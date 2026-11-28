import AppKit
import SwiftUI

/// What the session panel shows about one session (docs/AGENT-FIRST-SPEC.md, A6): where it stands, the spec with
/// each criterion's check, what the person told its agent, the agent's last calls, and its pull request.
struct SessionPanelState: Equatable {
    struct Criterion: Equatable, Identifiable {
        var id: Int
        var text: String
        var state: Work.Spec.Criterion.State
        /// "Passed 2 min ago · seen on screen", "Failed · not on screen: "Total"".
        var detail: String
        /// The moment in the recording, when there is one that can be played now.
        var recording: String?
        var second: Double?
    }
    struct Comment: Equatable, Identifiable {
        var id: String
        var text: String
        var pin: String?
        var picture: String?
        var status: String
        var pending: Bool
    }
    struct Call: Equatable, Identifiable {
        var id: Int
        var time: String
        var tool: String
        var summary: String
        var failed: Bool
    }
    enum Verdict: Equatable { case none, asked, ready, approved, changes }

    var worktree: String
    var title: String
    var repository: String
    var mark: String
    var group: Attention
    var line: String
    var verdict: Verdict
    var headline: String
    /// The agent's own summary when it asked, else what explains where the session stands.
    var summary: String
    /// Whether the agent has been told the answer.
    var answerNote: String
    var canAnswer: Bool
    var specTitle: String?
    var specText = ""
    var specLink: String?
    var criteria: [Criterion] = []
    var comments: [Comment] = []
    var calls: [Call] = []
    var steps: [LoopStep] = []
    var hasSimulator = false
}

/// The pull request's line in the panel.
struct MergeLine: Equatable {
    var number: Int?
    var title = ""
    /// "3 checks passed · mergeable into main".
    var detail = ""
    /// Why Merge is not offered ("" when it is).
    var blocked = ""
    var canMerge = false
    var busy = false
    var merged = false
    /// The branch is on a GitHub repository and has no pull request (GitHub was asked).
    var none = false
}

final class SessionPanelModel: ObservableObject {
    @Published var state: SessionPanelState?
    @Published var draft = ""
    @Published var pin: Work.Comment.Pin?
    @Published var pinning = false
    @Published var merge = MergeLine()
    /// The person pressed Request Changes with nothing written: the comment box is brought to them, and its
    /// button asks for the changes.
    @Published var askingChanges = false

    var onApprove: (() -> Void)?
    var onRequestChanges: (() -> Void)?
    var onSend: (() -> Void)?
    var onPin: (() -> Void)?
    var onRemove: ((String) -> Void)?
    var onMerge: (() -> Void)?
    var onAskForPull: (() -> Void)?
    var onPlay: ((SessionPanelState.Criterion) -> Void)?
    var onOpen: ((String) -> Void)?
    var onOpenPull: (() -> Void)?
    var onAllAgents: (() -> Void)?
    var onClose: (() -> Void)?
}

final class LoopStripModel: ObservableObject {
    @Published var steps: [LoopStep] = []
    @Published var title = ""
    @Published var action = ""
    /// Who has the device: "Codex is driving", "You have the device", or "" when nobody is at it.
    @Published var driver = ""
    /// "Take Over" or "Hand Back" ("" when there is nothing to take: no agent is known for the session).
    @Published var take = ""
    var onOpen: (() -> Void)?
    var onTake: (() -> Void)?
}

/// The review side of the window: the session panel in the right slot, the loop strip over the stage, a comment
/// pinned to a node of the screen, and Merge. Main thread only.
final class ReviewController {
    private unowned let workbench: Workbench
    let model = SessionPanelModel()
    let strip = LoopStripModel()
    // Neither view sizes the window: the pane's and the strip's constraints say how large they are.
    private(set) lazy var panelView: NSView = {
        let v = NSHostingView(rootView: SessionPanelView(model: model))
        v.sizingOptions = []
        return v
    }()
    private(set) lazy var stripView: NSView = {
        let v = NSHostingView(rootView: LoopStripView(model: strip))
        v.sizingOptions = []
        v.isHidden = true
        return v
    }()
    /// Called when the strip should show or hide (the stage makes room for it).
    var onStrip: ((Bool) -> Void)?

    private var pulls: [String: (result: Result<Merger.Info?, Merger.Failure>, at: Date, head: String)] = [:]
    private var reading = Set<String>()
    private var merging: String?
    /// The comment being pinned: the session, its simulator and the nodes on its screen when it began.
    private(set) var pinTarget: (worktree: String, sim: Simulator, nodes: [ScreenNode], screen: String)?
    private let queue = DispatchQueue(label: "greenroom-review")
    private var players: [NSWindow] = []

