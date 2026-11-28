import AppKit

/// `GREENROOM_STATE=EMPTY_DIR Greenroom --background --agent-check --review-check DIR`: the review side of the window
/// (docs/AGENT-FIRST-SPEC.md, A6). The rules by themselves (which criteria a check names, what a pull request's
/// state allows, the words an agent is given), the work file through a whole loop (a spec, checks that tick its
/// criteria, a review asked for and answered, comments given once, all read back from disk), then a temporary
/// repository with two worktrees in the window: the session panel on the chosen session in each state, Approve and
/// Request Changes through the panel's own functions, Mark as Reviewed taking a request back, and Merge with a
/// stand-in `gh` on the PATH (what it is asked, what it is told to do, a refusal said in its own words). Then what
/// A7 and A8 added that needs no simulator: the lane a call runs in and a device taken over, and CI watched for a
/// pushed commit (asked of the stand-in `gh`, shown in the loop, fetched by a stand-in `ci` recipe told to start no
/// workflow, told to the agent once). No engine is started and no real `gh` is run. The agent's side, a comment pinned to a node and the hooks' answers are
/// checked on real simulators by scripts/mcp-check.py --sessions. A picture is written to DIR (review.png).
/// One `[greenroom] review: ok|FAIL ...` line per step, then `review check: PASS|FAIL`; exits 0 or 1.
enum ReviewCheck {
    static func run(workbench wb: Workbench, dir: URL, capture: @escaping (URL) -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; print("[greenroom] review: \(ok ? "ok  " : "FAIL") \(what)"); fflush(stdout) }
            func settle(_ seconds: Double = 0.5) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            @MainActor func wait(_ what: String, _ seconds: Double = 20, _ cond: @MainActor () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
                print("[greenroom] review: timed out waiting for \(what)")
                return false
            }
            func finish() -> Never {
                print("review check: " + (failures == 0 ? "PASS" : "FAIL"))
                fflush(stdout)
                exit(failures == 0 ? 0 : 1)
            }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

            // MARK: The rules, by themselves

            typealias C = Work.Spec.Criterion
            let spec = Work.Spec(title: "t", text: "", criteria: [C(text: "The total rounds to two decimals"), C(text: "The trip can be renamed"), C(text: "The trip keeps its dates")], link: nil, at: Date())
            expect(spec.indices("2").found == [1] && spec.indices("2,3").found == [1, 2] && spec.indices("1 3").found == [0, 2], "a criterion is named by its number, or several")
            expect(spec.indices("9").found.isEmpty && spec.indices("9").unknown == ["9"] && spec.indices("2,9").found == [1], "a number the spec does not have is said, the others still count")
            expect(spec.indices("the trip can be renamed").found == [1] && spec.indices("rounds").found == [0], "... or by its words, or a part only it has")
            expect(spec.indices("The trip").found.isEmpty && spec.indices("The trip").unknown == ["The trip"], "words two criteria share name neither")

