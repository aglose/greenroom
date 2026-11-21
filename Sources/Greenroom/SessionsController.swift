import AppKit

/// The "Sessions" section of the sidebar: a row per git worktree of each repository the person added.
/// Owns the workspaces, the rows' data (from `Git` and the worktrees' Gradle outputs), the simulators that belong
/// to them (each with its own data slot, the last few kept alive), their reload when a build lands, the ⌃1-9 and
/// ⌃Tab shortcuts and the palette entries. `Workbench` only draws what this hands it.
final class SessionsController {
    private(set) weak var workbench: Workbench?
    private(set) var store = SessionStore.shared
    var workspaces: [Workspace] = []
    /// Every worktree of every workspace, in the order shown (each workspace's main checkout first).
    private(set) var sessions: [Session] = []
    /// Worktree paths, most recently used first.
    private(set) var used: [String] = []
    /// The newest recorded build of each worktree (by its path).
    private(set) var builds: [String: Build] = [:]
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
    /// The build queue (Builds.swift); its rows and buttons are BuildsUI.swift.
    private(set) lazy var buildQueue = Builds(sessions: self)
    /// Pull requests without a worktree, the Review section (PullRequests.swift).
    private(set) lazy var pulls = PullRows(sessions: self)
    /// The walk and capture queue (Evidence.swift): every new build of a session is walked in the background.
    let evidence = Evidence()

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
        evidence.controller = self
        evidence.store = store
        evidence.onChange = { [weak self] in self?.onChange?() }
        evidence.clickedSession = { [weak workbench] in workbench?.clickedSession }
        evidence.shouldPause = { [weak self] owner in self?.walkShouldWait(owner) ?? false }
        evidence.watchInput()
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
        installBuilds()
        let claude = ClaudeSessions.shared   // W1: Claude Code's sessions, behind the switch in Settings
        claude.workspaceRoots = { [weak self] in self?.workspaces.map(\.root) ?? [] }
        claude.onChange = { [weak self] in self?.applyClaude() }
        claude.changedSwitch()
        refresh()
    }

    /// Hands every row its Claude session (or takes it away) without asking git again. Says nothing when no row's
    /// session changed in a way the row shows.
    func applyClaude() {
        let next = ClaudeSessions.shared.attach(sessions)
        let changed = next.map { $0.claude?.shown } != sessions.map { $0.claude?.shown }
        sessions = next
        if autoArchive() || changed { onChange?() }
    }

    /// Uses another store (the check's own, so a check never touches the person's workspaces).
    func use(store: SessionStore) {
        self.store = store
        evidence.store = store
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
                ClaudeSessions.shared.workspacesChanged()
                self.workbench?.toast.show("Added \(root.lastPathComponent)")
                self.workbench?.showLibrary()
            }
            self.refresh()
            return root
        }
    }

    func removeWorkspace(containing session: Session) {
        for s in sessions where s.workspace.path == session.workspace.path { evidence.forget(worktree: s.worktree.path) }
        workspaces.removeAll { $0.root.path == session.workspace.path }
        store.saveWorkspaces(workspaces)
        ClaudeSessions.shared.workspacesChanged()
        refresh()
    }

    // MARK: Which rows show

    /// Whether the sidebar has the session: the person added it, or its simulator runs or a build of it is under way
    /// (what Greenroom is doing with it is never out of sight).
    func isShown(_ s: Session) -> Bool {
        if workspace(of: s)?.shown.contains(s.worktree.path) == true { return true }
        return simulator(for: s) != nil || (buildQueue.job(for: s)?.isActive ?? false)
    }

    /// Worth suggesting: not shown, not put away, and a Claude session is at work in it or it has an open pull request.
    func isSuggested(_ s: Session) -> Bool {
        guard !isShown(s), let ws = workspace(of: s), !ws.hidden.contains(s.worktree.path), !ws.archived.contains(s.worktree.path) else { return false }
        return s.claudeActive || s.hasOpenPR
    }

    /// The suggestions, active ones first.
    func suggestions() -> [Session] {
        sessions.filter(isSuggested).sorted { (Self.tier($0, live: false), $0.title) < (Self.tier($1, live: false), $1.title) }
    }

    /// The order rows show in: something running first (a simulator, a Claude session, a build), then an open pull
    /// request, then the rest; within each, the order they were added in (newest first). Coarse on purpose: a status
    /// that flickers does not make rows jump.
    private static func tier(_ s: Session, live: Bool) -> Int {
        if live || s.claudeActive { return 0 }
        return s.hasOpenPR ? 1 : 2
    }

    /// Puts the session in the sidebar, at the top.
    func show(_ s: Session) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == s.workspace.path }) else { return }
        let path = s.worktree.path
        guard !workspaces[i].shown.contains(path) else { return }
        workspaces[i].shown.insert(path, at: 0)
        workspaces[i].hidden.removeAll { $0 == path }
        workspaces[i].archived.removeAll { $0 == path }
        store.saveWorkspaces(workspaces)
        onChange?()
    }

    /// Shows every worktree of the session's repository.
    func showAll(in workspace: URL) {
        for s in sessions where s.workspace.path == workspace.path { show(s) }
    }

    /// Takes the session out of the sidebar and quits its simulator (its data stays in its slot). It is not suggested
    /// again; the + menu has it.
    func remove(_ s: Session) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == s.workspace.path }) else { return }
        let path = s.worktree.path
        workspaces[i].shown.removeAll { $0 == path }
        if !workspaces[i].hidden.contains(path) { workspaces[i].hidden.append(path) }
        store.saveWorkspaces(workspaces)
        closeSimulator(of: s)
        onChange?()
    }

    /// Whether sessions whose pull request merged leave the sidebar by themselves.
    static let autoArchiveKey = "sessionsAutoArchive"
    var autoArchiveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoArchiveKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoArchiveKey); if newValue, autoArchive() { onChange?() } }
    }

    /// Archives the shown sessions whose pull requests have all closed with one merged, unless something is still
    /// going on in them (a simulator, a build, a Claude session that runs) or they are a main checkout. Returns
    /// whether one was archived.
    @discardableResult
    func autoArchive() -> Bool {
        guard autoArchiveEnabled else { return false }
        var done: [Session] = []
        for s in sessions where !s.isMain && s.prMerged && !s.claudeActive && !(s.claude?.running ?? false) {
            guard let i = workspaces.firstIndex(where: { $0.root.path == s.workspace.path }), workspaces[i].shown.contains(s.worktree.path),
                  simulator(for: s) == nil, !(buildQueue.job(for: s)?.isActive ?? false) else { continue }
            workspaces[i].shown.removeAll { $0 == s.worktree.path }
            workspaces[i].archived.append(s.worktree.path)
            done.append(s)
        }
        guard !done.isEmpty else { return false }
        store.saveWorkspaces(workspaces)
        let what = done.count == 1 ? "\(done[0].title): its pull request merged" : "\(done.count) sessions whose pull requests merged"
        workbench?.toast.show("Archived \(what). The + menu brings it back.")
        return true
    }

    /// The + menu of a repository's header: the sessions it does not show, active ones first, then the archived.
    func addMenu(for workspace: URL) -> NSMenu {
        let menu = NSMenu()
        let rest = sessions.filter { $0.workspace.path == workspace.path && !isShown($0) }
        let archived = Set(self.workspace(at: workspace)?.archived ?? [])
        func item(_ s: Session) -> NSMenuItem {
            var bits: [String] = []
            if let n = s.pullRequests.first(where: { $0.state == .open })?.number { bits.append("#\(n) open") }
            else if let n = s.pullRequests.first?.number { bits.append("#\(n)") }
            if s.claude?.status == .working && s.claude?.running == true { bits.append("Claude working") }
            else if s.claude?.status == .waiting { bits.append("waiting for you") }
            let i = ClosureMenuItem(s.title + (bits.isEmpty ? "" : "  ·  " + bits.joined(separator: " · "))) { [weak self] in self?.show(s) }
            i.toolTip = (s.worktree.path as NSString).abbreviatingWithTildeInPath
            return i
        }
        let active = rest.filter { ($0.claudeActive || $0.hasOpenPR) && !archived.contains($0.worktree.path) }
        let others = rest.filter { !($0.claudeActive || $0.hasOpenPR) && !archived.contains($0.worktree.path) }
        let gone = rest.filter { archived.contains($0.worktree.path) }
        func section(_ title: String, _ list: [Session]) {
            guard !list.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            if #available(macOS 14.0, *) { menu.addItem(.sectionHeader(title: title)) } else { menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false }
            list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.forEach { menu.addItem(item($0)) }
        }
        section("Active or with an open pull request", active)
        section("Other worktrees", others)
        section("Archived", gone)
        if menu.items.isEmpty { menu.addItem(withTitle: "Every worktree is in the sidebar", action: nil, keyEquivalent: "").isEnabled = false }
        menu.addItem(.separator())
        if rest.count > 1 { menu.addItem(ClosureMenuItem("Show All \(rest.count)") { [weak self] in self?.showAll(in: workspace) }) }
        menu.addItem(ClosureMenuItem("Add Repository…") { [weak self] in self?.chooseRepository() })
        return menu
    }

    private func workspace(at root: URL) -> Workspace? { workspaces.first { $0.root.path == root.path } }

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
            if complete { for old in before where !live.contains(old.worktree.path) { self.evidence.forget(worktree: old.worktree.path) } }
            self.sessions = ClaudeSessions.shared.attach(all)
            self.watch(all)
            if complete { self.autoArchive() }
            self.onChange?()
            if complete {
                let store = self.store
                DispatchQueue.global(qos: .utility).async { store.prune(live: live) }
                self.evidence.pruneToCap()
            }
        }
    }

    /// The rows the sidebar shows, by repository, with each session's simulator (when one is alive) attached, in the
    /// order of `tier`. `hidden` is how many of the repository's worktrees are a + away.
    func groups() -> [(header: String, workspace: URL?, sessions: [Session], hidden: Int)] {
        var out: [(String, URL?, [Session], Int)] = []
        if !workspaces.isEmpty, !Git.available { return [(Self.noGit, nil, [], 0)] }
        for ws in workspaces {
            let all = sessions.filter { $0.workspace.path == ws.root.path }
            if all.isEmpty { continue }
            let order = Dictionary(ws.shown.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let rows = all.filter(isShown).map { s -> Session in var s = s; s.simulator = simulator(for: s); return s }
                .sorted { a, b in
                    let ka = (Self.tier(a, live: a.simulator != nil), order[a.worktree.path] ?? -1)
                    let kb = (Self.tier(b, live: b.simulator != nil), order[b.worktree.path] ?? -1)
                    return ka < kb
                }
            out.append((workspaces.count > 1 ? ws.root.lastPathComponent : "Sessions", ws.root, rows, all.count - rows.count))
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
        guard let apk = newestAPK(for: session) else {
            wb.toast.show("\(session.title) has no build yet. Build it, and it appears here.", problem: true)
            refresh()
            return false
        }
        for stale in Engine.shared.simulators where !stale.isAlive && Self.slot(of: stale) == session.slot { Engine.shared.close(stale) }
        noteUsed(session.worktree.path)
        // A simulator taken off the stage a moment ago may still hold the slot; one started now would get another.
        if let old = holder(of: session.slot) {
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
        return start(session, from: apk) != nil
    }

    /// The newest of the worktree's Gradle output and the stored builds (a recipe's) that is still there
    /// (`gradle clean` deletes an output without an event).
    func newestAPK(for session: Session) -> URL? {
        let fm = FileManager.default
        let candidates: [(URL, Date)] = [session.outputs.map { ($0.apk, $0.date) }, session.build.map { ($0.apk, $0.date) },
                                         builds[session.worktree.path].map { ($0.apk, $0.date) }].compactMap { $0 }
        return candidates.filter { fm.fileExists(atPath: $0.0.path) }.max(by: { $0.1 < $1.1 })?.0
    }

    /// A simulator taken off the stage that has not yet exited and so still holds the slot's lock.
    func holder(of slot: String) -> Simulator? { Engine.shared.closing.first { Self.slot(of: $0) == slot } }

    /// For an agent's `launch` (called on the main thread, after it has waited for `holder(of:)` to exit): starts the
    /// session's simulator from `apk` in its slot, with `options`.
    func startForAgent(_ session: Session, from apk: URL, options: [String]) -> Simulator? {
        for stale in Engine.shared.simulators where !stale.isAlive && Self.slot(of: stale) == session.slot { Engine.shared.close(stale) }
        noteUsed(session.worktree.path)
        return start(session, from: apk, options: options, fromAgent: true, remember: true)
    }

    @discardableResult
    private func start(_ session: Session, from apk: URL, options: [String] = [], fromAgent: Bool = false, remember: Bool = false) -> Simulator? {
        guard let wb = workbench, let sim = wb.open(apk, remember: remember, options: ["--data-slots", session.slot] + options, fromAgent: fromAgent) else { return nil }
        launched[session.slot] = Self.modified(apk)
        show(session)   // started from the palette, ⌘n or an agent: it is in use, so it is in the sidebar
        record(apk: apk, for: session)
        enforceWarmLimit(keeping: session.worktree.path)
        return sim
    }

    /// The session whose worktree is `folder` (a path `git rev-parse --show-toplevel` gave), symlinks resolved.
    func session(atWorktree folder: URL) -> Session? {
        let want = folder.resolvingSymlinksInPath().path
        return sessions.first { $0.worktree.resolvingSymlinksInPath().path == want }
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
            DispatchQueue.main.async {
                // Builds are filed on a concurrent queue and may arrive reversed: the newer one stays.
                if let have = self?.builds[path], have.date > build.date { return }
                self?.builds[path] = build
                self?.onChange?()
                self?.buildArrivedForEvidence(path, build)
            }
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
        // A recipe is building this session: when it finishes, `adopt` reloads the simulator once, on the filed build.
        if buildQueue.isBuilding(session.worktree.path) { return }
        record(apk: file, for: session)
        if let old = simulator(for: session), old.apk.resolvingSymlinksInPath().path == file.path,
           Self.modified(file) > launched[session.slot] ?? .distantPast {
            reload(old, of: session, to: file)
        }
        refresh()
    }

    /// The one place a session's simulator is replaced by a new build of it (same options, same data slot). Where hot
    /// swap's swap -> recreate -> relaunch ladder plugs in.
    private func reload(_ old: Simulator, of session: Session, to apk: URL) {
        launched[session.slot] = Self.modified(apk)
        DevHooks.shared.relaunch(old, apk: apk, options: old.options) { [weak self] new in
            guard let self, let new else { return }
            self.workbench?.toast.show("Reloaded \(session.title) on its new build")
            self.onReload?(session, new)
        }
    }

    /// A build a recipe made, filed in the store: it is the session's newest, and its simulator (if one is alive,
    /// selected or not) reloads on it with its data kept. A build the simulator already runs reloads nothing.
    func adopt(_ build: Build, forWorktree path: String) {
        builds[path] = build
        buildArrivedForEvidence(path, build)
        if let session = sessions.first(where: { $0.worktree.path == path }), let old = simulator(for: session),
           old.apk.resolvingSymlinksInPath().path != build.apk.resolvingSymlinksInPath().path {
            reload(old, of: session, to: build.apk)
        }
        refresh()
    }

    // MARK: Evidence

    /// A build of the session was filed (a rebuild landed, or a session with a build was started).
    private func buildArrivedForEvidence(_ worktree: String, _ build: Build) {
        guard let s = sessions.first(where: { $0.worktree.path == worktree }) else { return }
        evidence.buildArrived(worktree: worktree, build: build, auto: auto(of: s), withData: walksWithData(s))
    }

    /// Whether a queued walk is held back now: a recipe of its workspace is building, or the person is using a
    /// simulator (it starts by itself later).
    private func walkShouldWait(_ owner: String) -> Bool {
        if evidence.interacting { return true }
        if Engine.shared.simulators.contains(where: { ScreenRecording.shared.recorder(for: $0) != nil && !AgentRecording.isAgentTake($0) }) { return true }   // the person is recording (an agent's take is not)
        guard let s = sessions.first(where: { $0.worktree.path == owner }) else { return false }
        return buildQueue.isBuilding(workspace: s.workspace.path)
    }

    func walksWithData(_ s: Session) -> Bool { workspaces.first { $0.root.path == s.workspace.path }?.walkWithData ?? false }

    func setWalkWithData(_ on: Bool, for s: Session) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == s.workspace.path }) else { return }
        workspaces[i].walkWithData = on
        store.saveWorkspaces(workspaces)
        onChange?()
    }

    func auto(of s: Session) -> Auto { workspaces.first { $0.root.path == s.workspace.path }?.auto ?? .onBuild }
    func hasBuild(_ s: Session) -> Bool { (builds[s.worktree.path] ?? s.build) != nil }

    func setAuto(_ auto: Auto, for s: Session) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == s.workspace.path }) else { return }
        workspaces[i].auto = auto
        store.saveWorkspaces(workspaces)
        onChange?()
    }

    func walkAgain(_ s: Session) {
        guard let b = builds[s.worktree.path] ?? s.build else { return }
        evidence.walkAgain(worktree: s.worktree.path, build: b, withData: walksWithData(s))
    }

    func stopWalking(_ s: Session) { evidence.stop(worktree: s.worktree.path) }

    /// The Screen Map sheet on a finished run of the evidence folder.
    func openMap(folder: URL) {
        guard let wb = workbench else { return }
        wb.showMap()
        if !wb.screenMap.show(folder: folder) { wb.toast.show("That map is not there any more. \"Walk again\" makes it.", problem: true) }
    }

    // MARK: Palette

    func paletteItems() -> [PaletteItem] {
        var out: [PaletteItem] = []
        let rows = groups().flatMap(\.sessions)
        let shown = Set(rows.map(\.worktree.path))
        for (i, s) in (rows + sessions.filter { !shown.contains($0.worktree.path) }).enumerated() {
            let kind = s.simulator != nil ? "running" : (s.outputs == nil ? "no build" : "start")
            out.append(PaletteItem(id: "session." + s.worktree.path, title: "Go to session \(s.title) (\(kind))", group: "Sessions",
                                   symbol: "arrow.triangle.branch", shortcut: i < min(9, rows.count) ? "⌘\(i + 1)" : "",
                                   keywords: "worktree branch change \(s.shortHead) \(s.worktree.lastPathComponent)") { [weak self] in self?.activate(s) })
        }
        out.append(PaletteItem(id: "session.add", title: "Add a repository to Sessions…", group: "Sessions", symbol: "plus.rectangle.on.folder",
                               keywords: "git worktree folder") { [weak self] in self?.chooseRepository() })
        out += changesPaletteItems()   // Changes: this session's build against a base (ChangesSheet.swift)
        out += buildPaletteItems()   // Build this session, Cancel build (BuildsUI.swift)
        out += recipePaletteItems()  // Add pull request, Prepare remote builder, Build settings (RecipesUI.swift)
        return out
    }

    // MARK: Row view

    /// The second line of a row: what tells it apart (its pull request), then where its build is.
    private func detail(for s: Session) -> (text: String, color: NSColor?) {
        var bits: [String] = []
        if let pr = s.pullRequests.first(where: { $0.state == .open }) ?? s.pullRequests.first, let n = pr.number {
            bits.append("#\(n)" + (pr.state == .merged ? " merged" : pr.state == .closed ? " closed" : ""))
        } else if let pr = s.claude?.pullRequest, let n = Int(pr.lastPathComponent) { bits.append("#\(n)") }
        if let built = s.builtAt { bits.append(Self.age(built) + (s.isStale ? ", stale" : "")) } else { bits.append("not built") }
        if s.dirty { bits.append("edited") }
        if workspace(of: s)?.defaultRecipeName == "ci", let behind = CIBehind.note(for: s, store: store, then: { [weak self] in self?.onChange?() }) { bits.append(behind) }
        return (bits.joined(separator: " · "), nil)
    }

    /// Everything a session's row shows, as one string: the sidebar rebuilds a row only when this changed.
    func rowKey(for s: Session) -> String {
        let job = buildQueue.job(for: s)
        let jobKey = job.map { "\($0.id)|\($0.state == .queued)|\($0.isActive)|\($0.lastLine ?? "")|\($0.failure ?? "")" } ?? "-"
        let sim = s.simulator.map { $0.state == .running ? "run" : "on" } ?? "off"
        let c = s.claude.map { "\($0.status)|\($0.running)|\($0.archived)" } ?? "-"
        return [s.title, detail(for: s).text, sim, c, jobKey, evidence.badgeKey(for: s), workspace(of: s)?.defaultRecipeName ?? ""].joined(separator: "\u{1f}")
    }

    func cell(for s: Session) -> NSView {
        let sim = s.simulator
        let running = sim?.state == .running
        let icon = NSImageView(image: NSImage(systemSymbolName: sim == nil ? "circle" : (running ? "circle.fill" : "circle.dotted"), accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = running ? .systemGreen : .tertiaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: s.title)
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        // The branch, the head's hash and the commits ahead are in the tooltip: the row keeps to what tells it apart.
        let build = buildAccessories(for: s)
        let line = detail(for: s)
        let sub = NSTextField(labelWithString: build.detail ?? line.text)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = build.color ?? (s.isStale && s.builtAt != nil ? .systemOrange : .secondaryLabelColor)
        sub.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, text]
        if let dot = ClaudeUI.dot(for: s.claude), s.claude?.running == true || s.claude?.status == .waiting { views.append(dot) }   // a finished session's dot said nothing
        if let walk = evidence.badge(for: s) { views.append(walk) }   // "walking…", "N screens" (Evidence.swift)
        // A build under way keeps its spinner and cancel in sight; the hammer, the log and the cross show on hover.
        let active = buildQueue.job(for: s)?.isActive ?? false
        var hover: [NSView] = []
        for v in build.views {
            if active, v is NSProgressIndicator || (v as? ClosureButton)?.toolTip?.hasPrefix("Cancel") == true { views.append(v) } else { hover.append(v); views.append(v) }
        }
        let remove = ClosureButton(symbol: "xmark", tip: "Remove from the sidebar (the + menu brings it back)") { [weak self] in self?.remove(s) }
        remove.contentTintColor = .tertiaryLabelColor
        hover.append(remove)
        views.append(remove)
        let stack = HoverRow(views: views)
        stack.hoverOnly = hover
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 6)
        var tip = [s.branch ?? "detached", s.shortHead + (s.ahead > 0 ? ", \(s.ahead) ahead" : ""), (s.worktree.path as NSString).abbreviatingWithTildeInPath]
        for pr in s.pullRequests { tip.append(pr.url.absoluteString + (pr.state.map { " (\($0.rawValue.lowercased()))" } ?? "")) }
        if s.pullRequests.isEmpty, let pr = s.claude?.pullRequest { tip.append(pr.absoluteString) }
        stack.toolTip = tip.joined(separator: "\n")
        return stack
    }

    /// A suggested session: one line, with + to add it and a cross to stop suggesting it.
    func suggestionCell(for s: Session) -> NSView {
        let add = ClosureButton(symbol: "plus.circle", tip: "Add to the sidebar") { [weak self] in self?.show(s) }
        add.contentTintColor = .controlAccentColor
        let name = NSTextField(labelWithString: s.title)
        name.font = .systemFont(ofSize: 12)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var why = ""
        if s.claude?.status == .waiting { why = "waiting" }
        else if s.claude?.running == true && s.claude?.status == .working { why = "working" }
        else if let n = s.pullRequests.first(where: { $0.state == .open })?.number { why = "#\(n)" }
        else if s.claude?.running == true { why = "open" }
        let tag = NSTextField(labelWithString: why)
        tag.font = .systemFont(ofSize: 10)
        tag.textColor = s.claude?.status == .waiting ? .systemOrange : .tertiaryLabelColor
        tag.setContentHuggingPriority(.required, for: .horizontal)
        tag.setContentCompressionResistancePriority(.required, for: .horizontal)
        let dismiss = ClosureButton(symbol: "xmark", tip: "Don't suggest this one again") { [weak self] in self?.dismiss(s) }
        dismiss.contentTintColor = .tertiaryLabelColor
        let stack = HoverRow(views: [add, name, tag, dismiss])
        stack.hoverOnly = [dismiss]
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 6)
        stack.toolTip = [s.branch ?? "detached", (s.worktree.path as NSString).abbreviatingWithTildeInPath].joined(separator: "\n")
        return stack
    }

    /// Stops suggesting the session (it stays in the + menu).
    func dismiss(_ s: Session) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == s.workspace.path }) else { return }
        if !workspaces[i].hidden.contains(s.worktree.path) { workspaces[i].hidden.append(s.worktree.path) }
        store.saveWorkspaces(workspaces)
        onChange?()
    }

    /// The suggestion row's key, like `rowKey`.
    func suggestionKey(for s: Session) -> String {
        [s.title, "\(s.claude?.status as Any)", "\(s.claude?.running as Any)", s.pullRequests.first(where: { $0.state == .open })?.url.absoluteString ?? ""].joined(separator: "\u{1f}")
    }

    private static func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static let ageFormatter: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f }()

    private static func age(_ date: Date) -> String {
        "built " + ageFormatter.localizedString(for: date, relativeTo: Date())
    }
}

/// A row whose `hoverOnly` views show while the pointer is over it: the sidebar stays quiet until a row is pointed at.
final class HoverRow: NSStackView {
    var hoverOnly: [NSView] = [] { didSet { hoverOnly.forEach { $0.isHidden = !inside } } }
    private var inside = false
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A row rebuilt under the pointer starts hovered, or its buttons would wait for the pointer to leave and come back.
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setInside(bounds.contains(p))
    }

    override func mouseEntered(with event: NSEvent) { setInside(true) }
    override func mouseExited(with event: NSEvent) { setInside(false) }

    private func setInside(_ on: Bool) {
        guard on != inside else { return }
        inside = on
        hoverOnly.forEach { $0.isHidden = !on }
    }
}
