import Foundation

/// `Greenroom --walk-defaults-check DIR`: headless, no engine. A walk with nothing chosen covers the whole app (no
/// `--max-depth`, the four-hour ceiling for `--max-seconds`) on more than one device; a chosen depth and time are passed
/// as they are; the crawler's `--events` lines are read (a screen explored, a screen found and never opened, another
/// build's, a line that is no event); a build made with uncommitted changes is not kept in the history until the person
/// accepts it, and the reason is said in words. One `ok|FAIL` line per step, then `walk-defaults check: PASS|FAIL`.
enum WalkDefaultsCheck {
    static func run(dir: URL) -> Never {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) { print("[greenroom] walk-defaults: \(ok ? "ok  " : "FAIL") \(what)"); if !ok { failures += 1 } }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let python = URL(fileURLWithPath: "/usr/bin/python3"), apk = dir.appendingPathComponent("app.apk")
        func args(_ change: (inout CrawlRun.Settings) -> Void) -> [String] {
            var s = CrawlRun.Settings(); s.script = dir.appendingPathComponent("crawl.py"); change(&s)
            return CrawlRun(python: python, apk: apk, out: dir.appendingPathComponent("out-\(UUID().uuidString)"), settings: s).arguments
        }
        func value(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }

        let plain = args { _ in }
        expect(!plain.contains("--max-depth"), "a walk with nothing chosen has no depth limit: the whole app")
        expect(value(plain, "--max-seconds") == String(CrawlRun.ceiling) && CrawlRun.ceiling == 14_400, "... and stops only at the four-hour ceiling (\(value(plain, "--max-seconds") ?? "none"))")
        expect((2...6).contains(CrawlRun.parallel) && value(plain, "-j") == String(CrawlRun.parallel), "... on \(CrawlRun.parallel) devices at once (2 to 6, by the Mac's cores and memory)")
        expect(!plain.contains("--events"), "--events is passed only when asked for")
        let chosen = args { $0.depth = 3; $0.seconds = 300; $0.jobs = 1; $0.events = true; $0.engineOptions = ["--data-slots", "x"] }
        expect(value(chosen, "--max-depth") == "3" && value(chosen, "--max-seconds") == "300" && value(chosen, "-j") == "1", "a chosen depth, time and device count are passed as they are")
        expect(chosen.contains("--events") && (chosen.firstIndex(of: "--events") ?? 0) < (chosen.firstIndex(of: "--") ?? 0), "--events comes before the engine's own options")
        expect(Evidence.Budget().depth == 0 && Evidence.Budget().seconds == 0 && Evidence.Budget().jobs == CrawlRun.parallel, "a build's own walk is the whole app, in parallel")
        expect(MapProfile().depth == 0 && MapProfile().seconds == 0, "the profile with nothing chosen is the whole app's")
        expect(!Workspace(root: dir).quickWalk, "\"Quick Walks Only\" is off for a new repository")

        if case .screen(let id, let title, let depth, let explored) = CrawlRun.parse(#"{"event": "screen", "build": "new", "id": "Main-1", "origin": "walked", "depth": 2, "title": "Trips"}"#) {
            expect(id == "Main-1" && title == "Trips" && depth == 2 && explored, "an explored screen's event is read")
        } else { expect(false, "an explored screen's event is read") }
        if case .screen(_, _, _, let explored) = CrawlRun.parse(#"{"event": "screen", "build": "new", "id": "Main-2", "depth": 3, "title": "", "explored": false}"#) {
            expect(!explored, "a screen found and never opened is told apart")
        } else { expect(false, "a screen found and never opened is told apart") }
        if case .line = CrawlRun.parse(#"{"event": "screen", "build": "base", "id": "Main-1", "depth": 0, "title": "x"}"#) { expect(true, "the base build's screens are not counted as the walk's") }
        else { expect(false, "the base build's screens are not counted as the walk's") }
        if case .line = CrawlRun.parse(#"{"event": "level", "build": "new", "depth": 1, "screens": 3, "known": 4}"#) { expect(true, "other events are left to the human lines") }
        else { expect(false, "other events are left to the human lines") }
        if case .level(let d, let n, let k) = CrawlRun.parse("[new] depth 1: 3 screen(s) to explore, 4 known") { expect(d == 1 && n == 3 && k == 4, "the level line still reads") }
        else { expect(false, "the level line still reads") }

        let sha = String(repeating: "a", count: 40), key = "check-" + UUID().uuidString
        let clean = Build(key: key + "c", apk: apk, source: .local, sha: sha, ref: nil, dirty: false, date: Date())
        let dirty = Build(key: key, apk: apk, source: .local, sha: sha, ref: nil, dirty: true, date: Date())
        let loose = Build(key: key + "f", apk: apk, source: .file, sha: nil, ref: nil, dirty: false, date: Date())
        expect(History.fileable(clean) && History.whyNotFiled(clean) == nil, "a build of a clean commit is kept in the history")
        expect(!History.fileable(dirty) && (History.whyNotFiled(dirty) ?? "").contains("uncommitted changes"), "one made with uncommitted changes is not, and the reason is said")
        expect(!History.fileable(loose) && (History.whyNotFiled(loose) ?? "").contains("no commit"), "nor is an APK with no commit")
        History.accept(key)
        expect(History.fileable(dirty) && History.whyNotFiled(dirty) == nil, "\"Save Map to History Anyway\" makes that one build kept")
        expect(!History.fileable(loose), "... and no other")
        var kept = UserDefaults.standard.stringArray(forKey: "historyAcceptedBuilds") ?? []
        kept.removeAll { $0 == key }
        UserDefaults.standard.set(kept, forKey: "historyAcceptedBuilds")

        print("[greenroom] walk-defaults check: \(failures == 0 ? "PASS" : "FAIL")")
        exit(failures == 0 ? 0 : 1)
    }
}
