import AppKit

/// `GREENROOM_STATE=EMPTY_DIR Greenroom --background --agent-check --attention-check DIR`: the sidebar by what
/// sessions need (docs/AGENT-FIRST-SPEC.md, "Sessions, by what they need"; step A5). A temporary git repository
/// with a worktree for each case is added, and each is brought to its state the way it happens for real: a
/// harness's hooks heard (a turn running, a permission asked for, a turn's end), a `check` noted, a build filed.
/// It asserts where each session is filed and in what order, the counts in the top bar, the Dock badge, the
/// notification for a session that became ready or came to need the person (handed to the check, never posted), the
/// ⌘' order, the six marks of the loop, the grouping by repository given back, and first run's last screen. A
/// picture of each is written to DIR (set.png, attention.png, repositories.png). No engine is started, nothing is
/// built, and the person's settings are neither read nor changed. One `[greenroom] attention: ok|FAIL ...` line per
/// step, then `attention check: PASS|FAIL`; exits 0 or 1.
enum AttentionCheck {
    static func run(workbench wb: Workbench, dir: URL, capture: @escaping (URL) -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; print("[greenroom] attention: \(ok ? "ok  " : "FAIL") \(what)"); fflush(stdout) }
            func settle(_ seconds: Double = 0.7) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            @MainActor func wait(_ what: String, _ seconds: Double = 20, _ cond: @MainActor () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
                print("[greenroom] attention: timed out waiting for \(what)")
                return false
            }
            func finish() -> Never {
                print("attention check: " + (failures == 0 ? "PASS" : "FAIL"))
                fflush(stdout)
                exit(failures == 0 ? 0 : 1)
            }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // MARK: The rule, by itself

            typealias F = AttentionFacts
            func judge(_ f: F) -> AttentionState { AttentionState.judge(f) }
            expect(judge(F()).group == .quiet, "nothing known: quiet")
            expect(judge(F(working: "Codex")) == AttentionState(group: .working, line: "Codex is working", tone: .go), "a turn running: working, and whose")
            expect(judge(F(building: "Building with local")).group == .working && judge(F(calls: true)).line == "An agent is driving", "a build going, or calls arriving: working")
            expect(judge(F(waiting: "Claude Code", working: "Claude Code")) == AttentionState(group: .needs, line: "Claude Code is waiting for you", tone: .warn), "a harness waiting on a permission: needs you, before working")
            expect(judge(F(signIn: true)).line == "Needs a sign-in" && judge(F(asked: "remote")).line == "A remote build needs your yes" && judge(F(paused: true)).line == "Agents are paused",
                   "a sign-in, a remote build's yes, a pause: needs you, each in its words")
            expect(judge(F(turnEnded: true, buildCurrent: true, passed: 5)) == AttentionState(group: .ready, line: "5 of 5 checks passed", tone: .ok), "a turn ended on a current build with checks: ready")
            expect(judge(F(turnEnded: true, buildCurrent: true, passed: 3, failed: 1)) == AttentionState(group: .ready, line: "3 of 4 passed · 1 failed", tone: .bad), "... a failed check is said, and it is still ready")
            expect(judge(F(turnEnded: true, buildCurrent: true)).group == .quiet, "a turn ended with no check: quiet (the owner's decision 5)")
            expect(judge(F(turnEnded: true, buildCurrent: false, passed: 2)).group == .quiet, "... or on a build that is not current: quiet")
            expect(judge(F(turnEnded: false, buildCurrent: true, passed: 2)).group == .quiet, "checks alone, with no turn's end heard: quiet")
            expect(judge(F(working: "Codex", turnEnded: true, buildCurrent: true, passed: 2)).group == .working, "a new turn takes a ready session back to working")
            expect(judge(F(review: "done", working: "Codex")).group == .ready, "a session that asked for a review is ready though its turn still runs")
            let counts: [Attention: Int] = [.ready: 1, .needs: 2, .working: 3, .quiet: 4]
            expect(Attention.summary(counts) == "1 ready · 2 need you · 3 working" && Attention.summary([.needs: 1]) == "1 needs you" && Attention.summary([.quiet: 3]) == nil,
                   "the top bar's words: \(Attention.summary(counts) ?? "-")")
            expect(Attention.badge(counts) == "3" && Attention.badge([.working: 2]) == nil, "the Dock badge counts ready and needing sessions, and nothing else")
            let said = Notifier.words("Rename a trip", AttentionState(group: .ready, line: "5 of 5 checks passed", tone: .ok), repository: "homesafe")
            expect(said.title == "Ready for review: Rename a trip" && said.body == "5 of 5 checks passed · homesafe", "a notification's words: \(said.title) | \(said.body)")
            expect(SessionsController.short(20) == "just now" && SessionsController.short(250) == "4 min" && SessionsController.short(7300) == "2 h" && SessionsController.short(200_000) == "2 d", "how long, in a card's few letters")
            expect(SessionsController.mark(name: "Claude Code") == "CC" && SessionsController.mark(name: "Codex") == "CX" && SessionsController.mark(name: "Cursor") == "CU" && SessionsController.mark(name: "opencode") == "OP",
                   "a harness's two letters")
            var t3 = AgentSession(folder: URL(fileURLWithPath: "/x"))
            t3.source = .t3
            t3.provider = "codex"
            expect(SessionsController.mark(for: t3)?.letters == "CX" && SessionsController.mark(for: t3)?.name == "Codex in T3 Code" && SessionsController.mark(for: nil) == nil, "a T3 Code thread is marked by the harness it runs")

