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
        guard !b.dirty, let sha = b.sha, !sha.isEmpty, !sha.hasPrefix("-") else { return false }
        return true
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
    static func file(walk: URL, build: Build, profile: MapProfile, candidates: [Workspace], stateRoot: URL, engine: String) async -> Bool {
        guard let p = await place(build, candidates: candidates, stateRoot: stateRoot) else { return false }
        return await fileWalk(walk, place: p, profile: profile, engine: engine)
    }

    private static func fileWalk(_ walk: URL, place p: Place, profile: MapProfile, engine: String) async -> Bool {
        if p.store.snapshot(profile: profile.id, commit: p.commit) != nil { return true }
        guard let imported = p.store.importWalk(walk, commit: p.commit, tree: p.tree, profile: profile, engine: engine, walked: Date()) else { return false }
        let base = await baseline(commit: p.commit, mainRef: p.workspace.baseRef, in: p.workspace.root, store: p.store, profile: profile.id)
        let (paired, _) = MapPairing.pair(head: imported, base: base?.snapshot)
        return p.store.save(paired)
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
