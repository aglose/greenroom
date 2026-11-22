import CoreGraphics
import Foundation
import ImageIO

/// `Greenroom --map-history-check DIR`: map history wired into comparisons (History), headless, no engine. Golden pairs
/// from `MapFixtures` are written into a `MapStore` under DIR with small generated PNGs as their blobs; a `ChangeSet`
/// made from history has the counts and statuses the pair's expected difference has, and each modified screen with
/// differing captures has a difference image on disk. Then the baseline rule on a temporary git repository (the merge
/// base, then a tree match, then the nearest ancestor), and a pair walk's folder filed from both sides.
enum HistoryCheck {
    private static func png(_ url: URL, seed: String) {
        let h = Array(MapJSON.sha256(seed).utf8)
        func channel(_ i: Int) -> CGFloat { CGFloat((Int(h[i]) * 37 + Int(h[i + 1]) * 11) % 256) / 255 }
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: channel(0), green: channel(2), blue: channel(4), alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Every capture the snapshot names, as a PNG in the store's blobs (the fixtures have none behind their names).
    private static func writeBlobs(_ s: MapSnapshot, store: MapStore) {
        let blobs = store.folder.appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        for sc in s.screens { for h in sc.captures.values where store.blobURL(h) == nil { png(blobs.appendingPathComponent(h + ".png"), seed: h) } }
    }

    private static func status(_ s: MapDiff.Status) -> ChangeStatus {
        switch s {
        case .added: return .new
        case .removed: return .gone
        case .modified: return .changed
        case .same: return .same
        case .notCompared: return .unreached
        }
    }

    static func run(dir: URL) -> Never {
        var ok = true
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; print("[greenroom] map-history: \(good ? "ok  " : "FAIL") \(what)") }
        let fm = FileManager.default
        let base = dir.resolvingSymlinksInPath().appendingPathComponent("map-history-check", isDirectory: true)
        try? fm.removeItem(at: base)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)

