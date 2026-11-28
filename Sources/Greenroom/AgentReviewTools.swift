import AppKit

/// The tools of the loop's two ends (docs/AGENT-FIRST-SPEC.md, A6): `spec` says what a session is for before the
/// work, `check` ticks its criteria, `review` says the work is done and waits for the person's answer, `feedback`
/// reads what the person said. What the person says also reaches the agent without being asked for: with the answer
/// of a waiting `review`, when the turn ends (its harness's hook), and at the end of the next tool's answer.
extension AgentTools {
    static let reviewTools: [Tool] = [
        ("spec", "Say what this session is for, before you start: a title, the text, and the acceptance criteria you will check. "
            + "The person sees it in Greenroom beside the simulator, each criterion ticked as check passes it. Calling it again "
            + "replaces it (a criterion whose words did not change keeps its tick). Without arguments answers the spec as it stands.",
         schema(["title": ["type": "string", "description": "a few words: what changes"],
                 "text": ["type": "string", "description": "the task as you understand it, in a few sentences"],
                 "criteria": ["type": "array", "items": ["type": "string"], "description": "what must be true when you are done, one checkable sentence each"],
                 "link": ["type": "string", "description": "the issue or pull request it comes from, if any"]], sim: false)),
        ("review", "Say you are done and ask the person to look: Greenroom files the session as ready for review, with the spec, each "
            + "criterion's check and the recording of what you did. Waits for their answer: approved, or changes requested with their "
            + "comments (some pinned to a node of the screen, with a picture). If they have not answered when the wait ends it says so: "
            + "end your turn (their answer reaches you with your next call or your turn's end) or call review again, which joins the same request. "
            + "Only the person approves and merges; nothing here does.",
         schema(["summary": ["type": "string", "description": "what you did and what you checked, in a few sentences"],
                 "timeout_s": ["type": "integer", "description": "how long this call waits, 10-1800 s (default 200)"]], sim: false)),
        ("feedback", "What the person told you that you have not been given: their answer to your review and their comments, a pinned "
            + "one with its node and a picture. all answers every comment of this session again.",
         schema(["all": bool], sim: false)),
    ]

    /// Tools that neither act on a simulator nor change the app: a paused agent may still say what it is doing
    /// and hear the person.
    static let talk: Set<String> = ["spec", "review", "feedback"]

    func reviewCall(_ name: String, _ args: [String: Any], _ connection: Connection) throws -> [[String: Any]]? {
        switch name {
        case "spec": return text(try specTool(args, connection))
        case "review": return try reviewTool(args, connection)
        case "feedback": return try feedbackTool(args, connection)
        default: return nil
        }
    }

    // MARK: spec

