import AppKit

/// While an agent drives a session's simulator, its screen is recorded (docs/SESSIONS-PLAN.md, "3. Evidence" item 3):
/// the first action on the simulator starts a `Recorder` into `evidence/<build key>/video/agent-<time>.mp4`, with a
/// chapter per tool call, and `steps.jsonl` beside it says the same in lines (time, seconds into the video, tool,
/// summary). The recording ends after 60 s without an agent action, when the simulator ends (ScreenRecording), or
/// when the app quits (ScreenRecording.stopAll). It never starts while the person is recording that simulator, and
/// a workspace can turn it off (`Workspace.recordAgent`). The files stay on this Mac, under the build's evidence,
/// until the store prunes that build. Main thread only.
final class AgentRecording {
    final class Take {
        let sim: Simulator
        let file: URL
        let session: String
        let started = Date()
        var last = Date()
        /// Tool calls begun and not yet answered: a long one (wait_for) is activity.
        var inFlight = 0
        init(sim: Simulator, file: URL, session: String) { self.sim = sim; self.file = file; self.session = session }
    }

    /// A take with no activity for this long ends even with a call apparently in progress.
    static var ceiling: TimeInterval = 600

    /// Seconds without an agent action after which a recording ends.
    var idleSeconds: TimeInterval = 60
    /// Told on the main thread when a recording started or ended (the Agent popover shows it).
    var onChange: (() -> Void)?

    private var takes: [ObjectIdentifier: Take] = [:]
    /// The one instance (the agent interface's), for the places that must tell an agent's take from the person's.
    private(set) static weak var current: AgentRecording?
    /// Whether the recording of `sim` now running is an agent's take (main thread).
    static func isAgentTake(_ sim: Simulator) -> Bool { current?.takes[ObjectIdentifier(sim)] != nil }
    private var timer: Timer?
    /// The newest recording of each session (by worktree path), kept after it ends.
    private(set) var newest: [String: URL] = [:]

    init() {
        Self.current = self
        if Engine.agentCheck, let s = ProcessInfo.processInfo.environment["GREENROOM_CHECK_AGENT_IDLE"], let d = Double(s), d > 0 { idleSeconds = d }
    }

    /// What is being recorded for a session now, or the file of its last recording (`live` false).
    func recording(for worktree: String) -> (file: URL, live: Bool)? {
        if let t = takes.values.first(where: { $0.session == worktree && ScreenRecording.shared.recorder(for: $0.sim) != nil }) { return (t.file, true) }
        return newest[worktree].map { ($0, false) }
    }

    /// Where a session's recording is now: the file and the second in it (for a check's moment). Nil: none is being taken.
    func moment(for worktree: String) -> (recording: String, second: Double)? {
        guard let t = takes.values.first(where: { $0.session == worktree && ScreenRecording.shared.recorder(for: $0.sim) != nil }) else { return nil }
        return (t.file.path, max(0, Date().timeIntervalSince(t.started)))
    }

    /// Whether this class is recording `sim` now.
    func isActive(_ sim: Simulator) -> Bool { takes[ObjectIdentifier(sim)] != nil && ScreenRecording.shared.recorder(for: sim) != nil }

    /// Before an agent's action on `sim`: starts a recording if there is none for it. `key` names the build whose
    /// evidence folder holds it. Does nothing for a simulator the person is recording, or when `enabled` is off.
    func begin(_ sim: Simulator, session: Session, key: String?, workbench: Workbench, enabled: Bool) {
        let id = ObjectIdentifier(sim)
        if let t = takes[id] {
            if ScreenRecording.shared.recorder(for: sim) != nil { t.last = Date(); t.inFlight += 1; return }
            takes[id] = nil   // it ended by itself (the simulator quit): a new action starts another
        }
        guard enabled, sim.isAlive, ScreenRecording.shared.recorder(for: sim) == nil else { return }
        let file = newFile(for: sim, key: key, workbench: workbench)
        guard ScreenRecording.shared.start(sim, to: file) != nil else { return }
        let take = Take(sim: sim, file: file, session: session.worktree.path)
        take.inFlight = 1
        takes[id] = take
        newest[session.worktree.path] = file
        startTimer()
        onChange?()
    }

    /// After an agent's tool ran on `sim`: a chapter and a line of `steps.jsonl`. `shape` is what is stored: the tool
    /// and a redacted description of the call (see `shape`), never what was typed, a link's query, a setting's value
    /// or the text of a tap or wait. With the workspace's switch off the take ends instead.
    func note(_ sim: Simulator, shape: String, tool: String, failed: Bool, enabled: Bool) {
        guard let t = takes[ObjectIdentifier(sim)] else { return }
        t.inFlight = max(0, t.inFlight - 1)
        t.last = Date()
        guard enabled else { end(sim) { [weak self] in self?.onChange?() }; return }
        guard let recorder = ScreenRecording.shared.recorder(for: sim) else { return }
        recorder.mark(shape)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line: [String: Any] = ["time": stamp.string(from: Date()), "t": (Date().timeIntervalSince(t.started) * 1000).rounded() / 1000,
                                   "video": t.file.lastPathComponent, "tool": tool, "summary": shape, "failed": failed]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        let steps = t.file.deletingLastPathComponent().appendingPathComponent("steps.jsonl")
        if !FileManager.default.fileExists(atPath: steps.path) { FileManager.default.createFile(atPath: steps.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let h = try? FileHandle(forWritingTo: steps) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data + Data("\n".utf8))
            try? h.close()
        }
    }