        // 1. Golden pairs, from history.
        for p in MapFixtures.golden() {
            let store = MapStore(root: base.appendingPathComponent("state-" + p.name, isDirectory: true), repo: "fixtures")
            writeBlobs(p.base, store: store); writeBlobs(p.head, store: store)
            store.save(p.base); store.save(p.head)
            guard let b = store.snapshot(profile: p.base.profile.id, commit: p.base.commit), let h = store.snapshot(profile: p.head.profile.id, commit: p.head.commit) else {
                expect(false, "\(p.name): the pair was stored and read back"); continue
            }
            // A base made outside the app has no lineages; the head's are the pairing's to find.
            var bare = h
            for i in bare.screens.indices { bare.screens[i].lineage = "" }
            let folder = base.appendingPathComponent("changes-" + p.name, isDirectory: true)
            let set = History.changeSet(head: bare, base: b, store: store, folder: folder)
            let c = p.expected.counts
            expect(set.summary.new == c.added && set.summary.gone == c.removed && set.summary.changed == c.modified && set.summary.same == c.same && set.unreached == c.notCompared,
                   "\(p.name): counts new \(set.summary.new) gone \(set.summary.gone) changed \(set.summary.changed) same \(set.summary.same) not reached \(set.unreached) as expected")
            var wrong = 0, missing = 0, withVisual = 0
            for e in p.expected.screens {
                let id = e.head ?? ("base:" + (e.base ?? "?"))
                guard let s = set.screen(id) else { wrong += 1; continue }
                if s.status != status(e.status) { wrong += 1 }
                if e.status == .modified, !e.visual.isEmpty {
                    withVisual += 1
                    if !s.why.map({ $0.contains("visual") }).orFalse { wrong += 1 }
                    if let d = s.diff, fm.fileExists(atPath: d.path), d.isInside(folder), (s.pixels ?? 0) > 0, (s.total ?? 0) > 0 {} else { missing += 1 }
                }
            }
            expect(wrong == 0 && set.screens.count == p.expected.screens.count, "\(p.name): each of \(p.expected.screens.count) screens has the expected status")
            expect(missing == 0, "\(p.name): \(withVisual) modified screen(s) with differing captures have a difference image and pixel counts")
            // Asked again, the images are the ones that were made (cached beside the comparison).
            let imageDates = (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("diff").path)) ?? []
            let again = History.changeSet(head: bare, base: b, store: store, folder: folder)
            expect(again.screens.map(\.status) == set.screens.map(\.status) && ((try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("diff").path)) ?? []) == imageDates,
                   "\(p.name): the same comparison again gives the same result and the same images")
        }

        // 2. The baseline rule, in a temporary repository: main has c1..c4 with a tree of its own each, a branch has one more.
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "user.name=Check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false"] + args
            p.currentDirectoryURL = repo
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        func commit(_ name: String, content: String? = nil) -> String {
            try? (content ?? name).write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            _ = git(["add", "."]); _ = git(["commit", "-q", "--allow-empty", "-m", name])
            return git(["rev-parse", "HEAD"]) ?? ""
        }
        guard git(["init", "-q", "-b", "main"]) != nil else { expect(false, "baseline: a repository was made (is /usr/bin/git there?)"); finish(ok) }
        let c = [commit("c1"), commit("c2"), commit("c3"), commit("c4")]
        _ = git(["checkout", "-q", "-b", "feature"])
        let f1 = commit("f1")
        _ = git(["checkout", "-q", "main"])
        _ = commit("c5")    // main has moved on, so the merge base is c4
        func tree(_ sha: String) -> String { git(["rev-parse", sha + "^{tree}"]) ?? "" }
        let profile = MapProfile()
        let map = MapFixtures.make(screens: 12, seed: 5)
        func snap(_ commit: String) -> MapSnapshot { var s = map; s.commit = commit; s.tree = tree(commit); s.profile = profile; return s }

        let wait = DispatchSemaphore(value: 0)
        func baseline(_ store: MapStore) -> (MapSnapshot, Int)? {
            var out: (MapSnapshot, Int)?
            Task { out = await History.baseline(commit: f1, mainRef: "main", in: repo, store: store, profile: profile.id).map { ($0.snapshot, $0.behind) }; wait.signal() }
            wait.wait()
            return out
        }
        let fresh = MapStore(root: base.appendingPathComponent("state-baseline", isDirectory: true), repo: "repo")
        expect(baseline(fresh) == nil, "baseline: a history with no snapshot has none")
        fresh.save(snap(c[0]))
        let far = baseline(fresh)
        expect(far?.0.commit == c[0] && far?.1 == 3, "baseline: no snapshot at the merge base, the nearest ancestor with one is c1, 3 commits behind (\(far.map { String($0.0.commit.prefix(7)) + ", " + String($0.1) } ?? "none"))")
        fresh.save(snap(c[1]))
        let nearer = baseline(fresh)
        expect(nearer?.0.commit == c[1] && nearer?.1 == 2, "baseline: with c2 filed too, c2 is the nearest ancestor, 2 behind")
        // A snapshot of another commit that has the merge base's tree is its tree match.
        let twin = commit("twin", content: "c4")     // same content as c4: the same tree, on main after c5
        expect(tree(twin) == tree(c[3]), "baseline: the twin commit has c4's tree")
        _ = git(["reset", "-q", "--hard", "HEAD~1"])
        fresh.save(snap(twin))
        let byTree = baseline(fresh)
        expect(byTree?.0.commit == twin && byTree?.1 == 0, "baseline: the merge base has no snapshot, a commit with its tree does: that one, 0 behind")
        fresh.save(snap(c[3]))
        let direct = baseline(fresh)
        expect(direct?.0.commit == c[3] && direct?.1 == 0, "baseline: the merge base's own snapshot wins over a tree match")

        // 3. A pair walk's folder filed from both sides, then compared from history, is the comparison the walk made.
        let store = History.store(stateRoot: base.appendingPathComponent("state-pair", isDirectory: true), workspace: repo)
        let pairFolder = base.appendingPathComponent("pair-walk", isDirectory: true)
        try? fm.createDirectory(at: pairFolder.appendingPathComponent("screens"), withIntermediateDirectories: true)
        func shot(_ n: String, _ seed: String) -> String { png(pairFolder.appendingPathComponent("screens/\(n).png"), seed: seed); return "screens/\(n).png" }
        func scr(_ id: String, _ title: String, _ cap: String, parent: String?) -> [String: Any] {
            ["id": id, "activity": "app.\(id.split(separator: "-")[0])", "title": title, "depth": parent == nil ? 0 : 1, "parent": parent as Any? ?? NSNull(),
             "path": ["steps": parent == nil ? [] : ["tap-text \(title)"]], "captures": ["light": cap], "texts": [title], "settled": true]
        }
        let headScreens = [scr("Home-aaaa0001", "Home", shot("h-home", "home-head"), parent: nil), scr("Trips-bbbb0002", "Trips", shot("h-trips", "trips-same"), parent: "Home-aaaa0001"),
                           scr("Cart-cccc0003", "Cart", shot("h-cart", "cart"), parent: "Home-aaaa0001")]
        let baseScreens = [scr("Home-aaaa0001", "Home", shot("b-home", "home-base"), parent: nil), scr("Trips-bbbb0002", "Trips", shot("b-trips", "trips-same"), parent: "Home-aaaa0001"),
                           scr("Old-dddd0004", "Old", shot("b-old", "old"), parent: "Home-aaaa0001")]
        func edges(_ ids: [(String, String)]) -> [[String: Any]] { ids.map { ["from": "Home-aaaa0001", "action": $0.0, "cmd": "tap-text \($0.0)", "to": $0.1] } }
        let json: [String: Any] = ["combos": ["light"], "screens": headScreens, "edges": edges([("Trips", "Trips-bbbb0002"), ("Cart", "Cart-cccc0003")]),
                                   "base_screens": baseScreens, "base_edges": edges([("Trips", "Trips-bbbb0002"), ("Old", "Old-dddd0004")]),
                                   "compare": [["id": "Home-aaaa0001", "base": "Home-aaaa0001", "status": "changed"], ["id": "Trips-bbbb0002", "base": "Trips-bbbb0002", "status": "same"],
                                               ["id": "Cart-cccc0003", "status": "new"], ["base": "Old-dddd0004", "status": "gone"]],
                                   "findings": [["kind": "crash", "detail": "boom", "build": "base"]], "incomplete": [], "seconds": ["total": 1.0]]
        try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: pairFolder.appendingPathComponent("crawl.json"))
        let ws = Workspace(root: repo)
        let stateRoot = base.appendingPathComponent("state-pair", isDirectory: true)
        let now = Date()
        let baseBuild = Build(key: "b", apk: pairFolder.appendingPathComponent("b.apk"), source: .local, sha: c[3], ref: nil, dirty: false, date: now)
        let headBuild = Build(key: "h", apk: pairFolder.appendingPathComponent("h.apk"), source: .local, sha: f1, ref: nil, dirty: false, date: now)
        let dirtyBuild = Build(key: "d", apk: pairFolder.appendingPathComponent("d.apk"), source: .local, sha: f1, ref: nil, dirty: true, date: now)
        let noCommit = Build(key: "n", apk: pairFolder.appendingPathComponent("n.apk"), source: .file, sha: nil, ref: nil, dirty: false, date: now)
        let pairProfile = profile
        var from: ChangeSet?
        var dirtyFiled = true, noCommitFiled = true
        Task {
            dirtyFiled = await History.file(walk: pairFolder, build: dirtyBuild, profile: pairProfile, candidates: [ws], stateRoot: stateRoot, engine: "x")
            noCommitFiled = await History.file(walk: pairFolder, build: noCommit, profile: pairProfile, candidates: [ws], stateRoot: stateRoot, engine: "x")
            await History.fileFromPair(folder: pairFolder, build: baseBuild, side: .base, workspace: ws, profile: pairProfile, stateRoot: stateRoot, engine: "x")
            await History.fileFromPair(folder: pairFolder, build: headBuild, side: .head, workspace: ws, profile: pairProfile, stateRoot: stateRoot, engine: "x")
            from = await History.changeSet(head: headBuild, base: baseBuild, workspace: repo, profile: pairProfile, stateRoot: stateRoot, folder: base.appendingPathComponent("changes-pair"))
            wait.signal()
        }
        wait.wait()
        expect(!dirtyFiled && !noCommitFiled && store.commits(profile: pairProfile.id).count == 2, "filing: a dirty build and one with no commit file nothing; the pair's two commits are filed")
        let walked = ChangeSet.read(pairFolder)
        if let from, let walked {
            expect(from.summary == walked.summary && walked.summary.new == 1 && walked.summary.gone == 1 && walked.summary.changed == 1 && walked.summary.same == 1,
                   "filing: the pair walk's comparison and the one from its filed snapshots have the same counts (new 1, gone 1, changed 1, same 1)")
            // The walk lists screens in its own order; a snapshot keeps them by id, so they are compared by id.
            func byID(_ c: ChangeSet) -> [String: String] { Dictionary(c.screens.map { ($0.id, $0.status.rawValue) }, uniquingKeysWith: { a, _ in a }) }
            expect(byID(from) == byID(walked) && from.screens.count == walked.screens.count, "filing: the same status for every screen, by id")
            expect(from.crashes.count == 1 && from.crashes.first?.side == .base, "filing: the base's crash is the base's")
            let changed = from.screens.first { $0.status == .changed }
            expect(changed?.diff.map { fm.fileExists(atPath: $0.path) } == true && (changed?.percent ?? 0) > 0, "filing: the changed screen has a difference image and a share of pixels")
        } else {
            expect(false, "filing: the comparison from filed snapshots and the one the walk made were both read")
        }
        let again = History.store(stateRoot: stateRoot, workspace: repo)
        let before = again.commits(profile: pairProfile.id)
        let refiled = { () -> Bool in var r = false; Task { await History.fileFromPair(folder: pairFolder, build: headBuild, side: .head, workspace: ws, profile: pairProfile, stateRoot: stateRoot, engine: "x"); r = true; wait.signal() }; wait.wait(); return r }()
        expect(refiled && again.commits(profile: pairProfile.id) == before, "filing: filing a commit that has a snapshot again changes nothing")

        finish(ok)
    }

    private static func finish(_ ok: Bool) -> Never {
        print("[greenroom] map-history check: \(ok ? "PASS" : "FAIL")")
        exit(ok ? 0 : 1)
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
