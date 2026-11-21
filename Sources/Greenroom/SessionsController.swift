import AppKit

/// The "Sessions" section of the sidebar: a row per git worktree of each repository the person added.
/// Owns the workspaces, the rows' data (from `Git` and the worktrees' Gradle outputs), the simulators that belong
/// to them (each with its own data slot, the last few kept alive), their reload when a build lands, the ⌃1-9 and
/// ⌃Tab shortcuts and the palette entries. `Workbench` only draws what this hands it.
final class SessionsController {
    private(set) weak var workbench: Workbench?
    private(set) var store = SessionStore.shared
    private(set) var workspaces: [Workspace] = []
    /// Every worktree of every workspace, in the order shown (each workspace's main checkout first).
    private(set) var sessions: [Session] = []
    /// Worktree paths, most recently used first.
    private(set) var used: [String] = []
    /// The newest recorded build of each worktree (by its path).
    private var builds: [String: Build] = [:]
    private var watchers: [String: WorktreeWatcher] = [:]
    private var buildWatcher: BuildWatcher?
    private var watched: [String] = []
    private var generation = 0
    /// Slots whose simulator is to start as soon as the one that held the slot has exited.
    private var starting = Set<String>()
    private static let noGit = "Sessions needs git: install the Command Line Tools (xcode-select --install)"
    /// The modified time of the file each session's simulator was last started from. An event for a file that is
    /// no newer (the system touching a file it has just read or cloned) is not a build.
    private var launched: [String: Date] = [:]
    private var monitor: Any?

    /// Told on the main thread when the rows changed.
    var onChange: (() -> Void)?
    /// Told after each reload a new build made, with the session and the simulator that replaced the old one.
    var onReload: ((Session, Simulator) -> Void)?