    /// What a call is recorded as. Only the shape of the arguments: how many characters were typed, a link without its
    /// query or fragment, which setting changed (not to what), how long a tapped or awaited text is.
    static func shape(tool: String, args: [String: Any]) -> String {
        func chars(_ k: String) -> String? { (args[k] as? String).map { "text of \($0.count) characters" } }
        switch tool {
        case "type":
            let n = (args["text"] as? String)?.count ?? 0
            return "type: typed \(n) characters"
        case "open_url": return "open_url: " + linkShape(args["url"] as? String)
        case "set":
            let name = (args["setting"] as? String) ?? ""
            return "set: " + (AgentTools.settings.keys.contains(name) ? name : "a setting")
        case "tap":
            if let t = chars("text") { return "tap: \(t)" }
            if args["ref"] != nil { return "tap: a node" }
            return "tap: at a point"
        case "wait_for": return "wait_for: \(chars("text") ?? "a text")"
        case "check": return "check: \((args["visible"] as? [String])?.count ?? 0) visible, \((args["absent"] as? [String])?.count ?? 0) absent"
        case "swipe":
            let d = (args["direction"] as? String) ?? ""
            return "swipe: " + (["up", "down", "left", "right"].contains(d) ? d : "by points")
        default: return tool
        }
    }

    /// A link as stored: only the scheme for anything but http(s) (an app's own link can carry anything), and for http(s)
    /// the host and a path whose long or token-looking segments are replaced by an ellipsis. Never a query or fragment.
    static func linkShape(_ raw: String?) -> String {
        guard let raw, let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased() else { return "a link" }
        guard scheme == "http" || scheme == "https" else { return scheme }
        func token(_ seg: Substring) -> Bool {
            if seg.count > 24 { return true }
            let hex = seg.count >= 16 && seg.allSatisfy { $0.isHexDigit || $0 == "-" }
            let mixed = seg.count >= 12 && seg.contains { $0.isNumber } && seg.contains { $0.isLetter }
            return hex || mixed
        }
        let path = c.path.split(separator: "/", omittingEmptySubsequences: true).map { token($0) ? "…" : String($0) }
        return "\(scheme)://\(c.host ?? "")" + (path.isEmpty ? "" : "/" + path.joined(separator: "/"))
    }

    /// Ends the take of `sim` now, keeping its file (the person's own recording is starting, the workspace switch
    /// went off, ...). `done` runs on the main thread when the file is finished.
    func end(_ sim: Simulator, done: @escaping () -> Void = {}) {
        takes[ObjectIdentifier(sim)] = nil
        if takes.isEmpty { timer?.invalidate(); timer = nil }
        ScreenRecording.shared.stop(sim) { _ in done() }
    }

    /// Ends every take of a session (its workspace's switch went off).
    func endTakes(forSession worktree: String) {
        for t in takes.values where t.session == worktree { end(t.sim) { [weak self] in self?.onChange?() } }
    }

    // MARK: Ending

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        var changed = false
        for (id, t) in takes {
            if ScreenRecording.shared.recorder(for: t.sim) == nil { takes[id] = nil; changed = true; continue }   // the simulator ended
            let quiet = Date().timeIntervalSince(t.last)
            // A call in progress counts as activity, but never for more than 10 minutes.
            if (t.inFlight == 0 && quiet >= idleSeconds) || quiet >= AgentRecording.ceiling {
                takes[id] = nil
                changed = true
                ScreenRecording.shared.stop(t.sim) { [weak self] _ in self?.onChange?() }
            }
        }
        if takes.isEmpty { timer?.invalidate(); timer = nil }
        if changed { onChange?() }
    }

    // MARK: Where

    private func newFile(for sim: Simulator, key: String?, workbench wb: Workbench) -> URL {
        let store = wb.sessions.store
        let dir: URL
        if let key { dir = store.root.appendingPathComponent("evidence/\(key)/video", isDirectory: true) }
        else { dir = ScreenRecording.shared.folder(for: sim, in: wb) }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        var n = 0
        while true {
            let name = "agent-\(f.string(from: Date()))" + (n == 0 ? "" : "-\(n)") + ".mp4"
            let url = dir.appendingPathComponent(name)
            if ![url.path, url.path + ".part"].contains(where: { FileManager.default.fileExists(atPath: $0) }) { return url }
            n += 1
        }
    }
}

extension SessionsController {
    /// The workspace switch for recording the agent's session (on by default).
    func recordsAgent(_ s: Session) -> Bool { workspaces.first { $0.root.path == s.workspace.path }?.recordAgent ?? true }

    func setRecordsAgent(_ on: Bool, for s: Session) {
        guard let i = workspaces.firstIndex(where: { $0.root.path == s.workspace.path }) else { return }
        workspaces[i].recordAgent = on
        store.saveWorkspaces(workspaces)
        onChange?()
    }
}
