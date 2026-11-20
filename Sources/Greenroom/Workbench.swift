import AppKit
import UniformTypeIdentifiers

/// The main window: running simulators and recent APKs in a sidebar, the selected simulator beside it,
/// device controls in the toolbar. An APK dropped anywhere on the window opens.
final class Workbench: NSObject, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    private let table = NSTableView()
    private let grid = SimulatorGrid(frame: .zero)
    /// Every running simulator at once, tiled, rather than the chosen one alone.
    private(set) var sideBySide = false
    /// Input in one simulator, and the toolbar's commands, go to all of them.
    private(set) var mirror = false
    /// Differences between the chosen simulator and the others are found and marked as the apps are used.
    private(set) var comparing = false
    private let compareBar = NSTextField(wrappingLabelWithString: "")
    private var compareHeight: NSLayoutConstraint!
    private let compareQueue = DispatchQueue(label: "greenroom-compare")
    private var compareScheduled = false
    private var compareTimer: Timer?
    /// What agents have done here, and the popover that shows it.
    let agentActivity = AgentActivity()
    var agentTools: AgentTools? { didSet { agentPanel = agentTools.map { AgentPanel(activity: agentActivity, tools: $0) } } }
    private var agentPanel: AgentPanel?
    private let agentPopover = NSPopover()
    private let status = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var selected: Simulator?

    private enum Row {
        case header(String)
        case simulator(Simulator)
        case recent(URL)
    }

    private static let hint = "Drop an APK here, or press ⌘O"

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Greenroom"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 620, height: 460)
        window.toolbarStyle = .unified

        let split = NSSplitViewController()
        let side = NSSplitViewItem(sidebarWithViewController: sidebarController())
        side.minimumThickness = 200
        side.maximumThickness = 320
        split.addSplitViewItem(side)
        let content = NSViewController()
        compareBar.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        compareBar.textColor = .secondaryLabelColor
        compareBar.maximumNumberOfLines = 7
        compareBar.lineBreakMode = .byTruncatingTail
        compareBar.isSelectable = true
        let stack = NSView()
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor   // one surface with the simulators above
        for v in [grid, compareBar] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; stack.addSubview(v) }
        compareHeight = compareBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: stack.topAnchor),
            grid.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: compareBar.topAnchor),
            compareBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
            compareBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            compareBar.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: -8),
            compareHeight,
        ])
        content.view = DropTarget(content: stack) { [weak self] in self?.open($0) }
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 900, height: 760))

        let toolbar = NSToolbar(identifier: "workbench")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        window.setFrameAutosaveName("Workbench")
        if window.frame.origin == .zero { window.center() }
        Engine.shared.onChange = { [weak self] in self?.reload() }
        reload()
    }

    // MARK: Opening and selecting

    @discardableResult
    func open(_ apk: URL, remember: Bool = true, options: [String] = [], fromAgent: Bool = false) -> Simulator? {
        do {
            let sim = try Engine.shared.open(apk: apk, options: options)
            if remember {
                Recents.add(apk)
                NSDocumentController.shared.noteNewRecentDocumentURL(apk)
            }
            sim.onState = { [weak self, weak sim] state in
                guard let self, let sim else { return }
                switch state {
                case .starting: break
                case .running: self.grid.view(for: sim)?.setMessage("")
                case .ended(let code): self.grid.view(for: sim)?.setMessage(Self.ended(sim, code))
                }
                self.reload()
            }
            if fromAgent, selected?.isAlive == true, Engine.shared.simulators.filter(\.isAlive).count > 1 {
                sideBySide = true   // an agent's second simulator goes beside the first, not over it
                reload()
            } else {
                select(sim)
            }
            return sim
        } catch {
            if !fromAgent { NSAlert(error: error).beginSheetModal(for: window) }
            return nil
        }
    }

    private static func ended(_ sim: Simulator, _ code: Int32) -> String {
        code == 0 ? "\(sim.name) has quit" : "\(sim.name) ended (exit \(code)). Help > Show Simulator Logs has the details."
    }

    private func select(_ sim: Simulator?) {
        selected = sim
        window.subtitle = sim?.name ?? ""
        reload()
        if let sim, let v = grid.view(for: sim) { window.makeFirstResponder(v) }
    }

    /// The simulators on screen: all of them side by side, or the chosen one.
    private func refreshGrid() {
        let sims = Engine.shared.simulators
        let shown = sideBySide ? sims.filter { $0.isAlive || $0 === selected } : (selected.map { [$0] } ?? [])
        grid.show(shown, chosen: selected, sideBySide: sideBySide, hint: Self.hint) { [weak self] view in
            view.onSelect = { [weak self] v in
                guard let self, let sim = v.simulator, sim !== self.selected else { return }
                self.selected = sim
                self.window.subtitle = sim.name
                self.reload()
            }
            view.route = { [weak self] input, v in
                guard let self else { return }
                if self.mirror { Engine.shared.simulators.filter { $0.state == .running }.forEach { $0.perform(input) } }
                else { v.simulator?.perform(input) }
                self.scheduleCompare()
            }
        }
        for v in grid.views { if let sim = v.simulator, case .ended(let code) = sim.state { v.setMessage(Self.ended(sim, code)) } }
    }

    private func reload() {
        let sims = Engine.shared.simulators
        if let s = selected, !sims.contains(where: { $0 === s }) { selected = sims.last; window.subtitle = selected?.name ?? "" }
        refreshGrid()
        rows = []
        if !sims.isEmpty {
            rows.append(.header("Running"))
            rows += sims.map { .simulator($0) }
        }
        let recents = Recents.all
        if !recents.isEmpty {
            rows.append(.header("Recent"))
            rows += recents.map { .recent($0) }
        }
        table.reloadData()
        if let s = selected, let i = rows.firstIndex(where: { if case .simulator(let x) = $0 { return x === s }; return false }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        let alive = sims.filter(\.isAlive).count
        status.stringValue = "\(alive == 0 ? "No simulators" : alive == 1 ? "1 simulator" : "\(alive) simulators") · engine \(Engine.shared.version)\nYour APKs stay on this Mac"
        window.toolbar?.validateVisibleItems()
    }

    // MARK: Sidebar

    private func sidebarController() -> NSViewController {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        let menu = NSMenu()
        menu.addItem(withTitle: "Close Simulator", action: #selector(closeClicked), keyEquivalent: "").target = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        status.font = .systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        status.maximumNumberOfLines = 2

        let view = NSView()
        for v in [scroll, status] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .simulator = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 24 }
        return 36
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .simulator(let sim):
            let detail: String
            let symbol: String
            switch sim.state {
            case .starting: detail = "Starting…"; symbol = "circle.dotted"
            case .running:
                let size = sim.deviceSize
                detail = size.width > 0 ? "Running · \(Int(size.width))×\(Int(size.height))" : "Running"
                symbol = "play.circle.fill"
            case .ended(let code): detail = code == 0 ? "Quit" : "Ended (exit \(code))"; symbol = "stop.circle"
            }
            return cell(symbol: symbol, tint: sim.state == .running ? .systemGreen : .secondaryLabelColor, title: sim.name, detail: detail)
        case .recent(let url):
            return cell(symbol: "shippingbox", tint: .secondaryLabelColor, title: url.lastPathComponent,
                        detail: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        }
    }

    private func cell(symbol: String, tint: NSColor, title: String, detail: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = tint
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingHead
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let stack = NSStackView(views: [icon, text])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        return stack
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        if case .simulator(let sim) = rows[row] { select(sim) }
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        if case .recent(let url) = rows[row] { open(url) }
    }

    @objc private func closeClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, case .simulator(let sim) = rows[row] else { return }
        Engine.shared.close(sim)
    }

    // MARK: Toolbar and its commands

    private struct Tool {
        let id: String, label: String, symbol: String, command: Selector
    }

    private static let tools: [Tool] = [
        Tool(id: "back", label: "Back", symbol: "chevron.backward", command: #selector(back(_:))),
        Tool(id: "home", label: "Home", symbol: "house", command: #selector(home(_:))),
        Tool(id: "rotate", label: "Rotate", symbol: "rotate.right", command: #selector(rotate(_:))),
        Tool(id: "appearance", label: "Light or Dark", symbol: "circle.lefthalf.filled", command: #selector(appearance(_:))),
        Tool(id: "shot", label: "Screenshot", symbol: "camera", command: #selector(screenshot(_:))),
        Tool(id: "restart", label: "Restart App", symbol: "arrow.clockwise", command: #selector(restart(_:))),
        Tool(id: "close", label: "Close Simulator", symbol: "xmark.circle", command: #selector(closeSelected(_:))),
        Tool(id: "grid", label: "Side by Side", symbol: "rectangle.split.2x1", command: #selector(toggleSideBySide(_:))),
        Tool(id: "mirror", label: "Mirror Input", symbol: "arrow.triangle.branch", command: #selector(toggleMirror(_:))),
        Tool(id: "compare", label: "Compare", symbol: "plusminus.circle", command: #selector(toggleCompare(_:))),
        Tool(id: "agent", label: "Agent", symbol: "sparkles", command: #selector(showAgent(_:))),
    ]
    private static let devices = ["phone", "foldable", "tablet", "desktop", "tv"]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["back", "home", "rotate", "appearance", "device", "flex", "grid", "mirror", "compare", "agent", "flex", "shot", "restart", "close"].map {
            $0 == "flex" ? .flexibleSpace : NSToolbarItem.Identifier($0)
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id.rawValue == "device" {
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Device"
            item.toolTip = "Switch the device while the app runs"
            item.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: "Device")
            let menu = NSMenu()
            for d in Self.devices {
                let m = menu.addItem(withTitle: Self.title(d), action: #selector(device(_:)), keyEquivalent: "")
                m.target = self
                m.representedObject = d
            }
            menu.addItem(.separator())
            let again = NSMenuItem(title: "Open Beside As", action: nil, keyEquivalent: "")
            again.submenu = NSMenu()
            for d in Self.devices {
                let m = again.submenu!.addItem(withTitle: Self.title(d), action: #selector(openBeside(_:)), keyEquivalent: "")
                m.target = self
                m.representedObject = d
            }
            menu.addItem(again)
            item.menu = menu
            return item
        }
        guard let tool = Self.tools.first(where: { $0.id == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        if tool.id == "agent" {
            let button = NSButton(image: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label) ?? NSImage(),
                                  target: self, action: tool.command)
            button.bezelStyle = .toolbar
            item.view = button
            item.label = tool.label
            item.toolTip = "Connect an agent"
            return item
        }
        item.label = tool.label
        item.toolTip = tool.label
        item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label)
        item.isBordered = true
        item.target = self
        item.action = tool.command
        return item
    }

    @objc func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier.rawValue {
        case "grid":
            item.image = Self.toggleImage("rectangle.split.2x1", on: sideBySide, label: item.label)
            item.toolTip = sideBySide ? "Side by Side: every simulator is shown" : "Side by Side: show every simulator at once"
            return Engine.shared.simulators.count > 1 || sideBySide
        case "mirror":
            item.image = Self.toggleImage("arrow.triangle.branch", on: mirror, label: item.label)
            item.toolTip = mirror ? "Mirror Input: on. Touches, keys and toolbar commands go to every simulator" : "Mirror Input: send touches and keys to every simulator"
            return Engine.shared.simulators.count > 1 || mirror
        case "compare":
            item.image = Self.toggleImage("plusminus.circle", on: comparing, label: item.label)
            item.toolTip = comparing ? "Compare: differences from the chosen simulator are marked" : "Compare: mark what differs between the simulators"
            return Engine.shared.simulators.count > 1 || comparing
        case "agent":
            (item.view as? NSButton)?.image = Self.toggleImage("sparkles", on: agentActivity.client != nil, label: item.label)
            item.toolTip = agentActivity.client.map { "\($0) is connected" } ?? "Connect an agent"
            return true
        case "close": return selected != nil
        default: return live != nil
        }
    }

    /// A toolbar symbol, in the accent colour while its switch is on.
    private static func toggleImage(_ symbol: String, on: Bool, label: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return on ? image?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) : image
    }

    private static func title(_ device: String) -> String { device == "tv" ? "TV" : device.capitalized }

    private var live: Simulator? { selected?.state == .running ? selected : nil }

    /// The simulators a toolbar command goes to: the chosen one, or every running one while input is mirrored.
    private var targets: [Simulator] {
        mirror ? Engine.shared.simulators.filter { $0.state == .running } : (live.map { [$0] } ?? [])
    }

    // MARK: Comparing

    @objc func toggleCompare(_ sender: Any?) { setComparing(!comparing) }

    /// Compare mode: the simulators side by side, the differences from the chosen one marked on each picture
    /// (boxes: content only there or moved; shaded: pixels that differ) and listed under them.
    func setComparing(_ on: Bool) {
        comparing = on
        compareTimer?.invalidate()
        compareTimer = nil
        if on {
            sideBySide = true
            // Content that loads by itself changes the answer too: look again every few seconds.
            compareTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scheduleCompare(after: 0) }
        } else {
            for v in grid.views { v.boxes = []; v.areas = [] }
            compareBar.stringValue = ""
        }
        compareHeight.constant = on ? 104 : 0
        reload()
        if on { scheduleCompare(after: 0) }
    }

    /// The APK chosen in a panel, started beside the chosen simulator with input mirrored and differences marked:
    /// two builds of an app, driven as one.
    @objc func compareWithAPK(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.message = selected == nil ? "Choose the first of two builds to compare" : "Choose the build to compare with \(selected!.name)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.compare(with: url)
        }
    }

    @discardableResult
    func compare(with apk: URL) -> Simulator? {
        let base = selected
        let sim = open(apk, remember: true, options: base?.options ?? [])
        if let base, base.isAlive { selected = base; window.subtitle = base.name }
        mirror = true
        setComparing(true)
        return sim
    }

    /// What the bar under the simulators says (for scripted checks).
    var compareText: String { compareBar.stringValue }

    private func scheduleCompare(after delay: TimeInterval = 0.5) {
        guard comparing, !compareScheduled else { return }
        compareScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let running = Engine.shared.simulators.filter { $0.state == .running }
            guard self.comparing, let base = self.live, running.count > 1 else {
                self.compareScheduled = false
                if self.comparing { self.compareBar.stringValue = "Compare: open a second simulator (File > Compare With APK…, or the device menu's Open Beside As)." }
                return
            }
            let others = running.filter { $0 !== base }
            self.compareQueue.async {
                let results = others.map { ($0, base.compare(with: $0).comparison) }
                DispatchQueue.main.async {
                    self.compareScheduled = false
                    guard self.comparing else { return }
                    self.show(results, base: base)
                }
            }
        }
    }

    private func show(_ results: [(Simulator, ScreenComparison)], base: Simulator) {
        var baseBoxes: [CGRect] = []
        var text: [String] = []
        func rect(_ n: ScreenNode) -> CGRect { CGRect(x: n.left, y: n.top, width: n.right - n.left, height: n.bottom - n.top) }
        for (other, c) in results {
            baseBoxes += c.onlyA.map(rect) + c.moved.map { rect($0.a) }
            if let v = grid.view(for: other) {
                v.boxes = c.onlyB.map(rect) + c.moved.map { rect($0.b) }
                v.areas = c.cells
            }
            let size = other.deviceSize
            text.append("\(base.name) → \(other.name) \(Int(size.width))×\(Int(size.height)): \(c.summary)")
            text += c.lines(limit: 5).map { "  " + $0 }
        }
        grid.view(for: base)?.boxes = baseBoxes
        grid.view(for: base)?.areas = []
        compareBar.stringValue = text.joined(separator: "\n")
    }

    @objc func toggleSideBySide(_ sender: Any?) { setSideBySide(!sideBySide) }
    @objc func toggleMirror(_ sender: Any?) { setMirror(!mirror) }

    func setSideBySide(_ on: Bool) {
        if !on, comparing { setComparing(false) }
        sideBySide = on
        reload()
    }

    func setMirror(_ on: Bool) {
        mirror = on
        window.subtitle = on ? "Mirroring input to every simulator" : (selected?.name ?? "")
        reload()
    }

    /// The chosen simulator's APK again, as another device, shown beside it.
    @objc func openBeside(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? String, let apk = selected?.apk else { return }
        openBeside(apk: apk, device: d)
    }

    @discardableResult
    func openBeside(apk: URL, device: String) -> Simulator? {
        let keep = selected
        let sim = open(apk, remember: false, options: ["--device", device])
        sideBySide = true
        if let keep { selected = keep; window.subtitle = keep.name }
        reload()
        return sim
    }

    /// Shows where an agent touched a simulator.
    func agentTouched(_ sim: Simulator, x: Int, y: Int) {
        grid.view(for: sim)?.flashTouch(deviceX: x, deviceY: y)
    }

    @objc func showAgent(_ sender: Any?) {
        guard let agentPanel else { return }
        if agentPopover.isShown { agentPopover.close(); return }
        agentPopover.contentViewController = agentPanel
        agentPopover.behavior = .transient
        let item = window.toolbar?.items.first { $0.itemIdentifier.rawValue == "agent" }
        if let anchor = item?.view ?? window.contentView {
            agentPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
        agentPanel.refresh()
    }

    func agentChanged() {
        agentPanel?.refresh()
        window.toolbar?.validateVisibleItems()
    }

    /// A click made as the mouse would make it, at a fraction of the simulator view's size (for scripted checks).
    func debugClick(atFraction f: CGPoint) {
        guard let sel = selected, let v = grid.view(for: sel) else { return }
        let p = v.convert(CGPoint(x: v.bounds.width * f.x, y: v.bounds.height * f.y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { v.mouseDown(with: e) } else { v.mouseUp(with: e) }
        }
    }

    /// Text typed as the keyboard would type it, a key press per character (for scripted checks).
    func debugType(_ text: String) {
        for ch in text {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: String(ch),
                                           charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0) else { continue }
            if let sel = selected { grid.view(for: sel)?.keyDown(with: e) }
        }
    }

    @objc func back(_ sender: Any?) { targets.forEach { $0.send("back") }; scheduleCompare() }
    @objc func home(_ sender: Any?) { targets.forEach { $0.send("home") }; scheduleCompare() }
    @objc func rotate(_ sender: Any?) { targets.forEach { $0.send("rotate right") }; scheduleCompare() }
    @objc func appearance(_ sender: Any?) { targets.forEach { $0.send("appearance toggle") }; scheduleCompare() }
    @objc func restart(_ sender: Any?) { targets.forEach { $0.send("restart") }; scheduleCompare() }
    @objc func closeSelected(_ sender: Any?) { if let s = selected { Engine.shared.close(s) } }

    @objc func device(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? String else { return }
        live?.send("device \(d)")
    }

    /// Saves the app's pixels as a PNG in the state folder, copies the picture to the clipboard and shows the file.
    @objc func screenshot(_ sender: Any?) {
        guard let sim = live else { return }
        let dir = Engine.shared.screenshots
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let file = dir.appendingPathComponent("\(sim.name) \(stamp.string(from: Date())).png")
        // The control channel splits on spaces: write under a plain name, then give the file its real one.
        let plain = dir.appendingPathComponent("shot-\(UUID().uuidString).png")
        // (a path relative to the engine's working folder, which is its state folder: the full path has a space.)
        sim.send("shot screenshots/\(plain.lastPathComponent)") { [weak self] answer in
            let written = FileManager.default.fileExists(atPath: plain.path)
            guard written, (try? FileManager.default.moveItem(at: plain, to: file)) != nil else {
                self?.window.subtitle = "Screenshot failed: \(answer)"
                return
            }
            if let image = NSImage(contentsOf: file) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}

/// Wraps the simulator view so an APK dropped on it opens.
private final class DropTarget: NSView {
    private let open: (URL) -> Void
    private var highlighted = false { didSet { needsDisplay = true } }

    init(content: NSView, open: @escaping (URL) -> Void) {
        self.open = open
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func apks(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "apk" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = !apks(sender).isEmpty
        return highlighted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = apks(sender)
        urls.forEach(open)
        return !urls.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