            // MARK: First run's last screen

            await settle()
            expect(wb.connectShown, "first run: the Connect screen is up")
            wb.connectFlow.step = 3
            await settle()
            expect(wb.stageSummary == "the Connect screen (step 3 of 3: what the sidebar says)", "its third step says what the sidebar's groups mean: \(wb.stageSummary)")
            expect(Attention.allCases.allSatisfy { !ConnectFlowView.meaning($0).isEmpty }, "... a line for each group")
            expect(!Notifier.asked && !Notifier.enabled, "notifications are off until asked for")
            capture(dir.appendingPathComponent("set.png"))
            wb.connectFlow.setNotify(true)
            expect(Notifier.asked && Notifier.enabled && wb.connectFlow.notify, "the switch on that screen turns them on")
            wb.window.makeFirstResponder(nil)
            wb.connectFlow.onDone?()
            await settle()
            expect(!wb.connectShown, "Done leaves first run")

            // MARK: A repository, and a worktree for each case

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
            let base = dir.resolvingSymlinksInPath().appendingPathComponent("attention-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
            let repo = base.appendingPathComponent("homesafe", isDirectory: true)
            try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
            try? "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            guard git(["init", "-q", "-b", "main"], in: repo), git(["add", "."], in: repo), git(["commit", "-q", "-m", "first"], in: repo) else {
                expect(false, "could not make the repository (is /usr/bin/git there?)"); finish()
            }
            let names = ["trip-rename", "total-rounding", "empty-inbox", "settings-dark", "offline-banner"]
            func wt(_ n: String) -> URL { base.appendingPathComponent(n, isDirectory: true) }
            for n in names {
                guard git(["worktree", "add", "-q", "-b", "feat/" + n, wt(n).path], in: repo) else { expect(false, "could not make worktree \(n)"); finish() }
            }
            let sessions = wb.sessions
            let hooks = HookSessions.shared
            hooks.reset()
            var sent: [(title: String, body: String, worktree: String)] = []
            Notifier.deliver = { sent.append(($0, $1, $2)) }
            Notifier.inFront = { false }
            var clock = Date()
            WorkStore.now = { clock }
            HookSessions.now = { clock }

