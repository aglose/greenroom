import AppKit
import Foundation

/// What an agent may do: the tools, their schemas and their answers. Every action answers with what changed on
/// screen since the last answer, in compact lines, so an agent seldom needs the whole screen or a picture.
final class AgentTools {
    struct Failure: Error { let message: String }

    weak var workbench: Workbench?
    /// One line per call, for the person watching (main thread).
    var onActivity: ((_ tool: String, _ summary: String, _ failed: Bool) -> Void)?
    /// The person at the Mac paused the agent: actions are refused until it is lifted.
    var paused = false

    private var ids: [ObjectIdentifier: String] = [:]
    private var nextID = 1

    static let instructions = "Drives Android apps in Greenroom on this Mac; the person there sees the same simulators. "
        + "launch an APK, then tap/type/key/swipe: each action answers with the nodes that changed (+ added, - removed, "
        + "~ changed; refs like e3 stay the same while a node is on screen), so call screen or screenshot only when you "
        + "need all of it. check verifies texts in one call. APKs and their data stay on this Mac. "
        + "Sign-ins are the owner's: never ask for or type passwords."

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
    private static let settings: [String: String] = [
        "appearance": "^(dark|light|toggle)$", "locale": "^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$", "fontscale": "^[0-9.]{1,4}$",
        "rotate": "^(left|right|portrait|landscape)$", "network": "^(online|offline|3g|lossy)$",
        "device": "^(phone|foldable|tablet|desktop|tv|watch|[0-9]{3,4}x[0-9]{3,4}(@[0-9.]+)?)$",
        "timezone": "^[A-Za-z_]+(/[A-Za-z_+-]+)*$", "animscale": "^[0-9.]{1,4}$",
        "permission": "^(allow|deny|reset|(grant|revoke) [A-Za-z0-9_.]+)$", "home": "^$", "resume": "^$", "lock": "^$",
        "unlock": "^$", "recreate": "^$", "restart": "^$", "process-death": "^$",
    ]

    static let readOnly: Set<String> = ["simulators", "screen", "screenshot", "logs", "check", "wait_for", "compare"]

    static let tools: [(name: String, description: String, schema: [String: Any])] = [
        ("launch", "Start an APK in Greenroom. Answers with the screen's nodes.", schema([
            "apk": ["type": "string", "description": "path of the .apk"],
            "device": ["type": "string", "enum": devices],
            "appearance": ["type": "string", "enum": ["light", "dark"]],
            "locale": str, "font_scale": ["type": "number"],
            "fresh": ["type": "boolean", "description": "empty the app's data first"],
        ], required: ["apk"], sim: false)),
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
        ("screenshot", "A picture of the screen, for what the nodes do not show. annotate draws each tappable node's ref on it.",
         schema(["max_size": ["type": "integer", "description": "longest side in pixels (default 1000, 0 for full size)"], "annotate": bool])),
        ("compare", "How two simulators' screens differ (two builds, or two devices): - only on the base, + only on the other, > moved; "
            + "and, for screens of one size, the share of pixels that differ. map adds a picture of where.",
         schema(["base": ["type": "string", "description": "simulator id compared against (default: the first running)"],
                 "other": ["type": "string", "description": "simulator id compared (default: the second running)"], "map": bool], sim: false)),
        ("logs", "The app's log lines since the last call (android.util.Log and the engine's own).",
         schema(["filter": ["type": "string", "description": "keep lines containing this"], "lines": int])),
    ]

