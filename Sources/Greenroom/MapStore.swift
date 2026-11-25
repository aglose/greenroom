import Foundation

/// Map history's local store (docs/MAP-HISTORY-PLAN.md, "The store, and git"): one repository's snapshots and the
/// captures they name, kept so a capture that did not change is stored once.
///
///     <root>/history/<repo>/snapshots/<profile>/<commit>.json   the bytes of `MapSnapshot.data()`
///     <root>/history/<repo>/blobs/<sha256>.png                  captures, named by the hash of their bytes
///     <root>/history/<repo>/trees/<profile>/<tree>              the commit whose snapshot a tree is found by
///
/// - Folders are private (0700). Every file is written whole or not at all, and a write that would change nothing is
///   not made, so a second import of the same walk leaves every file's date alone.
/// - Safe from any queue: one lock serializes the store's changes, and readers only ever see whole files.
/// - `importWalk` fills the blobs and returns the snapshot without saving it: its lineages are empty, and a saved
///   snapshot must not be replaced by one without them. The pairing assigns lineages, then `save` keeps it.
final class MapStore {
    let folder: URL
    private let lock = NSLock()
    private let fm = FileManager.default

    /// `repo` names the repository's folder under `history/`.
    init(root: URL, repo: String = "local") {
        folder = root.appendingPathComponent("history", isDirectory: true).appendingPathComponent(MapStore.safe(repo) ?? "local", isDirectory: true)
        lock.lock(); defer { lock.unlock() }
        makeFolder(folder)
    }

    // MARK: Import

