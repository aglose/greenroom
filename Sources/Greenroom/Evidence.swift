import AppKit

/// What Greenroom captures for a session's build by itself (docs/SESSIONS-PLAN.md, "3. Evidence", the walk): one
/// background queue that runs the screen map's crawl (`CrawlRun`) on hidden simulators, never in the sidebar or on
/// the stage.
///
///     evidence/<build key>/map/              crawl.py's output (crawl.json, screens/...); its presence is the cache
///     changes/<head key>-<base key>/         crawl.py --base output (`changes(head:base:...)`)
///
/// - One walk at a time across the app. A newer build of a session cancels that session's running or queued walk.
/// - A walk runs on a clone of the session's data slot, never the slot itself (`SlotClone`), so it starts where the
///   person is signed in and changes nothing of theirs; a session with no data yet, or a clone that cannot be made,
///   is walked fresh, and the row's detail says so.
/// - A build whose map exists is not walked again. The map is made in `map.part` and renamed in whole.
/// - Main thread only, except where marked.
final class Evidence: NSObject, NSMenuItemValidation {
    struct Budget {
        var depth = 2
        var seconds = 120
        var jobs = 2
    }

    enum Status: Equatable {
        case queued
        case walking(depth: Int, known: Int)
        case done(screens: Int, crashes: Int, unfinished: Bool)
        case failed(String)
        case stopped
    }

    /// What the row of one session shows about its newest build.
    struct Entry: Equatable {
        var key: String
        /// The build's own date: a build that arrives older than the newest one seen for the session is ignored.
        var date: Date
        var status: Status
        /// How the walk was made ("on a copy of this session's data", "fresh: ...").
        var note: String?
    }

    /// What a comparison of two builds found, from the `compare` list of crawl.json.
    struct ChangesSummary: Equatable {
        var same = 0, changed = 0, new = 0, gone = 0
        var differing: Int { changed + new + gone }
    }

    struct ChangesResult {
        let folder: URL
        let map: ScreenMapData
        let summary: ChangesSummary
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Cancels a `changes` request (the run itself goes only when nobody else waits for the same pair).
    final class Token {
        fileprivate var cancelAction: (() -> Void)?
        func cancel() { cancelAction?() }
    }

    /// What a walk does not reach, said in the row's detail.
    static let limits = "The walk taps through the app a level or two deep within a time budget. It does not reach screens behind typed input, a signed-in server state it has no data for, or a gesture it does not try."

    var store: SessionStore = .shared {
        didSet {
            guard oldValue.root != store.root else { return }
            // Another store (a check's own): nothing queued or shown belongs to it.
            queue.removeAll()
            entries = [:]
            if let job = current { job.forgotten = true; cancel(job) }
        }
    }
    /// The engine's per-package data folders (`cache/data/<package>/<slot>-N`).
    var dataRoot: URL = Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true)
    var budget = Budget()
    /// Told on the main thread when any row's status changed.
    var onChange: (() -> Void)?
    weak var controller: SessionsController?
    /// The session row under the pointer when the sidebar's context menu opened (set by the controller).
    var clickedSession: () -> Session? = { nil }

    /// HOOK, not used yet: return true to hold a queued job back for now (a walk should pause while a build of that
    /// workspace is running or the person is recording). Asked with the job's owner (a worktree path, or
    /// "changes:..."), every time the queue looks at it and every 5 s after a yes. Later workstreams set this; this
    /// file depends on none of their types.
    var shouldPause: ((_ owner: String) -> Bool)?

    /// For checks: how many walks and comparisons were started, and how many were cancelled.
    private(set) var started = 0
    private(set) var cancelledRuns = 0

    private var entries: [String: Entry] = [:]
    private var queue: [Job] = []
    private var current: Job?
    private var retry: Timer?
    private var swept = false
    private let fm = FileManager.default
    private var quitObserver: NSObjectProtocol?