            _ = await sessions.addRepository(repo).value
            _ = await wait("the rows") { sessions.sessions.count == names.count + 1 && sessions.sessions.allSatisfy { !$0.head.isEmpty } }
            sessions.showAll(in: repo)
            func row(_ n: String) -> Session? { sessions.sessions.first { $0.worktree.lastPathComponent == n } }
            guard let any = row(names[0]) else { expect(false, "the worktrees are listed"); finish() }
            sessions.setAuto(.off, for: any)   // no walk: this check starts no engine
            await settle()
            expect(wb.sidebarOutline.first == "# Quiet 6" && wb.attentionText == nil && Notifier.badge == nil,
                   "six sessions with nothing known of them: all quiet, no counts in the top bar, no badge (\(wb.sidebarOutline.prefix(2)))")
            expect(wb.sidebarOutline.suffix(2) == ["# Repositories", "repo homesafe"], "the repository is listed under the groups, with its + menu: \(wb.sidebarOutline.suffix(2))")

            /// A hook heard from HARNESS in worktree N, as the agent endpoint hands it on.
            func hook(_ harness: String, _ n: String, _ event: String) {
                hooks.heard(HookLog.Event(time: clock, harness: harness, session: "s-" + n, cwd: wt(n), event: event))
            }
            func build(_ n: String) {
                guard let s = row(n) else { return }
                sessions.adopt(Build(key: "key-" + n, apk: base.appendingPathComponent("none-\(n).apk"), source: .local, sha: s.head, ref: s.branch, dirty: false, date: clock), forWorktree: s.worktree.path)
            }
            func check(_ n: String, _ passed: Bool) {
                guard let s = row(n) else { return }
                WorkStore.shared.noteCheck(s.worktree.path, passed: passed, summary: passed ? "PASS | Main" : "FAIL | Main | not on screen: \"€24.90\"", build: sessions.currentBuild(of: s)?.key)
            }
            func group(_ n: String) -> Attention? { row(n).map { sessions.attention(of: $0).group } }

            // Working: two agents' turns begin.
            clock = clock.addingTimeInterval(10)
            hook("codex", "offline-banner", "UserPromptSubmit")
            clock = clock.addingTimeInterval(10)
            hook("claude", "settings-dark", "UserPromptSubmit")
            _ = await wait("the working rows") { group("offline-banner") == .working && group("settings-dark") == .working }
            await settle()
            expect(wb.sidebarOutline.prefix(3) == ["# Working 2", "feat/offline-banner", "feat/settings-dark"], "two turns running: Working, in the order they began: \(wb.sidebarOutline.prefix(3))")
            expect(wb.attentionText == "2 working" && Notifier.badge == nil && sent.isEmpty, "the top bar counts them; working is no badge and no notification")

            // Ready: a build, checks, and the turn's end. The first to finish is on top.
            for n in ["trip-rename", "total-rounding"] { hook(n == "trip-rename" ? "claude" : "cursor", n, n == "trip-rename" ? "UserPromptSubmit" : "beforeSubmitPrompt"); build(n) }
            _ = await wait("the builds") { row("trip-rename").map { sessions.buildIsCurrent($0) } == true && row("total-rounding").map { sessions.buildIsCurrent($0) } == true }
            for _ in 0..<5 { check("trip-rename", true) }
            for ok in [true, true, false, true] { check("total-rounding", ok) }
            expect(group("trip-rename") == .working && group("total-rounding") == .working, "a build and checks while the turn runs: still working")
            clock = clock.addingTimeInterval(60)
            hook("cursor", "total-rounding", "stop")
            clock = clock.addingTimeInterval(120)
            hook("claude", "trip-rename", "Stop")
            _ = await wait("the ready rows") { group("trip-rename") == .ready && group("total-rounding") == .ready }
            await settle()
            expect(wb.sidebarOutline.prefix(3) == ["# Ready for review 2", "feat/total-rounding", "feat/trip-rename"], "their turns end: Ready for review, the first to finish on top: \(wb.sidebarOutline.prefix(3))")
            let rounding = row("total-rounding").map { sessions.attention(of: $0) }
            expect(rounding == AttentionState(group: .ready, line: "3 of 4 passed · 1 failed", tone: .bad), "a failed check shows on its card: \(rounding?.line ?? "-")")
            expect(sent.map(\.title) == ["Ready for review: feat/total-rounding", "Ready for review: feat/trip-rename"] && sent.first?.body == "3 of 4 passed · 1 failed · homesafe",
                   "each is a notification, as Greenroom is not in front: \(sent.map(\.title))")
            expect(Notifier.badge == "2" && wb.attentionText == "2 ready · 2 working", "the badge and the top bar follow: \(Notifier.badge ?? "-"), \(wb.attentionText ?? "-")")

