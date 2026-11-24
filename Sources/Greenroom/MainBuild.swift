import AppKit

// The "main" row at the top of each Android repository in Sessions: a debug build of the repository's base branch
// (`Workspace.baseRef`, origin/main by default) that Greenroom keeps current by itself, so there is always a build of
// the latest main one click away. Each check fetches that branch (at most every ten minutes, or at once from the
// row), then takes the build of its head commit from the store, else from CI (never starting a workflow), else a
// worktree already at that commit with a fresh APK, else builds it with the local recipe in a worktree of its own
// under the state folder (detached at the commit; never one of the person's). Its simulator keeps its data in a
// slot of its own and reloads, data kept, when a newer main lands. "Keep main built" in the repository's + menu
// turns it off.

/// Whether a folder looks like an Android app project: a Gradle wrapper, and a build file (at the top or one folder
/// down) that applies the Android application plugin, the way the local recipe finds the module. Cached per path.
enum AndroidProject {
    private static var cache: [String: Bool] = [:]
    private static let lock = NSLock()

    static func isApp(_ root: URL) -> Bool {
        let key = root.resolvingSymlinksInPath().path
        lock.lock()
        if let known = cache[key] { lock.unlock(); return known }
        lock.unlock()
        let found = look(root)
        lock.lock(); cache[key] = found; lock.unlock()
        return found
    }

    /// Forgets what was found (a check makes and removes projects).
    static func forget() { lock.lock(); cache = [:]; lock.unlock() }

    private static func look(_ root: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.appendingPathComponent("gradlew").path) else { return SessionStore.newestAPK(in: root) != nil }
        var dirs = [root]
        if let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            dirs += top.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "build" }
        }
        for d in dirs {
            for name in ["build.gradle.kts", "build.gradle"] {
                guard let text = try? String(contentsOf: d.appendingPathComponent(name), encoding: .utf8) else { continue }
                if text.range(of: #"android[._-]?[Aa]pplication"#, options: .regularExpression) != nil { return true }
            }
        }
        return SessionStore.newestAPK(in: root) != nil
    }
}

/// One repository's main row.
struct MainRow {
    enum State: Equatable {
        case idle
        /// Fetching the base branch and looking for a build of its head.
        case checking(String)
        case failed(String)
    }
    var workspace: URL
    /// The branch's short name ("main").
    var name: String
    /// The head commit of the base branch, once known.
    var sha: String?
    /// The build of `sha`, when there is one.
    var current: Build?
    /// The newest build there is (the current one, else the one before it, kept running while a newer one is made).
    var newest: Build?
    var state: State
    var job: BuildJob?
    var simulator: Simulator?

    var isBusy: Bool {
        if case .checking = state { return true }
        return job?.isActive ?? false
    }
}

final class MainBuilds {
    private weak var sessions: SessionsController?
    private var shas: [String: String] = [:]
    private var names: [String: String] = [:]
    private var states: [String: MainRow.State] = [:]
    private var lastCheck: [String: Date] = [:]
    /// The commit a local build was last started for: a failed one is not retried by itself (the row's button does).
    private var attempted: [String: String] = [:]
    private var openWhenReady = Set<String>()
    /// The commit each repository's last local build was made from, and the build: an APK identical to an earlier
    /// commit's is filed under that commit, so this is what says it is this one's too.
    private var madeFor: [String: (sha: String, key: String)] = [:]
    /// How often main is looked at by itself.
    static let interval: TimeInterval = 600

    init(sessions: SessionsController) { self.sessions = sessions }

    private var store: SessionStore { sessions?.store ?? SessionStore.shared }
    private func change() { sessions?.onChange?() }

    // MARK: Where it lives

    /// The folder main's worktrees live in, under the state folder.
    var folder: URL { store.root.appendingPathComponent("sessions/main", isDirectory: true) }

    /// The worktree main is built in: `sessions/main/<hash>/<repository name>`.
    func trunk(of root: URL) -> URL {
        folder.appendingPathComponent(SessionStore.slot(for: root), isDirectory: true).appendingPathComponent(root.lastPathComponent, isDirectory: true)
    }

    /// Whether a worktree is one of main's (not a session of the person's).
    func isTrunk(_ worktree: URL) -> Bool {
        let base = folder.resolvingSymlinksInPath().path + "/"
        return worktree.resolvingSymlinksInPath().path.hasPrefix(base) || worktree.path.hasPrefix(folder.path + "/")
    }

    func slot(of root: URL) -> String { SessionStore.slot(for: trunk(of: root)) }

