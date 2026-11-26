import AppKit
import UniformTypeIdentifiers

/// Runs an androidTest APK against an app with the engine and shows the results as they come: a summary and progress
/// bar, a tree of classes and tests, and for a picked failure its stack, its screenshot and its movie. Floats over the
/// stage on glass, in the right-hand slot the Device and Network panes share.
final class TestsPane: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    private let glass = GlassView(radius: 18)
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let summary = NSTextField(labelWithString: "")
    private let progress = ProgressBar()
    private let testLabel = NSTextField(labelWithString: "")
    private let appLabel = NSTextField(labelWithString: "")
    private let filter = NSTextField()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let runButton = GlassButton(symbol: "play.fill", title: "Run", label: "Run the tests", style: .accent, target: nil, action: nil)
    private let againButton = GlassButton(symbol: "arrow.counterclockwise", title: "Run failed again", label: "Run the failed tests again", style: .well, target: nil, action: nil)
    private let stopButton = GlassButton(symbol: "stop.fill", title: "Stop", label: "Stop the run", style: .record, target: nil, action: nil)
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailStatus = NSTextField(labelWithString: "")
    private let detailText = NSTextView()
    private let shot = NSImageView()
    private var shotHeight: NSLayoutConstraint!
    private let revealButton = GlassButton(symbol: "folder", title: "Reveal bundle", label: "Show the failure bundle in Finder", style: .well, target: nil, action: nil)
    private let movieButton = GlassButton(symbol: "film", title: "Open movie", label: "Open the recording of the test", style: .well, target: nil, action: nil)
    private var timer: Timer?
    private var collapsed: Set<String> = []
    private var reloading = false
    private var selected: TestRun.Test?
    private var userChoseApp = false
    private var active = false

    private(set) var run: TestRun?
    private(set) var testAPK: URL?
    private(set) var appAPK: URL?
    var classFilter: String { get { filter.stringValue } set { filter.stringValue = newValue } }
    var onSay: ((String, Bool) -> Void)?
    /// Called on the main thread when a run ends.
    var onFinish: ((TestRun) -> Void)?
    var onClose: (() -> Void)?

    private static let lastTestKey = "testsLastTestAPK"
    private static let lastFilterKey = "testsLastClassFilter"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let title = NSTextField(labelWithString: "Tests")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Design.ink
        runButton.onPress = { [weak self] in self?.start() }
        againButton.onPress = { [weak self] in self?.startFailed() }
        stopButton.onPress = { [weak self] in self?.run?.stop() }
        for b in [runButton, againButton, stopButton] { b.font = .systemFont(ofSize: 12, weight: .medium); b.heightAnchor.constraint(equalToConstant: 28).isActive = true }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let close = GlassButton(symbol: "xmark", label: "Close Tests", style: .plain, target: self, action: #selector(closePressed))
        close.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let top = NSStackView(views: [title, spacer, againButton, stopButton, runButton, close])
        top.spacing = 6

        func inputRow(_ name: String, _ label: NSTextField, _ pick: @escaping () -> Void) -> NSStackView {
            let n = NSTextField(labelWithString: name)
            n.font = .systemFont(ofSize: 12, weight: .medium)
            n.textColor = Design.mute
            n.widthAnchor.constraint(equalToConstant: 46).isActive = true
            label.font = .systemFont(ofSize: 12)
            label.textColor = Design.ink
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            label.setContentHuggingPriority(.init(1), for: .horizontal)
            let b = GlassButton(symbol: nil, title: "Choose…", label: "Choose the \(name.lowercased()) APK", style: .well, target: nil, action: nil)
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            b.onPress = pick
            let row = NSStackView(views: [n, label, b])
            row.spacing = 8
            return row
        }
        let testRow = inputRow("Tests", testLabel) { [weak self] in self?.chooseTestAPK() }
        let appRow = inputRow("App", appLabel) { [weak self] in self?.chooseAppAPK() }
        filter.placeholderString = "Only these classes: a.B, a.C (optional)"
        filter.controlSize = .small
        filter.font = .systemFont(ofSize: 12)
        filter.delegate = self
        filter.stringValue = UserDefaults.standard.string(forKey: Self.lastFilterKey) ?? ""

        summary.font = .systemFont(ofSize: 12, weight: .medium)
        summary.textColor = Design.mute
        summary.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("test"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.style = .plain
        outline.rowHeight = 26
        outline.indentationPerLevel = 16
        outline.intercellSpacing = NSSize(width: 4, height: 1)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.selectionHighlightStyle = .regular
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = Design.mute
        empty.alignment = .center
        empty.stringValue = "Pick a test APK and an app, then Run. Results show here as each test finishes; a failed test keeps its screenshot and a movie."

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0, alpha: 0.3).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Design.stroke.cgColor
        detailTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        detailTitle.textColor = Design.ink
        detailTitle.lineBreakMode = .byTruncatingMiddle
        detailTitle.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        detailStatus.font = .systemFont(ofSize: 12, weight: .semibold)
        detailText.isEditable = false
        detailText.isRichText = false
        detailText.drawsBackground = false
        detailText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailText.textColor = Design.ink
        detailText.textContainerInset = NSSize(width: 4, height: 6)
        detailText.isHorizontallyResizable = false
        detailText.autoresizingMask = [.width]
        let detailScroll = NSScrollView()
        detailScroll.documentView = detailText
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        shot.imageScaling = .scaleProportionallyUpOrDown
        shot.imageAlignment = .alignLeft
        shot.wantsLayer = true
        shot.layer?.cornerRadius = 8
        shot.layer?.cornerCurve = .continuous
        shot.layer?.masksToBounds = true
        shot.isHidden = true
        for b in [revealButton, movieButton] { b.font = .systemFont(ofSize: 12, weight: .medium); b.heightAnchor.constraint(equalToConstant: 28).isActive = true }
        revealButton.onPress = { [weak self] in
            guard let self, let t = self.selected, let dir = self.run?.bundleFolder(for: t) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
        movieButton.onPress = { [weak self] in
            guard let self, let t = self.selected, let f = self.run?.movieFile(for: t) else { return }
            NSWorkspace.shared.open(f)
        }
        let detailHead = NSStackView(views: [detailTitle, detailStatus])
        detailHead.spacing = 8
        let actions = NSStackView(views: [revealButton, movieButton])
        actions.spacing = 6
        for v in [detailHead, detailScroll, shot, actions] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(v) }
        shotHeight = shot.heightAnchor.constraint(equalToConstant: 0)

        for v in [top, testRow, appRow, filter, summary, progress, scroll, empty, card] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            testRow.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            testRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            testRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            appRow.topAnchor.constraint(equalTo: testRow.bottomAnchor, constant: 6),
            appRow.leadingAnchor.constraint(equalTo: testRow.leadingAnchor),
            appRow.trailingAnchor.constraint(equalTo: testRow.trailingAnchor),
            filter.topAnchor.constraint(equalTo: appRow.bottomAnchor, constant: 8),
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            summary.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 12),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progress.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 6),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progress.heightAnchor.constraint(equalToConstant: 5),
            scroll.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.36),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            card.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            detailHead.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            detailHead.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            detailHead.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            detailScroll.topAnchor.constraint(equalTo: detailHead.bottomAnchor, constant: 8),
            detailScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            detailScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            detailScroll.bottomAnchor.constraint(equalTo: shot.topAnchor, constant: -8),
            shot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            shot.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -14),
            shot.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            shotHeight,
            actions.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            actions.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])

        if let p = UserDefaults.standard.string(forKey: Self.lastTestKey), FileManager.default.fileExists(atPath: p) { testAPK = URL(fileURLWithPath: p) }
        refreshInputs()
        refreshAll()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Inputs

    /// The selected simulator's APK is the app to test, until one is chosen by hand.
    func follow(_ sim: Simulator?) {
        guard !userChoseApp, run?.isRunning != true else { return }
        appAPK = sim?.apk
        refreshInputs()
    }

    /// Shown or hidden: a running run's clock ticks only while it can be seen.
    func setActive(_ on: Bool) {
        active = on
        updateTimer()
        if on { refreshAll() }
    }

    func setInputs(test: URL?, app: URL?, filter f: String? = nil) {
        if let test { testAPK = test; UserDefaults.standard.set(test.path, forKey: Self.lastTestKey) }
        if let app { appAPK = app; userChoseApp = true }
        if let f { filter.stringValue = f }
        refreshInputs()
    }

    private func refreshInputs() {
        testLabel.stringValue = testAPK?.lastPathComponent ?? "Not chosen"
        testLabel.toolTip = testAPK?.path
        appLabel.stringValue = appAPK?.lastPathComponent ?? "Open an app, or choose one"
        appLabel.toolTip = appAPK?.path
        refreshButtons()
    }

    private func choose(_ message: String, _ then: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = [UTType(filenameExtension: "apk")].compactMap { $0 }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let w = window { panel.beginSheetModal(for: w) { if $0 == .OK, let u = panel.url { then(u) } } }
        else if panel.runModal() == .OK, let u = panel.url { then(u) }
    }

    func chooseTestAPK() { choose("Choose the androidTest APK") { [weak self] in self?.setInputs(test: $0, app: nil) } }
    func chooseAppAPK() { choose("Choose the app the tests run against") { [weak self] in self?.setInputs(test: nil, app: $0) } }

    // MARK: Running

    @discardableResult
    func start() -> Bool { begin(selectors: []) }

    private func startFailed() {
        guard let r = run, !r.failedSelectors.isEmpty else { return }
        begin(selectors: r.failedSelectors)
    }

    @discardableResult
    private func begin(selectors: [String]) -> Bool {
        guard run?.isRunning != true else { return false }
        guard let t = testAPK else { onSay?("Choose the test APK first", true); return false }
        guard let a = appAPK else { onSay?("Open an app, or choose one to test", true); return false }
        UserDefaults.standard.set(filter.stringValue, forKey: Self.lastFilterKey)
        let r = TestRun(config: .init(testAPK: t, appAPK: a, classFilter: filter.stringValue, selectors: selectors))
        r.onChange = { [weak self, weak r] in
            guard let self, let r, r === self.run else { return }
            self.changed(r)
        }
        do { try r.start() } catch {
            onSay?("The tests could not start: \(error.localizedDescription)", true)
            return false
        }
        run = r
        selected = nil
        collapsed = []
        refreshAll()
        updateTimer()
        return true
    }

    private func changed(_ r: TestRun) {
        refreshAll()
        if !r.isRunning {
            updateTimer()
            onFinish?(r)
        }
    }

    /// While a run is going and the pane is on screen, the elapsed time moves once a second; otherwise nothing ticks.
    private func updateTimer() {
        let want = active && run?.isRunning == true
        if want, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshSummary() }
        } else if !want { timer?.invalidate(); timer = nil }
    }

    // MARK: Showing the run

    private func refreshAll() {
        refreshSummary()
        refreshButtons()
        reloadTree()
        empty.isHidden = run != nil
        showDetail()
    }

    private static func time(_ s: TimeInterval) -> String { s < 10 ? String(format: "%.1f s", s) : s < 100 ? String(format: "%.0f s", s) : String(format: "%d min %02d s", Int(s) / 60, Int(s) % 60) }

    private func refreshSummary() {
        guard let r = run else { summary.stringValue = ""; progress.set(0, tint: Design.accent); return }
        var parts: [String] = []
        if r.passed > 0 || r.failed == 0 && r.ignored == 0 { parts.append("\(r.passed) passed") }
        if r.failed > 0 { parts.append("\(r.failed) failed") }
        if r.ignored > 0 { parts.append("\(r.ignored) ignored") }
        var text = parts.joined(separator: " · ")
        switch r.state {
        case .running:
            text = r.allTests.isEmpty ? "Starting the engine…" : text + (r.expected > 0 ? " · \(r.done) of \(r.expected)" : "")
            text += " · " + Self.time(r.elapsed)
            summary.textColor = Design.mute
        case .finished(let exit, let stopped):
            text += " · " + Self.time(r.elapsed)
            if stopped { text += " · stopped" } else if r.allTests.isEmpty { text = "No tests ran (exit \(exit))" }
            summary.textColor = r.failed > 0 ? Design.record : (r.allTests.isEmpty ? Design.warning : Design.accent)
        case .idle: break
        }
        summary.stringValue = text
        let total = max(r.expected, r.allTests.count, 1)
        let fraction: Double
        if case .finished = r.state, !r.allTests.isEmpty { fraction = 1 } else { fraction = Double(r.done) / Double(total) }
        progress.set(fraction, tint: r.failed > 0 ? Design.record : Design.accent, indeterminate: r.isRunning && r.allTests.isEmpty)
    }

    private func refreshButtons() {
        let running = run?.isRunning == true
        runButton.isEnabled = !running && testAPK != nil && appAPK != nil
        againButton.isEnabled = !running && !(run?.failedSelectors.isEmpty ?? true)
        stopButton.isEnabled = running
        againButton.isHidden = run == nil
    }

    private func reloadTree() {
        guard let r = run else { outline.reloadData(); return }
        let keep = selected?.id
        reloading = true
        outline.reloadData()
        for c in r.classes where !collapsed.contains(c.name) { outline.expandItem(c) }
        reloading = false
        if let keep, let t = r.allTests.first(where: { $0.id == keep }) {
            let row = outline.row(forItem: t)
            if row >= 0 { reloading = true; outline.selectRowIndexes([row], byExtendingSelection: false); reloading = false }
        } else if r.isRunning, outline.numberOfRows > 0, selected == nil, outline.selectedRow < 0 {
            // Follow the newest result while nothing is picked.
            outline.scrollRowToVisible(outline.numberOfRows - 1)
        }
    }

    /// Picks a test (for a scripted check or a link from elsewhere).
    func select(_ id: String) {
        guard let t = run?.allTests.first(where: { $0.id == id }) else { return }
        selected = t
        let row = outline.row(forItem: t)
        if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false); outline.scrollRowToVisible(row) }
        showDetail()
    }

    private func showDetail() {
        guard let t = selected, let r = run else {
            detailTitle.stringValue = "Select a test"
            detailStatus.stringValue = ""
            detailText.string = run == nil ? "" : "A failed test shows its stack here, with its screenshot and movie."
            setShot(nil)
            revealButton.isEnabled = false
            movieButton.isEnabled = false
            return
        }
        detailTitle.stringValue = t.cls.split(separator: ".").last.map(String.init).map { $0 + "." + t.method } ?? t.method
        detailTitle.toolTip = t.id
        let (word, color) = Self.describe(t.status)
        detailStatus.stringValue = word + (t.ms.map { " · \($0) ms" } ?? "")
        detailStatus.textColor = color
        switch t.status {
        case .running: detailText.string = "Running…"
        case .passed: detailText.string = "Passed."
        case .ignored: detailText.string = t.stack.isEmpty ? "Ignored." : t.stack
        default: detailText.string = t.stack.isEmpty ? "No stack was reported." : t.stack
        }
        detailText.scrollToBeginningOfDocument(nil)
        let folder = t.status == .failed ? r.bundleFolder(for: t) : nil
        setShot(folder.flatMap { NSImage(contentsOf: $0.appendingPathComponent("screen.png")) })
        revealButton.isEnabled = folder != nil
        movieButton.isEnabled = t.status == .failed && r.movieFile(for: t) != nil
    }

    private func setShot(_ image: NSImage?) {
        shot.image = image
        shot.isHidden = image == nil
        shotHeight.constant = image == nil ? 0 : 170
    }

    private static func describe(_ s: TestRun.Status) -> (String, NSColor) {
        switch s {
        case .running: return ("Running", Design.ink)
        case .passed: return ("Passed", Design.accent)
        case .failed: return ("Failed", Design.record)
        case .ignored: return ("Ignored", Design.mute)
        case .assumption: return ("Skipped (assumption)", Design.warning)
        }
    }

    fileprivate static func icon(_ s: TestRun.Status) -> (String, NSColor) {
        switch s {
        case .running: return ("arrow.triangle.2.circlepath", Design.ink)
        case .passed: return ("checkmark.circle.fill", Design.accent)
        case .failed: return ("xmark.circle.fill", Design.record)
        case .ignored: return ("minus.circle", Design.mute)
        case .assumption: return ("exclamationmark.circle", Design.warning)
        }
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let r = run else { return 0 }
        if item == nil { return r.classes.count }
        return (item as? TestRun.ClassNode)?.tests.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let c = item as? TestRun.ClassNode { return c.tests[index] }
        return run!.classes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is TestRun.ClassNode }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? TestCell) ?? TestCell()
        cell.identifier = id
        if let c = item as? TestRun.ClassNode {
            let ms = c.tests.reduce(0) { $0 + ($1.ms ?? 0) }
            let failed = c.tests.filter { $0.status == .failed }.count
            cell.set(status: c.status, name: c.shortName, trailing: failed > 0 ? "\(failed) of \(c.tests.count) failed" : "\(c.tests.count) · \(ms) ms", bold: true, tip: c.name)
        } else if let t = item as? TestRun.Test {
            cell.set(status: t.status, name: t.method, trailing: t.ms.map { "\($0) ms" } ?? "", bold: false, tip: t.id)
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        selected = outline.item(atRow: outline.selectedRow) as? TestRun.Test
        showDetail()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !reloading, let c = notification.userInfo?["NSObject"] as? TestRun.ClassNode { collapsed.insert(c.name) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if !reloading, let c = notification.userInfo?["NSObject"] as? TestRun.ClassNode { collapsed.remove(c.name) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        UserDefaults.standard.set(filter.stringValue, forKey: Self.lastFilterKey)
    }

    @objc private func closePressed() { onClose?() }
}

/// One row of the tree: a status icon, the name, and a muted time or count on the right.
private final class TestCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        name.setContentHuggingPriority(.init(1), for: .horizontal)
        trailing.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        trailing.textColor = Design.mute
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, name, trailing])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(status: TestRun.Status, name n: String, trailing t: String, bold: Bool, tip: String) {
        let (symbol, color) = TestsPane.icon(status)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.contentTintColor = color
        name.stringValue = n
        name.font = .systemFont(ofSize: 12, weight: bold ? .semibold : .regular)
        name.textColor = Design.ink
        trailing.stringValue = t
        toolTip = tip
    }
}