    static func list() -> [[String: Any]] {
        tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema,
                     "annotations": ["readOnlyHint": readOnly.contains($0.name), "openWorldHint": false]] }
    }

    // MARK: Calling

    /// Runs a tool. Never on the main thread. Answers with MCP content blocks.
    func call(_ name: String, _ args: [String: Any]) throws -> [[String: Any]] {
        guard AgentTools.tools.contains(where: { $0.name == name }) else { throw Failure(message: "unknown tool \(name)") }
        if paused, !AgentTools.readOnly.contains(name) {
            throw Failure(message: "The person at the Mac has paused the agent in Greenroom. Ask them to resume it.")
        }
        do {
            let content: [[String: Any]]
            switch name {
            case "launch": content = text(try launch(args))
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
            case "screenshot": content = try screenshot(args)
            case "logs": content = text(try logs(args))
            case "compare": content = try compare(args)
            default: throw Failure(message: "unknown tool \(name)")
            }
            let first = (content.first?["text"] as? String)?.split(separator: "\n").first.map(String.init) ?? "picture"
            report(name, first, failed: false)
            return content
        } catch let f as Failure {
            report(name, f.message, failed: true)
            throw f
        }
    }

    private func report(_ tool: String, _ summary: String, failed: Bool) {
        DispatchQueue.main.async { self.onActivity?(tool, summary, failed) }
    }

    private func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }

    // MARK: Finding simulators and nodes

    private func id(_ sim: Simulator) -> String {
        let key = ObjectIdentifier(sim)
        if let known = ids[key] { return known }
        let made = "s\(nextID)"
        nextID += 1
        ids[key] = made
        return made
    }

    private func all() -> [Simulator] { DispatchQueue.main.sync { Engine.shared.simulators } }

    private func sim(_ args: [String: Any]) throws -> Simulator {
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
        return ([first] + (lines.isEmpty ? ["no change"] : lines)).joined(separator: "\n")
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

    private func launch(_ args: [String: Any]) throws -> String {
        guard let path = args["apk"] as? String else { throw Failure(message: "apk is required") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard url.pathExtension.lowercased() == "apk", FileManager.default.isReadableFile(atPath: url.path) else {
            throw Failure(message: "\(path) is not a readable .apk file")
        }
        var options: [String] = []
        if let d = args["device"] as? String {
            guard AgentTools.devices.contains(d) else { throw Failure(message: "device is one of \(AgentTools.devices.joined(separator: ", "))") }
            options += ["--device", d]
        }
        if let a = args["appearance"] as? String, ["light", "dark"].contains(a) { options += ["--appearance", a] }
        if let l = args["locale"] as? String, l.range(of: AgentTools.settings["locale"]!, options: .regularExpression) != nil { options += ["--locale", l] }
        if let f = args["font_scale"] as? Double, f >= 0.5, f <= 3 { options += ["--font-scale", String(f)] }
        if args["fresh"] as? Bool == true { options.append("--fresh") }

        let opened: Simulator? = DispatchQueue.main.sync { self.workbench?.open(url, remember: true, options: options, fromAgent: true) }
        guard let sim = opened else { throw Failure(message: "Greenroom could not start \(url.lastPathComponent)") }
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline {
            let state = DispatchQueue.main.sync { sim.state }
            if state == .running { break }
            if case .ended(let code) = state { throw Failure(message: "\(url.lastPathComponent) ended while starting (exit \(code)):\n" + tail(sim, 12)) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard DispatchQueue.main.sync(execute: { sim.state }) == .running else { throw Failure(message: "\(url.lastPathComponent) did not start within 150 s") }
        let settled = sim.sendSync("settle 20000 300", timeout: 30)
        sim.tree.update(nodes(sim))
        sim.logOffset = 0
        let size = DispatchQueue.main.sync { sim.deviceSize }
        var head = "\(id(sim)) launched \(url.lastPathComponent) \(Int(size.width))x\(Int(size.height)) | \(activity(sim))"
        if !settled.hasPrefix("settled") { head += " (still animating)" }
        return ([head] + sim.tree.nodes.filter { !$0.label.isEmpty || $0.click }.map(\.line)).joined(separator: "\n")
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
            return "\(id(s)) \(s.apk.path) \(what)" + (s.options.isEmpty ? "" : " [\(s.options.joined(separator: " "))]")
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
