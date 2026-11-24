import AppKit
import ImageIO

// Map history wired into walks and comparisons (docs/MAP-HISTORY-PLAN.md, package H3): every walk of a clean commit is
// filed as a snapshot (`file`), the baseline of a commit is found by one rule (`baseline`), and a comparison whose two
// builds have a snapshot is a `MapDiff` made into a `ChangeSet` (`changeSet`), with no walk.
//
//     <state>/history/<repo>/...        MapStore, one `repo` per workspace (`store`)
//     <changes folder>/diff/<k>.png     the difference image of a modified screen's capture, k = the two blobs' hashes
//     <changes folder>/history-pixels.json   what those images say (pixels that differ, of how many, or a size change)
enum History {
    private static let lock = NSLock()
    private static var stores: [String: MapStore] = [:]

    /// The folder name of a workspace's history: its folder's name and eight digits of its path's hash.
    static func repoID(_ root: URL) -> String {
        let name = root.resolvingSymlinksInPath().lastPathComponent.unicodeScalars.map { c in
            (c.value < 128 && (CharacterSet.alphanumerics.contains(c) || c == "-" || c == "_")) ? String(c) : "-"
        }.joined()
        return String(name.prefix(40)) + "-" + String(MapJSON.sha256(root.resolvingSymlinksInPath().path).prefix(8))
    }

    /// The workspace's store. One object per folder, so its lock serializes every queue that writes to it.
    static func store(stateRoot: URL, workspace: URL) -> MapStore {
        let key = stateRoot.path + "\u{0}" + repoID(workspace)
        lock.lock(); defer { lock.unlock() }
        if let s = stores[key] { return s }
        let s = MapStore(root: stateRoot, repo: repoID(workspace))
        stores[key] = s
        return s
    }

    /// A build with a commit and no uncommitted changes: the only kind a snapshot can stand for.
    static func fileable(_ b: Build) -> Bool {
        guard !b.dirty || isAccepted(b.key), let sha = b.sha, !sha.isEmpty, !sha.hasPrefix("-") else { return false }
        return true
    }

