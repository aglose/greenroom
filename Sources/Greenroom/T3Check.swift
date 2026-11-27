import Foundation

/// `Greenroom --t3-check DIR`: T3 Code's threads read through a stand-in `t3` program, in a fresh folder inside DIR.
/// The stand-in answers `thread list` and `thread show` with fixtures in T3 Code's shapes and records its calls. The
/// real `t3` is never run: the lookup path is the stand-in's folder alone, and the login shell is not asked. Checks
/// the list's parsing, the details' worktree and branch, the status mapping (running is working, waiting or a pending
/// request is waiting, completed is idle), pull requests and their states, old and child threads left out, details
/// cached between reads, a thread landing on its worktree's row, and a `t3` that fails (no server) giving no threads.
/// One `[greenroom] t3: ok|FAIL ...` line per step, then `t3 check: PASS|FAIL`; exits 0 or 1.
enum T3Check {
    /// `Greenroom --t3-live REPO`: one read of the person's own T3 Code for REPO, printed (what the rows would get).
    static func live(repo: URL) -> Never {
        Thread.detachNewThread {
            var cache: [String: (updated: String, detail: T3Reader.Detail)] = [:]
            let r = T3Reader.read(roots: [repo], cache: &cache)
            print("[greenroom] t3 live: \(r.sessions.count) thread(s)" + (r.note.map { ", note: \($0)" } ?? ""))
            for s in r.sessions {
                let extra = [s.model.map { "model=\($0)" }, s.settled ? "settled" : nil, s.summary.map { "summary=\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
                print("  \(s.id ?? "?") \"\(s.title ?? "")\" \(s.status) running=\(s.running) archived=\(s.archived) branch=\(s.branch ?? "-") folder=\(s.folder.path) \(extra) prs=\(s.prs.map { "\($0.url.absoluteString) \($0.state.map { "\($0)" } ?? "?")" })")
            }
            exit(0)
        }
        dispatchMain()
    }

    static func run(dir: URL) -> Never {
        Thread.detachNewThread { body(dir: dir) }
        dispatchMain()
    }

    private static func body(dir: URL) -> Never {
        var failures = 0
        func say(_ s: String) { fputs("[greenroom] t3: \(s)\n", stdout); fflush(stdout) }
        func expect(_ ok: Bool, _ what: String, _ got: String = "") {
            if !ok { failures += 1 }
            say((ok ? "ok " : "FAIL ") + what + (ok || got.isEmpty ? "" : " (got: \(got))"))
        }
        let fm = FileManager.default
        let base = dir.resolvingSymlinksInPath().appendingPathComponent("t3-check-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        let repo = base.appendingPathComponent("repo", isDirectory: true)
        let wt = base.appendingPathComponent("repo-wt", isDirectory: true)
        for d in [bin, repo, wt] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let now = ISO8601DateFormatter().string(from: Date())
        let old = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 86_400))
        let list = """
        [{"threadId":"t-run","projectId":"p1","title":"Fix the login screen","status":"running","updatedAt":"\(now)","parentThreadId":null,
          "pullRequests":[{"host":"github.com","repository":"o/r","number":12,"url":"https://github.com/o/r/pull/12","source":"created","state":"open","watching":true,"watchStartedAt":null}],
          "linkedPullRequest":null,"settled":false,"snoozed":false,"itemCount":3,"createdAt":"\(now)"},
         {"threadId":"t-wait","projectId":"p1","title":"Ask first","status":"idle","updatedAt":"\(now)","parentThreadId":null,"pullRequests":[]},
         {"threadId":"t-done","projectId":"p1","title":"Shipped","status":"completed","updatedAt":"\(now)","parentThreadId":null,
          "pullRequests":[{"host":"github.com","repository":"o/r","number":9,"url":"https://github.com/o/r/pull/9","source":"created","state":"merged","watching":false,"watchStartedAt":null}]},
         {"threadId":"t-old","projectId":"p1","title":"Long ago","status":"idle","updatedAt":"\(old)","parentThreadId":null},
         {"threadId":"t-child","projectId":"p1","title":"A subagent","status":"running","updatedAt":"\(now)","parentThreadId":"t-run"}]
        """
        let script = """
        #!/bin/sh
        D="$(cd "$(dirname "$0")/.." && pwd)"
        echo "$*" >> "$D/calls.log"
        if [ -f "$D/down" ]; then echo "No running T3 Code server uses ~/.t3. Start T3 Code, then retry." >&2; exit 1; fi
        case "$1 $2" in
          "thread list")
            case "$4" in *other*) echo "No T3 Code project matches '$4'. Pass a project id or a path inside a project." >&2; exit 1 ;; esac
            cat "$D/list.json"; exit 0 ;;
          "thread show")
            case "$3" in
              t-run) echo '{"thread":{"threadId":"t-run","worktreePath":"\(wt.path)","branch":"fix-login","archived":false,"settled":false,"pendingRequestCount":0,"model":"gemini-4-neon","providerInstanceId":"antigravity"},"messages":[{"role":"user","text":"Fix the login button spacing on small screens"}]}' ;;
              t-wait) echo '{"thread":{"threadId":"t-wait","worktreePath":null,"branch":"main","archived":false,"settled":false,"pendingRequestCount":1}}' ;;
              t-done) echo '{"threadId":"t-done","worktreePath":"\(wt.path)","branch":"fix-login","archived":true,"settled":true}' ;;
              *) echo "no such thread" >&2; exit 1 ;;
            esac; exit 0 ;;
        esac
        echo "unexpected: $*" >&2; exit 3
        """
        let t3 = bin.appendingPathComponent("t3")
        try? script.write(to: t3, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: t3.path)
        try? list.write(to: base.appendingPathComponent("list.json"), atomically: true, encoding: .utf8)
        let log = base.appendingPathComponent("calls.log")
        func calls() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

        LoginEnvironment.override = [:]
        T3Reader.pathOverride = bin.path + ":/usr/bin:/bin"

        var cache: [String: (updated: String, detail: T3Reader.Detail)] = [:]
        let first = T3Reader.read(roots: [repo], cache: &cache)
        func one(_ id: String) -> ClaudeSession? { first.sessions.first { $0.id == id } }
        expect(calls().first == "thread list --project \(repo.path) --json", "the list is asked for the repository, as JSON", calls().first ?? "none")
        expect(first.note == nil && first.sessions.count == 3, "three threads: the old one and the subagent's are left out", first.sessions.compactMap(\.id).joined(separator: ","))
        expect(calls().filter { $0.hasPrefix("thread show") }.count == 3, "one thread show per thread kept")
        let run = one("t-run"), wait = one("t-wait"), done = one("t-done")
        expect(run?.source == .t3 && run?.title == "Fix the login screen" && run?.status == .working && run?.running == true,
               "a running thread is working", "\(run as Any)")
        expect(run?.model == "gemini-4-neon" && run?.provider == "antigravity" && run?.summary == "Fix the login button spacing on small screens",
               "model, provider, and latest user prompt summary come from thread show", "\(run?.model ?? "-") / \(run?.summary ?? "-")")
        expect(run?.folder.path == wt.resolvingSymlinksInPath().path && run?.branch == "fix-login", "its worktree and branch come from thread show")
        expect(run?.prs.first?.state == .open && run?.prs.first?.number == 12 && run?.prs.first?.branch == "fix-login", "its pull request is open, from its branch")
        expect(wait?.status == .waiting && wait?.folder.path == repo.resolvingSymlinksInPath().path, "a pending request is waiting; no worktree means the main checkout (details under \"thread\" read)")
        expect(done?.status == .idle && done?.running == false && done?.archived == true && done?.settled == true && done?.prs.first?.state == .merged, "a completed thread is idle, archived, settled, its pull request merged")

        // Details are cached while a thread's update time stays the same.
        try? fm.removeItem(at: log)
        _ = T3Reader.read(roots: [repo], cache: &cache)
        expect(calls() == ["thread list --project \(repo.path) --json"], "a second read asks no thread show", calls().joined(separator: " | "))

        // On the rows: the running thread names its worktree's row, which shows an open pull request and is active.
        let row = Session(worktree: wt, workspace: repo, branch: "fix-login", head: "abc", dirty: false, ahead: 0, claude: run, build: nil, simulator: nil, outputs: nil, sourcesDate: nil)
        expect(row.title == "Fix the login screen" && row.hasOpenPR && row.claudeActive, "the row is named by the thread, active, with an open pull request")
        var doneRow = row; doneRow.claude = done
        expect(doneRow.prMerged && !doneRow.claudeActive, "a row whose thread finished with a merged pull request is one to archive")

        // A repository that is not a T3 Code project: no threads from it, and no note (T3 Code answered).
        let other = base.appendingPathComponent("other", isDirectory: true)
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        let mixed = T3Reader.read(roots: [other], cache: &cache)
        expect(mixed.sessions.isEmpty && mixed.note == nil, "a repository T3 Code has no project for gives no threads and no note", mixed.note ?? "")

        // No server: nothing, and a line saying so.
        fm.createFile(atPath: base.appendingPathComponent("down").path, contents: Data())
        var empty: [String: (updated: String, detail: T3Reader.Detail)] = [:]
        let down = T3Reader.read(roots: [repo], cache: &empty)
        expect(down.sessions.isEmpty && down.note != nil, "with no T3 Code running: no threads, and a note", down.note ?? "no note")

        // No t3 at all.
        T3Reader.pathOverride = base.appendingPathComponent("nowhere").path
        let none = T3Reader.read(roots: [repo], cache: &empty)
        expect(none.sessions.isEmpty && (none.note ?? "").contains("not found"), "without a t3 command: no threads, and a note", none.note ?? "no note")

        if failures == 0 { try? fm.removeItem(at: base) }
        say(failures == 0 ? "done" : "stopped with \(failures) failure(s)")
        print("t3 check: " + (failures == 0 ? "PASS" : "FAIL"))
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