    private final class Job {
        enum Kind { case walk(slot: String?), changes(base: Build) }
        let owner: String
        let build: Build
        let kind: Kind
        var run: CrawlRun?
        var clone: String?
        var cancelled = false
        /// Why it was cancelled: a person's Stop (the row says stopped) or a newer build (its own entry takes over).
        var stopped = false
        var note: String?
        /// "Walk again": not satisfied by a map that is there.
        var force = false
        /// The session or repository went: the walk's folder goes with it.
        var forgotten = false
        struct Waiter {
            let id = UUID()
            let completion: (Result<ChangesResult, Failure>) -> Void
            let progress: ((CrawlRun.Event) -> Void)?
        }
        var waiters: [Waiter] = []
        /// A comparison's own start (a deep link) and engine options for the base's launches (a check's changed build).
        var start: String?
        var baseOption = ""
        /// How a walk was made, for the snapshot it files (set when it starts).
        var profile: MapProfile?
        /// Where it is made and where it ends up, fixed when the job is made (the store may change meanwhile).
        let part: URL
        let final: URL
        init(owner: String, build: Build, kind: Kind, part: URL, final: URL) {
            self.owner = owner; self.build = build; self.kind = kind; self.part = part; self.final = final
        }
        var isChanges: Bool { if case .changes = kind { return true } else { return false } }
        /// A walk a comparison waits for, or the comparison itself: its progress goes to its waiters.
        var forwardsProgress: Bool { isChanges || owner.hasPrefix("map:") }
    }

