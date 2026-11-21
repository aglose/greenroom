import AppKit

extension AppDelegate {
    /// `Greenroom --evidence-check DIR APK`: see EvidenceCheck.
    func evidenceCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--evidence-check"), i + 2 < args.count else { return }
        EvidenceCheck.run(workbench: workbench, dir: URL(fileURLWithPath: args[i + 1]), apk: URL(fileURLWithPath: args[i + 2]))
    }
}

/// `Greenroom --evidence-check DIR APK`: a temporary git repository with two worktrees whose "builds" are copies of
/// APK (each a different file: a marker entry added to the zip), added to Sessions and left alone: a session's first
/// activation must start a walk nobody asked for, which ends with a crawl.json and captures under
/// `evidence/<key>/map`; the same build is not walked twice; a new build cancels a running walk and walks the new
/// one; only one walk runs at a time; `auto` off walks nothing; a marker written into the session's data before a
/// walk is unchanged after it (the walk worked on a copy, which is gone afterwards); `changes(head:base:)` of a
/// build against itself finds no differing screen; pruning a build removes its evidence; the size cap removes the
/// oldest first. Budgets for the check: depth 1, 60 s. One `[greenroom] evidence: ok|FAIL ...` line per step, then
/// `evidence check: PASS|FAIL`. Everything is made in a fresh subfolder of DIR (`evidence-check`); DIR itself is
/// never deleted, and the engine's data folders of the check's slots are removed at the end.
enum EvidenceCheck {
    static func run(workbench wb: Workbench, dir: URL, apk: URL) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            let sessions = wb.sessions
            let ev = sessions.evidence

            func say(_ s: String) { fputs("[greenroom] evidence: \(s)\n", stdout); fflush(stdout) }
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
            func git(_ args: [String], in folder: URL) -> Bool {
                run("/usr/bin/git", ["-c", "user.name=Check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false"] + args, in: folder) != nil
            }
            let base = dir.resolvingSymlinksInPath().appendingPathComponent("evidence-check", isDirectory: true)
            var sampling = true
            var maxCrawlers = 0
            var maxWalking = 0
            @MainActor func finish() -> Never {
                sampling = false
                ev.shutdown()
                say(failures == 0 ? "done" : "stopped with \(failures) failure(s)")
                print("evidence check: " + (failures == 0 ? "PASS" : "FAIL"))
                fflush(stdout)
                Engine.shared.stopAll()
                exit(failures == 0 ? 0 : 1)
            }

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

