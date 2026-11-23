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

            // The store on its own: files from before a field existed still read, an unreadable one is kept aside,
            // a build is filed whole and at once from several places, and old builds are pruned.
            do {
                let t = SessionStore(root: base.appendingPathComponent("state-store", isDirectory: true))
                try? fm.createDirectory(at: t.workspacesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(#"[{"root":"file:///tmp/old-repo/"}]"#.utf8).write(to: t.workspacesFile)
                let old = t.loadWorkspaces()
                expect(old.count == 1 && old[0].variant == "debug" && old[0].baseRef == "origin/main" && old[0].auto == .onBuild,
                       "a workspaces.json written before the other fields existed still reads")
                try? Data("not json".utf8).write(to: t.workspacesFile)
                expect(t.loadWorkspaces().isEmpty && fm.fileExists(atPath: t.workspacesFile.path + ".bad") && !fm.fileExists(atPath: t.workspacesFile.path),
                       "an unreadable workspaces.json is moved aside to .bad, not taken for empty")
                let older = try? JSONDecoder().decode(Build.self, from: Data(#"{"key":"0123456789abcdef","apk":"file:///x/app.apk"}"#.utf8))
                expect(older?.source == .file && older?.dirty == false, "a build.json with only its key and apk still reads")

                let key = SessionStore.key(of: apk) ?? "none"
                let partial = t.folder(of: key)
                try? fm.createDirectory(at: partial, withIntermediateDirectories: true)
                try? Data("partial".utf8).write(to: partial.appendingPathComponent("app.apk"))   // what a copy that died would leave
                let size = (try? apk.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                var results = [Build?](repeating: nil, count: 8)
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: results.count) { i in
                    let b = t.record(apk: apk, source: .local, sha: nil, ref: nil, dirty: false)
                    lock.lock(); results[i] = b; lock.unlock()
                }
                let files = (try? fm.contentsOfDirectory(atPath: partial.path)) ?? []
                expect(results.allSatisfy { $0 != nil } && (try? partial.appendingPathComponent("app.apk").resourceValues(forKeys: [.fileSizeKey]).fileSize) == size
                       && Set(files) == ["app.apk", "build.json"],
                       "eight concurrent records of one APK all succeed, replace a partial app.apk and leave nothing behind (\(files.sorted().joined(separator: ",")))")
                var keys: [String] = []
                for n in 0..<5 {
                    let f = base.appendingPathComponent("distinct\(n).apk")
                    try? Data("build \(n)".utf8).write(to: f)
                    if let b = t.record(apk: f, source: .local, sha: nil, ref: nil, dirty: false) { keys.append(b.key); t.note(build: b.key, of: "/w/live") }
                    if let b = t.record(apk: f, source: .local, sha: nil, ref: nil, dirty: false), n < 2 { t.note(build: b.key, of: "/w/gone") }
                }
                t.prune(live: ["/w/live"])
                let left = (try? fm.contentsOfDirectory(atPath: t.builds.path)) ?? []
                expect(t.history(of: "/w/live") == Array(keys.suffix(3).reversed()) && !left.contains(keys[0]) && !left.contains(keys[1])
                       && keys.suffix(3).allSatisfy(left.contains) && left.contains(key) && t.history(of: "/w/gone").isEmpty,
                       "pruning keeps a worktree's last 3 builds, drops those of a worktree that is gone, leaves unlisted ones (\(left.count) folders)")
            }

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
            // An .apk that is not Gradle's output (an intermediate, a fixture) is not a build, however new.
            let intermediate = worktree("a").appendingPathComponent("app/build/intermediates/x.apk")
            let fixture = worktree("a").appendingPathComponent("fixtures/y.apk")
            for f in [intermediate, fixture] { try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true); _ = place(f) }
            expect(SessionStore.newestAPK(in: worktree("a"))?.apk.lastPathComponent == "app-debug.apk"
                   && !SessionStore.isBuildOutput(intermediate, in: worktree("a")) && !SessionStore.isBuildOutput(fixture, in: worktree("a"))
                   && SessionStore.isBuildOutput(apkPath("a"), in: worktree("a")),
                   "only build/outputs/apk counts: an intermediate and a fixture APK are not builds")
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
            guard await wait("b's first frame", 180, { ready(sessions.simulator(for: b)) }), var simB = sessions.simulator(for: b) else { failures += 1; finish() }
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
            for f in slotFolders(b.slot) { try? "kept".write(to: f.appendingPathComponent(marker + "-b"), atomically: true, encoding: .utf8) }
            func hasMarkerB() -> Bool { slotFolders(b.slot).contains { fm.fileExists(atPath: $0.appendingPathComponent(marker + "-b").path) } }

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

            // 4b. The same rebuild with the developer hooks watching the folder too: one reload, no second simulator.
            var reloads = 0
            sessions.onReload = { _, _ in reloads += 1 }
            DevHooks.shared.watch(folder: apkPath("b").deletingLastPathComponent(), name: "app-debug.apk")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try? fm.removeItem(at: apkPath("b"))
            _ = place(apkPath("b"))
            guard await wait("b's reload", 120, { let now = sessions.simulator(for: b); return now != nil && now !== simB && ready(now) }), let reloadedB = sessions.simulator(for: b) else {
                failures += 1; say("FAIL b's simulator did not reload"); finish()
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)   // long enough for a second relaunch to show
            let bSims = Engine.shared.simulators.filter { $0.isAlive && SessionsController.slot(of: $0) == b.slot }
            expect(reloads == 1 && bSims.count == 1 && bSims.first === reloadedB && Engine.shared.simulators.count == 2,
                   "with a build folder watched too, one rebuild reloaded b once (\(reloads) reload, \(bSims.count) simulator on its slot, \(Engine.shared.simulators.count) on stage: \(Engine.shared.simulators.map { "\(SessionsController.slot(of: $0) ?? "?") \($0.state)" }.joined(separator: "; ")))")
            expect(sessions.simulator(for: a) === reloaded && ready(reloaded), "a's simulator, which runs a file of the same name, was not reloaded by it")
            DevHooks.shared.stopWatch()
            simB = reloadedB

            // 5. Worktrees made while the app is open appear by themselves (the repository is watched).
            expect(makeWorktree("c") && makeWorktree("d"), "two more worktrees made with git")
            let appeared = await wait("the watcher to list c and d", 20) { row("c") != nil && row("d") != nil }
            expect(appeared, "worktrees c and d listed without asking (FSEvents on .git)")
            if !appeared { sessions.refresh() }
            _ = await wait("c's and d's builds", 30) { row("c")?.outputs != nil && row("d")?.outputs != nil }
            if row("c")?.outputs == nil { sessions.refresh(); _ = await wait("c's and d's builds", 30) { row("c")?.outputs != nil && row("d")?.outputs != nil } }

            // 5b. A click on a session whose build was deleted (gradle clean) builds it, to open when it lands: nothing
            // opens now. (This repository has no Gradle, so the build fails, and nothing opens later either.)
            guard let d0 = row("d") else { say("FAIL d missing"); failures += 1; finish() }
            try? fm.removeItem(at: apkPath("d"))
            let before = Engine.shared.simulators.count
            let took = sessions.activate(d0)
            expect(took && sessions.buildQueue.job(for: d0) != nil && Engine.shared.simulators.count == before && sessions.simulator(for: d0) == nil,
                   "a click on a session whose APK was deleted starts its build, not a simulator")
            sessions.cancelBuild(d0)
            _ = await wait("d's build to end", 60) { !(sessions.buildQueue.job(for: d0)?.isActive ?? false) }
            expect(!sessions.openWhenBuilt.contains(d0.worktree.path), "a build that ended without an APK opens nothing later")
            _ = place(apkPath("d"))
            sessions.refresh()
            _ = await wait("d's build again", 30) { row("d")?.outputs != nil }

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

            // 7. A click on b at once, while its quit simulator may still hold the slot: it waits for the exit, so the
            // new one has the same data (no second slot), and with b's output deleted it starts from the stored build.
            try? fm.removeItem(at: apkPath("b"))
            _ = sessions.activate(b)
            _ = sessions.activate(b)   // a second click meanwhile must not start a second one
            guard await wait("b's restart", 180, { ready(sessions.simulator(for: b)) }), let again = sessions.simulator(for: b) else { failures += 1; finish() }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            expect(slotFolders(b.slot).count == 1 && hasMarkerB() && Engine.shared.simulators.filter { SessionsController.slot(of: $0) == b.slot }.count == 1,
                   "b restarted at once has its own data back: \(slotFolders(b.slot).map(\.lastPathComponent).joined(separator: ",")), one simulator")
            expect(again.apk.lastPathComponent == "app.apk" && Engine.shared.simulators.count == 3, "b started from the stored build, as its output was gone; the limit still holds (\(Engine.shared.simulators.count))")

            // Clean up what the check made in the engine's state.
            for s in [a, b, c, d] { for f in slotFolders(s.slot) { try? fm.removeItem(at: f) } }
            finish()
        }
    }
}