    func simulator(of root: URL) -> Simulator? {
        let slot = slot(of: root)
        return Engine.shared.simulators.first { $0.isAlive && SessionsController.slot(of: $0) == slot }
    }

    func owns(_ sim: Simulator) -> Bool {
        guard let slot = SessionsController.slot(of: sim) else { return false }
        return (sessions?.workspaces ?? []).contains { self.slot(of: $0.root) == slot }
    }

    /// The paths whose builds the store keeps (main's worktrees are not in `git worktree list` of the rows).
    var livePaths: [String] { (sessions?.workspaces ?? []).filter(\.keepMain).map { trunk(of: $0.root).path } }

    /// Whether the repository gets a main row.
    func applies(to ws: Workspace) -> Bool { ws.keepMain && AndroidProject.isApp(ws.root) }

    // MARK: Rows

    func row(for ws: Workspace) -> MainRow? {
        guard applies(to: ws) else { return nil }
        let key = ws.root.path
        let sha = shas[key]
        let current = sha.flatMap { build(ofSha: $0, in: ws) }
        return MainRow(workspace: ws.root, name: names[key] ?? Self.shortName(ws.baseRef), sha: sha, current: current,
                       newest: current ?? previous(in: ws), state: states[key] ?? .idle,
                       job: sessions?.buildQueue.jobs[trunk(of: ws.root).path], simulator: simulator(of: ws.root))
    }

    /// The build of `sha` main has: stored by commit (CI's or a clean one), else one built in main's worktree there.
    private func build(ofSha sha: String, in ws: Workspace) -> Build? {
        let fm = FileManager.default
        if let b = store.build(forSha: sha), fm.fileExists(atPath: b.apk.path) { return b }
        let path = trunk(of: ws.root).path
        if let b = sessions?.builds[path], b.sha == sha, fm.fileExists(atPath: b.apk.path) { return b }
        if let made = madeFor[ws.root.path], made.sha == sha, let b = store.build(made.key), fm.fileExists(atPath: b.apk.path) { return b }
        return store.history(of: path).compactMap { store.build($0) }.first { $0.sha == sha && fm.fileExists(atPath: $0.apk.path) }
    }

    private func previous(in ws: Workspace) -> Build? {
        let path = trunk(of: ws.root).path
        let fm = FileManager.default
        let known = ([sessions?.builds[path]].compactMap { $0 } + store.history(of: path).compactMap { store.build($0) })
        return known.filter { fm.fileExists(atPath: $0.apk.path) }.max { $0.date < $1.date }
    }

    static func shortName(_ ref: String) -> String {
        if ref.hasPrefix("refs/remotes/") { return shortName(String(ref.dropFirst(13))) }
        if let slash = ref.firstIndex(of: "/"), !ref.hasPrefix("refs/") { return String(ref[ref.index(after: slash)...]) }
        return ref
    }

    // MARK: Keeping it current

    /// Looks at every repository's main (each at most every `interval`).
    func ensureAll() {
        // A check run (`--…-check`) never builds by itself, but the main check's: the others' repositories (and the
        // person's, loaded first) keep their stand-in recipes and remotes to themselves.
        let args = CommandLine.arguments
        if args.contains(where: { $0.hasPrefix("--") && $0.hasSuffix("-check") }),
           !args.contains("--main-check") || store.root.path == SessionStore.shared.root.path { return }
        for ws in sessions?.workspaces ?? [] { ensure(ws) }
    }

    /// Fetches the base branch and makes sure its head has a build. `force`: now, and a failed build is tried again.
    func ensure(_ ws: Workspace, force: Bool = false) {
        guard applies(to: ws), let sessions else { return }
        let key = ws.root.path
        if case .checking = states[key] ?? .idle { return }
        if sessions.buildQueue.isBuilding(trunk(of: ws.root).path) { return }
        if !force, let last = lastCheck[key], Date().timeIntervalSince(last) < Self.interval { return }
        lastCheck[key] = Date()
        states[key] = .checking("fetching \(ws.baseRef)")
        change()
        let store = self.store
        Task { @MainActor in
            guard let head = await Self.head(of: ws) else {
                self.states[key] = .failed("Could not find \(ws.baseRef) or a main branch in \(ws.root.lastPathComponent). Set the base in the repository's settings.")
                self.change()
                return
            }
            self.shas[key] = head.sha
            self.names[key] = head.name
            if let b = self.build(ofSha: head.sha, in: ws) { self.states[key] = .idle; self.land(b, in: ws); return }
            if !force, self.attempted[key] == head.sha { self.states[key] = .idle; self.change(); return }   // its failure is on the row
            self.states[key] = .checking("looking for a build of \(String(head.sha.prefix(7)))")
            self.change()
            let r = await Bases.resolve(sha: head.sha, ref: head.name, in: ws, sessions: self.sessions?.sessions ?? [], store: store) { [weak self] line in
                guard let self, case .checking = self.states[key] ?? .idle, !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                self.states[key] = .checking("CI: " + line)
                self.change()
            }
            if case .build(let b) = r { self.states[key] = .idle; self.land(b, in: ws); return }
            await self.buildLocally(ws, sha: head.sha, name: head.name)
        }
    }