    private func specTool(_ args: [String: Any], _ connection: Connection) throws -> String {
        let (s, _) = try tied(connection)
        let path = s.worktree.path
        let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let criteria = (args["criteria"] as? [String])?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let link = (args["link"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let declares = !title.isEmpty || !body.isEmpty || criteria != nil || link != nil
        if declares {
            let old = mainSync { WorkStore.shared.work(path).spec }
            guard !(title.isEmpty && old == nil) else { throw Failure(message: "spec needs a title: a few words for what changes") }
            if let criteria, criteria.count > 40 { throw Failure(message: "a spec holds 40 criteria at most: say the ones the person will care about") }
            if let criteria, Set(criteria).count != criteria.count { throw Failure(message: "two criteria say the same: each is checked on its own") }
            mainSync {
                WorkStore.shared.setSpec(path, title: title.isEmpty ? old!.title : String(title.prefix(200)),
                                         text: args["text"] == nil ? (old?.text ?? "") : String(body.prefix(4000)),
                                         criteria: (criteria ?? old?.criteria.map(\.text) ?? []).map { String($0.prefix(400)) },
                                         link: args["link"] == nil ? old?.link : (link?.isEmpty == true ? nil : link))
            }
        }
        guard let spec = mainSync({ WorkStore.shared.work(path).spec }) else {
            return "no spec yet: call spec with a title, the text and the criteria you will check"
        }
        let build = mainSync { self.workbench?.sessions.currentBuild(of: s)?.key }
        var lines = [(declares ? "the person now sees: " : "") + spec.title]
        if !spec.text.isEmpty { lines.append(spec.text) }
        if let l = spec.link { lines.append("from \(l)") }
        for (i, c) in spec.criteria.enumerated() { lines.append("\(i + 1). \(Self.mark(c, on: build)) \(c.text)" + (c.note.map { " (\($0))" } ?? "")) }
        if spec.criteria.isEmpty { lines.append("no criteria: say them, and check each with check's criterion") }
        else if declares { lines.append("tick each with check: criterion is its number") }
        return lines.joined(separator: "\n")
    }

    /// How a criterion stands, in a word.
    static func mark(_ c: Work.Spec.Criterion, on build: String?) -> String {
        switch c.state {
        case .none: return "[ ]"
        case .passed: return c.build == build ? "[passed]" : "[passed on an older build]"
        case .failed: return c.build == build ? "[FAILED]" : "[failed on an older build]"
        }
    }

    // MARK: check, for a criterion

    /// `check` answered: it counts for the session whose simulator it looked at, else the caller's (WorkStore), and
    /// ticks the criteria it named. Answers the lines to add to the tool's answer about those.
    func noteCheck(_ line: String, _ args: [String: Any], _ connection: Connection) -> String? {
        let sim = currentSim ?? (try? self.sim(args))
        let named: String? = (args["criterion"] as? String) ?? (args["criterion"] as? Int).map(String.init)
        return mainSync {
            guard let sessions = self.workbench?.sessions else { return nil }
            guard let s = sim.flatMap({ sessions.session(forSimulator: $0) }) ?? connection.session else {
                return named == nil ? nil : "criterion: this simulator belongs to no session, so nothing was ticked"
            }
            let path = s.worktree.path
            let passed = line.hasPrefix("PASS")
            var said: [String] = [], found: [Int] = []
            if let named, !named.trimmingCharacters(in: .whitespaces).isEmpty {
                if let spec = WorkStore.shared.work(path).spec {
                    let r = spec.indices(named)
                    found = r.found
                    for i in r.found { said.append("criterion \(i + 1) \(passed ? "passed" : "FAILED"): \(spec.criteria[i].text)") }
                    for u in r.unknown { said.append("no criterion \(ScreenNode.quote(u)): the spec has \(spec.criteria.count) (call spec)") }
                } else {
                    said.append("criterion: this session has no spec yet (call spec first)")
                }
            }
            let why = passed ? nil : line.split(separator: "|").dropFirst(2).joined(separator: "|").trimmingCharacters(in: .whitespaces)
            WorkStore.shared.noteCheck(path, passed: passed, summary: line, build: sessions.currentBuild(of: s)?.key, criteria: found,
                                       why: (why?.isEmpty ?? true) ? nil : why, moment: self.recording.moment(for: path))
            if !found.isEmpty, let spec = WorkStore.shared.work(path).spec {
                let left = spec.criteria.filter { $0.state == .none }.count
                let failed = spec.criteria.filter { $0.state == .failed }.count
                if left == 0, failed == 0 { said.append("every criterion has passed: call review when you are done") }
                else { said.append("\(left) not checked yet" + (failed > 0 ? ", \(failed) failed" : "")) }
            }
            return said.isEmpty ? nil : said.joined(separator: "\n")
        }
    }

    // MARK: review

    private func reviewTool(_ args: [String: Any], _ connection: Connection) throws -> [[String: Any]] {
        let (s, _) = try tied(connection)
        let path = s.worktree.path
        let summary = (args["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wait = TimeInterval(min(max((args["timeout_s"] as? Int) ?? 200, 10), 1800))
        // An answer already given for the commit the session is at (the person approved before being asked) is
        // the answer. One given for an older commit is not: the work changed since, so they are asked again.
        let standing: Bool = mainSync {
            let w = WorkStore.shared.work(path)
            if let a = w.answerWaiting, a.head == nil || a.head == s.head { return true }
            WorkStore.shared.askReview(path, summary: summary.map { String($0.prefix(4000)) })
            return false
        }
        if !standing {
            mainSync { self.workbench?.agentChanged() }
            let end = Date().addingTimeInterval(wait)
            while Date() < end {
                if mainSync({ WorkStore.shared.work(path).answerWaiting != nil }) { break }
                // The person can also take the request back by marking the session reviewed.
                if mainSync({ WorkStore.shared.work(path).review == nil }) { return text("the person dismissed the request without an answer") }
                Thread.sleep(forTimeInterval: Engine.agentCheck ? 0.05 : 0.3)
            }
        }
        guard let given = mainSync({ WorkStore.shared.deliver(path, via: "review") }), given.answer != nil else {
            return text("still waiting: the person has not answered after \(Int(wait)) s. The session stays ready for review in Greenroom. "
                + "End your turn: their answer reaches you with your next call or your turn's end; or call review again to keep waiting.")
        }
        return Self.blocks(given)
    }

    /// What the person said, as content blocks: the words, then the pictures of the pinned comments.
    static func blocks(_ given: (answer: Work.Review?, comments: [Work.Comment])) -> [[String: Any]] {
        let w = WorkStore.words(given)
        var out: [[String: Any]] = [["type": "text", "text": w.text]]
        for p in w.pictures {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: p)) else { continue }
            out.append(["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"])
        }
        return out
    }

    // MARK: feedback

    private func feedbackTool(_ args: [String: Any], _ connection: Connection) throws -> [[String: Any]] {
        let (s, _) = try tied(connection)
        let path = s.worktree.path
        if args["all"] as? Bool == true {
            let w = mainSync { () -> Work in _ = WorkStore.shared.deliver(path, via: "feedback"); return WorkStore.shared.work(path) }
            var lines: [String] = []
            if let r = w.review {
                switch r.answer {
                case .approved?: lines.append("review: approved" + (r.head.map { " at \($0.prefix(7))" } ?? "") + (r.head != nil && r.head != s.head ? " (the session has moved on since: ask again with review)" : ""))
                case .changes?: lines.append("review: changes requested")
                case nil: lines.append("review: waiting for the person")
                }
            }
            if w.comments.isEmpty { lines.append("no comments") }
            var blocks = Self.blocks((nil, w.comments))
            if !w.comments.isEmpty, let first = blocks.first?["text"] as? String {
                lines.append(first.split(separator: "\n").dropFirst().joined(separator: "\n"))
            }
            blocks[0] = ["type": "text", "text": lines.joined(separator: "\n")]
            return blocks
        }
        guard let given = mainSync({ WorkStore.shared.deliver(path, via: "feedback") }) else {
            let waiting = mainSync { WorkStore.shared.work(path).reviewWaiting != nil }
            return text(waiting ? "nothing new: the person has not answered your review yet" : "nothing new from the person")
        }
        return Self.blocks(given)
    }

    /// What the person said since the agent last heard from them, to add to the end of a tool's answer: handed over
    /// and marked as given. Nil: nothing.
    func handOver(_ connection: Connection) -> [[String: Any]]? {
        guard let s = connection.session else { return nil }
        guard let given = mainSync({ WorkStore.shared.deliver(s.worktree.path, via: "tool answer") }) else { return nil }
        var blocks = Self.blocks(given)
        if let first = blocks.first?["text"] as? String {
            blocks[0] = ["type": "text", "text": "--- from the person at the Mac, in Greenroom\n" + first]
        }
        return blocks
    }

    /// The lines `session` adds about the spec and the review.
    func reviewLines(_ s: Session) -> [String] {
        mainSync {
            let w = WorkStore.shared.work(s.worktree.path)
            var lines: [String] = []
            if let spec = w.spec {
                let n = spec.criteria.count, p = spec.criteria.filter { $0.state == .passed }.count, f = spec.criteria.filter { $0.state == .failed }.count
                lines.append("spec: \(ScreenNode.quote(spec.title))" + (n == 0 ? ", no criteria" : ", \(p) of \(n) criteria passed" + (f > 0 ? ", \(f) failed" : "")))
            } else {
                lines.append("spec: none (spec says what this session is for; the person sees it)")
            }
            if let r = w.review {
                switch r.answer {
                case nil: lines.append("review: waiting for the person")
                case .approved?: lines.append("review: approved" + (r.head.map { " at \($0.prefix(7))" } ?? "") + (r.head != nil && r.head != s.head ? ", but the session has moved on since" : ""))
                case .changes?: lines.append("review: changes requested")
                }
            }
            return lines
        }
    }
}
