import AppKit

/// What Greenroom captures for a session's build by itself (docs/SESSIONS-PLAN.md, "3. Evidence", the walk): one
/// background queue that runs the screen map's crawl (`CrawlRun`) on hidden simulators, never in the sidebar or on
/// the stage.
///
///     evidence/<build key>/map/              crawl.py's output (crawl.json, screens/...); its presence is the cache
///     changes/<head key>-<base key>/         crawl.py --base output (`changes(head:base:...)`)
///
/// - One walk at a time across the app: each is a job of the job queue (`JobQueue`, the "walk" lane), which decides
///   when it starts and is where the person holds, reorders, pauses and cancels them. A newer build of a session
///   cancels that session's running or queued walk.
/// - A walk runs on a clone of the session's data slot, never the slot itself (`SlotClone`), so it starts where the
///   person is signed in and changes nothing of theirs; a session with no data yet, or a clone that cannot be made,
///   is walked fresh, and the row's detail says so.
/// - A build whose map exists is not walked again. The map is made in `map.part` and renamed in whole.
/// - Main thread only, except where marked.
final class Evidence: NSObject, NSMenuItemValidation {
    struct Budget {
        /// The whole app, with no time budget: a build's map is the app's history, so it has to be all of it. The first
        /// walk of a repository is the long one; later ones redo only the screens a commit's changed files could touch.
        var depth = 0
        var seconds = 0
        var jobs = CrawlRun.parallel
    }

    enum Status: Equatable {
        case queued
        case walking(depth: Int, known: Int)
        case done(screens: Int, crashes: Int, unfinished: Bool)
        case failed(String)
        case stopped
        /// Not walked: the repository's maps are walked signed in, and there is no sign-in to walk with.
        case needsSignIn
    }

    /// What the row of one session shows about its newest build.
    struct Entry: Equatable {
        var key: String
        /// The build's own date: a build that arrives older than the newest one seen for the session is ignored.
        var date: Date
        var status: Status
        /// How the walk was made ("on a copy of this session's data", "fresh: ...").
        var note: String?
        /// Whether the walk redid everything or only what a change could touch, and what keeping it honest found.
        var impact: ImpactNote? = nil
        /// What sharing the map through git did, or what went wrong, in words (nil when the workspace does not share).
        var share: String? = nil
        /// While walking: the screens the walk has finished with (the crawler's `--events`; 0 when it has none).
        var explored = 0
        /// While walking: the whole app is being walked, not only what a change could touch.
        var whole = false
        /// The finished walk is in the history as its commit's snapshot.
        var saved = false
        /// Whether the finished walk met a sign-in (its first screen, or screens inside).
        var wall = SignInWall.none
        /// The walk started from the app's kept sign-in.
        var signedIn = false
        /// Screens that differ from the base branch's map (added, changed, removed), once the walk is filed and the
        /// project has that map. Nil: not known (no map of the base branch yet, a build of the base branch itself).
        var changed: Int? = nil
        /// The same in words, for the tooltip: "2 added, 1 changed against main at 53ffe80".
        var changedWords: String? = nil
        /// While walking: the person paused it in the job queue.
        var paused = false
    }

    /// A walk's plan and what came of it (packages I1, I2), kept beside its map as `greenroom-impact.json`. Absent for a
    /// walk the engine gave no choice about (the released engine walks everything, as before).
    struct ImpactNote: Codable, Equatable {
        /// Walked everything; `reason` says why.
        var full: Bool
        var reason: String?
        /// Screens walked, and in all (the rest carried from `base`).
        var walked: Int
        var total: Int
        /// Files changed since the walk it was seeded from.
        var files: Int
        var base: String?
        /// A full walk compared with a quick one: how many carried screens differed.
        var misses: Int?
        /// "Verify carried screens", in words, while it runs and after.
        var verify: String?
        /// Why each walked screen was walked again ("SettingsFragment.kt changed"), by screen id. Nil for a full walk.
        var why: [String: [String]]?
        /// Changes the walk could not trace to screens ("app start changed (App.kt)"): screens they reach were carried.
        var unplaced: [String]?
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
    static let limits = "The walk taps through the whole app, several simulators at once. It does not reach screens behind typed input, a signed-in server state it has no data for, or a gesture it does not try."

