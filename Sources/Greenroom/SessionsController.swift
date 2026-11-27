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
    /// Open/closed GitHub PRs per workspace root, keyed by `headRefName`.
    private var branchPRs: [String: [String: GH.BranchPull]] = [:]
    private var lastPRFetch: [String: Date] = [:]
    private var watchers: [String: WorktreeWatcher] = [:]
    private var buildWatcher: BuildWatcher?
    private var watched: [String] = []
    private var refreshEpoch = 0
    private var refreshing = false
    private var refreshQueued = false
    /// Thread-safe cancellation token for the current refresh scan's local APK filesystem walks.
    private final class ScanGate: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelledAll = false
        private var cancelledWorkspaces = Set<String>()
        func cancelAll() { lock.lock(); cancelledAll = true; lock.unlock() }
        func cancel(workspace path: String) { lock.lock(); cancelledWorkspaces.insert(path); lock.unlock() }
        func isCancelled(workspace path: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelledAll || cancelledWorkspaces.contains(path)
        }
    }
    private var activeScanGate: ScanGate?
    /// Workspaces currently scanning local worktree `build/outputs/apk` directories.
    private(set) var scanningWorkspaces = Set<String>()
    /// Slots whose simulator is to start as soon as the one that held the slot has exited.
    private var starting = Set<String>()
    static let noGit = "Sessions needs git: install the Command Line Tools (xcode-select --install)"
    /// The modified time of the file each session's simulator was last started from. An event for a file that is
    /// no newer (the system touching a file it has just read or cloned) is not a build.
    private var launched: [String: Date] = [:]
    private var monitor: Any?
    /// The build queue (Builds.swift); its rows and buttons are BuildsUI.swift.
    private(set) lazy var buildQueue = Builds(sessions: self)
    /// Pull requests without a worktree, the Review section (PullRequests.swift).
    private(set) lazy var pulls = PullRows(sessions: self)
    /// Each repository's main, kept built by itself (MainBuild.swift).
    private(set) lazy var mainBuilds = MainBuilds(sessions: self)
    /// Sessions clicked with no build: they are being built, and open when the build lands.
    var openWhenBuilt = Set<String>()
    /// A worktree to build and open once a refresh lists it (a project folder or a clone added from the empty stage).
    var runWhenListed: String?
    /// The session that was open when Greenroom last quit, to open again once a refresh lists it, if it has a build
    /// (a launch does not start a build by itself). Given up after the first complete refresh.
    var reopenWhenListed: String?
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
        let t3 = T3Sessions.shared   // T3 Code's threads, behind their own switch in Settings
        t3.workspaceRoots = { [weak self] in self?.workspaces.map(\.root) ?? [] }
        t3.onChange = { [weak self] in self?.applyClaude() }
        t3.changedSwitch()
        refresh()
    }

    /// Hands every row its Claude/T3 sessions (or takes them away) without asking git again. Says nothing when no row's
    /// sessions changed in a way the row shows.
    func applyClaude() {
        let next = attachPulls(ClaudeSessions.shared.attach(sessions))
        let changed = next.map { $0.agentSessions.map(\.shown) } != sessions.map { $0.agentSessions.map(\.shown) }
            || next.map { $0.claude?.shown } != sessions.map { $0.claude?.shown }
        sessions = next
        if autoArchive() || changed { onChange?() }
    }

    private func attachPulls(_ list: [Session]) -> [Session] {
        list.map { s in
            var s = s
            s.githubPR = s.branch.flatMap { branchPRs[s.workspace.path]?[$0] }
            return s
        }
    }

    /// Fetches GitHub PR metadata per workspace branch via `gh pr list` (at most every 3 minutes; skipped in checks).
    private func refreshPulls(for spaces: [Workspace]) {
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--") && $0.hasSuffix("-check") }) { return }
        let now = Date()
        for ws in spaces {
            let key = ws.root.path
            guard GitHubRemote.has(ws.root) else { continue }
            if let last = lastPRFetch[key], now.timeIntervalSince(last) < 180 { continue }
            lastPRFetch[key] = now
            let root = ws.root
            Task { @MainActor [weak self] in
                let slug = await GitHubRemote.repoSlug(for: root)
                let map = await GH.pullsByBranch(in: root, slug: slug)
                guard let self else { return }
                if self.branchPRs[key] != map {
                    self.branchPRs[key] = map
                    self.sessions = self.attachPulls(self.sessions)
                    for s in self.sessions where s.workspace.path == key {
                        if let sim = self.simulator(for: s) { sim.displayLabel = s.simLabel }
                    }
                    self.workbench?.refreshCaptions()
                    self.onChange?()
                }
            }
        }
    }

    /// Launch options for a simulator of `workspace` on `targetSlot`: when the repository has a kept sign-in, seeds an
    /// empty slot from it and passes `--biometrics auto` so biometric-protected apps auto-unlock on launch and restart.
    func signInLaunchOptions(forWorkspace workspace: URL, targetSlot: String, overwrite: Bool = false) -> [String] {
        guard let kept = SignIns.shared.record(SignIns.key(workspace: workspace)) else { return [] }
        SlotClone.seed(from: kept.slot, to: targetSlot, in: SignIns.dataRoot, overwrite: overwrite)
        return ["--biometrics", "auto"]
    }

    /// Uses another store (the check's own, so a check never touches the person's workspaces).
    func use(store: SessionStore) {
        self.store = store
        evidence.store = store
        workspaces = store.loadWorkspaces()
        builds = [:]
        refresh(supersede: true)
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

    /// Adds the repository `folder` is in (a worktree of it is as good as the main checkout) and ensures that
    /// worktree is visible in the sidebar. Gives the main checkout it resolved to, or nil with a toast when it is not
    /// a repository.
    @discardableResult
    func addRepository(_ folder: URL, quietIfExisting: Bool = false) -> Task<URL?, Never> {
        Task { @MainActor in
            guard let root = await Git.mainCheckout(of: folder)?.resolvingSymlinksInPath() else {
                self.workbench?.toast.show(Git.available ? "\(folder.lastPathComponent) is not in a git repository" : Self.noGit, problem: true)
                return nil
            }
            let worktree = (await Git.toplevel(of: folder)) ?? root
            let worktreePath = worktree.resolvingSymlinksInPath().path
            let rootPath = root.standardizedFileURL.path
            // Warm Android app discovery off the main thread before reloading the sidebar so UI never blocks.
            let discoveredApps = await Task.detached(priority: .userInitiated) { AndroidProject.apps(in: root) }.value
            let folderPath = folder.resolvingSymlinksInPath().standardizedFileURL.path
            let matchedApp: AndroidAppTarget? = discoveredApps.first { target in
                let dir = target.moduleDir.isEmpty ? rootPath : root.appendingPathComponent(target.moduleDir).standardizedFileURL.path
                let proj = target.projectDir.isEmpty ? rootPath : root.appendingPathComponent(target.projectDir).standardizedFileURL.path
                return folderPath == dir || folderPath.hasPrefix(dir + "/") || (proj != rootPath && (folderPath == proj || folderPath.hasPrefix(proj + "/")))
            }
            let defaultApp: AndroidAppTarget? = discoveredApps.count > 1
                ? (matchedApp ?? discoveredApps.first { $0.gradleModule == ":app" } ?? discoveredApps.first)
                : nil
            if let i = self.workspaces.firstIndex(where: { $0.root.resolvingSymlinksInPath().standardizedFileURL.path == rootPath }) {
                let wasShown = self.workspaces[i].shown.contains(worktreePath)
                if !wasShown { self.workspaces[i].shown.insert(worktreePath, at: 0) }
                self.workspaces[i].hidden.removeAll { $0 == worktreePath }
                self.workspaces[i].archived.removeAll { $0 == worktreePath }
                if let matchedApp, discoveredApps.count > 1, self.workspaces[i].module != matchedApp.id {
                    self.workspaces[i].module = matchedApp.id
                    self.mainBuilds.reset(self.workspaces[i])
                } else if self.workspaces[i].module == nil, let defaultApp {
                    self.workspaces[i].module = defaultApp.id
                }
                self.store.saveWorkspaces(self.workspaces)
                if !quietIfExisting {
                    if !wasShown {
                        let what = worktreePath == rootPath ? root.lastPathComponent : "\(worktree.lastPathComponent) in \(root.lastPathComponent)"
                        self.workbench?.toast.show("Showing \(what)")
                    } else if let matchedApp, discoveredApps.count > 1 {
                        self.workbench?.toast.show("Switched \(root.lastPathComponent) to \(matchedApp.displayName)")
                    } else {
                        self.workbench?.toast.show("\(root.lastPathComponent) is already in Sessions")
                    }
                }
            } else {
                var ws = Workspace(root: root)
                ws.shown = [worktreePath]
                if let defaultApp { ws.module = defaultApp.id }
                self.workspaces.append(ws)
                self.store.saveWorkspaces(self.workspaces)
                ClaudeSessions.shared.workspacesChanged()
                T3Sessions.shared.reload()
                if let defaultApp {
                    self.workbench?.toast.show("Added \(root.lastPathComponent) (\(discoveredApps.count) Android apps — using \(defaultApp.displayName); switch in sidebar)")
                } else {
                    self.workbench?.toast.show("Added \(root.lastPathComponent)")
                }
            }
            // Put the added worktree into `sessions` right away so the sidebar displays it immediately even while git
            // status and APK discovery are still running for large repositories.
            if !self.sessions.contains(where: { $0.worktree.resolvingSymlinksInPath().path == worktreePath }) {
                let wsRoot = self.workspaces.first { $0.root.resolvingSymlinksInPath().standardizedFileURL.path == rootPath }?.root ?? root
                let initial = Session(worktree: worktree, workspace: wsRoot, branch: nil, head: "", dirty: false,
                                      ahead: 0, claude: nil, build: self.builds[worktreePath], simulator: nil,
                                      outputs: nil, sourcesDate: nil)
                self.sessions.append(initial)
            }
            self.workbench?.showLibrary()
            self.onChange?()
            self.refresh(supersede: true)
            return root
        }
    }

    /// Cached Android app targets for `workspace` (never blocks the main thread).
    func apps(for workspace: URL) -> [AndroidAppTarget] {
        if let known = AndroidProject.cachedApps(in: workspace) { return known }
        AndroidProject.probe(workspace) { [weak self] in
            self?.reconcileAppTarget(for: workspace)
            self?.onChange?()
        }
        return []
    }

    /// The active Android app target for `workspace` when it has multiple apps (or nil for single-app repos).
    func selectedApp(for workspace: URL) -> AndroidAppTarget? {
        let all = apps(for: workspace)
        guard !all.isEmpty else { return nil }
        if let mod = self.workspace(at: workspace)?.module, !mod.isEmpty {
            if let exact = all.first(where: { $0.id == mod }) { return exact }
            let modDir = AndroidAppTarget.moduleDirectory(for: mod)
            if let byDir = all.first(where: { $0.moduleDir == modDir }) { return byDir }
        }
        return all.first { $0.gradleModule == ":app" } ?? all.first
    }

    /// Ensures a multi-app monorepo workspace has a valid `module` selected once its apps are discovered.
    func reconcileAppTarget(for workspace: URL) {
        let all = AndroidProject.cachedApps(in: workspace) ?? []
        guard all.count > 1, let i = workspaces.firstIndex(where: { $0.root.path == workspace.path }) else { return }
        if let cur = workspaces[i].module, !cur.isEmpty,
           all.contains(where: { $0.id == cur || $0.moduleDir == AndroidAppTarget.moduleDirectory(for: cur) }) {
            return
        }
        let chosen = all.first { $0.gradleModule == ":app" } ?? all[0]
        workspaces[i].module = chosen.id
        store.saveWorkspaces(workspaces)
    }

    /// Switches which Android app module a monorepo workspace builds and runs.
    func setAppModule(_ module: String?, for workspace: URL, silent: Bool = false) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == workspace.path }) else { return }
        let clean = module?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (clean?.isEmpty == false) ? clean : nil
        guard workspaces[i].module != next else { return }
        workspaces[i].module = next
        store.saveWorkspaces(workspaces)
        mainBuilds.reset(workspaces[i])
        if !silent {
            let label = next.flatMap { id in AndroidProject.cachedApps(in: workspace)?.first(where: { $0.id == id })?.displayName ?? id } ?? "auto-detect"
            workbench?.toast.show("Switched \(workspace.lastPathComponent) to \(label)")
        }
        onChange?()
        refresh(supersede: true)
    }

    /// Dropdown menu of all Android apps in a monorepo workspace.
    func appMenu(for workspace: URL) -> NSMenu {
        let menu = NSMenu(title: "Android App")
        let all = apps(for: workspace)
        let active = selectedApp(for: workspace)
        if #available(macOS 14.0, *) {
            menu.addItem(.sectionHeader(title: "Android App (\(all.count))"))
        }
        for target in all {
            let label = target.displayName == target.id ? target.displayName : "\(target.displayName)  ·  \(target.id)"
            let item = ClosureMenuItem(label) { [weak self] in self?.setAppModule(target.id, for: workspace) }
            item.state = (target == active) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    func removeWorkspace(containing session: Session) { removeWorkspace(at: session.workspace) }

    func removeWorkspace(at root: URL) {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        for s in sessions where s.workspace.resolvingSymlinksInPath().standardizedFileURL.path == rootPath { evidence.forget(worktree: s.worktree.path) }
        if let ws = workspaces.first(where: { $0.root.resolvingSymlinksInPath().standardizedFileURL.path == rootPath }) { mainBuilds.close(ws) }
        workspaces.removeAll { $0.root.resolvingSymlinksInPath().standardizedFileURL.path == rootPath }
        store.saveWorkspaces(workspaces)
        ClaudeSessions.shared.workspacesChanged()
        onChange?()
        refresh(supersede: true)
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
        // A worktree with nothing to run is not worth a row until the person adds it (the + menu has it).
        return (s.claudeActive || s.hasOpenPR) && newestAPK(for: s) != nil
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
            if let pr = s.githubPR {
                bits.append("#\(pr.number) \(pr.statusBadge.lowercased())")
            } else if let n = s.pullRequests.first(where: { $0.state == .open })?.number {
                bits.append("#\(n) open")
            } else if let n = s.pullRequests.first?.number {
                bits.append("#\(n)")
            }
            if let agent = s.displayAgent ?? s.claude {
                if agent.status == .waiting { bits.append("\(agent.sourceName) waiting for you") }
                else if agent.status == .working && agent.running { bits.append("\(agent.sourceName) working") }
            }
            if self.newestAPK(for: s) == nil { bits.append("no build: click it to build") }
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
        let discoveredApps = apps(for: workspace)
        if discoveredApps.count > 1 {
            let active = selectedApp(for: workspace)
            let appItem = NSMenuItem(title: "Android App: \(active?.displayName ?? "Auto")", action: nil, keyEquivalent: "")
            appItem.submenu = appMenu(for: workspace)
            menu.addItem(appItem)
        }
        if let ws = self.workspace(at: workspace) {
            if AndroidProject.cachedIsApp(ws.root) == true {
                let keep = ClosureMenuItem("Keep \(MainBuilds.shortName(ws.baseRef)) Built") { [weak self] in self?.setKeepMain(!ws.keepMain, for: workspace) }
                keep.state = ws.keepMain ? .on : .off
                keep.toolTip = "A row at the top runs the newest \(MainBuilds.shortName(ws.baseRef)): Greenroom fetches it and builds each new commit by itself"
                menu.addItem(keep)
                let unsigned = ClosureMenuItem("Count Walks That Are Not Signed In") { [weak self] in self?.setUnsignedBaseline(!ws.unsignedBaseline, for: workspace) }
                unsigned.state = ws.unsignedBaseline ? .on : .off
                unsigned.toolTip = Workspace.unsignedExplanation
                menu.addItem(unsigned)
            }
            menu.addItem(.separator())
            let skipScan = ClosureMenuItem("Skip Local APK Scan") { [weak self] in self?.setSkipLocalAPKScan(!ws.skipLocalAPKScan, for: workspace) }
            skipScan.state = ws.skipLocalAPKScan ? .on : .off
            skipScan.toolTip = "Stop scanning local build/outputs/apk directories in this repository and rely on your PR APK script or linked APKs"
            menu.addItem(skipScan)
            let noLocal = ClosureMenuItem("Disable Local Gradle Builds") { [weak self] in self?.setDisableLocalBuilds(!ws.disableLocalBuilds, for: workspace) }
            noLocal.state = ws.disableLocalBuilds ? .on : .off
            noLocal.toolTip = "Never run ./gradlew locally for this repository (use a PR APK script, CI, or linked local APKs instead)"
            menu.addItem(noLocal)
            menu.addItem(ClosureMenuItem(ws.hasPRFetchScript ? "Edit PR APK Script Settings…" : "Configure PR APK Script…") { [weak self] in
                guard self != nil else { return }
                SettingsWindow.shared.show(tab: .recipes, workspacePath: workspace.path)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add Repository…") { [weak self] in self?.chooseRepository() })
        menu.addItem(ClosureMenuItem("Remove \(workspace.lastPathComponent) from Sessions") { [weak self] in self?.removeWorkspace(at: workspace) })
        return menu
    }

    private func workspace(at root: URL) -> Workspace? { workspaces.first { $0.root.path == root.path } }

    /// The folders of a drag (files are not repositories).
    static func folders(in info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // MARK: Rows

    /// Re-reads git and the Gradle outputs of every worktree. Workspace mutations supersede an in-flight refresh;
    /// passive refreshes (app activation, FSEvents) coalesce into one follow-up pass instead of cancelling a slow scan.
    func refresh(supersede: Bool = false) {
        if supersede {
            refreshEpoch += 1
            activeScanGate?.cancelAll()
            refreshing = false
            refreshQueued = false
        } else if refreshing {
            refreshQueued = true
            return
        }
        refreshing = true
        let epoch = refreshEpoch
        let gate = ScanGate()
        activeScanGate = gate
        let spaces = workspaces
        let scanningNow = Set(spaces.filter { !$0.skipLocalAPKScan }.map(\.root.path))
        if scanningWorkspaces != scanningNow {
            scanningWorkspaces = scanningNow
            if !scanningNow.isEmpty { onChange?() }
        }
        // Teammates' maps, for the workspaces that share them (at most every ten minutes each; nothing when off).
        let sharing = spaces.filter(\.shareMaps)
        if !sharing.isEmpty { let root = store.root; Task.detached(priority: .utility) { for ws in sharing { _ = await History.fetchIfDue(ws, stateRoot: root) } } }
        let known = builds
        let before = sessions
        let trunkBase = mainBuilds.folder
        let trunkResolved = trunkBase.resolvingSymlinksInPath().path + "/"
        let trunkRaw = trunkBase.path + "/"
        let isTrunkPath: (URL) -> Bool = { url in
            url.resolvingSymlinksInPath().path.hasPrefix(trunkResolved) || url.path.hasPrefix(trunkRaw)
        }
        Task { @MainActor in
            let scanned = await Task.detached(priority: .userInitiated) { () -> (all: [Session], live: Set<String>, complete: Bool) in
                var all: [Session] = []
                var live = Set<String>()
                var complete = Git.available
                for ws in spaces {
                    if !ws.skipLocalAPKScan { _ = AndroidProject.isApp(ws.root) }
                    let wsModule = ws.module
                    let wsRootPath = ws.root.path
                    let skipLocalScan = ws.skipLocalAPKScan
                    let list = await Git.worktrees(of: ws.root)
                    if list.isEmpty {
                        complete = false   // git failed, or the repository moved: do not judge by it
                        let kept = before.filter { $0.workspace.path == ws.root.path }
                        if !kept.isEmpty {
                            all.append(contentsOf: kept)
                        } else if FileManager.default.fileExists(atPath: ws.root.path) {
                            let path = ws.root.resolvingSymlinksInPath()
                            all.append(Session(worktree: path, workspace: ws.root, branch: nil, head: "", dirty: false,
                                               ahead: 0, claude: nil, build: known[path.path], simulator: nil,
                                               outputs: nil, sourcesDate: nil))
                        }
                        continue
                    }
                    let worktrees = list.filter { !isTrunkPath($0.path) }
                    for wt in worktrees { live.insert(wt.path.path) }
                    // Scan each workspace's worktrees concurrently so multi-worktree / monorepo scans do not stall.
                    let results = await withTaskGroup(of: (Int, Session).self) { group -> [(Int, Session)] in
                        for (idx, wt) in worktrees.enumerated() {
                            group.addTask {
                                let path = wt.path
                                async let outputsTask: Session.Outputs? = skipLocalScan ? nil : Task.detached(priority: .utility) {
                                    SessionStore.newestAPK(in: path, module: wsModule, shouldCancel: { gate.isCancelled(workspace: wsRootPath) })
                                }.value
                                async let stateTask = Git.state(of: path)
                                let (outputs, state) = await (outputsTask, stateTask)
                                if let state {
                                    return (idx, Session(worktree: path, workspace: ws.root, branch: state.branch, head: state.head,
                                                         dirty: state.dirty, ahead: state.ahead, claude: nil, build: known[path.path],
                                                         simulator: nil, outputs: outputs, sourcesDate: state.sourcesDate))
                                } else if var old = before.first(where: { $0.worktree.path == path.path }) {
                                    // One failed call (a lock, a busy disk) must not drop the row, and with it the simulator's.
                                    old.outputs = outputs
                                    old.build = known[path.path]
                                    return (idx, old)
                                } else {
                                    // Unborn HEAD or transient git failure: still list the worktree from `git worktree list`.
                                    let head = wt.head.allSatisfy({ $0 == "0" }) ? "" : wt.head
                                    return (idx, Session(worktree: path, workspace: ws.root, branch: wt.branch, head: head,
                                                         dirty: false, ahead: 0, claude: nil, build: known[path.path],
                                                         simulator: nil, outputs: outputs, sourcesDate: nil))
                                }
                            }
                        }
                        var collected: [(Int, Session)] = []
                        for await item in group { collected.append(item) }
                        return collected
                    }
                    for (_, session) in results.sorted(by: { $0.0 < $1.0 }) {
                        all.append(session)
                    }
                }
                return (all, live, complete)
            }.value
            guard epoch == self.refreshEpoch else { return }
            self.refreshing = false
            self.scanningWorkspaces = []
            self.activeScanGate = nil
            var live = scanned.live
            let complete = scanned.complete
            let all = scanned.all
            if complete { for old in before where !live.contains(old.worktree.path) { self.evidence.forget(worktree: old.worktree.path) } }
            self.sessions = self.attachPulls(ClaudeSessions.shared.attach(all))
            self.refreshPulls(for: spaces)
            self.watch(all)
            if let want = self.runWhenListed, let s = self.sessions.first(where: { $0.worktree.resolvingSymlinksInPath().path == want }) {
                self.runWhenListed = nil
                self.activate(s)
            }
            if let want = self.reopenWhenListed, complete || self.sessions.contains(where: { $0.worktree.path == want }) {
                self.reopenWhenListed = nil
                if let s = self.sessions.first(where: { $0.worktree.path == want }), self.newestAPK(for: s) != nil { self.activate(s) }
            }
            if complete { self.autoArchive() }
            self.onChange?()
            self.mainBuilds.ensureAll()   // at most every ten minutes each, unless asked
            if complete {
                live.formUnion(self.mainBuilds.livePaths)   // main's builds are kept like a session's
                let store = self.store
                DispatchQueue.global(qos: .utility).async { store.prune(live: live) }
                self.evidence.pruneToCap()
            }
            if self.refreshQueued {
                self.refreshQueued = false
                self.refresh()
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
            let order = Dictionary(ws.shown.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            let rows = all.filter(isShown).map { s -> Session in var s = s; s.simulator = simulator(for: s); return s }
                .sorted { a, b in
                    let ka = (Self.tier(a, live: a.simulator != nil), order[a.worktree.path] ?? -1)
                    let kb = (Self.tier(b, live: b.simulator != nil), order[b.worktree.path] ?? -1)
                    return ka < kb
                }
            out.append((ws.root.lastPathComponent, ws.root, rows, all.count - rows.count))
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
        show(session)
        if let sim = simulator(for: session) {
            wb.select(sim)
            noteUsed(session.worktree.path)
            return true
        }
        guard let apk = newestAPK(for: session) else {
            // Nothing to run yet: build/fetch it with the workspace's recipe, and open when it lands.
            let path = session.worktree.path
            if buildQueue.isBuilding(path) {
                openWhenBuilt.insert(path)
                wb.toast.show("\(session.title) is building: it opens when it is ready")
                return true
            }
            guard let ws = workspace(of: session) else { return false }
            let recipeName = (ws.hasPRFetchScript && (session.prNumber != nil || ws.disableLocalBuilds)) ? "pr-script" : ws.defaultRecipeName
            if let refusal = ws.refusal(forRecipe: recipeName) {
                if recipeName == "remote" {
                    openWhenBuilt.insert(path)
                    build(session, recipe: recipeName)
                } else {
                    wb.toast.show(refusal, problem: true)
                }
                return true
            }
            openWhenBuilt.insert(path)
            build(session, recipe: recipeName == ws.defaultRecipeName ? nil : recipeName)
            if buildQueue.isBuilding(path) {
                let verb = recipeName == "pr-script" ? "Fetching PR APK for" : "Building"
                wb.toast.show("\(verb) \(session.title) with \(recipeName): it opens when it is ready")
            } else {
                openWhenBuilt.remove(path)
            }
            return true
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
        let signInOpts = options.contains("--biometrics") ? [] : signInLaunchOptions(forWorkspace: session.workspace, targetSlot: session.slot)
        guard let wb = workbench, let sim = wb.open(apk, remember: remember, options: ["--data-slots", session.slot] + signInOpts + options, fromAgent: fromAgent) else { return nil }
        sim.displayLabel = session.simLabel
        wb.refreshCaptions()
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
        let skippedRoots = Set(workspaces.filter(\.skipLocalAPKScan).map(\.root.path))
        let paths = all.filter { !skippedRoots.contains($0.workspace.path) }.map(\.worktree.path).sorted()
        guard paths != watched else { return }
        watched = paths
        buildWatcher?.stop()
        buildWatcher = nil
        guard !paths.isEmpty else { return }
        let b = BuildWatcher(folders: paths.map { URL(fileURLWithPath: $0, isDirectory: true) }, name: nil)
        b.onBuild = { [weak self] apk in self?.built(apk) }
        if b.start() { buildWatcher = b }
    }

    /// Stops any in-flight local APK scan for `root` immediately and enables `skipLocalAPKScan` so local search stays off.
    func stopLocalSearch(for root: URL) {
        activeScanGate?.cancel(workspace: root.path)
        scanningWorkspaces.remove(root.path)
        setSkipLocalAPKScan(true, for: root, silent: true)
        workbench?.toast.show("Stopped local APK search for \(root.lastPathComponent). Link a local APK or configure a PR APK script instead.")
    }

    func setSkipLocalAPKScan(_ on: Bool, for root: URL, silent: Bool = false) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == root.path }) else { return }
        if on {
            activeScanGate?.cancel(workspace: root.path)
            scanningWorkspaces.remove(root.path)
        }
        guard workspaces[i].skipLocalAPKScan != on else {
            onChange?()
            return
        }
        workspaces[i].skipLocalAPKScan = on
        store.saveWorkspaces(workspaces)
        if !silent {
            workbench?.toast.show(on ? "Skipped local APK scanning for \(root.lastPathComponent)" : "Resumed local APK scanning for \(root.lastPathComponent)")
        }
        onChange?()
        refresh(supersede: true)
    }

    func setDisableLocalBuilds(_ on: Bool, for root: URL, silent: Bool = false) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == root.path }) else { return }
        guard workspaces[i].disableLocalBuilds != on else { return }
        workspaces[i].disableLocalBuilds = on
        store.saveWorkspaces(workspaces)
        if on {
            // Cancel any in-flight local Gradle builds belonging to this workspace.
            for (wtPath, job) in buildQueue.jobs where job.workspace.path == root.path && job.isActive && job.recipeName == "local" {
                buildQueue.cancel(wtPath)
            }
        }
        if !silent {
            workbench?.toast.show(on ? "Disabled local Gradle builds for \(root.lastPathComponent)" : "Enabled local Gradle builds for \(root.lastPathComponent)")
        }
        onChange?()
    }

    func setPRFetchScript(_ path: String, for root: URL) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == root.path }) else { return }
        workspaces[i].prFetchScript = path.trimmingCharacters(in: .whitespacesAndNewlines)
        store.saveWorkspaces(workspaces)
        onChange?()
    }

    /// Files a local `.apk` on disk and links it to `session` (and its PR, when known or specified).
    @MainActor
    func linkLocalAPK(_ apk: URL, to session: Session, prNumber: Int? = nil, open shouldOpen: Bool = false) async -> Build? {
        let store = self.store
        let sha = session.head.isEmpty ? nil : session.head
        let ref = session.branch
        let dirty = session.dirty
        let path = session.worktree.path
        let pr = prNumber ?? session.prNumber
        let build = await Task.detached(priority: .userInitiated) {
            guard let b = store.record(apk: apk, source: .file, sha: sha, ref: ref, dirty: dirty, date: Date(), prNumber: pr) else { return nil as Build? }
            store.note(build: b.key, of: path)
            return b
        }.value
        guard let build else { return nil }
        if shouldOpen { openWhenBuilt.insert(path) }
        adopt(build, forWorktree: path)
        if let pr { pulls.applyLinkedBuild(build, toPR: pr, workspace: session.workspace.path, open: false) }
        return build
    }

    /// Links a local `.apk` on disk to any session(s) and/or Review PR row matching `prNumber` (and optional `workspace`).
    @MainActor
    func linkLocalAPK(_ apk: URL, toPR prNumber: Int, workspace: URL? = nil, open shouldOpen: Bool = false) async -> (build: Build?, linkedTargets: [String]) {
        let wsPath = workspace?.resolvingSymlinksInPath().standardizedFileURL.path
        let matchingSessions = sessions.filter { s in
            s.prNumber == prNumber && (wsPath == nil || s.workspace.resolvingSymlinksInPath().standardizedFileURL.path == wsPath)
        }
        var linked: [String] = []
        var firstBuild: Build?
        for s in matchingSessions {
            if let b = await linkLocalAPK(apk, to: s, prNumber: prNumber, open: shouldOpen && firstBuild == nil) {
                firstBuild = firstBuild ?? b
                linked.append(s.title)
            }
        }
        if firstBuild == nil {
            let store = self.store
            firstBuild = await Task.detached(priority: .userInitiated) {
                store.record(apk: apk, source: .file, sha: nil, ref: nil, dirty: false, date: Date(), prNumber: prNumber)
            }.value
        }
        if let b = firstBuild {
            let prLinked = pulls.applyLinkedBuild(b, toPR: prNumber, workspace: wsPath, open: shouldOpen && linked.isEmpty)
            if prLinked { linked.append("PR #\(prNumber)") }
        }
        return (firstBuild, linked)
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
        if openWhenBuilt.remove(session.worktree.path) != nil, simulator(for: session) == nil {
            var s = session
            s.outputs = Session.Outputs(apk: file, date: Self.modified(file))
            activate(s)
        }
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
            new.displayLabel = session.simLabel
            self.workbench?.refreshCaptions()
            self.workbench?.toast.show("Reloaded \(session.title) on its new build")
            self.onReload?(session, new)
        }
    }

    /// A build a recipe made, filed in the store: it is the session's newest, and its simulator (if one is alive,
    /// selected or not) reloads on it with its data kept. A build the simulator already runs reloads nothing.
    func adopt(_ build: Build, forWorktree path: String) {
        builds[path] = build
        if mainBuilds.adopted(build, worktree: path) { onChange?(); return }
        let waiting = openWhenBuilt.remove(path) != nil   // clicked with no build: it opens now
        buildArrivedForEvidence(path, build)
        if let pr = build.prNumber, let session = sessions.first(where: { $0.worktree.path == path }) {
            pulls.applyLinkedBuild(build, toPR: pr, workspace: session.workspace.path, open: false)
        }
        if waiting, let session = sessions.first(where: { $0.worktree.path == path }), simulator(for: session) == nil {
            activate(session)
        } else if let session = sessions.first(where: { $0.worktree.path == path }), let old = simulator(for: session),
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

    /// Whether a walk that was not signed in counts as a map of this repository (see `Workspace.unsignedBaseline`).
    /// Checks walk apps with no sign-in in stand-in repositories: `unsignedForChecks` answers for them.
    static var unsignedForChecks: Bool? = CommandLine.arguments.contains { $0.hasPrefix("--") && $0.hasSuffix("-check") } ? true : nil
    func countsUnsigned(_ root: URL?) -> Bool {
        if let forced = Self.unsignedForChecks { return forced }
        return workspaces.first { $0.root.path == root?.path }?.unsignedBaseline ?? false
    }
    /// The repository a walk's owner belongs to: a session's worktree, the base branch's own (the trunk), or a pull request row.
    func workspaceRoot(ofOwner owner: String) -> URL? {
        if let s = sessions.first(where: { $0.worktree.path == owner }) { return s.workspace }
        if let ws = workspaces.first(where: { mainBuilds.trunk(of: $0.root).path == owner }) { return ws.root }
        if owner.hasPrefix("pr:"), let p = pulls.all.first(where: { "pr:" + $0.id == owner }) { return URL(fileURLWithPath: p.workspace) }
        return nil
    }
    func setUnsignedBaseline(_ on: Bool, for root: URL) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == root.path }) else { return }
        workspaces[i].unsignedBaseline = on
        store.saveWorkspaces(workspaces)
        // What was held back for want of a sign-in is walked now; main's too.
        if on { for s in sessions where s.workspace.path == root.path { if let b = builds[s.worktree.path] ?? s.build { buildArrivedForEvidence(s.worktree.path, b) } }; mainBuilds.ensure(workspaces[i], force: true) }
        onChange?()
    }

    func walksWithData(_ s: Session) -> Bool { workspaces.first { $0.root.path == s.workspace.path }?.walkWithData ?? false }

    func setWalkWithData(_ on: Bool, for s: Session) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == s.workspace.path }) else { return }
        workspaces[i].walkWithData = on
        store.saveWorkspaces(workspaces)
        onChange?()
    }

    /// "Quick Walks Only", saved with the workspace.
    func walksQuick(_ s: Session) -> Bool { workspaces.first { $0.root.path == s.workspace.path }?.quickWalk ?? false }
    func walksQuick(worktree: String) -> Bool { sessions.first { $0.worktree.path == worktree }.map { walksQuick($0) } ?? false }

    func setQuickWalk(_ on: Bool, for s: Session) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == s.workspace.path }) else { return }
        workspaces[i].quickWalk = on
        store.saveWorkspaces(workspaces)
        onChange?()
    }

    func sharesMaps(_ s: Session) -> Bool { workspaces.first { $0.root.path == s.workspace.path }?.shareMaps ?? false }
    func sharesSignedInMaps(_ s: Session) -> Bool { workspaces.first { $0.root.path == s.workspace.path }?.shareSignedInMaps ?? false }

    /// "Share screen maps through git" and "Also share maps walked on signed-in data", saved with the workspace.
    func setShareMaps(_ on: Bool, signedIn: Bool? = nil, for s: Session) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == s.workspace.path }) else { return }
        workspaces[i].shareMaps = on
        if let signedIn { workspaces[i].shareSignedInMaps = signedIn }
        store.saveWorkspaces(workspaces)
        onChange?()
        refresh()
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
        // A walk running in the map is never replaced: its map shows when it ends.
        if wb.screenMap.isWalking { wb.toast.show("A walk is running in the screen map. Its map shows here when it ends."); return }
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
        for ws in workspaces {
            guard let row = mainBuilds.row(for: ws) else { continue }
            let repo = workspaces.count > 1 ? " of \(ws.root.lastPathComponent)" : ""
            out.append(PaletteItem(id: "main.open." + ws.root.path, title: "Run the newest \(row.name)\(repo)", group: "Sessions", symbol: "play.circle",
                                   keywords: "main master trunk latest debug apk launch") { [weak self] in self?.openMain(ws.root) })
        }
        out.append(PaletteItem(id: "session.add", title: "Add a repository to Sessions…", group: "Sessions", symbol: "plus.rectangle.on.folder",
                               keywords: "git worktree folder") { [weak self] in self?.chooseRepository() })
        out += changesPaletteItems()   // Changes: this session's build against a base (ChangesSheet.swift)
        out += buildPaletteItems()   // Build this session, Cancel build (BuildsUI.swift)
        out += recipePaletteItems()  // Add pull request, Prepare remote builder, Build settings (RecipesUI.swift)
        return out
    }

    // MARK: Row view

    /// Structured display model for a session row, shared by `rowHeight(for:)`, `rowKey(for:)`, and `cell(for:)`
    /// so layout heights and change detection stay strictly in sync.
    private struct RowPresentation {
        let isSelected: Bool
        let prNumber: Int?
        let prBadge: String?
        let prBadgeColor: NSColor
        let prTitle: String?
        let prAdditions: Int?
        let prDeletions: Int?
        let prTwoLineTitle: Bool
        /// Whether the branch / build line shows. A card that is not selected drops it when its agent line
        /// already says what the session is doing, unless a build has something to report.
        let showMeta: Bool
        let branchLabel: String
        let buildDetail: String?
        let buildColor: NSColor?
        let metadataParts: [(text: String, color: NSColor)]
        let metadataKey: String
        let agent: ClaudeSession?
        let extraActiveAgents: Int
        let agentTitle: String?
        let agentSnippet: String?
        let showOpenPRButton: Bool
    }

    private func presentation(for s: Session) -> RowPresentation {
        let isSelected = (s.simulator != nil && s.simulator === workbench?.selected)
        let build = buildAccessories(for: s)

        // 1. Pull request details (prefer GitHub PR metadata; fall back to open/feature Claude PR).
        let prNumber: Int?
        let prBadge: String?
        let prBadgeColor: NSColor
        let prTitle: String?
        if let pr = s.githubPR {
            prNumber = pr.number
            prBadge = pr.statusBadge
            if pr.isDraft { prBadgeColor = Design.mute }
            else if pr.isMerged { prBadgeColor = NSColor(srgbRed: 0.72, green: 0.56, blue: 1.0, alpha: 1) }
            else if pr.isClosed { prBadgeColor = Design.record }
            else if pr.reviewDecision?.uppercased() == "CHANGES_REQUESTED" { prBadgeColor = Design.warning }
            else { prBadgeColor = Design.accent }
            prTitle = pr.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pr.title
        } else if let pr = s.fallbackPR, let n = pr.number {
            prNumber = n
            switch pr.state {
            case .open?: prBadge = "Open"; prBadgeColor = Design.accent
            case .merged?: prBadge = "Merged"; prBadgeColor = NSColor(srgbRed: 0.72, green: 0.56, blue: 1.0, alpha: 1)
            case .closed?: prBadge = "Closed"; prBadgeColor = Design.record
            case nil: prBadge = nil; prBadgeColor = Design.mute
            }
            prTitle = nil
        } else {
            prNumber = nil
            prBadge = nil
            prBadgeColor = Design.mute
            prTitle = nil
        }

        // 2. Branch & build metadata line (only highlight "stale" in amber; keep other parts calm).
        let branchLabel = s.branch ?? (s.shortHead.isEmpty ? s.worktree.lastPathComponent : "(detached \(s.shortHead))")
        var parts: [(String, NSColor)] = []
        if prNumber != nil {
            parts.append((branchLabel, .secondaryLabelColor))
        } else if !s.shortHead.isEmpty {
            parts.append((s.shortHead, .secondaryLabelColor))
        }
        if let built = s.builtAt {
            parts.append((Self.age(built), .secondaryLabelColor))
            if s.isStale { parts.append(("stale", Design.warning)) }
        } else {
            parts.append(("not built", .secondaryLabelColor))
        }
        if s.dirty { parts.append(("edited", .secondaryLabelColor)) }
        if workspace(of: s)?.defaultRecipeName == "ci",
           let behind = CIBehind.note(for: s, store: store, then: { [weak self] in self?.onChange?() }) {
            parts.append((behind, .secondaryLabelColor))
        }
        let metadataKey = build.detail ?? parts.map(\.0).joined(separator: " · ")

        // 3. T3 Code / Claude Code agent card details.
        let agent = s.displayAgent
        let activeCount = s.activeAgentSessions.count
        let agentIsActive = agent != nil && s.activeAgentSessions.contains(where: {
            $0.id == agent?.id && $0.title == agent?.title && $0.source == agent?.source
        })
        let extraActive = max(0, activeCount - (agentIsActive ? 1 : 0))
        let agentTitle: String? = {
            guard let a = agent else { return nil }
            if let t = a.title, !t.isEmpty { return t }
            if let sum = a.summary, !sum.isEmpty { return sum }
            return a.status == .waiting ? "Waiting for your response" : (a.running ? "Active \(a.sourceName) session" : "\(a.sourceName) session")
        }()
        let agentSnippet: String? = {
            guard let a = agent, let sum = a.summary, !sum.isEmpty else { return nil }
            if let t = agentTitle, t.caseInsensitiveCompare(sum) == .orderedSame { return nil }
            guard a.running || a.status == .waiting || isSelected else { return nil }
            return sum
        }()
        let prTwoLineTitle = isSelected && (prTitle?.count ?? 0) > 38

        return RowPresentation(
            isSelected: isSelected,
            prNumber: prNumber,
            prBadge: prBadge,
            prBadgeColor: prBadgeColor,
            prTitle: prTitle,
            prAdditions: s.githubPR?.additions,
            prDeletions: s.githubPR?.deletions,
            prTwoLineTitle: prTwoLineTitle,
            showMeta: isSelected || agent == nil || build.detail != nil,
            branchLabel: branchLabel,
            buildDetail: build.detail,
            buildColor: build.color,
            metadataParts: parts,
            metadataKey: metadataKey,
            agent: agent,
            extraActiveAgents: extraActive,
            agentTitle: agentTitle,
            agentSnippet: agentSnippet,
            showOpenPRButton: s.prURL != nil
        )
    }

    /// Exact vertical geometry matching `cell(for:)` so card borders hug content evenly with zero dead space.
    /// Measured card heights by row key and width; a row rebuilt with the same key keeps its height.
    private var measuredHeights: [String: CGFloat] = [:]

    /// The height the card actually lays out to at this width, so the row always fits it exactly.
    func rowHeight(for s: Session, width: CGFloat) -> CGFloat {
        guard width > 0 else { return estimatedRowHeight(for: s) }
        let key = rowKey(for: s) + "\u{1f}\(Int(width))"
        if let h = measuredHeights[key] { return h }
        let view = cell(for: s)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.layoutSubtreeIfNeeded()
        let h = max(ceil(view.fittingSize.height), estimatedRowHeight(for: s))
        if measuredHeights.count > 400 { measuredHeights.removeAll() }
        measuredHeights[key] = h
        return h
    }

    private func estimatedRowHeight(for s: Session) -> CGFloat {
        let p = presentation(for: s)
        var h: CGFloat = 6                         // outer wrapper top(3) + bottom(3) card gap
        h += 14                                    // card inner padding top(7) + bottom(7)
        h += 17                                    // header row (explicit 17pt)
        if p.prTitle != nil {
            h += 4 + (p.prTwoLineTitle ? 32 : 16)  // spacing(4) + 1- or 2-line PR title
        }
        if p.showMeta { h += 4 + 14 }              // spacing(4) + metadata row (explicit 14pt)
        if p.agent != nil, !p.isSelected {
            h += 4 + 14                            // spacing(4) + one-line agent summary (explicit 14pt)
        } else if p.agent != nil {
            h += 6                                 // custom spacing before agent box
            h += 12                                // agent box padding top(6) + bottom(6)
            h += 16                                // agent header row (explicit 16pt)
            if p.agentTitle != nil { h += 3 + 15 } // spacing(3) + agent title (15pt)
            if p.agentSnippet != nil { h += 2 + 14 } // spacing(2) + snippet (14pt)
        }
        if p.isSelected {
            h += 7 + 25                            // custom spacing(7) + action buttons(25pt)
        }
        return h
    }

    private func shortcutIndex(for s: Session) -> Int? {
        guard let idx = groups().flatMap(\.sessions).firstIndex(where: { $0.worktree.path == s.worktree.path }), idx < 9 else { return nil }
        return idx + 1
    }

    /// Everything a session's row shows, as one string: the sidebar rebuilds a row only when this changed.
    func rowKey(for s: Session) -> String {
        let p = presentation(for: s)
        let job = buildQueue.job(for: s)
        let jobKey = job.map { "\($0.id)|\($0.state == .queued)|\($0.isActive)|\($0.lastLine ?? "")|\($0.failure ?? "")" } ?? "-"
        let sim = s.simulator.map { $0.state == .running ? "run" : "on" } ?? "off"
        let agentKey = p.agent.map {
            "\($0.source.rawValue)|\($0.status.rawValue)|\($0.rawStatus ?? "")|\($0.running)|\($0.archived)|\($0.settled)|\($0.title ?? "")|\($0.summary ?? "")|\($0.model ?? "")"
        } ?? "-"
        let prKey = "\(p.prNumber ?? 0)|\(p.prBadge ?? "")|\(p.prTitle ?? "")|\(p.prAdditions ?? -1)|\(p.prDeletions ?? -1)"
        let shortcut = shortcutIndex(for: s).map(String.init) ?? ""
        return [
            p.branchLabel, p.metadataKey, prKey, sim, agentKey, "\(p.extraActiveAgents)", "\(s.ahead)",
            jobKey, evidence.badgeKey(for: s), workspace(of: s)?.defaultRecipeName ?? "",
            p.isSelected ? "sel" : "", p.showMeta ? "meta" : "", shortcut
        ].joined(separator: "\u{1f}")
    }

    private static func makePill(_ text: String, textColor: NSColor, fill: NSColor, border: NSColor? = nil, font: NSFont = .systemFont(ofSize: 10, weight: .semibold)) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = textColor
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 4.5
        pill.layer?.cornerCurve = .continuous
        pill.layer?.backgroundColor = fill.cgColor
        if let border {
            pill.layer?.borderWidth = 0.75
            pill.layer?.borderColor = border.cgColor
        }
        pill.addSubview(label)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 1.5),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -1.5),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -5),
        ])
        return pill
    }

    private static func agentStatusStyle(for agent: ClaudeSession) -> (text: String, symbol: String, color: NSColor, border: NSColor, fill: NSColor) {
        let agentPurple = NSColor(srgbRed: 0.616, green: 0.569, blue: 1.0, alpha: 1)
        if agent.status == .waiting {
            return ("Waiting for you", "exclamationmark.circle.fill", Design.warning,
                    Design.warning.withAlphaComponent(0.35), Design.warning.withAlphaComponent(0.08))
        }
        if agent.running && agent.status == .working {
            return ("Working", "sparkles", agentPurple,
                    agentPurple.withAlphaComponent(0.32), agentPurple.withAlphaComponent(0.08))
        }
        if agent.rawStatus == "failed" {
            return ("Failed", "xmark.circle.fill", Design.record,
                    Design.record.withAlphaComponent(0.30), Design.record.withAlphaComponent(0.07))
        }
        if agent.rawStatus == "interrupted" {
            return ("Interrupted", "pause.circle.fill", Design.warning,
                    Design.warning.withAlphaComponent(0.28), Design.warning.withAlphaComponent(0.06))
        }
        if agent.running {
            return ("Idle", "circle.fill", Design.mute,
                    Design.stroke, NSColor(white: 0, alpha: 0.20))
        }
        let doneLabel = agent.settled ? "Settled" : (agent.rawStatus == "completed" ? "Done" : "Idle")
        return (doneLabel, "checkmark.circle", Design.mute.withAlphaComponent(0.85),
                Design.stroke, NSColor(white: 0, alpha: 0.18))
    }

    private func openAgent(_ agent: ClaudeSession, in worktree: URL) {
        if agent.source == .t3 {
            T3Sessions.open(worktree) { [weak self] why in
                if let why {
                    if let link = agent.link { NSWorkspace.shared.open(link) }
                    else { self?.workbench?.toast.show(why, problem: true) }
                }
            }
        } else {
            if !ClaudeSessions.openInClaude(agent) {
                workbench?.toast.show("Claude is not installed on this Mac", problem: true)
            }
        }
    }

    /// An attributed label ignores the field's own line break mode, so the ellipsis has to be in the text's paragraph style.
    private static func truncateTail(_ text: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
    }

    /// The agent on a card that is not selected: one line (source, status, what it is working on) instead of the box.
    private func buildAgentLine(presentation p: RowPresentation) -> NSView? {
        guard let agent = p.agent else { return nil }
        let style = Self.agentStatusStyle(for: agent)
        let active = agent.running || agent.status == .waiting

        let icon = NSImageView(image: NSImage(systemSymbolName: style.symbol, accessibilityDescription: style.text) ?? NSImage())
        icon.contentTintColor = style.color
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        let text = NSMutableAttributedString(
            string: "\(agent.sourceName) · \(style.text)" + (p.extraActiveAgents > 0 ? " +\(p.extraActiveAgents)" : ""),
            attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: style.color]
        )
        if let title = p.agentTitle {
            text.append(NSAttributedString(string: "  " + title, attributes: [
                .font: font, .foregroundColor: active ? Design.ink.withAlphaComponent(0.85) : NSColor.secondaryLabelColor,
            ]))
        }
        Self.truncateTail(text)
        let label = NSTextField(labelWithAttributedString: text)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let line = NSStackView(views: [icon, label])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 4
        line.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return line
    }

    private func buildAgentCard(for s: Session, presentation p: RowPresentation) -> NSView? {
        guard let agent = p.agent else { return nil }
        let style = Self.agentStatusStyle(for: agent)

        let sourcePill = Self.makePill(
            agent.sourceName,
            textColor: style.color,
            fill: style.color.withAlphaComponent(0.14),
            border: style.color.withAlphaComponent(0.26),
            font: .systemFont(ofSize: 9.5, weight: .semibold)
        )

        let statusIcon = NSImageView(image: NSImage(systemSymbolName: style.symbol, accessibilityDescription: style.text) ?? NSImage())
        statusIcon.contentTintColor = style.color
        statusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let statusLabel = NSTextField(labelWithString: style.text)
        statusLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        statusLabel.textColor = style.color
        statusLabel.maximumNumberOfLines = 1
        statusLabel.cell?.usesSingleLineMode = true
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        var headerViews: [NSView] = [sourcePill, statusIcon, statusLabel]
        if p.extraActiveAgents > 0 {
            let moreBtn = ClosureButton(title: "+\(p.extraActiveAgents) ▾", tip: "View all active sessions in this worktree") {}
            moreBtn.font = .systemFont(ofSize: 9.5, weight: .semibold)
            moreBtn.contentTintColor = Design.ink.withAlphaComponent(0.88)
            moreBtn.wantsLayer = true
            moreBtn.layer?.cornerRadius = 4.5
            moreBtn.layer?.backgroundColor = NSColor(white: 1, alpha: 0.09).cgColor
            moreBtn.setContentHuggingPriority(.required, for: .horizontal)
            moreBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
            moreBtn.handler = { [weak self, weak moreBtn] in
                guard let self, let moreBtn else { return }
                let menu = NSMenu()
                let list = s.activeAgentSessions.isEmpty ? s.agentSessions : s.activeAgentSessions
                for a in list.prefix(8) {
                    let st = Self.agentStatusStyle(for: a).text
                    let label = "\(a.sourceName) · \(st) — \(a.title ?? a.summary ?? "Untitled")"
                    let item = ClosureMenuItem(label) { [weak self] in self?.openAgent(a, in: s.worktree) }
                    if let sum = a.summary, sum != a.title { item.toolTip = sum }
                    menu.addItem(item)
                }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreBtn.bounds.height + 2), in: moreBtn)
            }
            headerViews.append(moreBtn)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        headerViews.append(spacer)

        if let model = agent.shortModel {
            let modelLabel = NSTextField(labelWithString: model)
            modelLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
            modelLabel.textColor = .tertiaryLabelColor
            modelLabel.maximumNumberOfLines = 1
            modelLabel.lineBreakMode = .byTruncatingMiddle
            modelLabel.cell?.usesSingleLineMode = true
            modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerViews.append(modelLabel)
        }

        let openBtn = ClosureButton(symbol: "arrow.up.right", tip: "Open in \(agent.sourceName)") { [weak self] in
            self?.openAgent(agent, in: s.worktree)
        }
        openBtn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        openBtn.contentTintColor = .secondaryLabelColor
        headerViews.append(openBtn)

        let headerRow = NSStackView(views: headerViews)
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 4
        headerRow.heightAnchor.constraint(equalToConstant: 16).isActive = true

        var boxLines: [NSView] = [headerRow]

        if let titleText = p.agentTitle {
            let titleLabel = NSTextField(labelWithString: titleText)
            titleLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
            titleLabel.textColor = (agent.running || agent.status == .waiting) ? Design.ink : Design.ink.withAlphaComponent(0.82)
            titleLabel.alignment = .left
            titleLabel.maximumNumberOfLines = 1
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.cell?.usesSingleLineMode = true
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            titleLabel.heightAnchor.constraint(equalToConstant: 15).isActive = true
            boxLines.append(titleLabel)
        }

        if let snippet = p.agentSnippet {
            let snippetLabel = NSTextField(labelWithString: snippet)
            snippetLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
            snippetLabel.textColor = Design.mute
            snippetLabel.alignment = .left
            snippetLabel.maximumNumberOfLines = 1
            snippetLabel.lineBreakMode = .byTruncatingTail
            snippetLabel.cell?.usesSingleLineMode = true
            snippetLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            snippetLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            snippetLabel.heightAnchor.constraint(equalToConstant: 14).isActive = true
            boxLines.append(snippetLabel)
        }

        let boxStack = NSStackView(views: boxLines)
        boxStack.orientation = .vertical
        boxStack.alignment = .leading
        boxStack.spacing = 3
        if boxLines.count == 3 {
            boxStack.setCustomSpacing(2, after: boxLines[1])
        }
        boxStack.translatesAutoresizingMaskIntoConstraints = false

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 7
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = style.fill.cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = style.border.cgColor
        box.addSubview(boxStack)
        var boxConstraints: [NSLayoutConstraint] = [
            boxStack.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            boxStack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
            boxStack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            boxStack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
        ]
        for line in boxLines {
            boxConstraints.append(line.widthAnchor.constraint(equalTo: boxStack.widthAnchor))
        }
        NSLayoutConstraint.activate(boxConstraints)
        return box
    }

    func cell(for s: Session) -> NSView {
        let p = presentation(for: s)
        let sim = s.simulator
        let running = sim?.state == .running

        // Simulator status indicator (green = simulator running; agent status is separated into its own labeled box).
        let simDot = NSImageView(image: NSImage(systemSymbolName: sim == nil ? "circle" : (running ? "circle.fill" : "circle.dotted"), accessibilityDescription: running ? "Simulator running" : "Simulator stopped") ?? NSImage())
        simDot.contentTintColor = running ? Design.accent : .tertiaryLabelColor
        simDot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .regular)
        simDot.toolTip = running ? "Simulator running" : (sim != nil ? "Simulator starting" : "Click to launch simulator")
        simDot.setContentHuggingPriority(.required, for: .horizontal)
        simDot.setContentCompressionResistancePriority(.required, for: .horizontal)
        simDot.widthAnchor.constraint(equalToConstant: 10).isActive = true

        var headerViews: [NSView] = [simDot]

        if let num = p.prNumber {
            headerViews.append(Self.makePill(
                "#\(num)",
                textColor: p.prBadgeColor,
                fill: p.prBadgeColor.withAlphaComponent(0.15),
                border: p.prBadgeColor.withAlphaComponent(0.28),
                font: .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
            ))
            if let badge = p.prBadge {
                headerViews.append(Self.makePill(
                    badge,
                    textColor: p.prBadgeColor,
                    fill: p.prBadgeColor.withAlphaComponent(0.10),
                    font: .systemFont(ofSize: 10, weight: .medium)
                ))
            }
            if let add = p.prAdditions, let del = p.prDeletions, (add > 0 || del > 0) {
                let diffText = NSMutableAttributedString(
                    string: "+\(add)",
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .foregroundColor: Design.accent.withAlphaComponent(0.9)]
                )
                diffText.append(NSAttributedString(
                    string: " -\(del)",
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .foregroundColor: Design.record.withAlphaComponent(0.85)]
                ))
                let diffLabel = NSTextField(labelWithAttributedString: diffText)
                diffLabel.maximumNumberOfLines = 1
                diffLabel.cell?.usesSingleLineMode = true
                diffLabel.setContentHuggingPriority(.required, for: .horizontal)
                diffLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
                headerViews.append(diffLabel)
            }
        } else {
            let branchTitle = NSTextField(labelWithString: p.branchLabel)
            branchTitle.font = .systemFont(ofSize: 13, weight: p.isSelected ? .semibold : .medium)
            branchTitle.textColor = Design.ink
            branchTitle.alignment = .left
            branchTitle.maximumNumberOfLines = 1
            branchTitle.lineBreakMode = .byTruncatingTail
            branchTitle.cell?.usesSingleLineMode = true
            branchTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerViews.append(branchTitle)
            if s.ahead > 0 {
                headerViews.append(Self.makePill(
                    "↑\(s.ahead)",
                    textColor: Design.mute,
                    fill: NSColor(white: 1, alpha: 0.07),
                    font: .monospacedSystemFont(ofSize: 9.5, weight: .medium)
                ))
            }
        }

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        headerViews.append(headerSpacer)

        // Active build progress stays visible in header; hover-only controls fade in as a trailing overlay so nothing jumps.
        let build = buildAccessories(for: s)
        let activeBuild = buildQueue.job(for: s)?.isActive ?? false
        var overlayButtons: [NSView] = []
        for v in build.views {
            if activeBuild, v is NSProgressIndicator || (v as? ClosureButton)?.toolTip?.hasPrefix("Cancel") == true {
                headerViews.append(v)
            } else {
                overlayButtons.append(v)
            }
        }
        let remove = ClosureButton(symbol: "xmark", tip: "Remove from the sidebar (the + menu brings it back)") { [weak self] in self?.remove(s) }
        remove.contentTintColor = .tertiaryLabelColor
        overlayButtons.append(remove)

        var shortcutBadge: NSTextField?
        if let n = shortcutIndex(for: s) {
            let badge = NSTextField(labelWithString: "⌘\(n)")
            badge.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            badge.textColor = .tertiaryLabelColor
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            headerViews.append(badge)
            shortcutBadge = badge
        }

        let headerStack = NSStackView(views: headerViews)
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 5
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        // Each hover button gets a real hit target; at their bare symbol size they crowd into an unreadable sliver.
        for case let button as ClosureButton in overlayButtons {
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        let hoverOverlay = NSStackView(views: overlayButtons)
        hoverOverlay.orientation = .horizontal
        hoverOverlay.alignment = .centerY
        hoverOverlay.spacing = 4
        hoverOverlay.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        hoverOverlay.wantsLayer = true
        hoverOverlay.layer?.cornerRadius = 7
        hoverOverlay.layer?.cornerCurve = .continuous
        hoverOverlay.layer?.backgroundColor = NSColor(srgbRed: 0.145, green: 0.153, blue: 0.172, alpha: 0.96).cgColor
        hoverOverlay.layer?.borderWidth = 0.75
        hoverOverlay.layer?.borderColor = Design.stroke.cgColor
        hoverOverlay.translatesAutoresizingMaskIntoConstraints = false
        hoverOverlay.isHidden = true

        let headerContainer = NSView()
        headerContainer.addSubview(headerStack)
        NSLayoutConstraint.activate([
            headerContainer.heightAnchor.constraint(equalToConstant: 17),
            headerStack.topAnchor.constraint(equalTo: headerContainer.topAnchor),
            headerStack.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            headerStack.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
        ])

        var cardRows: [NSView] = [headerContainer]

        // Full-width PR title row (always flush left, never fights with badges, shortcut, or evidence counts).
        if let prTitle = p.prTitle {
            let titleField = NSTextField(wrappingLabelWithString: prTitle)
            titleField.font = .systemFont(ofSize: 12.5, weight: p.isSelected ? .semibold : .medium)
            titleField.textColor = p.isSelected ? Design.ink : Design.ink.withAlphaComponent(0.78)
            titleField.alignment = .left
            titleField.maximumNumberOfLines = p.prTwoLineTitle ? 2 : 1
            // Truncating-tail mode keeps a label on one line; word wrap plus truncatesLastVisibleLine gives two lines and an ellipsis.
            titleField.lineBreakMode = p.prTwoLineTitle ? .byWordWrapping : .byTruncatingTail
            titleField.cell?.usesSingleLineMode = !p.prTwoLineTitle
            titleField.cell?.truncatesLastVisibleLine = true
            titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            // A fixed height either way: a wrapping label left to size itself collapses to one line and the
            // agent box below swallows the slack, spilling past the row.
            titleField.heightAnchor.constraint(equalToConstant: p.prTwoLineTitle ? 32 : 16).isActive = true
            cardRows.append(titleField)
        }

        // Branch / commit / build status + right-aligned Screen Map / Changes badge.
        let metaLabel: NSTextField
        if let detailText = p.buildDetail {
            metaLabel = NSTextField(labelWithString: detailText)
            metaLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
            metaLabel.textColor = p.buildColor ?? .secondaryLabelColor
        } else {
            let attr = NSMutableAttributedString()
            let font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
            let sep = NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
            for (i, part) in p.metadataParts.enumerated() {
                if i > 0 { attr.append(sep) }
                attr.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: part.color]))
            }
            Self.truncateTail(attr)
            metaLabel = NSTextField(labelWithAttributedString: attr)
        }
        metaLabel.alignment = .left
        metaLabel.maximumNumberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.cell?.usesSingleLineMode = true
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let metaSpacer = NSView()
        metaSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var metaViews: [NSView] = [metaLabel, metaSpacer]
        if let walk = evidence.badge(for: s) {
            metaViews.append(walk)
        }
        let metaRow = NSStackView(views: metaViews)
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 6
        metaRow.heightAnchor.constraint(equalToConstant: 14).isActive = true
        if p.showMeta { cardRows.append(metaRow) }

        // The selected card gets the full labeled T3 Code / Claude Code box; the others a one-line summary,
        // so the selected session is the one that stands out.
        var agentCardView: NSView?
        if !p.isSelected {
            if let line = buildAgentLine(presentation: p) { cardRows.append(line) }
        } else if let agentCard = buildAgentCard(for: s, presentation: p) {
            cardRows.append(agentCard)
            agentCardView = agentCard
        }

        // Action bar when selected.
        var actionRowView: NSView?
        if p.isSelected {
            let rebuildButton = GlassButton(symbol: "hammer", title: "Build", label: "Rebuild this session", style: .well, target: nil, action: nil)
            rebuildButton.image = NSImage(systemSymbolName: "hammer", accessibilityDescription: "Build")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            rebuildButton.font = .systemFont(ofSize: 11, weight: .medium)
            rebuildButton.heightAnchor.constraint(equalToConstant: 25).isActive = true
            rebuildButton.layer?.cornerRadius = 7
            rebuildButton.onPress = { [weak self] in self?.build(s) }

            let changesButton = GlassButton(symbol: "plusminus", title: "Changes", label: "Show changes for this session", style: .well, target: nil, action: nil)
            changesButton.image = NSImage(systemSymbolName: "plusminus", accessibilityDescription: "Changes")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            changesButton.font = .systemFont(ofSize: 11, weight: .medium)
            changesButton.heightAnchor.constraint(equalToConstant: 25).isActive = true
            changesButton.layer?.cornerRadius = 7
            changesButton.onPress = { [weak self] in self?.workbench?.showChanges(of: s) }

            var actions: [NSView] = [rebuildButton, changesButton]
            if let prURL = s.prURL {
                let prButton = GlassButton(symbol: "arrow.up.right", title: "PR", label: "Open pull request on GitHub", style: .well, target: nil, action: nil)
                prButton.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Open PR")?
                    .withSymbolConfiguration(.init(pointSize: 9.5, weight: .medium))
                prButton.font = .systemFont(ofSize: 11, weight: .medium)
                prButton.heightAnchor.constraint(equalToConstant: 25).isActive = true
                prButton.layer?.cornerRadius = 7
                prButton.onPress = { NSWorkspace.shared.open(prURL) }
                actions.append(prButton)
            }

            let actionRow = NSStackView(views: actions)
            actionRow.orientation = .horizontal
            actionRow.alignment = .centerY
            actionRow.distribution = .fillEqually
            actionRow.spacing = 6
            actionRow.heightAnchor.constraint(equalToConstant: 25).isActive = true
            cardRows.append(actionRow)
            actionRowView = actionRow
        }

        // Rich tooltip with complete PR, Git, and all T3 Code / Claude sessions on this worktree.
        var tip: [String] = []
        if let pr = s.githubPR {
            var line = "PR #\(pr.number): \(pr.title) (\(pr.statusBadge))"
            if let base = pr.baseBranch { line += " → \(base)" }
            if let a = pr.additions, let d = pr.deletions {
                let files = pr.changedFiles.map { ", \($0) file\($0 == 1 ? "" : "s")" } ?? ""
                line += " [+\(a) -\(d)\(files)]"
            }
            tip.append(line)
            if let url = pr.url { tip.append(url.absoluteString) }
        }
        tip.append("Branch: \(p.branchLabel) (\(s.shortHead)\(s.ahead > 0 ? ", \(s.ahead) ahead" : "")\(s.dirty ? ", edited" : ""))")
        tip.append("Worktree: \((s.worktree.path as NSString).abbreviatingWithTildeInPath)")
        let allAgents = s.agentSessions.isEmpty ? [s.claude].compactMap { $0 } : s.agentSessions
        for a in allAgents.prefix(4) {
            let st = Self.agentStatusStyle(for: a).text
            let modelStr = a.shortModel.map { " [\($0)]" } ?? ""
            var line = "\(a.sourceName) (\(st))\(modelStr): \(a.title ?? "Untitled")"
            if let sum = a.summary, sum != a.title { line += "\n  \"\(sum)\"" }
            tip.append(line)
        }
        for pr in s.pullRequests where pr.number != s.githubPR?.number {
            tip.append(pr.url.absoluteString + (pr.state.map { " (\($0.rawValue.lowercased()))" } ?? ""))
        }
        let tooltipText = tip.joined(separator: "\n")

        let contentStack = NSStackView(views: cardRows)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        if agentCardView != nil, p.showMeta {
            contentStack.setCustomSpacing(6, after: metaRow)
        }
        if let actionRowView, let prev = cardRows.dropLast().last, prev !== actionRowView {
            contentStack.setCustomSpacing(7, after: prev)
        }
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8.5
        card.layer?.cornerCurve = .continuous
        if !p.isSelected {
            card.layer?.backgroundColor = NSColor(white: 1, alpha: 0.02).cgColor
            card.layer?.borderWidth = 1
            card.layer?.borderColor = NSColor(white: 1, alpha: 0.05).cgColor
        } else {
            // SourceList already draws the native macOS rounded selection highlight around the row.
            card.layer?.backgroundColor = NSColor.clear.cgColor
            card.layer?.borderWidth = 0
        }
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentStack)
        card.addSubview(hoverOverlay)

        var constraints: [NSLayoutConstraint] = [
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -7),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            hoverOverlay.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            hoverOverlay.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -5),
        ]
        for rowView in cardRows {
            constraints.append(rowView.widthAnchor.constraint(equalTo: contentStack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        let wrapper = HoverCardWrapper()
        wrapper.overlay = hoverOverlay
        wrapper.hideOnHover = shortcutBadge
        wrapper.toolTip = tooltipText
        wrapper.autoresizingMask = [.width, .height]   // follows its row when the row's height changes
        wrapper.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -3),
            card.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 1),
            card.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -1),
        ])
        return wrapper
    }

    /// A suggested session: clear 2-line preview with PR/agent context, + to add it and × to dismiss.
    func suggestionCell(for s: Session) -> NSView {
        let add = ClosureButton(symbol: "plus.circle.fill", tip: "Add to the sidebar") { [weak self] in self?.show(s) }
        add.contentTintColor = .controlAccentColor
        add.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .medium)

        let name = NSTextField(labelWithString: s.title)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = Design.ink.withAlphaComponent(0.88)
        name.maximumNumberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        name.cell?.usesSingleLineMode = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var subBits: [String] = []
        if let pr = s.githubPR {
            subBits.append("#\(pr.number) \(pr.statusBadge)")
        } else if let n = s.pullRequests.first(where: { $0.state == .open })?.number {
            subBits.append("#\(n) Open")
        }
        if let agent = s.displayAgent ?? s.claude {
            let st = Self.agentStatusStyle(for: agent).text
            subBits.append("\(agent.sourceName) · \(st)")
        }
        if let b = s.branch, b != s.title { subBits.append(b) }
        let subText = subBits.isEmpty ? (s.branch ?? s.shortHead) : subBits.joined(separator: " · ")

        let sub = NSTextField(labelWithString: subText)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = (s.displayAgent?.status == .waiting || s.claude?.status == .waiting) ? Design.warning : .secondaryLabelColor
        sub.maximumNumberOfLines = 1
        sub.lineBreakMode = .byTruncatingTail
        sub.cell?.usesSingleLineMode = true
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let dismiss = ClosureButton(symbol: "xmark", tip: "Don't suggest this one again") { [weak self] in self?.dismiss(s) }
        dismiss.contentTintColor = .tertiaryLabelColor
        let stack = HoverRow(views: [add, text, dismiss])
        stack.hoverOnly = [dismiss]
        stack.alignment = .centerY
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
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
        let agent = s.displayAgent ?? s.claude
        return [
            s.title,
            s.branch ?? "",
            s.githubPR.map { "\($0.number)|\($0.statusBadge)" } ?? "",
            agent.map { "\($0.source.rawValue)|\($0.status.rawValue)|\($0.rawStatus ?? "")|\($0.running)" } ?? "",
            s.pullRequests.first(where: { $0.state == .open })?.url.absoluteString ?? "",
        ].joined(separator: "\u{1f}")
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

/// Wrapper for session cards that reveals a trailing hover action overlay without shifting any text or layout.
final class HoverCardWrapper: NSView {
    weak var overlay: NSView?
    weak var hideOnHover: NSView?
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
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setInside(bounds.contains(p), animated: false)
    }

    override func mouseEntered(with event: NSEvent) { setInside(true, animated: true) }
    override func mouseExited(with event: NSEvent) { setInside(false, animated: true) }

    private func setInside(_ on: Bool, animated: Bool) {
        guard on != inside else { return }
        inside = on
        if on { overlay?.isHidden = false }
        let apply = {
            self.overlay?.alphaValue = on ? 1 : 0
            self.hideOnHover?.alphaValue = on ? 0 : 1
        }
        if animated && !Design.reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                self.overlay?.animator().alphaValue = on ? 1 : 0
                self.hideOnHover?.animator().alphaValue = on ? 0 : 1
            }, completionHandler: { [weak self] in
                if self?.inside == false { self?.overlay?.isHidden = true }
            })
        } else {
            apply()
            if !on { overlay?.isHidden = true }
        }
    }
}
