import AppKit

/// `Greenroom --claude-check DIR`: fixture trees of Claude Code's files, with invented content, written into DIR (a
/// live terminal session, a desktop session in a worktree reached through a symlink, a finished session known only
/// from a transcript, an archived one, one whose process is gone; a truncated file, an empty file and one with
/// unknown fields), and a temporary git repository with matching worktrees. Checks that the right rows get the right
/// title and status, that the broken files change nothing, that files nothing can read leave plain rows with a line
/// saying so, that a change of a file shows up through FSEvents, that a repository with sessions is offered and
/// added on a click's call, and that with the switch off no fixture file is opened. The real `~/.claude` and the real
/// Claude app folder are never read (`ClaudeSessions` points at nothing under any `--*-check`). One
/// `[greenroom] claude: ok|FAIL ...` line per step, then `claude check: PASS|FAIL`; exits 0 or 1.
enum ClaudeCheck {
    static func run(workbench wb: Workbench, dir: URL) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            let sessions = wb.sessions
            let claude = ClaudeSessions.shared

            func say(_ s: String) { fputs("[greenroom] claude: \(s)\n", stdout); fflush(stdout) }
            func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; say((ok ? "ok " : "FAIL ") + what) }
            @MainActor func wait(_ what: String, _ seconds: Double = 20, _ cond: @MainActor () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
                say("timed out waiting for \(what)")
                return false
            }
            var scratch: URL?   // the fresh folder inside DIR this run works in; the only thing removed
            @MainActor func finish() -> Never {
                if failures == 0, let scratch { try? FileManager.default.removeItem(at: scratch) }
                say(failures == 0 ? "done" : "stopped with \(failures) failure(s)")
                print("claude check: " + (failures == 0 ? "PASS" : "FAIL"))
                fflush(stdout)
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
            func makeRepo(_ folder: URL) -> Bool {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                try? "hello\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
                return git(["init", "-q", "-b", "main"], in: folder) && git(["add", "."], in: folder) && git(["commit", "-q", "-m", "first"], in: folder)
            }

            let base = dir.resolvingSymlinksInPath().appendingPathComponent("claude-check-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
            scratch = base
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            let repo = base.appendingPathComponent("repo", isDirectory: true)
            let other = base.appendingPathComponent("other", isDirectory: true)
            // `other` is an Android app (a Gradle wrapper and an application module): only such a repository is offered.
            let notes = base.appendingPathComponent("notes", isDirectory: true)
            guard makeRepo(repo), makeRepo(other), makeRepo(notes) else { say("FAIL could not make the repositories (is /usr/bin/git there?)"); failures += 1; finish() }
            try? "#!/bin/sh\nexit 1\n".write(to: other.appendingPathComponent("gradlew"), atomically: true, encoding: .utf8)
            try? fm.createDirectory(at: other.appendingPathComponent("app"), withIntermediateDirectories: true)
            try? "plugins { id(\"com.android.application\") }\n".write(to: other.appendingPathComponent("app/build.gradle.kts"), atomically: true, encoding: .utf8)
            func wt(_ n: String) -> URL { base.appendingPathComponent("wt-" + n, isDirectory: true) }
            for n in ["live", "desk", "done", "arch", "dead", "sub", "small"] {
                guard git(["worktree", "add", "-q", "-b", "feat-" + n, wt(n).path], in: repo) else { say("FAIL could not make worktree \(n)"); failures += 1; finish() }
            }
            // The desktop session names its folder through a symlink: the join resolves it.
            let link = base.appendingPathComponent("link-desk")
            try? fm.createSymbolicLink(at: link, withDestinationURL: wt("desk"))

            // A process that is gone, for the pid file of a terminal session that ended.
            let ended = Process()
            ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try? ended.run()
            ended.waitUntilExit()
            let gonePid = Int(ended.processIdentifier)

            // MARK: Fixtures

            func put(_ text: String, at file: URL) {
                try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: file, atomically: true, encoding: .utf8)
            }
            func put(json obj: [String: Any], at file: URL) {
                put(String(data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(), encoding: .utf8) ?? "", at: file)
            }
            let iso = ISO8601DateFormatter()
            let hourAgo = iso.string(from: Date().addingTimeInterval(-3600))
            let pr = "https://example.invalid/acme/app/pull/12"
            let transcriptPr = "https://example.invalid/acme/app/pull/7"

            func writeLive(_ r: ClaudeRoots, working: Bool) {
                put(json: ["pid": Int(getpid()), "sessionId": "cli-live", "cwd": wt("live").path, "name": "Fixture: tidy the login form",
                           "status": working ? "busy" : "idle", "updatedAt": Date().timeIntervalSince1970 * 1000, "entrypoint": "cli"],
                    at: r.sessions.appendingPathComponent("\(getpid()).json"))
            }

            /// `broken`: whether the truncated, empty and unknown-field files are written too.
            func tree(_ root: URL, broken: Bool, working: Bool = true) -> ClaudeRoots {
                let r = ClaudeRoots(sessions: root.appendingPathComponent("home/.claude/sessions", isDirectory: true),
                                    desktop: root.appendingPathComponent("home/app/claude-code-sessions/acct/org", isDirectory: true),
                                    projects: root.appendingPathComponent("home/.claude/projects", isDirectory: true))
                // A: a live terminal session (this process stands in for Claude Code).
                writeLive(r, working: working)
                // A terminal session whose process ended.
                put(json: ["pid": gonePid, "sessionId": "cli-dead", "cwd": wt("dead").path, "name": "Fixture: ended terminal", "status": "busy"],
                    at: r.sessions.appendingPathComponent("\(gonePid).json"))
                // B: a desktop session in a worktree, reached through a symlink, waiting for the person.
                put(json: ["title": "Fixture: settings screen", "cwd": link.path, "originCwd": repo.path, "isArchived": false,
                           "prs": [["url": pr]], "lastActivityAt": hourAgo, "interruptedAwaitingPerson": true, "cliSessionId": "cli-desk"],
                    at: r.desktop.appendingPathComponent("local_fixture-b.json"))
                // An archived one.
                put(json: ["title": "Fixture: archived idea", "folderPlace": ["cwd": wt("arch").path, "origin": ["cwd": repo.path]],
                           "isArchived": true, "lastActivityAt": hourAgo], at: r.desktop.appendingPathComponent("local_fixture-arch.json"))
                // C: a finished session known only from its transcript: first line, filler, title and PR near the end.
                var lines = [["type": "user", "cwd": wt("done").path, "gitBranch": "feat-done", "sessionId": "cli-done"]]
                for i in 0..<400 { lines.append(["type": "assistant", "cwd": wt("done").path, "gitBranch": "feat-done", "note": String(repeating: "x", count: 200 + i % 7)]) }
                lines.append(["type": "custom-title", "customTitle": "Fixture: finished refactor"])
                lines.append(["type": "pr-link", "prUrl": transcriptPr])
                put(lines.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n",
                    at: r.projects.appendingPathComponent("-fixture-wt-done/cli-done.jsonl"))
                // A session started in a subfolder of a worktree.
                try? fm.createDirectory(at: wt("sub").appendingPathComponent("app/src"), withIntermediateDirectories: true)
                put(json: ["title": "Fixture: from a subfolder", "cwd": wt("sub").appendingPathComponent("app/src").path, "originCwd": repo.path,
                           "lastActivityAt": hourAgo], at: r.desktop.appendingPathComponent("local_fixture-sub.json"))
                // A small transcript (all of it is in the first 64 KB): the title is on its third line.
                let small = [["type": "user", "cwd": wt("small").path, "gitBranch": "feat-small"], ["type": "assistant", "cwd": wt("small").path],
                             ["type": "custom-title", "customTitle": "Fixture: small transcript"], ["type": "pr-link", "prUrl": "https://example.invalid/acme/app/pull/3"]]
                put(small.map { String(data: try! JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }.joined(separator: "\n") + "\n",
                    at: r.projects.appendingPathComponent("-fixture-wt-small/cli-small.jsonl"))
                if broken {
                    put("{\"pid\": 12, \"cwd\": \"", at: r.sessions.appendingPathComponent("broken.json"))       // cut off
                    put("", at: r.desktop.appendingPathComponent("local_empty.json"))                            // empty
                    put(json: ["schema": 9, "cwd": wt("desk").path, "futureField": ["a": [1, 2], "b": NSNull()], "title": NSNull(), "status": 7],
                        at: r.desktop.appendingPathComponent("local_unknown.json"))                              // unknown fields
                    put("not json at all\n", at: r.projects.appendingPathComponent("-fixture-wt-done/garbage.jsonl"))
                }
                return r
            }
            let full = tree(base.appendingPathComponent("fx-full"), broken: true)
            let clean = tree(base.appendingPathComponent("fx-clean"), broken: false)
            let onlyBroken = ClaudeRoots(sessions: base.appendingPathComponent("fx-broken/sessions"), desktop: base.appendingPathComponent("fx-broken/desktop"),
                                         projects: base.appendingPathComponent("fx-broken/projects"))
            put("{\"pid\": 12, \"cwd\": \"", at: onlyBroken.sessions.appendingPathComponent("broken.json"))
            put("", at: onlyBroken.desktop.appendingPathComponent("local_empty.json"))
            put("[1, 2", at: onlyBroken.projects.appendingPathComponent("-x/one.jsonl"))

            let store = SessionStore(root: base.appendingPathComponent("state", isDirectory: true))
            sessions.use(store: store)
            func row(_ n: String) -> Session? { sessions.sessions.first { $0.worktree.lastPathComponent == "wt-" + n } }
            func mainRow() -> Session? { sessions.sessions.first { $0.isMain } }

            // 1. The switch is off: rows are plain and no fixture file is opened.
            claude.roots = full
            claude.enabledOverride = false
            claude.changedSwitch()
            _ = await wait("a read in flight to end", 10) { !claude.isScanning }   // then nothing more can be recorded
            ClaudeReader.resetOpened()
            _ = await sessions.addRepository(repo).value
            _ = await wait("the rows") { sessions.sessions.count == 8 }
            claude.reload()
            sessions.refresh()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            expect(sessions.sessions.count == 8 && sessions.sessions.allSatisfy { $0.claude == nil }, "switch off: \(sessions.sessions.count) plain rows, none with a Claude session")
            expect(row("live")?.title == "feat-live" && claude.offers.isEmpty && claude.note == nil, "switch off: rows are titled by their branch, nothing offered, no note")
            expect(ClaudeReader.opened.isEmpty, "switch off: no Claude file was opened (\(ClaudeReader.opened.count) opened)")

            // 2. On: each shape joins its row.
            claude.enabledOverride = true
            claude.changedSwitch()
            let joined = await wait("the Claude sessions") { row("live")?.claude != nil && row("desk")?.claude != nil && row("done")?.claude != nil && row("arch")?.claude != nil && row("dead")?.claude != nil && row("sub")?.claude != nil && row("small")?.claude != nil }
            expect(joined, "switch on: seven worktrees have a Claude session")
            let live = row("live"), desk = row("desk"), done = row("done"), arch = row("arch"), dead = row("dead")
            expect(live?.title == "Fixture: tidy the login form" && live?.branch == "feat-live" && live?.claude?.status == .working && live?.claude?.running == true,
                   "live terminal session: its name is the row's title, the branch is kept, working (\(live?.title ?? "?"), \(live?.claude?.status.rawValue ?? "?"))")
            expect(desk?.title == "Fixture: settings screen" && desk?.claude?.status == .waiting && desk?.claude?.pullRequests.map(\.absoluteString) == [pr],
                   "desktop session in a worktree (named by a symlink): title, waiting for you, pull request (\(desk?.title ?? "?"), \(desk?.claude?.status.rawValue ?? "?"))")
            expect(done?.title == "Fixture: finished refactor" && done?.claude?.branch == "feat-done" && done?.claude?.running == false
                   && done?.claude?.status == .idle && done?.claude?.pullRequests.map(\.absoluteString) == [transcriptPr],
                   "finished session known from its transcript only: title, branch, pull request, not running (\(done?.title ?? "?"))")
            expect(arch?.claude?.archived == true && arch?.claude?.running == false && arch?.title == "Fixture: archived idea", "archived session is not live")
            expect(dead?.claude?.running == false && dead?.claude?.status == .idle && dead?.title == "Fixture: ended terminal", "a pid file whose process is gone counts as not running")
            expect(row("sub")?.title == "Fixture: from a subfolder", "a session started in a subfolder of a worktree is on that worktree's row")
            expect(row("small")?.title == "Fixture: small transcript" && row("small")?.claude?.pullRequests.count == 1 && row("small")?.claude?.branch == "feat-small",
                   "a transcript of under 64 KB has its later lines read (title, pull request)")
            let nested = ClaudeSessions.owner(of: URL(fileURLWithPath: "/x/a/b/c"), among: ["/x/a", "/x/a/b", "/x/ab"].map { URL(fileURLWithPath: $0) })
            let sibling = ClaudeSessions.owner(of: URL(fileURLWithPath: "/x/ab/c"), among: [URL(fileURLWithPath: "/x/a")])
            expect(nested == "/x/a/b" && sibling == nil, "the deepest worktree above a folder owns it, on whole path components (\(nested ?? "nil"), \(sibling ?? "nil"))")
            expect(mainRow()?.claude == nil && mainRow()?.title == "main", "a worktree with no Claude session stays a plain row")
            expect(ClaudeUI.dot(for: live?.claude) != nil && ClaudeUI.dot(for: nil) == nil, "a status dot for a row with a session, none without")

            // 3. Broken files change nothing; the reader says how many it could use.
            let withBroken = ClaudeReader.read(full), without = ClaudeReader.read(clean)
            func undated(_ s: ClaudeSession?) -> ClaudeSession? { var s = s; s?.lastActivity = nil; return s }   // file times differ between the two trees
            let same = ["live", "desk", "done", "arch", "dead", "sub", "small"].allSatisfy {
                undated(ClaudeSessions.best(for: wt($0), in: withBroken.sessions)) == undated(ClaudeSessions.best(for: wt($0), in: without.sessions))
            }
            expect(same && withBroken.seen == without.seen + 4 && withBroken.parsed == without.parsed + 1,
                   "truncated, empty and garbage files change no row (\(withBroken.parsed) of \(withBroken.seen) files used; the unknown-fields file adds nothing)")

            // 3b. Process ids that cannot be real never trap; a reused id is not running; unchanged files are not reopened.
            let weird = ClaudeRoots(sessions: base.appendingPathComponent("fx-pid/sessions"), desktop: base.appendingPathComponent("fx-pid/desktop"), projects: base.appendingPathComponent("fx-pid/projects"))
            let bad = ["{\"pid\": 99999999999, \"cwd\": \"/nonexistent/p1\"}", "{\"pid\": 1e30, \"cwd\": \"/nonexistent/p2\"}", "{\"pid\": true, \"cwd\": \"/nonexistent/p3\"}",
                       "{\"pid\": 1.5, \"cwd\": \"/nonexistent/p4\"}", "{\"pid\": -4, \"cwd\": \"/nonexistent/p5\"}", "{\"pid\": \"x\", \"cwd\": \"/nonexistent/p6\"}"]
            for (i, t) in bad.enumerated() { put(t, at: weird.sessions.appendingPathComponent("bad\(i).json")) }
            let weirdRead = ClaudeReader.read(weird)
            expect(weirdRead.sessions.count == bad.count && weirdRead.sessions.allSatisfy { !$0.running }, "pids of 99999999999, 1e30, true, 1.5, -4 and \"x\" are read without a trap and are not running")
            let ago = Date().addingTimeInterval(-86_400).timeIntervalSince1970 * 1000
            put(json: ["pid": Int(getpid()), "cwd": "/nonexistent/reuse", "procStart": ago], at: weird.sessions.appendingPathComponent("reused.json"))
            let mineStart = (ClaudeReader.startTime(of: getpid())?.timeIntervalSince1970 ?? 0) * 1000
            put(json: ["pid": Int(getpid()), "cwd": "/nonexistent/same", "procStart": mineStart], at: weird.sessions.appendingPathComponent("same.json"))
            let reuseRead = ClaudeReader.read(weird)
            let reused = reuseRead.sessions.first { $0.folder.lastPathComponent == "reuse" }, sameProc = reuseRead.sessions.first { $0.folder.lastPathComponent == "same" }
            expect(reused?.running == false && sameProc?.running == true, "a pid whose process began long after the file's start is another process (reused: \(reused?.running ?? true), same: \(sameProc?.running ?? false))")
            let cache = ClaudeReader.Cache()
            _ = ClaudeReader.read(full, cache: cache)
            ClaudeReader.resetOpened()
            _ = ClaudeReader.read(full, cache: cache)
            expect(ClaudeReader.opened.isEmpty, "a second read of unchanged files opens none (\(ClaudeReader.opened.count) opened)")
            let touched = full.desktop.appendingPathComponent("local_fixture-b.json")
            put(json: ["title": "Fixture: settings screen", "cwd": link.path, "originCwd": repo.path, "prs": [["url": pr]], "lastActivityAt": hourAgo, "interruptedAwaitingPerson": false, "cliSessionId": "cli-desk"], at: touched)
            _ = ClaudeReader.read(full, cache: cache)
            expect(ClaudeReader.opened.map { ($0 as NSString).lastPathComponent } == [touched.lastPathComponent], "a changed file is the only one reopened (\(ClaudeReader.opened.map { ($0 as NSString).lastPathComponent }))")
            put(json: ["title": "Fixture: settings screen", "cwd": link.path, "originCwd": repo.path, "prs": [["url": pr]], "lastActivityAt": hourAgo, "interruptedAwaitingPerson": true, "cliSessionId": "cli-desk"], at: touched)
            let oldFile = full.projects.appendingPathComponent("-fixture-old/cli-old.jsonl")
            put("{\"type\":\"user\",\"cwd\":\"/nonexistent/old\"}\n", at: oldFile)
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86_400)], ofItemAtPath: oldFile.path)
            ClaudeReader.resetOpened()
            _ = ClaudeReader.read(full)
            expect(!ClaudeReader.opened.contains { ($0 as NSString).lastPathComponent == "cli-old.jsonl" } && ClaudeReader.opened.contains { ($0 as NSString).lastPathComponent == "cli-done.jsonl" }, "a transcript untouched for 60 days is not opened")

            // 4. Nothing parses: plain rows and one line saying so.
            claude.roots = onlyBroken
            claude.changedSwitch()
            let noted = await wait("the note") { claude.note != nil && row("live")?.claude == nil }
            expect(noted && sessions.sessions.allSatisfy { $0.claude == nil } && row("live")?.title == "feat-live", "files that do not parse: plain rows and a line saying so (\(claude.note ?? "none"))")
            claude.roots = full
            claude.changedSwitch()
            _ = await wait("the sessions back") { row("live")?.claude != nil }
            expect(claude.note == nil && row("live")?.title == "Fixture: tidy the login form", "readable files again: the note goes, the titles come back")

            // 5. FSEvents, with a busy session: its file is rewritten every half second for ten seconds, and the row
            // follows within the debounce's longest wait, not after the writing stops.
            ClaudeReader.resetOpened()
            let writer = Task { @MainActor in for _ in 0..<20 { writeLive(full, working: false); try? await Task.sleep(nanoseconds: 500_000_000) } }
            let followed = await wait("the watcher", 9) { row("live")?.claude?.status == .idle }
            expect(followed && !writer.isCancelled, "a changed file shows up through FSEvents while it is still being written (live: \(row("live")?.claude?.status.rawValue ?? "?"))")
            await writer.value
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // the last burst's reload has run

            // 5b. One notification per reload.
            let told = claude.onChange
            var count = 0
            claude.onChange = { count += 1; told?() }
            claude.reload()
            _ = await wait("the reload") { count > 0 }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            claude.onChange = told
            expect(count == 1, "a reload tells its listener once (\(count))")

            // 6. A repository with sessions that was not added is offered; adding it takes the offer away.
            put(json: ["title": "Fixture: other one", "cwd": other.path, "originCwd": other.path, "lastActivityAt": hourAgo], at: full.desktop.appendingPathComponent("local_fixture-other.json"))
            put(["{\"type\":\"user\",\"cwd\":\"\(other.path)\",\"gitBranch\":\"main\"}"].joined(separator: "\n") + "\n", at: full.projects.appendingPathComponent("-fixture-other/cli-other.jsonl"))
            // A repository that is no Android project, with a session too: never offered.
            put(json: ["title": "Fixture: notes", "cwd": notes.path, "originCwd": notes.path, "lastActivityAt": hourAgo], at: full.desktop.appendingPathComponent("local_fixture-notes.json"))
            claude.reload()
            let offered = await wait("the offer") { claude.offers.first?.repository == other.resolvingSymlinksInPath() }
            expect(offered && claude.offers.count == 1 && claude.offers.first?.count == 2,
                   "a repository with 2 Claude sessions that was not added is offered, one that is no Android project is not (\(claude.offers.map { "\($0.repository.lastPathComponent) \($0.count)" }.joined(separator: ", ")))")
            _ = await sessions.addRepository(other).value
            let gone = await wait("the offer to go") { claude.offers.isEmpty && sessions.sessions.count == 9 }
            expect(gone, "adding it lists its worktree and withdraws the offer (\(sessions.sessions.count) rows)")

            // 7. Off again: rows are plain, and nothing is opened while it is.
            claude.enabledOverride = false
            ClaudeReader.resetOpened()
            claude.changedSwitch()
            put(json: ["title": "Fixture: while off", "cwd": wt("live").path], at: full.desktop.appendingPathComponent("local_fixture-off.json"))
            claude.reload()
            sessions.refresh()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            expect(sessions.sessions.allSatisfy { $0.claude == nil } && claude.offers.isEmpty, "switch off again: plain rows, no offers")
            expect(ClaudeReader.opened.isEmpty, "switch off again: no Claude file was opened (\(ClaudeReader.opened.count) opened)")

            finish()
        }
    }
}
