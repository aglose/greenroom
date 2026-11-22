import Foundation

// `Greenroom --map-git-check DIR`: map snapshots in git, headless. In DIR it makes a bare repository and two clones
// of it, files snapshots in one, shares them through the bare repository and reads them in the other, and shows that
// no branch, tag, index, `HEAD` or working file of either clone moved. Nothing leaves DIR: the only remote is the
// bare repository it made.
enum MapGitCheck {
    /// A 1x1 PNG; a capture is this and a few bytes after its end, so each is another file and still an image.
    static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    static func run(dir: URL) -> Never {
        var ok = true
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; print("[greenroom] map-git: \(good ? "ok  " : "FAIL") \(what)") }
        let fm = FileManager.default
        let work = dir.appendingPathComponent("map-git")
        try? fm.removeItem(at: work)
        try? fm.createDirectory(at: work.appendingPathComponent("pngs"), withIntermediateDirectories: true)

        @discardableResult func sh(_ args: [String], _ at: URL, _ env: [String: String] = [:]) -> String {
            MapGit.exec(args, in: at, env: env).text
        }
        func png(_ s: String) -> Data { pixel + Data(s.utf8) }
        /// Captures for a snapshot: every screen's capture becomes a PNG file named by its hash.
        func fill(_ snap: MapSnapshot, variant: String = "", changing: Set<Int> = []) -> MapSnapshot {
            var s = snap
            for i in s.screens.indices {
                for c in s.screens[i].captures.keys.sorted() {
                    let data = png("\(s.screens[i].id)|\(c)|\(changing.contains(i) ? variant : "")")
                    let h = MapJSON.sha256(data)
                    try? data.write(to: work.appendingPathComponent("pngs/\(h).png"))
                    s.screens[i].captures[c] = h
                }
            }
            return s
        }
        func blob(_ h: String) -> URL? {
            let u = work.appendingPathComponent("pngs/\(h).png")
            return fm.fileExists(atPath: u.path) ? u : nil
        }

