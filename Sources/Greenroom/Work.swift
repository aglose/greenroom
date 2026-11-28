import Foundation

/// What Greenroom knows of the work in one session (docs/AGENT-FIRST-SPEC.md, "The window"): the checks its agent
/// ran, when its turn last ended, what it asked for that only the person can give, and when the person last dealt
/// with it. It is what tells a session that is ready for review from one that is only quiet.
///
/// Nothing here is an agent's word alone: a check is noted by the `check` tool as it answers, a turn's end by the
/// harness's hook.
struct Work: Codable, Equatable {
    struct Check: Codable, Equatable {
        var at: Date
        var passed: Bool
        /// The answer's first line ("PASS | MainActivity").
        var summary: String
        /// The key of the build it ran on, when the session had one.
        var build: String?
    }

    /// What the session is for, as its agent declared it (`spec`).
    struct Spec: Codable, Equatable {
        struct Criterion: Codable, Equatable {
            enum State: String, Codable { case none, passed, failed }
            var text: String
            var state: State = .none
            /// What the check said when it failed.
            var note: String?
            var at: Date?
            /// The build the check ran on: a tick on an older build is said to be one.
            var build: String?
            /// The recording the moment can be seen in, and the second in it.
            var recording: String?
            var second: Double?
        }
        var title: String
        var text: String
        var criteria: [Criterion]
        /// An issue or pull request it comes from.
        var link: String?
        var at: Date

        /// The criteria a `check` named: numbers (1 is the first, several as "2,3") or a criterion's text. Answers
        /// their indices, and the words that matched none.
        func indices(_ named: String) -> (found: [Int], unknown: [String]) {
            var found: [Int] = [], unknown: [String] = []
            let whole = named.trimmingCharacters(in: .whitespacesAndNewlines)
            let numbers = whole.split(whereSeparator: { ", ".contains($0) }).map { Int($0) }
            if !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) {
                for n in numbers.compactMap({ $0 }) { if criteria.indices.contains(n - 1) { found.append(n - 1) } else { unknown.append(String(n)) } }
            } else if let i = criteria.firstIndex(where: { $0.text.caseInsensitiveCompare(whole) == .orderedSame }) {
                found = [i]
            } else {
                let loose = criteria.indices.filter { criteria[$0].text.localizedCaseInsensitiveContains(whole) }
                if loose.count == 1 { found = loose } else if !whole.isEmpty { unknown = [whole] }
            }
            return (Array(Set(found)).sorted(), unknown)
        }
    }

    /// The agent said it is done (`review`), and what the person answered.
    struct Review: Codable, Equatable {
        enum Answer: String, Codable { case approved, changes }
        var summary: String
        var asked: Date
        var answer: Answer?
        var answered: Date?
        /// The commit the answer was given on: an approval stands for that commit and no other.
        var head: String?
        /// Whether the agent has been told the answer.
        var delivered = false
    }

    /// Something the person told the agent, optionally about one node of the screen.
    struct Comment: Codable, Equatable, Identifiable {
        struct Pin: Codable, Equatable {
            /// The node's label (or what it is, when it has none), its frame in device pixels, and the screen it was on.
            var label: String
            var frame: [Int]
            var screen: String
            /// A picture of it, in the state folder.
            var picture: String?
        }
        var id: String
        var text: String
        var at: Date
        var pin: Pin?
        var delivered: Date?
        /// How it reached the agent: "review", "turn end", "feedback".
        var via: String?
    }

    var spec: Spec?
    var review: Review?
    var comments: [Comment] = []
    var checks: [Check] = []
    /// When the agent's turn last ended (its harness's hook said so).
    var turnEnded: Date?
    /// When the person last dealt with it: a session they have looked at is not ready again until its agent does more.
    var settled: Date?
    /// What the agent asked for that only the person can give ("remote": the remote recipe's yes), and when.
    var asked: String?
    var askedAt: Date?

    /// The checks that ran on BUILD (nil: on whatever ran, for a session with no filed build).
    func checks(on build: String?) -> [Check] { checks.filter { $0.build == build } }

    /// The comments the agent has not been given.
    var pending: [Comment] { comments.filter { $0.delivered == nil } }
    /// A review the agent asked for that the person has not answered.
    var reviewWaiting: Review? { review.flatMap { $0.answer == nil ? $0 : nil } }
    /// An answer the agent has not been told.
    var answerWaiting: Review? { review.flatMap { $0.answer != nil && !$0.delivered ? $0 : nil } }

    private enum Keys: String, CodingKey { case checks, turnEnded, settled, asked, askedAt, spec, review, comments }

    init() {}

    // A file written before a field existed still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        checks = (try? c.decodeIfPresent([Check].self, forKey: .checks)) ?? []
        turnEnded = try? c.decodeIfPresent(Date.self, forKey: .turnEnded)
        settled = try? c.decodeIfPresent(Date.self, forKey: .settled)
        asked = try? c.decodeIfPresent(String.self, forKey: .asked)
        askedAt = try? c.decodeIfPresent(Date.self, forKey: .askedAt)
        spec = try? c.decodeIfPresent(Spec.self, forKey: .spec)
        review = try? c.decodeIfPresent(Review.self, forKey: .review)
        comments = (try? c.decodeIfPresent([Comment].self, forKey: .comments)) ?? []
    }
}

