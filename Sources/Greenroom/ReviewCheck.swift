import AppKit

/// `GREENROOM_STATE=EMPTY_DIR Greenroom --background --agent-check --review-check DIR`: the review side of the window
/// (docs/AGENT-FIRST-SPEC.md, A6). The rules by themselves (which criteria a check names, what a pull request's
/// state allows, the words an agent is given), the work file through a whole loop (a spec, checks that tick its
/// criteria, a review asked for and answered, comments given once, all read back from disk), then a temporary
/// repository with two worktrees in the window: the session panel on the chosen session in each state, Approve and
/// Request Changes through the panel's own functions, Mark as Reviewed taking a request back, and Merge with a
/// stand-in `gh` on the PATH (what it is asked, what it is told to do, a refusal said in its own words). No engine
/// is started and no real `gh` is run. The agent's side, a comment pinned to a node and the hooks' answers are
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
