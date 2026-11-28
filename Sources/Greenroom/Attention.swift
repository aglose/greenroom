import AppKit
import UserNotifications

/// The sidebar's four groups (docs/AGENT-FIRST-SPEC.md, "Sessions, by what they need"), in the order shown: a
/// session is filed by what it needs from the person, not by its repository.
enum Attention: Int, CaseIterable {
    case ready, needs, working, quiet

    var title: String {
        switch self {
        case .ready: return "Ready for review"
        case .needs: return "Needs you"
        case .working: return "Working"
        case .quiet: return "Quiet"
        }
    }

    /// As the top bar counts it: "1 ready", "2 need you", "3 working".
    func counted(_ n: Int) -> String {
        switch self {
        case .ready: return "\(n) ready"
        case .needs: return n == 1 ? "1 needs you" : "\(n) need you"
        case .working: return "\(n) working"
        case .quiet: return "\(n) quiet"
        }
    }

    var color: NSColor {
        switch self {
        case .ready: return Design.accent
        case .needs: return Design.warning
        case .working: return NSColor(srgbRed: 0.616, green: 0.569, blue: 1.0, alpha: 1)
        case .quiet: return Design.mute
        }
    }

    /// The top bar's words for the counts: "1 ready · 1 needs you · 2 working" (quiet sessions are not counted), or
    /// nil when no session is in any of the three.
    static func summary(_ counts: [Attention: Int]) -> String? {
        let parts = [Attention.ready, .needs, .working].compactMap { g in (counts[g] ?? 0) > 0 ? g.counted(counts[g]!) : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Dock icon's badge: how many sessions wait for the person (ready, or needing them), or nil for none.
    static func badge(_ counts: [Attention: Int]) -> String? {
        let n = (counts[.ready] ?? 0) + (counts[.needs] ?? 0)
        return n > 0 ? "\(n)" : nil
    }
}

/// What is known of one session, from which its group follows. Gathered on the main thread; `judge` is pure.
struct AttentionFacts: Equatable {
    /// The agent called `review` and waits for the answer (A6), with its summary.
    var review: String? = nil
    /// The harness waits on the person (a permission, a question): its name.
    var waiting: String? = nil
    /// The app is on a sign-in screen one of the person's scripts signs in from.
    var signIn = false
    /// What the agent asked for that only the person can give ("remote").
    var asked: String? = nil
    /// Agents are paused, and one is at work here.
    var paused = false
    /// A turn is running: the harness's name.
    var working: String? = nil
    /// A build of it is queued or running: what the row says of it.
    var building: String? = nil
    /// A tool call arrived in the last minute.
    var calls = false
    /// Its turn ended, and the person has not dealt with it since.
    var turnEnded = false
    /// Its newest build is of its sources as they are.
    var buildCurrent = false
    /// The checks that ran on that build since the person last dealt with it.
    var passed = 0
    var failed = 0
}

/// Where a session is filed, and the few words its card says about it.
struct AttentionState: Equatable {
    enum Tone { case ok, bad, warn, go, plain }

    var group: Attention
    /// Why it is there: the card's last line ("" for a quiet one, which says its build's age).
    var line: String
    var tone: Tone

    /// A session's group, from what is known of it. The order is the spec's: a session that asked for a review is
    /// ready whatever else is true of it (its agent's turn is still running, waiting in that call); then what only
    /// the person can clear; then work under way; then a turn that ended on a current build with a check on it
    /// (the owner's decision 5). Everything else is quiet.
    static func judge(_ f: AttentionFacts) -> AttentionState {
        let checks = f.passed + f.failed
        func verdict() -> (String, Tone) {
            if checks == 0 { return ("No checks ran", .plain) }
            if f.failed > 0 { return ("\(f.passed) of \(checks) passed · \(f.failed) failed", .bad) }
            return ("\(checks) of \(checks) check\(checks == 1 ? "" : "s") passed", .ok)
        }
        if f.review != nil { let v = verdict(); return AttentionState(group: .ready, line: v.0, tone: v.1 == .plain ? .ok : v.1) }
        if let who = f.waiting { return AttentionState(group: .needs, line: "\(who) is waiting for you", tone: .warn) }
        if f.signIn { return AttentionState(group: .needs, line: "Needs a sign-in", tone: .warn) }
        if f.asked == "remote" { return AttentionState(group: .needs, line: "A remote build needs your yes", tone: .warn) }
        if f.paused { return AttentionState(group: .needs, line: "Agents are paused", tone: .warn) }
        if let detail = f.building { return AttentionState(group: .working, line: detail, tone: .go) }
        if let who = f.working { return AttentionState(group: .working, line: "\(who) is working", tone: .go) }
        if f.calls { return AttentionState(group: .working, line: "An agent is driving", tone: .go) }
        if f.turnEnded, f.buildCurrent, checks > 0 { let v = verdict(); return AttentionState(group: .ready, line: v.0, tone: v.1) }
        return AttentionState(group: .quiet, line: "", tone: .plain)
    }
}

/// One step of the loop a session goes through (Spec, Code, Build, Run, Verify, Review), as a card's six marks and
/// the strip over the stage show it.
struct LoopStep: Equatable {
    enum State: String { case done, going, failed, waiting, none }
    static let names = ["Spec", "Code", "Build", "Run", "Verify", "Review"]

    var name: String
    var state: State
    /// One line of detail ("local · 42 s", "4 of 5").
    var detail: String

    var color: NSColor {
        switch state {
        case .done: return Design.accent
        case .going: return NSColor(srgbRed: 0.616, green: 0.569, blue: 1.0, alpha: 1)
        case .failed: return Design.record
        case .waiting: return Design.warning
        case .none: return NSColor(white: 1, alpha: 0.16)
        }
    }
}

// MARK: - The sessions, by attention

extension SessionsController {
    static let groupByRepositoryKey = "sessionsGroupByRepository"

    /// The sidebar's switch: rows by repository, as before, instead of by what they need.
    var groupByRepository: Bool {
        get { CheckedDefault.bool(Self.groupByRepositoryKey) }
        set {
            guard newValue != groupByRepository else { return }
            CheckedDefault.set(newValue, Self.groupByRepositoryKey)
            onChange?()
        }
    }

    /// How long after its last tool call a session still counts as being driven.
    static let callsWindow: TimeInterval = 60

    /// The build that counts as the session's, when there is one.
    func currentBuild(of s: Session) -> Build? { builds[s.worktree.path] ?? s.build }

    /// Whether the session's newest build is of its sources as they are now.
    func buildIsCurrent(_ s: Session) -> Bool {
        let date = [currentBuild(of: s)?.date, s.outputs?.date].compactMap { $0 }.max()
        guard let date else { return false }
        return !(s.sourcesDate.map { $0 > date } ?? false)
    }

    func facts(for s: Session) -> AttentionFacts {
        let path = s.worktree.path
        let work = WorkStore.shared.work(path)
        let now = WorkStore.now()
        var f = AttentionFacts()
        let agents = s.activeAgentSessions
        f.review = reviewAsked(path)
        f.waiting = agents.first { $0.status == .waiting }?.sourceName
        f.working = agents.first { $0.running && $0.status == .working }?.sourceName
        if let sim = simulator(for: s) { f.signIn = workbench?.stage.view(for: sim)?.quickSignIn != nil }
        // What was asked for stands only while it is still missing (the remote recipe's yes may have been given since).
        if work.asked == "remote", workspace(of: s)?.refusal(forRecipe: "remote") != nil { f.asked = "remote" }
        if let job = buildQueue.job(for: s), job.isActive {
            f.building = job.state == .queued ? "Waiting to build with \(job.recipeName)" : "Building with \(job.recipeName)"
            f.asked = nil   // a build is under way: what was asked for was given, or is no longer wanted
        }
        // Being driven: a call that acts on a simulator, in the last minute, and since the turn's end if one was
        // heard (a harness with hooks says when it stops; one without is driven until its calls stop arriving).
        if let last = workbench?.agentActivity.entries(session: path, all: false).last(where: { AgentTools.driving.contains($0.tool) || $0.tool == "launch" }) {
            f.calls = last.time > (work.turnEnded ?? .distantPast) && now.timeIntervalSince(last.time) < Self.callsWindow
        }
        f.paused = (workbench?.agentTools?.paused ?? false) && (f.working != nil || f.calls)
        let settled = work.settled ?? .distantPast
        f.turnEnded = work.turnEnded.map { $0 > settled } ?? false
        f.buildCurrent = buildIsCurrent(s)
        let counted = work.checks(on: currentBuild(of: s)?.key).filter { $0.at > settled }
        f.passed = counted.filter(\.passed).count
        f.failed = counted.count - f.passed
        return f
    }

    func attention(of s: Session) -> AttentionState { AttentionState.judge(facts(for: s)) }

    /// The repository's base branch, kept built: quiet, unless it is being fetched or built.
    func attention(of row: MainRow) -> AttentionState {
        row.isBusy ? AttentionState(group: .working, line: "", tone: .go) : AttentionState(group: .quiet, line: "", tone: .plain)
    }

    /// The six steps of the loop for a session, from what is known of it.
    func loop(for s: Session) -> [LoopStep] {
        let f = facts(for: s)
        let state = AttentionState.judge(f)
        let work = WorkStore.shared.work(s.worktree.path)
        let job = buildQueue.job(for: s)
        let build = currentBuild(of: s)
        var steps = LoopStep.names.map { LoopStep(name: $0, state: .none, detail: "") }
        // Spec: what the agent said it is for (A6 declares it; until then a session has none).
        if let spec = specSummary(s.worktree.path) { steps[0] = LoopStep(name: "Spec", state: .done, detail: spec) }
        // Code: commits or edits on top of the base.
        if s.dirty || s.ahead > 0 {
            let bits = [s.ahead > 0 ? "\(s.ahead) commit\(s.ahead == 1 ? "" : "s")" : nil, s.dirty ? "edited" : nil].compactMap { $0 }
            steps[1] = LoopStep(name: "Code", state: f.working != nil && build == nil ? .going : .done, detail: bits.joined(separator: " · "))
        } else if f.working != nil, build == nil {
            steps[1] = LoopStep(name: "Code", state: .going, detail: "")
        }
        // Build.
        if let job, job.isActive {
            steps[2] = LoopStep(name: "Build", state: .going, detail: job.recipeName)
        } else if let job, job.failure != nil {
            steps[2] = LoopStep(name: "Build", state: .failed, detail: "\(job.recipeName) failed")
        } else if f.asked == "remote" {
            steps[2] = LoopStep(name: "Build", state: .waiting, detail: "needs your yes")
        } else if build != nil || s.outputs != nil {
            let source = build.map { $0.source.rawValue } ?? "local"
            steps[2] = LoopStep(name: "Build", state: f.buildCurrent ? .done : .waiting, detail: f.buildCurrent ? source : "\(source) · stale")
        }
        // Run: its simulator.
        if let sim = simulator(for: s) {
            steps[3] = LoopStep(name: "Run", state: f.signIn ? .waiting : (sim.state == .running ? .done : .going), detail: f.signIn ? "sign-in needed" : "")
        }
        // Verify: the checks on this build.
        let checks = f.passed + f.failed
        if checks > 0 {
            let going = state.group == .working
            steps[4] = LoopStep(name: "Verify", state: f.failed > 0 ? .failed : (going ? .going : .done), detail: "\(f.passed) of \(checks)")
        } else if f.calls, simulator(for: s) != nil {
            steps[4] = LoopStep(name: "Verify", state: .going, detail: "")
        }
        // Review: waiting for the person, or done with.
        if state.group == .ready {
            steps[5] = LoopStep(name: "Review", state: .going, detail: "waiting for you")
        } else if let verdict = reviewVerdict(s.worktree.path) {
            steps[5] = LoopStep(name: "Review", state: verdict.approved ? .done : .waiting, detail: verdict.approved ? "approved" : "changes requested")
        } else if work.settled != nil, checks == 0, work.turnEnded.map({ $0 <= work.settled! }) ?? false {
            steps[5] = LoopStep(name: "Review", state: .done, detail: "reviewed")
        }
        return steps
    }

    // MARK: Rows

    /// One row of the sidebar by attention: a session, or a repository's base branch.
    enum AttentionRow {
        case session(Session, AttentionState)
        case main(MainRow, AttentionState)

        var state: AttentionState {
            switch self { case .session(_, let s), .main(_, let s): return s }
        }
    }

    /// The rows the sidebar shows, by what they need. Within a group: ready and needing sessions the longest
    /// waiting first (so the first to finish is on top), working ones in the order they began, quiet ones as they
    /// were last used, and the base branches last.
    func attentionGroups() -> [(group: Attention, rows: [AttentionRow])] {
        guard workspaces.isEmpty || Git.available else { return [] }
        var filed: [Attention: [(AttentionRow, Date, Int)]] = [:]
        var n = 0
        for group in groups() {
            guard let ws = group.workspace else { continue }
            for s in group.sessions {
                let state = attention(of: s)
                let since = entered[s.worktree.path].flatMap { $0.group == state.group ? $0.since : nil } ?? WorkStore.now()
                filed[state.group, default: []].append((.session(s, state), since, n))
                n += 1
            }
            if let main = mainRow(for: ws) {
                let state = attention(of: main)
                filed[state.group, default: []].append((.main(main, state), .distantFuture, n))
                n += 1
            }
        }
        return Attention.allCases.compactMap { g in
            guard let list = filed[g], !list.isEmpty else { return nil }
            let sorted: [(AttentionRow, Date, Int)]
            switch g {
            case .ready, .needs, .working: sorted = list.sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            case .quiet:
                func rank(_ r: AttentionRow) -> Int {
                    guard case .session(let s, _) = r else { return Int.max }
                    return used.firstIndex(of: s.worktree.path) ?? (Int.max - 1)
                }
                sorted = list.sorted { (rank($0.0), $0.2) < (rank($1.0), $1.2) }
            }
            return (g, sorted.map(\.0))
        }
    }

    /// The session rows in the order the sidebar shows them, whichever way it groups: what ⌘1-9 pick.
    func orderedSessions() -> [Session] {
        if groupByRepository { return groups().flatMap(\.sessions) }
        return attentionGroups().flatMap { $0.rows.compactMap { row -> Session? in if case .session(let s, _) = row { return s }; return nil } }
    }

    /// How many sessions each group holds (base branches are not counted: they are nobody's work).
    func attentionCounts() -> [Attention: Int] {
        var out: [Attention: Int] = [:]
        for s in groups().flatMap(\.sessions) { out[attention(of: s).group, default: 0] += 1 }
        return out
    }

    /// When a session was first seen in the group it is in (ready: when its turn ended, or it asked).
    func since(_ s: Session) -> Date? { entered[s.worktree.path]?.since }

    /// Looks at every shown session's group again: notes when each entered it, and says so (a notification) when
    /// one became ready or came to need the person. Called whenever the rows are worked out.
    func noteAttention() {
        // `groups()` can run the run loop the first time (it asks whether git is there): not from inside itself.
        guard !notingAttention else { return }
        notingAttention = true
        defer { notingAttention = false }
        let now = WorkStore.now()
        var next: [String: (group: Attention, since: Date)] = [:]
        var arrived: [(Session, AttentionState)] = []
        for s in groups().flatMap(\.sessions) {
            let path = s.worktree.path
            let state = attention(of: s)
            if let old = entered[path], old.group == state.group {
                next[path] = old
            } else {
                var at = now
                if state.group == .ready, let ended = WorkStore.shared.work(path).turnEnded { at = min(now, ended) }
                next[path] = (state.group, at)
                // The first look at a session (the app just started, or the row was just added) is not news.
                if entered[path] != nil || attentionSeen, state.group == .ready || state.group == .needs { arrived.append((s, state)) }
            }
        }
        entered = next
        attentionSeen = true
        let counts = attentionCounts()
        if counts != lastCounts {
            lastCounts = counts
            Notifier.setBadge(Attention.badge(counts))
        }
        for (s, state) in arrived { Notifier.sessionArrived(s, state, repository: s.workspace.lastPathComponent) }
    }

    /// ⌘': the next session that is ready or needs the person, after the one last gone to (nil: there is none).
    func nextNeedingAttention() -> Session? {
        let waiting = attentionGroups().filter { $0.group == .ready || $0.group == .needs }
            .flatMap { $0.rows.compactMap { row -> Session? in if case .session(let s, _) = row { return s }; return nil } }
        guard !waiting.isEmpty else { return nil }
        let current = focus ?? workbench?.selected.flatMap { session(forSimulator: $0) }?.worktree.path
        if let current, let i = waiting.firstIndex(where: { $0.worktree.path == current }) { return waiting[(i + 1) % waiting.count] }
        return waiting[0]
    }

    /// Goes to it. Answers whether there was one.
    @discardableResult
    func goToNextNeedingAttention() -> Bool {
        guard let s = nextNeedingAttention() else {
            workbench?.toast.show("No session is ready or needs you")
            return false
        }
        focus = s.worktree.path
        activate(s)
        return true
    }

    /// The person has looked at it: it is not ready again until its agent does more.
    func markReviewed(_ s: Session) {
        WorkStore.shared.settle(s.worktree.path)
    }

    /// Starts the clock that looks again as time passes (a session stops counting as driven a minute after its last
    /// call, and a card's "2 min ago" moves on).
    func startAttentionClock() {
        guard attentionTimer == nil else { return }
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in self?.onChange?() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        attentionTimer = t
    }
}

// MARK: - What the agent declared, and what the person answered (Work.swift)

extension SessionsController {
    /// The summary of a `review` call that waits for the person's answer (nil: none does).
    func reviewAsked(_ worktree: String) -> String? { WorkStore.shared.work(worktree).reviewWaiting?.summary }
    /// The session's spec in a few words ("5 criteria"), when its agent declared one.
    func specSummary(_ worktree: String) -> String? {
        guard let spec = WorkStore.shared.work(worktree).spec else { return nil }
        return spec.criteria.isEmpty ? "declared" : "\(spec.criteria.count) criteri\(spec.criteria.count == 1 ? "on" : "a")"
    }
    /// The person's last answer to a review.
    func reviewVerdict(_ worktree: String) -> (approved: Bool, at: Date)? {
        guard let r = WorkStore.shared.work(worktree).review, let a = r.answer, let at = r.answered else { return nil }
        return (a == .approved, at)
    }
    /// Whether the person's approval stands: it was given on the commit the session is still at.
    func approvalStands(_ s: Session) -> Bool {
        guard let r = WorkStore.shared.work(s.worktree.path).review, r.answer == .approved else { return false }
        return r.head == nil || r.head == s.head
    }
}

// MARK: - Notifications and the Dock badge

/// A yes-or-no setting a check may read and change without touching the person's own: under any check it is kept in
/// memory and starts off, whatever the person chose.
enum CheckedDefault {
    static let inCheck = Engine.agentCheck || CommandLine.arguments.contains { $0.hasPrefix("--") && $0.hasSuffix("-check") }
    private static var memory: [String: Bool] = [:]

    static func has(_ key: String) -> Bool { inCheck ? memory[key] != nil : UserDefaults.standard.object(forKey: key) != nil }
    static func bool(_ key: String) -> Bool { inCheck ? memory[key] ?? false : UserDefaults.standard.bool(forKey: key) }
    static func set(_ on: Bool, _ key: String) { if inCheck { memory[key] = on } else { UserDefaults.standard.set(on, forKey: key) } }
    /// For a check: as if never asked.
    static func forget(_ key: String) { if inCheck { memory[key] = nil } }
}

/// Tells the person, when Greenroom is not in front, that a session became ready or came to need them: a
/// notification of this Mac's own (nothing leaves it), sent only if they said yes (first run's last step, or
/// Settings > Agents). Also the Dock icon's count.
enum Notifier {
    static let key = "notifySessions"

    /// Whether the person was asked, whatever they said.
    static var asked: Bool { CheckedDefault.has(key) }
    static var enabled: Bool { CheckedDefault.bool(key) }

    /// For a check: what would have been sent, instead of sending it. A check never posts to the person's Mac.
    static var deliver: ((_ title: String, _ body: String, _ worktree: String) -> Void)?
    /// For a check: the badge as it was last set.
    private(set) static var badge: String?
    /// Whether Greenroom is in front (a check says).
    static var inFront: () -> Bool = { NSApp.isActive }

    /// A notification is only ever posted by the real app: not by a check, and not by a bare executable, which has
    /// no bundle for the system to name.
    private static var real: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil && !CheckedDefault.inCheck
    }

    private static let responder = Responder()

    /// The person's answer. Saying yes asks macOS for its permission, once; `then` hears whether it was given.
    static func set(_ on: Bool, then: ((Bool) -> Void)? = nil) {
        CheckedDefault.set(on, key)
        guard on, real else { then?(on); return }
        let center = UNUserNotificationCenter.current()
        center.delegate = responder
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { then?(granted) }
        }
    }