    /// Checks main's worktree out at `sha` and queues the local recipe on it (one build at a time per repository,
    /// like a session's).
    @MainActor private func buildLocally(_ given: Workspace, sha: String, name: String) async {
        let key = given.root.path
        let ws = sessions?.workspaces.first { $0.root.path == key } ?? given   // its settings as they are now
        let trunk = trunk(of: ws.root)
        states[key] = .checking("checking out \(String(sha.prefix(7)))")
        change()
        if let why = await Self.checkout(sha, at: trunk, repo: ws.root) { states[key] = .failed(why); change(); return }
        attempted[key] = sha
        states[key] = .idle
        let session = Session(worktree: trunk, workspace: ws.root, branch: name, head: sha, dirty: false, ahead: 0, claude: nil,
                              build: nil, simulator: nil, outputs: nil, sourcesDate: nil)
        sessions?.buildQueue.start(session, workspace: ws, recipeName: "local", store: store) { [weak self] why in
            self?.states[key] = .failed(why)
        }
        change()
    }

    /// A build of main's head is there: noted for the store to keep, opened when the row was clicked for it, and the
    /// running simulator moved onto it (data kept).
    private func land(_ b: Build, in ws: Workspace) {
        let path = trunk(of: ws.root).path
        if store.history(of: path).first != b.key {
            let store = self.store
            DispatchQueue.global(qos: .utility).async { store.note(build: b.key, of: path) }
        }
        // Main's map is what every pull request's walk starts from and is compared with: main's builds are walked like
        // a session's (the first in full, each later one only where its commits changed the app), under the trunk's path.
        sessions?.evidence.buildArrived(worktree: path, build: b, auto: ws.auto, withData: ws.walkWithData)
        change()
        if openWhenReady.remove(ws.root.path) != nil { open(ws) }
        else if let sim = simulator(of: ws.root), sim.apk.resolvingSymlinksInPath().path != b.apk.resolvingSymlinksInPath().path {
            DevHooks.shared.relaunch(sim, apk: b.apk, options: sim.options) { [weak self] new in
                if new != nil { self?.sessions?.workbench?.toast.show("Reloaded \(self?.names[ws.root.path] ?? "main") on its newest build") }
            }
        }
    }

    /// A recipe build finished (`SessionsController.adopt`): true when it was main's.
    func adopted(_ b: Build, worktree path: String) -> Bool {
        guard let ws = sessions?.workspaces.first(where: { trunk(of: $0.root).path == path }) else { return false }
        if let sha = attempted[ws.root.path] { madeFor[ws.root.path] = (sha, b.key) }
        land(b, in: ws)
        return true
    }

    /// A build of main's ended without one (failed or cancelled): a click waiting for it does not open later.
    func jobsChanged() {
        for ws in sessions?.workspaces ?? [] where openWhenReady.contains(ws.root.path) {
            guard let job = sessions?.buildQueue.jobs[trunk(of: ws.root).path], !job.isActive else { continue }
            if case .built = job.state { continue }
            openWhenReady.remove(ws.root.path)
        }
    }

    // MARK: Opening

    /// A click: the running simulator, else the newest build (the latest main's, or the one before while it is made),
    /// else main is built first and opens when it lands.
    func open(_ ws: Workspace) {
        guard let wb = sessions?.workbench else { return }
        if let sim = simulator(of: ws.root) { wb.select(sim); return }
        guard let row = row(for: ws) else { return }
        if let b = row.newest {
            _ = wb.open(b.apk, remember: false, options: ["--data-slots", slot(of: ws.root)])
            if row.current == nil, row.isBusy { wb.toast.show("Opened the previous \(row.name) build; it reloads on the newest when that is built") }
            return
        }
        openWhenReady.insert(ws.root.path)
        if let job = row.job, job.isActive { wb.toast.show("\(row.name) is building: it opens when it is ready"); return }
        if case .checking = row.state { wb.toast.show("Looking for the newest \(row.name): it opens when it is ready"); return }
        wb.toast.show("Building the newest \(row.name): it opens when it is ready")
        ensure(ws, force: true)
    }