    /// Reads a walk's folder (`crawl.json` and the captures it names) into a snapshot, storing each capture once.
    /// The file is read here, not through `ScreenMapData`, so the order of the edges and the raw `to` survive.
    /// Nil when there is no readable `crawl.json`. A capture whose file is missing is left out of its screen.
    ///
    /// A walk seeded from an earlier one (`crawl.py --seed`, package I1) marks each screen `"origin": "walked"` or
    /// `"carried"`. A carried screen's `carriedFrom` is the commit its entry was walked at: the seed's own entry's
    /// `carriedFrom`, else the seed's commit; "unknown" when no `seed` is given. A carried screen the engine wrote without
    /// `deps` keeps the seed entry's. `deps`, `start_deps` and `deps_unreliable` (`--record-deps`) are read as they are.
    func importWalk(_ walk: URL, commit: String, tree: String, profile: MapProfile, engine: String, walked: Date, seed: MapSnapshot? = nil) -> MapSnapshot? {
        guard MapStore.safe(commit) != nil,
              let data = try? Data(contentsOf: walk.appendingPathComponent("crawl.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["screens"] as? [[String: Any]] else { return nil }

        var hashes: [String: String] = [:]      // relative path to blob, so a file shared by two screens is read once
        func blob(_ rel: String) -> String? {
            if let h = hashes[rel] { return h }
            let file = walk.appendingPathComponent(rel)
            guard file.isInside(walk), let h = storeBlob(file) else { return nil }
            hashes[rel] = h
            return h
        }

        let screens: [MapSnapshot.Screen] = list.compactMap { s in
            guard let id = s["id"] as? String else { return nil }
            let path = (s["path"] as? [String: Any]) ?? [:]
            var captures: [String: String] = [:]
            for (combo, rel) in (s["captures"] as? [String: String]) ?? [:] {
                if let h = blob(rel) { captures[combo] = h }
            }
            let activity = ((s["activity"] as? String) ?? id).split(separator: ".").last.map(String.init) ?? id
            var carriedFrom: String?
            var deps = MapStore.deps(s["deps"])
            if (s["origin"] as? String) == "carried" {
                let was = seed?.screen(id)
                carriedFrom = was.map { $0.carriedFrom ?? seed!.commit } ?? seed?.commit ?? "unknown"
                if deps == nil { deps = was?.deps }
            }
            var actions = MapStore.actions(s["actions"])
            if actions == nil, (s["origin"] as? String) == "carried" { actions = seed?.screen(id)?.actions }
            return MapSnapshot.Screen(id: id, lineage: "", activity: activity, title: (s["title"] as? String) ?? "",
                                      depth: (s["depth"] as? Int) ?? 0, parent: s["parent"] as? String, start: path["start"] as? String,
                                      steps: (path["steps"] as? [String]) ?? [], captures: captures, texts: (s["texts"] as? [String]) ?? [],
                                      settled: (s["settled"] as? Bool) ?? true, flaky: s["flaky"] as? String, carriedFrom: carriedFrom, deps: deps, actions: actions)
        }

        var next: [String: Int] = [:]       // each screen's controls are numbered in the order the file lists them
        let edges: [MapSnapshot.Edge] = ((json["edges"] as? [[String: Any]]) ?? []).compactMap { e in
            guard let from = e["from"] as? String else { return nil }
            let order = next[from, default: 0]
            next[from] = order + 1
            return MapSnapshot.Edge(from: from, order: order, action: (e["action"] as? String) ?? "", cmd: (e["cmd"] as? String) ?? "",
                                    to: e["to"] as? String, note: e["note"] as? String,
                                    kind: e["kind"] as? String, steps: e["steps"] as? [String])
        }
        let findings: [MapSnapshot.Finding] = ((json["findings"] as? [[String: Any]]) ?? []).map { f in
            MapSnapshot.Finding(kind: (f["kind"] as? String) ?? "", detail: (f["detail"] as? String) ?? "",
                                steps: ((f["path"] as? [String: Any])?["steps"] as? [String]) ?? [])
        }
        return MapSnapshot(commit: commit, tree: tree, profile: profile, engine: engine, walked: ISO8601DateFormatter().string(from: walked),
                           screens: screens, edges: edges, findings: findings,
                           // A seeded walk says what its seed left unfinished as "seed: ...": the same fact for this walk.
                           incomplete: ((json["incomplete"] as? [String]) ?? []).map { $0.hasPrefix("seed: ") ? String($0.dropFirst(6)) : $0 },
                           seconds: ((json["seconds"] as? [String: Any])?["total"] as? Double) ?? 0,
                           startDeps: MapStore.deps(json["start_deps"]), depsUnreliable: json["deps_unreliable"] as? String).canonical()
    }

    /// crawl.json's `actions` list. Nil when the screen has none written (a walk that did not read its controls).
    private static func actions(_ value: Any?) -> [MapSnapshot.Action]? {
        guard let list = value as? [[String: Any]] else { return nil }
        return list.compactMap { a in
            guard let label = a["label"] as? String, let cmd = a["cmd"] as? String else { return nil }
            return MapSnapshot.Action(label: label, cmd: cmd, kind: (a["kind"] as? String) ?? "control", box: a["box"] as? [Int],
                                      skipped: a["skipped"] as? String, scrolls: (a["scrolls"] as? Int) ?? 0)
        }
    }

    /// crawl.json's `deps` object: each list read when it is a list of strings, else empty. Nil when it is not an object.
    private static func deps(_ value: Any?) -> MapSnapshot.Deps? {
        guard let d = value as? [String: Any] else { return nil }
        return MapSnapshot.Deps(classes: (d["classes"] as? [String]) ?? [], sources: (d["sources"] as? [String]) ?? [], resources: (d["resources"] as? [String]) ?? [])
    }

    /// Keeps a capture given as bytes (a map fetched through git), under the hash of those bytes. Nil when `expected` is
    /// given and the bytes do not have it, or it could not be written.
    @discardableResult
    func importBlob(_ data: Data, expected: String? = nil) -> String? {
        let hash = MapJSON.sha256(data)
        if let expected, expected != hash { return nil }
        lock.lock(); defer { lock.unlock() }
        let dest = blobFile(hash)
        if fm.fileExists(atPath: dest.path) { return hash }
        makeFolder(dest.deletingLastPathComponent())
        return (try? data.write(to: dest, options: .atomic)) != nil ? hash : nil
    }

    // MARK: Seed

    /// Writes a stored snapshot back out as a walk's folder, in the shape `crawl.py` writes and reads (`--seed`):
    /// `crawl.json` and its captures, cloned from the blobs as `screens/<hash>.png`. Each screen says `origin` (carried
    /// when its entry was carried), so `importWalk(folder, ..., seed: snapshot)` gives the snapshot back, lineages aside.
    /// False when the folder could not be written or a capture is missing from the store.
    @discardableResult
    func writeSeed(_ snapshot: MapSnapshot, to folder: URL) -> Bool {
        try? fm.removeItem(at: folder)
        makeFolder(folder.appendingPathComponent("screens", isDirectory: true))
        func depsJSON(_ d: MapSnapshot.Deps) -> [String: Any] { ["classes": d.classes, "sources": d.sources, "resources": d.resources] }
        var complete = true
        var screens: [[String: Any]] = []
        for sc in snapshot.screens {
            var captures: [String: String] = [:]
            for (combo, hash) in sc.captures {
                let rel = "screens/\(hash).png"
                let to = folder.appendingPathComponent(rel)
                if !fm.fileExists(atPath: to.path) {
                    guard let from = blobURL(hash) else { complete = false; continue }
                    if clonefile(from.path, to.path, 0) != 0, (try? fm.copyItem(at: from, to: to)) == nil { complete = false; continue }
                }
                captures[combo] = rel
            }
            var path: [String: Any] = ["steps": sc.steps]
            if let start = sc.start { path["start"] = start }
            var o: [String: Any] = ["id": sc.id, "activity": sc.activity, "title": sc.title, "depth": sc.depth, "path": path, "captures": captures,
                                    "texts": sc.texts, "settled": sc.settled, "origin": sc.carriedFrom == nil ? "walked" : "carried"]
            o["parent"] = sc.parent ?? NSNull()
            if let f = sc.flaky { o["flaky"] = f }
            if let d = sc.deps { o["deps"] = depsJSON(d) }
            if let list = sc.actions {
                o["actions"] = list.map { a -> [String: Any] in
                    var j: [String: Any] = ["label": a.label, "cmd": a.cmd, "kind": a.kind, "scrolls": a.scrolls, "skipped": a.skipped ?? NSNull()]
                    if let b = a.box { j["box"] = b }
                    return j
                }
            }
            screens.append(o)
        }
        let edges: [[String: Any]] = snapshot.edges.map { e in
            var o: [String: Any] = ["from": e.from, "action": e.action, "cmd": e.cmd]
            if let to = e.to { o["to"] = to }
            if let n = e.note { o["note"] = n }
            if let k = e.kind { o["kind"] = k }
            if let st = e.steps { o["steps"] = st }
            return o
        }
        // The combinations as the walk named them (the engine's matrix labels, "phone-light-en-US-1"), which the crawler
        // checks against its own: the profile's names first when they are used, then the rest in order.
        let used = Set(snapshot.screens.flatMap { $0.captures.keys })
        let combos = snapshot.profile.combos.filter { used.contains($0) } + used.subtracting(snapshot.profile.combos).sorted()
        var json: [String: Any] = [
            "combos": combos, "screens": screens, "edges": edges,
            "findings": snapshot.findings.map { ["kind": $0.kind, "detail": $0.detail, "path": ["steps": $0.steps]] },
            "incomplete": snapshot.incomplete, "seconds": ["total": snapshot.seconds],
            // Not read by the crawler: what this seed is, for a person looking at the folder.
            "greenroom_seed": ["commit": snapshot.commit, "profile": snapshot.profile.id, "engine": snapshot.engine],
        ]
        if let d = snapshot.startDeps { json["start_deps"] = depsJSON(d) }
        if let u = snapshot.depsUnreliable { json["deps_unreliable"] = u }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted]),
              (try? data.write(to: folder.appendingPathComponent("crawl.json"), options: .atomic)) != nil else { return false }
        return complete
    }