    /// At launch: clicks on notifications sent before reach the app.
    static func start() {
        guard real, enabled else { return }
        UNUserNotificationCenter.current().delegate = responder
    }

    static func setBadge(_ text: String?) {
        badge = text
        if real { NSApp.dockTile.badgeLabel = text }
    }

    /// What a notification says for a session that became ready or came to need the person.
    static func words(_ title: String, _ state: AttentionState, repository: String) -> (title: String, body: String) {
        let head = state.group == .ready ? "Ready for review" : "Needs you"
        return ("\(head): \(title)", state.line.isEmpty ? repository : "\(state.line) · \(repository)")
    }

    static func sessionArrived(_ s: Session, _ state: AttentionState, repository: String) {
        guard enabled, !inFront() else { return }
        let w = words(s.title, state, repository: repository)
        if let deliver { deliver(w.title, w.body, s.worktree.path); return }
        guard real else { return }
        let content = UNMutableNotificationContent()
        content.title = w.title
        content.body = w.body
        content.userInfo = ["worktree": s.worktree.path]
        // One notification a session: a newer one replaces the one before it.
        let request = UNNotificationRequest(identifier: "session." + s.slot, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A click on a notification opens its session.
    private final class Responder: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
            let path = response.notification.request.content.userInfo["worktree"] as? String
            DispatchQueue.main.async {
                if let path, let wb = (NSApp.delegate as? AppDelegate)?.workbench {
                    Links.bringForward(wb)
                    if let s = wb.sessions.session(atWorktree: URL(fileURLWithPath: path)) { wb.sessions.focus = s.worktree.path; wb.sessions.activate(s) }
                }
                done()
            }
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
            done([])   // in front, the window already says it
        }
    }
}