        let bare = work.appendingPathComponent("origin.git"), a = work.appendingPathComponent("a"), b = work.appendingPathComponent("b")
        sh(["init", "--bare", "-b", "main", bare.path], work)
        sh(["clone", "-q", bare.path, a.path], work)
        for r in [a] {
            sh(["config", "user.name", "Check"], r); sh(["config", "user.email", "check@localhost"], r)
        }
        var commits: [String] = [], trees: [String] = []
        for i in 1...3 {
            try? "version \(i)\n".write(to: a.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
            try? "line \(i)\n".write(to: a.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
            sh(["add", "-A"], a); sh(["commit", "-q", "-m", "commit \(i)"], a)
            commits.append(sh(["rev-parse", "HEAD"], a)); trees.append(sh(["rev-parse", "HEAD^{tree}"], a))
        }
        sh(["push", "-q", "origin", "HEAD:main"], a)
        sh(["clone", "-q", bare.path, b.path], work)
        sh(["config", "user.name", "Check"], b); sh(["config", "user.email", "check@localhost"], b)
        expect(commits.allSatisfy { $0.count == 40 } && sh(["rev-parse", "HEAD"], b) == commits[2], "two clones of one bare repository, three commits")

        /// Everything the work must leave alone.
        func state(_ r: URL) -> [String] {
            let index = (try? Data(contentsOf: r.appendingPathComponent(".git/index"))).map(MapJSON.sha256) ?? "none"
            return [sh(["status", "--porcelain"], r), sh(["rev-parse", "HEAD"], r), sh(["symbolic-ref", "HEAD"], r), sh(["ls-files", "-s"], r), index,
                    sh(["for-each-ref", "refs/heads", "refs/tags", "refs/remotes"], r), sh(["config", "--local", "--list"], r)]
        }
        let before = [state(a), state(b)]

        let ga = MapGit(repo: a), gb = MapGit(repo: b)
        var snap = fill(MapFixtures.make(screens: 7, seed: 11, combos: ["light", "dark"]))
        snap.commit = commits[2]; snap.tree = trees[2]
        let profile = snap.profile.id
        do {
            let w = try ga.write(snap, blob: blob)
            expect(w.commit.count == 40 && w.missing.isEmpty, "a snapshot written in the first clone as a commit of its own")
            let again = try ga.write(snap, blob: blob)
            expect(again.commit == w.commit, "the same snapshot written twice is the same commit")
        } catch { expect(false, "write: \(error)") }

        expect(ga.list(profile: profile) == [commits[2]], "list gives the walked commit")
        expect(ga.push(remote: "origin", profile: profile) == nil, "pushed to the bare repository")
        expect(gb.read(profile: profile, commit: commits[2]) == nil, "the second clone has nothing before it fetches")
        expect(gb.fetch(remote: "origin") == nil, "fetched in the second clone")
        let there = gb.read(profile: profile, commit: commits[2])
        expect(there?.data() == snap.data(), "the snapshot read in the second clone is the same bytes")
        var same = there != nil
        for s in snap.screens { for (c, h) in s.captures {
            let got = gb.blobData(profile: profile, commit: commits[2], lineage: s.lineage, combo: c)
            if got != (try? Data(contentsOf: blob(h)!)) { same = false }
        } }
        expect(same, "every capture read in the second clone is the PNG that was written, byte for byte")
        expect(gb.blobData(profile: profile, commit: commits[2], lineage: "nowhere@0", combo: "light") == nil, "a capture that is not there reads as nothing")

        // A squash merge's shape: a new commit, not on any branch, with a walked commit's tree.
        let squash = sh(["commit-tree", trees[2], "-p", commits[0], "-m", "squash"], b, ["GIT_AUTHOR_NAME": "x", "GIT_AUTHOR_EMAIL": "x@x", "GIT_COMMITTER_NAME": "x", "GIT_COMMITTER_EMAIL": "x@x"])
        let found = gb.read(profile: profile, commit: squash)
        expect(squash.count == 40 && squash != commits[2] && found?.data() == snap.data(), "a commit with the same tree finds that commit's snapshot")
        expect(gb.blobData(profile: profile, commit: squash, lineage: snap.screens[0].lineage, combo: "dark") != nil, "and its captures")
        expect(gb.read(profile: profile, commit: commits[0]) == nil && gb.read(profile: "00000000", commit: commits[2]) == nil, "another tree, or another profile, finds nothing")

        // Unusual lineages and combinations survive the path.
        for name in ["Main-1f0e@53ffe80", ".hidden", "a b/c", "100%", "über", "x.lock", ""] { if MapGit.decode(MapGit.encode(name)) != name || MapGit.encode(name).contains("/") { expect(false, "name \(name)") } }
        var odd = snap
        odd.commit = commits[0]; odd.tree = trees[0]; odd.screens[0].lineage = "Odd/..\\lineage with spaces@x"; odd.screens[1].lineage = ""
        if let w = try? ga.write(odd, blob: blob), w.missing.isEmpty,
           let back = ga.read(profile: profile, commit: commits[0]), back.data() == odd.data() {
            expect(ga.blobData(profile: profile, commit: commits[0], lineage: odd.screens[0].lineage, combo: "light") != nil
                   && ga.blobData(profile: profile, commit: commits[0], lineage: odd.screens[1].id, combo: "light") != nil, "a lineage git would refuse, and a screen with none, are written and read")
        } else { expect(false, "a lineage git would refuse is written") }

        // Nothing moved in either clone.
        expect(state(a) == before[0] && state(b) == before[1], "status, HEAD, the index, branches, tags and remotes are unchanged in both clones")
        let clone = work.appendingPathComponent("c")
        sh(["clone", "-q", bare.path, clone.path], work)
        expect(sh(["for-each-ref", "refs/greenroom"], clone).isEmpty && !sh(["for-each-ref", "refs/greenroom"], bare).isEmpty, "a plain clone of the bare repository has no refs/greenroom refs")

        // Shared captures: seven screens, one capture differs.
        let solo = work.appendingPathComponent("solo")
        sh(["init", "-q", "-b", "main", solo.path], work)
        sh(["config", "user.name", "Check"], solo); sh(["config", "user.email", "check@localhost"], solo)
        for i in 1...2 { try? "v\(i)".write(to: solo.appendingPathComponent("f"), atomically: true, encoding: .utf8); sh(["add", "-A"], solo); sh(["commit", "-q", "-m", "c\(i)"], solo) }
        let sc = sh(["rev-list", "--reverse", "HEAD"], solo).split(separator: "\n").map(String.init)
        let gs = MapGit(repo: solo)
        func blobs() -> Int { sh(["cat-file", "--batch-all-objects", "--batch-check=%(objecttype)"], solo).split(separator: "\n").filter { $0 == "blob" }.count }
        var one = fill(MapFixtures.make(screens: 7, seed: 5)); one.commit = sc[0]; one.tree = sh(["rev-parse", sc[0] + "^{tree}"], solo)
        var two = fill(one, variant: "changed", changing: [3]); two.commit = sc[1]; two.tree = sh(["rev-parse", sc[1] + "^{tree}"], solo)
        _ = try? gs.write(one, blob: blob)
        let n1 = blobs()
        _ = try? gs.write(two, blob: blob)
        let n2 = blobs()
        expect(n2 - n1 == 2, "two snapshots sharing 6 of 7 captures: the second adds one PNG blob (and its map.json): \(n1) then \(n2) blobs")

        // Prune.
        var other = one
        other.profile.combos = ["light", "dark"]
        _ = try? gs.write(other, blob: blob)
        let sibling = sh(["commit-tree", two.tree, "-m", "same tree"], solo, ["GIT_AUTHOR_NAME": "x", "GIT_AUTHOR_EMAIL": "x@x", "GIT_COMMITTER_NAME": "x", "GIT_COMMITTER_EMAIL": "x@x"])
        var three = two; three.commit = sibling
        _ = try? gs.write(three, blob: blob)
        let p = one.profile.id
        func refs(_ prof: String) -> [String] { sh(["for-each-ref", "--format=%(refname)", "refs/greenroom/maps/\(prof)/"], solo).split(separator: "\n").map(String.init) }
        expect(refs(p).count == 5, "three commits and their two trees have five refs (\(refs(p).count))")
        let removed = gs.prune(keeping: [sibling], profile: p)
        let left = refs(p)
        expect(removed == 3 && left.sorted() == ["refs/greenroom/maps/\(p)/\(sibling)", "refs/greenroom/maps/\(p)/tree/\(two.tree)"].sorted(),
               "prune keeps the kept commit and the tree it shares, and deletes the rest (removed \(removed))")
        expect(!refs(other.profile.id).isEmpty && gs.read(profile: p, commit: sc[1])?.commit == two.commit, "another profile's refs stay, and the kept tree still finds its snapshot")
        expect(gs.list(profile: p) == [sibling], "list after prune")

        // Size and time of a 300-screen snapshot.
        var big = fill(MapFixtures.make(screens: 300, seed: 9)); big.commit = sc[0]; big.tree = one.tree
        let t0 = Date()
        let bw = try? gs.write(big, blob: blob)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        expect(bw != nil && gs.read(profile: big.profile.id, commit: sc[0])?.data() == big.data(), "a 300-screen snapshot (\(big.data().count / 1024) KB of map.json, 300 captures) is written in \(ms) ms and read back")

        print("[greenroom] map-git check: \(ok ? "PASS" : "FAIL")")
        exit(ok ? 0 : 1)
    }
}