/// Every session's `Work`, by its worktree's path. Kept in the state folder (`work/<slot>.json`, one small file a
/// session), so a session that was ready for review still is after Greenroom restarts. Main thread only.
final class WorkStore {
    static let shared = WorkStore()

    /// The time, for a check to move.
    static var now: () -> Date = { Date() }
    /// How many checks a session keeps (the oldest go).
    static let kept = 200

    private var all: [String: Work] = [:]
    private var loaded = Set<String>()
    /// Where the files are (nil: nothing is written, as before a store is set).
    private(set) var folder: URL?
    /// Told when a session's work changed.
    var onChange: (() -> Void)?

    /// Uses the state folder ROOT (the check's own, so a check never touches the person's).
    func use(root: URL) {
        folder = root.appendingPathComponent("work", isDirectory: true)
        all = [:]
        loaded = []
    }

    private func file(_ worktree: String) -> URL? {
        folder?.appendingPathComponent(SessionStore.slot(for: URL(fileURLWithPath: worktree)) + ".json")
    }

    func work(_ worktree: String) -> Work {
        if let w = all[worktree] { return w }
        guard loaded.insert(worktree).inserted, let file = file(worktree), let data = try? Data(contentsOf: file),
              let w = try? Self.decoder.decode(Work.self, from: data) else { return Work() }
        all[worktree] = w
        return w
    }

    // Dates as numbers: they read back as exactly what was written.
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder = JSONDecoder()

