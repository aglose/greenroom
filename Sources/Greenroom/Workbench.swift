import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// The main window: running simulators and recent APKs in a sidebar, the selected simulator beside it,
/// device controls in the toolbar. An APK dropped anywhere on the window opens.
final class Workbench: NSObject, NSWindowDelegate, NSToolbarDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
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
    private var inspectTimer: Timer?
    /// The unified bottom dock (Log, Timeline, Compare) and flight recorder state.
    private let logPanel = LogPanel(frame: .zero)
    private lazy var bottomDock = BottomDock(logPanel: logPanel, timeline: timeline)
    private var bottomDockHeight: NSLayoutConstraint!
    private var bottomDockSavedHeight: CGFloat = 216
    private(set) var showingBottomDock = false
    var showingLog: Bool { showingBottomDock && bottomDock.activeTab == .log }
    var showingTimeline: Bool { showingBottomDock && bottomDock.activeTab == .timeline }
    private var logErrorCount = 0
    private var networkRuleCount = 0
    private var recording = Set<ObjectIdentifier>()
    private var recordingStarted: [ObjectIdentifier: Date] = [:]
    private var recordTimer: Timer?
    private let compareQueue = DispatchQueue(label: "greenroom-compare")
    private var compareScheduled = false
    private var compareTimer: Timer?
    /// What agents have done here, and the persistent right-drawer panel that shows it.
    let agentActivity = AgentActivity()
    var agentTools: AgentTools? {
        didSet {
            let panel = agentTools.map {
                AgentPanel(activity: agentActivity, tools: $0, selected: { [weak self] in
                    self?.selected.flatMap { self?.sessions.session(forSimulator: $0) }.map { ($0.worktree.path, $0.branch ?? $0.shortHead) }
                })
            }
            panel?.onClose = { [weak self] in self?.show(nil, closing: .agent) }
            panel?.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
            agentPanel = panel
            mountAgentPanel()
        }
    }
    private var agentPanel: AgentPanel?
    private let agentHost = NSView()
    private let status = NSTextField(wrappingLabelWithString: "")
    // The floating chrome: a glass bar along the top, a badged rail on the right, override pills & Agent HUD on stage.
    private let header = GlassView()
    private var headerBar: NSStackView?
    private var sidebarCollapseObserver: NSKeyValueObservation?
    private let rail = GlassView()
    private let overrideBar = NSStackView()
    private let agentHud = GlassView(radius: 18)
    private let agentHudDot = NSView()
    private let agentHudLabel = NSTextField(labelWithString: "")
    private var agentHudPause: GlassButton!
    private var appChip: GlassButton!
    private var deviceButton: GlassButton!
    private var deviceButtons: [GlassButton] = []
    private var exitMatrixButton: GlassButton!
    private var mirrorButton: GlassButton!
    private var layoutButtons: [GlassButton] = []
    private var recordButton: GlassButton!
    private var saveRecordButton: GlassButton!
    private var railButtons: [String: GlassButton] = [:]
    private var railBadges: [String: NSTextField] = [:]
    private var railDots: [String: NSView] = [:]
    private var splitController: NSSplitViewController!
    // The network pane (right, over the stage) and the timeline dock (hosted in BottomDock).
    private let networkPane = NetworkPane(frame: .zero)
    private let timeline = TimelineDock(frame: .zero)
    private var gridTrailing: NSLayoutConstraint!
    private var networkLeading: NSLayoutConstraint!
    /// The right-hand slot holds one glass drawer at a time; opening one sends the one there away.
    enum RightPane { case device, inspector, network, tests, diagnostics, recordings, agent }
    private(set) var rightPane: RightPane?
    var showingNetwork: Bool { rightPane == .network }
    var showingDevice: Bool { rightPane == .device }
    var showingTests: Bool { rightPane == .tests }
    var showingDiagnostics: Bool { rightPane == .diagnostics }
    var showingRecordings: Bool { rightPane == .recordings }
    var showingAgent: Bool { rightPane == .agent }
    private var inspectorLeading: NSLayoutConstraint!
    private static let inspectorWidth: CGFloat = 340
    private var agentLeading: NSLayoutConstraint!
    private static let agentWidth: CGFloat = 360
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
    /// The running walk in the top bar, while the map is closed as well as open.
    let walkChip = WalkProgressChip()
    // Changes (ChangesSheet.swift): a build against a base, a full-stage sheet as well.
    let changesSheet = ChangesSheet(frame: .zero)
    private(set) var showingPalette = false
    private static let networkWidth: CGFloat = 600
    private var rows: [Row] = []
    /// What each row showed when it was drawn (`key(of:)`): a reload redraws only the rows whose key moved.
    private var rowKeys: [String] = []
    private var sidebarPending = false
    private(set) var selected: Simulator?
    /// The Sessions section of the sidebar (SessionsController.swift).
    let sessions = SessionsController()

    private enum Row {
        case header(String)
        /// A repository's header, with its + menu; `hidden` is how many of its worktrees the menu holds.
        case sessionsHeader(String, URL, hidden: Int)
        /// "Add a session" under a repository that shows none.
        case addSession(URL, hidden: Int)
        case suggestion(Session)
        /// The repository's main, kept built by itself (MainBuild.swift).
        case main(MainRow)
        case session(Session)
        case pull(PullRow)
        case simulator(Simulator)
        case recent(URL)
        case claudeOffer(ClaudeOffer)
        case claudeTitles
    }

    private static let hint = ""

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = Variant.name
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        Variant.addBadge(to: window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Design.stage

        let split = NSSplitViewController()
        splitController = split
        let side = NSSplitViewItem(sidebarWithViewController: sidebarController())
        side.minimumThickness = 200
        side.maximumThickness = 320
        side.isCollapsed = UserDefaults.standard.bool(forKey: Self.sidebarHiddenKey)   // open until the person folds it away
        split.addSplitViewItem(side)
        sidebarCollapseObserver = side.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateHeaderInset() }
        }
        let content = NSViewController()
        let stack = StageBackground()
        for v in [grid, emptyStage, overrideBar, agentHud, bottomDock, toast] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; stack.addSubview(v) }
        emptyStage.onOpen = { [weak self] in self?.open($0) }
        emptyStage.onAddRepo = { [weak self] in self?.addRepository(nil) }
        DevHooks.shared.install(workbench: self, in: stack, over: grid)   // developer hooks (DevHooks.swift)
        emptyStage.onChoose = { NSApp.sendAction(Selector(("openDocument:")), to: nil, from: nil) }
        emptyStage.onFolder = { [weak self] in self?.sessions.chooseProjectToRun() }
        emptyStage.onClone = { [weak self] in self?.sessions.askToClone() }
        bottomDock.isHidden = true
        bottomDockHeight = bottomDock.heightAnchor.constraint(equalToConstant: 0)
        gridTrailing = grid.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -68)

        overrideBar.orientation = .horizontal
        overrideBar.spacing = 6
        overrideBar.alignment = .centerY
        overrideBar.isHidden = true

        buildAgentHud()
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: stack.topAnchor, constant: Design.barHeight + 8),
            grid.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            gridTrailing,
            grid.bottomAnchor.constraint(equalTo: bottomDock.topAnchor, constant: -6),
            emptyStage.topAnchor.constraint(equalTo: grid.topAnchor),
            emptyStage.bottomAnchor.constraint(equalTo: grid.bottomAnchor),
            emptyStage.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            emptyStage.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            overrideBar.trailingAnchor.constraint(equalTo: grid.trailingAnchor, constant: -14),
            overrideBar.topAnchor.constraint(equalTo: grid.topAnchor, constant: 12),
            agentHud.leadingAnchor.constraint(equalTo: grid.leadingAnchor, constant: 14),
            agentHud.topAnchor.constraint(equalTo: grid.topAnchor, constant: 12),
            agentHud.trailingAnchor.constraint(lessThanOrEqualTo: grid.trailingAnchor, constant: -14),
            toast.trailingAnchor.constraint(equalTo: grid.trailingAnchor, constant: -14),
            toast.bottomAnchor.constraint(equalTo: bottomDock.topAnchor, constant: -12),
            bottomDock.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Design.margin),
            bottomDock.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            bottomDock.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: -Design.margin),
            bottomDockHeight,
        ])
        let drop = DropTarget(content: stack) { [weak self] in self?.open($0) }
        content.view = drop
        buildChrome(in: drop)
        linkPanes()
        grid.onClose = { Engine.shared.close($0) }
        memoryMeter.onReading = { [weak self] in self?.grid.memoryLabel.show($0) }
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 520
        split.addSplitViewItem(contentItem)
        inspector.onPick = { [weak self] node in
            guard let self, let sim = self.selected else { return }
            self.grid.view(for: sim)?.outlined = node?.frame
        }
        inspector.onClose = { [weak self] in self?.setInspecting(false) }
        inspector.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
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
        sessions.onChange = { [weak self] in self?.setNeedsSidebar() }   // the rows only: the stage did not change
        sessions.install(workbench: self)
        let quick = QuickSignIn(workbench: self)
        quickSignIn = quick
        ScriptWindow.onOffersChanged = { [weak quick] in quick?.refresh() }
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        newFrame
    }

    /// The "Sign in with…" button on a device whose screen a script signed in from before (SignInOffers).
    private var quickSignIn: QuickSignIn?

    // MARK: Opening and selecting

    @discardableResult
    func open(_ apk: URL, remember: Bool = true, options: [String] = [], fromAgent: Bool = false) -> Simulator? {
        Reports.shared.count(.apkOpened)
        do {
            // Plain launches keep their app data per device (DeviceData); a session's, or any naming a slot, keep theirs.
            let engine = Engine.shared
            let others = engine.simulators.filter(\.isAlive) + engine.closing
            let slotted = DeviceData.options(for: apk, options, others: others, root: engine.engineState.appendingPathComponent("cache/data", isDirectory: true))
            let sim = try engine.open(apk: apk, options: slotted)
            if sim.displayLabel == nil, let label = storedBuildLabel(for: apk) { sim.displayLabel = label }
            if remember {
                Recents.add(apk)
                NSDocumentController.shared.noteNewRecentDocumentURL(apk)
            }
            sim.onState = { [weak self, weak sim] state in
                guard let self, let sim else { return }
                switch state {
                case .starting: break
                case .running: self.grid.view(for: sim)?.setMessage("")
                case .ended(let code):
                    self.grid.view(for: sim)?.setMessage(Self.ended(sim, code))
                    DeviceData.release(sim)   // a clone or fresh slot goes once nothing uses it
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

    /// Readable label for a stored build APK (`builds/<key>/app.apk`), so loose simulators and recents never just say "app".
    private func storedBuildLabel(for apk: URL) -> String? {
        let buildsDir = sessions.store.builds.standardizedFileURL.path + "/"
        let path = apk.standardizedFileURL.path
        guard path.hasPrefix(buildsDir) else { return nil }
        guard let key = path.dropFirst(buildsDir.count).split(separator: "/").first.map(String.init), !key.isEmpty else { return nil }
        if let b = sessions.store.build(key) {
            let lead = b.ref.flatMap { $0.isEmpty ? nil : $0 } ?? "build"
            let short = b.sha.flatMap { $0.isEmpty ? nil : String($0.prefix(7)) } ?? String(b.key.prefix(8))
            return "\(lead) · \(short)"
        }
        return "build \(String(key.prefix(8)))"
    }

    /// Redraws every simulator's caption, top bar chip, and sidebar after a displayLabel changes.
    func refreshCaptions() {
        for v in grid.views { v.updateCaption() }
        if let sim = selected { window.subtitle = sim.effectiveLabel }
        updateChrome()
        setNeedsSidebar()
    }

    func select(_ sim: Simulator?) {
        selected = sim
        window.subtitle = sim?.effectiveLabel ?? ""
        sessions.selected(sim)
        noteLastOpened(sim)
        reload()
        if let sim, let v = grid.view(for: sim) { window.makeFirstResponder(v) }
    }

    /// Remembers what was chosen, for "Reopen what was open last" (LastOpened.swift): its session, else its APK.
    private func noteLastOpened(_ sim: Simulator?) {
        guard let sim else { return }
        sessions.reopenWhenListed = nil   // something else was chosen first: it is not to be replaced
        if let s = sessions.session(forSimulator: sim) { LastOpened.note(.session(worktree: s.worktree.path)) }
        else { LastOpened.note(.apk(path: sim.apk.path)) }
    }

    /// At launch, with "Reopen what was open last" on: opens the APK again, or the session once Sessions lists it.
    func reopenLast() {
        switch LastOpened.stored {
        case .apk(let path)?:
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { open(url) }
        case .session(let worktree)?:
            sessions.reopenWhenListed = worktree
        case nil: break
        }
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
                self.noteLastOpened(sim)
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
        reloadSidebar()
        window.toolbar?.validateVisibleItems()
        updateChrome()
    }

    /// Asks for the rows to be worked out again, once, at the end of this turn of the run loop: a build line, a
    /// walk's progress and a Claude session's write arriving together make one redraw, not three.
    private func setNeedsSidebar() {
        guard !sidebarPending else { return }
        sidebarPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sidebarPending else { return }
            self.reloadSidebar()
        }
    }

    private static let recentLimit = 3

    /// The sidebar's rows: each repository's sessions (the ones the person added, and any in use), what is worth
    /// adding, pull requests to review, simulators of no session, and recent APKs. Only rows whose key changed are
    /// redrawn.
    private func reloadSidebar() {
        sidebarPending = false
        let sims = Engine.shared.simulators
        // Built aside and swapped in at once: groups() can run the run loop (Git.available waits for xcode-select), and
        // the table laying out there would read rows it was never told about.
        var rows: [Row] = []
        let groups = sessions.groups()
        if !groups.isEmpty && ClaudeUI.offersTitles { rows.append(.claudeTitles) }   // rows read as branches, and nothing is suggested, until it is on
        for group in groups {
            guard let ws = group.workspace else { rows.append(.header(group.header)); continue }
            rows.append(.sessionsHeader(group.header, ws, hidden: group.hidden))
            let main = sessions.mainRow(for: ws)
            if let main { rows.append(.main(main)) }
            if group.sessions.isEmpty && main == nil { rows.append(.addSession(ws, hidden: group.hidden)) }
            rows += group.sessions.map { .session($0) }
        }
        let suggested = sessions.suggestions()
        let offers = ClaudeSessions.shared.offers
        if !suggested.isEmpty || !offers.isEmpty {
            rows.append(.header("Suggested"))
            rows += suggested.prefix(4).map { .suggestion($0) }   // the rest are in the + menu
            rows += offers.prefix(2).map { .claudeOffer($0) }   // W1
        }
        let pullRows = sessions.pullRows()
        if !pullRows.isEmpty {
            rows.append(.header("Review"))
            rows += pullRows.map { .pull($0) }
        }
        let loose = sims.filter { sessions.session(forSimulator: $0) == nil && !sessions.pulls.owns($0) && !sessions.mainBuilds.owns($0) }   // a session's, main's or pull request's own is on its row
        if !loose.isEmpty {
            rows.append(.header("Running"))
            rows += loose.map { .simulator($0) }
        }
        // With sessions in the sidebar, the recent APKs are a short list (all of them are in File > Open Recent).
        let recents = groups.isEmpty ? Recents.all : Array(Recents.all.prefix(Self.recentLimit))
        if !recents.isEmpty {
            rows.append(.header("Recent"))
            rows += recents.map { .recent($0) }
        }
        let keys = rows.map(key(of:))
        let sameShape = keys.count == rowKeys.count && zip(rows, self.rows).allSatisfy { Self.identity($0) == Self.identity($1) }
        let changed = IndexSet(keys.indices.filter { !sameShape || keys[$0] != rowKeys[$0] })
        self.rows = rows
        self.rowKeys = keys
        if !sameShape { table.reloadData() }
        else if !changed.isEmpty {
            table.reloadData(forRowIndexes: changed, columnIndexes: [0])
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
        }
        let selected = self.selected
        let want = selected.flatMap { s in rows.firstIndex(where: {
            if case .session(let x) = $0 { return x.simulator === s }
            if case .main(let x) = $0 { return x.simulator === s }
            if case .pull(let x) = $0 { return x.simulator === s }
            return false
        }) ?? rows.firstIndex(where: { if case .simulator(let x) = $0 { return x === s }; return false }) }
        if let want, table.selectedRow != want { table.selectRowIndexes([want], byExtendingSelection: false) }
        let alive = sims.filter(\.isAlive).count
        let notes = [ClaudeSessions.shared.note, groups.isEmpty ? nil : T3Sessions.shared.note].compactMap { $0 }
        status.stringValue = "\(alive == 0 ? "No simulators" : alive == 1 ? "1 simulator" : "\(alive) simulators") · engine \(Engine.shared.version)\nYour APKs stay on this Mac" + notes.map { "\n" + $0 }.joined()
    }

    /// Which thing a row stands for (not how it looks): rows that keep their identities in place are redrawn one by one.
    private static func identity(_ row: Row) -> String {
        switch row {
        case .header(let t): return "h:" + t
        case .sessionsHeader(let t, let ws, _): return "sh:" + t + ws.path
        case .addSession(let ws, _): return "add:" + ws.path
        case .suggestion(let s): return "sg:" + s.worktree.path
        case .main(let m): return "m:" + m.workspace.path
        case .session(let s): return "s:" + s.worktree.path
        case .pull(let p): return "p:" + p.pull.id
        case .simulator(let sim): return "sim:" + String(UInt(bitPattern: ObjectIdentifier(sim).hashValue))
        case .recent(let u): return "r:" + u.path
        case .claudeOffer(let o): return "o:" + o.repository.path
        case .claudeTitles: return "titles"
        }
    }

    /// Everything a row shows.
    private func key(of row: Row) -> String {
        switch row {
        case .sessionsHeader(_, _, let hidden): return Self.identity(row) + "|\(hidden)"
        case .addSession(_, let hidden): return Self.identity(row) + "|\(hidden)"
        case .session(let s): return Self.identity(row) + "|" + sessions.rowKey(for: s)
        case .suggestion(let s): return Self.identity(row) + "|" + sessions.suggestionKey(for: s)
        case .main(let m): return Self.identity(row) + "|" + sessions.mainRowKey(m)
        case .pull(let p): return Self.identity(row) + "|\(p.state)|\(p.build?.key ?? "")|\(p.simulator?.state == .running)|\(p.simulator != nil)|\(p.pull.title)|\(p.repo)"
        case .simulator(let sim): return Self.identity(row) + "|\(sim.state)|\(sim.deviceSize)|\(sim.effectiveLabel)"
        case .claudeOffer(let o): return Self.identity(row) + "|\(o.count)"
        default: return Self.identity(row)
        }
    }

    // MARK: Floating chrome

    private func buildAgentHud() {
        agentHud.isHidden = true
        agentHudDot.wantsLayer = true
        agentHudDot.layer?.cornerRadius = 4
        agentHudDot.layer?.backgroundColor = Design.agent.cgColor
        agentHudDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        agentHudDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        agentHudLabel.font = .systemFont(ofSize: 12, weight: .medium)
        agentHudLabel.textColor = Design.ink
        agentHudLabel.maximumNumberOfLines = 1
        agentHudLabel.lineBreakMode = .byTruncatingTail
        agentHudLabel.cell?.usesSingleLineMode = true
        agentHudLabel.cell?.truncatesLastVisibleLine = true
        agentHudLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        agentHudLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        agentHudPause = GlassButton(symbol: nil, title: "Pause", label: "Pause or resume the agent", style: .well, target: self, action: #selector(toggleAgentPause(_:)))
        agentHudPause.font = .systemFont(ofSize: 11, weight: .semibold)
        agentHudPause.layer?.cornerRadius = 12
        agentHudPause.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let row = NSStackView(views: [agentHudDot, agentHudLabel, agentHudPause])
        row.spacing = 10
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        agentHud.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: agentHud.topAnchor), row.bottomAnchor.constraint(equalTo: agentHud.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: agentHud.leadingAnchor), row.trailingAnchor.constraint(equalTo: agentHud.trailingAnchor),
        ])
    }

    @objc private func toggleAgentPause(_ sender: Any?) {
        guard let tools = agentTools else { return }
        tools.paused.toggle()
        agentPanel?.refresh()
        updateAgentHud()
    }

    private func updateAgentHud() {
        guard let client = agentActivity.client else { agentHud.isHidden = true; return }
        agentHud.isHidden = false
        let paused = agentTools?.paused ?? false
        agentHudDot.layer?.backgroundColor = (paused ? Design.warning : Design.agent).cgColor
        let latest = agentActivity.entries(session: nil, all: true).last
        let action: String
        if paused {
            action = "Paused"
        } else if let latest {
            let summary = latest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.isEmpty {
                action = latest.tool
            } else if summary.lowercased() == latest.tool.lowercased()
                        || summary.lowercased().hasPrefix(latest.tool.lowercased() + " ") {
                action = summary
            } else {
                action = "\(latest.tool) \(summary)"
            }
        } else {
            action = "Connected"
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(
            string: client + "  ",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Design.ink, .paragraphStyle: paragraph]
        )
        text.append(NSAttributedString(
            string: action,
            attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Design.mute, .paragraphStyle: paragraph]
        ))
        agentHudLabel.attributedStringValue = text
        agentHud.toolTip = "\(client) — \(action)"
        agentHudPause.title = paused ? "Resume" : "Pause"
        agentHudPause.isOn = paused
    }

    private func mountAgentPanel() {
        agentHost.subviews.forEach { $0.removeFromSuperview() }
        guard let v = agentPanel?.view else { return }
        v.translatesAutoresizingMaskIntoConstraints = false
        agentHost.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: agentHost.topAnchor), v.bottomAnchor.constraint(equalTo: agentHost.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: agentHost.leadingAnchor), v.trailingAnchor.constraint(equalTo: agentHost.trailingAnchor),
        ])
    }

    /// An edge of a full-stage sheet that gives way to the window: a sheet that needs more room than a narrow window
    /// has is clipped, and never holds the window wider than a person drags it (hidden ones included).
    private static func giving(_ c: NSLayoutConstraint) -> NSLayoutConstraint {
        c.priority = .dragThatCannotResizeWindow
        return c
    }

    private func buildChrome(in host: NSView) {
        appChip = GlassButton(symbol: nil, title: "Open an APK", label: "Running apps", style: .well, target: self, action: #selector(showAppMenu(_:)))
        deviceButton = GlassButton(symbol: "iphone", title: "Phone", label: "Switch the device while the app runs", style: .plain, target: self, action: #selector(showDeviceMenu(_:)))
        deviceButtons = [
            GlassButton(symbol: "chevron.backward", label: "Back (⌘[)", target: self, action: #selector(back(_:))),
            GlassButton(symbol: "rotate.right", label: "Rotate (⌘R)", target: self, action: #selector(rotate(_:))),
            GlassButton(symbol: "circle.lefthalf.filled", label: "Light or dark (⇧⌘A)", target: self, action: #selector(appearance(_:))),
        ]
        exitMatrixButton = GlassButton(symbol: "xmark.square", title: "Exit Matrix", label: "Close the matrix wall", style: .well, target: self, action: #selector(closeMatrix(_:)))
        exitMatrixButton.isHidden = true
        mirrorButton = GlassButton(symbol: "dot.radiowaves.left.and.right", title: "Mirror", label: "Send touches and keys to every device (⇧⌘M)", style: .well, target: self, action: #selector(toggleMirror(_:)))
        layoutButtons = [
            GlassButton(symbol: "iphone", label: "One device", target: self, action: #selector(showOne(_:))),
            GlassButton(symbol: "rectangle.split.2x1", label: "Every device, side by side (⌘\\)", target: self, action: #selector(showAll(_:))),
            GlassButton(symbol: "square.on.square.dashed", label: "Compare: mark what differs (⇧⌘D)", target: self, action: #selector(toggleCompare(_:))),
        ]
        let shot = GlassButton(symbol: "camera", label: "Screenshot (⌘S)", target: self, action: #selector(screenshot(_:)))
        recordButton = GlassButton(symbol: "record.circle", title: "", label: "Record input, log, network and screen (⌥⌘R)", style: .record, target: self, action: #selector(toggleRecording(_:)))
        saveRecordButton = GlassButton(symbol: "square.and.arrow.down", label: "Save recording (⇧⌘S)", style: .well, target: self, action: #selector(saveRecordingAndShow(_:)))
        saveRecordButton.isHidden = true
        let library = GlassButton(symbol: "sidebar.left", label: "Show or hide the library", target: self, action: #selector(toggleLibrary(_:)))
        let commands = GlassButton(symbol: "magnifyingglass", title: "⌘K", label: "Search every command, device, app and recording (⌘K)", style: .well, target: self, action: #selector(showPalette(_:)))

        func divider() -> NSView {
            let d = NSView()
            d.wantsLayer = true
            d.layer?.backgroundColor = Design.stroke.cgColor
            d.widthAnchor.constraint(equalToConstant: 1).isActive = true
            d.heightAnchor.constraint(equalToConstant: 16).isActive = true
            return d
        }

        func group(_ views: [NSView]) -> NSView {
            let well = NSView()
            well.wantsLayer = true
            well.layer?.backgroundColor = Design.well.cgColor
            well.layer?.cornerRadius = Design.controlRadius
            well.layer?.cornerCurve = .continuous
            let row = NSStackView(views: views)
            row.spacing = 2
            row.alignment = .centerY
            row.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
            row.translatesAutoresizingMaskIntoConstraints = false
            well.addSubview(row)
            NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: well.topAnchor), row.bottomAnchor.constraint(equalTo: well.bottomAnchor),
                                         row.leadingAnchor.constraint(equalTo: well.leadingAnchor), row.trailingAnchor.constraint(equalTo: well.trailingAnchor)])
            return well
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        walkChip.onOpen = { [weak self] in self?.showMap() }
        let deviceCluster = group([deviceButton, divider()] + deviceButtons)
        let captureCluster = group([shot, divider(), recordButton, saveRecordButton])
        let bar = NSStackView(views: [library, appChip, deviceCluster, spacer, walkChip, exitMatrixButton, mirrorButton, group(layoutButtons), captureCluster, commands])
        bar.spacing = 8
        bar.setHuggingPriority(.init(1), for: .horizontal)
        bar.setHuggingPriority(.init(1), for: .vertical)
        headerBar = bar
        updateHeaderInset()
        bar.translatesAutoresizingMaskIntoConstraints = false
        // A narrow window drops the buttons it can do without (each is in the menus and ⌘K too), then clips, rather
        // than the bar holding the window wide.
        bar.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for (v, p) in [(commands, 300), (mirrorButton, 310), (captureCluster, 320), (deviceCluster, 340)] as [(NSView, Float)] {
            bar.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: p), for: v)
        }
        header.addSubview(bar)

        // Three labeled micro-clusters: Inspect (right drawers), Verify (Changes/Map/Snapshots/Tests/Recordings), Dock (BottomDock & Agent).
        enum RailEntry {
            case section(String)
            case item(String, String, String, Selector)
        }
        let railEntries: [RailEntry] = [
            .section("INSPECT"),
            .item("device", "slider.horizontal.3", "Device controls", #selector(toggleDevicePane(_:))),
            .item("inspect", "cursorarrow.rays", "Inspector: pick what is on screen (⌥⌘I)", #selector(toggleInspector(_:))),
            .item("network", "arrow.up.arrow.down", "Network: live requests & mocks", #selector(toggleNetwork(_:))),
            .item("diagnostics", "stethoscope", "Diagnostics: performance, accessibility, background work", #selector(toggleDiagnostics(_:))),
            .section("VERIFY"),
            .item("changes", "plusminus", "Changes: compare session build against base (⌘D)", #selector(showChanges(_:))),
            .item("map", "point.3.connected.trianglepath.dotted", "Screen map: walk every screen", #selector(toggleMap(_:))),
            .item("snapshots", "photo.stack", "Screenshot tests", #selector(toggleSnapshots(_:))),
            .item("tests", "checkmark.circle", "Tests: run an androidTest APK", #selector(toggleTests(_:))),
            .item("recordings", "film", "Recordings: replay & bisect", #selector(toggleRecordings(_:))),
            .section("DOCK"),
            .item("dock", "dock.rectangle", "Bottom dock: Log, Timeline & Compare (⇧⌘L)", #selector(toggleBottomDock(_:))),
            .item("agent", "sparkles", "Agent activity (⌥⌘A)", #selector(showAgent(_:))),
        ]
        var railViews: [NSView] = []
        for (idx, entry) in railEntries.enumerated() {
            switch entry {
            case .section(let title):
                if idx > 0 {
                    let line = NSView()
                    line.wantsLayer = true
                    line.layer?.backgroundColor = Design.stroke.cgColor
                    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                    line.widthAnchor.constraint(equalToConstant: 26).isActive = true
                    railViews.append(line)
                }
                let lbl = NSTextField(labelWithString: title)
                lbl.font = .systemFont(ofSize: 8, weight: .bold)
                lbl.textColor = Design.mute.withAlphaComponent(0.75)
                lbl.alignment = .center
                railViews.append(lbl)
            case .item(let id, let symbol, let label, let action):
                let b = GlassButton(symbol: symbol, label: label, target: self, action: action)
                railButtons[id] = b
                let wrap = NSView()
                wrap.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(b)
                NSLayoutConstraint.activate([
                    b.topAnchor.constraint(equalTo: wrap.topAnchor), b.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                    b.leadingAnchor.constraint(equalTo: wrap.leadingAnchor), b.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
                ])
                // Small corner status dot (for overrides, log errors, live agent)
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 3.5
                dot.isHidden = true
                dot.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(dot)
                NSLayoutConstraint.activate([
                    dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
                    dot.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
                    dot.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -2),
                ])
                railDots[id] = dot
                // Compact count pill (for active mock rules, etc.)
                let badge = NSTextField(labelWithString: "")
                badge.font = .systemFont(ofSize: 9, weight: .bold)
                badge.alignment = .center
                badge.wantsLayer = true
                badge.layer?.cornerRadius = 7
                badge.layer?.masksToBounds = true
                badge.isHidden = true
                badge.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(badge)
                NSLayoutConstraint.activate([
                    badge.heightAnchor.constraint(equalToConstant: 14),
                    badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
                    badge.topAnchor.constraint(equalTo: wrap.topAnchor, constant: -2),
                    badge.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: 3),
                ])
                railBadges[id] = badge
                railViews.append(wrap)
            }
        }
        let column = NSStackView(views: railViews)
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 6, left: 5, bottom: 6, right: 5)
        column.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(column)

        // Panes first, then the bar and rail over them, then the palette's veil and the palette on top.
        let inspectorView = inspector.view
        for v in [networkPane, devicePane, inspectorView, testsPane, diagnosticsPane, recordingsPane, agentHost, header, rail, scrim, palette] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(v)
        }
        scrim.isHidden = true
        palette.isHidden = true
        installSnapshotReview(in: host)
        installScreenMap(in: host)
        installChangesSheet(in: host)
        scrim.onClick = { [weak self] in self?.hidePalette() }
        palette.onClose = { [weak self] in self?.hidePalette() }
        palette.source = { [weak self] in self?.paletteItems() ?? [] }
        networkPane.isHidden = true
        devicePane.isHidden = true
        inspectorView.isHidden = true
        agentHost.isHidden = true
        testsPane.isHidden = true
        testsPane.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
        testsPane.onClose = { [weak self] in self?.setShowingTests(false) }
        testsPane.follow(selected)
        testsLeading = testsPane.leadingAnchor.constraint(equalTo: host.trailingAnchor, constant: 20)
        diagnosticsPane.isHidden = true
        wireDiagnostics()
        diagnosticsPane.onClose = { [weak self] in self?.setShowingDiagnostics(false) }
        diagnosticsLeading = diagnosticsPane.leadingAnchor.constraint(equalTo: host.trailingAnchor, constant: 20)
        recordingsPane.isHidden = true
        recordingsPane.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
        recordingsPane.onOpenTrace = { [weak self] file in self?.view(recording: file) }
        recordingsPane.onClose = { [weak self] in self?.setShowingRecordings(false) }
        recordingsLeading = recordingsPane.leadingAnchor.constraint(equalTo: host.trailingAnchor, constant: 20)
        devicePane.targets = { [weak self] in
            guard let self else { return [] }
            return self.devicePane.toAll ? Engine.shared.simulators.filter { $0.state == .running } : (self.live.map { [$0] } ?? [])
        }
        devicePane.onOverridesChange = { [weak self] in self?.refreshOverrides() }
        devicePane.onClose = { [weak self] in self?.setShowingDevice(false) }
        deviceLeading = devicePane.leadingAnchor.constraint(equalTo: host.trailingAnchor, constant: 20)
        inspectorLeading = inspectorView.leadingAnchor.constraint(equalTo: host.trailingAnchor, constant: 20)
        agentLeading = agentHost.leadingAnchor.constraint(equalTo: host.trailingAnchor, constant: 20)
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
            inspectorView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.margin),
            inspectorView.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Design.margin),
            inspectorView.widthAnchor.constraint(equalToConstant: Self.inspectorWidth),
            inspectorLeading,
            agentHost.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Design.margin),
            agentHost.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Design.margin),
            agentHost.widthAnchor.constraint(equalToConstant: Self.agentWidth),
            agentLeading,
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

    private func refreshOverrides() {
        overrideBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let sim = selected, sim.isAlive else {
            overrideBar.isHidden = true
            updateRailBadges(overrideCount: 0)
            return
        }
        let overrides = devicePane.activeOverrides(for: sim)
        for o in overrides {
            let pill = makeOverridePill(symbol: o.symbol, title: o.label, color: o.color) { [weak self] in
                self?.devicePane.clearOverride(o, on: sim)
                self?.toast.show("Cleared \(o.label)")
            }
            overrideBar.addArrangedSubview(pill)
        }
        if networkRuleCount > 0 {
            let label = networkRuleCount == 1 ? "1 Mock" : "\(networkRuleCount) Mocks"
            let pill = makeOverridePill(symbol: "theatermasks", title: label, color: Design.difference) { [weak self] in
                self?.networkPane.clearAllRules()
                self?.toast.show("Cleared all network rules")
            }
            overrideBar.addArrangedSubview(pill)
        }
        overrideBar.isHidden = overrideBar.arrangedSubviews.isEmpty
        updateRailBadges(overrideCount: overrides.count)
    }

    private func makeOverridePill(symbol: String, title: String, color: NSColor, onClear: @escaping () -> Void) -> NSView {
        let b = GlassButton(symbol: symbol, title: "\(title)  ×", label: "Click to clear \(title)", style: .well, target: nil, action: nil)
        b.font = .systemFont(ofSize: 11, weight: .semibold)
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        b.layer?.cornerRadius = 12
        b.layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        b.layer?.borderWidth = 1
        b.layer?.borderColor = color.withAlphaComponent(0.38).cgColor
        b.contentTintColor = color
        b.attributedTitle = NSAttributedString(string: "\(title)  ×", attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
        b.onPress = onClear
        return b
    }

    private func updateRailBadges(overrideCount: Int) {
        if let dot = railDots["device"] {
            dot.isHidden = overrideCount == 0
            dot.layer?.backgroundColor = Design.warning.cgColor
        }
        if let badge = railBadges["network"] {
            badge.isHidden = networkRuleCount == 0
            badge.stringValue = " \(networkRuleCount) "
            badge.textColor = Design.stage
            badge.layer?.backgroundColor = Design.difference.cgColor
        }
        if let dot = railDots["dock"] {
            dot.isHidden = logErrorCount == 0
            dot.layer?.backgroundColor = Design.record.cgColor
        }
        if let dot = railDots["agent"] {
            dot.isHidden = agentActivity.client == nil
            dot.layer?.backgroundColor = ((agentTools?.paused ?? false) ? Design.warning : Design.accent).cgColor
        }
    }

    func updateChrome() {
        guard appChip != nil else { return }
        let alive = Engine.shared.simulators.filter(\.isAlive).count
        if let sim = selected {
            let dot = sim.state == .running ? "● " : (sim.state == .starting ? "◌ " : "○ ")
            let text = NSMutableAttributedString(string: dot, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold),
                                                                           .foregroundColor: sim.state == .running ? Design.accent : Design.mute])
            let primary = sim.effectiveLabel
            text.append(NSAttributedString(string: primary, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Design.ink]))
            if alive > 1 {
                text.append(NSAttributedString(string: "  (\(alive) devices)", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Design.mute]))
            }
            appChip.title = primary
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
        exitMatrixButton?.isHidden = matrixSims.isEmpty
        mirrorButton.isOn = mirror
        mirrorButton.title = mirror ? "Mirroring" : "Mirror"
        mirrorButton.isHidden = alive < 2 && !mirror
        layoutButtons[0].isOn = !sideBySide
        layoutButtons[1].isOn = sideBySide && !comparing
        layoutButtons[2].isOn = comparing
        for b in layoutButtons.dropFirst() { b.isEnabled = alive > 1 || sideBySide }
        recordButton.isOn = isRecording
        if isRecording, let sim = selected, let start = recordingStarted[ObjectIdentifier(sim)] {
            let secs = max(0, Int(Date().timeIntervalSince(start)))
            recordButton.title = String(format: "%d:%02d", secs / 60, secs % 60)
        } else {
            recordButton.title = isRecording ? "0:00" : ""
        }
        recordButton.isEnabled = live != nil
        saveRecordButton?.isHidden = !isRecording
        railButtons["inspect"]?.isOn = inspecting
        railButtons["dock"]?.isOn = showingBottomDock
        railButtons["network"]?.isOn = showingNetwork
        railButtons["device"]?.isOn = showingDevice
        railButtons["tests"]?.isOn = showingTests
        railButtons["diagnostics"]?.isOn = showingDiagnostics
        railButtons["recordings"]?.isOn = showingRecordings
        railButtons["changes"]?.isOn = changesSheet.isOpen
        timeline.saveButton.isEnabled = isRecording
        railButtons["agent"]?.isOn = showingAgent
        railButtons["snapshots"]?.isOn = snapshotReview.isOpen
        railButtons["map"]?.isOn = screenMap.isOpen
        refreshOverrides()
        updateAgentHud()
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
        host.addSubview(snapshotReview, positioned: .below, relativeTo: rail)
        NSLayoutConstraint.activate([snapshotReview.topAnchor.constraint(equalTo: host.topAnchor), snapshotReview.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     snapshotReview.leadingAnchor.constraint(equalTo: host.leadingAnchor), Self.giving(snapshotReview.trailingAnchor.constraint(equalTo: host.trailingAnchor))])
        snapshotReview.defaultAPK = { [weak self] in self?.selected?.apk }
        snapshotReview.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
        snapshotReview.onToggle = { [weak self] in self?.updateChrome() }
    }

    @objc func toggleSnapshots(_ sender: Any?) { if snapshotReview.isOpen { snapshotReview.close() } else { showSnapshots() } }

    func showSnapshots(run: Bool = false) {
        Reports.shared.count(.snapshots)
        if screenMap.isOpen { screenMap.close() }
        if changesSheet.isOpen { changesSheet.close() }
        snapshotReview.open()
        if run { snapshotReview.runIfReady() }
    }

    // MARK: Screen map

    private func installScreenMap(in host: NSView) {
        screenMap.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(screenMap, positioned: .below, relativeTo: scrim)
        NSLayoutConstraint.activate([screenMap.topAnchor.constraint(equalTo: host.topAnchor), screenMap.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     screenMap.leadingAnchor.constraint(equalTo: host.leadingAnchor), Self.giving(screenMap.trailingAnchor.constraint(equalTo: host.trailingAnchor))])
        screenMap.defaultAPK = { [weak self] in self?.selected?.apk }
        screenMap.worktree = { [weak self] in
            guard let self, let sim = self.selected else { return nil }
            if let w = self.worktree(of: sim) { return w }
            return self.sessions.mainBuilds.workspace(for: sim).map { self.sessions.mainBuilds.trunk(of: $0.root) }
        }
        screenMap.signInKey = { [weak self] in
            guard let self, let sim = self.selected else { return nil }
            if let s = self.sessions.session(forSimulator: sim) { return SignIns.key(workspace: s.workspace) }
            return self.sessions.mainBuilds.workspace(for: sim).map { SignIns.key(workspace: $0.root) }
        }
        screenMap.signInOnce = { [weak self] apk, key, app, done in
            guard let self else { return }
            self.screenMap.close()   // the stage, with the device to sign in on, is under the sheet
            if !SignInOnce.begin(workbench: self, apk: apk, key: key, app: app, done: done) { done(false) }
        }
        screenMap.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
        screenMap.onToggle = { [weak self] in self?.updateChrome() }
        screenMap.onProgress = { [weak self] p in self?.walkChip.show(p) }
        screenMap.onGo = { [weak self] screen, map in self?.goThere(screen, map) }
        screenMap.context = { [weak self] apk in await self?.mapContext(for: apk) }
    }

    /// The history a walk of this APK is filed in: the session whose newest build it is (the same bytes), that build's clean
    /// commit, and the baseline rule (History.baseline) against the workspace's base ref. Nil when no session built it
    /// or the build has no clean commit.
    func mapContext(for apk: URL) async -> MapContext? {
        let key = await Task.detached { Workbench.fileKey(apk) }.value
        guard let key else { return nil }
        // A session's newest build, else the base branch's own build (the main row): its walk is the project's map.
        var found: (build: Build, workspace: Workspace)?
        if let session = sessions.sessions.first(where: { (sessions.builds[$0.worktree.path] ?? $0.build)?.key == key }),
           let build = sessions.builds[session.worktree.path] ?? session.build,
           let workspace = sessions.workspaces.first(where: { $0.root.path == session.workspace.path }) {
            found = (build, workspace)
        } else {
            for ws in sessions.workspaces {
                guard let row = sessions.mainBuilds.row(for: ws), let b = [row.current, row.newest].compactMap({ $0 }).first(where: { $0.key == key }) else { continue }
                found = (b, ws)
                break
            }
        }
        guard let (build, workspace) = found, History.fileable(build), let sha = build.sha,
              let (commit, tree) = await History.resolve(sha, in: workspace.root) else { return nil }
        let store = History.store(stateRoot: sessions.evidence.store.root, workspace: workspace.root)
        var onBase = false
        for r in [workspace.baseRef, workspace.baseRef.hasPrefix("origin/") ? String(workspace.baseRef.dropFirst(7)) : nil].compactMap({ $0 }) where !onBase {
            onBase = await Git.run(["merge-base", "--is-ancestor", commit, r], in: workspace.root) != nil
        }
        var ctx = MapContext(store: store, commit: commit, tree: tree, engine: Engine.shared.version) { profile in
            await History.baseline(commit: commit, mainRef: workspace.baseRef, in: workspace.root, store: store, profile: profile.id)
        }
        ctx.baseBranch = onBase ? MainBuilds.shortName(workspace.baseRef) : nil
        ctx.unsignedCounts = sessions.countsUnsigned(workspace.root)
        return ctx
    }

    /// The first 16 hex digits of a file's SHA-256: a build's key.
    nonisolated static func fileKey(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    @objc func toggleMap(_ sender: Any?) { if screenMap.isOpen { screenMap.close() } else { showMap() } }

    func showMap(walk: Bool = false) {
        Reports.shared.count(.screenMap)
        if snapshotReview.isOpen { snapshotReview.close() }
        if changesSheet.isOpen { changesSheet.close() }
        screenMap.open()
        if walk, !screenMap.isWalking { screenMap.walk() }
    }

    // MARK: Changes

    private func installChangesSheet(in host: NSView) {
        changesSheet.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(changesSheet, positioned: .below, relativeTo: rail)
        NSLayoutConstraint.activate([changesSheet.topAnchor.constraint(equalTo: host.topAnchor), changesSheet.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                                     changesSheet.leadingAnchor.constraint(equalTo: host.leadingAnchor), Self.giving(changesSheet.trailingAnchor.constraint(equalTo: host.trailingAnchor))])
        changesSheet.controller = sessions
        changesSheet.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
        changesSheet.onToggle = { [weak self] in self?.updateChrome() }
        changesSheet.onGo = { [weak self] screen, map, session in self?.goThere(screen, map, session: session) }
        changesSheet.onLive = { [weak self] session, base in self?.compareLive(session: session, base: base) }
    }

    /// Opens a session's build side by side with a base build, with mirrored input, clear Head/Base labels, and
    /// signed-in data cloned when the repository has a kept sign-in.
    func compareLive(session: Session, base: Build) {
        sessions.activate(session)
        guard let headSim = sessions.simulator(for: session) else {
            toast.show("Could not open \(session.title) to compare", problem: true)
            return
        }
        headSim.displayLabel = "Head · \(session.simLabel)"
        let baseShort = base.sha.map { String($0.prefix(7)) } ?? String(base.key.prefix(8))
        let baseTitle = "Base · \(base.ref ?? "main") · \(baseShort)"
        let basePath = base.apk.resolvingSymlinksInPath().path

        // Reuse main's running simulator if it is already running this base APK (and is not the head simulator).
        var baseSim: Simulator?
        if let mainSim = sessions.mainBuilds.simulator(of: session.workspace),
           mainSim !== headSim,
           mainSim.apk.resolvingSymlinksInPath().path == basePath {
            baseSim = mainSim
        } else if let existing = Engine.shared.simulators.first(where: { $0.isAlive && $0 !== headSim && $0.apk.resolvingSymlinksInPath().path == basePath }) {
            baseSim = existing
        }
        if let baseSim {
            baseSim.displayLabel = baseTitle
        } else {
            var opts: [String] = []
            if let deviceIdx = headSim.options.firstIndex(of: "--device"), deviceIdx + 1 < headSim.options.count {
                opts += ["--device", headSim.options[deviceIdx + 1]]
            }
            let dataRoot = Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true)
            if let kept = SignIns.shared.record(SignIns.key(workspace: session.workspace)),
               case .cloned(let cloneSlot) = SlotClone.make(slot: kept.slot, in: dataRoot, prefix: DeviceData.clonePrefix) {
                opts += ["--data-slots", cloneSlot, "--biometrics", "auto"]
            } else {
                opts += ["--data-slots", DeviceData.clonePrefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))]
            }
            if let launched = open(base.apk, remember: false, options: opts) {
                launched.displayLabel = baseTitle
                baseSim = launched
            }
        }
        selected = headSim
        window.subtitle = headSim.effectiveLabel
        mirror = true
        setComparing(true)
        refreshCaptions()
        toast.show("Comparing \(session.title) side by side with \(base.ref ?? "base") (input mirrored)")
    }

    /// Device > Changes… (⌘D): the current session's build against its base.
    @objc func showChanges(_ sender: Any?) {
        guard let session = sessions.currentSession else { toast.show("Add a repository first: Changes compares a session's build with a base", problem: true); return }
        showChanges(of: session)
    }

    func showChanges(of session: Session, compare: Bool = true) {
        if changesSheet.isOpen, changesSheet.session?.worktree.path == session.worktree.path { changesSheet.close(); return }
        if snapshotReview.isOpen { snapshotReview.close() }
        if screenMap.isOpen { screenMap.close() }
        changesSheet.open(session: session, compare: compare)
    }

    /// Replays a screen's route from the map on the target simulator (or the session's simulator, starting/selecting it
    /// if needed): restart (at the route's deep link), then each step, settling after each. Closes open map/changes
    /// sheets first so the device can be watched getting there.
    func goThere(_ screen: MapScreen, _ map: ScreenMapData, session: Session? = nil, done: ((Bool) -> Void)? = nil) {
        if let session {
            if sessions.simulator(for: session) == nil { sessions.activate(session) }
            if let sessionSim = sessions.simulator(for: session) {
                select(sessionSim)
            }
        }
        guard let initialSim = (session.flatMap { sessions.simulator(for: $0) }) ?? selected ?? Engine.shared.simulators.first(where: { $0.isAlive }) else {
            toast.show("Open the app first: the route is replayed on a running device", problem: true); done?(false); return
        }
        if session == nil {
            let mapped = map.apk?.lastPathComponent ?? map.apkName
            if !mapped.isEmpty, initialSim.apk.lastPathComponent != mapped {
                toast.show("The selected device runs \(initialSim.apk.lastPathComponent); this map is of \(mapped)", problem: true); done?(false); return
            }
        }
        screenMap.close()
        changesSheet.close()
        // If this session's repository has a kept sign-in and the simulator was launched without `--biometrics auto`
        // (e.g. before signing in), relaunch it seeded from the kept sign-in so signed-in routes can actually replay.
        let workspace = session?.workspace ?? sessions.session(forSimulator: initialSim)?.workspace ?? sessions.mainBuilds.workspace(for: initialSim)?.root
        let needsSignedInRelaunch: Bool = {
            guard let ws = workspace, SignIns.shared.record(SignIns.key(workspace: ws)) != nil else { return false }
            return !initialSim.options.contains("--biometrics")
        }()
        if needsSignedInRelaunch, let ws = workspace {
            toast.show("Signing in to go to \(screen.label)…")
            let targetSlot = SessionsController.slot(of: initialSim) ?? DeviceData.slot(for: initialSim.options)
            let label = initialSim.displayLabel
            let apk = initialSim.apk
            let baseOpts = initialSim.options
            Engine.shared.close(initialSim)
            Task { @MainActor [weak self] in
                guard let self else { done?(false); return }
                await Task.detached(priority: .userInitiated) {
                    initialSim.waitUntilExit()
                    let root = Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true)
                    if let kept = SignIns.shared.record(SignIns.key(workspace: ws)) {
                        SlotClone.waitUntilFree(kept.slot, in: root, timeout: 10)
                        SlotClone.seed(from: kept.slot, to: targetSlot, in: root, overwrite: true)
                    }
                }.value
                let opts = baseOpts + ["--biometrics", "auto"]
                guard let relaunched = self.open(apk, remember: false, options: opts) else {
                    self.toast.show("Could not restart simulator to go to \(screen.label)", problem: true)
                    done?(false)
                    return
                }
                relaunched.displayLabel = label
                self.refreshCaptions()
                self.replayRoute(screen, on: relaunched, done: done)
            }
            return
        }
        replayRoute(screen, on: initialSim, done: done)
    }

    private func replayRoute(_ screen: MapScreen, on sim: Simulator, done: ((Bool) -> Void)?) {
        grid.view(for: sim).map { window.makeFirstResponder($0) }
        toast.show("Going to \(screen.label)…")
        let commands = [screen.start.map { "restart \($0)" } ?? "restart"] + screen.steps
        Task { @MainActor [weak self] in
            // Wait if the simulator was just started or relaunched.
            let readyDeadline = Date().addingTimeInterval(45)
            while sim.isAlive, !(sim.state == .running && sim.framesShown > 0), Date() < readyDeadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard sim.state == .running else {
                self?.toast.show("Simulator did not become ready to go to \(screen.label)", problem: true)
                done?(false)
                return
            }
            let failed: String? = await Task.detached(priority: .userInitiated) {
                for (i, c) in commands.enumerated() {
                    var answer = sim.sendSync(c)
                    if answer.hasPrefix("error"), i > 0 {
                        Thread.sleep(forTimeInterval: 0.8)
                        _ = sim.sendSync("settle 1500 150")
                        answer = sim.sendSync(c)
                    }
                    if answer.hasPrefix("error") { return "Step \(i) (\(ScreenMap.describe(c))) failed: " + answer.replacingOccurrences(of: "error: ", with: "") }
                    _ = sim.sendSync(i == 0 ? "settle 4000 300" : "settle 2500 150")
                }
                return nil
            }.value
            self?.toast.show(failed ?? "On \(screen.label)", problem: failed != nil)
            done?(failed == nil)
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
        add("compare.apk", "Compare with another build…", "App", "square.on.square.dashed", "⇧⌘O") { [weak self] in self?.compareWithAPK(nil) }
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
        if let sim = live {
            for script in Scripts.available(for: worktree(of: sim)) {
                add("script." + script.url.path, "Run script: \(script.name)", "Scripts", "terminal", keywords: "script sign in login test setup") { [weak self] in
                    self?.runScript(at: script.url)
                }
            }
        }
        add("script.new", "New script…", "Scripts", "plus.rectangle.on.folder", keywords: "script sign in login automate") { [weak self] in self?.newScript(nil) }
        add("variables", "Variables (sign-ins for scripts)…", "Scripts", "key", keywords: "env environment secret password credentials keychain") { [weak self] in self?.showVariables(nil) }
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
            setting("dark", "Dark appearance", "moon", "appearance dark", keywords: "dark mode night theme")
            setting("light", "Light appearance", "sun.max", "appearance light", keywords: "light mode day theme")
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
        add("screen.rec", Recorder.isRecording(selected) ? "Stop recording the screen" : "Record the screen to a video", "Record", "video.circle", "⌃⌘R", keywords: "mp4 movie capture") { [weak self] in self?.toggleScreenRecording(nil) }
        out += DevHooks.shared.paletteItems(for: selected)   // developer hooks (DevHooks.swift)
        out += sessions.paletteItems()                       // worktree sessions (SessionsController.swift)
        // Layout and panes.
        add("layout.one", "Show one device", "View", "iphone") { [weak self] in self?.setSideBySide(false) }
        add("layout.all", "Show every device side by side", "View", "rectangle.split.2x1", "⌘\\") { [weak self] in self?.showAll(nil) }
        add("compare", comparing ? "Stop comparing" : "Compare the devices", "View", "square.on.square.dashed", "⇧⌘D") { [weak self] in self?.toggleCompare(nil) }
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
        add("help.feedback", "Report feedback…", "Help", "exclamationmark.bubble", keywords: "bug issue problem crash stacktrace screenshot github") { [weak self] in
            FeedbackWindow.shared.show(workbench: self)
        }
        // Recordings saved before.
        let files = (try? FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.pathExtension == "apkrec" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for f in newest.prefix(6) {
            add("recording." + f.lastPathComponent, "Open recording " + f.deletingPathExtension().lastPathComponent, "Recordings", "film", keywords: "replay trace") { [weak self] in self?.view(recording: f) }
        }
        for style in AppIconStyle.allCases {
            add("icon." + style.rawValue, "App icon: \(style.title)", "App", "app.badge", keywords: "app icon dock \(style.title)") { [weak self] in
                AppIcon.current = style
                self?.toast.show("App icon: \(style.title)")
            }
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
            case .inspector: Reports.shared.count(.inspector)
            case .network: Reports.shared.count(.paneNetwork)
            case .tests: Reports.shared.count(.paneTests)
            case .diagnostics: Reports.shared.count(.paneDiagnostics)
            case .recordings: Reports.shared.count(.paneRecordings)
            case .agent: break
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
        case .inspector:
            inspecting = on
            inspectTimer?.invalidate()
            inspectTimer = on ? Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refreshInspector() } : nil
            refreshGrid()
            if on { refreshInspector() }
        case .network: networkPane.follow(on ? selected : nil)
        case .tests: testsPane.setActive(on)
        case .diagnostics: diagnosticsPane.follow(on ? selected : nil)
        case .recordings: recordingsPane.setShown(on, folder: recordings)
        case .agent: if on { agentPanel?.refresh() }
        }
    }

    /// Each pane of the slot: its view, the constraint that slides it, its width.
    private var slot: [(RightPane, NSView, NSLayoutConstraint, CGFloat)] {
        [(.device, devicePane, deviceLeading, Self.deviceWidth),
         (.inspector, inspector.view, inspectorLeading, Self.inspectorWidth),
         (.network, networkPane, networkLeading, Self.networkWidth),
         (.tests, testsPane, testsLeading, Self.testsWidth),
         (.diagnostics, diagnosticsPane, diagnosticsLeading, Self.diagnosticsWidth),
         (.recordings, recordingsPane, recordingsLeading, Self.recordingsWidth),
         (.agent, agentHost, agentLeading, Self.agentWidth)]
    }

    func setShowingRecordings(_ on: Bool) { show(on ? .recordings : nil, closing: .recordings) }

    private func layoutRightSlot() {
        guard let host = networkPane.superview else { return }
        let panes = slot
        for (p, view, _, _) in panes where p == rightPane { view.isHidden = false }
        let width = panes.first { $0.0 == rightPane }?.3 ?? 0
        Design.animate(Design.move, {
            for (p, _, leading, w) in panes { leading.animator().constant = p == self.rightPane ? -(w + 68) : 20 }
            self.gridTrailing.animator().constant = width > 0 ? -(width + 80) : -68
            host.layoutSubtreeIfNeeded()
        }, done: {
            for (p, view, _, _) in self.slot where p != self.rightPane { view.isHidden = true }
        })
        updateChrome()
    }

    @objc func toggleBottomDock(_ sender: Any?) {
        setBottomDock(!showingBottomDock)
    }

    func setBottomDock(_ on: Bool, tab: BottomDock.Tab? = nil) {
        if let tab { bottomDock.select(tab) }
        showingBottomDock = on
        if on {
            bottomDock.isHidden = false
            logPanel.follow(bottomDock.activeTab == .log ? selected : nil)
            timeline.follow(bottomDock.activeTab == .timeline ? selected : nil)
            timeline.setShown(bottomDock.activeTab == .timeline)
        } else {
            logPanel.follow(nil)
            timeline.follow(nil)
            timeline.setShown(false)
        }
        Design.animate(Design.move, { self.bottomDockHeight.animator().constant = on ? self.bottomDockSavedHeight : 0 },
                       done: { if !self.showingBottomDock { self.bottomDock.isHidden = true } })
        window.toolbar?.validateVisibleItems()
        updateChrome()
    }

    /// The timeline docks along the bottom, inside the unified BottomDock.
    func setShowingTimeline(_ on: Bool) {
        if on { Reports.shared.count(.timeline) }
        if on {
            setBottomDock(true, tab: .timeline)
        } else if showingTimeline {
            setBottomDock(false)
        }
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
        networkPane.onRulesChange = { [weak self] count in
            self?.networkRuleCount = count
            self?.refreshOverrides()
        }
        timeline.onScrub = { [weak self] t in
            guard let self else { return }
            if !self.showingNetwork { self.setShowingNetwork(true) }
            self.networkPane.reveal(at: t)
            self.bottomDock.setTimelineLive(false)
        }
        timeline.onSave = { [weak self] in self?.saveRecordingAndShow(nil) }
        networkPane.onSay = { [weak self] text, problem in self?.toast.show(text, problem: problem) }
        networkPane.onClose = { [weak self] in self?.setShowingNetwork(false) }
        timeline.onClose = { [weak self] in self?.setBottomDock(false) }
        logPanel.onErrorCount = { [weak self] count in
            self?.logErrorCount = count
            self?.bottomDock.setLogErrorCount(count)
            self?.refreshOverrides()
        }
        bottomDock.onClose = { [weak self] in self?.setBottomDock(false) }
        bottomDock.onResizeDelta = { [weak self] delta in
            guard let self, self.showingBottomDock else { return }
            let next = min(max(self.bottomDockSavedHeight + delta, 140), 420)
            self.bottomDockSavedHeight = next
            self.bottomDockHeight.constant = next
        }
        bottomDock.onTabChange = { [weak self] tab in
            guard let self, self.showingBottomDock else { return }
            self.logPanel.follow(tab == .log ? self.selected : nil)
            self.timeline.follow(tab == .timeline ? self.selected : nil)
            self.timeline.setShown(tab == .timeline)
            self.bottomDock.setTimelineLive(self.timeline.isLive)
            self.updateChrome()
        }
        bottomDock.onHighlightDiff = { [weak self] item in
            guard let self else { return }
            for v in self.grid.views { v.outlined = nil }
            guard let item, let target = item.simulator ?? self.selected else { return }
            self.grid.view(for: target)?.outlined = item.rect
        }
    }

    private func updateHeaderInset() {
        let collapsed = splitController?.splitViewItems.first?.isCollapsed ?? false
        headerBar?.edgeInsets = NSEdgeInsets(top: 0, left: collapsed ? 76 : 8, bottom: 0, right: 8)
    }

    private static let sidebarHiddenKey = "sidebarHidden"

    /// Shows the sidebar if it is folded away.
    func showLibrary() {
        guard let item = splitController.splitViewItems.first, item.isCollapsed else { return }
        item.animator().isCollapsed = false
        UserDefaults.standard.set(false, forKey: Self.sidebarHiddenKey)
        updateHeaderInset()
    }

    @objc func addRepository(_ sender: Any?) { sessions.chooseRepository() }

    @objc func toggleLibrary(_ sender: Any?) {
        guard let item = splitController.splitViewItems.first else { return }
        let hide = !item.isCollapsed
        item.animator().isCollapsed = hide
        UserDefaults.standard.set(hide, forKey: Self.sidebarHiddenKey)   // remembered: the next window opens the same way
        updateHeaderInset()
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
        menu.addItem(withTitle: "Open in Claude", action: #selector(openInClaudeClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Remove from Sidebar", action: #selector(removeSessionClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Remove Repository from Sessions", action: #selector(removeRepositoryClicked), keyEquivalent: "").target = self
        menu.delegate = self
        sessions.evidence.menuItems().forEach(menu.addItem)   // Walk Again, Stop Walking, ... (Evidence.swift)
        table.menu = menu
        table.registerForDraggedTypes([.fileURL])   // a folder dropped here is a repository to add

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        status.font = .systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        status.alignment = .left
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 4

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
        if case .sessionsHeader = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .simulator, .session, .main, .claudeOffer, .claudeTitles, .pull, .suggestion, .addSession: return true
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
        if case .sessionsHeader = rows[row] { return 24 }
        if case .suggestion = rows[row] { return 24 }
        if case .addSession = rows[row] { return 28 }
        if case .session(let s) = rows[row] { return sessions.rowHeight(for: s) }
        if case .main = rows[row] { return 40 }
        if case .pull = rows[row] { return 42 }
        return 36
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .sessionsHeader(let title, let ws, _):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let add = ClosureButton(symbol: "plus", tip: "Add a session from \(ws.lastPathComponent)") {}
            add.handler = { [weak self, weak add] in
                guard let self, let add else { return }
                self.sessions.addMenu(for: ws).popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height + 2), in: add)
            }
            add.contentTintColor = .secondaryLabelColor
            let stack = NSStackView(views: [label, add])
            stack.spacing = 4
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 6)
            return stack
        case .addSession(_, let hidden):
            return cell(symbol: "plus.circle", tint: .controlAccentColor, title: "Add a session",
                        detail: hidden == 0 ? "No worktrees yet" : "\(hidden) worktree\(hidden == 1 ? "" : "s") to choose from")
        case .suggestion(let s):
            return sessions.suggestionCell(for: s)
        case .session(let session):
            return sessions.cell(for: session)
        case .main(let m):
            return sessions.mainCell(m)
        case .claudeOffer(let offer):
            return ClaudeUI.offerCell(offer)
        case .claudeTitles:
            return ClaudeUI.titlesPromptCell { [weak self] in
                UserDefaults.standard.set(true, forKey: ClaudeUI.titlesPromptHiddenKey)
                self?.reload()
            }
        case .pull(let pull):
            return sessions.pullCell(pull)
        case .simulator(let sim):
            let kind = sim.options.firstIndex(of: "--device").flatMap { i in i + 1 < sim.options.count ? Self.title(sim.options[i + 1]) : nil } ?? "Phone"
            let detail: String
            let symbol: String
            switch sim.state {
            case .starting: detail = "\(kind) · Starting…"; symbol = "circle.dotted"
            case .running:
                let size = sim.deviceSize
                detail = size.width > 0 ? "\(kind) · \(Int(size.width))×\(Int(size.height))" : "\(kind) · Running"
                symbol = "play.circle.fill"
            case .ended(let code): detail = code == 0 ? "\(kind) · Quit" : "\(kind) · Ended (exit \(code))"; symbol = "stop.circle"
            }
            let title = sim.effectiveLabel
            let rowView = cell(symbol: symbol, tint: sim.state == .running ? .systemGreen : .secondaryLabelColor, title: title, detail: detail)
            rowView.toolTip = (sim.apk.path as NSString).abbreviatingWithTildeInPath
            return rowView
        case .recent(let url):
            let title = storedBuildLabel(for: url) ?? url.lastPathComponent
            let rowView = cell(symbol: "shippingbox", tint: .secondaryLabelColor, title: title,
                               detail: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
            rowView.toolTip = (url.path as NSString).abbreviatingWithTildeInPath
            return rowView
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
        if case .main(let m) = rows[row] { sessions.openMain(m.workspace) }
        if case .suggestion(let s) = rows[row] { sessions.show(s) }
        if case .addSession(let ws, _) = rows[row], let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) {
            sessions.addMenu(for: ws).popUp(positioning: nil, at: NSPoint(x: 8, y: view.bounds.height), in: view)
        }
        if case .claudeOffer(let offer) = rows[row] { sessions.addRepositories([offer.repository]) }
        if case .claudeTitles = rows[row] { ClaudeSessions.shared.enabled = true; reload() }   // the titles arrive with the read
        if case .pull(let pull) = rows[row] { sessions.openPull(pull) }
        if case .recent(let url) = rows[row] { open(url) }
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
        guard row >= 0, row < rows.count else { return }
        if let open = menu.items.first(where: { $0.action == #selector(openInClaudeClicked) }) {
            if case .session(let s) = rows[row], s.claude?.source == .t3 { open.title = "Open in T3 Code" } else { open.title = "Open in Claude" }
        }
        // Main's row is not a worktree of the person's: no Claude session, nothing to remove but the repository.
        var isMain = false
        if case .main = rows[row] { isMain = true }
        for item in menu.items where [#selector(openInClaudeClicked), #selector(removeSessionClicked)].contains(item.action) { item.isHidden = isMain }
        var items: [NSMenuItem] = []
        if case .session(let session) = rows[row] { items = sessions.buildMenuItems(for: session) + [.separator()] }
        else if case .pull(let pull) = rows[row] { items = sessions.pullMenuItems(for: pull) + [.separator()] }
        else if case .main(let m) = rows[row] { items = sessions.mainMenuItems(m) + [.separator()] }
        else { return }
        for (i, item) in items.enumerated() { item.tag = 77; menu.insertItem(item, at: i) }
    }

    @objc private func closeClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        if case .simulator(let sim) = rows[row] { Engine.shared.close(sim) }
        if case .session(let session) = rows[row] { sessions.closeSimulator(of: session) }
        if case .main(let m) = rows[row] { sessions.closeMain(m.workspace) }
        if case .pull(let pull) = rows[row] { sessions.closePullSimulator(pull) }
    }

    @objc private func openInClaudeClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, case .session(let session) = rows[row] else { return }
        if session.claude?.source == .t3 {
            T3Sessions.open(session.worktree) { [weak self] why in if let why { self?.toast.show(why, problem: true) } }
            return
        }
        if !ClaudeSessions.openInClaude(session.claude) { toast.show("Claude is not installed on this Mac", problem: true) }
    }

    /// The session row under the pointer when the sidebar's context menu opened.
    var clickedSession: Session? {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, case .session(let s) = rows[row] else { return nil }
        return s
    }

    @objc private func removeSessionClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        if case .session(let s) = rows[row] { sessions.remove(s) }
        if case .suggestion(let s) = rows[row] { sessions.dismiss(s) }
    }

    @objc private func removeRepositoryClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        if case .main(let m) = rows[row] { sessions.removeWorkspace(at: m.workspace); return }
        guard case .session(let session) = rows[row] else { return }
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
        if on {
            setBottomDock(true, tab: .log)
        } else if showingLog {
            setBottomDock(false)
        }
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
            if on {
                self.recording.insert(key)
                self.recordingStarted[key] = Date()
            } else {
                self.recording.remove(key)
                self.recordingStarted.removeValue(forKey: key)
            }
            self.updateRecordTimer()
            self.toast.show(on ? "Recording \(sim.name): input, log, network and screen" : "Recording stopped")
            self.updateChrome()
        }
    }

    private func updateRecordTimer() {
        if recording.isEmpty {
            recordTimer?.invalidate()
            recordTimer = nil
        } else if recordTimer == nil {
            recordTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                let aliveKeys = Set(Engine.shared.simulators.filter(\.isAlive).map(ObjectIdentifier.init))
                self.recording.formIntersection(aliveKeys)
                self.recordingStarted = self.recordingStarted.filter { aliveKeys.contains($0.key) }
                if self.recording.isEmpty {
                    self.recordTimer?.invalidate()
                    self.recordTimer = nil
                }
                self.updateChrome()
            }
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

    /// The inspector: the chosen simulator's nodes in a frosted glass right drawer, picked by pointing at the picture.
    /// While it is open clicks on that picture pick instead of tapping; keys and the toolbar still reach the app.
    func setInspecting(_ on: Bool) {
        show(on ? .inspector : nil, closing: .inspector)
        reload()
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
    /// (boxes: content only there or moved; shaded: pixels that differ) and listed in the BottomDock's Compare tab.
    func setComparing(_ on: Bool) {
        comparing = on
        compareTimer?.invalidate()
        compareTimer = nil
        if on {
            sideBySide = true
            // Content that loads by itself changes the answer too: look again every few seconds.
            compareTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.scheduleCompare(after: 0) }
            setBottomDock(true, tab: .compare)
        } else {
            for v in grid.views { v.boxes = []; v.areas = [] }
            bottomDock.setCompareSummary(text: "", items: [], counts: (0, 0, 0))
            if showingBottomDock && bottomDock.activeTab == .compare { setBottomDock(false) }
        }
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

    /// What the compare tab says (for scripted checks).
    var compareText: String { bottomDock.compareText }

    private func scheduleCompare(after delay: TimeInterval = 0.5) {
        guard comparing, !compareScheduled else { return }
        compareScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let running = Engine.shared.simulators.filter { $0.state == .running }
            guard self.comparing, let base = self.live, running.count > 1 else {
                self.compareScheduled = false
                if self.comparing {
                    self.bottomDock.setCompareSummary(text: "Compare: open a second simulator (File > Compare With APK…, or the device menu's Open Beside As).", items: [], counts: (0, 0, 0))
                }
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
        var diffItems: [CompareDiffItem] = []
        var totalAdded = 0, totalRemoved = 0, totalMoved = 0
        func rect(_ n: ScreenNode) -> CGRect { CGRect(x: n.left, y: n.top, width: n.right - n.left, height: n.bottom - n.top) }
        for (other, c) in results {
            baseBoxes += c.onlyA.map(rect) + c.moved.map { rect($0.a) }
            if let v = grid.view(for: other) {
                v.boxes = c.onlyB.map(rect) + c.moved.map { rect($0.b) }
                v.areas = c.cells
            }
            totalAdded += c.onlyA.count
            totalRemoved += c.onlyB.count
            totalMoved += c.moved.count
            var baseLabel = base.effectiveLabel
            var otherLabel = other.effectiveLabel
            if baseLabel == otherLabel {
                baseLabel += " (base)"
                otherLabel += " (compare)"
            }
            for n in c.onlyA.prefix(12) {
                diffItems.append(CompareDiffItem(symbol: "+", title: n.label.isEmpty ? "(unlabeled)" : n.label, detail: "Only in \(baseLabel)", rect: rect(n), isAdded: true, simulator: base))
            }
            for n in c.onlyB.prefix(12) {
                diffItems.append(CompareDiffItem(symbol: "−", title: n.label.isEmpty ? "(unlabeled)" : n.label, detail: "Only in \(otherLabel)", rect: rect(n), isAdded: false, simulator: other))
            }
            for pair in c.moved.prefix(12) {
                let dx = pair.b.left - pair.a.left, dy = pair.b.top - pair.a.top
                diffItems.append(CompareDiffItem(symbol: "↔", title: pair.a.label.isEmpty ? "(unlabeled)" : pair.a.label, detail: "Moved (\(dx >= 0 ? "+\(dx)" : "\(dx)"), \(dy >= 0 ? "+\(dy)" : "\(dy)")) px", rect: rect(pair.a), isAdded: false, simulator: base))
            }
            let size = other.deviceSize
            text.append("\(baseLabel) → \(otherLabel) \(Int(size.width))×\(Int(size.height)): \(c.summary)")
            text += c.lines(limit: 5).map { "  " + $0 }
        }
        grid.view(for: base)?.boxes = baseBoxes
        grid.view(for: base)?.areas = []
        bottomDock.setCompareSummary(text: text.joined(separator: "\n"), items: diffItems, counts: (totalAdded, totalRemoved, totalMoved))
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
        while let o = rest.popFirst() {
            if o == "--device" { _ = rest.popFirst(); continue }
            // The new device picks its own data (DeviceData); a session's slot stays with it.
            if o == "--data-slots", DeviceData.isOurs(rest.first) { _ = rest.popFirst(); continue }
            if o == "--fresh" { continue }
            options.append(o)
        }
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
        guard agentPanel != nil else { return }
        show(showingAgent ? nil : .agent, closing: .agent)
    }

    func agentChanged() {
        agentPanel?.refresh()
        updateAgentHud()
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