            /// A build that differs from every other: the APK with one more entry in the zip.
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
            /// A build as Gradle leaves it: the file is new.
            func place(_ name: String, _ file: URL) -> String? {
                let target = apkPath(name)
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temp = target.deletingLastPathComponent().appendingPathComponent("app-debug.apk.tmp")
                try? fm.removeItem(at: temp)
                guard (try? fm.copyItem(at: file, to: temp)) != nil else { return nil }
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: temp.path)
                try? fm.removeItem(at: target)
                guard (try? fm.moveItem(at: temp, to: target)) != nil else { return nil }
                return SessionStore.key(of: target)
            }
            guard git(["worktree", "add", "-q", "-b", "feat-a", worktree("a").path], in: repo),
                  git(["worktree", "add", "-q", "-b", "feat-b", worktree("b").path], in: repo),
                  let va = variant(), let vb = variant(), let keyA = place("a", va), let keyB = place("b", vb), keyA != keyB else {
                say("FAIL could not make the worktrees and their builds"); failures += 1; finish()
            }

            let store = SessionStore(root: base.appendingPathComponent("state", isDirectory: true))
            sessions.use(store: store)
            ev.budget = Evidence.Budget(depth: 1, seconds: 60, jobs: 2)
            let data = Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true)
            func slotFolders(_ slot: String) -> [URL] {
                ((try? fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []).flatMap { pkg in
                    ((try? fm.contentsOfDirectory(at: pkg, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(slot + "-") && !$0.lastPathComponent.hasSuffix(".device") }
                }
            }
            func clones() -> [URL] {
                ((try? fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []).flatMap { pkg in
                    ((try? fm.contentsOfDirectory(at: pkg, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix("evg") && !$0.lastPathComponent.hasSuffix(".device") }
                }
            }
            func mapDir(_ key: String) -> URL { store.root.appendingPathComponent("evidence/\(key)/map") }
            func hasMap(_ key: String) -> Bool { fm.fileExists(atPath: mapDir(key).appendingPathComponent("crawl.json").path) }
            func captures(_ key: String) -> Int {
                let walk = fm.enumerator(at: mapDir(key).appendingPathComponent("screens"), includingPropertiesForKeys: nil)
                var n = 0
                while let f = walk?.nextObject() as? URL { if f.pathExtension == "png" { n += 1 } }
                return n
            }
            func isDone(_ path: String, _ key: String) -> Bool {
                if case .done? = ev.entry(of: path)?.status, ev.entry(of: path)?.key == key { return true }
                return false
            }

            /// Running crawl.py processes of this check (the system's python3 is a shim that starts the real one, so
            /// a process whose parent is also one counts as that parent's).
            func crawlers() -> Int {
                guard let list = run("/bin/ps", ["-axo", "pid=,ppid=,command="]) else { return 0 }
                var mine: [(pid: Int, ppid: Int)] = []
                for line in list.split(separator: "\n") where line.contains("scripts/crawl.py") && line.contains("evidence-check/state") {
                    let f = line.split(separator: " ", omittingEmptySubsequences: true)
                    if f.count > 2, let pid = Int(f[0]), let ppid = Int(f[1]) { mine.append((pid, ppid)) }
                }
                return mine.filter { m in !mine.contains { $0.pid == m.ppid } }.count
            }

            // Whatever happens, one walk at a time: sample the crawler processes and the rows while the check runs.
            Task { @MainActor in
                while sampling {
                    maxCrawlers = max(maxCrawlers, crawlers())
                    let walking = sessions.sessions.filter { if case .walking? = ev.entry(of: $0.worktree.path)?.status { return true } else { return false } }.count
                    maxWalking = max(maxWalking, walking)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }

            let added = await sessions.addRepository(worktree("a")).value
            expect(added == repo.resolvingSymlinksInPath(), "the repository is added")
            func row(_ name: String) -> Session? { sessions.sessions.first { $0.worktree.lastPathComponent == "wt-" + name } }
            _ = await wait("the rows", 30) { row("a")?.outputs != nil && row("b")?.outputs != nil }
            guard let a = row("a"), let b = row("b") else { say("FAIL rows missing"); failures += 1; finish() }
            expect(sessions.auto(of: a) == .onBuild, "a workspace walks on build by default")
            expect(ev.entry(of: a.worktree.path) == nil && ev.started == 0, "nothing is walked before a session is used")

            // 1. First activations: nobody asks for a walk. a's starts, b's waits behind it.
            expect(sessions.activate(a), "first activation of a")
            expect(sessions.activate(b), "first activation of b")
            let began = await wait("a's walk to start", 60) { ev.started >= 1 && ev.entry(of: a.worktree.path) != nil }
            expect(began, "a walk started by itself on a's first activation")
            _ = await wait("b's row", 30) { ev.entry(of: b.worktree.path) != nil }
            let bStatus = ev.entry(of: b.worktree.path)?.status
            let aStatus = ev.entry(of: a.worktree.path)?.status
            expect(bStatus == .queued && ev.runningOwner == a.worktree.path, "b's walk waits while a's runs (a \(String(describing: aStatus)), b \(String(describing: bStatus)))")
            let aDone = await wait("a's walk", 240) { isDone(a.worktree.path, keyA) }
            expect(aDone && hasMap(keyA), "a's walk ends with evidence/<key>/map/crawl.json")
            let nCaptures = captures(keyA)
            expect(nCaptures > 0, "the walk's captures are there (\(nCaptures) screens captured)")
            if case .done(let n, _)? = ev.entry(of: a.worktree.path)?.status { expect(n >= 3, "the row says N screens (\(n))") }
            expect(!fm.fileExists(atPath: mapDir(keyA).deletingLastPathComponent().appendingPathComponent("map.part").path), "no half-made map is left")
            let bDone = await wait("b's walk", 240) { isDone(b.worktree.path, keyB) }
            expect(bDone && hasMap(keyB), "b's walk follows and ends with its own map")
            expect(ev.started == 2, "two builds, two walks (\(ev.started))")
            expect(clones().isEmpty, "no clone of a data slot is left behind")

            // 2. The same build is not walked again, however it arrives.
            _ = place("a", va)
            if let build = store.build(keyA) { ev.buildArrived(worktree: a.worktree.path, build: build, auto: .onBuild) }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            expect(ev.started == 2 && isDone(a.worktree.path, keyA), "a build with a map is not walked again (\(ev.started) walks)")

            // 3. A marker in the session's data is unchanged by a walk, which ran on a copy of it.
            _ = await wait("a's data slot", 60) { !slotFolders(a.slot).isEmpty }
            let marker = "evidence-check-marker.txt"
            for f in slotFolders(a.slot) { try? "kept".write(to: f.appendingPathComponent(marker), atomically: true, encoding: .utf8) }
            let before = slotFolders(a.slot).map { $0.lastPathComponent }.sorted()
            expect(!before.isEmpty, "a has a data folder to protect (\(before.joined(separator: ",")))")
            sessions.walkAgain(a)
            var sawCopy = false
            let again = await wait("the repeated walk", 240) {
                if clones().contains(where: { fm.fileExists(atPath: $0.appendingPathComponent(marker).path) }) { sawCopy = true }
                return ev.started == 3 && isDone(a.worktree.path, keyA)
            }
            expect(again, "\"Walk again\" walks a cached build once more")
            expect(sawCopy, "the walk ran on a copy of the data, which held the marker")
            let after = slotFolders(a.slot).filter { fm.fileExists(atPath: $0.appendingPathComponent(marker).path) }
            expect(!after.isEmpty && after.allSatisfy { (try? String(contentsOf: $0.appendingPathComponent(marker), encoding: .utf8)) == "kept" },
                   "the marker in the session's data is unchanged after the walk")
            expect(slotFolders(a.slot).map { $0.lastPathComponent }.sorted() == before && clones().isEmpty, "no slot appeared or went, and the copy is deleted")
            expect(ev.entry(of: a.worktree.path)?.note?.contains("copy of this session's data") == true, "the row's detail says it walked a copy")

            // 4. A new build cancels a running walk, and the newer one is walked.
            let cancelledBefore = ev.cancelledRuns
            guard let v3 = variant(), let v4 = variant(), let key3 = place("a", v3) else { failures += 1; finish() }
            let key4 = SessionStore.key(of: v4) ?? "none"
            _ = await wait("a's walk of the third build", 60) {
                if case .walking? = ev.entry(of: a.worktree.path)?.status, ev.entry(of: a.worktree.path)?.key == key3 { return true }
                return false
            }
            expect(place("a", v4) == key4, "a newer build lands while that one is walked")
            let newer = await wait("the walk of the newer build", 240) { isDone(a.worktree.path, key4) }
            expect(newer && hasMap(key4), "the newer build is walked\(newer ? "" : " (row: \(String(describing: ev.entry(of: a.worktree.path))), running \(ev.runningOwner ?? "none"), started \(ev.started), key3 \(key3) key4 \(key4))")")
            expect(ev.cancelledRuns > cancelledBefore && !hasMap(key3), "the older build's walk was cancelled and left no map (\(ev.cancelledRuns - cancelledBefore) cancelled)")
            expect(!fm.fileExists(atPath: mapDir(key3).deletingLastPathComponent().appendingPathComponent("map.part").path), "its half-made map is gone")
            expect(clones().isEmpty, "the cancelled walk's data copy is gone")

            // 5. One at a time, all through.
            expect(maxCrawlers <= 1 && maxWalking <= 1, "never more than one walk at once (crawlers \(maxCrawlers), rows walking \(maxWalking))")

            // 6. Off walks nothing.
            sessions.setAuto(.off, for: a)
            expect(sessions.auto(of: a) == .off && store.loadWorkspaces().first?.auto == .off, "auto off is saved with the workspace")
            let startedBefore = ev.started
            guard let v5 = variant(), let key5 = place("a", v5) else { failures += 1; finish() }
            _ = await wait("the new build to be filed", 30) { store.build(key5) != nil }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            expect(ev.started == startedBefore && !hasMap(key5) && ev.entry(of: a.worktree.path)?.key != key5, "with auto off a new build is not walked")

            // 7. Builds against a base.
            // (Of a's builds the store keeps the last three, so the first has gone with its evidence.)
            if let head = store.build(key4) {
                var ended: Result<Evidence.ChangesResult, Evidence.Failure>?
                ev.changes(head: head, base: head) { ended = $0 }
                _ = await wait("the comparison", 300) { ended != nil }
                switch ended {
                case .success(let r)?:
                    expect(r.summary.differing == 0 && r.summary.same > 0 && r.map.screens.count > 0,
                           "a build against itself differs on no screen (same \(r.summary.same), changed \(r.summary.changed), new \(r.summary.new), gone \(r.summary.gone))")
                    expect(fm.fileExists(atPath: store.root.appendingPathComponent("changes/\(key4)-\(key4)/crawl.json").path), "it is kept in changes/<head>-<base>")
                case .failure(let f)?: expect(false, "the comparison ran: \(f)")
                case nil: expect(false, "the comparison ended")
                }
                let n = ev.started
                var cached = false
                ev.changes(head: head, base: head) { if case .success = $0 { cached = true } }
                _ = await wait("the cached comparison", 10) { cached }
                expect(cached && ev.started == n, "a pair already compared answers at once, without a run")
                // And one that is cancelled leaves nothing running.
                if let other = store.build(keyB) {
                    var result: Result<Evidence.ChangesResult, Evidence.Failure>?
                    let token = ev.changes(head: head, base: other) { result = $0 }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    token.cancel()
                    _ = await wait("the cancelled comparison", 30) { result != nil }
                    if case .failure? = result { expect(true, "a cancelled comparison is told so") } else { expect(false, "a cancelled comparison is told so") }
                    let gone = await wait("the cancelled run to end", 30) { ev.entry(of: "changes:\(key4)-\(keyB)") == nil && (run("/usr/bin/pgrep", ["-f", "scripts/crawl.py .*evidence-check/state"]) ?? "").isEmpty }
                    expect(gone && !fm.fileExists(atPath: store.root.appendingPathComponent("changes/\(key4)-\(keyB)/crawl.json").path), "no process and no result is left of it")
                }
            } else { expect(false, "a's build is in the store") }

            // 8. Pruning a build removes its evidence; the cap removes the oldest first.
            expect(hasMap(key4) && hasMap(keyB), "both builds have evidence before pruning")
            store.prune(live: [b.worktree.path])
            expect(!hasMap(key4) && !fm.fileExists(atPath: mapDir(key4).deletingLastPathComponent().path), "pruning a's builds removes their evidence")
            expect(!fm.fileExists(atPath: store.root.appendingPathComponent("changes/\(key4)-\(key4)").path), "and the comparisons they were part of")
            expect(hasMap(keyB), "b's evidence stays with b's build")
            let capStore = SessionStore(root: base.appendingPathComponent("cap", isDirectory: true))
            let capEv = Evidence()
            capEv.store = capStore
            func fake(_ name: String, age: TimeInterval) {
                let d = capStore.root.appendingPathComponent("evidence/\(name)/map", isDirectory: true)
                try? fm.createDirectory(at: d, withIntermediateDirectories: true)
                let f = d.appendingPathComponent("blob")
                try? Data(count: 600_000).write(to: f)
                try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: f.path)
                try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: d.path)
            }
            fake("oldest", age: 3000); fake("middle", age: 2000); fake("newest", age: 1000)
            capEv.pruneToCap(cap: 1_300_000)
            _ = await wait("the cap to be applied", 10) { !fm.fileExists(atPath: capStore.root.appendingPathComponent("evidence/oldest").path) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            expect(!fm.fileExists(atPath: capStore.root.appendingPathComponent("evidence/oldest").path)
                   && fm.fileExists(atPath: capStore.root.appendingPathComponent("evidence/newest").path),
                   "over the size cap the oldest evidence goes first")

            // The row's wording.
            if let e = ev.entry(of: b.worktree.path) {
                expect(ev.label(e).hasSuffix("screens") && ev.detail(e).contains("does not reach"), "the row says N screens, and its detail says what a walk does not reach: \(ev.label(e))")
            }

            for s in [a, b] { for f in slotFolders(s.slot) { try? fm.removeItem(at: f) } }
            for f in ((try? fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []) {
                for d in (try? fm.contentsOfDirectory(at: f, includingPropertiesForKeys: nil)) ?? [] where [a.slot, b.slot].contains(where: { d.lastPathComponent.hasPrefix($0 + "-") }) { try? fm.removeItem(at: d) }
            }
            finish()
        }
    }
}