/// A thin bar: filled to a fraction, red once anything failed; a sweeping stripe while nothing has been reported yet.
private final class ProgressBar: NSView {
    private let fill = CALayer()
    private var fraction = 0.0
    private var sweeping = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Design.well.cgColor
        layer?.cornerRadius = 2.5
        layer?.masksToBounds = true
        fill.cornerRadius = 2.5
        fill.backgroundColor = Design.accent.cgColor
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ f: Double, tint: NSColor, indeterminate: Bool = false) {
        fraction = min(max(f, 0), 1)
        fill.backgroundColor = tint.cgColor
        setSweep(indeterminate)
        if !indeterminate { place(animated: true) }
    }

    override func layout() { super.layout(); if !sweeping { place(animated: false) } }

    private func place(animated: Bool) {
        CATransaction.begin()
        if animated, !Design.reduceMotion { CATransaction.setAnimationDuration(Design.arrive) } else { CATransaction.setDisableActions(true) }
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
        CATransaction.commit()
    }

    private func setSweep(_ on: Bool) {
        guard on != sweeping else { return }
        sweeping = on
        fill.removeAllAnimations()
        guard on, !Design.reduceMotion else { if on { fill.frame = bounds; fill.opacity = 0.4 } else { fill.opacity = 1 }; return }
        fill.opacity = 1
        fill.frame = CGRect(x: 0, y: 0, width: max(bounds.width * 0.2, 20), height: bounds.height)
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -fill.bounds.width / 2
        a.toValue = bounds.width + fill.bounds.width / 2
        a.duration = 1.4
        a.repeatCount = .infinity
        fill.add(a, forKey: "sweep")
    }
}