    override init() {
        super.init()
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.shutdown()
        }
    }

    // MARK: Folders

    var evidenceFolder: URL { store.root.appendingPathComponent("evidence", isDirectory: true) }
    var changesFolder: URL { store.root.appendingPathComponent("changes", isDirectory: true) }
    func mapFolder(for key: String) -> URL { evidenceFolder.appendingPathComponent(key, isDirectory: true).appendingPathComponent("map", isDirectory: true) }
    func changesFolder(head: String, base: String) -> URL { changesFolder.appendingPathComponent("\(head)-\(base)", isDirectory: true) }

    private func hasCrawl(_ folder: URL) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent("crawl.json").path) }

    private func privateFolder(_ dir: URL) {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: Sessions

    /// The owner of the walk running now (a worktree path, or "changes:...").
    var runningOwner: String? { current?.owner }

    func entry(of worktree: String) -> Entry? { entries[worktree] }

    /// A build of the session was filed (a rebuild landed, a recipe built one, or a session with a build was
    /// started): walk it when the workspace's `auto` asks to. `onTurnEnd` is treated as `onBuild` until the Claude
    /// link can tell a turn's end. `withData`: the workspace's "walk with my signed-in data" (off by default).
    func buildArrived(worktree: String, build: Build, auto: Auto, withData: Bool = false) {
        request(worktree: worktree, build: build, force: false, walk: auto != .off, withData: withData)
    }

    /// "Walk again": walks the build now whatever the setting, and whatever is cached.
    func walkAgain(worktree: String, build: Build, withData: Bool = false) {
        request(worktree: worktree, build: build, force: true, walk: true, withData: withData)
    }

    /// "Stop walking": the session's running or queued walk ends and the row says so.
    func stop(worktree: String) {
        var was = false
        queue.removeAll { if $0.owner == worktree { was = true; return true } else { return false } }
        if let job = current, job.owner == worktree, !job.isChanges {
            job.stopped = true
            cancel(job)
            was = true
        }
        if was, var e = entries[worktree] { e.status = .stopped; entries[worktree] = e; onChange?() }
    }

    /// A worktree is gone (or its repository was removed): its queued and running walks stop, its row goes, and the
    /// folder of a walk that was running goes with it. Its finished evidence goes with its builds, when the store
    /// prunes them.
    func forget(worktree: String) {
        queue.removeAll { $0.owner == worktree }
        if let job = current, job.owner == worktree { job.forgotten = true; cancel(job) }
        if entries[worktree] != nil { entries[worktree] = nil; onChange?() }
    }

    func isWalking(_ worktree: String) -> Bool {
        switch entries[worktree]?.status { case .queued?, .walking?: return true; default: return false }
    }

    private func walkJob(owner: String, build: Build, slot: String?) -> Job {
        let dir = evidenceFolder.appendingPathComponent(build.key, isDirectory: true)
        return Job(owner: owner, build: build, kind: .walk(slot: slot), part: dir.appendingPathComponent("map.part", isDirectory: true),
                   final: dir.appendingPathComponent("map", isDirectory: true))
    }

    private func request(worktree: String, build: Build, force: Bool, walk: Bool, withData: Bool) {
        // Two builds of one session can arrive in either order (they are filed on a concurrent queue): the newest
        // one, by its own date, is the one that counts.
        if !force, let e = entries[worktree], e.date > build.date { return }
        if !force, let e = entries[worktree], e.key == build.key {
            switch e.status {
            case .queued, .walking, .done: return
            default: break
            }
        }
        let map = mapFolder(for: build.key)
        if !force, hasCrawl(map), let data = ScreenMapData.read(map) {
            drop(worktree)
            entries[worktree] = Entry(key: build.key, date: build.date, status: Self.done(data), note: nil)
            onChange?()
            return
        }
        guard walk else {
            // Off: nothing runs, and a row that showed an older build's map stops showing it.
            drop(worktree)
            if entries[worktree] != nil { entries[worktree] = nil; onChange?() }
            return
        }
        drop(worktree)
        if force { try? fm.removeItem(at: map) }
        // The data of this session is used only when the workspace asked for it.
        let slot = withData ? (controller?.sessions.first { $0.worktree.path == worktree }?.slot ?? SessionStore.slot(for: URL(fileURLWithPath: worktree))) : nil
        entries[worktree] = Entry(key: build.key, date: build.date, status: .queued, note: nil)
        let job = walkJob(owner: worktree, build: build, slot: slot)
        job.force = force
        queue.append(job)
        onChange?()
        pump()
    }

    static func done(_ data: ScreenMapData) -> Status {
        .done(screens: data.screens.count, crashes: data.crashes.count, unfinished: data.incomplete.contains { !$0.hasPrefix("--max-depth") })   // a depth limit is the budget's choice, not a walk cut short
    }

    /// Removes the owner's queued jobs and cancels its running one (a newer build has come).
    private func drop(_ owner: String) {
        queue.removeAll { $0.owner == owner }
        if let job = current, job.owner == owner { cancel(job) }
    }

    // MARK: Map history

    /// Snapshots being filed, by build key.
    private var filing: [String: Task<Void, Never>] = [:]

    /// The profile of the walks a comparison makes (and so of the snapshots it files): the queue's budget, light captures,
    /// no signed-in data.
    func changesProfile(start: String? = nil) -> MapProfile {
        Self.profile(depth: budget.depth, seconds: budget.seconds, appearances: ["light"], start: start, signedIn: false, offline: false)
    }

    static func profile(depth: Int, seconds: Int, appearances: [String], start: String?, signedIn: Bool, offline: Bool) -> MapProfile {
        MapProfile(depth: depth, seconds: seconds, starts: (start?.isEmpty == false) ? [start!] : [], combos: appearances,
                   signIn: signedIn ? "session-data" : nil, offline: offline)
    }

    /// A finished walk of a build that has a clean commit is filed in the history store, off the main thread.
    private func file(_ job: Job, folder: URL) {
        guard let profile = job.profile, History.fileable(job.build) else { return }
        let build = job.build, root = store.root, engine = Engine.shared.version
        let all = controller?.workspaces ?? []
        let own = controller?.sessions.first { $0.worktree.path == job.owner }?.workspace.path
        let candidates = own.map { p in all.filter { $0.root.path == p } } ?? all
        let key = build.key
        filing[key] = Task { @MainActor [weak self] in
            await Task.detached { await History.file(walk: folder, build: build, profile: profile, candidates: candidates, stateRoot: root, engine: engine) }.value
            self?.filing[key] = nil
        }
    }

    /// Waits for the snapshot of this build's walk to be filed, when one is being.
    func awaitFiling(_ build: Build) async {
        if let t = filing[build.key] { await t.value }
    }

    /// Walks only `head` (the same budgets), for a comparison whose base is already in the history; the walk files its
    /// snapshot. Cached: a build that has its map is answered at once. Callers asking for the same build share the run.
    @discardableResult
    func walkHead(_ head: Build, progress: ((CrawlRun.Event) -> Void)? = nil, completion: @escaping (Result<ChangesResult, Failure>) -> Void) -> Token {
        let token = Token()
        let final = mapFolder(for: head.key)
        let owner = "map:\(head.key)"
        if hasCrawl(final), let data = ScreenMapData.read(final) {
            DispatchQueue.main.async { completion(.success(ChangesResult(folder: final, map: data, summary: Self.summary(of: final)))) }
            return token
        }
        let job: Job
        if let running = current, running.owner == owner, !running.cancelled { job = running }
        else if let queued = queue.first(where: { $0.owner == owner }) { job = queued }
        else {
            job = walkJob(owner: owner, build: head, slot: nil)
            queue.append(job)
        }
        let waiter = Job.Waiter(completion: completion, progress: progress)
        job.waiters.append(waiter)
        token.cancelAction = { [weak self, weak job] in
            guard let self, let job, let i = job.waiters.firstIndex(where: { $0.id == waiter.id }) else { return }
            job.waiters.remove(at: i).completion(.failure(Failure(message: "cancelled")))
            guard job.waiters.isEmpty else { return }
            if self.current === job { self.cancel(job) } else { self.queue.removeAll { $0 === job } }
        }
        pump()
        return token
    }

    // MARK: Comparisons

    /// Walks `head` against `base` (`crawl.py HEAD --base BASE`, the same budgets) and tells the result, on the main
    /// thread. Cached by the pair: a finished one answers at once. The run joins the one walk at a time, and
    /// callers asking for the same pair share it: a token's cancel removes only its own caller, and the run ends
    /// when none is left. No data slot is used: the crawler cannot keep data across two builds.
    @discardableResult
    func changes(head: Build, base: Build, start: String? = nil, baseOption: String = "", progress: ((CrawlRun.Event) -> Void)? = nil,
                 completion: @escaping (Result<ChangesResult, Failure>) -> Void) -> Token {
        let token = Token()
        let folder = changesFolder(head: head.key, base: base.key)
        let owner = "changes:\(head.key)-\(base.key)"
        if hasCrawl(folder), let data = ScreenMapData.read(folder) {
            DispatchQueue.main.async { completion(.success(ChangesResult(folder: folder, map: data, summary: Self.summary(of: folder)))) }
            return token
        }
        let job: Job
        if let running = current, running.owner == owner, !running.cancelled { job = running }
        else if let queued = queue.first(where: { $0.owner == owner }) { job = queued }
        else {
            job = Job(owner: owner, build: head, kind: .changes(base: base),
                      part: changesFolder.appendingPathComponent("\(head.key)-\(base.key).part", isDirectory: true), final: folder)
            job.start = start
            job.baseOption = baseOption
            queue.append(job)
        }
        let waiter = Job.Waiter(completion: completion, progress: progress)
        job.waiters.append(waiter)
        token.cancelAction = { [weak self, weak job] in
            guard let self, let job, let i = job.waiters.firstIndex(where: { $0.id == waiter.id }) else { return }
            job.waiters.remove(at: i).completion(.failure(Failure(message: "cancelled")))
            // The run goes only when nobody is left waiting for it.
            guard job.waiters.isEmpty else { return }
            if self.current === job { self.cancel(job) } else { self.queue.removeAll { $0 === job } }
        }
        pump()
        return token
    }

    static func summary(of folder: URL) -> ChangesSummary {
        var s = ChangesSummary()
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("crawl.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pairs = json["compare"] as? [[String: Any]] else { return s }
        for p in pairs {
            switch p["status"] as? String {
            case "same": s.same += 1
            case "changed": s.changed += 1
            case "new": s.new += 1
            case "gone": s.gone += 1
            default: break
            }
        }
        return s
    }

    // MARK: The queue

    private func pump() {
        guard current == nil else { return }
        while let next = queue.first {
            // The same build in two sessions: the first walk made the map the second one wants.
            if !next.isChanges, !next.force, hasCrawl(next.final), let data = ScreenMapData.read(next.final) {
                queue.removeFirst()
                if var e = entries[next.owner], e.key == next.build.key { e.status = Self.done(data); entries[next.owner] = e; onChange?() }
                let waiters = next.waiters
                next.waiters.removeAll()
                for w in waiters { w.completion(.success(ChangesResult(folder: next.final, map: data, summary: Self.summary(of: next.final)))) }
                continue
            }
            if shouldPause?(next.owner) == true {
                guard retry == nil else { return }
                retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.retry = nil; self?.pump() }
                return
            }
            queue.removeFirst()
            current = next
            started += 1
            begin(next)
            return
        }
    }

    private func begin(_ job: Job) {
        guard let python = SnapshotRun.python() else {
            finish(job, .failed("Walking needs Python 3, and this Mac has none. Install the command line tools (xcode-select --install in Terminal)."))
            return
        }
        let out = job.part
        var s = CrawlRun.Settings()
        s.depth = budget.depth
        s.seconds = budget.seconds
        s.jobs = budget.jobs
        s.appearances = ["light"]
        s.background = true   // evidence walks yield to everything the person is doing
        if case .changes(let base) = job.kind { s.base = base.apk; s.start = job.start; s.baseOption = job.baseOption }
        else if job.owner.hasPrefix("map:") { s.start = job.start }
        // The clone, and the rest of the set-up, off the main thread (a copy fallback of a big slot takes a while).
        let root = dataRoot
        var slotName: String?
        if case .walk(let slot) = job.kind { slotName = slot }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            try? fm.removeItem(at: out)
            try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var settings = s
            var clone: String?
            var note: String?
            SlotClone.sweep(in: root)
            let fresh = SlotClone.freshName()
            if let slot = slotName {
                switch SlotClone.make(slot: slot, in: root) {
                case .cloned(let name):
                    clone = name
                    settings.keepData = true
                    settings.jobs = 1   // the crawler walks a kept slot with one simulator
                    settings.engineOptions = ["--data-slots", name]
                    note = "walked signed in, on a copy of this session's data with one simulator; the session's own data is untouched"
                case .none:
                    clone = fresh
                    settings.engineOptions = ["--data-slots", fresh]
                    note = "walked fresh: this session has no data yet"
                case .failed(let why):
                    clone = fresh
                    settings.engineOptions = ["--data-slots", fresh]
                    note = "walked fresh: this session's data could not be copied (\(why))"
                }
            } else {
                clone = fresh
                settings.engineOptions = ["--data-slots", fresh]
                if !job.isChanges { note = "walked fresh, with no sign-in (\"Walk with my signed-in data\" is off for this repository)" }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                job.clone = clone
                job.note = note
                // A snapshot's profile is the walk's own settings: signed-in only when the data was really copied.
                job.profile = Self.profile(depth: settings.depth, seconds: settings.seconds, appearances: settings.appearances, start: settings.start,
                                           signedIn: settings.keepData && slotName != nil, offline: settings.offline)
                if job.cancelled { self.finish(job, .cancelled); return }
                let run = CrawlRun(python: python, apk: job.build.apk, out: out, settings: settings)
                job.run = run
                run.onEvent = { [weak self] e in self?.event(e, job) }
                run.onFinish = { [weak self] o in
                    switch o {
                    case .finished: self?.finish(job, .finished)
                    case .failed(let why): self?.finish(job, .failed(why))
                    case .cancelled: self?.finish(job, .cancelled)
                    }
                }
                run.start()
            }
        }
    }

    private func event(_ e: CrawlRun.Event, _ job: Job) {
        if job.forwardsProgress { job.waiters.forEach { $0.progress?(e) }; return }
        guard var entry = entries[job.owner], entry.key == job.build.key else { return }
        switch e {
        case .level(let depth, _, let known): entry.status = .walking(depth: depth, known: known)
        case .capturing(let screens, _): entry.status = .walking(depth: -1, known: screens)
        case .line: return
        }
        entries[job.owner] = entry
        onChange?()
    }

    private func cancel(_ job: Job) {
        guard !job.cancelled else { return }
        job.cancelled = true
        cancelledRuns += 1
        job.run?.cancel()
    }

    private enum End { case finished, failed(String), cancelled }

    private func finish(_ job: Job, _ end: End) {
        guard current === job else { return }
        current = nil
        switch end {
        case .finished: break
        case .failed(let why): NSLog("Greenroom: a walk of \(job.build.key) failed: \(why)")
        case .cancelled: NSLog("Greenroom: the walk of \(job.build.key) was cancelled\(job.stopped ? " (stopped)" : "")")
        }
        if let name = job.clone { let root = dataRoot; DispatchQueue.global(qos: .utility).async { SlotClone.remove(name, in: root) } }
        let part = job.part, final = job.final
        var result: Result<ChangesResult, Failure> = .failure(Failure(message: "cancelled"))
        var status: Status?
        switch end {
        case .finished where job.forgotten || job.cancelled:
            try? fm.removeItem(at: part)
        case .finished:
            try? fm.removeItem(at: final)
            if (try? fm.moveItem(at: part, to: final)) != nil, let data = ScreenMapData.read(final) {
                status = Self.done(data)
                result = .success(ChangesResult(folder: final, map: data, summary: Self.summary(of: final)))
                if !job.isChanges { file(job, folder: final) }
            } else {
                status = .failed("The walk finished but its map could not be read.")
                result = .failure(Failure(message: "the walk's map could not be read"))
            }
        case .failed(let why):
            try? fm.removeItem(at: part)
            status = .failed(why)
            result = .failure(Failure(message: why))
        case .cancelled:
            try? fm.removeItem(at: part)
            status = job.stopped ? .stopped : nil
        }
        if job.forgotten, !job.isChanges { try? fm.removeItem(at: final.deletingLastPathComponent()); status = nil }
        if !job.isChanges, let status, var e = entries[job.owner], e.key == job.build.key {
            e.status = status
            e.note = job.note
            entries[job.owner] = e
        }
        let waiters = job.waiters
        job.waiters.removeAll()
        for w in waiters { w.completion(result) }
        onChange?()
        pruneToCap(force: true)
        pump()
    }

    /// Kills the walk's processes and removes its clone (app quit).
    func shutdown() {
        queue.removeAll()
        retry?.invalidate()
        if let job = current {
            job.cancelled = true
            job.run?.cancel(wait: true)
            if let name = job.clone { SlotClone.remove(name, in: dataRoot) }
        }
    }

    // MARK: Pausing

    /// When the person last used one of the app's own simulators (a click, a key or a scroll on a device view).
    private(set) var lastInput = Date.distantPast
    private var inputMonitor: Any?

    /// Starts listening for the person's input to a device (for `interacting`). Once.
    func watchInput() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            var v = event.window?.contentView?.hitTest(event.locationInWindow)
            if event.type == .keyDown { v = event.window?.firstResponder as? NSView }
            while let view = v { if view is SimulatorView { self?.lastInput = Date(); break }; v = view.superview }
            return event
        }
    }

    /// True while the person used a simulator in the last 30 s: a walk does not start then, and starts by itself
    /// once they stop (the queue looks again every 5 s).
    var interacting: Bool { Date().timeIntervalSince(lastInput) < 30 }

    // MARK: Size cap

    /// The size cap of `evidence/` and `changes/` together, in bytes: Settings' "evidenceCapGB" (default 5).
    static var capBytes: Int64 {
        let gb = UserDefaults.standard.object(forKey: "evidenceCapGB") as? Double ?? 5
        return Int64(max(0.001, gb) * 1_073_741_824)
    }

    private var lastPrune = Date.distantPast
    private var pruning = false

    /// Removes the oldest evidence folders until what is kept fits the cap. Never the folder of an owner that is
    /// queued or running: that is decided when the victims are chosen, not when the call was made. A call that is
    /// not `force`d (the sidebar's refresh) runs at most every 3 minutes; a walk's end forces one. The folders are
    /// listed once, for size and newest file together.
    func pruneToCap(cap: Int64 = Evidence.capBytes, force: Bool = false) {
        guard !pruning, force || Date().timeIntervalSince(lastPrune) > 180 else { return }
        pruning = true
        lastPrune = Date()
        let roots = [evidenceFolder, changesFolder]
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            var items: [(url: URL, size: Int64, date: Date)] = []
            for root in roots {
                for d in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                    let (size, date) = Self.measure(d)
                    items.append((d, size, date))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let busy = self.busyFolders()
                var total = items.reduce(0) { $0 + $1.size }
                var victims: [URL] = []
                for item in items.sorted(by: { $0.date < $1.date }) where total > cap && !busy.contains(item.url.path) {
                    victims.append(item.url)
                    total -= item.size
                }
                for v in victims { try? fm.removeItem(at: v) }
                self.pruning = false
                if !victims.isEmpty { self.clearRowsOfRemoved(victims) }
            }
        }
    }

    /// The top-level folders of what is queued or running now: their evidence is not to be pruned.
    private func busyFolders() -> Set<String> {
        var out = Set<String>()
        for job in queue + (current.map { [$0] } ?? []) {
            switch job.kind {
            case .walk: out.insert(evidenceFolder.appendingPathComponent(job.build.key).path)
            case .changes(let base):
                out.insert(changesFolder.appendingPathComponent("\(job.build.key)-\(base.key)").path)
                out.insert(job.part.path)
            }
        }
        return out
    }

    /// A pruned map no longer counts on its row.
    private func clearRowsOfRemoved(_ removed: [URL]) {
        let keys = Set(removed.map { $0.lastPathComponent })
        var changed = false
        for (owner, e) in entries where keys.contains(e.key) {
            if case .done = e.status, !hasCrawl(mapFolder(for: e.key)) { entries[owner] = nil; changed = true }
        }
        if changed { onChange?() }
    }

    /// Size and the newest modification time of a folder, in one pass.
    static func measure(_ folder: URL) -> (Int64, Date) {
        var n: Int64 = 0
        var best = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey]) else { return (0, best) }
        for case let f as URL in walk {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey])
            if v?.isRegularFile == true { n += Int64(v?.totalFileAllocatedSize ?? 0) }
            if let d = v?.contentModificationDate, d > best { best = d }
        }
        return (n, best)
    }

    // MARK: Row

    /// "walking… 4 screens", "7 screens", ... (nil when the session has nothing to say).
    func label(_ e: Entry) -> String {
        switch e.status {
        case .queued: return "walk queued"
        case .walking(_, let known): return known > 0 ? "walking… \(known) screen\(known == 1 ? "" : "s")" : "walking…"
        case .done(let n, let crashes, let unfinished):
            return "\(n) screen\(n == 1 ? "" : "s")" + (crashes > 0 ? ", \(crashes) crash\(crashes == 1 ? "" : "es")" : "") + (unfinished ? ", not finished" : "")
        case .failed: return "walk failed"
        case .stopped: return "walk stopped"
        }
    }

    func detail(_ e: Entry) -> String {
        var lines: [String] = []
        switch e.status {
        case .failed(let why): lines.append(why)
        case .stopped: lines.append("The walk was stopped. \"Walk again\" starts it.")
        case .done(_, _, true): lines.append("The walk ran out of time before it had tried everything. \"Walk again\" tries again.")
        default: break
        }
        if let n = e.note { lines.append(n.prefix(1).uppercased() + n.dropFirst() + ".") }
        lines.append(Self.limits)
        return lines.joined(separator: "\n")
    }

    /// The row's evidence button: its label is the status, a click opens the Screen Map on that build's run.
    /// What `badge(for:)` shows, for the sidebar to tell whether the row changed.
    func badgeKey(for session: Session) -> String {
        guard let e = entries[session.worktree.path] else { return "" }
        return label(e) + "|" + detail(e)
    }

    func badge(for session: Session) -> NSView? {
        guard let e = entries[session.worktree.path] else { return nil }
        let b = NSButton(title: label(e), target: self, action: #selector(openMapClicked(_:)))
        b.isBordered = false
        b.font = .systemFont(ofSize: 10, weight: .medium)
        b.contentTintColor = { if case .failed = e.status { return .systemOrange } else { return .secondaryLabelColor } }()
        b.identifier = NSUserInterfaceItemIdentifier(session.worktree.path)
        b.toolTip = detail(e)
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.isEnabled = { if case .done = e.status { return true } else { return false } }()
        return b
    }

    @objc private func openMapClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, let e = entries[path], case .done = e.status else { return }
        controller?.openMap(folder: mapFolder(for: e.key))
    }

    // MARK: Context menu

    /// Items for the sidebar's session-row menu; they act on `clickedSession`.
    func menuItems() -> [NSMenuItem] {
        let again = NSMenuItem(title: "Walk Again", action: #selector(walkAgainMenu(_:)), keyEquivalent: "")
        let stop = NSMenuItem(title: "Stop Walking", action: #selector(stopMenu(_:)), keyEquivalent: "")
        let auto = NSMenuItem(title: "Walk New Builds Automatically", action: #selector(autoMenu(_:)), keyEquivalent: "")
        let data = NSMenuItem(title: "Walk with My Signed-In Data", action: #selector(dataMenu(_:)), keyEquivalent: "")
        for i in [again, stop, auto, data] { i.target = self }
        return [.separator(), again, stop, auto, data]
    }

    @objc private func walkAgainMenu(_ sender: Any?) { clickedSession().map { controller?.walkAgain($0) } }
    @objc private func stopMenu(_ sender: Any?) { clickedSession().map { controller?.stopWalking($0) } }
    @objc private func dataMenu(_ sender: Any?) {
        guard let s = clickedSession(), let c = controller else { return }
        c.setWalkWithData(!c.walksWithData(s), for: s)
    }
    @objc private func autoMenu(_ sender: Any?) {
        guard let s = clickedSession(), let c = controller else { return }
        c.setAuto(c.auto(of: s) == .off ? .onBuild : .off, for: s)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let s = clickedSession() else { return false }
        switch item.action {
        case #selector(walkAgainMenu(_:))?: return controller?.hasBuild(s) == true
        case #selector(stopMenu(_:))?: return isWalking(s.worktree.path)
        case #selector(autoMenu(_:))?: item.state = controller?.auto(of: s) == .off ? .off : .on; return true
        case #selector(dataMenu(_:))?: item.state = controller?.walksWithData(s) == true ? .on : .off; return true
        default: return true
        }
    }
}

/// A clone of a session's data slot for a walk to use and lose: the engine keeps a slot as
/// `cache/data/<package>/<slot>-N` with a `<slot>-N.device` beside it (its /sdcard and Settings values); instance 0
/// is the session's simulator. Verified by running `crawl.py --keep-data -- --data-slots NAME`: it uses exactly that
/// slot (one simulator), and the original's files are byte for byte what they were.
enum SlotClone {
    enum Outcome { case cloned(String), none, failed(String) }

    static func freshName(prefix: String = "evg") -> String { prefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)) }

    /// Clones `<slot>-0` (and its `.device` folder) of every package that has one to a throwaway slot name.
    static func make(slot: String, in root: URL, prefix: String = "evg") -> Outcome {
        let fm = FileManager.default
        let name = freshName(prefix: prefix)
        var cloned = false
        for pkg in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let source = pkg.appendingPathComponent(slot + "-0", isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { continue }
            for suffix in ["", ".device"] {
                let from = pkg.appendingPathComponent(slot + "-0" + suffix), to = pkg.appendingPathComponent(name + "-0" + suffix)
                guard fm.fileExists(atPath: from.path) else { continue }
                // An APFS clone shares the blocks; anywhere else a plain copy does the job.
                if clonefile(from.path, to.path, 0) != 0 {
                    do { try fm.copyItem(at: from, to: to) } catch {
                        remove(name, in: root)
                        return .failed(error.localizedDescription)
                    }
                }
            }
            cloned = true
        }
        return cloned ? .cloned(name) : .none
    }

    /// Deletes every folder of the throwaway slot, in every package.
    static func remove(_ name: String, in root: URL) {
        let fm = FileManager.default
        for pkg in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for e in (try? fm.contentsOfDirectory(at: pkg, includingPropertiesForKeys: nil)) ?? [] where e.lastPathComponent.hasPrefix(name + "-") {
                try? fm.removeItem(at: e)
            }
        }
    }

    /// Throwaway slots a crash left behind (a day old: another Greenroom's live walk is never touched).
    static func sweep(in root: URL) {
        let fm = FileManager.default
        for pkg in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for e in (try? fm.contentsOfDirectory(at: pkg, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where e.lastPathComponent.hasPrefix("evg") {
                let d = (try? e.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                if Date().timeIntervalSince(d) > 86_400 { try? fm.removeItem(at: e) }
            }
        }
    }
}

extension SessionStore {
    /// Removes what was captured for a build that is pruned: its walk and every comparison it is a side of.
    func removeEvidence(of key: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: root.appendingPathComponent("evidence/\(key)", isDirectory: true))
        let changes = root.appendingPathComponent("changes", isDirectory: true)
        for d in (try? fm.contentsOfDirectory(at: changes, includingPropertiesForKeys: nil)) ?? [] {
            let name = d.lastPathComponent.replacingOccurrences(of: ".part", with: "")
            if name.split(separator: "-").map(String.init).contains(key) { try? fm.removeItem(at: d) }
        }
    }
}
