import AppKit
import Foundation

/// What an agent may do: the tools, their schemas and their answers. Every action answers with what changed on
/// screen since the last answer, in compact lines, so an agent seldom needs the whole screen or a picture.
final class AgentTools {
    struct Failure: Error { let message: String }

    weak var workbench: Workbench? {
        didSet { recording.onChange = { [weak self] in self?.workbench?.agentChanged() } }
    }
    /// The recording of an agent's session on a session's simulator (AgentRecording.swift).
    let recording = AgentRecording()
    /// The simulator the tool being run acts on (set while it runs; tools run one at a time).
    var currentSim: Simulator?
    /// The folder of the newest `changes` answer of each session (by worktree path), for `screenshot`'s `screen`.
    var lastChanges: [String: ChangeSet] = [:]
    let changesLock = NSLock()
    /// Base resolutions in progress (by session and base): a call that gives up waiting leaves one running, and the next call joins it.
    var pendingResolves: [String: ResolveBox] = [:]
    final class ResolveBox { let group = DispatchGroup(); var result: BaseResolution? }
    /// One line per call, for the person watching (main thread).
    var onActivity: ((_ tool: String, _ summary: String, _ failed: Bool, _ session: Session?) -> Void)?

    /// Who is calling: the shim's working folder and its parent process (the agent), as it said, and the session
    /// the folder is a worktree of (nil: none, or a folder outside every added repository). Hints, not rights.
    struct Connection {
        var cwd: URL?
        var parent: Int32?
        var session: Session?
    }

    /// The person at the Mac paused the agent: actions are refused until it is lifted.
    var paused = false

    private var ids: [ObjectIdentifier: String] = [:]
    private var nextID = 1

    static let instructions = "Drives Android apps in Greenroom on this Mac; the person there sees the same simulators. "
        + "launch an APK, then tap/type/key/swipe: each action answers with the nodes that changed (+ added, - removed, "
        + "~ changed; refs like e3 stay the same while a node is on screen), so call screen or screenshot only when you "
        + "need all of it. check verifies texts in one call. APKs and their data stay on this Mac. "
        + "Sign-ins are the owner's: never ask for or type passwords. To sign in, run_script a script the owner allowed "
        + "(scripts lists them): it types their stored credentials, which you never see."

    // MARK: Schemas

    private static let str: [String: Any] = ["type": "string"]
    private static let int: [String: Any] = ["type": "integer"]
    private static let bool: [String: Any] = ["type": "boolean"]
    private static let strings: [String: Any] = ["type": "array", "items": ["type": "string"]]

    private static func schema(_ props: [String: Any] = [:], required: [String] = [], sim: Bool = true) -> [String: Any] {
        var p = props
        if sim { p["sim"] = ["type": "string", "description": "simulator id (s1), if several run"] }
        return ["type": "object", "properties": p, "required": required, "additionalProperties": false]
    }

    private static let devices = ["phone", "foldable", "tablet", "desktop", "tv", "watch"]
    static let settings: [String: String] = [
        "appearance": "^(dark|light|toggle)$", "locale": "^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$", "fontscale": "^[0-9.]{1,4}$",
        "rotate": "^(left|right|portrait|landscape)$", "network": "^(online|offline|3g|lossy)$",
        "device": "^(phone|foldable|tablet|desktop|tv|watch|[0-9]{3,4}x[0-9]{3,4}(@[0-9.]+)?)$",
        "timezone": "^[A-Za-z_]+(/[A-Za-z_+-]+)*$", "animscale": "^[0-9.]{1,4}$",
        "permission": "^(allow|deny|reset|(grant|revoke) [A-Za-z0-9_.]+)$", "home": "^$", "resume": "^$", "lock": "^$",
        "unlock": "^$", "recreate": "^$", "restart": "^$", "process-death": "^$",
    ]

    /// The tools that act on a simulator and so are recorded (launch is noted when it has made one).
    static let driving: Set<String> = ["tap", "type", "key", "swipe", "back", "open_url", "set", "screen", "check", "wait_for", "screenshot", "logs", "run_script"]

    /// Tools that wait for builds and walks: they run on their own queue so the others still answer meanwhile.
    static let slow: Set<String> = ["build", "changes"]

    static let readOnly: Set<String> = ["simulators", "screen", "screenshot", "logs", "check", "wait_for", "compare", "session", "scripts", "history"]

