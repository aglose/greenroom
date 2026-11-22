import Foundation

/// `Greenroom --map-import WALK_DIR --repo REPO --commit SHA [options] --engine VERSION --walked ISO_DATE [--seed-snapshot FILE] [--write-refs]`
/// and `Greenroom --map-import --has SHA --repo REPO [options]`: files one walk as a snapshot by hand, headless. It
/// does what `scripts/map-snapshot.py` does on Linux in CI (same options, same bytes, same git objects), through
/// `MapStore.importWalk` into a temporary store and `MapGit.write`; the check compares the two.
///
/// stdout: the snapshot's JSON. With `--write-refs`, stderr gets `snapshot-commit: <id>`. `--has` exits 0 when the
/// commit, or one with its tree, has a snapshot for the profile, else 1; other failures exit 2.
enum MapTool {
    private static func fail(_ text: String) -> Never {
        FileHandle.standardError.write(Data("map-import: \(text)\n".utf8))
        exit(2)
    }

    /// The profile from `.greenroom/map.json` (every key optional), then the command line's own settings over it.
    private static func profile(_ o: [String: [String]]) -> MapProfile {
        var p = MapProfile()
        if let file = o["--profile-file"]?.last {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)), let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                fail("cannot read the profile file \(file)")
            }
            if let v = d["depth"] as? Int { p.depth = v }
            if let v = d["seconds"] as? Int { p.seconds = v }
            if let v = d["starts"] as? [String] { p.starts = v }
            if let v = d["combos"] as? [String] { p.combos = v }
            if let v = d["signIn"] as? String, !v.isEmpty { p.signIn = v }
            if let v = d["offline"] as? Bool { p.offline = v }
        }
        if let v = o["--depth"]?.last { guard let n = Int(v) else { fail("--depth is not a number") }; p.depth = n }
        if let v = o["--seconds"]?.last { guard let n = Int(v) else { fail("--seconds is not a number") }; p.seconds = n }
        if let v = o["--start"], !v.isEmpty { p.starts = v }
        if let v = o["--combos"]?.last { p.combos = v.split(separator: ",").map(String.init) }
        if let v = o["--sign-in"]?.last, !v.isEmpty { p.signIn = v }
        if o["--offline"] != nil { p.offline = true }
        return p
    }

    static func run(_ args: [String]) -> Never {
        let flags: Set<String> = ["--offline", "--write-refs"]
        let valued: Set<String> = ["--repo", "--commit", "--has", "--profile-file", "--depth", "--seconds", "--start", "--combos", "--sign-in", "--engine", "--walked", "--seed-snapshot"]
        var o: [String: [String]] = [:]
        var walk: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            if flags.contains(a) { o[a, default: []].append("") }
            else if valued.contains(a) {
                guard i + 1 < args.count else { fail("\(a) needs a value") }
                o[a, default: []].append(args[i + 1]); i += 1
            } else if a.hasPrefix("--") { fail("unknown option \(a)") }
            else if walk == nil { walk = a }
            else { fail("more than one walk folder") }
            i += 1
        }
        guard let repoPath = o["--repo"]?.last else { fail("--repo is required") }
        let git = MapGit(repo: URL(fileURLWithPath: repoPath))
        let p = profile(o)

        if let sha = o["--has"]?.last { exit(git.read(profile: p.id, commit: sha) != nil ? 0 : 1) }

        guard let walk, let commit = o["--commit"]?.last, let engine = o["--engine"]?.last, let walkedText = o["--walked"]?.last else {
            fail("WALK_DIR, --commit, --engine and --walked are required")
        }
        guard let walked = ISO8601DateFormatter().date(from: walkedText) else { fail("--walked is not an ISO 8601 date: \(walkedText)") }
        let t = MapGit.exec(["rev-parse", "--verify", "-q", "--end-of-options", commit + "^{tree}"], in: git.repo)
        guard t.ok, !t.text.isEmpty else { fail("no such commit in \(repoPath): \(commit)") }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("greenroom-map-import-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = MapStore(root: temp, repo: "import")
        var seed: MapSnapshot?
        if let file = o["--seed-snapshot"]?.last {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)), let s = MapSnapshot.read(data) else { fail("--seed-snapshot is not a readable snapshot: \(file)") }
            seed = s
        }
        guard let snapshot = store.importWalk(URL(fileURLWithPath: walk), commit: commit, tree: t.text, profile: p, engine: engine, walked: walked, seed: seed) else {
            fail("no readable crawl.json in \(walk)")
        }
        FileHandle.standardOutput.write(snapshot.data())
        if o["--write-refs"] != nil {
            do {
                let written = try git.write(snapshot, blob: { store.blobURL($0) })
                FileHandle.standardError.write(Data("snapshot-commit: \(written.commit)\n".utf8))
            } catch { fail("\(error)") }
        }
        exit(0)
    }
}