    func close(_ ws: Workspace) { if let sim = simulator(of: ws.root) { Engine.shared.close(sim) } }

    // MARK: Git

    /// Fetches the base branch from its remote (quietly; a failure leaves what was fetched before) and gives its head,
    /// falling back to the remote's default branch, then a local main or master.
    static func head(of ws: Workspace) async -> (name: String, sha: String)? {
        let ref = ws.baseRef
        let remotes = Set((await Git.run(["remote"], in: ws.root) ?? "").split(whereSeparator: \.isNewline).map(String.init))
        if let slash = ref.firstIndex(of: "/"), remotes.contains(String(ref[..<slash])), !ref.hasPrefix("-") {
            _ = await Git.run(["fetch", "--quiet", "--no-tags", "--", String(ref[..<slash]), String(ref[ref.index(after: slash)...])], in: ws.root, timeout: 90)
        }
        var candidates = [ref]
        if remotes.contains("origin") { candidates.append("origin/HEAD") }
        candidates += ["main", "master"]
        for c in candidates where !c.hasPrefix("-") {
            guard let out = await Git.run(["rev-parse", "--verify", "--quiet", c + "^{commit}"], in: ws.root) else { continue }
            let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty else { continue }
            var name = shortName(c)
            if c == "origin/HEAD", let sym = await Git.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: ws.root) {
                name = shortName(sym.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return (name, sha)
        }
        return nil
    }

    /// Main's worktree at `sha`: added (detached) the first time, moved there after. Gives why not, or nil. The
    /// untracked `local.properties` (the SDK's folder) is copied from the main checkout when the worktree has none.
    static func checkout(_ sha: String, at trunk: URL, repo: URL) async -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: trunk.appendingPathComponent(".git").path) {
            if await Git.run(["checkout", "--detach", "--force", "--quiet", sha], in: trunk, timeout: 180) == nil {
                return "git could not move \(trunk.lastPathComponent)'s main worktree to \(String(sha.prefix(7)))"
            }
        } else {
            try? fm.removeItem(at: trunk)   // a leftover folder that is not a worktree any more
            try? fm.createDirectory(at: trunk.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = await Git.run(["worktree", "prune"], in: repo)
            if await Git.run(["worktree", "add", "--detach", "--force", trunk.path, sha], in: repo, timeout: 300) == nil {
                return "git could not check \(String(sha.prefix(7))) out in a worktree for main"
            }
        }
        let props = "local.properties"
        if !fm.fileExists(atPath: trunk.appendingPathComponent(props).path), fm.fileExists(atPath: repo.appendingPathComponent(props).path) {
            try? fm.copyItem(at: repo.appendingPathComponent(props), to: trunk.appendingPathComponent(props))
        }
        return nil
    }
}

// MARK: Row view

extension SessionsController {
    /// Main's row in each repository that has one, by repository root.
    func mainRow(for root: URL) -> MainRow? {
        guard let ws = workspaces.first(where: { $0.root.path == root.path }) else { return nil }
        return mainBuilds.row(for: ws)
    }

    func openMain(_ root: URL) { if let ws = workspaces.first(where: { $0.root.path == root.path }) { mainBuilds.open(ws) } }
    func updateMain(_ root: URL) { if let ws = workspaces.first(where: { $0.root.path == root.path }) { mainBuilds.ensure(ws, force: true) } }
    func closeMain(_ root: URL) { if let ws = workspaces.first(where: { $0.root.path == root.path }) { mainBuilds.close(ws) } }

