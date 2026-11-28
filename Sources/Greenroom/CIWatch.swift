import Foundation

/// CI watched for sessions whose commit is pushed (docs/AGENT-FIRST-SPEC.md, A8): nobody has to press Build for a
/// repository whose APKs come from CI. For each shown session on a branch whose head is what its upstream has,
/// GitHub is asked for that commit's runs (`gh run list --commit`, as the person's own sign-in). While a run goes
/// the session is Working and its loop strip says so; when the runs succeed the `ci` recipe fetches the APK through
/// the ordinary build queue, with `GREENROOM_CI_DISPATCH=0`, so the session's simulator reloads on it; when one
/// fails the strip says that. Either way the session's agent is told with its next call's answer or its turn's end.
///
/// It only reads GitHub. It never starts a workflow: listing runs starts none, and the recipe is told not to.
/// A fetch is started only for a repository that is known to get APKs from CI (its default recipe is `ci`, an
/// artifact or workflow is set for it, or a CI build of it was fetched before), for a clean worktree that has no
/// build of that commit yet. Main thread only.
final class CIWatch {
    struct Run: Equatable {
        var id: Int
        /// queued, in_progress, completed (and GitHub's other waiting states).
        var status: String
        var conclusion: String
        var workflow: String
        var url: String?
        var created: Date?

        var active: Bool { status != "completed" }
        var failed: Bool { !active && !["success", "neutral", "skipped"].contains(conclusion) }
    }

    /// What is known about one session's commit.
    struct Entry: Equatable {
        var sha: String
        var runs: [Run] = []
        /// When the commit was first seen pushed, and when GitHub was last asked.
        var first: Date
        var asked: Date?
        /// A fetch of its APK was started by the watch.
        var fetching = false
        /// The agent was told how it ended.
        var told = false

        var active: Bool { runs.contains(where: \.active) }
        var failed: Run? { active ? nil : runs.first(where: \.failed) }
        var passed: Bool { !runs.isEmpty && !active && failed == nil }
        /// Nothing more will be learned by asking.
        var over: Bool { !runs.isEmpty && !active }
    }

    static let enabledKey = "watchCI"
    /// The person's switch (Settings > Agents): on unless turned off.
    static var enabled: Bool {
        get { CheckedDefault.has(enabledKey) ? CheckedDefault.bool(enabledKey) : true }
        set { CheckedDefault.set(newValue, enabledKey) }
    }

    /// The time, for a check to move.
    static var now: () -> Date = { Date() }
    /// How often GitHub is asked: while a run goes; while none has shown yet; and for how long none is waited for.
    static let whileActive: TimeInterval = 30
    static let whileNone: TimeInterval = 60
    static let giveUp: TimeInterval = 30 * 60

    private unowned let sessions: SessionsController
    private(set) var entries: [String: Entry] = [:]
    private var asking = Set<String>()
    private var timer: Timer?
    var onChange: (() -> Void)?
    /// Tells a session's agent something, with its next call's answer or its turn's end.
    var tell: ((_ worktree: String, _ text: String) -> Void)?

    init(sessions: SessionsController) { self.sessions = sessions }

