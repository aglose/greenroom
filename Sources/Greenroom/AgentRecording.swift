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
        init(sim: Simulator, file: URL, session: String) { self.sim = sim; self.file = file; self.session = session }
    }

    /// Seconds without an agent action after which a recording ends.
    var idleSeconds: TimeInterval = 60
    /// Told on the main thread when a recording started or ended (the Agent popover shows it).
    var onChange: (() -> Void)?

    private var takes: [ObjectIdentifier: Take] = [:]
    private var timer: Timer?
    /// The newest recording of each session (by worktree path), kept after it ends.
    private(set) var newest: [String: URL] = [:]

    init() {
        if Engine.agentCheck, let s = ProcessInfo.processInfo.environment["GREENROOM_CHECK_AGENT_IDLE"], let d = Double(s), d > 0 { idleSeconds = d }
    }

    /// What is being recorded for a session now, or the file of its last recording (`live` false).
    func recording(for worktree: String) -> (file: URL, live: Bool)? {
        if let t = takes.values.first(where: { $0.session == worktree && ScreenRecording.shared.recorder(for: $0.sim) != nil }) { return (t.file, true) }
        return newest[worktree].map { ($0, false) }
    }

    /// Whether this class is recording `sim` now.
    func isActive(_ sim: Simulator) -> Bool { takes[ObjectIdentifier(sim)] != nil && ScreenRecording.shared.recorder(for: sim) != nil }

    /// Before an agent's action on `sim`: starts a recording if there is none for it. `key` names the build whose
    /// evidence folder holds it. Does nothing for a simulator the person is recording, or when `enabled` is off.
    func begin(_ sim: Simulator, session: Session, key: String?, workbench: Workbench, enabled: Bool) {
        let id = ObjectIdentifier(sim)
        if let t = takes[id] {
            if ScreenRecording.shared.recorder(for: sim) != nil { t.last = Date(); return }
            takes[id] = nil   // it ended by itself (the simulator quit): a new action starts another
        }
        guard enabled, sim.isAlive, ScreenRecording.shared.recorder(for: sim) == nil else { return }
        let file = newFile(for: sim, key: key, workbench: workbench)
        guard ScreenRecording.shared.start(sim, to: file) != nil else { return }
        takes[id] = Take(sim: sim, file: file, session: session.worktree.path)
        newest[session.worktree.path] = file
        startTimer()
        onChange?()
    }

    /// After (or while) an agent's tool ran on `sim`: a chapter and a line of `steps.jsonl`.
    func note(_ sim: Simulator, tool: String, summary: String, failed: Bool) {
        guard let t = takes[ObjectIdentifier(sim)], let recorder = ScreenRecording.shared.recorder(for: sim) else { return }
        t.last = Date()
        let one = summary.split(separator: "\n").first.map(String.init) ?? ""
        let short = one.count > 90 ? String(one.prefix(90)) + "…" : one
        recorder.mark("\(tool): \(short)")
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line: [String: Any] = ["time": stamp.string(from: Date()), "t": (Date().timeIntervalSince(t.started) * 1000).rounded() / 1000,
                                   "video": t.file.lastPathComponent, "tool": tool, "summary": short, "failed": failed]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        let steps = t.file.deletingLastPathComponent().appendingPathComponent("steps.jsonl")
        if !FileManager.default.fileExists(atPath: steps.path) { FileManager.default.createFile(atPath: steps.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let h = try? FileHandle(forWritingTo: steps) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data + Data("\n".utf8))
            try? h.close()
        }
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
            if Date().timeIntervalSince(t.last) >= idleSeconds {
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
