import AppKit
import UniformTypeIdentifiers

/// The main window: running simulators and recent APKs in a sidebar, the selected simulator beside it,
/// device controls in the toolbar. An APK dropped anywhere on the window opens.
final class Workbench: NSObject, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let window: NSWindow
    private let table = NSTableView()
    private let grid = SimulatorGrid(frame: .zero)
    private let memoryMeter = MemoryMeter()
    /// The stage of devices, for the checks.
    var stage: SimulatorGrid { grid }
    /// Every running simulator at once, tiled, rather than the chosen one alone.
    private(set) var sideBySide = false
    /// Input in one simulator, and the toolbar's commands, go to all of them.
    private(set) var mirror = false
    /// The matrix wall's simulators (MatrixWall.swift), empty when none runs.
    var matrixSims: [Simulator] = []
    /// Bumped by every run and close of the matrix (a pending check or callback can tell its wall is gone).
    var matrixGeneration = 0
    /// Side by side and mirroring as they were before the matrix took them over, put back when it closes.
    var beforeMatrix: (sideBySide: Bool, mirror: Bool)?

    /// A click at a fraction of the chosen simulator's screen, routed as the mouse's would be (mirrored when on). Checks.
    func clickForCheck(_ f: CGPoint) {
        guard let sim = selected, let v = grid.view(for: sim) else { return }
        v.route?(.touch("down", f), v); v.route?(.touch("up", f), v)
    }
    /// Differences between the chosen simulator and the others are found and marked as the apps are used.
    private(set) var comparing = false
    /// The inspector pane is open: the pointer picks nodes on the chosen simulator.
    private(set) var inspecting = false
    private let inspector = Inspector()
    private var inspectorItem: NSSplitViewItem!
    private var inspectTimer: Timer?
    private let compareBar = NSTextField(wrappingLabelWithString: "")
    private var compareHeight: NSLayoutConstraint!
    /// The log panel under the simulators, and whether the flight recorder is on for the chosen simulator.
    private let logPanel = LogPanel(frame: .zero)
    private var logHeight: NSLayoutConstraint!
    private(set) var showingLog = false
    private var recording = Set<ObjectIdentifier>()
    private let compareQueue = DispatchQueue(label: "greenroom-compare")
    private var compareScheduled = false
    private var compareTimer: Timer?
    /// What agents have done here, and the popover that shows it.
    let agentActivity = AgentActivity()
    var agentTools: AgentTools? { didSet { agentPanel = agentTools.map { AgentPanel(activity: agentActivity, tools: $0) } } }
    private var agentPanel: AgentPanel?
    private let agentPopover = NSPopover()
    private let status = NSTextField(labelWithString: "")
    // The floating chrome: a glass bar along the top and a rail of panes on the right.
    private let header = GlassView()
    private let rail = GlassView()
    private var appChip: GlassButton!
    private var deviceButton: GlassButton!
    private var deviceButtons: [GlassButton] = []
    private var mirrorButton: GlassButton!
    private var layoutButtons: [GlassButton] = []
    private var recordButton: GlassButton!
    private var railButtons: [String: GlassButton] = [:]
    private var splitController: NSSplitViewController!
    // The network pane (right, over the stage) and the timeline dock (bottom).
    private let networkPane = NetworkPane(frame: .zero)
    private let timeline = TimelineDock(frame: .zero)
    private var gridTrailing: NSLayoutConstraint!
    private var timelineHeight: NSLayoutConstraint!
    private var networkLeading: NSLayoutConstraint!
    /// The right-hand slot holds one pane at a time; opening one sends the one there away.
    enum RightPane { case device, network, tests, diagnostics, recordings }
    private(set) var rightPane: RightPane?
    var showingNetwork: Bool { rightPane == .network }
    var showingDevice: Bool { rightPane == .device }
    var showingTests: Bool { rightPane == .tests }
    var showingDiagnostics: Bool { rightPane == .diagnostics }
    var showingRecordings: Bool { rightPane == .recordings }
    private let devicePane = DevicePane(frame: .zero)
    private var deviceLeading: NSLayoutConstraint!
    private static let deviceWidth: CGFloat = 384
    // Tests pane (right slot, shared with Device and Network).
    private let testsPane = TestsPane(frame: .zero)
    private var testsLeading: NSLayoutConstraint!
    private static let testsWidth: CGFloat = 520
    // Diagnostics pane (extras): performance, accessibility audit, background work, clipboard, skin.
    private let diagnosticsPane = DiagnosticsPane(frame: .zero)
    private var diagnosticsLeading: NSLayoutConstraint!
    private static let diagnosticsWidth: CGFloat = 420
    // Recordings pane (right slot): see RecordingsPane.swift.
    private let recordingsPane = RecordingsPane(frame: .zero)
    private var recordingsLeading: NSLayoutConstraint!
    private static let recordingsWidth: CGFloat = 470
    private let emptyStage = EmptyStage(frame: .zero)
    let toast = Toast(frame: .zero)
    let palette = Palette(frame: .zero)
    private let scrim = Scrim()
    // Screenshot tests (SnapshotReview.swift): a full-stage sheet.
    let snapshotReview = SnapshotReview(frame: .zero)
    // The screen map (ScreenMap.swift): a full-stage sheet too.
    let screenMap = ScreenMap(frame: .zero)
    private(set) var showingPalette = false
    private(set) var showingTimeline = false
    private static let networkWidth: CGFloat = 600
    private var rows: [Row] = []
    private(set) var selected: Simulator?
    /// The Sessions section of the sidebar (SessionsController.swift).
    let sessions = SessionsController()

    private enum Row {
        case header(String)
        case session(Session)
        case simulator(Simulator)
        case recent(URL)
    }

    private static let hint = ""

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Greenroom"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Design.stage

        let split = NSSplitViewController()
        splitController = split
        let side = NSSplitViewItem(sidebarWithViewController: sidebarController())
        side.minimumThickness = 200
        side.maximumThickness = 320
        side.isCollapsed = true   // the stage gets the window; the library slides in when asked for
        split.addSplitViewItem(side)
        let content = NSViewController()
        compareBar.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        compareBar.textColor = .secondaryLabelColor
        compareBar.maximumNumberOfLines = 7
        compareBar.lineBreakMode = .byTruncatingTail
        compareBar.isSelectable = true
        let stack = StageBackground()
        for v in [grid, emptyStage, compareBar, timeline, logPanel, toast] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; stack.addSubview(v) }
        emptyStage.onOpen = { [weak self] in self?.open($0) }
        DevHooks.shared.install(workbench: self, in: stack, over: grid)   // developer hooks (DevHooks.swift)
        emptyStage.onChoose = { NSApp.sendAction(Selector(("openDocument:")), to: nil, from: nil) }
        timeline.isHidden = true
        compareHeight = compareBar.heightAnchor.constraint(equalToConstant: 0)
        timelineHeight = timeline.heightAnchor.constraint(equalToConstant: 0)
        gridTrailing = grid.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -64)
        logHeight = logPanel.heightAnchor.constraint(equalToConstant: 0)
        logPanel.isHidden = true
        logPanel.wantsLayer = true   // a dock of glass along the bottom, as the timeline will be
        logPanel.layer?.cornerRadius = Design.glassRadius
        logPanel.layer?.cornerCurve = .continuous
        logPanel.layer?.masksToBounds = true
        logPanel.layer?.borderWidth = 1
        logPanel.layer?.borderColor = Design.stroke.cgColor
        logPanel.layer?.backgroundColor = NSColor(srgbRed: 0.17, green: 0.18, blue: 0.2, alpha: 0.86).cgColor
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: stack.topAnchor, constant: Design.barHeight + 8),
            grid.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            gridTrailing,
            emptyStage.topAnchor.constraint(equalTo: grid.topAnchor),
            emptyStage.bottomAnchor.constraint(equalTo: grid.bottomAnchor),
            emptyStage.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            emptyStage.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            toast.centerXAnchor.constraint(equalTo: grid.centerXAnchor),
            toast.topAnchor.constraint(equalTo: grid.topAnchor, constant: 4),
            grid.bottomAnchor.constraint(equalTo: compareBar.topAnchor),
            compareBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16),
            compareBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16),
            compareBar.bottomAnchor.constraint(equalTo: timeline.topAnchor, constant: -8),
            compareHeight,
            timeline.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Design.margin),
            timeline.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            timeline.bottomAnchor.constraint(equalTo: logPanel.topAnchor, constant: -8),
            timelineHeight,
            logPanel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Design.margin),
            logPanel.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            logPanel.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: -Design.margin),
            logHeight,
        ])
        let drop = DropTarget(content: stack) { [weak self] in self?.open($0) }
        content.view = drop
        buildChrome(in: drop)
        linkPanes()
        grid.onClose = { Engine.shared.close($0) }
        memoryMeter.onReading = { [weak self] in self?.grid.memoryLabel.show($0) }
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 380
        inspectorItem.isCollapsed = true
        split.addSplitViewItem(inspectorItem)
        inspector.onPick = { [weak self] node in
            guard let self, let sim = self.selected else { return }
            self.grid.view(for: sim)?.outlined = node?.frame
        }
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1080, height: 780))

        // An empty toolbar only gives the title bar the height that centres the window buttons on the glass bar.
        let toolbar = NSToolbar(identifier: "workbench-empty")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: 1440, height: 900))

        window.setFrameAutosaveName("Workbench3")   // the glass layout wants a larger first window
        if window.frame.origin == .zero { window.center() }
        Engine.shared.onChange = { [weak self] in self?.reload() }
        reload()
        sessions.onChange = { [weak self] in self?.reload() }
        sessions.install(workbench: self)
    }

    // MARK: Opening and selecting

    @discardableResult
    func open(_ apk: URL, remember: Bool = true, options: [String] = [], fromAgent: Bool = false) -> Simulator? {
        Reports.shared.count(.apkOpened)
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

    func select(_ sim: Simulator?) {
        selected = sim
        window.subtitle = sim?.name ?? ""
        sessions.selected(sim)
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
                self.sessions.selected(sim)
                self.reload()
            }
            view.onHover = { [weak self] v, inside in
                if let sim = v.simulator { self?.matrixHover(sim, inside: inside) }
            }
            view.route = { [weak self] input, v in
                guard let self else { return }
                if self.mirror { Engine.shared.simulators.filter { $0.state == .running }.forEach { $0.perform(input) } }
                else { v.simulator?.perform(input) }
                self.scheduleCompare()
            }
        }
        for v in grid.views { if let sim = v.simulator, case .ended(let code) = sim.state { v.setMessage(Self.ended(sim, code)) } }
        for v in grid.views {
            v.inspecting = inspecting && v.simulator === selected
            v.onPoint = { [weak self] x, y in self?.inspector.pick(atDeviceX: x, y: y) }
        }
    }

    private func reload() {
        let sims = Engine.shared.simulators
        if let s = selected, !sims.contains(where: { $0 === s }) { selected = sims.last; window.subtitle = selected?.name ?? "" }
        refreshGrid()
        memoryMeter.watch(sims)
        let nothing = sims.isEmpty
        if emptyStage.isHidden == nothing {   // shown when nothing runs, gone (after a fade) when something does
            if nothing { emptyStage.reload(); emptyStage.alphaValue = 0; emptyStage.isHidden = false }
            Design.animate(Design.arrive, { self.emptyStage.animator().alphaValue = nothing ? 1 : 0 },
                           done: { if !Engine.shared.simulators.isEmpty { self.emptyStage.isHidden = true } })
        }
        if showingLog { logPanel.follow(selected) }
        if showingNetwork { networkPane.follow(selected) }
        if showingDevice { devicePane.follow(selected) }
        testsPane.follow(selected)
        if showingDiagnostics { diagnosticsPane.follow(selected) }
        if showingTimeline { timeline.follow(selected) }
        rows = []
        for group in sessions.groups() {
            rows.append(.header(group.header))
            rows += group.sessions.map { .session($0) }
        }
        let loose = sims.filter { sessions.session(forSimulator: $0) == nil }   // a session's own is on its row
        if !loose.isEmpty {
            rows.append(.header("Running"))
            rows += loose.map { .simulator($0) }
        }
        let recents = Recents.all
        if !recents.isEmpty {
            rows.append(.header("Recent"))
            rows += recents.map { .recent($0) }
        }
        table.reloadData()
        if let s = selected, let i = rows.firstIndex(where: {
            if case .session(let x) = $0 { return x.simulator === s }
            return false
        }) ?? rows.firstIndex(where: { if case .simulator(let x) = $0 { return x === s }; return false }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        let alive = sims.filter(\.isAlive).count
        status.stringValue = "\(alive == 0 ? "No simulators" : alive == 1 ? "1 simulator" : "\(alive) simulators") · engine \(Engine.shared.version)\nYour APKs stay on this Mac"
        window.toolbar?.validateVisibleItems()
        updateChrome()
    }

    // MARK: Floating chrome

    private func buildChrome(in host: NSView) {
        appChip = GlassButton(symbol: nil, title: "No app", label: "Running apps", style: .well, target: self, action: #selector(showAppMenu(_:)))
        deviceButton = GlassButton(symbol: "iphone", title: "Phone", label: "Switch the device while the app runs", style: .well, target: self, action: #selector(showDeviceMenu(_:)))
        deviceButtons = [
            GlassButton(symbol: "chevron.backward", label: "Back", target: self, action: #selector(back(_:))),
            GlassButton(symbol: "house", label: "Home", target: self, action: #selector(home(_:))),
            GlassButton(symbol: "rotate.right", label: "Rotate", target: self, action: #selector(rotate(_:))),
            GlassButton(symbol: "circle.lefthalf.filled", label: "Light or dark", target: self, action: #selector(appearance(_:))),
            GlassButton(symbol: nil, title: "Shake", label: "Shake the device", target: self, action: #selector(shake(_:))),
        ]
        mirrorButton = GlassButton(symbol: "dot.radiowaves.left.and.right", title: "Mirror", label: "Send touches and keys to every device", style: .well, target: self, action: #selector(toggleMirror(_:)))
        layoutButtons = [
            GlassButton(symbol: "iphone", label: "One device", target: self, action: #selector(showOne(_:))),
            GlassButton(symbol: "rectangle.split.2x1", label: "Every device, side by side", target: self, action: #selector(showAll(_:))),
            GlassButton(symbol: "plusminus", label: "Compare: mark what differs", target: self, action: #selector(toggleCompare(_:))),
        ]
        recordButton = GlassButton(symbol: "record.circle", title: "Record", label: "Record input, log, network and screen for replay", style: .record, target: self, action: #selector(toggleRecording(_:)))
        let library = GlassButton(symbol: "sidebar.left", label: "Show the library", target: self, action: #selector(toggleLibrary(_:)))
        let shot = GlassButton(symbol: "camera", label: "Screenshot", target: self, action: #selector(screenshot(_:)))
        let commands = GlassButton(symbol: "magnifyingglass", title: "Commands   ⌘K", label: "Search every command, device, app and recording", style: .well, target: self, action: #selector(showPalette(_:)))

        func group(_ views: [NSView]) -> NSView {
            let well = NSView()
            well.wantsLayer = true
            well.layer?.backgroundColor = Design.well.cgColor
            well.layer?.cornerRadius = Design.controlRadius
            well.layer?.cornerCurve = .continuous
            let row = NSStackView(views: views)
            row.spacing = 2
            row.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
            row.translatesAutoresizingMaskIntoConstraints = false
            well.addSubview(row)
            NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: well.topAnchor), row.bottomAnchor.constraint(equalTo: well.bottomAnchor),
                                         row.leadingAnchor.constraint(equalTo: well.leadingAnchor), row.trailingAnchor.constraint(equalTo: well.trailingAnchor)])
            return well
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [library, appChip, deviceButton, group(deviceButtons), spacer, mirrorButton, group(layoutButtons), shot, recordButton, commands])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 76, bottom: 0, right: 8)   // the window's own buttons sit on the glass's left
        bar.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(bar)

        let rails: [(String, String, String, Selector)] = [
            ("device", "slider.horizontal.3", "Device controls", #selector(toggleDevicePane(_:))),
            ("inspect", "cursorarrow.rays", "Inspect: pick what is on screen", #selector(toggleInspector(_:))),
            ("diagnostics", "stethoscope", "Diagnostics: performance, accessibility, background work", #selector(toggleDiagnostics(_:))),
            ("-", "", "", #selector(toggleLog(_:))),
            ("network", "arrow.up.arrow.down", "Network: the app's requests", #selector(toggleNetwork(_:))),
            ("timeline", "chart.bar.xaxis", "Timeline: the last minute, track by track", #selector(toggleTimeline(_:))),
            ("log", "text.alignleft", "Log", #selector(toggleLog(_:))),
            ("-", "", "", #selector(toggleLog(_:))),
            ("tests", "checkmark.circle", "Tests: run an androidTest APK", #selector(toggleTests(_:))),
            ("snapshots", "photo.stack", "Screenshot tests", #selector(toggleSnapshots(_:))),
            ("map", "point.3.connected.trianglepath.dotted", "Screen map: walk the app and see every screen", #selector(toggleMap(_:))),
            ("recordings", "film", "Recordings: replay, and find the first build that differs", #selector(toggleRecordings(_:))),
            ("-", "", "", #selector(toggleLog(_:))),
            ("agent", "sparkles", "Agent", #selector(showAgent(_:))),
        ]
        // Four groups, a hairline between them: the device, what it does over time, checking builds, the agent.
        let column = NSStackView(views: rails.map { id, symbol, label, action -> NSView in
            if id == "-" {
                let line = NSView()
                line.wantsLayer = true
                line.layer?.backgroundColor = Design.stroke.cgColor
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                line.widthAnchor.constraint(equalToConstant: 22).isActive = true
                return line
            }
            let b = GlassButton(symbol: symbol, label: label, target: self, action: action)
            railButtons[id] = b
            return b
        })
        column.orientation = .vertical
        column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        column.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(column)

        // Panes first, then the bar and rail over them, then the palette's veil and the palette on top.
        for v in [networkPane, devicePane, testsPane, diagnosticsPane, recordingsPane, header, rail, scrim, palette] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(v)
        }
        scrim.isHidden = true
        palette.isHidden = true
        installSnapshotReview(in: host)
        installScreenMap(in: host)
        scrim.onClick = { [weak self] in self?.hidePalette() }
        palette.onClose = { [weak self] in self?.hidePalette() }
        palette.source = { [weak self] in self?.paletteItems() ?? [] }
        networkPane.isHidden = true
        devicePane.isHidden = true
        testsPane.isHidden = true
        testsPane.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
        testsPane.follow(selected)
        testsLeading = testsPane.leadingAnchor.constraint(equalTo: host.trailingAnchor, constant: 20)
        diagnosticsPane.isHidden = true
        wireDiagnostics()
        diagnosticsLeading = diagnosticsPane.leadingAnchor.constraint(equalTo: host.trailingAnchor, constant: 20)
        recordingsPane.isHidden = true
        recordingsPane.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
        recordingsPane.onOpenTrace = { [weak self] file in self?.view(recording: file) }
        recordingsLeading = recordingsPane.leadingAnchor.constraint(equalTo: host.trailingAnchor, constant: 20)
        devicePane.targets = { [weak self] in
            guard let self else { return [] }
            return self.devicePane.toAll ? Engine.shared.simulators.filter { $0.state == .running } : (self.live.map { [$0] } ?? [])
        }
        deviceLeading = devicePane.leadingAnchor.constraint(equalTo: host.trailingAnchor, constant: 20)
        // Hidden, the pane waits just off the window's right edge; shown, it slides in beside the rail.
        networkLeading = networkPane.leadingAnchor.constraint(equalTo: host.trailingAnchor, constant: 20)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: host.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 6),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Design.margin),
            header.heightAnchor.constraint(equalToConstant: 44),
            bar.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            bar.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            rail.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.margin),
            networkPane.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.margin),
            networkPane.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Design.margin),
            networkPane.widthAnchor.constraint(equalToConstant: Self.networkWidth),
            networkLeading,
            scrim.topAnchor.constraint(equalTo: host.topAnchor), scrim.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: host.leadingAnchor), scrim.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            palette.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            palette.topAnchor.constraint(equalTo: host.topAnchor, constant: 110),
            devicePane.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.margin),
            devicePane.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Design.margin),
            devicePane.widthAnchor.constraint(equalToConstant: Self.deviceWidth),
            deviceLeading,
            testsPane.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.margin),
            testsPane.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Design.margin),
            testsPane.widthAnchor.constraint(equalToConstant: Self.testsWidth),
            testsLeading,
            diagnosticsPane.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.margin),
            diagnosticsPane.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Design.margin),
            diagnosticsPane.widthAnchor.constraint(equalToConstant: Self.diagnosticsWidth),
            diagnosticsLeading,
            recordingsPane.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.margin),
            recordingsPane.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Design.margin),
            recordingsPane.widthAnchor.constraint(equalToConstant: Self.recordingsWidth),
            recordingsLeading,
            rail.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Design.margin),
            column.topAnchor.constraint(equalTo: rail.topAnchor),
            column.bottomAnchor.constraint(equalTo: rail.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: rail.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: rail.trailingAnchor),
        ])
    }

    private func updateChrome() {
        guard appChip != nil else { return }
        let alive = Engine.shared.simulators.filter(\.isAlive).count
        if let sim = selected {
            let state = sim.state == .running ? "  ● Live" : (sim.state == .starting ? "  Starting…" : "  Ended")
            let text = NSMutableAttributedString(string: sim.name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Design.ink])
            text.append(NSAttributedString(string: state, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                                       .foregroundColor: sim.state == .running ? Design.accent : Design.mute]))
            if alive > 1 { text.append(NSAttributedString(string: "  \(alive) devices", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Design.mute])) }
            appChip.title = sim.name
            appChip.attributedTitle = text
        } else {
            appChip.title = "Open an APK"
        }
        let kind = selected.flatMap { s -> String? in
            guard let i = s.options.firstIndex(of: "--device"), let d = s.options.dropFirst(i + 1).first else { return nil }
            return Self.title(d)
        } ?? "Phone"
        deviceButton.title = kind
        deviceButton.isEnabled = live != nil
        for b in deviceButtons { b.isEnabled = live != nil }
        mirrorButton.isOn = mirror
        mirrorButton.title = mirror ? "Mirroring to all" : "Mirror"
        mirrorButton.isHidden = alive < 2 && !mirror
        layoutButtons[0].isOn = !sideBySide
        layoutButtons[1].isOn = sideBySide && !comparing
        layoutButtons[2].isOn = comparing
        for b in layoutButtons.dropFirst() { b.isEnabled = alive > 1 || sideBySide }
        recordButton.isOn = isRecording
        recordButton.title = isRecording ? "Recording" : "Record"
        recordButton.isEnabled = live != nil
        railButtons["inspect"]?.isOn = inspecting
        railButtons["log"]?.isOn = showingLog
        railButtons["network"]?.isOn = showingNetwork
        railButtons["device"]?.isOn = showingDevice
        railButtons["tests"]?.isOn = showingTests
        railButtons["diagnostics"]?.isOn = showingDiagnostics
        railButtons["recordings"]?.isOn = showingRecordings
        railButtons["timeline"]?.isOn = showingTimeline
        timeline.saveButton.isEnabled = isRecording
        railButtons["agent"]?.isOn = agentActivity.client != nil
        railButtons["snapshots"]?.isOn = snapshotReview.isOpen
        railButtons["map"]?.isOn = screenMap.isOpen
    }

    @objc func toggleNetwork(_ sender: Any?) { setShowingNetwork(!showingNetwork) }
    @objc func toggleTimeline(_ sender: Any?) { setShowingTimeline(!showingTimeline) }

    @objc func toggleDevicePane(_ sender: Any?) { setShowingDevice(!showingDevice) }
    @objc func toggleTests(_ sender: Any?) { setShowingTests(!showingTests) }
    @objc func toggleDiagnostics(_ sender: Any?) { setShowingDiagnostics(!showingDiagnostics) }
    @objc func toggleRecordings(_ sender: Any?) { setShowingRecordings(!showingRecordings) }

    // MARK: Screenshot tests

    private func installSnapshotReview(in host: NSView) {
        snapshotReview.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(snapshotReview, positioned: .below, relativeTo: scrim)
        NSLayoutConstraint.activate([snapshotReview.topAnchor.constraint(equalTo: host.topAnchor), snapshotReview.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     snapshotReview.leadingAnchor.constraint(equalTo: host.leadingAnchor), snapshotReview.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        snapshotReview.defaultAPK = { [weak self] in self?.selected?.apk }
        snapshotReview.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
        snapshotReview.onToggle = { [weak self] in self?.updateChrome() }
    }

    @objc func toggleSnapshots(_ sender: Any?) { if snapshotReview.isOpen { snapshotReview.close() } else { showSnapshots() } }

    func showSnapshots(run: Bool = false) {
        Reports.shared.count(.snapshots)
        if screenMap.isOpen { screenMap.close() }
        snapshotReview.open()
        if run { snapshotReview.runIfReady() }
    }

    // MARK: Screen map

    private func installScreenMap(in host: NSView) {
        screenMap.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(screenMap, positioned: .below, relativeTo: scrim)
        NSLayoutConstraint.activate([screenMap.topAnchor.constraint(equalTo: host.topAnchor), screenMap.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     screenMap.leadingAnchor.constraint(equalTo: host.leadingAnchor), screenMap.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
        screenMap.defaultAPK = { [weak self] in self?.selected?.apk }
        screenMap.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
        screenMap.onToggle = { [weak self] in self?.updateChrome() }
        screenMap.onGo = { [weak self] screen, map in self?.goThere(screen, map) }
    }

    @objc func toggleMap(_ sender: Any?) { if screenMap.isOpen { screenMap.close() } else { showMap() } }

    func showMap(walk: Bool = false) {
        Reports.shared.count(.screenMap)
        if snapshotReview.isOpen { snapshotReview.close() }
        screenMap.open()
        if walk, screenMap.run == nil { screenMap.walk() }
    }

    /// Replays a screen's route from the map on the selected device: restart (at the route's deep link), then each
    /// step, settling after each. The map closes first so the device can be watched getting there.
    func goThere(_ screen: MapScreen, _ map: ScreenMapData, done: ((Bool) -> Void)? = nil) {
        guard let sim = selected ?? Engine.shared.simulators.first(where: { $0.state == .running }), sim.state == .running else {
            toast.show("Open the app first: the route is replayed on a running device", problem: true); done?(false); return
        }
        let mapped = map.apk?.lastPathComponent ?? map.apkName
        if sim.apk.lastPathComponent != mapped {
            toast.show("The selected device runs \(sim.apk.lastPathComponent); this map is of \(mapped)", problem: true); done?(false); return
        }
        screenMap.close()
        grid.view(for: sim).map { window.makeFirstResponder($0) }
        toast.show("Going to \(screen.label)…")
        let commands = [screen.start.map { "restart \($0)" } ?? "restart"] + screen.steps
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failed: String?
            for (i, c) in commands.enumerated() {
                let answer = sim.sendSync(c)
                if answer.hasPrefix("error") { failed = "Step \(i) (\(ScreenMap.describe(c))) failed: " + answer.replacingOccurrences(of: "error: ", with: ""); break }
                _ = sim.sendSync("settle 1500 100")
            }
            DispatchQueue.main.async {
                self?.toast.show(failed ?? "On \(screen.label)", problem: failed != nil)
                done?(failed == nil)
            }
        }
    }

    // MARK: Command palette

    @objc func showPalette(_ sender: Any?) {
        Reports.shared.count(.palette)
        if showingPalette { hidePalette(); return }
        showingPalette = true
        scrim.isHidden = false
        palette.isHidden = false
        scrim.alphaValue = 0
        palette.alphaValue = 0
        palette.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: 8))
        palette.open()
        Design.animate(Design.arrive, {
            self.scrim.animator().alphaValue = 1
            self.palette.animator().alphaValue = 1
            self.palette.layer?.setAffineTransform(.identity)
        })
    }

    func hidePalette() {
        guard showingPalette else { return }
        showingPalette = false
        Design.animate(Design.snap, {
            self.scrim.animator().alphaValue = 0
            self.palette.animator().alphaValue = 0
        }, done: {
            if !self.showingPalette { self.scrim.isHidden = true; self.palette.isHidden = true }
        })
        if let sim = selected, let v = grid.view(for: sim) { window.makeFirstResponder(v) }
    }

    /// A device command from the palette, sent where the toolbar's go, with the engine's answer as a toast.
    private func run(_ command: String, _ done: String) {
        let to = targets
        guard !to.isEmpty else { toast.show("No device is running", problem: true); return }
        for (i, s) in to.enumerated() {
            s.send(command) { [weak self] answer in
                guard i == 0 else { return }
                let problem = answer.hasPrefix("error") || answer.hasPrefix("no ") || answer.contains(" has no ")
                self?.toast.show(problem ? answer.replacingOccurrences(of: "error: ", with: "") : (to.count > 1 ? "\(done) on \(to.count) devices" : done), problem: problem)
            }
        }
        scheduleCompare()
    }

    /// Everything the palette offers, as things stand now.
    private func paletteItems() -> [PaletteItem] {
        var out: [PaletteItem] = []
        func add(_ id: String, _ title: String, _ group: String, _ symbol: String, _ shortcut: String = "", keywords: String = "", _ run: @escaping () -> Void) {
            out.append(PaletteItem(id: id, title: title, group: group, symbol: symbol, shortcut: shortcut, keywords: keywords, run: run))
        }
        func setting(_ id: String, _ title: String, _ symbol: String, _ command: String, keywords: String = "") {
            add("set." + id, title, "Device", symbol, keywords: keywords) { [weak self] in self?.run(command, title) }
        }
        // Apps.
        add("open", "Open APK…", "App", "folder", "⌘O") { NSApp.sendAction(Selector(("openDocument:")), to: nil, from: nil) }
        add("compare.apk", "Compare with another build…", "App", "plusminus", "⇧⌘O") { [weak self] in self?.compareWithAPK(nil) }
        add("matrix", "Matrix wall: every device, appearance, language and text size", "App", "square.grid.3x3", "⌥⌘X", keywords: "grid locale dark font rtl") { [weak self] in self?.showMatrix(nil) }
        if !matrixSims.isEmpty { add("matrix.close", "Close the matrix wall", "App", "xmark.square") { [weak self] in self?.closeMatrix(nil) } }
        let sample = Engine.shared.root.deletingLastPathComponent().appendingPathComponent("engine-testapp.apk")
        if FileManager.default.fileExists(atPath: sample.path) { add("open.sample", "Open the sample app", "App", "shippingbox") { [weak self] in self?.open(sample) } }
        for url in Recents.all.prefix(8) {
            add("open." + url.path, "Open " + url.deletingPathExtension().lastPathComponent, "Recent", "clock.arrow.circlepath", keywords: url.path) { [weak self] in self?.open(url) }
        }
        // Running devices.
        for sim in Engine.shared.simulators where sim.isAlive {
            let kind = sim.options.firstIndex(of: "--device").flatMap { i in i + 1 < sim.options.count ? Self.title(sim.options[i + 1]) : nil } ?? "Phone"
            add("switch." + String(UInt(bitPattern: ObjectIdentifier(sim).hashValue)), "Go to \(sim.name) on \(kind)", "Running", "iphone") { [weak self] in self?.select(sim) }
        }
        if live != nil {
            add("back", "Back", "Device", "chevron.backward", "⌘[") { [weak self] in self?.back(nil) }
            add("home", "Home", "Device", "house", "⇧⌘H") { [weak self] in self?.home(nil) }
            add("rotate", "Rotate", "Device", "rotate.right", "⌘R") { [weak self] in self?.rotate(nil) }
            add("shake", "Shake", "Device", "iphone.radiowaves.left.and.right") { [weak self] in self?.shake(nil) }
            add("shot", "Save screenshot", "Device", "camera", "⌘S", keywords: "capture picture") { [weak self] in self?.screenshot(nil) }
            add("restart", "Restart the app", "App", "arrow.clockwise", "⇧⌘R") { [weak self] in self?.restart(nil) }
            add("close", "Close this simulator", "App", "xmark.circle", "⇧⌘W", keywords: "quit stop") { [weak self] in self?.closeSelected(nil) }
            if grid.canTidy {
                add("tidy", "Tidy up the simulators", "Device", "square.grid.2x2", keywords: "arrange layout tile reset size") { [weak self] in self?.tidyUp(nil) }
            }
            setting("dark", "Dark appearance", "moon", "appearance dark", keywords: "night theme")
            setting("light", "Light appearance", "sun.max", "appearance light", keywords: "day theme")
            for (d, _) in [("phone", 0), ("foldable", 0), ("pixel-10-pro-fold", 0), ("watch", 0), ("tablet", 0), ("desktop", 0), ("tv", 0)] {
                setting("device." + d, "Switch to \(Self.title(d))", "iphone.gen3", "device \(d)", keywords: "device size form factor")
                add("beside." + d, "Open beside as \(Self.title(d))", "Device", "rectangle.split.2x1", keywords: "another second") { [weak self] in
                    if let apk = self?.selected?.apk { self?.openBeside(apk: apk, device: d) }
                }
            }
            for (tag, name) in [("en-US", "English (US)"), ("fr-FR", "French"), ("de-DE", "German"), ("es-ES", "Spanish"), ("ja-JP", "Japanese"), ("ar-EG", "Arabic, right to left"), ("he-IL", "Hebrew, right to left"), ("hi-IN", "Hindi")] {
                setting("locale." + tag, "Language: \(name)", "globe", "locale \(tag)", keywords: "locale translate rtl " + tag)
            }
            for f in ["0.85", "1.0", "1.3", "1.5", "2.0"] { setting("font." + f, "Text size \(f)×", "textformat.size", "fontscale \(f)", keywords: "font scale accessibility larger") }
            for (n, t) in [("online", "Network: online"), ("3g", "Network: slow 3G"), ("lossy", "Network: lossy"), ("offline", "Network: offline")] {
                setting("net." + n, t, "wifi", "network \(n)", keywords: "conditions connection airplane")
            }
            for (v, t) in [("run", "Location: city run"), ("bike", "Location: bicycle ride"), ("drive", "Location: freeway drive"), ("37.7749 -122.4194", "Location: San Francisco"), ("51.5072 -0.1276", "Location: London"), ("35.6762 139.6503", "Location: Tokyo"), ("none", "Location: none")] {
                setting("loc." + v, t, "location", "location \(v)", keywords: "gps map")
            }
            for z in ["UTC", "America/Los_Angeles", "America/New_York", "Europe/London", "Asia/Tokyo"] { setting("tz." + z, "Time zone: \(z)", "clock", "timezone \(z)", keywords: "zone clock") }
            setting("anim.off", "Animations off", "tortoise", "animscale 0", keywords: "speed duration scale")
            setting("anim.on", "Animations on", "hare", "animscale 1", keywords: "speed duration scale")
            setting("anim.slow", "Slow animations", "tortoise.fill", "animscale 10", keywords: "speed duration scale")
            setting("bounds.on", "Show layout bounds", "square.dashed", "debug layout on", keywords: "debug outlines")
            setting("bounds.off", "Hide layout bounds", "square", "debug layout off", keywords: "debug outlines")
            setting("kb.on", "Software keyboard on", "keyboard", "keyboard soft on", keywords: "ime")
            setting("kb.off", "Software keyboard off", "keyboard", "keyboard soft off", keywords: "ime")
            setting("bt.off", "Bluetooth off", "antenna.radiowaves.left.and.right.slash", "bluetooth off")
            setting("bt.on", "Bluetooth on", "antenna.radiowaves.left.and.right", "bluetooth on")
            setting("thermal.severe", "Thermal: severe", "thermometer.high", "thermal severe", keywords: "heat hot")
            setting("thermal.none", "Thermal: normal", "thermometer.low", "thermal none", keywords: "heat")
            setting("recreate", "Recreate the activity", "arrow.triangle.2.circlepath", "recreate", keywords: "configuration change")
            setting("death", "Kill the process (state kept)", "bolt.slash", "process-death", keywords: "process death restore saved state")
            setting("memory", "Low memory warning", "memorychip", "memory low", keywords: "trim")
            setting("fp.ok", "Fingerprint: matching", "touchid", "biometrics match", keywords: "biometric auth")
            setting("fp.no", "Fingerprint: not matching", "touchid", "biometrics nomatch", keywords: "biometric auth")
            setting("perm.allow", "Allow the permission request", "checkmark.shield", "permission allow")
            setting("perm.deny", "Deny the permission request", "xmark.shield", "permission deny")
            setting("perm.reset", "Reset permissions", "shield", "permission reset")
            add(isRecording ? "rec.stop" : "rec.start", isRecording ? "Stop recording" : "Start recording", "Record", "record.circle", "⌥⌘R") { [weak self] in self?.toggleRecording(nil) }
            if isRecording { add("rec.save", "Save recording", "Record", "square.and.arrow.down", "⇧⌘S") { [weak self] in self?.saveRecordingAndShow(nil) } }
        }
        out += DevHooks.shared.paletteItems(for: selected)   // developer hooks (DevHooks.swift)
        out += sessions.paletteItems()                       // worktree sessions (SessionsController.swift)
        // Layout and panes.
        add("layout.one", "Show one device", "View", "iphone") { [weak self] in self?.setSideBySide(false) }
        add("layout.all", "Show every device side by side", "View", "rectangle.split.2x1", "⌘\\") { [weak self] in self?.showAll(nil) }
        add("compare", comparing ? "Stop comparing" : "Compare the devices", "View", "plusminus", "⇧⌘D") { [weak self] in self?.toggleCompare(nil) }
        add("mirror", mirror ? "Stop mirroring input" : "Mirror input to every device", "View", "dot.radiowaves.left.and.right", "⇧⌘M") { [weak self] in self?.toggleMirror(nil) }
        add("pane.device", showingDevice ? "Hide device controls" : "Show device controls", "Panes", "slider.horizontal.3") { [weak self] in self?.toggleDevicePane(nil) }
        add("pane.diagnostics", showingDiagnostics ? "Hide diagnostics" : "Show diagnostics", "Panes", "stethoscope", keywords: "performance fps memory cpu accessibility background clipboard skin") { [weak self] in self?.toggleDiagnostics(nil) }
        add("diagnostics.audit", "Audit accessibility", "Panes", "checklist", keywords: "a11y labels touch targets") { [weak self] in self?.auditAccessibility() }
        add("pane.network", showingNetwork ? "Hide network" : "Show network", "Panes", "arrow.up.arrow.down", keywords: "requests http") { [weak self] in self?.toggleNetwork(nil) }
        add("tests.run", "Run tests…", "Tests", "checkmark.circle", keywords: "androidtest instrument espresso") { [weak self] in self?.runTests() }
        add("pane.tests", showingTests ? "Hide tests" : "Show tests", "Panes", "checkmark.circle", keywords: "androidtest instrument espresso") { [weak self] in self?.toggleTests(nil) }
        add("pane.recordings", "Show recordings", "Recordings", "film", keywords: "replay saved bundles apkrec") { [weak self] in self?.setShowingRecordings(true) }
        add("recordings.replay", "Replay a recording…", "Recordings", "play.fill", keywords: "replay build regression") { [weak self] in self?.setShowingRecordings(true); self?.recordingsPane.promptReplay() }
        add("recordings.bisect", "Find the first build that differs…", "Recordings", "arrow.triangle.branch", keywords: "bisect replay regression builds") { [weak self] in self?.setShowingRecordings(true); self?.recordingsPane.promptBisect() }
        add("pane.timeline", showingTimeline ? "Hide timeline" : "Show timeline", "Panes", "chart.bar.xaxis") { [weak self] in self?.toggleTimeline(nil) }
        add("pane.log", showingLog ? "Hide log" : "Show log", "Panes", "text.alignleft", "⇧⌘L", keywords: "logcat") { [weak self] in self?.toggleLog(nil) }
        add("pane.inspect", inspecting ? "Stop inspecting" : "Inspect the screen", "Panes", "cursorarrow.rays", "⌥⌘I", keywords: "nodes accessibility tree") { [weak self] in self?.toggleInspector(nil) }
        add("pane.agent", "Agent activity", "Panes", "sparkles", "⌥⌘A", keywords: "claude mcp") { [weak self] in self?.showAgent(nil) }
        add("snapshots.run", "Run screenshot tests…", "Panes", "photo.stack", keywords: "golden snapshot visual regression compare") { [weak self] in self?.showSnapshots(run: true) }
        add("snapshots.show", "Show screenshot test results", "Panes", "photo.stack", keywords: "golden snapshot visual regression review") { [weak self] in self?.showSnapshots() }
        add("map.walk", "Map the app's screens…", "Map", "point.3.connected.trianglepath.dotted", keywords: "crawl explore walk graph screens") { [weak self] in self?.showMap(walk: true) }
        add("map.show", "Show the screen map", "Map", "point.3.connected.trianglepath.dotted", keywords: "crawl explore graph screens") { [weak self] in self?.showMap() }
        if let map = screenMap.data {
            for s in map.screens.prefix(30) {
                add("map.go." + s.id, "Go to " + s.label, "Map", "arrow.forward.circle", keywords: s.activity + " " + s.texts.prefix(6).joined(separator: " ")) { [weak self] in self?.goThere(s, map) }
            }
        }
        add("pane.library", "Show or hide the library", "Panes", "sidebar.left") { [weak self] in self?.toggleLibrary(nil) }
        // Recordings saved before.
        let files = (try? FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.pathExtension == "apkrec" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for f in newest.prefix(6) {
            add("recording." + f.lastPathComponent, "Open recording " + f.deletingPathExtension().lastPathComponent, "Recordings", "film", keywords: "replay trace") { [weak self] in self?.view(recording: f) }
        }
        return out
    }

    /// The network pane slides in from the right; the stage makes room as it comes. It shares the place with the
    /// device pane: opening one sends the other away.
    func setShowingNetwork(_ on: Bool) { show(on ? .network : nil, closing: .network) }
    func setShowingDevice(_ on: Bool) { show(on ? .device : nil, closing: .device) }
    func setShowingTests(_ on: Bool) { show(on ? .tests : nil, closing: .tests) }

    /// "Run tests…": the pane opens, and runs at once when both APKs are known, else asks for the test APK.
    private func runTests() {
        setShowingTests(true)
        if testsPane.testAPK == nil { testsPane.chooseTestAPK() } else { testsPane.start() }
    }

    var tests: TestsPane { testsPane }
    func setShowingDiagnostics(_ on: Bool) { show(on ? .diagnostics : nil, closing: .diagnostics) }

    /// The palette's "Audit accessibility": opens the pane if needed and runs the audit.
    func auditAccessibility() {
        if !showingDiagnostics { setShowingDiagnostics(true) }
        diagnosticsPane.audit()
    }

    var diagnostics: DiagnosticsPane { diagnosticsPane }

    /// The pane's marks, outlines and fps chips go to the device views (the view of the simulator it names).
    private func wireDiagnostics() {
        func view(_ sim: Simulator) -> SimulatorView? { grid.views.first { $0.simulator === sim } }
        diagnosticsPane.devices = { Engine.shared.simulators.filter { $0.state == .running } }
        diagnosticsPane.onMarks = { sim, boxes in view(sim)?.boxes = boxes }
        diagnosticsPane.onOutline = { [weak self] sim, rect in if self?.inspecting != true { view(sim)?.outlined = rect } }
        diagnosticsPane.onChip = { sim, text in view(sim)?.captionExtra = text ?? "" }
        diagnosticsPane.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
    }

    /// Puts `pane` in the right slot (nil: empties it, when `closing` is the one there now). The pane that leaves
    /// stops following its device, so nothing it shows keeps polling.
    func show(_ pane: RightPane?, closing: RightPane? = nil) {
        if let pane, pane != rightPane {
            switch pane {
            case .device: Reports.shared.count(.paneDevice)
            case .network: Reports.shared.count(.paneNetwork)
            case .tests: Reports.shared.count(.paneTests)
            case .diagnostics: Reports.shared.count(.paneDiagnostics)
            case .recordings: Reports.shared.count(.paneRecordings)
            }
        }
        if pane == nil, let closing, rightPane != closing { return }
        let old = rightPane
        rightPane = pane
        if old != pane, let old { activate(old, false) }
        if let pane { activate(pane, true) }
        layoutRightSlot()
    }

    private func activate(_ pane: RightPane, _ on: Bool) {
        switch pane {
        case .device: devicePane.follow(on ? selected : nil)
        case .network: networkPane.follow(on ? selected : nil)
        case .tests: testsPane.setActive(on)
        case .diagnostics: diagnosticsPane.follow(on ? selected : nil)
        case .recordings: recordingsPane.setShown(on, folder: recordings)
        }
    }

    /// Each pane of the slot: its view, the constraint that slides it, its width.
    private var slot: [(RightPane, NSView, NSLayoutConstraint, CGFloat)] {
        [(.device, devicePane, deviceLeading, Self.deviceWidth), (.network, networkPane, networkLeading, Self.networkWidth),
         (.tests, testsPane, testsLeading, Self.testsWidth), (.diagnostics, diagnosticsPane, diagnosticsLeading, Self.diagnosticsWidth),
         (.recordings, recordingsPane, recordingsLeading, Self.recordingsWidth)]
    }

    func setShowingRecordings(_ on: Bool) { show(on ? .recordings : nil, closing: .recordings) }

    private func layoutRightSlot() {
        guard let host = networkPane.superview else { return }
        let panes = slot
        for (p, view, _, _) in panes where p == rightPane { view.isHidden = false }
        let width = panes.first { $0.0 == rightPane }?.3 ?? 0
        Design.animate(Design.move, {
            for (p, _, leading, w) in panes { leading.animator().constant = p == self.rightPane ? -(w + 68) : 20 }
            self.gridTrailing.animator().constant = width > 0 ? -(width + 80) : -64
            host.layoutSubtreeIfNeeded()
        }, done: {
            for (p, view, _, _) in self.slot where p != self.rightPane { view.isHidden = true }
        })
        updateChrome()
    }

    /// The timeline docks along the bottom, under the stage.
    func setShowingTimeline(_ on: Bool) {
        if on { Reports.shared.count(.timeline) }
        showingTimeline = on
        timeline.follow(on ? selected : nil)
        timeline.setShown(on)
        if on { timeline.isHidden = false }
        Design.animate(Design.move, { self.timelineHeight.animator().constant = on ? 196 : 0 },
                       done: { if !self.showingTimeline { self.timeline.isHidden = true } })
        updateChrome()
    }

    var network: NetworkPane { networkPane }
    var timelineDock: TimelineDock { timeline }
    var recordingsView: RecordingsPane { recordingsPane }

    /// The playhead dragged to a moment, as a person would (for scripted checks).
    func debugScrub(to time: Date) { timeline.show(time); timeline.onScrub?(time) }

    /// A request picked in the network pane, as a moment on the timeline (shown if it was not), and the other way round.
    private func linkPanes() {
        networkPane.onSelect = { [weak self] e in
            guard let self else { return }
            if !self.showingTimeline { self.setShowingTimeline(true) }
            self.timeline.show(e.start)
        }
        timeline.onScrub = { [weak self] t in
            guard let self else { return }
            if !self.showingNetwork { self.setShowingNetwork(true) }
            self.networkPane.reveal(at: t)
        }
        timeline.onSave = { [weak self] in self?.saveRecordingAndShow(nil) }
        networkPane.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
        timeline.onClose = { [weak self] in self?.setShowingTimeline(false) }
    }

    /// Shows the sidebar if it is folded away.
    func showLibrary() {
        guard let item = splitController.splitViewItems.first, item.isCollapsed else { return }
        item.animator().isCollapsed = false
    }

    @objc func addRepository(_ sender: Any?) { sessions.chooseRepository() }

    @objc func toggleLibrary(_ sender: Any?) {
        guard let item = splitController.splitViewItems.first else { return }
        item.animator().isCollapsed.toggle()
    }

    @objc private func showOne(_ sender: Any?) { setSideBySide(false) }
    @objc private func showAll(_ sender: Any?) { if comparing { setComparing(false) }; setSideBySide(true) }
    @objc func shake(_ sender: Any?) { targets.forEach { $0.send("sensor shake") }; scheduleCompare() }

    @objc private func showAppMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for sim in Engine.shared.simulators {
            let item = menu.addItem(withTitle: sim.name + (sim.isAlive ? "" : " (ended)"), action: #selector(pickSimulator(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sim
            item.state = sim === selected ? .on : .off
        }
        if !Engine.shared.simulators.isEmpty { menu.addItem(.separator()) }
        let open = menu.addItem(withTitle: "Open APK…", action: Selector(("openDocument:")), keyEquivalent: "")
        open.target = nil
        if selected != nil {
            menu.addItem(withTitle: "Restart App", action: #selector(restart(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Close Simulator", action: #selector(closeSelected(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(DevHooks.shared.submenuItem(for: selected))   // Developer ▸ (DevHooks.swift)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func pickSimulator(_ sender: NSMenuItem) {
        if let sim = sender.representedObject as? Simulator { select(sim) }
    }

    @objc private func showDeviceMenu(_ sender: NSButton) {
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
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
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
        menu.addItem(withTitle: "Remove Repository from Sessions", action: #selector(removeRepositoryClicked), keyEquivalent: "").target = self
        menu.delegate = self
        table.menu = menu
        table.registerForDraggedTypes([.fileURL])   // a folder dropped here is a repository to add

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
        switch rows[row] {
        case .simulator, .session: return true
        default: return false
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard !SessionsController.folders(in: info).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)   // the whole sidebar takes it
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let folders = SessionsController.folders(in: info)
        sessions.addRepositories(folders)
        return !folders.isEmpty
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 24 }
        if case .session = rows[row] { return 42 }
        return 36
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .session(let session):
            return sessions.cell(for: session)
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
        if case .session(let session) = rows[row] { sessions.activate(session) }
    }

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        if case .recent(let url) = rows[row] { open(url) }
    }

    /// The row's context menu: a session's row gets Build, Build with and the log in front (SessionsController).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag == 77 }.forEach { menu.removeItem($0) }
        let row = table.clickedRow
        guard row >= 0, row < rows.count, case .session(let session) = rows[row] else { return }
        let items = sessions.buildMenuItems(for: session) + [.separator()]
        for (i, item) in items.enumerated() { item.tag = 77; menu.insertItem(item, at: i) }
    }

    @objc private func closeClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        if case .simulator(let sim) = rows[row] { Engine.shared.close(sim) }
        if case .session(let session) = rows[row] { sessions.closeSimulator(of: session) }
    }

    @objc private func removeRepositoryClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, case .session(let session) = rows[row] else { return }
        sessions.removeWorkspace(containing: session)
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
        Tool(id: "inspect", label: "Inspector", symbol: "scope", command: #selector(toggleInspector(_:))),
        Tool(id: "record", label: "Record", symbol: "record.circle", command: #selector(toggleRecording(_:))),
        Tool(id: "log", label: "Log", symbol: "text.alignleft", command: #selector(toggleLog(_:))),
    ]
    private static let devices = ["phone", "foldable", "pixel-10-pro-fold", "watch", "tablet", "desktop", "tv"]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["back", "rotate", "appearance", "device", "flex", "grid", "mirror", "compare", "flex", "agent", "record", "shot", "log", "inspect"].map {
            $0 == "flex" ? .flexibleSpace : NSToolbarItem.Identifier($0)
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + ["home", "restart", "close"].map { NSToolbarItem.Identifier($0) }   // also in the Device menu
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
        case "record":
            item.image = isRecording ? NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: item.label)?
                .withSymbolConfiguration(.init(paletteColors: [.systemRed])) : NSImage(systemSymbolName: "record.circle", accessibilityDescription: item.label)
            item.toolTip = isRecording ? "Recording: File > Save Recording keeps the last minutes" : "Record input, log, network and screen for replay"
            return live != nil
        case "log":
            item.image = Self.toggleImage("text.alignleft", on: showingLog, label: item.label)
            return true
        case "inspect":
            item.image = Self.toggleImage("scope", on: inspecting, label: item.label)
            item.toolTip = inspecting ? "Inspector: clicks on the chosen simulator pick nodes" : "Inspector: see the nodes on screen"
            return true
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

    static func title(_ device: String) -> String {
        switch device {
        case "tv": return "TV"
        case "pixel-10-pro-fold": return "Pixel 10 Pro Fold"
        default: return device.capitalized
        }
    }

    private var live: Simulator? { selected?.state == .running ? selected : nil }

    /// The simulators a toolbar command goes to: the chosen one, or every running one while input is mirrored.
    private var targets: [Simulator] {
        mirror ? Engine.shared.simulators.filter { $0.state == .running } : (live.map { [$0] } ?? [])
    }

    // MARK: Log and recordings

    @objc func toggleLog(_ sender: Any?) { setShowingLog(!showingLog) }

    func setShowingLog(_ on: Bool) {
        if on { Reports.shared.count(.log) }
        showingLog = on
        logPanel.isHidden = !on
        Design.animate { self.logHeight.animator().constant = on ? 210 : 0 }
        logPanel.follow(on ? selected : nil)
        window.toolbar?.validateVisibleItems()
        updateChrome()
    }

    /// The log lines shown (for scripted checks).
    var logLines: [String] { logPanel.shown }

    var isRecording: Bool { selected.map { recording.contains(ObjectIdentifier($0)) } ?? false }

    /// The flight recorder for the chosen simulator: input, log, network, database and screen for the last while,
    /// kept in the engine until saved. Recording takes checkpoints the app can notice (a brief stop and start), so
    /// it is off until asked for.
    @objc func toggleRecording(_ sender: Any?) {
        Reports.shared.count(.recording)
        guard let sim = live else { return }
        let key = ObjectIdentifier(sim)
        let on = !recording.contains(key)
        sim.send(on ? "rec on all" : "rec off all") { [weak self] answer in
            guard let self else { return }
            if answer.hasPrefix("error") { self.toast.show("Recorder: " + answer.replacingOccurrences(of: "error: ", with: ""), problem: true); return }
            if on { self.recording.insert(key) } else { self.recording.remove(key) }
            self.toast.show(on ? "Recording \(sim.name): input, log, network and screen" : "Recording stopped")
            self.updateChrome()
        }
    }

    var recordings: URL { Engine.shared.engineState.appendingPathComponent("recordings", isDirectory: true) }

    /// Saves what the recorder holds as a .apkrec bundle and shows it. `done` gets the file, or nil with the reason.
    func saveRecording(done: ((URL?, String) -> Void)? = nil) {
        guard let sim = live else { done?(nil, "no running simulator"); return }
        try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(sim.name.replacingOccurrences(of: " ", with: "-"))-\(stamp.string(from: Date())).apkrec"
        let file = recordings.appendingPathComponent(name)
        sim.send("rec save recordings/\(name)") { [weak self] answer in
            guard let self else { return }
            if answer.hasPrefix("error") {
                self.toast.show("Recording not saved: " + answer.replacingOccurrences(of: "error: ", with: ""), problem: true)
                done?(nil, answer)
                return
            }
            // The engine answers at once and writes the bundle after: wait until the file is there and has stopped growing.
            self.toast.show("Saving the recording…")
            var tries = 0, lastSize = -1
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
                tries += 1
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
                if size > 0, size == lastSize {
                    timer.invalidate()
                    self.toast.show("Saved \(name)")
                    if self.showingRecordings { self.recordingsPane.refresh(select: file) }   // recordings pane: the new file
                    done?(file, answer)
                } else if tries > 100 {
                    timer.invalidate()
                    self.toast.show("Recording not saved: the engine wrote no file", problem: true)
                    done?(nil, answer)
                }
                lastSize = size
            }
        }
    }

    @objc func saveRecordingAndShow(_ sender: Any?) {
        saveRecording { file, _ in if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
    }

    /// Opens a recording in the engine's trace viewer (a page it serves on this Mac only, in the default browser).
    func view(recording file: URL) {
        let p = Process()
        p.executableURL = Engine.shared.launcher
        p.arguments = ["rec", "view", file.path]
        var env = ProcessInfo.processInfo.environment
        env["APKSIM_HOME"] = Engine.shared.engineState.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    @objc func saveRecordingAndView(_ sender: Any?) {
        saveRecording { [weak self] file, _ in if let file { self?.view(recording: file) } }
    }

    // MARK: Inspecting

    @objc func toggleInspector(_ sender: Any?) { if !inspecting { Reports.shared.count(.inspector) }; setInspecting(!inspecting) }

    /// The inspector: the chosen simulator's nodes in a pane, picked by pointing at the picture. While it is open
    /// clicks on that picture pick instead of tapping; keys and the toolbar still reach the app.
    func setInspecting(_ on: Bool) {
        inspecting = on
        inspectorItem.animator().isCollapsed = !on
        inspectTimer?.invalidate()
        inspectTimer = on ? Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refreshInspector() } : nil
        reload()
        if on { refreshInspector() }
    }

    private var inspectorBusy = false

    private func refreshInspector() {
        guard inspecting, !inspectorBusy else { return }
        guard let sim = live else { inspector.show([], of: nil); return }
        inspectorBusy = true
        compareQueue.async {
            let nodes = ScreenNode.parse(sim.sendSync("nodes", timeout: 10))
            DispatchQueue.main.async {
                self.inspectorBusy = false
                if self.inspecting, self.selected === sim { self.inspector.show(nodes, of: sim) }
            }
        }
    }

    /// The outlined node's box on the chosen simulator (for scripted checks).
    var inspectorOutline: CGRect? { selected.flatMap { grid.view(for: $0)?.outlined } }

    /// What the inspector lists (for scripted checks).
    var inspectorNodes: [ScreenNode] { inspector.nodes }

    // MARK: Comparing

    @objc func toggleCompare(_ sender: Any?) { if !comparing { Reports.shared.count(.compare) }; setComparing(!comparing) }

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

    @objc func toggleSideBySide(_ sender: Any?) { if !sideBySide { Reports.shared.count(.sideBySide) }; setSideBySide(!sideBySide) }
    @objc func toggleMirror(_ sender: Any?) { if !mirror { Reports.shared.count(.mirror) }; setMirror(!mirror) }

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
        var options: [String] = []
        var rest = ArraySlice(keep?.options ?? [])
        while let o = rest.popFirst() { if o == "--device" { _ = rest.popFirst() } else { options.append(o) } }
        let sim = open(apk, remember: false, options: options + ["--device", device])
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
        if let anchor = railButtons["agent"] ?? window.contentView {
            agentPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
        }
        agentPanel.refresh()
    }

    func agentChanged() {
        agentPanel?.refresh()
        updateChrome()
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
    /// Side by side: tiles the devices again after they were moved or resized by hand.
    @objc func tidyUp(_ sender: Any?) { grid.tidy() }

    @objc func device(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? String else { return }
        live?.send("device \(d)")
    }

    /// Saves the app's pixels as a PNG in the state folder, copies the picture to the clipboard and shows the file.
    @objc func screenshot(_ sender: Any?) {
        Reports.shared.count(.screenshot)
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
                self?.toast.show("Screenshot failed: " + answer.replacingOccurrences(of: "error: ", with: ""), problem: true)
                return
            }
            if let image = NSImage(contentsOf: file) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            self?.toast.show("Screenshot copied, and saved as \(file.lastPathComponent)")
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
            content.topAnchor.constraint(equalTo: topAnchor),
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

/// A dark veil over the window while the palette is open; a click on it closes the palette.
final class Scrim: NSView {
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
