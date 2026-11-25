import Foundation

/// `Greenroom --map-walks DIR WALK_A WALK_B`: two finished walks (folders with a `crawl.json`, as `crawl.py --out` leaves
/// them) through map history's whole chain with no window and no engine: both are imported into a store under DIR as
/// two commits, paired and compared, and the result is exported as the HTML report in `DIR/export`. One line per
/// screen that differs and the counts are printed, so two walks of one unchanged build say how much noise a real app
/// has, and two builds say what changed.
enum MapWalksTool {
    static func run(dir: URL, a: URL, b: URL) -> Never {
        func say(_ s: String) { print("[greenroom] map-walks: " + s) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MapStore(root: dir, repo: "walks")
        var profile = MapProfile()
        let combos = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: a.appendingPathComponent("crawl.json")))) as? [String: Any])?["combos"] as? [String]
        profile.combos = combos ?? ["light"]
        func commit(_ name: String) -> String { String(MapJSON.sha256("walks|" + name).prefix(40)) }
        func take(_ walk: URL, _ name: String) -> MapSnapshot? {
            let started = Date()
            let s = store.importWalk(walk, commit: commit(name), tree: commit("tree|" + name), profile: profile, engine: "walks", walked: Date())
            if let s {
                let captures = s.screens.reduce(0) { $0 + $1.captures.count }
                say(String(format: "%@: %d screens, %d edges, %d captures, %d findings, imported in %.0f ms", name, s.screens.count, s.edges.count, captures,
                           s.findings.count, Date().timeIntervalSince(started) * 1000))
            }
            return s
        }
        guard let rawBase = take(a, "base"), let rawHead = take(b, "head") else { say("FAIL: a walk has no readable crawl.json"); exit(1) }
        let (base, _) = MapPairing.pair(head: rawBase, base: nil)
        store.save(base)
        let (head, how) = MapPairing.pair(head: rawHead, base: base)
        store.save(head)
        let started = Date()
        let diff = MapPairing.diff(head: head, base: base)
        let c = diff.counts
        say(String(format: "+%d added, -%d removed, ~%d modified, =%d same, %d not compared; %d edge changes; compared in %.1f ms",
                   c.added, c.removed, c.modified, c.same, c.notCompared, diff.edges.count, Date().timeIntervalSince(started) * 1000))
        let methods = Dictionary(grouping: how.values, by: { $0.rawValue }).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.value) by \($0.key)" }
        say("paired: " + (methods.isEmpty ? "none" : methods.joined(separator: ", ")))
        let title = Dictionary(base.screens.map { ($0.lineage, $0.title) } + head.screens.map { ($0.lineage, $0.title) }, uniquingKeysWith: { _, new in new })
        for s in diff.screens where s.status != .same {
            var line = "\(s.status.rawValue): \(title[s.lineage] ?? s.lineage) [\(s.head ?? s.base ?? "")]"
            if !s.reasons.isEmpty { line += " (" + s.reasons.map(\.rawValue).joined(separator: ", ") + ")" }
            if let why = s.why { line += " " + why }
            say(line)
        }
        let blobs = Set((base.screens + head.screens).flatMap { $0.captures.values })
        say("\(blobs.count) distinct captures stored for \(base.screens.count + head.screens.count) screen entries")
        do {
            let out = dir.appendingPathComponent("export", isDirectory: true)
            try? FileManager.default.removeItem(at: out)
            let bytes = try MapExport.write(head: head, base: base, diff: diff, blob: { store.blobURL($0) }, to: out, title: a.deletingLastPathComponent().lastPathComponent,
                                            names: (base: a.lastPathComponent, head: b.lastPathComponent))
            say(String(format: "exported %.1f MB to %@", Double(bytes) / 1_048_576, out.path))
        } catch { say("FAIL: the export did not write: \(error)"); exit(1) }
        exit(0)
    }
}