    static let tools: [(name: String, description: String, schema: [String: Any])] = [
        ("launch", "Start an APK in Greenroom. Without apk, starts (or selects) this worktree's own simulator from its newest build, "
            + "with its own app data. Answers with the screen's nodes.", schema([
            "apk": ["type": "string", "description": "path of the .apk (omit in a worktree of a repository added to Greenroom)"],
            "device": ["type": "string", "enum": devices],
            "appearance": ["type": "string", "enum": ["light", "dark"]],
            "locale": str, "font_scale": ["type": "number"],
            "fresh": ["type": "boolean", "description": "start with empty app data. In a worktree it runs beside the session's simulator on a separate data slot: the session's own data is never emptied"],
        ], sim: false)),
        ("simulators", "List running simulators and recently opened APKs.", schema(sim: false)),
        ("close", "Stop a simulator.", schema()),
        ("tap", "Tap a node by ref (e3), by its text, or at x,y. Answers with what changed.", schema(["ref": str, "text": str, "x": int, "y": int])),
        ("type", "Type text; ref or tap_text taps a field first; enter presses Enter after.", schema(
            ["text": str, "ref": str, "tap_text": str, "enter": bool], required: ["text"])),
        ("key", "Press a key: ENTER, DEL, TAB, DPAD_DOWN, ...", schema(["key": str, "count": int, "modifiers": strings], required: ["key"])),
        ("swipe", "Swipe by direction (up shows later content), from the centre or from a ref; or x1,y1 to x2,y2.", schema([
            "direction": ["type": "string", "enum": ["up", "down", "left", "right"]], "ref": str,
            "x1": int, "y1": int, "x2": int, "y2": int, "ms": int])),
        ("back", "Press Back.", schema()),
        ("open_url", "Open a deep link in the app.", schema(["url": str], required: ["url"])),
        ("set", "Change the device or app state: appearance dark|light, locale fr-FR, fontscale 1.3, rotate left|right|portrait|"
            + "landscape, network online|offline|3g|lossy, device phone|tablet|..., timezone, animscale, permission allow|deny|"
            + "grant NAME|revoke NAME|reset, and (no value) home, resume, lock, unlock, recreate, restart, process-death.",
         schema(["setting": ["type": "string", "enum": settings.keys.sorted()], "value": str], required: ["setting"])),
        ("screen", "The whole screen as compact lines: ref \"label\" click|field. text keeps lines containing it.",
         schema(["text": str, "bounds": bool])),
        ("check", "Verify the screen in one call: every text in visible must be on screen, none in absent. Answers PASS or FAIL with what is wrong.",
         schema(["visible": strings, "absent": strings])),
        ("wait_for", "Wait until a text is on screen (or, with gone, no longer is). Answers with what changed.",
         schema(["text": str, "gone": bool, "timeout_ms": int], required: ["text"])),
        ("screenshot", "A picture of the screen, for what the nodes do not show. annotate draws each tappable node's ref on it. "
            + "With screen (an id from changes) it answers that screen's stored capture instead: side head (default), base, or diff. "
            + "With screen and commit it answers the stored capture of that screen at that commit (see history).",
         schema(["max_size": ["type": "integer", "description": "longest side in pixels (default 1000, 0 for full size)"], "annotate": bool,
                 "screen": ["type": "string", "description": "a screen id from the last changes answer (worktree sessions only), or with commit a screen's title or id"],
                 "side": ["type": "string", "enum": ["head", "base", "diff"]],
                 "commit": ["type": "string", "description": "with screen: the stored capture of that screen at this commit (from history)"]])),
        ("compare", "How two simulators' screens differ (two builds, or two devices): - only on the base, + only on the other, > moved; "
            + "and, for screens of one size, the share of pixels that differ. map adds a picture of where.",
         schema(["base": ["type": "string", "description": "simulator id compared against (default: the first running)"],
                 "other": ["type": "string", "description": "simulator id compared (default: the second running)"], "map": bool], sim: false)),
        ("session", "This worktree's session in Greenroom: branch and commit, whether it has uncommitted changes, its build (age, "
            + "source, current or stale), the default recipe, the base changes are compared with, whether its simulator runs. "
            + "Only for an agent started in a worktree of a repository added to Greenroom.", schema(sim: false)),
        ("build", "Build this worktree with a recipe and wait: answers the new build's key and age, or the log's last error lines. "
            + "The session's simulator then reloads on it with its data kept. The remote recipe needs the person's yes in Greenroom "
            + "(an agent cannot give it); ci never starts a workflow from here.",
         schema(["recipe": ["type": "string", "description": "local, ci, remote or a custom recipe's name (default: the workspace's)"],
                 "timeout_s": ["type": "integer", "description": "how long this call waits, 10-200 s (default 200); the build goes on, and calling build again joins it"]], sim: false)),
        ("changes", "How this session's newest build differs from a base, as screens: + new, ~ changed (why: pixels, routes, texts), - gone, "
            + "> a control that now leads elsewhere, then counts, crashes (new, fixed or still there) and what the walk did not finish. "
            + "When both builds have a stored map the answer comes from history and its first line says so: no walk is started. Otherwise it walks both builds. "
            + "Screen ids in [brackets] go to screenshot's screen. An unbuilt base is answered as text saying what would build it; nothing is started.",
         schema(["base": ["type": "string", "description": "default: the workspace's base branch. Or session:BRANCH, pr:NUMBER, a branch/tag/commit, the path of an .apk, or snapshot:COMMIT (the stored map of that commit; no build needed)"],
                 "timeout_s": ["type": "integer", "description": "how long this call waits, 10-200 s (default 200); the walk goes on, and calling changes again joins it"]], sim: false)),
        ("history", "The screen maps stored for this session's repository and profile, newest first: commit, date, screens, and what changed "
            + "against the one before. With screen (a title or id) that screen's lineage over time: each commit that changed it and why. "
            + "Reads only; nothing is walked. screenshot's screen and commit show a stored picture.",
         schema(["screen": ["type": "string", "description": "a screen's title or id: its lineage over time"]], sim: false)),
        ("scripts", "The owner's scripts (sign in, seed data, reach a screen) and whether you may run each, and the names of their "
            + "variables. Values are never shown.", schema(sim: false)),
        ("run_script", "Run a script the owner allowed on a simulator and wait for it: answers its exit status, its last output lines "
            + "(secret values as ••••) and what changed on screen. Use it to sign in instead of typing credentials.",
         schema(["name": ["type": "string", "description": "the script's file name, from scripts"],
                 "timeout_s": ["type": "integer", "description": "10-300 s (default 120); the script is stopped after it"]], required: ["name"])),
        ("logs", "The app's log lines since the last call (android.util.Log and the engine's own).",
         schema(["filter": ["type": "string", "description": "keep lines containing this"], "lines": int])),
    ]