    /// Starts the clock. Not under a check: a check moves it by hand (`tick`).
    func start() {
        guard timer == nil, !CheckedDefault.inCheck else { return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func entry(for worktree: String) -> Entry? { entries[worktree] }

    // MARK: Words

    /// "CI run 4812 · 3 min", "CI · 1 of 3 runs done · 3 min", "CI run 4812 failed".
    static func line(_ e: Entry, now: Date) -> String? {
        if e.active {
            let since = e.runs.compactMap(\.created).min() ?? e.first
            let min = max(0, Int(now.timeIntervalSince(since) / 60))
            let time = min == 0 ? "just started" : (min < 120 ? "\(min) min" : "\(min / 60) h")
            if e.runs.count == 1 { return "CI run \(e.runs[0].id) · \(time)" }
            return "CI · \(e.runs.filter { !$0.active }.count) of \(e.runs.count) runs done · \(time)"
        }
        if let f = e.failed { return "CI run \(f.id) failed" }
        return nil
    }

    func line(for worktree: String) -> String? { entries[worktree].flatMap { Self.line($0, now: Self.now()) } }

    /// What `session` says of it.
    func said(for worktree: String) -> String? {
        guard let e = entries[worktree], !e.runs.isEmpty else { return nil }
        let short = e.sha.prefix(7)
        if e.active { return "ci: \(Self.line(e, now: Self.now()) ?? "running") for \(short) (Greenroom watches it; build with the ci recipe waits for it)" }
        if let f = e.failed { return "ci: run \(f.id) (\(f.workflow)) failed for \(short)" + (f.url.map { ": \($0)" } ?? "") }
        return "ci: passed for \(short)"
    }

    // MARK: Asking

    /// The runs of a commit, from `gh run list --json databaseId,status,conclusion,workflowName,headSha,url,createdAt`.
    static func parse(_ json: String, sha: String) -> [Run] {
        guard let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return list.compactMap { o in
            guard let id = o["databaseId"] as? Int, (o["headSha"] as? String) == sha else { return nil }
            return Run(id: id, status: (o["status"] as? String ?? "").lowercased(), conclusion: (o["conclusion"] as? String ?? "").lowercased(),
                       workflow: o["workflowName"] as? String ?? "", url: o["url"] as? String, created: (o["createdAt"] as? String).flatMap { iso.date(from: $0) })
        }
    }

    /// With a workflow set for the repository, its runs count when the commit has some; else every run does.
    static func counted(_ runs: [Run], workflow: String) -> [Run] {
        guard !workflow.isEmpty else { return runs }
        var stem = (workflow as NSString).lastPathComponent
        for ext in [".yml", ".yaml"] where stem.hasSuffix(ext) { stem = String(stem.dropLast(ext.count)) }
        let mine = runs.filter { $0.workflow.caseInsensitiveCompare(workflow) == .orderedSame || $0.workflow.caseInsensitiveCompare(stem) == .orderedSame }
        return mine.isEmpty ? runs : mine
    }

    /// Whether a session is one to ask GitHub about now.
    private func due(_ s: Session, now: Date) -> Bool {
        let path = s.worktree.path
        guard s.branch != nil, !s.head.isEmpty, s.ahead == 0, !asking.contains(path), GitHubRemote.has(s.workspace) else { return false }
        guard let e = entries[path], e.sha == s.head else { return true }
        if e.over { return false }
        guard let asked = e.asked else { return true }
        if e.active { return now.timeIntervalSince(asked) >= Self.whileActive }
        if now.timeIntervalSince(e.first) > Self.giveUp { return false }
        return now.timeIntervalSince(asked) >= Self.whileNone
    }

    /// Looks at every shown session: asks GitHub about those that are due, and forgets those that are gone.
    func tick() {
        guard Self.enabled else {
            if !entries.isEmpty { entries = [:]; onChange?() }
            return
        }
        let now = Self.now()
        let shown = sessions.groups().flatMap(\.sessions)
        let paths = Set(shown.map(\.worktree.path))
        for gone in entries.keys where !paths.contains(gone) { entries[gone] = nil }
        for s in shown {
            settle(s)
            guard due(s, now: now) else { continue }
            let path = s.worktree.path
            asking.insert(path)
            let workflow = sessions.workspace(of: s)?.ci.workflow ?? ""
            Task { @MainActor [weak self] in
                let found = await Self.look(s, workflow: workflow)
                guard let self else { return }
                self.asking.remove(path)
                self.apply(s, found)
            }
        }
    }

    /// For a check: whether an answer from GitHub is still awaited.
    var busy: Bool { !asking.isEmpty }

    /// Asks git whether the head is what the upstream has, then GitHub for that commit's runs. Nil: not pushed, or
    /// GitHub could not be asked (it is asked again later).
    private static func look(_ s: Session, workflow: String) async -> [Run]? {
        let upstream = (await Git.run(["rev-parse", "--verify", "--quiet", "@{upstream}"], in: s.worktree))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard upstream == s.head else { return nil }
        var args = ["run", "list", "--commit", s.head, "--limit", "30", "--json", "databaseId,status,conclusion,workflowName,headSha,url,createdAt"]
        if let slug = await GitHubRemote.repoSlug(for: s.worktree) { args += ["-R", slug] }
        let r = await GH.run(args, in: s.worktree, timeout: 30)
        guard r.status == 0 else { return nil }
        return counted(parse(r.out, sha: s.head), workflow: workflow)
    }

    /// What GitHub said about a session's commit.
    func apply(_ s: Session, _ found: [Run]?) {
        let path = s.worktree.path
        let now = Self.now()
        guard let found else {
            // Not pushed (any more), or no answer: what was known of another commit is dropped.
            if let e = entries[path], e.sha != s.head { entries[path] = nil; onChange?() }
            return
        }
        var e = entries[path].flatMap { $0.sha == s.head ? $0 : nil } ?? Entry(sha: s.head, first: now)
        let before = entries[path]
        e.asked = now
        e.runs = found
        entries[path] = e
        settle(s)
        if entries[path] != before { onChange?() }
    }

    /// Acts on what is known of a session's commit: fetches the APK of runs that passed, and tells the agent how it
    /// ended (a failure once it failed; a build once it is the session's).
    private func settle(_ s: Session) {
        let path = s.worktree.path
        guard var e = entries[path], e.sha == s.head, e.over else { return }
        let short = String(e.sha.prefix(7))
        defer { if entries[path] != e { entries[path] = e; onChange?() } }
        if let f = e.failed {
            if !e.told {
                e.told = true
                tell?(path, "CI failed for \(short): run \(f.id) (\(f.workflow)) ended in \(f.conclusion.isEmpty ? "failure" : f.conclusion)." + (f.url.map { " \($0)" } ?? ""))
            }
            return
        }
        let have = sessions.currentBuild(of: s)
        if e.fetching {
            guard !e.told else { return }
            if have?.sha == e.sha, have?.source == .ci {
                e.told = true
                tell?(path, "CI built \(short): Greenroom fetched its APK (build \(have!.key)), and the session's simulator runs it.")
            } else if let job = sessions.buildQueue.job(for: s), let why = job.failure {
                e.told = true
                tell?(path, "CI passed for \(short), but its APK could not be fetched: \(why)")
            }
            return
        }
        guard !e.told else { return }
        if have?.sha != e.sha, !s.dirty, let ws = sessions.workspace(of: s), fetches(ws) {
            guard !sessions.buildQueue.isBuilding(path) else { return }   // after the build that is going
            var refused = false
            _ = sessions.buildQueue.start(s, workspace: ws, recipeName: "ci", store: sessions.store, environment: ["GREENROOM_CI_DISPATCH": "0"], error: { _ in refused = true })
            if !refused { e.fetching = true; return }
        }
        e.told = true
        tell?(path, "CI passed for \(short).")
    }

    /// Whether a repository is known to get its APKs from CI: nothing is fetched by itself for one that is not
    /// (most repositories' runs are tests and linters, with no APK in them).
    func fetches(_ ws: Workspace) -> Bool {
        if ws.recipe(named: "ci") == nil { return false }
        if ws.defaultRecipeName == "ci" || !ws.ci.artifact.isEmpty || !ws.ci.workflow.isEmpty { return true }
        let store = sessions.store
        return sessions.sessions.contains { s in
            s.workspace.path == ws.root.path && store.history(of: s.worktree.path).contains { store.build($0)?.source == .ci }
        }
    }

    /// For a check: as if nothing was ever asked.
    func reset() { entries = [:]; asking = [] }
}