    /// Builds made with uncommitted changes that the person said stand for their commit all the same ("Save Map to
    /// History Anyway": the changes were to files the app is not built from). Kept by build key in the defaults.
    private static let acceptedLock = NSLock()
    private static var accepted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "historyAcceptedBuilds") ?? [])
    static func isAccepted(_ key: String) -> Bool { acceptedLock.lock(); defer { acceptedLock.unlock() }; return accepted.contains(key) }
    static func accept(_ key: String) {
        acceptedLock.lock()
        accepted.insert(key)
        let all = Array(accepted).sorted()
        acceptedLock.unlock()
        UserDefaults.standard.set(Array(all.suffix(500)), forKey: "historyAcceptedBuilds")
    }
    /// Why a build's walk is not kept in the history, in words; nil when it is.
    static func whyNotFiled(_ b: Build) -> String? {
        guard let sha = b.sha, !sha.isEmpty, !sha.hasPrefix("-") else { return "this build has no commit (an APK from outside a repository)" }
        if b.dirty, !isAccepted(b.key) { return "this build was made with uncommitted changes, so it does not stand for commit \(sha.prefix(7))" }
        return nil
    }

    // MARK: Git

    private static func line(_ args: [String], in dir: URL) async -> String? {
        guard let out = await Git.run(args, in: dir) else { return nil }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// A commit's full name and its tree, or nil when the repository does not have it.
    static func resolve(_ sha: String, in dir: URL) async -> (commit: String, tree: String)? {
        guard !sha.hasPrefix("-"), let commit = await line(["rev-parse", "--verify", "--quiet", sha + "^{commit}"], in: dir),
              let tree = await line(["rev-parse", sha + "^{tree}"], in: dir) else { return nil }
        return (commit, tree)
    }

    /// The baseline of a commit: the snapshot of its merge base with `mainRef`; if that commit has none (by commit, then
    /// by tree), the nearest ancestor of it that has one, and how many commits behind the merge base that is. Nil when
    /// there is none.
    static func baseline(commit: String, mainRef: String, in dir: URL, store: MapStore, profile: String) async -> (snapshot: MapSnapshot, behind: Int)? {
        var base: String?
        for ref in [mainRef, mainRef.hasPrefix("origin/") ? String(mainRef.dropFirst(7)) : nil].compactMap({ $0 }) {
            if let mb = await Git.mergeBase(commit, ref, in: dir) { base = mb; break }
        }
        guard let mb = base else { return nil }
        if let s = store.snapshot(profile: profile, commit: mb) { return (s, 0) }
        if let tree = await line(["rev-parse", mb + "^{tree}"], in: dir), let s = store.snapshot(profile: profile, tree: tree) { return (s, 0) }
        let have = Set(store.commits(profile: profile))
        guard !have.isEmpty, let list = await Git.run(["rev-list", "-n", "2000", mb], in: dir) else { return nil }
        for (i, c) in list.split(whereSeparator: \.isNewline).enumerated() where i > 0 && have.contains(String(c)) {
            if let s = store.snapshot(profile: profile, commit: String(c)) { return (s, i) }
        }
        return nil
    }

    // MARK: Filing

    private struct Place {
        let workspace: Workspace
        let commit: String
        let tree: String
        let store: MapStore
    }

    /// The workspace (of `candidates`) whose repository has the build's commit.
    private static func place(_ build: Build, candidates: [Workspace], stateRoot: URL) async -> Place? {
        guard fileable(build), let sha = build.sha else { return nil }
        for w in candidates {
            if let (commit, tree) = await resolve(sha, in: w.root) { return Place(workspace: w, commit: commit, tree: tree, store: store(stateRoot: stateRoot, workspace: w.root)) }
        }
        return nil
    }

    /// Imports a walk's folder as the snapshot of `build`'s commit, pairs it against the baseline and keeps it. A dirty build
    /// or one with no commit files nothing, nor does a commit that has a snapshot of this profile. Off the main thread.
    @discardableResult
    static func file(walk: URL, build: Build, profile: MapProfile, candidates: [Workspace], stateRoot: URL, engine: String, seed: MapSnapshot? = nil) async -> Bool {
        await filed(walk: walk, build: build, profile: profile, candidates: candidates, stateRoot: stateRoot, engine: engine, seed: seed) != nil
    }

    /// What filing a walk did (package I2): the snapshot kept, and when it was a full walk compared with a quick one,
    /// that quick walk's commit and the screens it carried that turned out to differ.
    struct Filed {
        var snapshot: MapSnapshot
        var audit: (quick: String, misses: [MapImpact.Miss])?
        /// Sharing through git went wrong (writing, pushing or fetching), in words; nil when it worked or is off.
        var shareProblem: String?
        /// What sharing did: "written", "pushed", "written, not pushed (signed-in data)"; nil when off.
        var shared: String?
    }

    /// `file`, saying what it did. Nil when nothing could be filed. `seed`: the snapshot a seeded walk started from.
    static func filed(walk: URL, build: Build, profile: MapProfile, candidates: [Workspace], stateRoot: URL, engine: String, seed: MapSnapshot? = nil) async -> Filed? {
        guard let p = await place(build, candidates: candidates, stateRoot: stateRoot) else { return nil }
        return await fileWalk(walk, place: p, profile: profile, engine: engine, seed: seed)
    }

    /// A commit's snapshot is kept once, except that a full walk replaces a quick one of the same commit (it is the more
    /// truthful of the two), after being compared with it. A full walk with no quick one of its commit is compared with
    /// the nearest earlier snapshot when that one was quick.
    private static func fileWalk(_ walk: URL, place p: Place, profile: MapProfile, engine: String, seed: MapSnapshot? = nil) async -> Filed? {
        let existing = p.store.snapshot(profile: profile.id, commit: p.commit)
        if let existing, !existing.screens.contains(where: { $0.carriedFrom != nil }) { return Filed(snapshot: existing) }
        guard let imported = p.store.importWalk(walk, commit: p.commit, tree: p.tree, profile: profile, engine: engine, walked: Date(), seed: seed) else {
            return existing.map { Filed(snapshot: $0) }
        }
        let isFull = !imported.screens.contains { $0.carriedFrom != nil }
        if let existing, !(isFull && existing.screens.contains { $0.carriedFrom != nil }) { return Filed(snapshot: existing) }
        let base = await sharedBaseline(place: p, profile: profile)
        let (paired, _) = MapPairing.pair(head: imported, base: base.found?.snapshot)
        guard p.store.save(paired) else { return nil }
        var filed = Filed(snapshot: paired)
        if isFull { filed.audit = await audit(full: paired, quick: existing, place: p) }
        if p.workspace.shareMaps {
            let s = share(paired, workspace: p.workspace, store: p.store)
            filed.shared = s.done
            filed.shareProblem = s.problem ?? base.problem
        }
        return filed
    }

    // MARK: Sharing through git (the workspace's "Share screen maps through git")

    /// The remote maps are pushed to and fetched from.
    static let shareRemote = "origin"
    private static let fetchLock = NSLock()
    private static var lastFetch: [String: Date] = [:]

    /// Writes the snapshot's refs (`MapGit.write`, captures from the store's blobs) in the workspace's repository and,
    /// unless it was walked on signed-in data and the workspace does not share those, pushes them to origin (never
    /// forced). Only called when the workspace shares maps. Never throws: a failure comes back in words.
    static func share(_ snapshot: MapSnapshot, workspace ws: Workspace, store: MapStore) -> (done: String?, problem: String?) {
        let git = MapGit(repo: ws.root)
        let written: MapGit.Written
        do { written = try git.write(snapshot, blob: { store.blobURL($0) }) } catch { return (nil, "writing the map's refs failed: \(error)") }
        let missing = written.missing.isEmpty ? "" : " (\(written.missing.count) capture\(written.missing.count == 1 ? "" : "s") missing from the store)"
        if snapshot.profile.signIn != nil && !ws.shareSignedInMaps {
            return ("written here, not pushed: it was walked on signed-in data" + missing, nil)
        }
        if let why = git.push(remote: shareRemote, profile: snapshot.profile.id) { return ("written here" + missing, why) }
        return ("pushed to \(shareRemote)" + missing, nil)
    }

    /// Fetches `refs/greenroom/maps/*` from origin when the workspace shares maps and the last fetch for it is ten
    /// minutes old (`force`: whatever its age). Nil when it worked or was not due; else what went wrong, in words.
    @discardableResult
    static func fetchIfDue(_ ws: Workspace, stateRoot: URL, force: Bool = false) async -> String? {
        guard ws.shareMaps else { return nil }
        guard due(stateRoot.path + "\u{0}" + ws.root.resolvingSymlinksInPath().path, force: force) else { return nil }
        return await Task.detached(priority: .utility) { MapGit(repo: ws.root).fetch(remote: shareRemote) }.value
    }

    /// Whether a fetch for `key` is due (none in the last ten minutes), marking it done now when it is.
    private static func due(_ key: String, force: Bool) -> Bool {
        fetchLock.lock(); defer { fetchLock.unlock() }
        if !force, let last = lastFetch[key], Date().timeIntervalSince(last) < 600 { return false }
        lastFetch[key] = Date()
        return true
    }

    /// Imports the snapshot git has for `commit` (its own ref, else its tree's) into the store, captures included,
    /// when the store has none. True when the store has one now.
    static func importShared(commit: String, profile: MapProfile, workspace ws: Workspace, store: MapStore) -> Bool {
        if store.snapshot(profile: profile.id, commit: commit) != nil { return true }
        let git = MapGit(repo: ws.root)
        guard let s = git.read(profile: profile.id, commit: commit), s.profile.id == profile.id else { return false }
        if store.snapshot(profile: profile.id, commit: s.commit) != nil { return true }
        for sc in s.screens {
            for (combo, hash) in sc.captures where store.blobURL(hash) == nil {
                if let data = git.blobData(profile: profile.id, commit: s.commit, lineage: sc.lineage.isEmpty ? sc.id : sc.lineage, combo: combo) {
                    store.importBlob(data, expected: hash)
                }
            }
        }
        return store.save(s)
    }

    /// The baseline rule, after fetching teammates' maps when the workspace shares them: the merge base, by commit and
    /// then by tree, and failing that the nearest ancestor, each taken from git when the store has none. With sharing
    /// off this is `baseline` exactly.
    private static func sharedBaseline(place p: Place, profile: MapProfile) async -> (found: (snapshot: MapSnapshot, behind: Int)?, problem: String?) {
        let ws = p.workspace
        var problem: String?
        if ws.shareMaps {
            problem = await fetchIfDue(ws, stateRoot: p.store.folder.deletingLastPathComponent().deletingLastPathComponent())
            var mb: String?
            for ref in [ws.baseRef, ws.baseRef.hasPrefix("origin/") ? String(ws.baseRef.dropFirst(7)) : nil].compactMap({ $0 }) where mb == nil {
                mb = await Git.mergeBase(p.commit, ref, in: ws.root)
            }
            if let mb, p.store.snapshot(profile: profile.id, commit: mb) == nil, !importShared(commit: mb, profile: profile, workspace: ws, store: p.store) {
                // The nearest ancestor that git has a snapshot of (by its own ref) and the store has not.
                let shared = Set(MapGit(repo: ws.root).list(profile: profile.id)), have = Set(p.store.commits(profile: profile.id))
                if !shared.subtracting(have).isEmpty, let list = await Git.run(["rev-list", "-n", "2000", mb], in: ws.root) {
                    for c in list.split(whereSeparator: \.isNewline).map(String.init) {
                        if have.contains(c) { break }
                        if shared.contains(c) { _ = importShared(commit: c, profile: profile, workspace: ws, store: p.store); break }
                    }
                }
            }
        }
        let found = await baseline(commit: p.commit, mainRef: ws.baseRef, in: ws.root, store: p.store, profile: profile.id)
        return (found, problem)
    }

    /// The baseline of a build as a walk would find it (teammates' maps fetched and imported when the workspace shares
    /// them). Nil when the build has no commit in any of `candidates` or there is no baseline.
    static func baseline(of build: Build, profile: MapProfile, candidates: [Workspace], stateRoot: URL) async -> (snapshot: MapSnapshot, behind: Int, problem: String?)? {
        guard let p = await place(build, candidates: candidates, stateRoot: stateRoot) else { return nil }
        let r = await sharedBaseline(place: p, profile: profile)
        return r.found.map { ($0.snapshot, $0.behind, r.problem) }
    }

    // MARK: Walking only what changed (I1, I2)

    /// How a walk is to be made: in full (`seed` nil), or seeded from the baseline with only some screens walked again.
    struct WalkPlan {
        /// The baseline written out as a walk's folder, and the ids to walk again (one per line).
        var seed: URL?
        var onlyFile: URL?
        var seedSnapshot: MapSnapshot?
        var ids: [String] = []
        /// Screens in the seed, and files changed since its commit.
        var total = 0
        var files = 0
        /// Why the walk is full, in words; nil for a full walk the engine gives no choice about (as before I1).
        var reason: String?
        var recordDeps = false
        /// Why each screen of `ids` is walked again, in words ("SettingsFragment.kt changed").
        var reasons: [String: [String]] = [:]
        /// `--diff-seed`: the engine compares the walk with its seed and keeps its instances parked on the screens it
        /// walks (apksim 0.62.0). `diffControls` is its `--diff-controls`: "changed" taps only the controls the seed
        /// does not have, and is chosen only when no source file changed (a changed handler would not be tried).
        var diffSeed = false
        var diffControls = "all"
        /// The baseline was walked by another engine (its version): the map is kept, and the screens this walk carries
        /// are verified once it is filed. A screen the new engine reads differently then starts a full walk.
        var engineChanged: String?
        /// Fetching teammates' maps before looking for the baseline went wrong, in words.
        var shareProblem: String?
        var isFull: Bool { seed == nil }
    }

    /// Decides how to walk `build`: seeded when the engine can, the build has a commit with a stored baseline that
    /// recorded its dependencies, and `MapImpact` says only some screens. The seed's
    /// folder and only-file are written into `folder`. Off the main thread.
    static func plan(build: Build, profile: MapProfile, candidates: [Workspace], stateRoot: URL, engine: String, support: CrawlRun.Support,
                     forceFull: Bool, fullReason: String? = nil, folder: URL) async -> WalkPlan {
        var plan = WalkPlan(recordDeps: support.recordDeps)
        guard support.seed, support.recordDeps else { return plan }
        guard let p = await place(build, candidates: candidates, stateRoot: stateRoot) else { return plan }
        if forceFull { plan.reason = fullReason ?? "asked to walk everything again"; return plan }
        // A commit on main is walked like any other: where its changes reach. (Every tenth used to be walked in full
        // to audit the quick ones; a full walk is now the first of a project, or one the person asks for.)
        let ref = p.workspace.baseRef
        var onMain = false
        for r in [ref, ref.hasPrefix("origin/") ? String(ref.dropFirst(7)) : nil].compactMap({ $0 }) where !onMain {
            onMain = await Git.run(["merge-base", "--is-ancestor", p.commit, r], in: p.workspace.root) != nil
        }
        let shared = await sharedBaseline(place: p, profile: profile)
        plan.shareProblem = shared.problem
        guard let base = shared.found else {
            plan.reason = "no earlier walk to start from"; return plan
        }
        if base.snapshot.commit == p.commit { plan.reason = "this commit was walked before, so it is walked again in full"; return plan }
        guard let diff = await MapImpact.changes(base: base.snapshot.commit, head: p.commit, in: p.workspace.root) else {
            plan.reason = "git could not list what changed since the last walk"; return plan
        }
        plan.files = diff.changes.count
        let input = MapImpact.Input(baseline: base.snapshot, changes: diff.changes, valueDiff: diff.valueDiff, engine: engine, profile: profile,
                                    fullWalkPatterns: p.store.ledger.patterns)
        switch MapImpact.decide(input) {
        case .full(let why): plan.reason = why
        case .screens(let ids, let reasons):
            let seed = folder.appendingPathComponent("seed", isDirectory: true), only = folder.appendingPathComponent("only.txt")
            guard p.store.writeSeed(base.snapshot, to: seed),
                  (try? Data((ids.joined(separator: "\n") + (ids.isEmpty ? "" : "\n")).utf8).write(to: only, options: .atomic)) != nil else {
                try? FileManager.default.removeItem(at: seed)
                plan.reason = "the last walk's captures are not all kept"; return plan
            }
            plan.seed = seed
            plan.onlyFile = only
            plan.seedSnapshot = base.snapshot
            plan.ids = ids
            plan.total = base.snapshot.screens.count
            plan.reasons = reasons
            if base.snapshot.engine != engine, ids.count < base.snapshot.screens.count { plan.engineChanged = base.snapshot.engine }
            plan.diffSeed = support.diffSeed
            // Resources say exactly which screens show them; code may also change where a control leads.
            let codeChanged = diff.changes.contains { if case .source = MapImpact.kind(of: $0.path) { return true } else { return false } }
            let allKnown = ids.allSatisfy { base.snapshot.screen($0)?.actions != nil }
            plan.diffControls = !onMain && !codeChanged && allKnown ? "changed" : "all"
        }
        return plan
    }

    /// The files changed from `from` to `to` that could change what the app shows (none when `from` is not a commit).
    private static func relevantFiles(from: String, to: String, in dir: URL) async -> [String] {
        guard from != to, from != "unknown", let d = await MapImpact.changes(base: from, head: to, in: dir) else { return [] }
        return d.changes.map(\.path).filter { MapImpact.kind(of: $0) != .ignored }
    }

    private static func misses(_ found: [(screen: MapSnapshot.Screen, why: String)], quick: MapSnapshot, foundBy: String, place p: Place) async -> [MapImpact.Miss] {
        var out: [MapImpact.Miss] = []
        var filesFrom: [String: [String]] = [:]
        let now = ISO8601DateFormatter().string(from: Date())
        for (s, why) in found {
            let from = s.carriedFrom ?? "unknown"
            if filesFrom[from] == nil { filesFrom[from] = await relevantFiles(from: from, to: quick.commit, in: p.workspace.root) }
            out.append(MapImpact.Miss(screen: s.id, title: s.title.isEmpty ? s.activity : s.title, why: why, quickCommit: quick.commit, carriedFrom: from,
                                      foundBy: foundBy, files: filesFrom[from] ?? [], found: now))
        }
        return out
    }

    /// I2: a full walk compared with what a quick walk carried: `quick` (the same commit's), else the nearest earlier
    /// snapshot when it is quick. A difference the commits in between explain (the impact of those commits selects the
    /// screen, or would walk everything) is not a miss. Misses go into the workspace's ledger with their files.
    private static func audit(full: MapSnapshot, quick: MapSnapshot?, place p: Place) async -> (quick: String, misses: [MapImpact.Miss])? {
        var q = quick
        if q == nil {
            let have = Set(p.store.commits(profile: full.profile.id))
            if let list = await Git.run(["rev-list", "-n", "500", p.commit], in: p.workspace.root) {
                for (i, c) in list.split(whereSeparator: \.isNewline).enumerated() where i > 0 && have.contains(String(c)) {
                    q = p.store.snapshot(profile: full.profile.id, commit: String(c))
                    break
                }
            }
        }
        guard let q, q.screens.contains(where: { $0.carriedFrom != nil }) else { return nil }
        var found = MapImpact.differing(full: full, quick: q)
        if q.commit != full.commit {
            guard let d = await MapImpact.changes(base: q.commit, head: full.commit, in: p.workspace.root) else { return nil }
            switch MapImpact.decide(MapImpact.Input(baseline: q, changes: d.changes, valueDiff: d.valueDiff, engine: full.engine, profile: full.profile)) {
            case .full: return nil      // everything may have changed since: nothing to tell
            case .screens(let ids, _): found.removeAll { ids.contains($0.screen.id) }
            }
        }
        let m = await misses(found, quick: q, foundBy: full.commit, place: p)
        p.store.record(misses: m)
        return (q.commit, m)
    }

    /// "Verify carried screens": the snapshot's carried screens, to be reached again and compared (no control tried).
    /// Writes the seed folder and the only-file into `folder`; nil when nothing is carried or the seed cannot be written.
    static func verifyPlan(build: Build, profile: MapProfile, candidates: [Workspace], stateRoot: URL, folder: URL) async -> WalkPlan? {
        guard let p = await place(build, candidates: candidates, stateRoot: stateRoot),
              let snap = p.store.snapshot(profile: profile.id, commit: p.commit) else { return nil }
        let ids = snap.screens.filter { $0.carriedFrom != nil }.map(\.id)
        guard !ids.isEmpty else { return nil }
        let seed = folder.appendingPathComponent("seed", isDirectory: true), only = folder.appendingPathComponent("only.txt")
        guard p.store.writeSeed(snap, to: seed), (try? Data((ids.joined(separator: "\n") + "\n").utf8).write(to: only, options: .atomic)) != nil else { return nil }
        return WalkPlan(seed: seed, onlyFile: only, seedSnapshot: snap, ids: ids, total: snap.screens.count, recordDeps: true)
    }

    /// The verification walk's result against the snapshot: each carried screen reached again must have its id (its
    /// structure) and, when both settled, the same captures. Differences are misses, kept in the ledger. Returns how many
    /// carried screens were reached and compared, and the misses; nil when the walk cannot be read.
    static func verified(walk: URL, plan: WalkPlan, build: Build, profile: MapProfile, candidates: [Workspace], stateRoot: URL, engine: String) async -> (checked: Int, misses: [MapImpact.Miss])? {
        guard let snap = plan.seedSnapshot, let p = await place(build, candidates: candidates, stateRoot: stateRoot),
              let again = p.store.importWalk(walk, commit: p.commit, tree: p.tree, profile: profile, engine: engine, walked: Date(), seed: snap) else { return nil }
        let byID = Dictionary(again.screens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var found: [(screen: MapSnapshot.Screen, why: String)] = []
        var checked = 0
        for s in snap.screens where s.carriedFrom != nil {
            guard let v = byID[s.id] else {
                if !again.cutShort { checked += 1; found.append((s, "its structure changed")) }
                continue
            }
            checked += 1
            let steady = s.settled && v.settled && s.flaky == nil && v.flaky == nil
            if steady, Set(s.captures.keys).intersection(v.captures.keys).contains(where: { s.captures[$0] != v.captures[$0] }) {
                found.append((s, "its capture changed"))
            }
        }
        let m = await misses(found, quick: snap, foundBy: "verify", place: p)
        // Kept and shown, but no pattern: a screen reached with no control tried can differ for what the full walk did
        // before it (a job a button ran), so these are leads, not proof. A full walk's audit makes the patterns.
        p.store.record(misses: m, patterns: false)
        return (checked, m)
    }

    enum Side { case head, base }

    /// Files one side of a pair walk (`crawl.py HEAD --base BASE`): its screens, edges, findings and unfinished lines are
    /// read out of the comparison's crawl.json (the base's from `base_screens` and `base_edges`) into a walk folder of
    /// their own, with the captures cloned, which is imported like any walk.
    static func fileFromPair(folder: URL, build: Build, side: Side, workspace: Workspace, profile: MapProfile, stateRoot: URL, engine: String) async {
        guard let p = await place(build, candidates: [workspace], stateRoot: stateRoot),
              p.store.snapshot(profile: profile.id, commit: p.commit) == nil,
              let data = try? Data(contentsOf: folder.appendingPathComponent("crawl.json")),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        guard let stage = stagePair(folder: folder, raw: raw, side: side, stateRoot: stateRoot) else { return }
        defer { try? FileManager.default.removeItem(at: stage) }
        _ = await fileWalk(stage, place: p, profile: profile, engine: engine)
    }


    /// One side of a pair walk's crawl.json as a walk folder of its own, in a staging folder (the caller removes it).
    private static func stagePair(folder: URL, raw: [String: Any], side: Side, stateRoot: URL) -> URL? {
        let isBase = side == .base
        guard let screens = raw[isBase ? "base_screens" : "screens"] as? [[String: Any]] else { return nil }
        let fm = FileManager.default
        let stage = stateRoot.appendingPathComponent("history-staging/\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return nil }
        for s in screens {
            for rel in ((s["captures"] as? [String: String]) ?? [:]).values {
                let from = folder.appendingPathComponent(rel)
                guard from.isInside(folder), fm.fileExists(atPath: from.path) else { continue }
                let to = stage.appendingPathComponent(rel)
                try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: from, to: to)
            }
        }
        let findings = ((raw["findings"] as? [[String: Any]]) ?? []).filter { ((($0["build"] as? String) == "base")) == isBase }
        let incomplete = ((raw["incomplete"] as? [String]) ?? []).filter { $0.hasPrefix("base: ") == isBase }.map { isBase ? String($0.dropFirst(6)) : $0 }
        let json: [String: Any] = ["combos": raw["combos"] ?? [], "screens": screens, "edges": raw[isBase ? "base_edges" : "edges"] ?? [],
                                   "findings": findings, "incomplete": incomplete, "seconds": raw["seconds"] ?? [:]]
        guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              (try? out.write(to: stage.appendingPathComponent("crawl.json"))) != nil else { try? fm.removeItem(at: stage); return nil }
        return stage
    }

    /// The two snapshots of a pair walk's folder (`crawl.py HEAD --base BASE`), for a map that has no history behind it:
    /// each side imported into a store inside the folder, so the map has the same one input a stored comparison has.
    /// Nil when the folder is not a pair walk's. Off the main thread.
    static func pairSource(folder: URL) -> MapSource? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("crawl.json")),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], raw["base_screens"] != nil else { return nil }
        let root = folder.appendingPathComponent("pair-snapshots", isDirectory: true)
        let store = MapStore(root: root, repo: "pair")
        let profile = MapProfile()
        func side(_ side: Side, _ commit: String) -> MapSnapshot? {
            guard let stage = stagePair(folder: folder, raw: raw, side: side, stateRoot: root) else { return nil }
            defer { try? FileManager.default.removeItem(at: stage) }
            return store.importWalk(stage, commit: commit, tree: "", profile: profile, engine: "pair", walked: Date())
        }
        guard let head = side(.head, "head"), let base = side(.base, "base") else { return nil }
        return MapSource.make(head: head, base: base, history: [base, head], blobURL: { store.blobURL($0) })
    }

    // MARK: Lookup

    /// The snapshot a build stands for: its commit's, else any commit's with the same tree.
    static func snapshot(of build: Build, workspace: URL, profile: MapProfile, stateRoot: URL) async -> MapSnapshot? {
        guard fileable(build), let sha = build.sha, let (commit, tree) = await resolve(sha, in: workspace) else { return nil }
        let store = store(stateRoot: stateRoot, workspace: workspace)
        return store.snapshot(profile: profile.id, commit: commit) ?? store.snapshot(profile: profile.id, tree: tree)
    }

    static func hasSnapshot(of build: Build, workspace: URL, profile: MapProfile, stateRoot: URL) async -> Bool {
        await snapshot(of: build, workspace: workspace, profile: profile, stateRoot: stateRoot) != nil
    }

    /// A comparison from history: nil unless both builds have a snapshot of this profile. Off the main thread.
    static func changeSet(head: Build, base: Build, workspace: URL, profile: MapProfile, stateRoot: URL, folder: URL) async -> ChangeSet? {
        guard let h = await snapshot(of: head, workspace: workspace, profile: profile, stateRoot: stateRoot),
              let b = await snapshot(of: base, workspace: workspace, profile: profile, stateRoot: stateRoot) else { return nil }
        // Two different builds that find the same stored snapshot (one commit, or one tree, built twice) cannot be told
        // apart from history: whatever differs between them is not in the commit. The pair is walked instead.
        if head.key != base.key, h.commit == b.commit { return nil }
        return changeSet(head: h, base: b, store: store(stateRoot: stateRoot, workspace: workspace), folder: folder)
    }

    // MARK: The comparison

    private struct PixelNote: Codable {
        var differing: Int
        var total: Int
        var sizeChanged: Bool
    }

    /// The `ChangeSet` of two snapshots, in `folder` (made if it is not there): `MapPairing.diff`, each status as the
    /// walk's word, and for a screen whose captures differ its difference image and pixel counts, computed once and kept there.
    static func changeSet(head: MapSnapshot, base: MapSnapshot, store: MapStore, folder: URL) -> ChangeSet {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let diff = MapPairing.diff(head: head, base: base)
        let headMap = ScreenMapData.from(head, store: store, folder: folder)
        let baseMap = ScreenMapData.from(base, store: store, folder: folder)
        let headBy = Dictionary(head.screens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let baseBy = Dictionary(base.screens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byHead = Dictionary(diff.screens.compactMap { c in c.head.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        let byBase = Dictionary(diff.screens.compactMap { c in c.base.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })

        // The routes of each screen, in words.
        var routeWords: [String: String] = [:]
        for lineage in Set(diff.edges.map(\.from)) {
            var counts: [DiffEdgeStatus: Int] = [:]
            for e in diff.edges where e.from == lineage { counts[e.status, default: 0] += 1 }
            routeWords[lineage] = [DiffEdgeStatus.added, .removed, .retargeted].compactMap { st in
                counts[st].map { "\($0) route\($0 == 1 ? "" : "s") \(st.rawValue)" }
            }.joined(separator: ", ")
        }
        func why(_ c: MapDiff.ScreenChange) -> String? {
            if c.status == .notCompared { return c.why }
            guard c.status == .modified else { return nil }
            var parts: [String] = []
            for r in c.reasons {
                if r == .routes, let w = routeWords[c.lineage], !w.isEmpty { parts.append(w) } else { parts.append(r.rawValue) }
            }
            return parts.joined(separator: ", ")
        }

        var notes = readNotes(folder)
        var notesChanged = false
        func pixels(_ c: MapDiff.ScreenChange, base b: MapSnapshot.Screen, head h: MapSnapshot.Screen, combo: String) -> (note: PixelNote, image: URL?)? {
            guard let bh = b.captures[combo], let hh = h.captures[combo], bh != hh else { return nil }
            let key = String(bh.prefix(16)) + "-" + String(hh.prefix(16))
            let image = folder.appendingPathComponent("diff/\(key).png")
            if let n = notes[key], n.sizeChanged || n.differing == 0 || fm.fileExists(atPath: image.path) { return (n, n.differing > 0 && !n.sizeChanged ? image : nil) }
            guard let bu = store.blobURL(bh), let hu = store.blobURL(hh), let bi = load(bu), let hi = load(hu) else { return nil }
            guard let p = ScreenComparison.pixels(a: bi, b: hi) else {
                notes[key] = PixelNote(differing: 0, total: 0, sizeChanged: true); notesChanged = true
                return (notes[key]!, nil)
            }
            var wrote = false
            if p.differing > 0, let png = ScreenComparison.map(b: hi, cells: p.cells) {
                try? fm.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                wrote = (try? png.write(to: image, options: .atomic)) != nil
            }
            notes[key] = PixelNote(differing: p.differing, total: p.total, sizeChanged: false); notesChanged = true
            return (notes[key]!, wrote ? image : nil)
        }

        func status(_ s: MapDiff.Status) -> ChangeStatus {
            switch s {
            case .added: return .new
            case .removed: return .gone
            case .modified: return .changed
            case .same: return .same
            case .notCompared: return .unreached
            }
        }
        func capture(_ s: MapScreen?, _ combo: String?) -> URL? {
            guard let s else { return nil }
            return s.captures.first { $0.combo == combo }?.file ?? s.captures.first?.file
        }

        var screens: [ChangeScreen] = []
        var baseToMerged: [String: String] = [:]
        func add(_ c: MapDiff.ScreenChange) {
            let hs = c.head.flatMap { headBy[$0] }, bs = c.base.flatMap { baseBy[$0] }
            let id = c.head ?? ("base:" + (c.base ?? "?"))
            if let b = c.base { baseToMerged[b] = id }
            let combo = c.visual.first ?? headMap.combos.first
            var note: (note: PixelNote, image: URL?)?
            if c.status == .modified, let combo, let hs, let bs { note = pixels(c, base: bs, head: hs, combo: combo) }
            screens.append(ChangeScreen(
                id: id, headID: c.head, baseID: c.base,
                title: (hs.map { $0.title.isEmpty ? $0.activity : $0.title }) ?? (bs.map { $0.title.isEmpty ? $0.activity : $0.title }) ?? id,
                activity: hs?.activity ?? bs?.activity ?? "", status: status(c.status),
                head: capture(c.head.flatMap { headMap.screen($0) }, combo), base: capture(c.base.flatMap { baseMap.screen($0) }, combo),
                diff: note?.image, pixels: note.flatMap { $0.note.sizeChanged ? nil : $0.note.differing }, total: note.flatMap { $0.note.sizeChanged ? nil : $0.note.total },
                sizeChanged: note?.note.sizeChanged ?? false, why: why(c)))
        }
        for s in head.screens { if let c = byHead[s.id] { add(c) } }
        for s in base.screens { if let c = byBase[s.id], c.head == nil { add(c) } }
        if notesChanged { writeNotes(notes, folder) }

        var crashes: [ChangeFinding] = []
        for (side, snap) in [(ChangeFinding.Side.head, head), (.base, base)] {
            for f in snap.findings where f.kind == "crash" || f.kind == "compare" { crashes.append(ChangeFinding(side: side, kind: f.kind, detail: f.detail)) }
        }
        let headFindings = head.findings.map { MapFinding(kind: $0.kind, detail: $0.detail, steps: $0.steps) }
        let unfinished = head.incomplete.map { ChangeSet.unfinishedLine($0) } + base.incomplete.map { ChangeSet.unfinishedLine("base: " + $0) }
        var set = ChangeSet.assemble(folder: folder, screens: screens, baseToMerged: baseToMerged, headMap: headMap, baseMap: baseMap, headFindings: headFindings,
                                     crashes: crashes, unfinished: unfinished)
        set.mapSource = MapSource.make(head: head, base: base, history: [base, head], blobURL: { store.blobURL($0) })
        return set
    }

    private typealias DiffEdgeStatus = MapDiff.EdgeChange.Status

    private static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func readNotes(_ folder: URL) -> [String: PixelNote] {
        (try? Data(contentsOf: folder.appendingPathComponent("history-pixels.json"))).flatMap { try? JSONDecoder().decode([String: PixelNote].self, from: $0) } ?? [:]
    }

    private static func writeNotes(_ notes: [String: PixelNote], _ folder: URL) {
        try? MapJSON.encode(notes).write(to: folder.appendingPathComponent("history-pixels.json"), options: .atomic)
    }
}

extension ScreenMapData {
    /// A stored snapshot as a map to show: captures are the store's blobs, a screen's controls are its edges.
    static func from(_ s: MapSnapshot, store: MapStore, folder: URL) -> ScreenMapData {
        var combos = s.profile.combos
        for sc in s.screens { for k in sc.captures.keys.sorted() where !combos.contains(k) { combos.append(k) } }
        var edgesFrom: [String: [MapSnapshot.Edge]] = [:]
        for e in s.edges { edgesFrom[e.from, default: []].append(e) }
        let screens = s.screens.map { sc in
            MapScreen(id: sc.id, activity: sc.activity, title: sc.title, depth: sc.depth, parent: sc.parent, start: sc.start, steps: sc.steps,
                      captures: combos.compactMap { c in sc.captures[c].flatMap { store.blobURL($0) }.map { (combo: c, file: $0) } },
                      texts: sc.texts, settled: sc.settled, flaky: sc.flaky,
                      controls: (edgesFrom[sc.id] ?? []).map { (label: $0.action, cmd: $0.cmd, skipped: $0.to == "SKIPPED" ? ($0.note ?? "skipped") : nil) })
        }
        let edges = s.edges.map { e -> MapEdge in
            let to: MapEdge.Target
            switch e.to {
            case nil: to = .unfollowed
            case "EXIT": to = .exit
            case "CRASH": to = .crash
            case "SKIPPED": to = .skipped
            case "FAILED": to = .failed
            case let id?: to = .screen(id)
            }
            return MapEdge(from: e.from, action: e.action, cmd: e.cmd, to: to, note: e.note)
        }
        let findings = s.findings.map { MapFinding(kind: $0.kind, detail: $0.detail, steps: $0.steps) }
        return ScreenMapData(folder: folder, apkName: "", screens: screens, edges: edges, findings: findings, combos: combos, incomplete: s.incomplete,
                             seconds: s.seconds, apk: nil)
    }
}