    /// Changes one session's work, and keeps it. Says nothing when the change changed nothing.
    func change(_ worktree: String, _ edit: (inout Work) -> Void) {
        var w = work(worktree)
        let before = w
        edit(&w)
        guard w != before else { return }
        all[worktree] = w
        loaded.insert(worktree)
        if let file = file(worktree), let data = try? Self.encoder.encode(w) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: file, options: .atomic)
        }
        onChange?()
    }

    /// The `check` tool answered, on a simulator of this session. `criteria`: the spec's criteria it was about (their
    /// indices), ticked or marked failed with `why` and the moment in the recording.
    func noteCheck(_ worktree: String, passed: Bool, summary: String, build: String?, criteria: [Int] = [], why: String? = nil,
                   moment: (recording: String, second: Double)? = nil) {
        change(worktree) { w in
            let now = Self.now()
            w.checks.append(Work.Check(at: now, passed: passed, summary: summary, build: build))
            if w.checks.count > Self.kept { w.checks.removeFirst(w.checks.count - Self.kept) }
            for i in criteria where w.spec?.criteria.indices.contains(i) == true {
                w.spec?.criteria[i].state = passed ? .passed : .failed
                w.spec?.criteria[i].note = passed ? nil : why
                w.spec?.criteria[i].at = now
                w.spec?.criteria[i].build = build
                w.spec?.criteria[i].recording = moment?.recording
                w.spec?.criteria[i].second = moment?.second
            }
        }
    }

    /// `spec`: what the session is for. Declared again it replaces the one before; a criterion whose words did not
    /// change keeps its tick.
    func setSpec(_ worktree: String, title: String, text: String, criteria: [String], link: String?) {
        change(worktree) { w in
            let old = w.spec?.criteria ?? []
            let next = criteria.map { words in old.first { $0.text == words } ?? Work.Spec.Criterion(text: words) }
            w.spec = Work.Spec(title: title, text: text, criteria: next, link: link, at: Self.now())
        }
    }

    /// `review`: the agent says it is done. A review still waiting is joined: its summary is kept unless a new one is given.
    func askReview(_ worktree: String, summary: String?) {
        change(worktree) { w in
            if var r = w.reviewWaiting {
                if let summary, !summary.isEmpty { r.summary = summary }
                w.review = r
            } else {
                w.review = Work.Review(summary: summary ?? "", asked: Self.now())
            }
        }
    }

    /// The person's answer. With no review asked for (a session that became ready when its turn ended), the answer
    /// is kept all the same, for the agent to be told. Either way the person has dealt with the session.
    func answerReview(_ worktree: String, _ answer: Work.Review.Answer, head: String?) {
        change(worktree) { w in
            let now = Self.now()
            var r = w.reviewWaiting ?? Work.Review(summary: "", asked: w.turnEnded ?? now)
            r.answer = answer
            r.answered = now
            r.head = head
            r.delivered = false
            w.review = r
            w.settled = now
        }
    }

    /// The person tells the agent something. Answers the comment.
    @discardableResult
    func addComment(_ worktree: String, text: String, pin: Work.Comment.Pin? = nil) -> Work.Comment {
        let c = Work.Comment(id: UUID().uuidString, text: text, at: Self.now(), pin: pin)
        change(worktree) { w in
            w.comments.append(c)
            if w.comments.count > Self.kept { w.comments.removeFirst(w.comments.count - Self.kept) }
        }
        return c
    }

    /// Takes back a comment the agent has not been given (and its picture).
    func removeComment(_ worktree: String, id: String) {
        change(worktree) { w in
            for c in w.comments where c.id == id && c.delivered == nil { if let p = c.pin?.picture { try? FileManager.default.removeItem(atPath: p) } }
            w.comments.removeAll { $0.id == id && $0.delivered == nil }
        }
    }

    /// Where the pictures of a session's pinned comments are kept (made when asked for).
    func pins(_ worktree: String) -> URL? {
        guard let dir = file(worktree)?.deletingPathExtension().appendingPathExtension("pins") else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Hands the agent everything it has not been told: the answer to its review and the comments. Marks them
    /// given, by `via`. Answers what there was (nil: nothing).
    func deliver(_ worktree: String, via: String) -> (answer: Work.Review?, comments: [Work.Comment])? {
        let w = work(worktree)
        let answer = w.answerWaiting, comments = w.pending
        guard answer != nil || !comments.isEmpty else { return nil }
        let now = Self.now()
        change(worktree) { w in
            if w.review?.answer != nil { w.review?.delivered = true }
            for i in w.comments.indices where w.comments[i].delivered == nil { w.comments[i].delivered = now; w.comments[i].via = via }
        }
        return (answer, comments)
    }

    /// What `deliver` would hand over, in words, for an agent: the answer first, then each comment, a pinned one with
    /// its node. `pictures` are the files of the pinned ones' pictures, in order.
    /// `paths`: say where each picture is on disk (for a harness's hook, which carries words only).
    static func words(_ given: (answer: Work.Review?, comments: [Work.Comment]), paths: Bool = false) -> (text: String, pictures: [String]) {
        var lines: [String] = []
        if let a = given.answer?.answer {
            lines.append(a == .approved ? "approved" : "changes requested:")
        } else if !given.comments.isEmpty {
            lines.append(given.comments.count == 1 ? "1 comment from the person:" : "\(given.comments.count) comments from the person:")
        }
        var pictures: [String] = []
        for c in given.comments {
            lines.append("- " + c.text.replacingOccurrences(of: "\n", with: "\n  "))
            if let pin = c.pin {
                let f = pin.frame.count == 4 ? " [\(pin.frame[0]),\(pin.frame[1]),\(pin.frame[2]),\(pin.frame[3])]" : ""
                var where_ = "  pinned to \(ScreenNode.quote(pin.label))\(f)" + (pin.screen.isEmpty ? "" : " on \(pin.screen)")
                if let p = pin.picture, FileManager.default.fileExists(atPath: p) { pictures.append(p); where_ += paths ? " (picture: \(p))" : " (picture \(pictures.count))" }
                lines.append(where_)
            }
        }
        if given.answer?.answer == .changes, given.comments.isEmpty { lines.append("- (the person left no comment: ask them what to change)") }
        return (lines.joined(separator: "\n"), pictures)
    }

    /// The agent's turn ended (its harness's hook said so).
    func turnEnded(_ worktree: String) { change(worktree) { $0.turnEnded = Self.now() } }

    /// The person dealt with it. A review still waiting for an answer is taken back with it.
    func settle(_ worktree: String) {
        change(worktree) { w in
            w.settled = Self.now()
            if w.reviewWaiting != nil { w.review = nil }
        }
    }

    /// The agent asked for something only the person gives; `nil` when it was given, or no longer wanted.
    func ask(_ worktree: String, _ what: String?) {
        change(worktree) { w in
            guard w.asked != what else { return }
            w.asked = what
            w.askedAt = what == nil ? nil : Self.now()
        }
    }

    /// The session is gone (its worktree was removed): its file goes too.
    func forget(_ worktree: String) {
        all[worktree] = nil
        loaded.remove(worktree)
        if let file = file(worktree) {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension("pins"))
        }
    }

    /// For a check: as if nothing was ever noted (the files stay).
    func reset() { all = [:]; loaded = [] }
}