            // Needs you: a harness asks for a permission.
            clock = clock.addingTimeInterval(30)
            hook("codex", "empty-inbox", "UserPromptSubmit")
            hook("codex", "empty-inbox", "PermissionRequest")
            _ = await wait("the needing row") { group("empty-inbox") == .needs }
            await settle()
            expect(wb.sidebarOutline.prefix(5) == ["# Ready for review 2", "feat/total-rounding", "feat/trip-rename", "# Needs you 1", "feat/empty-inbox"], "a permission asked for: Needs you, under Ready: \(wb.sidebarOutline.prefix(5))")
            expect(sent.last?.title == "Needs you: feat/empty-inbox" && sent.last?.body == "Codex is waiting for you · homesafe" && sent.count == 3, "... and a notification saying who waits: \(sent.last?.body ?? "-")")
            expect(Notifier.badge == "3" && wb.attentionText == "2 ready · 1 needs you · 2 working", "three wait for the person: \(wb.attentionText ?? "-")")
            let outline = wb.sidebarOutline
            expect(outline == ["# Ready for review 2", "feat/total-rounding", "feat/trip-rename", "# Needs you 1", "feat/empty-inbox", "# Working 2", "feat/offline-banner", "feat/settings-dark",
                               "# Quiet 1", "main", "# Repositories", "repo homesafe"], "the whole sidebar, by what each needs: \(outline)")

            // The cards.
            if let s = row("trip-rename") {
                let steps = sessions.loop(for: s)
                expect(steps.map(\.name) == LoopStep.names && steps[2].state == .done && steps[4].state == .done && steps[4].detail == "5 of 5" && steps[5].state == .going,
                       "a ready session's loop: built, verified 5 of 5, review waiting: \(steps.map { "\($0.name) \($0.state.rawValue)" })")
                expect(sessions.attentionLine(for: s, sessions.attention(of: s)) == "5 of 5 checks passed", "its card's line: \(sessions.attentionLine(for: s, sessions.attention(of: s)))")
                expect(SessionsController.mark(for: s.displayAgent)?.letters == "CC", "... and its harness's mark: \(SessionsController.mark(for: s.displayAgent)?.letters ?? "-")")
            }
            if let s = row("total-rounding") { expect(sessions.loop(for: s)[4].state == .failed, "a failed check marks Verify as failed") }
            if let s = row("offline-banner") {
                clock = clock.addingTimeInterval(240)
                expect(sessions.attentionLine(for: s, sessions.attention(of: s)).hasPrefix("Codex is working · "), "a working card says who and for how long: \(sessions.attentionLine(for: s, sessions.attention(of: s)))")
            }
            wb.window.setContentSize(NSSize(width: 1280, height: 860))
            await settle(1.2)
            capture(dir.appendingPathComponent("attention.png"))

            // ⌘' and ⌘1-9 follow the order shown.
            sessions.focus = nil
            let first = sessions.nextNeedingAttention()
            sessions.focus = first?.worktree.path
            let second = sessions.nextNeedingAttention()
            sessions.focus = second?.worktree.path
            let third = sessions.nextNeedingAttention()
            sessions.focus = third?.worktree.path
            let around = sessions.nextNeedingAttention()
            expect([first, second, third, around].map { $0?.worktree.lastPathComponent ?? "-" } == ["total-rounding", "trip-rename", "empty-inbox", "total-rounding"],
                   "⌘' goes through the ready ones, then the one that needs you, and round again: \([first, second, third, around].map { $0?.worktree.lastPathComponent ?? "-" })")
            expect(sessions.orderedSessions().map(\.worktree.lastPathComponent) == ["total-rounding", "trip-rename", "empty-inbox", "offline-banner", "settings-dark", "homesafe"]
                   && row("total-rounding").flatMap { sessions.shortcutIndex(for: $0) } == 1, "⌘1-9 pick rows in the order shown")

