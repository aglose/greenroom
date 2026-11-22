import AppKit

extension AppDelegate {
    /// `Greenroom --map-history-live DIR APK`: see HistoryLive.
    func historyLiveIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--map-history-live"), i + 2 < args.count else { return }
        HistoryLive.run(workbench: workbench, dir: URL(fileURLWithPath: args[i + 1]), apk: URL(fileURLWithPath: args[i + 2]))
    }
}

/// `Greenroom --map-history-live DIR APK`: comparisons answered from map history, with the bundled engine and the test app.
/// A repository with a base commit on main (its build stored) and two worktrees one commit ahead, each with a build.
///
///  1. a against the base: no snapshot, so the pair is walked (`crawl.py --base`), and both builds are filed;
///  2. b against the same base: the base has a snapshot, so only b is walked (a `crawl.py` with no `--base`), and the
///     comparison is made from history;
///  3. a against the base again, its comparison folder gone: nothing is walked at all, and the result is the first one's.
///
/// One `[greenroom] history-live: ok|FAIL ...` line per step, then `history-live check: PASS|FAIL`. Made in a fresh subfolder
/// of DIR; the crawler command lines seen while it ran are printed.
enum HistoryLive {
    static func run(workbench wb: Workbench, dir: URL, apk: URL) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            let sessions = wb.sessions, ev = sessions.evidence, sheet = wb.changesSheet
            let base = dir.resolvingSymlinksInPath().appendingPathComponent("history-live", isDirectory: true)
            func say(_ s: String) { fputs("[greenroom] history-live: \(s)\n", stdout); fflush(stdout) }
            func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; say((ok ? "ok " : "FAIL ") + what) }
            @MainActor func wait(_ what: String, _ seconds: Double = 120, _ cond: @MainActor () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
                say("timed out waiting for \(what)")
                return false
            }
            func run(_ exe: String, _ args: [String], in folder: URL? = nil) -> String? {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = folder
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
            }
            func git(_ args: [String], in folder: URL) -> String? {
                run("/usr/bin/git", ["-c", "user.name=Check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false"] + args, in: folder)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            @MainActor func finish() -> Never {
                ev.shutdown()
                print("history-live check: " + (failures == 0 ? "PASS" : "FAIL"))
                fflush(stdout)
                Engine.shared.stopAll()
                exit(failures == 0 ? 0 : 1)
            }

            for old in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != "engine-state" { try? fm.removeItem(at: old) }
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            let repo = base.appendingPathComponent("repo", isDirectory: true)
            try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
            try? "build/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try? "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            guard git(["init", "-q", "-b", "main"], in: repo) != nil, git(["add", "."], in: repo) != nil, git(["commit", "-q", "-m", "first"], in: repo) != nil,
                  let first = git(["rev-parse", "HEAD"], in: repo) else { say("FAIL could not make the repository"); failures += 1; finish() }
            var variants = 0
            func variant() -> URL? {
                variants += 1
                let folder = base.appendingPathComponent("variant\(variants)", isDirectory: true)
                try? fm.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
                try? "build \(variants)\n".write(to: folder.appendingPathComponent("assets/greenroom-check.txt"), atomically: true, encoding: .utf8)
                let out = folder.appendingPathComponent("app.apk")
                guard (try? fm.copyItem(at: apk, to: out)) != nil, run("/usr/bin/zip", ["-q", out.path, "assets/greenroom-check.txt"], in: folder) != nil else { return nil }
                return out
            }
            func worktree(_ n: String) -> URL { base.appendingPathComponent("wt-" + n, isDirectory: true) }
            for n in ["a", "b"] {
                guard git(["worktree", "add", "-q", "-b", "feat-" + n, worktree(n).path], in: repo) != nil else { say("FAIL worktree \(n)"); failures += 1; finish() }
                try? "change \(n)\n".write(to: worktree(n).appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
                _ = git(["commit", "-q", "-am", "change " + n], in: worktree(n))
                let out = worktree(n).appendingPathComponent("app/build/outputs/apk/debug/app-debug.apk")
                try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let v = variant(), (try? fm.copyItem(at: v, to: out)) != nil else { say("FAIL build \(n)"); failures += 1; finish() }
            }
            guard let baseApk = variant() else { say("FAIL base build"); failures += 1; finish() }

            let store = SessionStore(root: base.appendingPathComponent("state", isDirectory: true))
            sessions.use(store: store)
            ev.budget = Evidence.Budget(depth: 1, seconds: 120, jobs: 2)
            guard store.record(apk: baseApk, source: .local, sha: first, ref: "main", dirty: false) != nil else { say("FAIL the base build was not stored"); failures += 1; finish() }
            _ = await sessions.addRepository(worktree("a")).value
            func row(_ n: String) -> Session? { sessions.sessions.first { $0.worktree.lastPathComponent == "wt-" + n } }
            _ = await wait("the rows", 30) { row("a")?.outputs != nil && row("b")?.outputs != nil }
            guard let a = row("a"), let b = row("b") else { say("FAIL the rows are missing"); failures += 1; finish() }
            sessions.setAuto(.off, for: a); sessions.setAuto(.off, for: b)
            expect(ev.started == 0, "nothing is walked by itself")

            // The crawler command lines seen while this runs (this check's state folder only).
            var seen = Set<String>()
            var sampling = true
            Task { @MainActor in
                while sampling {
                    for line in (run("/bin/ps", ["-axo", "command="]) ?? "").split(separator: "\n") where line.contains("scripts/crawl.py") && line.contains(base.path + "/state") {
                        seen.insert(String(line.prefix(400)))
                    }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            func snapshots() -> Int {
                let h = store.root.appendingPathComponent("history", isDirectory: true)
                var n = 0
                for case let f as URL in fm.enumerator(at: h, includingPropertiesForKeys: nil) ?? FileManager.DirectoryEnumerator() where f.pathExtension == "json" && f.path.contains("/snapshots/") { n += 1 }
                return n
            }
            @MainActor func compare(_ s: Session) async -> ChangeSet? {
                sheet.open(session: s, compare: false)
                sheet.compare(base: .ref(first), name: "first commit")
                _ = await wait("the comparison", 300) { sheet.changeSet != nil || sheet.stateTitleText == "Could not compare" }
                return sheet.changeSet
            }

            // 1.
            let s0 = ev.started
            let one = await compare(a)
            expect(one != nil && ev.started == s0 + 1, "a against the base: one run, the pair walked (runs \(ev.started - s0))")
            expect(seen.filter { $0.contains(" --base ") }.count >= 1, "that crawl had --base")
            expect(await wait("both snapshots", 60) { snapshots() == 2 }, "both builds were filed (snapshots: \(snapshots()))")
            let seen1 = seen.count

            // 2.
            let s1 = ev.started
            let two = await compare(b)
            expect(two != nil && ev.started == s1 + 1, "b against the same base: one run (runs \(ev.started - s1))")
            expect(seen.count == seen1 + 1, "that run was one more crawler command (\(seen.count - seen1))")
            expect(seen.filter { !$0.contains(" --base ") }.count == 1, "and it had no --base: only b was walked")
            if let two {
                expect(!fm.fileExists(atPath: two.folder.appendingPathComponent("crawl.json").path) && two.screens.count > 0,
                       "its result is made from history (no crawl.json in its folder): \(two.screens.count) screens, changed \(two.summary.changed) new \(two.summary.new) gone \(two.summary.gone) same \(two.summary.same)")
            }
            expect(await wait("b's snapshot", 60) { snapshots() == 3 }, "b was filed (snapshots: \(snapshots()))")

            // 3.
            if let one { try? fm.removeItem(at: one.folder) }
            let s2 = ev.started, seen2 = seen.count
            let three = await compare(a)
            expect(three != nil && ev.started == s2 && seen.count == seen2, "a against the base again, its folder gone: no run, no crawler (runs \(ev.started - s2))")
            if let one, let three { expect(three.summary == one.summary, "and the same counts as the walk's (changed \(three.summary.changed) new \(three.summary.new) gone \(three.summary.gone) same \(three.summary.same))") }

            sampling = false
            say("crawler commands seen:")
            for line in seen.sorted() { say("  " + line.replacingOccurrences(of: base.path, with: "<dir>")) }
            finish()
        }
    }
}