    /// How many sessions' simulators stay alive; the least recently used quits beyond that.
    var warmLimit: Int {
        get { max(1, UserDefaults.standard.object(forKey: "sessionsWarm") as? Int ?? 3) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: "sessionsWarm") }
    }

    // MARK: Install

    func install(workbench: Workbench) {
        self.workbench = workbench
        workspaces = store.loadWorkspaces()
        DevHooks.shared.owns = { [weak self] sim in self?.session(forSimulator: sim) != nil }   // reloaded here, once
        // ⌘1-9 and ⌥⌘Tab. A monitor, not menu items: the number of sessions changes. Command keys are never sent to
        // the device (SimulatorView), so these leave the keys the app under test may use (⌃1, ⌃Tab...) alone.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak workbench] event in
            guard let self, let workbench, event.window === workbench.window else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command, .option], event.keyCode == 48 { return self.switchToLast() ? nil : event }   // Tab
            if flags == .command, let c = event.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) { return self.switchTo(n - 1) ? nil : event }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()   // edits made elsewhere (dirty files) are not watched; looking again when the app is shown is enough
        }
        refresh()
    }

    /// Uses another store (the check's own, so a check never touches the person's workspaces).
    func use(store: SessionStore) {
        self.store = store
        workspaces = store.loadWorkspaces()
        builds = [:]
        refresh()
    }

    // MARK: Workspaces

    /// File > Add Repository...
    func chooseRepository() {
        guard let window = workbench?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose a git repository: each of its worktrees becomes a session"
        panel.prompt = "Add"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK else { return }
            self?.addRepositories(panel.urls)
        }
    }

    func addRepositories(_ folders: [URL]) {
        for f in folders { addRepository(f) }
    }

    /// Adds the repository `folder` is in (a worktree of it is as good as the main checkout). Gives the main
    /// checkout it resolved to, or nil with a toast when it is not a repository.
    @discardableResult
    func addRepository(_ folder: URL) -> Task<URL?, Never> {
        Task { @MainActor in
            guard let root = await Git.mainCheckout(of: folder)?.resolvingSymlinksInPath() else {
                self.workbench?.toast.show(Git.available ? "\(folder.lastPathComponent) is not in a git repository" : Self.noGit, problem: true)
                return nil
            }
            if self.workspaces.contains(where: { $0.root == root }) {
                self.workbench?.toast.show("\(root.lastPathComponent) is already in Sessions")
            } else {
                self.workspaces.append(Workspace(root: root))
                self.store.saveWorkspaces(self.workspaces)
                self.workbench?.toast.show("Added \(root.lastPathComponent)")
                self.workbench?.showLibrary()
            }
            self.refresh()
            return root
        }
    }

    func removeWorkspace(containing session: Session) {
        workspaces.removeAll { $0.root.path == session.workspace.path }
        store.saveWorkspaces(workspaces)
        refresh()
    }

    /// The folders of a drag (files are not repositories).
    static func folders(in info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // MARK: Rows

    /// Re-reads git and the Gradle outputs of every worktree. Overlapping calls: the last one's answer is used.
    func refresh() {
        generation += 1
        let mine = generation
        let spaces = workspaces
        let known = builds
        let before = sessions
        Task { @MainActor in
            var all: [Session] = []
            var live = Set<String>()
            var complete = Git.available
            for ws in spaces {
                let list = await Git.worktrees(of: ws.root)
                if list.isEmpty { complete = false }   // git failed, or the repository moved: do not judge by it
                for wt in list {
                    live.insert(wt.path.path)
                    let path = wt.path
                    let outputs = await Task.detached(priority: .utility) { SessionStore.newestAPK(in: path) }.value
                    if let state = await Git.state(of: wt.path) {
                        all.append(Session(worktree: wt.path, workspace: ws.root, branch: state.branch, head: state.head, dirty: state.dirty,
                                           ahead: state.ahead, claude: nil, build: known[wt.path.path], simulator: nil,
                                           outputs: outputs, sourcesDate: state.sourcesDate))
                    } else if var old = before.first(where: { $0.worktree.path == wt.path.path }) {
                        // One failed call (a lock, a busy disk) must not drop the row, and with it the simulator's.
                        old.outputs = outputs
                        old.build = known[wt.path.path]
                        all.append(old)
                    }
                }
            }
            guard mine == self.generation else { return }
            self.sessions = all
            self.watch(all)
            self.onChange?()
            if complete {
                let store = self.store
                DispatchQueue.global(qos: .utility).async { store.prune(live: live) }
            }
        }
    }

    /// The rows by repository, with each session's simulator (when one is alive) attached.
    func groups() -> [(header: String, sessions: [Session])] {
        var out: [(String, [Session])] = []
        if !workspaces.isEmpty, !Git.available { return [(Self.noGit, [])] }
        for ws in workspaces {
            let rows = sessions.filter { $0.workspace.path == ws.root.path }.map { s -> Session in var s = s; s.simulator = simulator(for: s); return s }
            if rows.isEmpty { continue }
            out.append((workspaces.count > 1 ? "Sessions: \(ws.root.lastPathComponent)" : "Sessions", rows))
        }
        return out
    }

    func session(forSimulator sim: Simulator) -> Session? {
        guard let slot = Self.slot(of: sim) else { return nil }
        return sessions.first { $0.slot == slot }
    }

    /// The live simulator started for a session, found by its data slot (a reload replaces the object, not the slot).
    func simulator(for session: Session) -> Simulator? {
        Engine.shared.simulators.first { $0.isAlive && Self.slot(of: $0) == session.slot }
    }

    static func slot(of sim: Simulator) -> String? { DevHooks.value("--data-slots", in: sim.options) }

    // MARK: Switching

    /// Selects the session's simulator, or starts one from its newest build. Returns whether anything happened.
    @discardableResult
    func activate(_ session: Session) -> Bool {
        guard let wb = workbench else { return false }
        if let sim = simulator(for: session) {
            wb.select(sim)
            noteUsed(session.worktree.path)
            return true
        }
        // The newest output if it is still there (`gradle clean` deletes it without an event), else the stored build.
        let fm = FileManager.default
        guard let apk = [session.outputs?.apk, session.build?.apk, builds[session.worktree.path]?.apk].compactMap({ $0 }).first(where: { fm.fileExists(atPath: $0.path) }) else {
            wb.toast.show("\(session.title) has no build yet. Build it, and it appears here.", problem: true)
            refresh()
            return false
        }
        for stale in Engine.shared.simulators where !stale.isAlive && Self.slot(of: stale) == session.slot { Engine.shared.close(stale) }
        noteUsed(session.worktree.path)
        // A simulator taken off the stage a moment ago may still hold the slot; one started now would get another.
        if let old = Engine.shared.closing.first(where: { Self.slot(of: $0) == session.slot }) {
            guard !starting.contains(session.slot) else { return true }
            starting.insert(session.slot)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                old.waitUntilExit()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.starting.remove(session.slot)
                    if self.simulator(for: session) == nil { self.start(session, from: apk) }
                }
            }
            return true
        }
        return start(session, from: apk)
    }

    @discardableResult
    private func start(_ session: Session, from apk: URL) -> Bool {
        guard let wb = workbench, wb.open(apk, remember: false, options: ["--data-slots", session.slot]) != nil else { return false }
        launched[session.slot] = Self.modified(apk)
        record(apk: apk, for: session)
        enforceWarmLimit(keeping: session.worktree.path)
        return true
    }

    /// ⌃n: the n-th row (0-based) of every repository's sessions, in the order shown.
    @discardableResult
    func switchTo(_ index: Int) -> Bool {
        let rows = groups().flatMap(\.sessions)
        guard rows.indices.contains(index) else { return false }
        return activate(rows[index])
    }

    /// ⌃Tab: the session used before this one.
    @discardableResult
    func switchToLast() -> Bool {
        guard used.count > 1, let s = sessions.first(where: { $0.worktree.path == used[1] }) else { return false }
        return activate(s)
    }

    /// Called by the workbench whenever a simulator is selected, however it came to be.
    func selected(_ sim: Simulator?) {
        guard let sim, let s = session(forSimulator: sim) else { return }
        noteUsed(s.worktree.path)
    }

    private func noteUsed(_ path: String) {
        used.removeAll { $0 == path }
        used.insert(path, at: 0)
    }

    func closeSimulator(of session: Session) {
        if let sim = simulator(for: session) { Engine.shared.close(sim) }
    }

    /// Quits the least recently used sessions' simulators beyond the limit. Their data stays in their slots.
    func enforceWarmLimit(keeping keep: String? = nil) {
        let warm = sessions.compactMap { s in simulator(for: s).map { (s, $0) } }
        let over = warm.count - warmLimit
        guard over > 0 else { return }
        let rank = { (s: Session) in self.used.firstIndex(of: s.worktree.path) ?? Int.max }   // larger: used longer ago
        let victims = warm.filter { $0.0.worktree.path != keep }.sorted { rank($0.0) > rank($1.0) }.prefix(over)
        for (s, sim) in victims {
            workbench?.toast.show("\(s.title) simulator quit: more than \(warmLimit) kept running. Its data is kept.")
            Engine.shared.close(sim)
        }
    }

    // MARK: Builds

    private func record(apk: URL, for session: Session) {
        let store = self.store, sha = session.head, ref = session.branch, dirty = session.dirty, path = session.worktree.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let build = store.record(apk: apk, source: .local, sha: sha, ref: ref, dirty: dirty) else { return }
            store.note(build: build.key, of: path)
            DispatchQueue.main.async { self?.builds[path] = build; self?.onChange?() }
        }
    }

    /// One FSEvents stream over every worktree, and one `WorktreeWatcher` per repository.
    private func watch(_ all: [Session]) {
        let roots = Set(workspaces.map(\.root.path))
        for (path, w) in watchers where !roots.contains(path) { w.stop(); watchers[path] = nil }
        for ws in workspaces where watchers[ws.root.path] == nil {
            let w = WorktreeWatcher(repo: ws.root)
            w.onChange = { [weak self] in self?.refresh() }
            if w.start() { watchers[ws.root.path] = w }
        }
        let paths = all.map(\.worktree.path).sorted()
        guard paths != watched else { return }
        watched = paths
        buildWatcher?.stop()
        buildWatcher = nil
        guard !paths.isEmpty else { return }
        let b = BuildWatcher(folders: paths.map { URL(fileURLWithPath: $0, isDirectory: true) }, name: nil)
        b.onBuild = { [weak self] apk in self?.built(apk) }
        if b.start() { buildWatcher = b }
    }

    /// An APK settled somewhere under a worktree: that session's simulator, if it runs this file, reloads on it
    /// (same options and data, through the developer hooks' relaunch), whether or not it is the selected one.
    private func built(_ apk: URL) {
        let file = apk.resolvingSymlinksInPath()
        // The worktree holding the file; with worktrees inside one another (a main checkout holding its linked
        // ones), the deepest. Only what Gradle leaves in build/outputs/apk is a build.
        let owner = sessions.filter { file.path.hasPrefix($0.worktree.resolvingSymlinksInPath().path + "/") }
            .max { $0.worktree.path.count < $1.worktree.path.count }
        guard let session = owner, SessionStore.isBuildOutput(file, in: session.worktree) else { return }
        record(apk: file, for: session)
        if let old = simulator(for: session), old.apk.resolvingSymlinksInPath().path == file.path,
           Self.modified(file) > launched[session.slot] ?? .distantPast {
            launched[session.slot] = Self.modified(file)
            DevHooks.shared.relaunch(old, apk: file, options: old.options) { [weak self] new in
                guard let self, let new else { return }
                self.workbench?.toast.show("Reloaded \(session.title) on its new build")
                self.onReload?(session, new)
            }
        }
        refresh()
    }

    // MARK: Palette

    func paletteItems() -> [PaletteItem] {
        var out: [PaletteItem] = []
        for (i, s) in groups().flatMap(\.sessions).enumerated() {
            let kind = s.simulator != nil ? "running" : (s.outputs == nil ? "no build" : "start")
            out.append(PaletteItem(id: "session." + s.worktree.path, title: "Go to session \(s.title) (\(kind))", group: "Sessions",
                                   symbol: "arrow.triangle.branch", shortcut: i < 9 ? "⌘\(i + 1)" : "",
                                   keywords: "worktree branch change \(s.shortHead) \(s.worktree.lastPathComponent)") { [weak self] in self?.activate(s) })
        }
        out.append(PaletteItem(id: "session.add", title: "Add a repository to Sessions…", group: "Sessions", symbol: "plus.rectangle.on.folder",
                               keywords: "git worktree folder") { [weak self] in self?.chooseRepository() })
        return out
    }

    // MARK: Row view

    func cell(for s: Session) -> NSView {
        let sim = s.simulator
        let running = sim?.state == .running
        let icon = NSImageView(image: NSImage(systemSymbolName: sim == nil ? "circle" : (running ? "circle.fill" : "circle.dotted"), accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = running ? .systemGreen : .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: s.title)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        var detail = [s.shortHead]
        if let o = s.outputs { detail.append(Self.age(o.date)) }
        if s.ahead > 0 { detail.append("\(s.ahead) ahead") }
        if s.dirty { detail.append("edited") }
        let sub = NSTextField(labelWithString: detail.joined(separator: " · "))
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, text]
        if s.outputs == nil || s.isStale {
            let badge = NSTextField(labelWithString: s.outputs == nil ? "no build" : "stale")
            badge.font = .systemFont(ofSize: 9, weight: .semibold)
            badge.textColor = s.outputs == nil ? .secondaryLabelColor : .systemOrange
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(badge)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        return stack
    }

    private static func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func age(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return "built " + f.localizedString(for: date, relativeTo: Date())
    }
}
