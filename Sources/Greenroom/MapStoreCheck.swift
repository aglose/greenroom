import CoreGraphics
import Foundation
import ImageIO

/// `Greenroom --map-store-check DIR`: the history store against small walks written into DIR. Headless; prints
/// `[greenroom] map-store: ok|FAIL <what>` and a last PASS or FAIL line.
enum MapStoreCheck {
    /// A walk folder: `crawl.json` and one tiny PNG per screen, each colored by its number in `colors`.
    private static func writeWalk(_ folder: URL, colors: [Int]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder.appendingPathComponent("screens"), withIntermediateDirectories: true)
        var screens: [[String: Any]] = [], edges: [[String: Any]] = []
        for (i, c) in colors.enumerated() {
            png(folder.appendingPathComponent("screens/s\(i)-light.png"), color: c)
            screens.append(["id": "Main\(i)Activity-0000000\(i)", "activity": "com.example.Main\(i)Activity", "title": "Screen \(i)", "depth": i == 0 ? 0 : 1,
                            "parent": i == 0 ? NSNull() : "Main0Activity-00000000", "path": ["steps": i == 0 ? [] : ["tap \(i)"]],
                            "captures": ["light": "screens/s\(i)-light.png"], "texts": ["Hello \(i)"], "settled": true])
            if i > 0 {
                edges.append(["from": "Main0Activity-00000000", "action": "Open \(i)", "cmd": "tap \(i)", "to": "Main\(i)Activity-0000000\(i)"])
            }
        }
        edges.append(["from": "Main0Activity-00000000", "action": "Leave", "cmd": "back", "to": "EXIT"])
        edges.append(["from": "Main0Activity-00000000", "action": "Later", "cmd": "tap 99"])
        let json: [String: Any] = ["apk": "a.apk", "combos": ["light"], "screens": screens, "edges": edges, "findings": [], "incomplete": [], "seconds": ["total": 12.5]]
        try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: folder.appendingPathComponent("crawl.json"))
    }

    private static func png(_ url: URL, color: Int) {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(color % 7) / 7, green: CGFloat(color / 7 % 7) / 7, blue: CGFloat(color) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Every file under `folder` with its modification date.
    private static func dates(_ folder: URL) -> [String: Date] {
        var out: [String: Date] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        for case let u as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys)! {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isRegularFile == true { out[u.path] = v?.contentModificationDate }
        }
        return out
    }

    static func run(dir: URL) -> Never {
        var ok = true
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; print("[greenroom] map-store: \(good ? "ok  " : "FAIL") \(what)") }
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let walkA = dir.appendingPathComponent("walk-a"), walkB = dir.appendingPathComponent("walk-b")
        writeWalk(walkA, colors: [1, 2, 3, 4, 5, 6, 7])
        writeWalk(walkB, colors: [1, 2, 3, 4, 5, 6, 8])     // 6 captures shared with A, one new
        let store = MapStore(root: dir.appendingPathComponent("state"), repo: "repo")
        let profile = MapProfile()
        let when = Date(timeIntervalSince1970: 1_700_000_000)

        guard var a = store.importWalk(walkA, commit: "aaaa111", tree: "tree1", profile: profile, engine: "e1", walked: when),
              let b = store.importWalk(walkB, commit: "bbbb222", tree: "tree2", profile: profile, engine: "e1", walked: when) else {
            expect(false, "a walk folder imports")
            print("[greenroom] map-store check: FAIL"); exit(1)
        }
        expect(a.screens.count == 7 && a.screens.allSatisfy { $0.captures.count == 1 && $0.lineage.isEmpty },
               "import: 7 screens with a capture each, no lineages")
        let main0 = a.edges.filter { $0.from == "Main0Activity-00000000" }
        expect(main0.map(\.order) == Array(0..<main0.count) && main0.last?.to == nil && main0.contains { $0.to == "EXIT" },
               "import: edges keep their order, EXIT stays raw, an unfollowed control has no target")
        let blobs = store.folder.appendingPathComponent("blobs")
        func blobCount() -> Int { ((try? fm.contentsOfDirectory(atPath: blobs.path)) ?? []).filter { $0.hasSuffix(".png") }.count }
        expect(blobCount() == 8, "two walks of 7 screens sharing 6 captures store 8 blobs (\(blobCount()))")

        // Saving, then everything again: nothing may be written the second time.
        for i in a.screens.indices { a.screens[i].lineage = a.screens[i].id + "@aaaa111" }
        expect(store.save(a) && store.save(b), "save: both snapshots are kept")
        let before = dates(store.folder)
        Thread.sleep(forTimeInterval: 0.05)
        let again = store.importWalk(walkA, commit: "aaaa111", tree: "tree1", profile: profile, engine: "e1", walked: when)
        store.save(a)
        let after = dates(store.folder)
        expect(again != nil && before == after && !before.isEmpty, "importing one walk twice writes nothing the second time (\(before.count) files, none touched)")

        let back = store.snapshot(profile: profile.id, commit: "aaaa111")
        let file = store.folder.appendingPathComponent("snapshots/\(profile.id)/aaaa111.json")
        expect(back == a.canonical() && back?.data() == a.data() && (try? Data(contentsOf: file)) == a.data(), "a snapshot read back equals the one written, byte for byte")
        expect(store.commits(profile: profile.id) == ["aaaa111", "bbbb222"] && store.commits(profile: "ffffffff").isEmpty, "the commits with a snapshot are listed")

        // The same tree under another commit finds the snapshot already there.
        var twin = a
        twin.commit = "cccc333"
        store.save(twin)
        let byTree = store.snapshot(profile: profile.id, tree: "tree1")
        expect(byTree?.commit == "aaaa111" && store.snapshot(profile: profile.id, tree: "tree2")?.commit == "bbbb222" && store.snapshot(profile: profile.id, tree: "nope") == nil,
               "lookup by tree finds a snapshot filed under another commit with the same tree")
        expect(store.blobURL(a.screens[0].captures.values.first!) != nil && store.blobURL(String(repeating: "0", count: 64)) == nil, "blobURL finds a stored capture and no other")

        let perms = (try? fm.attributesOfItem(atPath: blobs.path)[.posixPermissions] as? Int) ?? 0
        expect(perms == 0o700, "folders are private (\(String(perms, radix: 8)))")

        // Prune to A: B's one capture of its own goes, the six it shared stay.
        let removed = store.prune(keep: [(profile.id, "aaaa111"), (profile.id, "cccc333")])
        let wanted = Set(a.screens.flatMap { $0.captures.values })
        let left = Set(((try? fm.contentsOfDirectory(atPath: blobs.path)) ?? []).map { String($0.dropLast(4)) })
        expect(removed.snapshots == 1 && removed.blobs == 1 && left == wanted, "prune removes exactly the unreferenced blobs (\(removed.blobs) of 8, \(left.count) left)")
        expect(store.snapshot(profile: profile.id, tree: "tree2") == nil && store.snapshot(profile: profile.id, tree: "tree1") != nil, "prune drops the tree entry of a removed snapshot")

        // Many queues at once.
        let group = DispatchGroup()
        for i in 0..<8 {
            DispatchQueue.global().async(group: group) {
                _ = store.importWalk(i % 2 == 0 ? walkA : walkB, commit: "dddd\(i)", tree: "tree\(i % 2 + 1)", profile: profile, engine: "e1", walked: when)
            }
        }
        group.wait()
        expect(blobCount() == 8, "imports from several queues at once keep one blob each")

        print("[greenroom] map-store check: \(ok ? "PASS" : "FAIL")")
        exit(ok ? 0 : 1)
    }
}