    /// Keeps a snapshot, and its tree's way to it when the tree has none yet. False when it could not be written.
    @discardableResult
    func save(_ snapshot: MapSnapshot) -> Bool {
        guard let profile = MapStore.safe(snapshot.profile.id), MapStore.safe(snapshot.commit) != nil else { return false }
        lock.lock(); defer { lock.unlock() }
        let bytes = snapshot.data()
        let file = snapshotFile(profile, snapshot.commit)
        makeFolder(file.deletingLastPathComponent())
        if (try? Data(contentsOf: file)) != bytes {
            do { try bytes.write(to: file, options: .atomic) } catch { return false }
        }
        if let tree = MapStore.safe(snapshot.tree) {
            let entry = treeFile(profile, tree)
            let current = (try? String(contentsOf: entry, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // The first commit to be walked keeps the tree, unless its snapshot has gone.
            if current == nil || !fm.fileExists(atPath: snapshotFile(profile, current!).path) {
                makeFolder(entry.deletingLastPathComponent())
                if current != snapshot.commit { try? Data((snapshot.commit + "\n").utf8).write(to: entry, options: .atomic) }
            }
        }
        return true
    }

    // MARK: Lookup

    func snapshot(profile: String, commit: String) -> MapSnapshot? {
        guard let p = MapStore.safe(profile), MapStore.safe(commit) != nil,
              let data = try? Data(contentsOf: snapshotFile(p, commit)) else { return nil }
        return MapSnapshot.read(data)
    }

    /// The snapshot of any commit that has this tree: the same tree is the same app.
    func snapshot(profile: String, tree: String) -> MapSnapshot? {
        guard let p = MapStore.safe(profile), let t = MapStore.safe(tree),
              let commit = (try? String(contentsOf: treeFile(p, t), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return snapshot(profile: profile, commit: commit)
    }

    /// The commits that have a snapshot for this profile, sorted.
    func commits(profile: String) -> [String] {
        guard let p = MapStore.safe(profile) else { return [] }
        let names = (try? fm.contentsOfDirectory(atPath: snapshotFile(p, "x").deletingLastPathComponent().path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// Where a capture is kept; nil when it is not in the store.
    func blobURL(_ hash: String) -> URL? {
        guard let h = MapStore.safe(hash) else { return nil }
        let url = blobFile(h)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Prune

    /// Removes the snapshots not in `keep` (profile id, commit), then the captures no snapshot left names, and the
    /// tree entries that led to a removed snapshot. Returns what it removed.
    @discardableResult
    func prune(keep: [(profile: String, commit: String)]) -> (snapshots: Int, blobs: Int) {
        lock.lock(); defer { lock.unlock() }
        let kept = Set(keep.map { $0.profile + "/" + $0.commit })
        let snaps = folder.appendingPathComponent("snapshots", isDirectory: true)
        var removedSnapshots = 0
        var used = Set<String>()
        for profile in (try? fm.contentsOfDirectory(atPath: snaps.path)) ?? [] {
            let dir = snaps.appendingPathComponent(profile, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".json") {
                let commit = String(name.dropLast(5))
                if !kept.contains(profile + "/" + commit) {
                    try? fm.removeItem(at: dir.appendingPathComponent(name))
                    removedSnapshots += 1
                } else if let data = try? Data(contentsOf: dir.appendingPathComponent(name)), let s = MapSnapshot.read(data) {
                    for screen in s.screens { used.formUnion(screen.captures.values) }
                } else {
                    // Unreadable: keep what it might name rather than lose captures to a bad file.
                    return (removedSnapshots, 0)
                }
            }
            // A tree entry whose snapshot is gone leads nowhere.
            let trees = folder.appendingPathComponent("trees", isDirectory: true).appendingPathComponent(profile, isDirectory: true)
            for tree in (try? fm.contentsOfDirectory(atPath: trees.path)) ?? [] {
                let commit = ((try? String(contentsOf: trees.appendingPathComponent(tree), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !fm.fileExists(atPath: dir.appendingPathComponent(commit + ".json").path) { try? fm.removeItem(at: trees.appendingPathComponent(tree)) }
            }
        }
        var removedBlobs = 0
        let blobs = folder.appendingPathComponent("blobs", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: blobs.path)) ?? [] where name.hasSuffix(".png") {
            if !used.contains(String(name.dropLast(4))) {
                try? fm.removeItem(at: blobs.appendingPathComponent(name))
                removedBlobs += 1
            }
        }
        return (removedSnapshots, removedBlobs)
    }

    // MARK: Files

    /// Copies a capture in under the hash of its bytes (an APFS clone, so no space), unless that blob is there.
    private func storeBlob(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        let hash = MapJSON.sha256(data)
        lock.lock(); defer { lock.unlock() }
        let dest = blobFile(hash)
        if fm.fileExists(atPath: dest.path) { return hash }
        makeFolder(dest.deletingLastPathComponent())
        // Copied beside the blob and renamed, so the blob is never seen half written.
        let part = dest.deletingLastPathComponent().appendingPathComponent(".part-" + UUID().uuidString)
        do {
            try fm.copyItem(at: file, to: part)
            try fm.moveItem(at: part, to: dest)
        } catch {
            try? fm.removeItem(at: part)
            return fm.fileExists(atPath: dest.path) ? hash : nil
        }
        return hash
    }

    private func snapshotFile(_ profile: String, _ commit: String) -> URL {
        folder.appendingPathComponent("snapshots", isDirectory: true).appendingPathComponent(profile, isDirectory: true).appendingPathComponent(commit + ".json")
    }
    private func treeFile(_ profile: String, _ tree: String) -> URL {
        folder.appendingPathComponent("trees", isDirectory: true).appendingPathComponent(profile, isDirectory: true).appendingPathComponent(tree)
    }
    private func blobFile(_ hash: String) -> URL { folder.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent(hash + ".png") }

    /// Creates a folder and any above it that are missing, all private.
    private func makeFolder(_ url: URL) {
        try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// A name that is safe as one path component: letters, digits, dash and underscore only (hashes, ids).
    private static func safe(_ name: String) -> String? {
        !name.isEmpty && name.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 }) ? name : nil
    }
}