    init(workbench: Workbench) {
        self.workbench = workbench
        model.onApprove = { [weak self] in self?.approve() }
        model.onRequestChanges = { [weak self] in self?.requestChanges() }
        model.onSend = { [weak self] in self?.send() }
        model.onPin = { [weak self] in self?.togglePin() }
        model.onRemove = { [weak self] id in self?.remove(id) }
        model.onMerge = { [weak self] in self?.merge() }
        model.onAskForPull = { [weak self] in self?.askForPull() }
        model.onPlay = { [weak self] c in self?.play(c) }
        model.onOpen = { raw in if let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) } }
        model.onOpenPull = { [weak self] in
            guard let s = self?.session, let url = self?.info(s)?.url ?? s.githubPR?.url else { return }
            NSWorkspace.shared.open(url)
        }
        strip.onOpen = { [weak self] in self?.workbench.showSession() }
        strip.onTake = { [weak self] in self?.toggleTakeOver() }
        if Engine.agentCheck { watchForCheck() }
    }

    /// The session the panel was last about, and whether it was ready: a session the person goes to while it waits
    /// for their review opens its panel, when the right side is free.
    private var lastSeen: (path: String, ready: Bool)?

    private var sessions: SessionsController { workbench.sessions }

    /// The session the panel is about: the one the person last chose.
    var session: Session? {
        guard let path = sessions.focus else { return nil }
        return sessions.sessions.first { $0.worktree.path == path }
    }

    // MARK: What is shown

    func reload() {
        guard let s = session else {
            if model.state != nil { model.state = nil }
            endPin()
            showStrip(nil)
            return
        }
        if pinTarget != nil, pinTarget?.worktree != s.worktree.path { endPin() }
        let next = state(for: s)
        if model.state?.worktree != next.worktree, model.askingChanges { model.askingChanges = false }
        if model.state != next { model.state = next }
        let ready = next.verdict == .asked || next.verdict == .ready
        if ready, lastSeen?.path != next.worktree, workbench.rightPane == nil { lastSeen = (next.worktree, ready); workbench.showSession() }
        lastSeen = (next.worktree, ready)
        let line = mergeLine(for: s)
        if model.merge != line { model.merge = line }
        refreshPull(s)
        showStrip(s)
    }

    private func showStrip(_ s: Session?) {
        // Over the devices only: when the chosen simulator is the session's own.
        let on = s.flatMap { sessions.simulator(for: $0) }.map { $0 === workbench.chosen } ?? false
        if let s, on {
            let steps = sessions.loop(for: s)
            if strip.steps != steps { strip.steps = steps }
            let title = s.branch ?? s.shortHead
            if strip.title != title { strip.title = title }
            let action = sessions.attention(of: s).group == .ready ? "Review" : "Session"
            if strip.action != action { strip.action = action }
            let d = driving(s)
            if strip.driver != d.line { strip.driver = d.line }
            if strip.take != d.button { strip.take = d.button }
        }
        if stripView.isHidden == on {
            stripView.isHidden = !on
            onStrip?(on)
        }
    }

    // MARK: Taking the device over

    /// Whether the person has the session's device.
    func isTaken(_ s: Session) -> Bool { workbench.agentTools?.takenSince(s.worktree.path) != nil }

    /// Who is at a session's device, and what the button beside it does.
    func driving(_ s: Session) -> (line: String, button: String) {
        if isTaken(s) { return ("You have the device", "Hand Back") }
        let f = sessions.facts(for: s)
        let who = SessionsController.mark(for: s.displayAgent)?.name
        if f.calls { return ("\(who ?? "An agent") is driving", "Take Over") }
        if f.working != nil || s.displayAgent != nil { return ("", "Take Over") }
        return ("", "")
    }

    /// Take Over: this session's agent waits (its actions are refused, reading still answers) while every other
    /// session's goes on. Hand Back lets it act again, and tells it so with its next call's answer.
    func toggleTakeOver() {
        guard let s = session, let tools = workbench.agentTools else { return }
        let path = s.worktree.path
        if tools.takenSince(path) != nil {
            tools.handBack(path)
            workbench.say("Handed \(s.branch ?? s.shortHead)'s device back to its agent")
        } else {
            tools.takeOver(path)
            workbench.say("You have \(s.branch ?? s.shortHead)'s device: its agent waits until you hand it back")
        }
        workbench.agentChanged()
        sessions.onChange?()
    }

    static func ago(_ date: Date) -> String {
        let n = max(0, Int(WorkStore.now().timeIntervalSince(date)))
        if n < 60 { return "just now" }
        if n < 5400 { return "\(n / 60) min ago" }
        if n < 129_600 { return "\(n / 3600) h ago" }
        return "\(n / 86_400) days ago"
    }

    func state(for s: Session) -> SessionPanelState {
        let path = s.worktree.path
        let work = WorkStore.shared.work(path)
        let attention = sessions.attention(of: s)
        let build = sessions.currentBuild(of: s)?.key
        let harness = SessionsController.mark(for: s.displayAgent)
        let who = harness?.name ?? "The agent"
        var st = SessionPanelState(worktree: path, title: s.branch ?? s.shortHead, repository: s.workspace.lastPathComponent,
                                   mark: harness?.letters ?? "·", group: attention.group, line: attention.line, verdict: SessionPanelState.Verdict.none,
                                   headline: "", summary: "", answerNote: "", canAnswer: true)
        st.hasSimulator = sessions.simulator(for: s)?.state == .running
        // Where it stands, and whether the person's answer is still wanted.
        let stands = work.review.flatMap { r -> Work.Review? in
            guard r.answer != nil, attention.group != .ready else { return nil }
            return r.answer == .changes || r.head == nil || r.head == s.head ? r : nil
        }
        if let r = work.reviewWaiting {
            st.verdict = .asked
            st.headline = "Ready for review"
            st.summary = r.summary.isEmpty ? "\(who) says it is done, and waits for your answer." : r.summary
        } else if let r = stands, let at = r.answered {
            st.verdict = r.answer == .approved ? .approved : .changes
            st.headline = (r.answer == .approved ? "Approved" : "Changes requested") + " · " + Self.ago(at)
            st.summary = r.summary
            st.answerNote = r.delivered ? "The agent has been told." : "The agent hears it with its next call, or when its turn ends."
            // After asking for changes the person can still approve what came of it, asked again or not.
            st.canAnswer = r.answer == .changes && r.delivered
        } else if attention.group == .ready {
            st.verdict = .ready
            st.headline = "Ready for review"
            st.summary = "Its turn ended on a build of the sources as they are. " + attention.line + "."
        } else {
            st.headline = attention.group == .quiet ? "Quiet" : attention.group.title
            st.summary = attention.line
            if let r = work.review, r.answer == .approved, r.head != nil, r.head != s.head {
                st.summary = "You approved \(r.head!.prefix(7)); the session is at \(s.shortHead) now."
            }
        }
        if let spec = work.spec {
            st.specTitle = spec.title
            st.specText = spec.text
            st.specLink = spec.link
            let live = workbench.agentTools?.recording.recording(for: path).flatMap { $0.live ? $0.file.path : nil }
            st.criteria = spec.criteria.enumerated().map { i, c in
                var detail = ""
                switch c.state {
                case .none: detail = "Not checked yet"
                case .passed: detail = "Passed" + (c.at.map { " " + Self.ago($0) } ?? "")
                case .failed: detail = "Failed" + (c.at.map { " " + Self.ago($0) } ?? "") + (c.note.map { " · " + $0 } ?? "")
                }
                if c.state != .none, c.build != build { detail += " · on an older build" }
                // A recording still being written cannot be played yet.
                let playable = c.recording.map { $0 != live && FileManager.default.fileExists(atPath: $0) } ?? false
                return SessionPanelState.Criterion(id: i, text: c.text, state: c.state, detail: detail,
                                                   recording: playable ? c.recording : nil, second: playable ? c.second : nil)
            }
        }
        st.comments = work.comments.suffix(30).map { c in
            let how: String
            switch c.via {
            case "review"?: how = "with the answer to its review"
            case "turn end"?: how = "when its turn ended"
            case "tool answer"?: how = "with a tool's answer"
            case "feedback"?: how = "when it asked"
            default: how = ""
            }
            let status = c.delivered.map { "Given " + Self.ago($0) + (how.isEmpty ? "" : ", " + how) } ?? "Not given yet"
            let pin = c.pin.map { "Pinned to \(ScreenNode.quote($0.label))" + ($0.screen.isEmpty ? "" : " on \($0.screen)") }
            return SessionPanelState.Comment(id: c.id, text: c.text, pin: pin, picture: c.pin?.picture, status: status, pending: c.delivered == nil)
        }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        st.calls = workbench.agentActivity.entries(session: path, all: false).suffix(12).enumerated().map { i, e in
            SessionPanelState.Call(id: i, time: f.string(from: e.time), tool: e.tool, summary: e.summary, failed: e.failed)
        }
        st.steps = sessions.loop(for: s)
        return st
    }

    // MARK: The person's answer

    func approve() {
        guard let s = session else { return }
        WorkStore.shared.answerReview(s.worktree.path, .approved, head: s.head)
        workbench.say("Approved \(s.branch ?? s.shortHead) at \(s.shortHead)")
    }

    /// Asking for changes says what to change: a comment written and not yet given goes with it.
    func requestChanges() {
        guard let s = session else { return }
        if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send() }
        guard !WorkStore.shared.work(s.worktree.path).pending.isEmpty else {
            model.askingChanges = true   // the panel scrolls to the comment box and puts the cursor in it
            return
        }
        model.askingChanges = false
        WorkStore.shared.answerReview(s.worktree.path, .changes, head: s.head)
        workbench.say("Asked \(s.branch ?? s.shortHead)'s agent for changes")
    }

    func send() {
        guard let s = session else { return }
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        WorkStore.shared.addComment(s.worktree.path, text: String(text.prefix(4000)), pin: model.pin)
        model.draft = ""
        model.pin = nil
        endPin()
    }

    func remove(_ id: String) {
        guard let s = session else { return }
        WorkStore.shared.removeComment(s.worktree.path, id: id)
    }

    // MARK: Pinning a comment to a node

    func isPinning(_ sim: Simulator?) -> Bool { sim != nil && pinTarget?.sim === sim }

    func togglePin() {
        if model.pin != nil { dropPin(); return }
        if pinTarget != nil || model.pinning { endPin(); return }
        beginPin()
    }

    private func dropPin() {
        if let p = model.pin?.picture { try? FileManager.default.removeItem(atPath: p) }
        model.pin = nil
    }

    /// The next click on the session's device picks what the comment is about.
    func beginPin() {
        guard let s = session, let sim = sessions.simulator(for: s), sim.state == .running else {
            workbench.say("Start the session's simulator to pin a comment to its screen", problem: true)
            return
        }
        model.pinning = true
        let path = s.worktree.path
        queue.async { [weak self] in
            let nodes = ScreenNode.parse(sim.sendSync("nodes", timeout: 10))
            let screen = String(sim.sendSync("activity").split(separator: ".").last ?? "")
            DispatchQueue.main.async {
                guard let self, self.model.pinning, self.session?.worktree.path == path else { return }
                self.pinTarget = (path, sim, nodes, screen)
                self.workbench.pinChanged()
                self.workbench.say("Click what your comment is about on \(s.branch ?? s.shortHead)'s screen")
            }
        }
    }

    func endPin() {
        let had = pinTarget != nil
        if let sim = pinTarget?.sim { workbench.stage.view(for: sim)?.outlined = nil }
        pinTarget = nil
        if model.pinning { model.pinning = false }
        if had { workbench.pinChanged() }
    }

    /// The node at a point of the device: the smallest that holds it.
    private func node(atX x: Int, y: Int) -> ScreenNode? {
        guard let t = pinTarget else { return nil }
        let p = CGPoint(x: x, y: y)
        func area(_ n: ScreenNode) -> CGFloat { n.frame.width * n.frame.height }
        // What has a name says more to an agent than a bare box inside it.
        let holding = t.nodes.filter { $0.frame.contains(p) }
        return holding.filter { !$0.label.isEmpty || !$0.resourceId.isEmpty }.min { area($0) < area($1) } ?? holding.min { area($0) < area($1) }
    }

    /// The pointer moved over the device while pinning: what would be picked is outlined.
    func point(_ sim: Simulator, x: Int, y: Int) {
        guard isPinning(sim) else { return }
        workbench.stage.view(for: sim)?.outlined = node(atX: x, y: y)?.frame
    }

    /// A click: the comment is about that node (or, where there is none, that place on the screen).
    func pick(_ sim: Simulator, x: Int, y: Int) {
        guard isPinning(sim), let t = pinTarget, let dir = WorkStore.shared.pins(t.worktree) else { return }
        let node = node(atX: x, y: y)
        let frame = node?.frame ?? CGRect(x: x - 48, y: y - 48, width: 96, height: 96)
        let label = node.map { n in !n.label.isEmpty ? n.label : (n.resourceId.isEmpty ? "an unlabelled \(n.field ? "field" : (n.click ? "control" : "node"))" : String(n.resourceId.split(separator: "/").last ?? "")) }
            ?? "the screen at \(x),\(y)"
        var pin = Work.Comment.Pin(label: label, frame: [Int(frame.minX), Int(frame.minY), Int(frame.maxX), Int(frame.maxY)], screen: t.screen)
        let size = sim.deviceSize
        let out = dir.appendingPathComponent(UUID().uuidString + ".png")
        queue.async { [weak self] in
            let made = Self.picture(of: sim, frame: frame, device: size, to: out)
            DispatchQueue.main.async {
                guard let self, self.pinTarget?.sim === sim else { try? FileManager.default.removeItem(at: out); return }
                if made { pin.picture = out.path }
                self.dropPin()
                self.model.pin = pin
                self.endPin()
            }
        }
    }

    /// A picture of the screen around a node, the node outlined, for the agent to see what is meant.
    private static func picture(of sim: Simulator, frame: CGRect, device: CGSize, to out: URL) -> Bool {
        let dir = Engine.shared.screenshots
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "pin-\(UUID().uuidString).png"
        let file = dir.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: file) }
        guard !sim.sendSync("shot screenshots/\(name)", timeout: 20).hasPrefix("error"),
              let cg = NSBitmapImageRep(data: (try? Data(contentsOf: file)) ?? Data())?.cgImage, device.width > 0 else { return false }
        let k = CGFloat(cg.width) / device.width
        let node = CGRect(x: frame.minX * k, y: frame.minY * k, width: frame.width * k, height: frame.height * k)
        // Room around it, so it can be told where on the screen it is.
        let margin = max(60 * k, min(node.width, node.height) * 0.5)
        var crop = node.insetBy(dx: -margin, dy: -margin)
        if crop.width < 360 * k { crop = crop.insetBy(dx: -(360 * k - crop.width) / 2, dy: 0) }
        if crop.height < 200 * k { crop = crop.insetBy(dx: 0, dy: -(200 * k - crop.height) / 2) }
        crop = crop.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height)).integral
        guard !crop.isEmpty, let part = cg.cropping(to: crop) else { return false }
        let scale = min(1, 900 / max(crop.width, crop.height))
        let w = max(1, Int(crop.width * scale)), h = max(1, Int(crop.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The image's origin is at the top, the context's at the bottom.
        let box = CGRect(x: (node.minX - crop.minX) * scale, y: CGFloat(h) - (node.maxY - crop.minY) * scale, width: node.width * scale, height: node.height * scale)
        ctx.setStrokeColor(Design.difference.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(box.insetBy(dx: -2, dy: -2))
        guard let image = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: out, options: .atomic)) != nil
    }

    // MARK: A criterion's moment

    /// Plays a recording from just before a check passed or failed.
    func play(_ c: SessionPanelState.Criterion) {
        guard let path = c.recording else { return }
        let window = MomentPlayer.window(file: URL(fileURLWithPath: path), second: max(0, (c.second ?? 0) - 3), title: c.text)
        players = players.filter(\.isVisible) + [window]
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Merge

    private func info(_ s: Session) -> Merger.Info? {
        guard let r = pulls[s.worktree.path], case .success(let info) = r.result else { return nil }
        return info
    }

    /// Reads the session's pull request again when what is known is old, or of another commit.
    private func refreshPull(_ s: Session, force: Bool = false) {
        let path = s.worktree.path
        guard GitHubRemote.has(s.workspace), s.branch != nil, !reading.contains(path) else { return }
        if !force, let known = pulls[path], known.head == s.head, WorkStore.now().timeIntervalSince(known.at) < 60 { return }
        // With no pull request known for the branch there is nothing to ask about, until the row finds one.
        if !force, s.githubPR == nil, pulls[path] != nil, !Engine.agentCheck { return }
        reading.insert(path)
        let head = s.head
        let asked = changed[path, default: 0]
        Task { @MainActor [weak self] in
            let result = await Merger.read(s)
            guard let self else { return }
            self.reading.remove(path)
            // A merge ended while GitHub was being asked: this answer is of before it, so it is asked again.
            guard self.changed[path, default: 0] == asked else { self.refreshPull(s, force: true); return }
            self.pulls[path] = (result, WorkStore.now(), head)
            if self.session?.worktree.path == path { self.reload() }
        }
    }

    /// Counts the merges tried per worktree: an answer GitHub gave to a question from before one is not kept.
    private var changed: [String: Int] = [:]

    func mergeLine(for s: Session) -> MergeLine {
        let path = s.worktree.path
        guard let known = pulls[path] else {
            return s.githubPR.map { MergeLine(number: $0.number, title: $0.title, detail: "Reading it from GitHub…") } ?? MergeLine()
        }
        switch known.result {
        case .failure(let f):
            return MergeLine(number: s.githubPR?.number, title: s.githubPR?.title ?? "", detail: "", blocked: f.message)
        case .success(nil):
            return MergeLine(none: true)
        case .success(let info?):
            var line = MergeLine(number: info.number, title: info.title)
            line.busy = merging == path
            line.merged = info.state == "MERGED"
            if let why = Merger.block(info, session: s) {
                line.blocked = why
            } else {
                line.canMerge = merging == nil
                line.detail = info.checksLine + " · " + (info.mergeable == "MERGEABLE" ? "can be merged into \(info.base)" : "GitHub is still working out whether it can be merged")
            }
            return line
        }
    }

    /// A session with no pull request: the person asks its agent for one, as a comment like any other.
    func askForPull() {
        guard let s = session else { return }
        let text = "Please open a pull request for this branch."
        guard !WorkStore.shared.work(s.worktree.path).pending.contains(where: { $0.text == text }) else { return }
        WorkStore.shared.addComment(s.worktree.path, text: text)
        workbench.say("Asked \(s.branch ?? s.shortHead)'s agent for a pull request: it hears with its next call or its turn's end")
    }

    func merge() {
        guard let s = session, merging == nil, let info = info(s), Merger.block(info, session: s) == nil else { return }
        let path = s.worktree.path
        let spec = WorkStore.shared.work(path).spec
        let criteria = (failed: spec?.criteria.filter { $0.state == .failed }.count ?? 0, unchecked: spec?.criteria.filter { $0.state == .none }.count ?? 0)
        let warnings = Merger.warnings(info, session: s, approved: sessions.approvalStands(s), criteria: criteria)
        Merger.ask(info, warnings: warnings, in: workbench.window) { [weak self] method in
            guard let self, let method else { return }
            self.merging = path
            self.reload()
            Task { @MainActor [weak self] in
                let why = await Merger.merge(info, method: method, in: s.worktree)
                guard let self else { return }
                self.merging = nil
                self.changed[path, default: 0] += 1
                if let why {
                    self.workbench.say("Not merged: \(why)", problem: true)
                } else {
                    self.workbench.say("Merged #\(info.number) into \(info.base)")
                    if case .success(var done?) = self.pulls[path]?.result { done.state = "MERGED"; self.pulls[path]?.result = .success(done) }
                }
                self.refreshPull(s, force: true)
                self.reload()
            }
        }
    }

    // MARK: The person, for scripts/mcp-check.py

    /// Only with `--agent-check`: the check cannot click, so it writes what the person would do to
    /// `review-person-check.json` in the state folder: {"worktree", "comment"?, "pin": [x, y]?, "answer": "approved"|"changes"?,
    /// "take": true|false?}.
    /// It is done through the same functions the panel's buttons call, and the file is replaced by `.done`.
    private func watchForCheck() {
        let file = Engine.shared.state.appendingPathComponent("review-person-check.json")
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let data = try? Data(contentsOf: file) else { return }
            try? FileManager.default.removeItem(at: file)
            guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let path = o["worktree"] as? String,
                  let s = self.sessions.sessions.first(where: { $0.worktree.resolvingSymlinksInPath().path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path }) else {
                try? Data("no such session".utf8).write(to: file.appendingPathExtension("done"))
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                var said = "ok"
                self.sessions.focus = s.worktree.path
                self.reload()
                if let text = o["comment"] as? String {
                    self.model.draft = text
                    if let at = o["pin"] as? [Int], at.count == 2 {
                        self.beginPin()
                        for _ in 0..<100 where self.pinTarget == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                        if let sim = self.pinTarget?.sim { self.pick(sim, x: at[0], y: at[1]) } else { said = "no simulator to pin to" }
                        for _ in 0..<200 where self.model.pin == nil && self.pinTarget != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                        if self.model.pin?.picture == nil { said = "the pin has no picture" }
                    }
                    self.send()
                }
                if let take = o["take"] as? Bool, take != self.isTaken(s) { self.toggleTakeOver() }
                switch o["answer"] as? String {
                case "approved"?: self.approve()
                case "changes"?: self.requestChanges()
                default: break
                }
                try? Data(said.utf8).write(to: file.appendingPathExtension("done"))
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }
}