            let pr = #"{"number":12,"title":"Round the total","url":"https://github.com/example/homesafe/pull/12","state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","headRefOid":"abc1234def","baseRefName":"main","reviewDecision":"","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""},{"__typename":"StatusContext","state":"FAILURE"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"}]}"#
            let info = Merger.parse(pr)
            expect(info?.number == 12 && info?.head == "abc1234def" && info?.base == "main" && info?.passed == 2 && info?.failed == 1 && info?.pending == 1 && info?.review == nil,
                   "a pull request as gh says it: its commit, its base, its checks counted (\(info.map { "\($0.passed)/\($0.failed)/\($0.pending)" } ?? "-"))")
            expect(info?.checksLine == "1 of 4 checks failed", "its checks in a line: \(info?.checksLine ?? "-")")
            expect(Merger.methods(#"{"squashMergeAllowed":true,"mergeCommitAllowed":false,"rebaseMergeAllowed":true,"viewerDefaultMergeMethod":"REBASE"}"#) == [.rebase, .squash],
                   "only the ways the repository allows, the one it prefers first")
            var at = Session(worktree: URL(fileURLWithPath: "/x/wt"), workspace: URL(fileURLWithPath: "/x"), head: "abc1234def", dirty: false, ahead: 0)
            if var i = info {
                expect(Merger.block(i, session: at) == nil, "an open pull request at the session's commit can be merged")
                at.head = "fff0000aaa"
                expect(Merger.block(i, session: at)?.contains("push first") == true, "one at another commit cannot: what is merged is what was looked at")
                at.head = "abc1234def"
                i.isDraft = true
                expect(Merger.block(i, session: at)?.contains("draft") == true, "a draft cannot")
                i.isDraft = false; i.mergeable = "CONFLICTING"
                expect(Merger.block(i, session: at) == "It has conflicts with main", "one with conflicts cannot")
                i.mergeable = "MERGEABLE"; i.state = "MERGED"
                expect(Merger.block(i, session: at) == "Merged", "a merged one says so")
                i.state = "OPEN"; i.review = "CHANGES_REQUESTED"
                let w = Merger.warnings(i, session: at, approved: false, criteria: (failed: 1, unchecked: 0))
                expect(w == ["1 of 4 checks failed on GitHub.", "A reviewer on GitHub asked for changes.", "You have not approved this commit in Greenroom.", "1 of the spec's criteria failed."],
                       "what the person is told before a merge: \(w)")
            }
            let pinned = Work.Comment(id: "c1", text: "This is cut off", at: Date(), pin: Work.Comment.Pin(label: "Total", frame: [10, 20, 300, 80], screen: "CartActivity", picture: nil))
            let plain = Work.Comment(id: "c2", text: "And two lines\nof it", at: Date())
            var answered = Work.Review(summary: "", asked: Date())
            answered.answer = .changes
            expect(WorkStore.words((answered, [pinned, plain])).text == "changes requested:\n- This is cut off\n  pinned to \"Total\" [10,20,300,80] on CartActivity\n- And two lines\n  of it",
                   "the words an agent is given: the answer, each comment, a pinned one with its node")
            expect(WorkStore.words((nil, [plain])).text.hasPrefix("1 comment from the person:") && WorkStore.words((answered, [])).text.contains("left no comment"), "comments alone, and changes asked for with none")
            answered.answer = .approved
            expect(WorkStore.words((answered, [])).text == "approved", "an approval is one word")

            // Taking one session's device over, and the lanes calls run in.
            expect(AttentionState.judge(AttentionFacts(working: "Codex", taken: true)) == AttentionState(group: .needs, line: "You have the device: hand it back", tone: .warn),
                   "a session whose device the person took over needs them, to hand it back")
            let tools = AgentTools()
            tools.takeOver("/x/wt")
            expect(tools.takenSince("/x/wt") != nil && tools.takenSince("/x/other") == nil, "taking over is one session's, not every agent's")
            tools.handBack("/x/wt")
            expect(tools.takenSince("/x/wt") == nil && tools.takeNotice("/x/wt") == nil, "handing back an agent that was never refused tells it nothing")
            func lane(_ name: String?, _ args: [String: Any] = [:], cwd: String = "/x/wt", parent: Int32 = 7) -> String {
                let m: [String: Any] = name.map { ["method": "tools/call", "params": ["name": $0, "arguments": args]] } ?? ["method": "tools/list"]
                return AgentServer.laneKey(m, hint: (URL(fileURLWithPath: cwd), parent), tools: tools)
            }
            expect(lane("tap", ["sim": "s3", "text": "Add"]) == "sim:s3" && lane("screen", ["sim": "s4"]) == "sim:s4", "calls on a simulator run in that simulator's lane, one at a time")
            expect(lane("session") == "agent:7|/x/wt" && lane(nil) == "agent:7|/x/wt" && lane("session", cwd: "/x/other", parent: 9) == "agent:9|/x/other", "an agent's other calls run in its own lane, beside other agents'")
            expect(lane("launch") == "launch:/x/wt" && lane("launch", ["apk": "/y/app.apk"]) == "launch:/y/app.apk", "a launch waits in a lane of its own target")

            // MARK: First run is left

            await settle()
            if wb.connectShown {
                wb.window.makeFirstResponder(nil)
                wb.connectFlow.onDone?()
                await settle()
            }

            // MARK: A repository, two worktrees, and a stand-in gh

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
            let base = dir.resolvingSymlinksInPath().appendingPathComponent("review-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
            let repo = base.appendingPathComponent("homesafe", isDirectory: true)
            try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
            try? "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            guard git(["init", "-q", "-b", "main"], in: repo), git(["add", "."], in: repo), git(["commit", "-q", "-m", "first"], in: repo),
                  git(["remote", "add", "origin", "https://github.com/example/homesafe.git"], in: repo) else {
                expect(false, "could not make the repository (is /usr/bin/git there?)"); finish()
            }
            let names = ["trip-rename", "total-rounding"]
            func wt(_ n: String) -> URL { base.appendingPathComponent(n, isDirectory: true) }
            for n in names {
                guard git(["worktree", "add", "-q", "-b", "feat/" + n, wt(n).path], in: repo) else { expect(false, "could not make worktree \(n)"); finish() }
            }
            // gh, played by a script: it answers from files, and writes down what it was asked.
            let bin = base.appendingPathComponent("bin", isDirectory: true)
            try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let ghLog = base.appendingPathComponent("gh.log"), prFile = base.appendingPathComponent("pr.json"), refuse = base.appendingPathComponent("refuse")
            let script = """
            #!/bin/sh
            echo "$*" >> "\(ghLog.path)"
            case "$1 $2" in
              "run list") if [ -f "\(base.path)/runs-$4.json" ]; then cat "\(base.path)/runs-$4.json"; else echo "[]"; fi ;;
              "pr view") if [ -f "\(prFile.path)" ]; then cat "\(prFile.path)"; else echo "no pull requests found for branch" >&2; exit 1; fi ;;
              "repo view") echo '{"squashMergeAllowed":true,"mergeCommitAllowed":true,"rebaseMergeAllowed":false,"viewerDefaultMergeMethod":"SQUASH"}' ;;
              "pr merge") if [ -f "\(refuse.path)" ]; then echo "X Pull request is not mergeable: the base branch policy prohibits the merge." >&2; exit 1; fi
                          sed -i '' 's/"OPEN"/"MERGED"/' "\(prFile.path)" ;;
              *) exit 1 ;;
            esac
            """
            try? script.write(to: bin.appendingPathComponent("gh"), atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("gh").path)
            LoginEnvironment.override = ["PATH": bin.path + ":/usr/bin:/bin"]
            func asked() -> [String] { ((try? String(contentsOf: ghLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

            let sessions = wb.sessions
            let hooks = HookSessions.shared
            hooks.reset()
            Notifier.deliver = { _, _, _ in }
            Notifier.inFront = { false }
            var clock = Date()
            WorkStore.now = { clock }
            HookSessions.now = { clock }
            _ = await sessions.addRepository(repo).value
            _ = await wait("the rows") { sessions.sessions.count == names.count + 1 && sessions.sessions.allSatisfy { !$0.head.isEmpty } }
            sessions.showAll(in: repo)
            func row(_ n: String) -> Session? { sessions.sessions.first { $0.worktree.lastPathComponent == n } }
            guard let trip = row("trip-rename"), let total = row("total-rounding") else { expect(false, "the worktrees are listed"); finish() }
            sessions.setAuto(.off, for: trip)
            let review = wb.review
            let store = WorkStore.shared
            func choose(_ s: Session) { sessions.focus = s.worktree.path; wb.reloadReview() }
            func state() -> SessionPanelState? { review.model.state }
            func build(_ s: Session) {
                sessions.adopt(Build(key: "key-" + s.worktree.lastPathComponent, apk: base.appendingPathComponent("none.apk"), source: .local, sha: s.head, ref: s.branch, dirty: false, date: clock), forWorktree: s.worktree.path)
            }
            let tripPath = trip.worktree.path, totalPath = total.worktree.path

            // MARK: The panel, on the chosen session

            wb.window.setContentSize(NSSize(width: 1380, height: 900))
            choose(total)
            await settle()
            expect(state()?.title == "feat/total-rounding" && state()?.repository == "homesafe" && state()?.verdict == SessionPanelState.Verdict.none && state()?.headline == "Quiet",
                   "the panel is about the session the person chose: \(state()?.title ?? "-"), \(state()?.headline ?? "-")")
            expect(state()?.specTitle == nil && state()?.criteria.isEmpty == true && state()?.canAnswer == true, "with no spec it says the agent declared none")
            expect(!wb.sessionPanelShown && review.stripView.isHidden, "nothing opens by itself for a quiet session, and with no simulator there is no loop strip")

            // A spec, and checks that tick its criteria.
            build(trip)
            store.setSpec(tripPath, title: "Rename a trip", text: "A trip can be renamed from its detail screen.", criteria: ["The trip can be renamed", "The trip keeps its dates", "The total rounds to two decimals"], link: "https://example.invalid/issues/7")
            clock = clock.addingTimeInterval(30)
            store.noteCheck(tripPath, passed: true, summary: "PASS | TripActivity", build: "key-trip-rename", criteria: [0])
            store.noteCheck(tripPath, passed: false, summary: "FAIL | TripActivity | not on screen: \"3 nights\"", build: "key-trip-rename", criteria: [1], why: "not on screen: \"3 nights\"")
            clock = clock.addingTimeInterval(120)
            choose(trip)
            await settle()
            let c = state()?.criteria ?? []
            expect(state()?.specTitle == "Rename a trip" && c.count == 3 && c[0].state == .passed && c[0].detail == "Passed 2 min ago"
                   && c[1].state == .failed && c[1].detail == "Failed 2 min ago · not on screen: \"3 nights\"" && c[2].detail == "Not checked yet",
                   "the spec with each criterion as it stands: \(c.map(\.detail))")
            expect(sessions.loop(for: trip).first?.state == .done && sessions.loop(for: trip).first?.detail == "3 criteria", "the loop's first step is done: \(sessions.loop(for: trip).first?.detail ?? "-")")
            store.setSpec(tripPath, title: "Rename a trip", text: "", criteria: ["The trip can be renamed", "The trip keeps its dates and nights"], link: nil)
            expect(store.work(tripPath).spec?.criteria.map(\.state) == [.passed, Work.Spec.Criterion.State.none], "a spec declared again keeps the tick of a criterion whose words did not change")
            store.noteCheck(tripPath, passed: true, summary: "PASS | TripActivity", build: "key-older", criteria: [1])
            wb.reloadReview()
            expect(state()?.criteria.last?.detail.hasSuffix("on an older build") == true, "a tick from an older build says so: \(state()?.criteria.last?.detail ?? "-")")

            // The agent asks for a review; the person goes to the session.
            choose(total)
            store.askReview(tripPath, summary: "Renaming works; the dates stay.")
            await settle()
            expect(sessions.attention(of: trip).group == .ready && wb.sidebarOutline.first == "# Ready for review 1", "a session that asked is ready for review: \(wb.sidebarOutline.prefix(2))")
            choose(trip)
            await settle(0.8)
            expect(wb.sessionPanelShown, "going to a session that waits for a review opens its panel")
            expect(state()?.verdict == .asked && state()?.headline == "Ready for review" && state()?.summary == "Renaming works; the dates stay." && state()?.canAnswer == true,
                   "it says what the agent said: \(state()?.summary ?? "-")")
            store.askReview(tripPath, summary: nil)
            expect(store.work(tripPath).review?.summary == "Renaming works; the dates stay.", "asking again joins the same request")
            capture(dir.appendingPathComponent("review.png"))

            // Request Changes needs something said.
            review.requestChanges()
            expect(store.work(tripPath).reviewWaiting != nil && wb.lastSaid.hasPrefix("Say what to change first"), "Request Changes with nothing written asks for a comment first")
            review.model.draft = "The nights are missing under the dates"
            review.requestChanges()
            await settle()
            var w = store.work(tripPath)
            expect(w.review?.answer == .changes && w.pending.count == 1 && review.model.draft.isEmpty, "with a comment written it is sent with the answer")
            expect(state()?.verdict == .changes && state()?.headline.hasPrefix("Changes requested") == true && state()?.canAnswer == false
                   && state()?.answerNote == "The agent hears it with its next call, or when its turn ends.", "the panel says what was answered, and that the agent has not heard yet")
            expect(sessions.attention(of: trip).group != .ready && state()?.comments.first?.status == "Not given yet" && state()?.comments.first?.pending == true, "the session is no longer waiting for the person")
            let given = store.deliver(tripPath, via: "review")
            expect(given.map { WorkStore.words($0).text } == "changes requested:\n- The nights are missing under the dates", "the agent is given the answer and the comment")
            expect(store.deliver(tripPath, via: "review") == nil, "... once")
            wb.reloadReview()
            expect(state()?.answerNote == "The agent has been told." && state()?.comments.first?.status == "Given just now, with the answer to its review", "and the panel says it was told: \(state()?.comments.first?.status ?? "-")")
            let id = store.work(tripPath).comments.first?.id ?? ""
            store.removeComment(tripPath, id: id)
            expect(store.work(tripPath).comments.count == 1, "a comment the agent was given cannot be taken back")
            review.model.draft = "One more thing"
            review.send()
            let pending = store.work(tripPath).pending.first?.id ?? ""
            review.remove(pending)
            expect(store.work(tripPath).comments.count == 1 && store.work(tripPath).pending.isEmpty, "one it was not given can")

            // It asks again, and is approved: for the commit the session is at.
            clock = clock.addingTimeInterval(60)
            store.askReview(tripPath, summary: "Nights added.")
            wb.reloadReview()
            expect(state()?.verdict == .asked && state()?.canAnswer == true, "asked again, the answer is wanted again")
            review.approve()
            await settle()
            w = store.work(tripPath)
            expect(w.review?.answer == .approved && w.review?.head == trip.head && sessions.approvalStands(trip), "Approve answers it, for the commit the session is at")
            expect(state()?.verdict == .approved && state()?.headline.hasPrefix("Approved") == true && sessions.loop(for: trip).last?.detail == "approved", "the panel and the loop say approved")
            expect(store.deliver(tripPath, via: "turn end").map { WorkStore.words($0).text } == "approved", "the agent is told: approved")

            // Ready by its turn's end, with no review asked for: the answer is kept for the agent all the same.
            build(total)
            hooks.heard(HookLog.Event(time: clock, harness: "codex", session: "s-total", cwd: total.worktree, event: "UserPromptSubmit"))
            store.noteCheck(totalPath, passed: true, summary: "PASS | CartActivity", build: "key-total-rounding")
            clock = clock.addingTimeInterval(20)
            hooks.heard(HookLog.Event(time: clock, harness: "codex", session: "s-total", cwd: total.worktree, event: "Stop"))
            _ = await wait("total-rounding ready") { sessions.attention(of: total).group == .ready }
            choose(total)
            await settle()
            expect(state()?.verdict == .ready && state()?.summary == "Its turn ended on a build of the sources as they are. 1 of 1 check passed.", "a turn that ended with checks is ready, and says why: \(state()?.summary ?? "-")")
            review.approve()
            await settle()
            expect(store.work(totalPath).answerWaiting?.answer == .approved && sessions.attention(of: total).group != .ready, "approving it keeps the answer for the agent, and the session is dealt with")
            hooks.heard(HookLog.Event(time: clock, harness: "codex", session: "s-total", cwd: total.worktree, event: "Stop"), continues: true)
            expect(hooks.midTurn(in: total.worktree), "a turn's end answered with what the person said leaves the session working")

            // Mark as Reviewed takes a waiting request back.
            clock = clock.addingTimeInterval(60)
            store.askReview(totalPath, summary: "Rounded.")
            expect(sessions.attention(of: total).group == .ready, "it asks")
            sessions.markReviewed(total)
            expect(store.work(totalPath).review == nil && sessions.attention(of: total).group != .ready, "Mark as Reviewed takes the request back")

            // Read back from disk.
            let kept = store.work(tripPath)
            store.reset()
            expect(store.work(tripPath) == kept && kept.spec != nil && kept.review != nil && kept.comments.count == 1, "the spec, the review and the comments are read back from the session's work file")

            // MARK: Merge, through a stand-in gh

            func writePR(head: String, state: String = "OPEN", checks: String = #"[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]"#) {
                let json = #"{"number":12,"title":"Rename a trip","url":"https://github.com/example/homesafe/pull/12","state":"\#(state)","isDraft":false,"mergeable":"MERGEABLE","headRefOid":"\#(head)","baseRefName":"main","reviewDecision":"","statusCheckRollup":\#(checks)}"#
                try? json.write(to: prFile, atomically: true, encoding: .utf8)
            }
            choose(total)
            _ = await wait("no pull request") { asked().contains { $0.hasPrefix("pr view feat/total-rounding") } }
            await settle()
            expect(review.model.merge == MergeLine(), "a branch with no pull request shows no Merge")
            writePR(head: trip.head)
            clock = clock.addingTimeInterval(120)
            choose(trip)
            _ = await wait("the pull request") { review.model.merge.number == 12 && review.model.merge.canMerge }
            expect(review.model.merge.canMerge && review.model.merge.detail == "2 checks passed · can be merged into main" && review.model.merge.title == "Rename a trip",
                   "the session's pull request, read from gh: \(review.model.merge.detail)\(review.model.merge.blocked)")
            var question = ""
            var offered: [Merger.Method] = []
            Merger.answerForCheck = { text, methods in question = text; offered = methods; return nil }
            review.merge()
            await settle()
            expect(!asked().contains { $0.hasPrefix("pr merge") } && question.hasPrefix("\u{201C}Rename a trip\u{201D} into main, as your GitHub account. 2 checks passed on GitHub.") && offered == [.squash, .merge],
                   "Merge asks first, saying what and as whom, and offers the repository's ways: \(question) \(offered.map(\.rawValue))")
            expect(question.contains("1 of the spec's criteria") == false && !question.contains("You have not approved"), "an approved commit with its criteria checked carries no warning")
            try? "".write(to: refuse, atomically: true, encoding: .utf8)
            Merger.answerForCheck = { _, methods in methods.first }
            review.merge()
            _ = await wait("gh's refusal") { wb.lastSaid.hasPrefix("Not merged") }
            expect(wb.lastSaid == "Not merged: X Pull request is not mergeable: the base branch policy prohibits the merge.", "a merge GitHub refuses is said in gh's own words: \(wb.lastSaid)")
            try? fm.removeItem(at: refuse)
            _ = await wait("merge offered again") { review.model.merge.canMerge }
            review.merge()
            _ = await wait("the merge") { wb.lastSaid.hasPrefix("Merged") }
            expect(asked().last { $0.hasPrefix("pr merge") } == "pr merge 12 --squash --match-head-commit \(trip.head)", "it merges that pull request, that way, at the commit the session is at: \(asked().last { $0.hasPrefix("pr merge") } ?? "-")")
            _ = await wait("merged shown") { review.model.merge.merged }
            expect(wb.lastSaid == "Merged #12 into main" && review.model.merge.merged && !review.model.merge.canMerge && review.model.merge.blocked == "Merged", "and the panel says it is merged")
            // A commit nobody approved here, with a failing check on GitHub: the question says both.
            writePR(head: total.head, checks: #"[{"__typename":"StatusContext","state":"FAILURE"}]"#)
            clock = clock.addingTimeInterval(120)
            choose(total)
            _ = await wait("total's pull request") { review.model.merge.canMerge }
            Merger.answerForCheck = { text, _ in question = text; return nil }
            review.merge()
            await settle()
            expect(question.contains("1 of 1 check failed on GitHub.") && question.contains("You have not approved this commit in Greenroom."), "what is not right is said before the person says yes: \(question)")
            expect(!AgentTools.tools.contains { $0.name.contains("merge") || $0.name == "approve" }, "no tool of the agent interface merges or approves")

            // MARK: CI, watched for a pushed session (A8)

            let run1 = CIWatch.Run(id: 4812, status: "in_progress", conclusion: "", workflow: "Build", url: nil, created: clock.addingTimeInterval(-200))
            let done = CIWatch.Run(id: 4811, status: "completed", conclusion: "success", workflow: "Lint", url: nil, created: clock.addingTimeInterval(-200))
            let bad = CIWatch.Run(id: 9, status: "completed", conclusion: "failure", workflow: "Build", url: nil, created: nil)
            expect(CIWatch.line(CIWatch.Entry(sha: "a", runs: [run1], first: clock), now: clock) == "CI run 4812 · 3 min"
                   && CIWatch.line(CIWatch.Entry(sha: "a", runs: [run1, done], first: clock), now: clock) == "CI · 1 of 2 runs done · 3 min"
                   && CIWatch.line(CIWatch.Entry(sha: "a", runs: [bad, done], first: clock), now: clock) == "CI run 9 failed"
                   && CIWatch.line(CIWatch.Entry(sha: "a", runs: [done], first: clock), now: clock) == nil, "a commit's runs in a line: going, several, failed, and nothing to say once passed")
            let listed = CIWatch.parse(#"[{"databaseId":1,"status":"completed","conclusion":"success","workflowName":"Build APK","headSha":"aaa","url":"u","createdAt":"2026-11-27T10:00:00Z"},{"databaseId":2,"status":"queued","conclusion":"","workflowName":"Lint","headSha":"aaa"},{"databaseId":3,"status":"completed","conclusion":"failure","workflowName":"Lint","headSha":"bbb"}]"#, sha: "aaa")
            expect(listed.map(\.id) == [1, 2] && listed[0].created != nil && CIWatch.counted(listed, workflow: "build-apk.yml").count == 2 && CIWatch.counted(listed, workflow: ".github/workflows/lint.yml").map(\.id) == [2],
                   "only the commit's own runs count, and the set workflow's when it has some")

            let watch = sessions.ciWatch
            CIWatch.now = { clock }
            func upstream(_ s: Session) -> Bool {
                guard let branch = s.branch else { return false }
                return git(["update-ref", "refs/remotes/origin/" + branch, "HEAD"], in: s.worktree)
                    && git(["config", "branch.\(branch).remote", "origin"], in: s.worktree) && git(["config", "branch.\(branch).merge", "refs/heads/" + branch], in: s.worktree)
            }
            func runs(_ sha: String, _ status: String, _ conclusion: String, id: Int) {
                let json = #"[{"databaseId":\#(id),"status":"\#(status)","conclusion":"\#(conclusion)","workflowName":"Build","headSha":"\#(sha)","url":"https://github.com/example/homesafe/actions/runs/\#(id)","createdAt":"2026-11-27T10:00:00Z"}]"#
                try? json.write(to: base.appendingPathComponent("runs-\(sha).json"), atomically: true, encoding: .utf8)
            }
            func listings() -> Int { asked().filter { $0.hasPrefix("run list") }.count }
            func tick() async { watch.tick(); _ = await wait("GitHub's answer") { !watch.busy }; await settle(0.2) }
            // A commit nobody pushed is not asked about.
            await tick()
            expect(listings() == 0 && watch.entry(for: tripPath)?.runs.isEmpty != false, "GitHub is not asked about a session whose commit is not pushed")
            // A new commit, pushed, with a run going.
            guard git(["commit", "-q", "--allow-empty", "-m", "nights"], in: trip.worktree), upstream(trip) else { expect(false, "could not commit and push in the worktree"); finish() }
            sessions.refresh(supersede: true)
            _ = await wait("the new commit") { row("trip-rename")?.head != trip.head && row("trip-rename")?.ahead == 0 }
            guard let trip2 = row("trip-rename") else { finish() }
            runs(trip2.head, "in_progress", "", id: 4812)
            await tick()
            expect(watch.entry(for: tripPath)?.active == true && listings() == 1, "a pushed commit's runs are asked of GitHub, unasked: \(watch.entry(for: tripPath)?.runs.map(\.status) ?? [])")
            let building = sessions.attention(of: trip2)
            expect(building.group == .working && building.line.hasPrefix("CI run 4812"), "while CI builds it the session is working, and says so: \(building.line)")
            expect(sessions.loop(for: trip2)[2].state == .going && sessions.loop(for: trip2)[2].detail.hasPrefix("CI run 4812"), "the loop's Build step shows the run: \(sessions.loop(for: trip2)[2].detail)")
            await tick()
            expect(listings() == 1, "GitHub is not asked again within half a minute")
            clock = clock.addingTimeInterval(31)
            await tick()
            expect(listings() == 2, "... and is after it")
            // It passes. A repository not known to build its APK on CI: nothing is fetched, and the agent is told.
            runs(trip2.head, "completed", "success", id: 4812)
            clock = clock.addingTimeInterval(31)
            await tick()
            expect(watch.entry(for: tripPath)?.passed == true && sessions.buildQueue.job(for: trip2) == nil, "runs that passed in a repository that builds nothing on CI fetch nothing")
            expect(wb.agentTools?.takeNotice(tripPath) == "CI passed for \(trip2.head.prefix(7)).", "the agent is told it passed")
            clock = clock.addingTimeInterval(120)
            await tick()
            expect(listings() == 3 && wb.agentTools?.takeNotice(tripPath) == nil, "a commit whose runs are over is not asked about again, and nothing is told twice")
            // A repository that builds on CI (an artifact is named for it): the APK is fetched, by the ci recipe, told to start nothing.
            let envFile = base.appendingPathComponent("recipe-env.txt"), fake = base.appendingPathComponent("ci.apk")
            try? Data("not an apk, for a check: \(UUID().uuidString)".utf8).write(to: fake)
            let recipe = base.appendingPathComponent("ci-recipe.sh")
            try? "#!/bin/sh\nenv | grep '^GREENROOM_' | sort > \"\(envFile.path)\"\ncp \"\(fake.path)\" \"$GREENROOM_OUT\"\n".write(to: recipe, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recipe.path)
            if let i = sessions.workspaces.firstIndex(where: { $0.root.path == repo.path }) {
                sessions.workspaces[i].recipes["ci"] = Recipe(executable: recipe.path)
                sessions.workspaces[i].ci.artifact = "app-debug"
            }
            guard git(["commit", "-q", "--allow-empty", "-m", "more"], in: trip.worktree), upstream(trip) else { expect(false, "could not commit again"); finish() }
            sessions.refresh(supersede: true)
            _ = await wait("the newer commit") { row("trip-rename")?.head != trip2.head && row("trip-rename")?.ahead == 0 }
            guard let trip3 = row("trip-rename") else { finish() }
            runs(trip3.head, "completed", "success", id: 4900)
            await tick()
            _ = await wait("CI's build", 60) { row("trip-rename").flatMap { sessions.currentBuild(of: $0) }.map { $0.source == .ci && $0.sha == trip3.head } ?? false }
            let fetched = row("trip-rename").flatMap { sessions.currentBuild(of: $0) }
            expect(fetched?.source == .ci && fetched?.sha == trip3.head, "when the runs pass, the APK is fetched and becomes the session's build: \(fetched.map { "\($0.source.rawValue) \($0.sha?.prefix(7) ?? "-")" } ?? "none")")
            let env = (try? String(contentsOf: envFile, encoding: .utf8)) ?? ""
            expect(env.contains("GREENROOM_CI_DISPATCH=0") && env.contains("GREENROOM_SHA=\(trip3.head)") && !asked().contains { $0.hasPrefix("workflow") },
                   "the recipe is told to start no workflow, and none was started")
            await tick()
            expect(wb.agentTools?.takeNotice(tripPath) == "CI built \(trip3.head.prefix(7)): Greenroom fetched its APK (build \(fetched?.key ?? "-")), and the session's simulator runs it.", "the agent is told its build is there")
            // A run that fails: said once, with where to read it.
            guard upstream(total) else { expect(false, "could not push the other worktree"); finish() }
            guard git(["commit", "-q", "--allow-empty", "-m", "round"], in: total.worktree), upstream(total) else { expect(false, "could not commit in the other worktree"); finish() }
            sessions.refresh(supersede: true)
            _ = await wait("total's commit") { row("total-rounding")?.head != total.head && row("total-rounding")?.ahead == 0 }
            guard let total2 = row("total-rounding") else { finish() }
            runs(total2.head, "completed", "failure", id: 77)
            await tick()
            let failedLine = "CI failed for \(total2.head.prefix(7)): run 77 (Build) ended in failure. https://github.com/example/homesafe/actions/runs/77"
            expect(wb.agentTools?.takeNotice(totalPath) == failedLine, "a failed run is told to the agent, with where to read it")
            expect(sessions.loop(for: total2)[2].state == .failed && sessions.loop(for: total2)[2].detail == "CI run 77 failed" && watch.said(for: totalPath)?.hasPrefix("ci: run 77 (Build) failed") == true,
                   "and the loop's Build step says it failed: \(sessions.loop(for: total2)[2].detail)")
            await tick()
            expect(wb.agentTools?.takeNotice(totalPath) == nil, "... once")
            // The person's switch.
            CIWatch.enabled = false
            await tick()
            expect(watch.entry(for: tripPath) == nil && watch.entry(for: totalPath) == nil, "with the switch off nothing is watched")
            CIWatch.enabled = true
            CIWatch.now = { Date() }

            Merger.answerForCheck = nil
            LoginEnvironment.override = nil
            WorkStore.now = { Date() }
            HookSessions.now = { Date() }
            hooks.reset()
            try? fm.removeItem(at: base)
            finish()
        }
    }
}