    static func list() -> [[String: Any]] {
        tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema,
                     "annotations": ["readOnlyHint": readOnly.contains($0.name), "openWorldHint": false]] }
    }

    // MARK: Calling

    /// Runs a tool. Never on the main thread. Answers with MCP content blocks.
    func call(_ name: String, _ args: [String: Any], connection: Connection = Connection()) throws -> [[String: Any]] {
        Reports.shared.count(.agentTool)
        guard AgentTools.tools.contains(where: { $0.name == name }) else { throw Failure(message: "unknown tool \(name)") }
        if paused || AgentCheckHooks.pausedByCheck, !AgentTools.readOnly.contains(name) {
            throw Failure(message: "The person at the Mac has paused the agent in Greenroom. Ask them to resume it.")
        }
        // build and changes wait for minutes and run beside the other tools (AgentServer): they touch no simulator and no recording.
        let slow = AgentTools.slow.contains(name)
        // A paused agent is not recorded, reading included: recording follows what the agent does, and it is not allowed to act.
        let recorded = !slow && !(paused || AgentCheckHooks.pausedByCheck)
        if !slow { currentSim = nil }
        // An agent driving a session's simulator is recorded (AgentRecording): the first action starts it.
        if recorded, AgentTools.driving.contains(name), !(name == "screenshot" && args["screen"] != nil), let s = try? sim(args) {
            currentSim = s
            beginRecording(s)
        }
        do {
            let content: [[String: Any]]
            switch name {
            case "session": content = text(try sessionTool(connection))
            case "build": content = text(try buildTool(args, connection))
            case "changes": content = text(try changesTool(args, connection))
            case "history": content = text(try historyTool(args, connection))
            case "launch": content = text(try launch(args, connection))
            case "simulators": content = text(simulators())
            case "close": content = text(try close(args))
            case "tap": content = text(try tap(args))
            case "type": content = text(try type(args))
            case "key": content = text(try key(args))
            case "swipe": content = text(try swipe(args))
            case "back": content = text(try act(try sim(args), "back", head: "back"))
            case "open_url": content = text(try openURL(args))
            case "set": content = text(try set(args))
            case "screen": content = text(try screen(args))
            case "check": content = text(try check(args))
            case "wait_for": content = text(try waitFor(args))
            case "screenshot": content = args["screen"] != nil ? (args["commit"] != nil ? try historyPicture(args, connection) : try changePicture(args, connection)) : try screenshot(args)
            case "logs": content = text(try logs(args))
            case "scripts": content = text(scriptsList())
            case "run_script": content = text(try runScript(args))
            case "compare": content = try compare(args)
            default: throw Failure(message: "unknown tool \(name)")
            }
            let first = (content.first?["text"] as? String)?.split(separator: "\n").first.map(String.init) ?? "picture"
            if recorded, name == "launch", let s = currentSim { beginRecording(s) }
            if recorded { noteRecording(name, args, failed: false) }
            report(name, first, failed: false, connection)
            return content
        } catch let f as Failure {
            if recorded { noteRecording(name, args, failed: true) }
            report(name, f.message, failed: true, connection)
            throw f
        }
    }

    // MARK: Scripts

    private func scriptsList() -> String {
        let all = Scripts.list(in: Scripts.folder)
        var out: [String] = []
        if all.isEmpty { out.append("no scripts: the owner adds them in Greenroom (Device > Run Script > New Script…)") }
        for s in all {
            switch Scripts.approval(s) {
            case .yes: out.append("\(s.name): you may run it")
            case .no: out.append("\(s.name): not allowed for agents (the owner can allow it in Greenroom > Settings > Scripts)")
            case .changed: out.append("\(s.name): changed since the owner allowed it, so not allowed until they allow it again")
            }
        }
        let names = Variables.shared.names().map(\.name)
        out.append("variables: " + (names.isEmpty ? "none" : names.joined(separator: ", ")) + " (values are never shown)")
        return out.joined(separator: "\n")
    }

    private func runScript(_ args: [String: Any]) throws -> String {
        guard let name = args["name"] as? String, !name.isEmpty else { throw Failure(message: "run_script needs name: call scripts") }
        let s = try sim(args)
        guard let script = Scripts.list(in: Scripts.folder).first(where: { $0.name == name }) else {
            throw Failure(message: "no script \(name): call scripts")
        }
        switch Scripts.approval(script) {
        case .yes: break
        case .no: throw Failure(message: "\(name) is not allowed for agents. Ask the owner to allow it in Greenroom > Settings > Scripts, or to run it themselves.")
        case .changed: throw Failure(message: "\(name) has changed since the owner allowed it. Ask them to allow it again in Greenroom > Settings > Scripts.")
        }
        let timeout = TimeInterval(min(300, max(10, args["timeout_s"] as? Int ?? 120)))
        let made: ScriptRun? = DispatchQueue.main.sync {
            ScriptRun(script: script, sim: s, worktree: self.workbench?.worktree(of: s))
        }
        guard let run = made else { throw Failure(message: "\(id(s)) is still starting: try again in a moment") }
        let before = activity(s)
        let o = run.runSync(timeout: timeout)
        if let f = o.failure { throw Failure(message: f) }
        let tail = o.output.suffix(40)
        var head = "ran \(name)"
        if o.timedOut { head += ": stopped after \(Int(timeout)) s" }
        else if let c = o.code { head += c == 0 ? ": exit 0" : ": FAILED, exit \(c)" }
        let screen = answer(s, head: head, before: before)
        let output = tail.isEmpty ? "(no output)" : (o.output.count > tail.count ? "[…]\n" : "") + tail.joined(separator: "\n")
        return screen + "\n--- output\n" + output
    }

    private func report(_ tool: String, _ summary: String, failed: Bool, _ connection: Connection) {
        DispatchQueue.main.async { self.onActivity?(tool, summary, failed, connection.session) }
    }

    func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }

    // MARK: Finding simulators and nodes

    func id(_ sim: Simulator) -> String {
        let key = ObjectIdentifier(sim)
        if let known = ids[key] { return known }
        let made = "s\(nextID)"
        nextID += 1
        ids[key] = made
        return made
    }

    func all() -> [Simulator] { DispatchQueue.main.sync { Engine.shared.simulators } }

    func sim(_ args: [String: Any]) throws -> Simulator {
        let live = all().filter { $0.state == .running }
        if let want = args["sim"] as? String {
            guard let s = live.first(where: { id($0) == want }) else { throw Failure(message: "no running simulator \(want): call simulators") }
            return s
        }
        if live.count == 1 { return live[0] }
        throw Failure(message: live.isEmpty ? "no simulator is running: launch an APK first"
                                            : "several simulators run (\(live.map(id).joined(separator: ", "))): say which with sim")
    }

    private func command(_ sim: Simulator, _ command: String, timeout: TimeInterval = 30) throws -> String {
        let answer = sim.sendSync(command, timeout: timeout)
        if answer.hasPrefix("error") { throw Failure(message: "\(command.split(separator: " ").first ?? ""): \(answer)") }
        return answer
    }

    private func nodes(_ sim: Simulator) -> [ScreenNode] { ScreenNode.parse(sim.sendSync("nodes")) }

    private func activity(_ sim: Simulator) -> String {
        String(sim.sendSync("activity").split(separator: ".").last ?? "")
    }

    /// The node a reference named, found again on the screen as it is now (it may have moved, or gone).
    private func resolve(_ sim: Simulator, ref: String) throws -> ScreenNode {
        guard let old = sim.tree.node(ref: ref) else { throw Failure(message: "\(ref) is not on screen: call screen") }
        let fresh = nodes(sim)
        let same = fresh.filter {
            $0.label == old.label && $0.field == old.field
                && (!old.label.isEmpty || ($0.left == old.left && $0.top == old.top && $0.right == old.right && $0.bottom == old.bottom))
        }
        guard let found = same.first else { throw Failure(message: "\(ref) \(ScreenNode.quote(old.label)) is no longer on screen: call screen") }
        return found
    }

    private func find(_ sim: Simulator, text: String) throws -> ScreenNode {
        let fresh = nodes(sim)
        let exact = fresh.filter { $0.label == text }
        let loose = exact.isEmpty ? fresh.filter { $0.label.localizedCaseInsensitiveContains(text) } : exact
        guard let found = loose.first(where: { $0.click || $0.field }) ?? loose.first else {
            throw Failure(message: "no node with text \(ScreenNode.quote(text)) on screen: call screen")
        }
        return found
    }

    /// Settles, reads the screen and says what changed since the last answer.
    private func answer(_ sim: Simulator, head: String, before: String? = nil) -> String {
        let settled = sim.sendSync("settle 2500 150", timeout: 10)
        let now = activity(sim)
        let change = sim.tree.update(nodes(sim))
        var first = "\(id(sim)) \(head)"
        if !settled.hasPrefix("settled") { first += " (still animating)" }
        first += " | \(now)"
        if let before, before != now { first += " (was \(before))" }
        let lines = change.lines()
        // Only the nodes are compared: a change of colours, pictures or layout alone (dark mode, say) is not text, and
        // "no change" alone read as "it did not work" in a real agent session.
        return ([first] + (lines.isEmpty ? ["no change in the screen's text (colours and pictures are not compared: screenshot shows them)"] : lines)).joined(separator: "\n")
    }

    private func act(_ sim: Simulator, _ commandLine: String, head: String) throws -> String {
        let before = activity(sim)
        _ = try command(sim, commandLine)
        return answer(sim, head: head, before: before)
    }

    private func showTouch(_ sim: Simulator, _ x: Int, _ y: Int) {
        DispatchQueue.main.async { self.workbench?.agentTouched(sim, x: x, y: y) }
    }

    // MARK: Tools

    private func launch(_ args: [String: Any], _ connection: Connection) throws -> String {
        var options: [String] = []
        if let d = args["device"] as? String {
            guard AgentTools.devices.contains(d) else { throw Failure(message: "device is one of \(AgentTools.devices.joined(separator: ", "))") }
            options += ["--device", d]
        }
        if let a = args["appearance"] as? String, ["light", "dark"].contains(a) { options += ["--appearance", a] }
        if let l = args["locale"] as? String, l.range(of: AgentTools.settings["locale"]!, options: .regularExpression) != nil { options += ["--locale", l] }
        if let f = args["font_scale"] as? Double, f >= 0.5, f <= 3 { options += ["--font-scale", String(f)] }
        let fresh = args["fresh"] as? Bool == true
        if fresh { options.append("--fresh") }

        // The session this connection is tied to, as it is now (its build may be newer than when it was tied).
        let session: Session? = connection.session.flatMap { s in DispatchQueue.main.sync { self.workbench?.sessions.session(atWorktree: s.worktree) } }
        let name: String
        let opened: Simulator?
        var note = ""
        var mark = true   // the simulator is the session's (not so for another app's APK)
        /// A simulator beside the session's, on a data slot of its own that nothing else uses.
        func throwaway(_ apk: URL) -> Simulator? {
            let slot = "grx" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            note = " (fresh data on a separate slot, beside the session's simulator; the session's own data is untouched)"
            return DispatchQueue.main.sync { self.workbench?.open(apk, remember: true, options: ["--data-slots", slot] + options, fromAgent: true) }
        }
        /// The session's slot is held until an old simulator on it has exited.
        func waitForSlot(_ session: Session) {
            let end = Date().addingTimeInterval(30)
            while Date() < end, let holder = DispatchQueue.main.sync(execute: { self.workbench?.sessions.holder(of: session.slot) }) {
                holder.waitUntilExit()
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if let path = args["apk"] as? String {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard url.pathExtension.lowercased() == "apk", FileManager.default.isReadableFile(atPath: url.path) else {
                throw Failure(message: "\(path) is not a readable .apk file")
            }
            name = url.lastPathComponent
            // Only the session's own build is the session's app: any other APK is not run on its data, nor in its place.
            let own: Bool = session.map { s in DispatchQueue.main.sync {
                let mine = [s.outputs?.apk, s.build?.apk, self.workbench?.sessions.newestAPK(for: s)].compactMap { $0?.resolvingSymlinksInPath().path }
                return mine.contains(url.resolvingSymlinksInPath().path)
            } } ?? false
            if let session, own, fresh {
                opened = throwaway(url)
            } else if let session, own {
                DispatchQueue.main.sync {
                    if let old = self.workbench?.sessions.simulator(for: session) { Engine.shared.close(old); note = " (replaced the session's running simulator; its data is kept)" }
                }
                waitForSlot(session)
                opened = DispatchQueue.main.sync { self.workbench?.sessions.startForAgent(session, from: url, options: options) }
            } else {
                mark = false
                opened = DispatchQueue.main.sync { self.workbench?.open(url, remember: true, options: options, fromAgent: true) }
            }
        } else {
            guard let session else {
                throw Failure(message: "this folder is not a worktree of a repository added to Greenroom: pass apk")
            }
            let label = session.branch ?? session.shortHead
            let found: (alive: Simulator?, apk: URL?) = DispatchQueue.main.sync {
                (self.workbench?.sessions.simulator(for: session), self.workbench?.sessions.newestAPK(for: session))
            }
            if let alive = found.alive, !fresh {
                DispatchQueue.main.sync { _ = self.workbench?.sessions.activate(session) }
                opened = alive
                name = "the session's running simulator"
                note = " (already running; device and other options not applied)"
            } else {
                guard let apk = found.apk else { throw Failure(message: "no build yet for \(label)") }
                name = apk.lastPathComponent
                if fresh { opened = throwaway(apk) }
                else {
                    waitForSlot(session)
                    opened = DispatchQueue.main.sync { self.workbench?.sessions.startForAgent(session, from: apk, options: options) }
                }
            }
        }
        guard let sim = opened else { throw Failure(message: "Greenroom could not start \(name)") }
        currentSim = sim
        // Marked as the session's, on whatever slot it runs.
        if let session, mark { DispatchQueue.main.sync { sim.agentSession = session.worktree.path } }
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline {
            let state = DispatchQueue.main.sync { sim.state }
            if state == .running { break }
            if case .ended(let code) = state { throw Failure(message: "\(name) ended while starting (exit \(code)):\n" + tail(sim, 12)) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard DispatchQueue.main.sync(execute: { sim.state }) == .running else { throw Failure(message: "\(name) did not start within 150 s") }
        let settled = sim.sendSync("settle 20000 300", timeout: 30)
        sim.tree.update(nodes(sim))
        sim.logOffset = 0
        let size = DispatchQueue.main.sync { sim.deviceSize }
        var head = "\(id(sim)) launched \(name)\(session.map { " for \($0.branch ?? $0.shortHead)" } ?? "") \(Int(size.width))x\(Int(size.height)) | \(activity(sim))\(note)"
        if !settled.hasPrefix("settled") { head += " (still animating)" }
        return ([head] + sim.tree.nodes.filter { !$0.label.isEmpty || $0.click }.map(\.line)).joined(separator: "\n")
    }

    /// The session a simulator belongs to: the one an agent opened it for, else the one whose data slot it runs.
    func sessionOf(_ sim: Simulator) -> Session? {
        DispatchQueue.main.sync {
            guard let sessions = workbench?.sessions else { return nil }
            if let path = sim.agentSession, let s = sessions.sessions.first(where: { $0.worktree.path == path }) { return s }
            return sessions.session(forSimulator: sim)
        }
    }

    private func simulators() -> String {
        let sims = all()
        var lines = sims.map { s -> String in
            let state = DispatchQueue.main.sync { s.state }
            let size = DispatchQueue.main.sync { s.deviceSize }
            let what: String
            switch state {
            case .starting: what = "starting"
            case .running: what = "running \(Int(size.width))x\(Int(size.height)) | \(activity(s))"
            case .ended(let code): what = "ended (exit \(code))"
            }
            let owner = sessionOf(s).map { " (session \($0.branch ?? $0.shortHead))" } ?? ""
            return "\(id(s)) \(s.apk.path)\(owner) \(what)" + (s.options.isEmpty ? "" : " [\(s.options.joined(separator: " "))]")
        }
        if lines.isEmpty { lines.append("no simulators") }
        let recent = Recents.all.prefix(8).map(\.path)
        if !recent.isEmpty { lines.append("recent: " + recent.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    private func close(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        let name = id(s)
        DispatchQueue.main.sync { Engine.shared.close(s) }
        return "\(name) closed"
    }

    private func tap(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        let x: Int, y: Int, what: String
        if let ref = args["ref"] as? String {
            let n = try resolve(s, ref: ref)
            (x, y) = n.center
            what = n.label.isEmpty ? ref : "\(ref) \(ScreenNode.quote(n.label))"
        } else if let t = args["text"] as? String {
            let n = try find(s, text: t)
            (x, y) = n.center
            what = ScreenNode.quote(n.label)
        } else if let px = args["x"] as? Int, let py = args["y"] as? Int {
            (x, y, what) = (px, py, "\(px),\(py)")
        } else {
            throw Failure(message: "tap needs ref, text, or x and y")
        }
        showTouch(s, x, y)
        return try act(s, "tap \(x) \(y)", head: "tapped \(what)")
    }

    private func type(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        guard let t = args["text"] as? String else { throw Failure(message: "text is required") }
        let before = activity(s)
        var target: ScreenNode?
        if let ref = args["ref"] as? String { target = try resolve(s, ref: ref) }
        else if let tt = args["tap_text"] as? String { target = try find(s, text: tt) }
        if let target {
            let (x, y) = target.center
            showTouch(s, x, y)
            _ = try command(s, "tap \(x) \(y)")
            _ = s.sendSync("settle 1500 100", timeout: 5)
        }
        _ = try command(s, "type64 " + Data(t.utf8).base64EncodedString())
        if args["enter"] as? Bool == true { _ = try command(s, "key ENTER 1") }
        let shown = target?.password == true ? "\(t.count) characters" : ScreenNode.quote(t)
        return answer(s, head: "typed \(shown)", before: before)
    }

    private func key(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        guard let k = args["key"] as? String, k.range(of: "^[A-Za-z0-9_]{1,24}$", options: .regularExpression) != nil else {
            throw Failure(message: "key is a name such as ENTER, DEL, TAB or DPAD_DOWN")
        }
        let count = min(max(args["count"] as? Int ?? 1, 1), 50)
        let mods = (args["modifiers"] as? [String] ?? []).filter { ["ctrl", "shift", "alt", "meta"].contains($0) }
        return try act(s, (["key", k.uppercased(), String(count)] + mods).joined(separator: " "), head: "key \(k.uppercased())")
    }

    private func swipe(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        let size = DispatchQueue.main.sync { s.deviceSize }
        let w = Int(size.width), h = Int(size.height)
        var x1 = w / 2, y1 = h / 2, x2 = w / 2, y2 = h / 2
        let head: String
        if let a = args["x1"] as? Int, let b = args["y1"] as? Int, let c = args["x2"] as? Int, let d = args["y2"] as? Int {
            (x1, y1, x2, y2) = (a, b, c, d)
            head = "swiped \(a),\(b) to \(c),\(d)"
        } else if let direction = args["direction"] as? String {
            if let ref = args["ref"] as? String { (x1, y1) = try resolve(s, ref: ref).center }
            let dx = w * 2 / 5, dy = h * 2 / 5
            switch direction {
            case "up": (x2, y2) = (x1, y1 - dy)
            case "down": (x2, y2) = (x1, y1 + dy)
            case "left": (x2, y2) = (x1 - dx, y1)
            case "right": (x2, y2) = (x1 + dx, y1)
            default: throw Failure(message: "direction is up, down, left or right")
            }
            if args["ref"] == nil {   // from the centre: start so the gesture stays on screen
                switch direction {
                case "up": (y1, y2) = (h * 7 / 10, h * 3 / 10)
                case "down": (y1, y2) = (h * 3 / 10, h * 7 / 10)
                case "left": (x1, x2) = (w * 7 / 10, w * 3 / 10)
                default: (x1, x2) = (w * 3 / 10, w * 7 / 10)
                }
            }
            head = "swiped \(direction)"
        } else {
            throw Failure(message: "swipe needs direction, or x1, y1, x2 and y2")
        }
        let ms = min(max(args["ms"] as? Int ?? 300, 50), 5000)
        showTouch(s, x1, y1)
        // `drag` holds before lifting, so the same swipe scrolls the same distance every time (no fling).
        return try act(s, "drag \(x1) \(y1) \(x2) \(y2) \(ms)", head: head)
    }

    private func openURL(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        guard let url = args["url"] as? String, !url.contains(where: \.isWhitespace), url.contains(":") else {
            throw Failure(message: "url is a link such as myapp://screen")
        }
        return try act(s, "open \(url)", head: "opened \(url)")
    }

    private func set(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        guard let setting = args["setting"] as? String, let pattern = AgentTools.settings[setting] else {
            throw Failure(message: "setting is one of \(AgentTools.settings.keys.sorted().joined(separator: ", "))")
        }
        let value = (args["value"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw Failure(message: pattern == "^$" ? "\(setting) takes no value" : "\(setting): \(ScreenNode.quote(value)) is not a value it takes")
        }
        let line = value.isEmpty ? setting : "\(setting) \(value)"
        let before = activity(s)
        _ = try command(s, line, timeout: 60)
        _ = s.sendSync("settle 8000 250", timeout: 15)   // a configuration change rebuilds the screen
        return answer(s, head: line, before: before)
    }

    private func screen(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        s.tree.update(nodes(s))
        var shown = s.tree.nodes.filter { !$0.label.isEmpty || $0.click || $0.field }
        if let t = args["text"] as? String, !t.isEmpty { shown = shown.filter { $0.label.localizedCaseInsensitiveContains(t) } }
        let bounds = args["bounds"] as? Bool == true
        let size = DispatchQueue.main.sync { s.deviceSize }
        let lines = shown.map { bounds ? "\($0.line) [\($0.left),\($0.top),\($0.right),\($0.bottom)]" : $0.line }
        return (["\(id(s)) \(Int(size.width))x\(Int(size.height)) | \(activity(s)) | \(shown.count) nodes"] + lines).joined(separator: "\n")
    }

    private func check(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        _ = s.sendSync("settle 2500 150", timeout: 10)
        let labels = nodes(s).map(\.label).filter { !$0.isEmpty }
        func on(_ t: String) -> Bool { labels.contains { $0.localizedCaseInsensitiveContains(t) } }
        let missing = (args["visible"] as? [String] ?? []).filter { !on($0) }
        let present = (args["absent"] as? [String] ?? []).filter { on($0) }
        if missing.isEmpty, present.isEmpty { return "PASS | \(activity(s))" }
        var parts: [String] = []
        if !missing.isEmpty { parts.append("not on screen: " + missing.map(ScreenNode.quote).joined(separator: ", ")) }
        if !present.isEmpty { parts.append("on screen but should not be: " + present.map(ScreenNode.quote).joined(separator: ", ")) }
        return "FAIL | \(activity(s)) | " + parts.joined(separator: "; ")
    }

    private func waitFor(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        guard let t = args["text"] as? String, !t.isEmpty else { throw Failure(message: "text is required") }
        let gone = args["gone"] as? Bool == true
        let timeout = Double(min(max(args["timeout_ms"] as? Int ?? 10_000, 100), 120_000)) / 1000
        let before = activity(s)
        let start = Date()
        while true {
            let on = nodes(s).contains { $0.label.localizedCaseInsensitiveContains(t) }
            if on != gone {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                return answer(s, head: "\(ScreenNode.quote(t)) \(gone ? "gone" : "on screen") after \(ms) ms", before: before)
            }
            if Date().timeIntervalSince(start) > timeout {
                throw Failure(message: "\(ScreenNode.quote(t)) was \(gone ? "still" : "not") on screen after \(Int(timeout * 1000)) ms | \(activity(s))")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func screenshot(_ args: [String: Any]) throws -> [[String: Any]] {
        let s = try sim(args)
        let dir = Engine.shared.screenshots
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "agent-\(UUID().uuidString).png"
        let file = dir.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = try command(s, "shot screenshots/\(name)")
        guard let source = NSBitmapImageRep(data: (try? Data(contentsOf: file)) ?? Data()), let cg = source.cgImage else {
            throw Failure(message: "the screenshot could not be read")
        }
        let annotate = args["annotate"] as? Bool == true
        if annotate { s.tree.update(nodes(s)) }
        let maxSize = args["max_size"] as? Int ?? 1000
        let longest = max(cg.width, cg.height)
        let scale = maxSize > 0 && longest > maxSize ? CGFloat(maxSize) / CGFloat(longest) : 1
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(message: "the screenshot could not be drawn") }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var legend = ""
        if annotate {
            let marked = s.tree.nodes.filter { $0.click || $0.field }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            for n in marked {
                // Device pixels have their origin at the top; the bitmap context's is at the bottom.
                let r = CGRect(x: CGFloat(n.left) * scale, y: CGFloat(h) - CGFloat(n.bottom) * scale,
                               width: CGFloat(n.right - n.left) * scale, height: CGFloat(n.bottom - n.top) * scale)
                NSColor.systemPink.setStroke()
                let box = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
                box.lineWidth = 2
                box.stroke()
                let tag = NSAttributedString(string: n.ref, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white, .backgroundColor: NSColor.systemPink])
                // Above the box's corner, so the tag does not cover the node's own text; inside when there is no room.
                let above = r.maxY + tag.size().height <= CGFloat(h)
                tag.draw(at: CGPoint(x: max(r.minX, 0), y: above ? r.maxY : r.maxY - tag.size().height))
            }
            NSGraphicsContext.restoreGraphicsState()
            legend = "\n" + marked.map(\.line).joined(separator: "\n")
        }
        guard let out = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else {
            throw Failure(message: "the screenshot could not be encoded")
        }
        return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                ["type": "text", "text": "\(id(s)) \(w)x\(h) (device \(cg.width)x\(cg.height)) | \(activity(s))\(legend)"]]
    }

    private func compare(_ args: [String: Any]) throws -> [[String: Any]] {
        let live = all().filter { $0.state == .running }
        func pick(_ key: String, _ fallback: Int) throws -> Simulator {
            if let want = args[key] as? String {
                guard let s = live.first(where: { id($0) == want }) else { throw Failure(message: "no running simulator \(want): call simulators") }
                return s
            }
            guard live.count > fallback else { throw Failure(message: "compare needs two running simulators: launch the other build or device first") }
            return live[fallback]
        }
        let base = try pick("base", 0), other = try pick("other", 1)
        guard base !== other else { throw Failure(message: "base and other are the same simulator") }
        let (c, image) = base.compare(with: other)
        let head = "\(id(base)) vs \(id(other)): \(c.isSame ? "SAME" : "DIFFERENT") | \(c.summary)"
        var content = text(([head] + c.lines()).joined(separator: "\n"))
        if args["map"] as? Bool == true, let image, !c.cells.isEmpty, let png = ScreenComparison.map(b: image, cells: c.cells) {
            content.insert(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"], at: 0)
        }
        return content
    }

    private func logs(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        guard let handle = try? FileHandle(forReadingFrom: s.log) else { return "no log" }
        defer { try? handle.close() }
        try? handle.seek(toOffset: s.logOffset)
        let data = handle.readDataToEndOfFile()
        s.logOffset += UInt64(data.count)
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { !$0.contains("[apksim] control ") }   // the engine's echo of each command sent to it
        if let f = args["filter"] as? String, !f.isEmpty { lines = lines.filter { $0.localizedCaseInsensitiveContains(f) } }
        let limit = min(max(args["lines"] as? Int ?? 60, 1), 500)
        let dropped = max(lines.count - limit, 0)
        let shown = lines.suffix(limit).map { $0.count > 400 ? String($0.prefix(400)) + "…" : $0 }
        if shown.isEmpty { return "no new log lines" }
        return (dropped > 0 ? ["(\(dropped) earlier lines left out)"] : []).joined() + (dropped > 0 ? "\n" : "") + shown.joined(separator: "\n")
    }

    private func tail(_ sim: Simulator, _ count: Int) -> String {
        let all = (try? String(contentsOf: sim.log, encoding: .utf8)) ?? ""
        return all.split(separator: "\n").suffix(count).joined(separator: "\n")
    }
}
