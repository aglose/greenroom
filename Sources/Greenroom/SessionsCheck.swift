import AppKit

/// `Greenroom --sessions-check DIR APK`: a temporary git repository with worktrees whose "builds" are copies of APK,
/// added to Sessions and driven as a person would: rows listed, a click switches simulators, each worktree has its
/// own data slot, a replaced APK reloads only its own simulator and keeps its data, and one more session than may
/// stay warm quits the least recently used. One `[greenroom] sessions: ok|FAIL ...` line per step, then
/// `sessions check: PASS|FAIL`; exits 0 or 1. Nothing of the person's is touched: the store is DIR's own, and the
/// engine's data folders of the check's slots are removed at the end.
enum SessionsCheck {
    static func run(workbench wb: Workbench, dir: URL, apk: URL) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            let sessions = wb.sessions

            func say(_ s: String) { fputs("[greenroom] sessions: \(s)\n", stdout); fflush(stdout) }
            func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; say((ok ? "ok " : "FAIL ") + what) }
            @MainActor func wait(_ what: String, _ seconds: Double = 120, _ cond: @MainActor () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 200_000_000) }
                say("timed out waiting for \(what)")
                return false
            }
            func ready(_ s: Simulator?) -> Bool { s?.state == .running && (s?.framesShown ?? 0) > 0 }
            @MainActor func finish() -> Never {
                say(failures == 0 ? "done" : "stopped with \(failures) failure(s)")
                print("sessions check: " + (failures == 0 ? "PASS" : "FAIL"))
                fflush(stdout)
                Engine.shared.stopAll()
                exit(failures == 0 ? 0 : 1)
            }
            func git(_ args: [String], in folder: URL) -> Bool {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-c", "user.name=Check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false"] + args
                p.currentDirectoryURL = folder
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return false }
                p.waitUntilExit()
                return p.terminationStatus == 0
            }

            // The repository: a main checkout and worktrees a and b (c and d come later, while it is open).
            let base = dir.resolvingSymlinksInPath()
            try? fm.removeItem(at: base)
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            let repo = base.appendingPathComponent("repo", isDirectory: true)
            try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
            try? "build/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try? "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            guard git(["init", "-q", "-b", "main"], in: repo), git(["add", "."], in: repo), git(["commit", "-q", "-m", "first"], in: repo) else {
                say("FAIL could not make the repository (is /usr/bin/git there?)"); failures += 1; finish()
            }
            func worktree(_ name: String) -> URL { base.appendingPathComponent("wt-" + name, isDirectory: true) }
            func apkPath(_ name: String) -> URL { worktree(name).appendingPathComponent("app/build/outputs/apk/debug/app-debug.apk") }
            func makeWorktree(_ name: String) -> Bool {
                guard git(["worktree", "add", "-q", "-b", "feat-" + name, worktree(name).path], in: repo) else { return false }
                try? fm.createDirectory(at: apkPath(name).deletingLastPathComponent(), withIntermediateDirectories: true)
                return place(apkPath(name))
            }
            /// A build as Gradle leaves it: the file is new, whatever the copied one's time was.
            func place(_ file: URL) -> Bool {
                guard (try? fm.copyItem(at: apk, to: file)) != nil else { return false }
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return true
            }
            guard makeWorktree("a"), makeWorktree("b") else { say("FAIL could not make the worktrees"); failures += 1; finish() }

            let store = SessionStore(root: base.appendingPathComponent("state", isDirectory: true))
            sessions.use(store: store)

            // 1. Adding: by one of the worktrees, as a person might drop whichever folder they have.
            let added = await sessions.addRepository(worktree("a")).value
            expect(added == repo.resolvingSymlinksInPath(), "a worktree dropped on the sidebar adds its repository's main checkout")
            func row(_ name: String) -> Session? { sessions.sessions.first { $0.worktree.lastPathComponent == "wt-" + name } }
            _ = await wait("the rows", 30) { row("a") != nil && row("b") != nil && row("a")?.outputs != nil && row("b")?.outputs != nil }
            let main = sessions.sessions.first { $0.isMain }
            expect(sessions.sessions.count == 3 && row("a")?.branch == "feat-a" && row("b")?.branch == "feat-b" && main?.branch == "main",
                   "rows listed: \(sessions.sessions.map { "\($0.branch ?? "?") \($0.shortHead)" }.joined(separator: ", "))")
            expect(main?.outputs == nil && row("a")?.outputs != nil && row("a")?.isStale == false && row("a")?.dirty == false,
                   "the main checkout has no build, a has one and it is not stale, a is clean (main outputs \(main?.outputs?.apk.path ?? "none"), a stale \(row("a")?.isStale ?? true), a dirty \(row("a")?.dirty ?? true))")
            expect(store.loadWorkspaces().map(\.root) == [repo.resolvingSymlinksInPath()], "the workspace is stored in workspaces.json")
            if let a = row("a") {
                let mergeBase = await Git.mergeBase("feat-a", "main", in: repo)
                expect(mergeBase == main?.head, "merge base of feat-a and main is main's head")
                _ = a
            }

            // 2. A click starts the session's simulator from its newest build, in its own data slot.
            guard let a = row("a"), let b = row("b") else { say("FAIL rows missing"); failures += 1; finish() }
            expect(a.slot != b.slot && a.slot.hasPrefix("gr") && a.slot.count == 10, "each worktree has its own data slot (\(a.slot), \(b.slot))")
            expect(sessions.activate(a), "click a")
            guard await wait("a's first frame", 180, { ready(sessions.simulator(for: a)) }), let simA = sessions.simulator(for: a) else { failures += 1; finish() }
            expect(wb.selected === simA && SessionsController.slot(of: simA) == a.slot, "a's simulator is selected and runs with --data-slots \(a.slot)")
            expect(sessions.activate(b), "click b")
            guard await wait("b's first frame", 180, { ready(sessions.simulator(for: b)) }), let simB = sessions.simulator(for: b) else { failures += 1; finish() }
            expect(wb.selected === simB && SessionsController.slot(of: simB) == b.slot && simA !== simB, "b has a simulator of its own, selected, with --data-slots \(b.slot) (selected is b: \(wb.selected === simB), is a: \(wb.selected === simA), slot \(SessionsController.slot(of: simB) ?? "none"))")
            _ = sessions.activate(a)
            expect(wb.selected === simA && sessions.simulator(for: a) === simA && Engine.shared.simulators.count == 2, "a click on a started session only selects it (no new simulator) (selected is a: \(wb.selected === simA), same sim: \(sessions.simulator(for: a) === simA), count \(Engine.shared.simulators.count): \(Engine.shared.simulators.map { "\(SessionsController.slot(of: $0) ?? "?") \($0.state) \($0 === simA ? "simA" : $0 === simB ? "simB" : "other")" }.joined(separator: "; ")))")
            let builds = (try? fm.contentsOfDirectory(atPath: store.builds.path)) ?? []
            let stored = builds.first.flatMap { store.build($0) }
            expect(builds.count == 1 && builds[0].count == 16 && stored?.apk.lastPathComponent == "app.apk" && fm.fileExists(atPath: stored?.apk.path ?? ""),
                   "both builds are one file in builds/<key>/app.apk (\(builds.first ?? "none"))")

            // 3. Data: each slot has its own folder in the engine's state; a marker in a's must survive a's reload.
            let data = Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true)
            func slotFolders(_ slot: String) -> [URL] {
                ((try? fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []).flatMap { pkg in
                    ((try? fm.contentsOfDirectory(at: pkg, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(slot + "-") && !$0.lastPathComponent.hasSuffix(".device") }
                }
            }
            _ = await wait("the data slot folders", 60) { !slotFolders(a.slot).isEmpty && !slotFolders(b.slot).isEmpty }
            expect(!slotFolders(a.slot).isEmpty && !slotFolders(b.slot).isEmpty, "each simulator has its own data folder in the engine's state")
            let marker = "greenroom-sessions-check"
            for f in slotFolders(a.slot) { try? "kept".write(to: f.appendingPathComponent(marker), atomically: true, encoding: .utf8) }
            func hasMarker(_ slot: String) -> Bool { slotFolders(slot).contains { fm.fileExists(atPath: $0.appendingPathComponent(marker).path) } }
            expect(hasMarker(a.slot) && !hasMarker(b.slot), "a marker written to a's data is not in b's")

            // 4. A rebuilt APK in a's outputs reloads a's simulator in place and no other.
            let optionsBefore = simA.options
            try? fm.removeItem(at: apkPath("a"))
            _ = place(apkPath("a"))
            let t0 = Date()
            guard await wait("a's reload", 120, { let now = sessions.simulator(for: a); return now != nil && now !== simA && ready(now) }), let reloaded = sessions.simulator(for: a) else {
                failures += 1; say("FAIL a's simulator did not reload"); finish()
            }
            expect(true, "a reloaded after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            expect(sessions.simulator(for: b) === simB && simB.isAlive && ready(simB), "b's simulator was left alone")
            expect(reloaded.options == optionsBefore && !simA.isAlive && wb.selected === reloaded && Engine.shared.simulators.count == 2,
                   "a's options kept, the old one ended, the new one selected, \(Engine.shared.simulators.count) simulators")
            expect(hasMarker(a.slot) && !hasMarker(b.slot), "a's data survived the reload and b's is still separate")

            // 5. Worktrees made while the app is open appear by themselves (the repository is watched).
            expect(makeWorktree("c") && makeWorktree("d"), "two more worktrees made with git")
            let appeared = await wait("the watcher to list c and d", 20) { row("c") != nil && row("d") != nil }
            expect(appeared, "worktrees c and d listed without asking (FSEvents on .git)")
            if !appeared { sessions.refresh() }
            _ = await wait("c's and d's builds", 30) { row("c")?.outputs != nil && row("d")?.outputs != nil }
            if row("c")?.outputs == nil { sessions.refresh(); _ = await wait("c's and d's builds", 30) { row("c")?.outputs != nil && row("d")?.outputs != nil } }

            // 6. The third and fourth sessions: three stay warm, the least recently used (b) quits.
            guard let c = row("c"), let d = row("d") else { say("FAIL c or d missing"); failures += 1; finish() }
            expect(sessions.warmLimit == 3, "three sessions stay warm")
            _ = sessions.activate(c)
            guard await wait("c's first frame", 180, { ready(sessions.simulator(for: c)) }) else { failures += 1; finish() }
            expect(Engine.shared.simulators.count == 3, "three simulators with c")
            _ = sessions.activate(d)
            guard await wait("d's first frame", 180, { ready(sessions.simulator(for: d)) }) else { failures += 1; finish() }
            _ = await wait("b to quit", 30) { sessions.simulator(for: b) == nil }
            expect(sessions.simulator(for: b) == nil && !simB.isAlive, "the fourth session quit the least recently used (b)")
            expect(sessions.simulator(for: a) != nil && sessions.simulator(for: c) != nil && sessions.simulator(for: d) != nil && Engine.shared.simulators.count == 3,
                   "a, c and d stay, \(Engine.shared.simulators.count) simulators on stage")
            expect(!slotFolders(b.slot).isEmpty, "b's data is kept after its simulator quit")

            // Clean up what the check made in the engine's state.
            for s in [a, b, c, d] { for f in slotFolders(s.slot) { try? fm.removeItem(at: f) } }
            finish()
        }
    }
}
