import Foundation

/// The one status model for every harness (docs/AGENT-FIRST-SPEC.md, A4): which sessions are working, waiting for
/// the person or finished with their turn, as the harnesses' own hooks said it (`greenroom hook EVENT`, heard by
/// HookLog). A session here is a harness's name, its session id and the folder it works in, and nothing more: a
/// hook sends no title, prompt or transcript. Kept in memory only, so a session is known from its first hook after
/// the app started.
///
/// What it cannot hear: no harness says "the person allowed it" (a session that asked for a permission shows as
/// waiting until its tool finishes), and none says "interrupted" in every case (Claude Code says so a minute later,
/// as an idle notification; elsewhere a session shows as working until `stale` has passed with no hook).
///
/// Main thread only.
final class HookSessions {
    static let shared = HookSessions()

    enum State: String { case working, waiting, idle }

    struct Entry: Equatable {
        /// As the person knows it: "Claude Code", "Codex", "Cursor", or what the hook called itself.
        var harness: String
        var session: String
        var folder: URL
        var state: State
        var last: Date
        /// When its last turn ended, if one did.
        var turnEnded: Date?
    }

    /// What an event means for a session. Events are matched by their letters alone, so Claude Code's `Stop` and
    /// Cursor's `stop` are one.
    enum Kind { case start, working, waiting, idle, turnEnd, end, other }

    static func kind(_ event: String) -> Kind {
        switch event.lowercased().filter(\.isLetter) {
        case "sessionstart": return .start
        case "userpromptsubmit", "beforesubmitprompt", "pretooluse", "posttooluse", "posttoolusefailure", "afterfileedit",
             "beforeshellexecution", "aftershellexecution", "beforemcpexecution", "aftermcpexecution", "subagentstart", "subagentstop":
            return .working
        case "permissionrequest", "notification": return .waiting
        case "idle": return .idle
        case "stop": return .turnEnd
        case "sessionend": return .end
        default: return .other
        }
    }

    /// The time, for a check to move.
    static var now: () -> Date = { Date() }
    /// A session heard as working, then not at all for this long, is taken to have stopped.
    static let stale: TimeInterval = 15 * 60
    /// A session that is neither working nor waiting counts as open for this long after its last hook.
    static let open: TimeInterval = 60 * 60
    /// ... and is forgotten after this long.
    static let forget: TimeInterval = 24 * 60 * 60

    private(set) var entries: [String: Entry] = [:]
    /// What is shown changed.
    var onChange: (() -> Void)?
    /// A session's turn ended, in this folder.
    var onTurnEnd: ((URL) -> Void)?
    private var timer: Timer?
    private var shown: [AgentSession] = []

    private static func key(_ harness: String, _ session: String, _ folder: URL) -> String {
        harness + "\n" + (session.isEmpty ? folder.path : session)
    }

    /// One hook, as HookLog kept it.
    func heard(_ e: HookLog.Event) {
        let harness = ConnectModel.displayName(client: e.harness)
        let folder = e.cwd.resolvingSymlinksInPath()
        let k = Self.key(harness, e.session, folder)
        let now = Self.now()
        let kind = Self.kind(e.event)
        if kind == .end {
            if entries.removeValue(forKey: k) != nil { changed() }
            return
        }
        var entry = entries[k] ?? Entry(harness: harness, session: e.session, folder: folder, state: .idle, last: now, turnEnded: nil)
        entry.folder = folder
        entry.last = now
        var ended = false
        switch kind {
        case .working: entry.state = .working
        case .waiting: entry.state = .waiting
        case .idle: entry.state = .idle
        case .turnEnd:
            // A harness that runs two hooks for one turn's end (Cursor also runs Claude Code's) ends one turn.
            ended = entry.turnEnded.map { now.timeIntervalSince($0) > 2 } ?? true
            entry.state = .idle
            entry.turnEnded = now
        case .start, .other, .end: break   // a start in the middle of a turn (a resume, a compaction) changes nothing
        }
        entries[k] = entry
        if timer == nil, !CommandLine.arguments.contains("--connect-check") {
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 10
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        changed()
        if ended { onTurnEnd?(folder) }
    }

    /// Time passed: a session may have gone stale, or be forgotten.
    func tick() {
        let now = Self.now()
        entries = entries.filter { now.timeIntervalSince($0.value.last) < Self.forget }
        if entries.isEmpty { timer?.invalidate(); timer = nil }
        changed()
    }

    private func changed() {
        let next = sessions
        guard next.map(\.shown) != shown.map(\.shown) || next.map(\.running) != shown.map(\.running) else { return }
        shown = next
        onChange?()
    }

    /// The state as it counts now.
    private static func state(_ e: Entry, at now: Date) -> State {
        e.state == .working && now.timeIntervalSince(e.last) > stale ? .idle : e.state
    }

    /// Every session heard from, as the rows show sessions.
    var sessions: [AgentSession] {
        let now = Self.now()
        return entries.values.sorted { ($0.last, $0.session) > ($1.last, $1.session) }.map { e in
            let state = Self.state(e, at: now)
            let status: AgentSession.Status = state == .working ? .working : (state == .waiting ? .waiting : .idle)
            return AgentSession(folder: e.folder, status: status, lastActivity: e.last,
                                running: state != .idle || now.timeIntervalSince(e.last) < Self.open,
                                source: .hook, id: e.session.isEmpty ? nil : e.session, harness: e.harness)
        }
    }

    /// Whether a session in FOLDER's worktree (the folder itself or one inside it) is in the middle of a turn.
    func midTurn(in worktree: URL) -> Bool {
        let path = worktree.resolvingSymlinksInPath().path
        let now = Self.now()
        return entries.values.contains { e in
            Self.state(e, at: now) != .idle && (e.folder.path == path || e.folder.path.hasPrefix(path.hasSuffix("/") ? path : path + "/"))
        }
    }

    /// For a check: as if no hook was ever heard.
    func reset() {
        entries = [:]
        shown = []
        timer?.invalidate()
        timer = nil
    }

    // MARK: Joining what the files say

    /// The harness a session read from files belongs to, as hooks name it.
    private static func harness(of s: AgentSession) -> String? {
        if s.source == .claude { return "Claude Code" }
        if s.source == .hook { return s.harness }
        guard let p = s.provider?.lowercased() else { return nil }
        if p.contains("claude") { return "Claude Code" }
        if p.contains("codex") { return "Codex" }
        if p.contains("cursor") { return "Cursor" }
        return nil
    }

    /// POOL (sessions read from Claude Code's files and T3 Code) with what the hooks say. A hook's session that the
    /// files know by its id is that session, and takes its status from the hook: the files give the title and the
    /// pull requests, the hook says what it is doing now. One the files do not know is a session of its own, unless a
    /// live session of the same harness is already shown for the same folder (a T3 Code thread running that harness,
    /// or files that have not caught up yet): then it is that one, which keeps its own status.
    func joined(with pool: [AgentSession]) -> [AgentSession] {
        var out = pool
        for h in sessions {
            if let id = h.id, let at = out.firstIndex(where: { $0.source != .hook && !$0.archived && ($0.ids.contains(id) || $0.id == id) }) {
                out[at].status = h.status
                out[at].running = out[at].running || h.running
                out[at].lastActivity = max(out[at].lastActivity ?? .distantPast, h.lastActivity ?? .distantPast)
                continue
            }
            if out.contains(where: { $0.source != .hook && !$0.archived && !$0.settled && ($0.running || $0.status == .waiting)
                && $0.folder.path == h.folder.path && Self.harness(of: $0) == h.harness }) { continue }
            out.append(h)
        }
        return out
    }
}