            // The person deals with one; the agent of another starts again; the permission is answered.
            let before = sent.count
            if let s = row("total-rounding") { sessions.markReviewed(s) }
            hook("claude", "trip-rename", "UserPromptSubmit")
            hook("codex", "empty-inbox", "PostToolUse")
            _ = await wait("the rows to move") { group("total-rounding") == .quiet && group("trip-rename") == .working && group("empty-inbox") == .working }
            await settle()
            expect(group("total-rounding") == .quiet, "Mark as Reviewed takes a session out of Ready")
            expect(group("trip-rename") == .working && group("empty-inbox") == .working, "a new turn, and a tool that ran after the permission: working again")
            expect(Notifier.badge == nil && wb.attentionText == "4 working" && sent.count == before, "nothing waits for the person now, and leaving a group is no news: \(wb.attentionText ?? "-")")
            hook("claude", "trip-rename", "Stop")
            _ = await wait("ready again") { group("trip-rename") == .ready }
            await settle()
            expect(group("trip-rename") == .ready && sent.count == before + 1, "its turn ends again on the same build and checks: ready again, and said once")
            hook("cursor", "total-rounding", "beforeSubmitPrompt")
            hook("cursor", "total-rounding", "stop")
            await settle()
            expect(group("total-rounding") == .quiet, "a turn that ends with no new check, after the person dealt with the session: quiet, not ready again")

            // An edit after the build: the build is no longer of the sources. (The check's clock runs ahead of the
            // real one, so the file is dated after the build by hand.)
            let edited = wt("trip-rename").appendingPathComponent("NOTES.md")
            try? "more\n".write(to: edited, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: clock.addingTimeInterval(3600)], ofItemAtPath: edited.path)
            sessions.refresh(supersede: true)
            let stale = await wait("the edit", 15) { row("trip-rename").map { !sessions.buildIsCurrent($0) } ?? false }
            expect(stale && group("trip-rename") == .quiet, "an edit after the build: the build is stale and the session is no longer ready (\(group("trip-rename")?.title ?? "-"))")

            // Notifications off, and in front: nothing is sent.
            let count = sent.count
            Notifier.inFront = { true }
            hook("codex", "offline-banner", "PermissionRequest")
            _ = await wait("needs") { group("offline-banner") == .needs }
            await settle()
            expect(sent.count == count, "with Greenroom in front nothing is sent")
            Notifier.inFront = { false }
            Notifier.set(false)
            hook("claude", "settings-dark", "Notification")
            _ = await wait("needs") { group("settings-dark") == .needs }
            await settle()
            expect(sent.count == count && Notifier.badge == "2", "with notifications off nothing is sent, and the badge still counts")

            // The grouping by repository, given back.
            sessions.groupByRepository = true
            await settle()
            expect(wb.sidebarOutline.first == "## homesafe" && !wb.sidebarOutline.contains { $0.hasPrefix("# Ready") || $0.hasPrefix("repo ") }, "Group Sessions by Repository gives the old sidebar back: \(wb.sidebarOutline.prefix(2))")
            expect(wb.attentionText == "2 need you · 1 working", "... and the top bar still counts: \(wb.attentionText ?? "-")")
            capture(dir.appendingPathComponent("repositories.png"))
            sessions.groupByRepository = false
            await settle()
            expect(wb.sidebarOutline.first == "# Needs you 2", "and back")

            // Kept across a restart of the app: what was noted is in the state folder.
            let path = row("trip-rename")?.worktree.path ?? ""
            let kept = WorkStore.shared.work(path)
            WorkStore.shared.reset()
            expect(!kept.checks.isEmpty && WorkStore.shared.work(path) == kept, "a session's checks and its turn's end are read back from the state folder")

            Notifier.deliver = nil
            if failures == 0 { try? fm.removeItem(at: base) }
            finish()
        }
    }
}