    var store: SessionStore = .shared {
        didSet {
            guard oldValue.root != store.root else { return }
            // Another store (a check's own): nothing queued or shown belongs to it.
            unqueue { _ in true }
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
    /// The newest build asked for each worktree ("Verify carried screens" acts on it).
    private var lastBuild: [String: Build] = [:]
    /// Worktrees whose next walk is full ("Walk Everything Again").
    private var fullNext = Set<String>()
    /// Why the next walk of a worktree is full when it was not the person who asked (a verification after an engine update).
    private var fullWhy: [String: String] = [:]
    private var queue: [Job] = []
    private var current: Job?
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
        /// Its data clone is being removed; the end is published when that is done.
        var finishing = false
        /// "Walk Everything Again": a full walk whatever the impact says.
        var forceFull = false
        /// The walk starts from the app's kept sign-in (SignIns), not the session's own data.
        var kept = false
        /// How it walks (I1), once planned; the folder holding the seed and the only-file.
        var plan: History.WalkPlan?
        var workDir: URL?
        /// "Verify carried screens" of this worktree's map (its part and final folders are `verify.part`, `verify`).
        var verifyOf: String?
        /// The verification follows an engine update (the engine the map was carried from): a screen whose structure
        /// the new engine reads differently starts a full walk.
        /// The walk compared with its seed (`--diff-seed`) failed in the engine: it is made once more without the comparison.
        var plainSeed = false
        /// The commit's stored map was taken as this build's: no walk was made.
        var adopted = false
        var engineCheck: String?
        var fullWhy: String?
        /// The session or repository went: the walk's folder goes with it.
        var forgotten = false
        /// Its place in the job queue (Jobs.swift).
        var ticket: QueueJob?
        /// While walking: screens found and screens finished with, for the queue's progress.
        var known = 0
        var explored = 0
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
        /// The walk uses a data slot that is not the kept sign-in's: the session's own data was asked for.
        var withData: Bool { if case .walk(let slot) = kind { return slot != nil && !kept } else { return false } }
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
    func changesFolder(head: String, base: String, start: String? = nil, baseOption: String = "") -> URL {
        changesFolder.appendingPathComponent(Self.pairName(head: head, base: base, start: start, baseOption: baseOption), isDirectory: true)
    }

    /// A comparison's folder name: the two keys, and when it has its own start or base option a hash of them, so a run
    /// with either is never answered from one made without (or with others).
    static func pairName(head: String, base: String, start: String?, baseOption: String) -> String {
        let extra = (start ?? "") + "\u{0}" + baseOption
        return "\(head)-\(base)" + (extra == "\u{0}" ? "" : "-o" + String(MapJSON.sha256(extra).prefix(8)))
    }

    private func hasCrawl(_ folder: URL) -> Bool { fm.fileExists(atPath: folder.appendingPathComponent("crawl.json").path) }

    private func privateFolder(_ dir: URL) {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: Sessions

    /// The owner of the walk running now (a worktree path, or "changes:...").
    var runningOwner: String? { current?.owner }

    func entry(of worktree: String) -> Entry? { entries[worktree] }

    /// A build of the session was filed (a rebuild landed, a recipe built one, or a session with a build was
    /// started): walk it when the workspace's `auto` asks to. With `onTurnEnd`, a build that lands while an agent is
    /// in the middle of a turn in that worktree (HookSessions: its hooks say so) is not walked: the agent is likely
    /// to build again, and the controller sends the build here once more when the turn ends. With no agent heard in
    /// the worktree it is `onBuild`. `withData`: the workspace's "walk with my signed-in data" (off by default).
    func buildArrived(worktree: String, build: Build, auto: Auto, withData: Bool = false) {
        let held = auto == .onTurnEnd && HookSessions.shared.midTurn(in: URL(fileURLWithPath: worktree))
        request(worktree: worktree, build: build, force: false, walk: auto != .off && !held, withData: withData)
    }

    /// "Walk again": walks the build now whatever the setting, and whatever is cached.
    func walkAgain(worktree: String, build: Build, withData: Bool = false) {
        request(worktree: worktree, build: build, force: true, walk: true, withData: withData)
    }

    /// "Stop walking": the session's running or queued walk ends and the row says so.
    func stop(worktree: String) {
        var was = unqueue(silent: false) { $0.owner == worktree }
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
        unqueue { $0.owner == worktree }
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
        lastBuild[worktree] = build
        if !force, hasCrawl(map), let data = ScreenMapData.read(map) {
            drop(worktree)
            entries[worktree] = Entry(key: build.key, date: build.date, status: Self.done(data), note: nil, impact: Self.impactNote(map))
            onChange?()
            // A map kept from an earlier run of the app: its count against the base branch is read again.
            let all = controller?.workspaces ?? []
            let own = controller?.sessions.first { $0.worktree.path == worktree }?.workspace.path
            countChanges(owner: worktree, build: build, profiles: walkProfiles(worktree: worktree, withData: withData),
                         candidates: own.map { p in all.filter { $0.root.path == p } } ?? all)
            return
        }
        guard walk else {
            // Off: nothing runs, and a row that showed an older build's map stops showing it.
            drop(worktree)
            if entries[worktree] != nil { entries[worktree] = nil; onChange?() }
            return
        }
        drop(worktree)
        // A map is walked signed in, since only that reaches every screen: with no sign-in to walk with (the kept one,
        // or the session's own data), a walk nobody asked for by hand is not made, and the row says what to do.
        if !force, keptSignIn(worktree) == nil, !withData, controller?.countsUnsigned(controller?.workspaceRoot(ofOwner: worktree)) == false {
            entries[worktree] = Entry(key: build.key, date: build.date, status: .needsSignIn, note: nil)
            onChange?()
            return
        }
        if force { try? fm.removeItem(at: map) }
        // The data of this session is used only when the workspace asked for it.
        // The app's kept sign-in ("Sign In Once") comes first; else this session's own data, when the workspace asked for it.
        let kept = keptSignIn(worktree)?.slot
        let slot = kept ?? (withData ? (controller?.sessions.first { $0.worktree.path == worktree }?.slot ?? SessionStore.slot(for: URL(fileURLWithPath: worktree))) : nil)
        entries[worktree] = Entry(key: build.key, date: build.date, status: .queued, note: nil)
        let job = walkJob(owner: worktree, build: build, slot: slot)
        job.kept = kept != nil
        job.force = force
        job.forceFull = fullNext.remove(worktree) != nil
        job.fullWhy = fullWhy.removeValue(forKey: worktree)
        enqueue(job)
        onChange?()
    }

    static func done(_ data: ScreenMapData) -> Status {
        .done(screens: data.screens.count, crashes: data.crashes.count, unfinished: data.incomplete.contains { !$0.hasPrefix("--max-depth") })   // a depth limit is the budget's choice, not a walk cut short
    }

    /// Removes the owner's queued jobs and cancels its running one (a newer build has come).
    private func drop(_ owner: String) {
        unqueue { $0.owner == owner }
        if let job = current, job.owner == owner { cancel(job) }
    }

    // MARK: Map history

    /// Snapshots being filed, by build key.
    private var filing: [String: Task<Void, Never>] = [:]

    /// The profile of the walks a comparison makes (and so of the snapshots it files): the queue's budget, light captures,
    /// no signed-in data.
    /// The profiles a worktree's own walks can have, the likelier first: signed in (the kept sign-in, or the session's
    /// data when the repository asks for it) and not. A walk is signed in only when its data was really copied, so
    /// which of the two a stored map has is known only by looking.
    func walkProfiles(worktree: String, withData: Bool) -> [MapProfile] {
        let quick = controller?.walksQuick(worktree: worktree) == true
        let signedInFirst = keptSignIn(worktree) != nil || withData
        // A map that was not walked signed in is none, unless the repository counts those.
        let unsigned = controller?.countsUnsigned(controller?.workspaceRoot(ofOwner: worktree)) ?? true
        return (signedInFirst ? [true, false] : [false, true]).filter { $0 || unsigned }.map {
            Self.profile(depth: quick ? 2 : budget.depth, seconds: quick ? 120 : budget.seconds, appearances: ["light"], start: nil, signedIn: $0, offline: false,
                         launch: controller?.walkLaunchKey(forOwner: worktree))
        }
    }

    /// `workspace`: the repository compared, whose launch options are part of the profile.
    func changesProfile(start: String? = nil, workspace: URL?) -> MapProfile {
        Self.profile(depth: budget.depth, seconds: budget.seconds, appearances: ["light"], start: start, signedIn: false, offline: false,
                     launch: controller?.walkLaunchKey(forWorkspace: workspace))
    }

    /// `launch`: the repository's launch options for walks (LaunchSettings.walkKey), nil when it has none.
    static func profile(depth: Int, seconds: Int, appearances: [String], start: String?, signedIn: Bool, offline: Bool, launch: String? = nil) -> MapProfile {
        MapProfile(depth: depth, seconds: seconds, starts: (start?.isEmpty == false) ? [start!] : [], combos: appearances,
                   signIn: signedIn ? "session-data" : nil, offline: offline, launch: launch)
    }

    /// A finished walk of a build that has a clean commit is filed in the history store, off the main thread.
    private func file(_ job: Job, folder: URL) {
        guard let profile = job.profile else { return }
        file(build: job.build, owner: job.owner, profile: profile, folder: folder, candidates: candidates(for: job), seed: job.plan?.seedSnapshot, planProblem: job.plan?.shareProblem)
    }

    /// "Save Map to History Anyway": the build of the row's finished walk was made with uncommitted changes; the person
    /// says it stands for its commit, and the walk that is there is filed as that commit's snapshot.
    @discardableResult
    func saveToHistoryAnyway(worktree: String) -> Bool {
        guard let build = lastBuild[worktree], let e = entries[worktree], e.key == build.key, case .done = e.status, build.dirty,
              let sha = build.sha, !sha.isEmpty, !sha.hasPrefix("-") else { return false }
        let folder = mapFolder(for: build.key)
        // The walk's own settings, as it wrote them: the profile is the one the walk was made with.
        guard let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("greenroom.json")))) as? [String: Any] else { return false }
        let profile = Self.profile(depth: meta["depth"] as? Int ?? budget.depth, seconds: meta["seconds"] as? Int ?? budget.seconds,
                                   appearances: meta["appearances"] as? [String] ?? ["light"], start: (meta["start"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                   signedIn: meta["keptData"] as? Bool ?? false, offline: meta["offline"] as? Bool ?? false,
                                   launch: controller?.walkLaunchKey(forOwner: worktree))
        History.accept(build.key)
        let all = controller?.workspaces ?? []
        let own = controller?.sessions.first { $0.worktree.path == worktree }?.workspace.path
        file(build: build, owner: worktree, profile: profile, folder: folder, candidates: own.map { p in all.filter { $0.root.path == p } } ?? all, seed: nil, planProblem: nil)
        onChange?()
        return true
    }

    /// What a build changes against the base branch's map, for its row: counted from the two stored maps (the build's
    /// own, under the first of `profiles` that has one), off the main thread. Nothing for a build of the base branch.
    private func countChanges(owner: String, build: Build, profiles: [MapProfile], candidates: [Workspace]) {
        guard let c = controller, !c.mainBuilds.isTrunk(URL(fileURLWithPath: owner)), History.fileable(build) else { return }
        let names = Dictionary(c.workspaces.map { ($0.root.path, MainBuilds.shortName($0.baseRef)) }, uniquingKeysWith: { a, _ in a })
        let root = store.root, key = build.key
        Task { @MainActor [weak self] in
            let against = await Task.detached { () -> (Int, String)? in
                for profile in profiles {
                    for ws in candidates {
                        guard let snap = await History.snapshot(of: build, workspace: ws.root, profile: profile, stateRoot: root) else { continue }
                        guard let b = await History.baseline(of: build, profile: profile, candidates: [ws], stateRoot: root), b.snapshot.commit != snap.commit else { return nil }
                        let n = MapPairing.diff(head: snap, base: b.snapshot).counts
                        let parts = [(n.added, "added"), (n.modified, "changed"), (n.removed, "removed")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
                        return (n.differing, (parts.isEmpty ? "No screen differs" : parts.joined(separator: ", ")) + " against \(names[ws.root.path] ?? "the base branch") at \(b.snapshot.commit.prefix(7))")
                    }
                }
                return nil
            }.value
            if let self, let against, var e = self.entries[owner], e.key == key, e.changed != against.0 || e.changedWords != against.1 {
                e.changed = against.0; e.changedWords = against.1
                self.entries[owner] = e
                self.onChange?()
            }
        }
    }

    private func file(build: Build, owner: String, profile: MapProfile, folder: URL, candidates: [Workspace], seed: MapSnapshot?, planProblem: String?) {
        guard History.fileable(build) else { return }
        let root = store.root, engine = Engine.shared.version
        let key = build.key
        filing[key] = Task { @MainActor [weak self] in
            let filed = await Task.detached {
                await History.filed(walk: folder, build: build, profile: profile, candidates: candidates, stateRoot: root, engine: engine, seed: seed)
            }.value
            self?.filing[key] = nil
            if let self, filed != nil, var e = self.entries[owner], e.key == key { e.saved = true; self.entries[owner] = e; self.onChange?() }
            if let self, filed != nil { self.countChanges(owner: owner, build: build, profiles: [profile], candidates: candidates) }
            // Sharing through git: said on the row, once, in words; it never stops a walk.
            if let self, let filed, filed.shared != nil || filed.shareProblem != nil || planProblem != nil, var e = self.entries[owner], e.key == key {
                if let why = filed.shareProblem ?? planProblem { e.share = "The map was not shared through git: \(why)" + (filed.shared.map { " (\($0))" } ?? "") }
                else { e.share = "Map shared through git: \(filed.shared!)" }
                self.entries[owner] = e
                self.onChange?()
            }
            // A full walk compared with a quick one (I2): the row says what the quick one missed.
            if let audit = filed?.audit { self?.updateImpact(owner: owner, key: key, folder: folder) { $0.misses = audit.misses.count } }
        }
    }

    /// The workspaces a job's build may belong to: its session's, else all.
    private func candidates(for job: Job) -> [Workspace] {
        let all = controller?.workspaces ?? []
        let worktree = job.verifyOf ?? job.owner
        let own = controller?.sessions.first { $0.worktree.path == worktree }?.workspace.path
        return own.map { p in all.filter { $0.root.path == p } } ?? all
    }

    // MARK: Walking only what changed (I1, I2)

    static func impactNote(_ folder: URL) -> ImpactNote? {
        (try? Data(contentsOf: folder.appendingPathComponent("greenroom-impact.json"))).flatMap { MapJSON.decode(ImpactNote.self, from: $0) }
    }

    private static func writeImpactNote(_ note: ImpactNote, _ folder: URL) {
        try? MapJSON.encode(note).write(to: folder.appendingPathComponent("greenroom-impact.json"), options: .atomic)
    }

    /// Changes a map's impact note on disk and on its row (when the row still shows that build). A map with no note
    /// (the released engine) gets one only for a verification.
    private func updateImpact(owner: String, key: String, folder: URL, _ change: (inout ImpactNote) -> Void) {
        var note = Self.impactNote(folder) ?? ImpactNote(full: true, reason: nil, walked: 0, total: 0, files: 0)
        change(&note)
        Self.writeImpactNote(note, folder)
        if var e = entries[owner], e.key == key { e.impact = note; entries[owner] = e; onChange?() }
    }

    /// Decides how a walk walks (off the main thread) and hands the plan back on the main thread: nil for a comparison.
    private func planWalk(_ job: Job, python: URL, then: @escaping (History.WalkPlan?) -> Void) {
        guard !job.isChanges, let profile = job.profile else { then(nil); return }
        let candidates = candidates(for: job), root = store.root, engine = Engine.shared.version, build = job.build
        let force = job.forceFull, why = job.fullWhy, verify = job.verifyOf != nil
        let unsigned = controller?.countsUnsigned(controller?.workspaceRoot(ofOwner: job.verifyOf ?? job.owner)) ?? true
        let work = job.part.deletingLastPathComponent().appendingPathComponent(verify ? "verify-work" : "impact-work", isDirectory: true)
        job.workDir = work
        Task { @MainActor in
            let plan = await Task.detached(priority: .utility) { () -> History.WalkPlan? in
                let fm = FileManager.default
                try? fm.removeItem(at: work)
                try? fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let support = CrawlRun.support(python: python)
                if verify {
                    guard support.seed else { return nil }
                    return await History.verifyPlan(build: build, profile: profile, candidates: candidates, stateRoot: root, folder: work)
                }
                return await History.plan(build: build, profile: profile, candidates: candidates, stateRoot: root, engine: engine, support: support,
                                          forceFull: force, fullReason: why, unsignedCounts: unsigned, folder: work)
            }.value
            then(plan)
        }
    }

    /// "Walk Everything Again": walks the build now, in full, whatever changed.
    func walkEverythingAgain(worktree: String, build: Build, withData: Bool = false) {
        fullNext.insert(worktree)
        request(worktree: worktree, build: build, force: true, walk: true, withData: withData)
    }

    /// "Verify carried screens": reaches each screen the worktree's newest map carried and compares its structure and
    /// captures, trying no control. The engine has no mode for that alone, so it is a walk seeded from the map with
    /// `--max-actions 0` over the carried ids. What differs is a miss, as for a full walk. False when there is nothing to do.
    @discardableResult
    func verifyCarried(worktree: String, withData: Bool = false, afterEngine: String? = nil) -> Bool {
        guard let build = lastBuild[worktree], let e = entries[worktree], e.key == build.key, case .done = e.status, History.fileable(build) else { return false }
        let owner = "verify:" + worktree
        guard current?.owner != owner, !queue.contains(where: { $0.owner == owner }) else { return true }
        let dir = evidenceFolder.appendingPathComponent(build.key, isDirectory: true)
        // The same data as the session's walks, so the same profile and so the same snapshot.
        let kept = keptSignIn(worktree)?.slot
        let slot = kept ?? (withData ? (controller?.sessions.first { $0.worktree.path == worktree }?.slot ?? SessionStore.slot(for: URL(fileURLWithPath: worktree))) : nil)
        let job = Job(owner: owner, build: build, kind: .walk(slot: slot), part: dir.appendingPathComponent("verify.part", isDirectory: true),
                      final: dir.appendingPathComponent("verify", isDirectory: true))
        job.force = true
        job.verifyOf = worktree
        job.engineCheck = afterEngine
        updateImpact(owner: worktree, key: build.key, folder: mapFolder(for: build.key)) { $0.verify = "verifying carried screens…" }
        enqueue(job)
        return true
    }

    /// A verification's end: its walk compared with the map, in words on the row; its folders go.
    private func finishVerify(_ job: Job, _ end: End) {
        guard let worktree = job.verifyOf else { return }
        let key = job.build.key, map = mapFolder(for: key), part = job.part, work = job.workDir
        let cleanup = { let fm = FileManager.default; try? fm.removeItem(at: part); if let work { try? fm.removeItem(at: work) } }
        switch end {
        case .cancelled: cleanup(); updateImpact(owner: worktree, key: key, folder: map) { $0.verify = nil }
        case .failed(let why): cleanup(); updateImpact(owner: worktree, key: key, folder: map) { $0.verify = "verifying carried screens failed: \(why)" }
        case .finished:
            guard let plan = job.plan, let profile = job.profile else {
                cleanup()
                updateImpact(owner: worktree, key: key, folder: map) { $0.verify = "nothing to verify: this map carried no screens, or this engine cannot start from an earlier walk" }
                return
            }
            let build = job.build, candidates = candidates(for: job), root = store.root, engine = Engine.shared.version
            Task { @MainActor [weak self] in
                let r = await Task.detached { await History.verified(walk: part, plan: plan, build: build, profile: profile, candidates: candidates, stateRoot: root, engine: engine) }.value
                cleanup()
                let words: String
                if let r {
                    words = r.misses.isEmpty ? "verified \(r.checked) carried screen\(r.checked == 1 ? "" : "s"): all as carried"
                        : "verified \(r.checked) carried screen\(r.checked == 1 ? "" : "s"): \(MapImpact.missWords(r.misses.count))"
                } else { words = "verifying carried screens failed: its walk could not be read" }
                self?.updateImpact(owner: worktree, key: key, folder: map) { $0.verify = words; if let r, !r.misses.isEmpty { $0.misses = ($0.misses ?? 0) + r.misses.count } }
                // After an engine update: a carried screen the new engine no longer reads as the same screen means the
                // kept map cannot be trusted, so this build is walked in full. A capture that differs is only a lead.
                if let was = job.engineCheck, let r, let self {
                    let moved = r.misses.filter { $0.why == "its structure changed" }.count
                    if moved > 0, self.lastBuild[worktree]?.key == key {
                        self.fullNext.insert(worktree)
                        self.fullWhy[worktree] = "engine \(Engine.shared.version) reads \(moved) screen\(moved == 1 ? "" : "s") differently than \(was) did"
                        self.request(worktree: worktree, build: build, force: true, walk: true, withData: job.withData)
                    }
                }
            }
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
            enqueue(job, start: false)
        }
        let waiter = Job.Waiter(completion: completion, progress: progress)
        job.waiters.append(waiter)
        token.cancelAction = { [weak self, weak job] in
            guard let self, let job, let i = job.waiters.firstIndex(where: { $0.id == waiter.id }) else { return }
            job.waiters.remove(at: i).completion(.failure(Failure(message: "cancelled")))
            guard job.waiters.isEmpty else { return }
            if self.current === job { self.cancel(job) } else { self.unqueue { $0 === job } }
        }
        if let t = job.ticket { JobQueue.shared.submit(t) }   // a job that is there already stays where it is
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
        let name = Self.pairName(head: head.key, base: base.key, start: start, baseOption: baseOption)
        let folder = changesFolder.appendingPathComponent(name, isDirectory: true)
        let owner = "changes:" + name
        if hasCrawl(folder), let data = ScreenMapData.read(folder) {
            DispatchQueue.main.async { completion(.success(ChangesResult(folder: folder, map: data, summary: Self.summary(of: folder)))) }
            return token
        }
        let job: Job
        if let running = current, running.owner == owner, !running.cancelled { job = running }
        else if let queued = queue.first(where: { $0.owner == owner }) { job = queued }
        else {
            job = Job(owner: owner, build: head, kind: .changes(base: base),
                      part: changesFolder.appendingPathComponent(name + ".part", isDirectory: true), final: folder)
            job.start = start
            job.baseOption = baseOption
            enqueue(job, start: false)
        }
        let waiter = Job.Waiter(completion: completion, progress: progress)
        job.waiters.append(waiter)
        token.cancelAction = { [weak self, weak job] in
            guard let self, let job, let i = job.waiters.firstIndex(where: { $0.id == waiter.id }) else { return }
            job.waiters.remove(at: i).completion(.failure(Failure(message: "cancelled")))
            // The run goes only when nobody is left waiting for it.
            guard job.waiters.isEmpty else { return }
            if self.current === job { self.cancel(job) } else { self.unqueue { $0 === job } }
        }
        if let t = job.ticket { JobQueue.shared.submit(t) }   // a job that is there already stays where it is
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

    /// Asks the job queue to start whatever can start now.
    private func pump() { JobQueue.shared.pump() }

    /// Puts a job in the queue: the job queue starts it (`start`) when no other walk runs and nothing holds it back.
    /// `start` false when the caller still has to finish setting the job up (its waiters): it submits the ticket itself.
    private func enqueue(_ job: Job, start: Bool = true) {
        queue.append(job)
        let ticket = QueueJob(kind: job.verifyOf != nil ? .verify : (job.isChanges ? .compare : .walk), title: title(of: job),
                              owner: job.verifyOf ?? job.owner, lane: "walk")
        ticket.pauseTip = "Freeze the walk and its hidden simulators where they are. A step that was timing out may be tried again."
        ticket.gate = { [weak self, weak job] in
            guard let self, let job, self.shouldPause?(job.owner) == true else { return nil }
            return "waiting until this repository's build is done and the simulators are left alone"
        }
        ticket.begin = { [weak self, weak job] in
            guard let self, let job else { return }
            self.start(job)
        }
        ticket.onCancel = { [weak self, weak job] in
            guard let self, let job else { return }
            self.cancelByPerson(job)
        }
        ticket.onPause = { [weak self, weak job] in
            guard let self, let job, self.current === job, !job.cancelled, let run = job.run, run.isRunning else {
                return "This walk is still getting ready. It can be paused once it is walking."
            }
            run.suspend()
            if let t = job.ticket { JobQueue.shared.suspended(t) }
            self.notePaused(job, true)
            return nil
        }
        ticket.onResume = { [weak self, weak job] in
            guard let job else { return }
            job.run?.resume()
            self?.notePaused(job, false)
        }
        job.ticket = ticket
        if start { JobQueue.shared.submit(ticket) }   // which may start the job in this same call
    }

    /// A session's own walk was paused or resumed: its row says so.
    private func notePaused(_ job: Job, _ paused: Bool) {
        guard !job.forwardsProgress, job.verifyOf == nil, var e = entries[job.owner], e.key == job.build.key, e.paused != paused else { return }
        e.paused = paused
        entries[job.owner] = e
        onChange?()
    }

    /// "Map fix-login", "Compare main with fix-login": what the job queue calls a job.
    private func title(of job: Job) -> String {
        func name(_ owner: String) -> String {
            if owner.hasPrefix("pr:") { return "a pull request's build" }
            if let s = controller?.sessions.first(where: { $0.worktree.path == owner }) { return s.title }
            return URL(fileURLWithPath: owner).lastPathComponent
        }
        func label(_ b: Build) -> String { b.ref.flatMap { $0.isEmpty ? nil : $0 } ?? b.sha.map { String($0.prefix(7)) } ?? String(b.key.prefix(7)) }
        if let worktree = job.verifyOf { return "Verify the map of \(name(worktree))" }
        if case .changes(let base) = job.kind { return "Compare \(label(job.build)) with \(label(base))" }
        if job.owner.hasPrefix("map:") { return "Map \(label(job.build)) to compare" }
        return "Map \(name(job.owner))"
    }

    /// Takes jobs out of the queue, and out of the job queue with them: silently (a newer build replaced them), or
    /// said as cancelled (the person stopped them). True when there was one.
    @discardableResult
    private func unqueue(silent: Bool = true, _ match: (Job) -> Bool) -> Bool {
        var gone: [Job] = []
        queue.removeAll { if match($0) { gone.append($0); return true } else { return false } }
        for job in gone {
            guard let t = job.ticket else { continue }
            if silent { JobQueue.shared.forget(t) } else { JobQueue.shared.finish(t, .cancelled) }
        }
        return !gone.isEmpty
    }

    /// Cancel in the job queue's list: a session's own walk is stopped as "Stop walking" does (its row says so); a
    /// comparison or a verification ends, and whoever waited for it hears "cancelled".
    private func cancelByPerson(_ job: Job) {
        if job.verifyOf == nil, !job.isChanges, !job.owner.hasPrefix("map:") { stop(worktree: job.owner); return }
        if current === job { job.stopped = true; cancel(job); return }
        guard unqueue(silent: false, { $0 === job }) else { return }
        let waiters = job.waiters
        job.waiters.removeAll()
        for w in waiters { w.completion(.failure(Failure(message: "cancelled"))) }
        if let worktree = job.verifyOf { updateImpact(owner: worktree, key: job.build.key, folder: mapFolder(for: job.build.key)) { $0.verify = nil } }
    }

    /// The job queue's go-ahead for a queued job: no other walk runs.
    private func start(_ next: Job) {
        guard let i = queue.firstIndex(where: { $0 === next }) else {
            if let t = next.ticket { JobQueue.shared.forget(t) }
            return
        }
        guard current == nil else {
            // Another Evidence's walk shares the lane, never this one's: asked again shortly rather than run two.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if let t = next.ticket { JobQueue.shared.requeue(t, held: false) } }
            return
        }
        queue.remove(at: i)
        // The same build in two sessions: the first walk made the map the second one wants.
        if !next.isChanges, !next.force, hasCrawl(next.final), let data = ScreenMapData.read(next.final) {
            if var e = entries[next.owner], e.key == next.build.key { e.status = Self.done(data); e.impact = Self.impactNote(next.final); entries[next.owner] = e; onChange?() }
            let waiters = next.waiters
            next.waiters.removeAll()
            for w in waiters { w.completion(.success(ChangesResult(folder: next.final, map: data, summary: Self.summary(of: next.final)))) }
            if let t = next.ticket { JobQueue.shared.forget(t) }
            return
        }
        current = next
        started += 1
        begin(next)
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
        // "Quick Walks Only" for the repository: two taps deep, two minutes.
        if !job.isChanges, controller?.walksQuick(worktree: job.verifyOf ?? job.owner) == true { s.depth = 2; s.seconds = 120 }
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
                    settings.engineOptions = ["--data-slots", name]
                    note = job.kept ? "walked signed in, on copies of the kept sign-in; the kept sign-in is untouched"
                                    : "walked signed in, on copies of this session's data; the session's own data is untouched"
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
                                           signedIn: settings.keepData && slotName != nil, offline: settings.offline,
                                           launch: self.controller?.walkLaunchKey(forOwner: job.verifyOf ?? job.owner))
                if job.cancelled { self.finish(job, .cancelled); return }
                self.planWalk(job, python: python) { [weak self] plan in
                    guard let self else { return }
                    if job.cancelled { self.finish(job, .cancelled); return }
                    var settings = settings
                    job.plan = plan
                    let known = CrawlRun.knownSupport(python: python)
                    settings.events = known?.events ?? false
                    settings.standby = known?.standby ?? false
                    settings.freezeNetwork = known?.freezeNetwork ?? false
                    settings.deterministic = known?.deterministic ?? false
                    if known?.dataIgnore == true { settings.dataIgnore = RepoMapSettings.dataIgnore(in: self.controller?.workspaceRoot(ofOwner: job.verifyOf ?? job.owner)) }
                    if !job.isChanges, var e = self.entries[job.owner], e.key == job.build.key { e.whole = plan?.seed == nil && settings.depth == 0; self.entries[job.owner] = e }
                    if let plan {
                        settings.recordDeps = plan.recordDeps
                        settings.seed = plan.seed
                        settings.onlyFile = plan.onlyFile
                        if job.verifyOf != nil { settings.maxActions = 0 }
                        else if plan.diffSeed, plan.seed != nil, !job.plainSeed { settings.diffControls = plan.diffControls }
                    }
                    if job.verifyOf != nil, plan == nil { self.finish(job, .finished); return }
                    // The commit's map is in the history already (a walk from the Screen Map sheet, or of another
                    // build of the commit): unless the person asked for this walk, the stored map is written out as
                    // this build's and nothing is walked.
                    if job.verifyOf == nil, !job.isChanges, !job.force, !job.forceFull, let snap = plan?.existing, snap.startDeps != nil, !snap.cutShort,
                       let p = job.profile, let store = plan?.existingStore {
                        let part = job.part
                        job.adopted = true
                        job.plan?.reason = "this commit's map was already there (walked \(snap.walked.prefix(10))), so it was not walked again"
                        DispatchQueue.global(qos: .utility).async { [weak self] in
                            let ok = store.writeSeed(snap, to: part)
                            DispatchQueue.main.async {
                                guard let self else { return }
                                if job.cancelled { self.finish(job, .cancelled); return }
                                if ok { NSLog("Greenroom: \(job.build.key) takes the stored map of \(snap.commit.prefix(7)) (\(p.id)); nothing is walked"); self.finish(job, .finished) }
                                else { job.adopted = false; job.force = true; self.begin(job) }
                            }
                        }
                        return
                    }
                    // The repository's skin and launch options: its maps are of the device its simulators show.
                    settings.engineOptions += self.controller?.walkLaunchOptions(forOwner: job.verifyOf ?? job.owner) ?? []
                    let run = CrawlRun(python: python, apk: job.build.apk, out: out, settings: settings)
                    job.run = run
                    run.onEvent = { [weak self] e in self?.event(e, job) }
                    run.onFinish = { [weak self] o in
                        switch o {
                        case .finished: self?.finish(job, .finished)
                        case .failed(let why):
                            // The engine's comparison with the seed is an extra Greenroom does not read: when the walk
                            // fails with it (aglose/apksim#639), the same walk is made once more without it.
                            if settings.diffControls != nil, !job.plainSeed, !job.cancelled, let self {
                                NSLog("Greenroom: the walk of \(job.build.key) failed with --diff-seed (\(why.prefix(200))); walking it again without")
                                job.plainSeed = true
                                job.run = nil
                                self.begin(job)
                            } else { self?.finish(job, .failed(why)) }
                        case .cancelled: self?.finish(job, .cancelled)
                        }
                    }
                    run.start()
                }
            }
        }
    }

    private func event(_ e: CrawlRun.Event, _ job: Job) {
        progress(e, job)
        if job.forwardsProgress { job.waiters.forEach { $0.progress?(e) }; return }
        guard var entry = entries[job.owner], entry.key == job.build.key else { return }
        switch e {
        case .level(let depth, _, let known): entry.status = .walking(depth: depth, known: known)
        case .capturing(let screens, _): entry.status = .walking(depth: -1, known: screens)
        case .screen(_, _, _, let explored):
            guard explored else { return }
            entry.explored += 1
        case .line: return
        }
        entries[job.owner] = entry
        onChange?()
    }

    /// A walk's progress, for the job queue: screens found, and the share of them it has finished with.
    private func progress(_ e: CrawlRun.Event, _ job: Job) {
        guard let t = job.ticket else { return }
        switch e {
        case .level(_, _, let known): job.known = max(job.known, known)
        case .capturing(let screens, _):
            JobQueue.shared.update(t, detail: "capturing \(screens) screen\(screens == 1 ? "" : "s")")
            return
        case .screen(_, _, _, let explored):
            guard explored else { return }
            job.explored += 1
        case .line: return
        }
        guard job.known > 0 else { return }
        let left = job.explored > 0 && job.explored < job.known ? ", \(job.known - job.explored) to open" : ""
        JobQueue.shared.update(t, detail: "\(job.known) screen\(job.known == 1 ? "" : "s") found" + left,
                               fraction: .some(job.explored > 0 ? min(1, Double(job.explored) / Double(job.known)) : nil))
    }

    private func cancel(_ job: Job) {
        guard !job.cancelled else { return }
        job.cancelled = true
        cancelledRuns += 1
        job.run?.cancel()
    }

    private enum End { case finished, failed(String), cancelled }

    /// A run's end. Its data clone is removed first, off the main thread, and only then is the result published (the
    /// row says done, waiters hear, the next walk starts): a walk is not over while its copy of the data is still there.
    private func finish(_ job: Job, _ end: End) {
        guard current === job, !job.finishing else { return }
        if let name = job.clone {
            job.clone = nil
            job.finishing = true
            let root = dataRoot
            DispatchQueue.global(qos: .userInitiated).async {
                SlotClone.remove(name, in: root)
                DispatchQueue.main.async { [weak self] in
                    job.finishing = false
                    self?.finish(job, end)
                }
            }
            return
        }
        current = nil
        // The job queue hears last, once the map is in its place: the next walk may start in that same call.
        let release = {
            guard let t = job.ticket else { return }
            switch end {
            case .finished where job.forgotten || job.cancelled: JobQueue.shared.finish(t, .cancelled)
            case .finished: JobQueue.shared.finish(t, .done, detail: job.adopted ? "this commit's map was there already" : (job.known > 0 ? "\(job.known) screen\(job.known == 1 ? "" : "s")" : nil))
            case .failed(let why): JobQueue.shared.finish(t, .failed(why))
            case .cancelled: if job.forgotten { JobQueue.shared.forget(t) } else { JobQueue.shared.finish(t, .cancelled) }
            }
        }
        switch end {
        case .finished: break
        case .failed(let why): NSLog("Greenroom: a walk of \(job.build.key) failed: \(why)")
        case .cancelled: NSLog("Greenroom: the walk of \(job.build.key) was cancelled\(job.stopped ? " (stopped)" : "")")
        }
        if job.verifyOf != nil {
            finishVerify(job, end)
            onChange?()
            release()
            return
        }
        if let work = job.workDir { try? fm.removeItem(at: work) }
        let part = job.part, final = job.final
        var result: Result<ChangesResult, Failure> = .failure(Failure(message: "cancelled"))
        var status: Status?
        var wall = SignInWall.none
        switch end {
        case .finished where job.forgotten || job.cancelled:
            try? fm.removeItem(at: part)
        case .finished:
            try? fm.removeItem(at: final)
            if (try? fm.moveItem(at: part, to: final)) != nil, let data = ScreenMapData.read(final) {
                status = Self.done(data)
                if !job.isChanges, job.verifyOf == nil { wall = SignInWall.find(data) }
                if let plan = job.plan, !plan.isFull || plan.reason != nil { Self.writeImpactNote(Self.note(plan, walk: final), final) }
                result = .success(ChangesResult(folder: final, map: data, summary: Self.summary(of: final)))
                if !job.isChanges { file(job, folder: final) }
                // The map was kept across an engine update: once this walk is filed, the screens it carried are verified.
                if !job.isChanges, let was = job.plan?.engineChanged {
                    let build = job.build, owner = job.owner, withData = job.withData
                    Task { @MainActor [weak self] in
                        await self?.awaitFiling(build)
                        self?.verifyCarried(worktree: owner, withData: withData, afterEngine: was)
                    }
                }
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
            e.impact = Self.impactNote(final)
            e.wall = wall
            e.signedIn = job.kept
            entries[job.owner] = e
        }
        // The kept sign-in stopped working and there is a recorded script: sign in again with it, once for a build, and walk again.
        if !job.isChanges, wall == .atStart, job.kept, !job.cancelled { renewSignIn(worktree: job.owner, build: job.build) }
        let waiters = job.waiters
        job.waiters.removeAll()
        for w in waiters { w.completion(result) }
        onChange?()
        pruneToCap(force: true)
        release()
    }

    /// What a finished walk's plan came to: walked and carried screens are counted in its crawl.json.
    static func note(_ plan: History.WalkPlan, walk: URL) -> ImpactNote {
        let list = ((try? Data(contentsOf: walk.appendingPathComponent("crawl.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["screens"] as? [[String: Any]]) ?? []
        let carried = list.filter { ($0["origin"] as? String) == "carried" }.count
        return ImpactNote(full: plan.isFull, reason: plan.reason, walked: list.count - carried, total: list.count, files: plan.files,
                          base: plan.seedSnapshot.map { String($0.commit.prefix(7)) }, why: plan.reasons.isEmpty ? nil : plan.reasons, unplaced: plan.unplaced.isEmpty ? nil : plan.unplaced)
    }

    /// Kills the walk's processes and removes its clone (app quit).
    func shutdown() {
        unqueue { _ in true }
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
            case .changes:
                out.insert(job.final.path)
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
        case .walking(let depth, let known):
            if e.paused { return known > 0 ? "walk paused at \(known) screen\(known == 1 ? "" : "s")" : "walk paused" }
            // "mapping": the whole app, the first time or when asked; "walking": only what a change could touch.
            let verb = e.whole ? "mapping" : "walking"
            guard known > 0 else { return verb + "…" }
            if depth < 0 { return "capturing \(known) screen\(known == 1 ? "" : "s")…" }
            return "\(verb)… \(known) screen\(known == 1 ? "" : "s")" + (e.explored > 0 && e.explored < known ? ", \(known - e.explored) to open" : "")
        case .done(let n, let crashes, let unfinished):
            let screens = e.impact.map { !$0.full ? "walked \($0.walked) of \($0.total) screens" : nil } ?? nil
            let signIn = e.wall == .none ? "" : (e.wall == .atStart && e.signedIn ? ", sign-in expired" : ", needs sign-in")
            return (screens ?? "\(n) screen\(n == 1 ? "" : "s")") + (crashes > 0 ? ", \(crashes) crash\(crashes == 1 ? "" : "es")" : "") + (unfinished ? ", not finished" : "") + signIn
        case .failed: return "walk failed"
        case .stopped: return "walk stopped"
        case .needsSignIn: return "sign in to walk"
        }
    }

    func detail(_ e: Entry) -> String {
        var lines: [String] = []
        switch e.status {
        case .failed(let why): lines.append(why)
        case .stopped: lines.append("The walk was stopped. \"Walk again\" starts it.")
        case .needsSignIn: lines.append("A map is walked signed in, so it has every screen, and this app has no sign-in kept. Choose \"Sign In Once…\" in this row's menu (or the Screen Map's sign-in menu) and it is walked by itself. For an app with no sign-in, turn on \"Count Walks That Are Not Signed In\" in the repository's + menu.")
        case .done(_, _, true): lines.append("The walk ran out of time before it had tried everything. \"Walk again\" tries again.")
        case .queued, .walking:
            if e.whole { lines.append("Mapping the whole app, on up to \(budget.jobs) hidden devices at once. This is the long walk: once the app has a map, a new build only redoes the screens its changes could touch.") }
        default: break
        }
        if case .done = e.status, let w = e.wall.note(kept: e.signedIn) { lines.append(w) }
        if let n = e.note { lines.append(n.prefix(1).uppercased() + n.dropFirst() + ".") }
        if case .done = e.status, let build = lastBuildFor(e) {
            if let why = History.whyNotFiled(build) { lines.append("Not saved to the history: \(why)." + (build.dirty && build.sha != nil ? " \"Save Map to History Anyway\" keeps it, if the changes were to files the app is not built from." : "")) }
            else if e.saved, let sha = build.sha { lines.append("Saved to the history for commit \(sha.prefix(7)).") }
        }
        if case .done = e.status, let i = e.impact {
            for l in Self.impactLines(i) { lines.append(l) }
        }
        if let sh = e.share { lines.append(sh.hasSuffix(".") ? sh : sh + ".") }
        lines.append(Self.limits)
        return lines.joined(separator: "\n")
    }

    /// The impact note in words: "Walked 3 of 212 screens (12 files changed); the other 209 were carried from 1a2b3c4.",
    /// "Full walk: build files changed.", "1 screen changed that the last quick walk did not redo."
    static func impactLines(_ i: ImpactNote) -> [String] {
        var lines: [String] = []
        let files = "\(i.files) file\(i.files == 1 ? "" : "s") changed"
        if !i.full {
            let carried = i.total - i.walked
            lines.append("Walked \(i.walked) of \(i.total) screens (\(files)); the other \(carried) \(carried == 1 ? "was" : "were") carried from \(i.base.map { "the walk of " + $0 } ?? "the last walk").")
        } else if let r = i.reason {
            lines.append(r.hasPrefix("this commit's map was already there") ? "Not walked: \(r)." : "Full walk: \(r).")
        }
        if let m = i.misses, m > 0 { lines.append(MapImpact.missWords(m).prefix(1).uppercased() + MapImpact.missWords(m).dropFirst() + "; its folder now always gets a full walk.") }
        else if i.misses == 0 { lines.append("Compared with the last quick walk: every screen it carried was as carried.") }
        if let v = i.verify { lines.append(v.prefix(1).uppercased() + v.dropFirst() + ".") }
        return lines
    }

    /// The row's evidence button: its label is the status, a click opens the Screen Map on that build's run.
    /// What `badge(for:)` shows, for the sidebar to tell whether the row changed.
    func badgeKey(for session: Session) -> String {
        guard let e = entries[session.worktree.path] else { return "" }
        return label(e) + "|" + detail(e) + "|" + (e.changedWords ?? "")
    }

    func badge(for session: Session) -> NSView? {
        guard let e = entries[session.worktree.path] else { return nil }
        // When a diff count against main is known, show a single compact pill so the session's PR/branch title never
        // gets squeezed out of the narrow sidebar (the walk detail stays in the tooltip).
        if case .done = e.status, let n = e.changed {
            let c = NSButton(title: n == 0 ? "no changes" : "\(n) changed", target: self, action: #selector(openChangesClicked(_:)))
            c.isBordered = false
            c.font = .systemFont(ofSize: 10, weight: .semibold)
            c.contentTintColor = n == 0 ? .tertiaryLabelColor : Design.warning
            c.identifier = NSUserInterfaceItemIdentifier(session.worktree.path)
            c.toolTip = [e.changedWords, label(e), detail(e)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n") + "\nClick to see the changes."
            c.setContentHuggingPriority(.required, for: .horizontal)
            c.setContentCompressionResistancePriority(.init(600), for: .horizontal)
            return c
        }
        let shortLabel: String = {
            if case .done(_, let crashes, let unfinished) = e.status, let i = e.impact, !i.full, crashes == 0, !unfinished, e.wall == .none {
                return "\(i.walked)/\(i.total)"
            }
            return label(e)
        }()
        let b = NSButton(title: shortLabel, target: self, action: #selector(openMapClicked(_:)))
        b.isBordered = false
        b.font = .systemFont(ofSize: 10, weight: .medium)
        b.contentTintColor = { if case .failed = e.status { return .systemOrange } else { return .secondaryLabelColor } }()
        b.identifier = NSUserInterfaceItemIdentifier(session.worktree.path)
        b.toolTip = [label(e), detail(e)].filter { !$0.isEmpty }.joined(separator: "\n")
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.init(600), for: .horizontal)
        b.isEnabled = { if case .done = e.status { return true } else { return false } }()
        return b
    }

    @objc private func openChangesClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, let s = controller?.sessions.first(where: { $0.worktree.path == path }) else { return }
        guard let wb = controller?.workbench else { return }
        if wb.changesSheet.isOpen, wb.changesSheet.session?.worktree.path == path { return }
        wb.showChanges(of: s)
    }

    @objc private func openMapClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, let e = entries[path], case .done = e.status else { return }
        controller?.openMap(folder: mapFolder(for: e.key))
    }

    // MARK: Context menu

    /// Items for the sidebar's session-row menu; they act on `clickedSession`.
    func menuItems() -> [NSMenuItem] {
        let again = NSMenuItem(title: "Walk Again", action: #selector(walkAgainMenu(_:)), keyEquivalent: "")
        let everything = NSMenuItem(title: "Walk Everything Again", action: #selector(walkEverythingMenu(_:)), keyEquivalent: "")
        let verify = NSMenuItem(title: "Verify Carried Screens", action: #selector(verifyMenu(_:)), keyEquivalent: "")
        let share = NSMenuItem(title: "Share Screen Maps Through Git", action: #selector(shareMenu(_:)), keyEquivalent: "")
        share.toolTip = Workspace.shareExplanation
        let shareSignedIn = NSMenuItem(title: "Also Share Maps Walked on Signed-In Data", action: #selector(shareSignedInMenu(_:)), keyEquivalent: "")
        shareSignedIn.toolTip = Workspace.shareSignedInExplanation
        shareSignedIn.indentationLevel = 1
        let stop = NSMenuItem(title: "Stop Walking", action: #selector(stopMenu(_:)), keyEquivalent: "")
        let auto = NSMenuItem(title: "Walk New Builds Automatically", action: #selector(autoMenu(_:)), keyEquivalent: "")
        let turnEnd = NSMenuItem(title: "Wait for the Agent's Turn to End", action: #selector(turnEndMenu(_:)), keyEquivalent: "")
        turnEnd.toolTip = "Off: every new build is walked as it lands. On: a build that lands while an agent is still working in that worktree is walked when its turn ends, so the builds it makes along the way are not. Needs the agent's hooks (File > Connect Agents…)."
        turnEnd.indentationLevel = 1
        let data = NSMenuItem(title: "Walk with My Signed-In Data", action: #selector(dataMenu(_:)), keyEquivalent: "")
        let quick = NSMenuItem(title: "Quick Walks Only", action: #selector(quickMenu(_:)), keyEquivalent: "")
        quick.toolTip = "Off: a walk covers the whole app, which is what its history needs; the first one is long, later ones redo only what changed. On: every walk stops two taps deep after two minutes."
        let save = NSMenuItem(title: "Save Map to History Anyway", action: #selector(saveAnywayMenu(_:)), keyEquivalent: "")
        save.toolTip = "This build was made with uncommitted changes, so its map is not kept as its commit's. Choose this when the changes were to files the app is not built from."
        let signIn = NSMenuItem(title: "Sign In Once…", action: #selector(signInMenu(_:)), keyEquivalent: "")
        signIn.toolTip = "Opens the app on a device you can see. Sign in as you would on a phone and press Use This Sign-In: every walk of this repository then starts signed in, on a copy of that device's data. What you do is recorded as a script, with what you type kept in your Keychain."
        let forget = NSMenuItem(title: "Forget Sign-In", action: #selector(forgetSignInMenu(_:)), keyEquivalent: "")
        for i in [again, everything, verify, stop, save, signIn, forget, auto, turnEnd, data, quick, share, shareSignedIn] { i.target = self }
        return [.separator(), again, everything, verify, stop, save, .separator(), signIn, forget, data, .separator(), auto, turnEnd, quick, share, shareSignedIn]
    }

    @objc private func shareMenu(_ sender: Any?) {
        guard let s = clickedSession(), let c = controller else { return }
        c.setShareMaps(!c.sharesMaps(s), for: s)
    }
    @objc private func shareSignedInMenu(_ sender: Any?) {
        guard let s = clickedSession(), let c = controller else { return }
        c.setShareMaps(c.sharesMaps(s), signedIn: !c.sharesSignedInMaps(s), for: s)
    }

    // MARK: Sign-in

    /// The key of the app's kept sign-in: one for a repository, whatever the worktree.
    func signInKey(_ worktree: String) -> String? {
        guard let c = controller else { return nil }
        if let s = c.sessions.first(where: { $0.worktree.path == worktree }) { return SignIns.key(workspace: s.workspace) }
        // Main's walks (owned by the trunk's path) and a pull request row's ("pr:ID") are of the same app as the
        // repository's sessions, and must be walked the same way to be compared with them.
        if let ws = c.workspaces.first(where: { c.mainBuilds.trunk(of: $0.root).path == worktree }) { return SignIns.key(workspace: ws.root) }
        if worktree.hasPrefix("pr:"), let p = c.pulls.all.first(where: { "pr:" + $0.id == worktree }) { return SignIns.key(workspace: URL(fileURLWithPath: p.workspace)) }
        return nil
    }
    func keptSignIn(_ worktree: String) -> SignIns.Record? { SignIns.shared.record(signInKey(worktree)) }

    /// Builds a kept sign-in was already renewed for: once each, so a script that no longer signs in is not run in a loop.
    private var renewed: Set<String> = []
    private var renewing: MapSignIn?

    /// The kept sign-in no longer works (a walk from it opened on the sign-in screen): the recorded script signs in
    /// again on a hidden device, its data becomes the kept sign-in, and the build is walked again. Without a script,
    /// the row says so and "Sign In Again…" is the way.
    private func renewSignIn(worktree: String, build: Build) {
        guard let key = signInKey(worktree), let r = SignIns.shared.record(key), let name = r.script, !renewed.contains(build.key), renewing == nil else { return }
        let url = Scripts.folder.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return }
        renewed.insert(build.key)
        let s = MapSignIn(apk: build.apk, script: Scripts.Script(url: url, fromWorktree: false), worktree: URL(fileURLWithPath: worktree))
        renewing = s
        if var e = entries[worktree], e.key == build.key { e.note = "the kept sign-in stopped working: signing in again with \(name)"; entries[worktree] = e; onChange?() }
        s.start { [weak self] outcome in
            guard let self else { return }
            self.renewing = nil
            switch outcome {
            case .ready(let slot):
                SlotClone.remove(r.slot, in: SignIns.dataRoot)
                if SignIns.adopt(slot, as: r.slot) {
                    SignIns.shared.set(SignIns.Record(slot: r.slot, date: Date(), script: name), key: key)
                    self.request(worktree: worktree, build: build, force: true, walk: true, withData: false)
                } else { MapSignIn.discard(slot) }
            case .failed(let why):
                if var e = self.entries[worktree], e.key == build.key { e.note = "signing in again with \(name) did not work (\(why))"; self.entries[worktree] = e; self.onChange?() }
            case .cancelled: break
            }
        }
    }

    @objc private func signInMenu(_ sender: Any?) {
        guard let s = clickedSession(), let c = controller, let wb = c.workbench, let build = lastBuild[s.worktree.path] ?? s.build else { return }
        let key = SignIns.key(workspace: s.workspace), app = s.workspace.lastPathComponent
        SignInOnce.begin(workbench: wb, apk: build.apk, key: key, app: app) { [weak self] kept in
            guard kept, let self else { return }
            // Every session of the repository that has a build is walked again, signed in.
            for other in c.sessions where other.workspace == s.workspace { self.renewed = []; c.walkAgain(other) }
        }
    }
    @objc private func forgetSignInMenu(_ sender: Any?) {
        guard let s = clickedSession() else { return }
        SignIns.shared.forget(SignIns.key(workspace: s.workspace))
        onChange?()
    }

    @objc private func quickMenu(_ sender: Any?) {
        guard let s = clickedSession(), let c = controller else { return }
        c.setQuickWalk(!c.walksQuick(s), for: s)
    }
    @objc private func saveAnywayMenu(_ sender: Any?) { clickedSession().map { _ = saveToHistoryAnyway(worktree: $0.worktree.path) } }

    /// The build an entry's walk was of, when it is still the row's newest.
    private func lastBuildFor(_ e: Entry) -> Build? { lastBuild.values.first { $0.key == e.key } }

    @objc private func walkEverythingMenu(_ sender: Any?) {
        guard let s = clickedSession() else { return }
        fullNext.insert(s.worktree.path)
        controller?.walkAgain(s)
    }
    @objc private func verifyMenu(_ sender: Any?) {
        guard let s = clickedSession() else { return }
        verifyCarried(worktree: s.worktree.path, withData: controller?.walksWithData(s) == true)
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
    @objc private func turnEndMenu(_ sender: Any?) {
        guard let s = clickedSession(), let c = controller else { return }
        c.setAuto(c.auto(of: s) == .onTurnEnd ? .onBuild : .onTurnEnd, for: s)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let s = clickedSession() else { return false }
        switch item.action {
        case #selector(walkAgainMenu(_:))?, #selector(walkEverythingMenu(_:))?: return controller?.hasBuild(s) == true
        case #selector(verifyMenu(_:))?: return entries[s.worktree.path]?.impact?.full == false && !isWalking(s.worktree.path)
        case #selector(stopMenu(_:))?: return isWalking(s.worktree.path)
        case #selector(autoMenu(_:))?: item.state = controller?.auto(of: s) == .off ? .off : .on; return true
        case #selector(turnEndMenu(_:))?: item.state = controller?.auto(of: s) == .onTurnEnd ? .on : .off; return controller?.auto(of: s) != .off
        case #selector(dataMenu(_:))?: item.state = controller?.walksWithData(s) == true ? .on : .off; return true
        case #selector(signInMenu(_:))?:
            item.title = keptSignIn(s.worktree.path) != nil ? "Sign In Again…" : "Sign In Once…"
            return controller?.hasBuild(s) == true && !SignInOnce.isRunning
        case #selector(forgetSignInMenu(_:))?: return keptSignIn(s.worktree.path) != nil
        case #selector(quickMenu(_:))?: item.state = controller?.walksQuick(s) == true ? .on : .off; return true
        case #selector(saveAnywayMenu(_:))?:
            guard let b = lastBuild[s.worktree.path], let e = entries[s.worktree.path], e.key == b.key, case .done = e.status else { return false }
            return b.dirty && b.sha != nil && !History.isAccepted(b.key)
        case #selector(shareMenu(_:))?: item.state = controller?.sharesMaps(s) == true ? .on : .off; return true
        case #selector(shareSignedInMenu(_:))?:
            item.state = controller?.sharesSignedInMaps(s) == true ? .on : .off
            return controller?.sharesMaps(s) == true
        default: return true
        }
    }
}

/// A clone of a session's data slot for a walk to use and lose: the engine keeps a slot as
/// `cache/data/<package>/<slot>-N` with a `<slot>-N.device` beside it (its /sdcard and Settings values); instance 0
/// is the session's simulator. Verified by running `crawl.py --keep-data -- --data-slots NAME`: it uses exactly that
/// slot (each simulator of the walk on its own clone of it, since apksim 0.60), and the original's files are byte for byte what they were.
enum SlotClone {
    enum Outcome { case cloned(String), none, failed(String) }

    static func freshName(prefix: String = "evg") -> String { prefix + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)) }

    /// Seeds `<target>-0` (and `.device`) from `<source>-0` for each package where the source exists. When `overwrite`
    /// is false, an existing target slot is left untouched so a session's own app data is never clobbered.
    @discardableResult
    static func seed(from source: String, to target: String, in root: URL, overwrite: Bool = false) -> Bool {
        guard source != target else { return false }
        let fm = FileManager.default
        var seeded = false
        for pkg in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let from = pkg.appendingPathComponent(source + "-0", isDirectory: true)
            let to = pkg.appendingPathComponent(target + "-0", isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: from.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if !overwrite, fm.fileExists(atPath: to.path) {
                let fromKey = from.appendingPathComponent("apksim-keystore.properties").path
                let toKey = to.appendingPathComponent("apksim-keystore.properties").path
                let missingSignIn = fm.fileExists(atPath: fromKey) && !fm.fileExists(atPath: toKey)
                if !missingSignIn { continue }
            }
            if DeviceData.inUse(to) { continue }
            for suffix in ["", ".device"] {
                let a = pkg.appendingPathComponent(source + "-0" + suffix)
                let b = pkg.appendingPathComponent(target + "-0" + suffix)
                try? fm.removeItem(at: b)
                guard fm.fileExists(atPath: a.path) else { continue }
                if clonefile(a.path, b.path, 0) != 0 { try? fm.copyItem(at: a, to: b) }
            }
            seeded = true
        }
        return seeded
    }

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

    /// Waits (blocking) until no engine holds instance 0 of `slot` in any package, or `timeout` has passed; true when
    /// it is free. A simulator's process is the engine's launcher client: the JVM that ran the app (a standby that took
    /// the launch) is another process, which can hold the slot's lock for a moment after the client has exited. A walk
    /// with `--keep-data` refuses a slot that is held ("in use by a running apksim"), and a copy taken while the JVM
    /// still writes could miss what it wrote.
    @discardableResult
    static func waitUntilFree(_ slot: String, in root: URL, timeout: TimeInterval = 20) -> Bool {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent(slot + "-0", isDirectory: true) }.filter { fm.fileExists(atPath: $0.path) }
        let deadline = Date().addingTimeInterval(timeout)
        while folders.contains(where: DeviceData.inUse) {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
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