    /// "Keep main built": saved with the repository; off takes the row away and quits its simulator.
    func setKeepMain(_ on: Bool, for root: URL) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == root.path }) else { return }
        if !on { mainBuilds.close(workspaces[i]) }
        workspaces[i].keepMain = on
        store.saveWorkspaces(workspaces)
        if on { mainBuilds.ensure(workspaces[i], force: true) }
        onChange?()
    }

    private func mainDetail(_ row: MainRow) -> (String, NSColor) {
        let short = row.sha.map { String($0.prefix(7)) }
        if let job = row.job, job.isActive {
            let what = job.state == .queued ? "queued behind another build" : "building: " + (job.lastLine ?? "local")
            return ((short.map { $0 + " · " } ?? "") + what, .secondaryLabelColor)
        }
        if case .checking(let what) = row.state { return (what, .secondaryLabelColor) }
        if case .failed(let why) = row.state { return (why, .systemRed) }
        if row.current == nil, let job = row.job, let why = job.failure, job.recipeName == "local" {
            return ("build failed: " + (why.split(separator: "\n").last.map(String.init) ?? why), .systemRed)
        }
        if let b = row.current { return ("latest · \(short ?? "") · \(Self.ageText(b.date))", .secondaryLabelColor) }
        if row.newest != nil { return ("older build; \(short ?? "the newest") not built yet", .systemOrange) }
        return ("not built yet: click to build and open", .secondaryLabelColor)
    }

    func mainRowKey(_ row: MainRow) -> String {
        let job = row.job.map { "\($0.id)|\($0.isActive)|\($0.lastLine ?? "")|\($0.failure ?? "")" } ?? "-"
        let sim = row.simulator.map { $0.state == .running ? "run" : "on" } ?? "off"
        return [row.name, row.sha ?? "", row.current?.key ?? "", row.newest?.key ?? "", "\(row.state)", job, sim, mainDetail(row).0].joined(separator: "\u{1f}")
    }

    func mainCell(_ row: MainRow) -> NSView {
        let running = row.simulator?.state == .running
        let icon = NSImageView(image: NSImage(systemSymbolName: running ? "play.circle.fill" : "play.circle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = running ? .systemGreen : (row.newest != nil ? .controlAccentColor : .tertiaryLabelColor)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: row.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let (detail, color) = mainDetail(row)
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = color
        sub.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, text]
        var hover: [NSView] = []
        let root = row.workspace
        if row.isBusy {
            let spin = NSProgressIndicator()
            spin.style = .spinning; spin.controlSize = .small; spin.isIndeterminate = true; spin.startAnimation(nil)
            spin.setContentHuggingPriority(.required, for: .horizontal)
            views.append(spin)
        } else {
            let update = ClosureButton(symbol: "arrow.clockwise", tip: "Fetch \(row.name) and build its newest commit now") { [weak self] in self?.updateMain(root) }
            hover.append(update)
            views.append(update)
        }
        if row.job != nil {
            let log = ClosureButton(symbol: "text.alignleft", tip: "Show the build log") {}
            log.handler = { [weak self, weak log] in self?.showMainLog(root, from: log) }
            hover.append(log)
            views.append(log)
        }
        let stack = HoverRow(views: views)
        stack.hoverOnly = hover
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 6)
        var tip = ["The newest \(row.name), a debug build Greenroom keeps up to date by itself. Click to run it."]
        if let sha = row.sha { tip.append(sha) }
        if let b = row.newest { tip.append("\(b.source.rawValue) build \(b.key)") }
        stack.toolTip = tip.joined(separator: "\n")
        return stack
    }

    func showMainLog(_ root: URL, from view: NSView?) {
        guard let job = buildQueue.jobs[mainBuilds.trunk(of: root).path], let content = workbench?.window.contentView else {
            workbench?.toast.show("main has not been built here yet")
            return
        }
        var rect = NSRect(x: 0, y: content.bounds.height - 60, width: 1, height: 1)
        if let view { rect = content.convert(view.bounds, from: view) }
        BuildLogPopover.show(job: job, anchor: rect, in: content, onCancel: { [weak self] in
            guard let self else { return }
            self.buildQueue.cancel(self.mainBuilds.trunk(of: root).path)
        })
    }

    func mainMenuItems(_ row: MainRow) -> [NSMenuItem] {
        let root = row.workspace
        var items = [ClosureMenuItem("Open \(row.name)") { [weak self] in self?.openMain(root) },
                     ClosureMenuItem("Build the Newest \(row.name) Now") { [weak self] in self?.updateMain(root) }]
        if row.job != nil { items.append(ClosureMenuItem("Show Build Log") { [weak self] in self?.showMainLog(root, from: nil) }) }
        if row.job?.isActive == true {
            items.append(ClosureMenuItem("Cancel Build") { [weak self] in
                guard let self else { return }
                self.buildQueue.cancel(self.mainBuilds.trunk(of: root).path)
            })
        }
        items.append(ClosureMenuItem("Stop Keeping \(row.name) Built") { [weak self] in self?.setKeepMain(false, for: root) })
        return items
    }

    private static let mainAgeFormatter: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f }()
    static func ageText(_ date: Date) -> String { "built " + mainAgeFormatter.localizedString(for: date, relativeTo: Date()) }
}
