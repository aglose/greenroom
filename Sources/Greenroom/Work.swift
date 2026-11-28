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

    private enum Keys: String, CodingKey { case checks, turnEnded, settled, asked, askedAt }

    init() {}

    // A file written before a field existed still reads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        checks = (try? c.decodeIfPresent([Check].self, forKey: .checks)) ?? []
        turnEnded = try? c.decodeIfPresent(Date.self, forKey: .turnEnded)
        settled = try? c.decodeIfPresent(Date.self, forKey: .settled)
        asked = try? c.decodeIfPresent(String.self, forKey: .asked)
        askedAt = try? c.decodeIfPresent(Date.self, forKey: .askedAt)
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

    /// The `check` tool answered, on a simulator of this session.
    func noteCheck(_ worktree: String, passed: Bool, summary: String, build: String?) {
        change(worktree) { w in
            w.checks.append(Work.Check(at: Self.now(), passed: passed, summary: summary, build: build))
            if w.checks.count > Self.kept { w.checks.removeFirst(w.checks.count - Self.kept) }
        }
    }

    func turnEnded(_ worktree: String) { change(worktree) { $0.turnEnded = Self.now() } }

    /// The person dealt with it.
    func settle(_ worktree: String) { change(worktree) { $0.settled = Self.now() } }

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
        if let file = file(worktree) { try? FileManager.default.removeItem(at: file) }
    }

    /// For a check: as if nothing was ever noted (the files stay).
    func reset() { all = [:]; loaded = [] }
}
