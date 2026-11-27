import Foundation

/// The agent's debugging tools: what the Network, Diagnostics, Device and Inspector panes show, the developer hooks
/// (adb, a debugger, HAR traffic), the flight recorder and its replays, instrumentation tests and screenshot tests.
/// Each answers in compact text, as the driving tools do (AgentTools.swift).
extension AgentTools {
    typealias Tool = (name: String, description: String, schema: [String: Any])

    static let debugTools: [Tool] = [
        ("network", "The app's HTTP traffic as the Network pane shows it, newest last: #id METHOD STATUS ms size url (mocked when a rule "
            + "answered). filter keeps requests whose address, method or status contains it; failed keeps failures. With id: that "
            + "exchange's headers and bodies (credentials such as Authorization and Cookie are shown as ••••, bodies cut at 8 KB).",
         schema(["filter": str, "failed": bool, "limit": ["type": "integer", "description": "newest N (default 40, at most 300)"],
                 "id": ["type": "integer", "description": "one request's #id: its headers and bodies"]])),
        ("network_rule", "Mock, patch, fail or slow the app's requests (the Network pane's rules). action list (default), add, remove "
            + "or clear. add: method (GET, POST...), pattern (the address, * matches anything: https://api.example.com/v1/items*), "
            + "status (an HTTP status answered from Greenroom; 0 lets the server answer, only delayed), body (the answer, or with "
            + "patch a JSON merge patch over the server's answer), content_type, latency_ms. The next matching request gets it.",
         schema(["action": ["type": "string", "enum": ["list", "add", "remove", "clear"]],
                 "method": str, "pattern": str, "status": int, "patch": bool, "body": str, "content_type": str, "latency_ms": int,
                 "rule": ["type": "integer", "description": "the rule's id, for remove"]])),
        ("perf", "How the app runs now: frame rate and frame times (p50, p95, share of frames on pace) since the last call, Java heap, "
            + "memory footprint, CPU use over about a second, and the time a cold start took when the engine knows it.",
         schema(["sample_ms": ["type": "integer", "description": "how long CPU use is measured over, 200-5000 ms (default 1000)"]])),
        ("accessibility", "Audits the screen for accessibility: controls with no label, touch targets under 48 dp, and the like. Each "
            + "finding gives its bounds and the nearest node's ref.", schema()),
        ("background", "The app's scheduled background work: jobs, services and alarms. run_job runs a scheduled job now (its number, "
            + "from the list).", schema(["run_job": int])),
        ("clipboard", "The device's clipboard: answers it, or with text puts text on it.", schema(["text": str])),
        ("inspect", "Everything about one node: kind, label, text, hint, description, resource id, bounds, size, where a tap lands, "
            + "the box that takes the tap, and accessibility problems. By ref or text.", schema(["ref": str, "text": str])),
        ("devtools", "Developer hooks on a simulator. Each but status and har_list restarts the app with the same options and data. "
            + "action: status (default), adb_on (answers the adb connect command), adb_off, debugger_on (a JDWP port for Android "
            + "Studio's Remote JVM Debug), debugger_off, har_record (record all traffic to a HAR in Greenroom's state folder), "
            + "har_save (write it now), har_stop, har_list (the recorded HARs), har_replay (answer every request from a recorded "
            + "HAR, by name; nothing leaves the Mac).",
         schema(["action": ["type": "string", "enum": ["status", "adb_on", "adb_off", "debugger_on", "debugger_off", "har_record", "har_save", "har_stop", "har_list", "har_replay"]],
                 "name": ["type": "string", "description": "har_replay: a HAR's name from har_list"]])),
        ("recorder", "The flight recorder: it keeps the last while of input, log, network, database and screen of a simulator so a "
            + "problem can be replayed. action status (default), on, off, save (writes it as a recording and answers its name), "
            + "or list (the saved recordings, newest first).",
         schema(["action": ["type": "string", "enum": ["status", "on", "off", "save", "list"]]])),
        ("replay", "Replays a saved recording headless, on its own build or on another APK, and answers whether the app did the same: "
            + "same, diverged (where, and how many pixels), crashed, or cannot replay. Waits up to timeout_s; calling again with the "
            + "same recording joins a replay still running.",
         schema(["recording": ["type": "string", "description": "a recording's name, from recorder list"],
                 "apk": ["type": "string", "description": "path of another build's .apk to replay on (default: the recording's own)"],
                 "timeout_s": ["type": "integer", "description": "10-200 s (default 200)"]], required: ["recording"], sim: false)),
        ("tests", "Runs the app's instrumentation tests headless (androidTest APK) and answers passed, failed and ignored, with each "
            + "failure's first stack lines. Without test_apk it answers the last run (still running or not). stop ends a run.",
         schema(["test_apk": ["type": "string", "description": "path of the androidTest .apk"],
                 "app_apk": ["type": "string", "description": "path of the app's .apk (default: this worktree's newest build, else the only running simulator's)"],
                 "filter": ["type": "string", "description": "a class, Class#method or package, as -e class takes it"],
                 "stop": bool, "timeout_s": ["type": "integer", "description": "10-200 s (default 200); the run goes on, and tests without test_apk answers it"]], sim: false)),
        ("snapshots", "The screenshot tests the owner set up in Snapshots (a spec of screens and the golden pictures). action status "
            + "(default: the last results), run (capture and compare with the goldens, and wait), record (capture new goldens), or "
            + "accept (make the named results' captures the goldens: ids as status lists them, screen/combo). Accept and record "
            + "write picture files in the repository.",
         schema(["action": ["type": "string", "enum": ["status", "run", "record", "accept"]], "ids": strings,
                 "timeout_s": ["type": "integer", "description": "10-200 s (default 200)"]], sim: false)),
    ]

    /// Runs a debugging tool; nil when `name` is not one.
    func debugCall(_ name: String, _ args: [String: Any], _ connection: Connection) throws -> [[String: Any]]? {
        switch name {
        case "network": return text(try network(args))
        case "network_rule": return text(try networkRule(args))
        case "perf": return text(try perf(args))
        case "accessibility": return text(try accessibility(args))
        case "background": return text(try background(args))
        case "clipboard": return text(try clipboard(args))
        case "inspect": return text(try inspect(args))
        case "devtools": return text(try devtools(args))
        case "recorder": return text(try recorder(args))
        case "replay": return text(try replay(args))
        case "tests": return text(try tests(args, connection))
        case "snapshots": return text(try snapshots(args, connection))
        default: return nil
        }
    }

    // MARK: Network

    /// Header names whose values are credentials: never answered.
    static let secretHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token", "x-csrf-token", "x-xsrf-token"]

    static func isSecretHeader(_ name: String) -> Bool {
        let n = name.lowercased()
        return secretHeaders.contains(n) || n.contains("token") || n.contains("secret") || n.contains("password") || n.contains("api-key") || n.contains("apikey")
    }

    private static func bytes(_ n: Int) -> String {
        n < 1024 ? "\(n) B" : n < 1_048_576 ? String(format: "%.1f KB", Double(n) / 1024) : String(format: "%.1f MB", Double(n) / 1_048_576)
    }

    private func network(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        if let id = args["id"] as? Int { return try networkDetail(s, id) }
        var all = s.activity.requests
        let total = all.count
        if let f = (args["filter"] as? String)?.trimmingCharacters(in: .whitespaces), !f.isEmpty {
            all = all.filter { $0.url.localizedCaseInsensitiveContains(f) || String($0.status) == f || $0.method.localizedCaseInsensitiveContains(f) }
        }
        if args["failed"] as? Bool == true { all = all.filter(\.failed) }
        let limit = min(max(args["limit"] as? Int ?? 40, 1), 300)
        let shown = all.suffix(limit)
        guard !shown.isEmpty else {
            return total == 0 ? "\(id(s)) no requests yet (the app has made none since it started, or it uses no HTTP)" : "\(id(s)) no request of \(total) matches"
        }
        var lines = ["\(id(s)) \(shown.count) of \(total) requests" + (all.count > shown.count ? " (\(all.count - shown.count) earlier matches left out)" : "")]
        for e in shown {
            var line = "#\(e.id) \(e.method) \(e.status == 0 ? "failed" : String(e.status)) \(e.ms) ms \(Self.bytes(e.respBytes))"
            if e.mocked { line += " mocked" }
            let url = e.url.count > 300 ? String(e.url.prefix(300)) + "…" : e.url
            line += " " + url
            if let err = e.error, !err.isEmpty { line += " | " + err }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func networkDetail(_ s: Simulator, _ id: Int) throws -> String {
        guard let e = s.activity.requests.first(where: { $0.id == id }) else { throw Failure(message: "no request #\(id): call network") }
        let answer = try command(s, "network detail \(id)")
        guard let d = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String: Any] else { throw Failure(message: "network detail: \(answer.prefix(200))") }
        var lines = ["#\(e.id) \(e.method) \(e.url)", "status \(e.status == 0 ? "failed" : String(e.status)) in \(e.ms) ms" + (e.http.map { ", \($0)" } ?? "") + (e.mocked ? ", answered by a rule" : "")]
        if let err = d["error"] as? String, !err.isEmpty { lines.append("error: \(err)") }
        func headers(_ key: String, _ title: String) {
            guard let list = d[key] as? [[String]], !list.isEmpty else { return }
            lines.append(title + ":")
            for h in list where h.count == 2 { lines.append("  \(h[0]): \(Self.isSecretHeader(h[0]) ? "••••" : h[1])") }
        }
        func body(_ key: String, cut: String, _ title: String, type: String?) {
            guard let b64 = d[key] as? String, let data = Data(base64Encoded: b64), !data.isEmpty else { return }
            let limit = 8192
            var shown: String
            if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]) {
                shown = String(decoding: pretty, as: UTF8.self)
            } else if let text = String(data: data, encoding: .utf8) {
                shown = text
            } else {
                lines.append("\(title): \(Self.bytes(data.count)) of binary\(type.map { " (\($0))" } ?? "")")
                return
            }
            let cutByEngine = d[cut] as? Bool == true
            if shown.count > limit { shown = String(shown.prefix(limit)) + "\n… (\(shown.count - limit) more characters)" }
            lines.append("\(title) (\(Self.bytes(data.count))\(cutByEngine ? ", cut by the engine" : "")):")
            lines.append(shown)
        }
        headers("reqHeaders", "request headers")
        body("reqBody", cut: "reqCut", "request body", type: nil)
        headers("respHeaders", "response headers")
        headers("trailers", "trailers")
        body("respBody", cut: "respCut", "response body", type: e.type)
        return lines.joined(separator: "\n")
    }

    private func networkRule(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        let action = args["action"] as? String ?? "list"
        switch action {
        case "add":
            guard let method = (args["method"] as? String)?.uppercased(), method.range(of: "^[A-Z]{3,10}$", options: .regularExpression) != nil else {
                throw Failure(message: "add needs method: GET, POST, PUT, PATCH, DELETE...")
            }
            guard let pattern = args["pattern"] as? String, !pattern.isEmpty, pattern.count <= 2000, !pattern.contains(where: \.isWhitespace) else {
                throw Failure(message: "add needs pattern: an address with no spaces, * for anything (https://api.example.com/v1/items*)")
            }
            let patch = args["patch"] as? Bool == true
            let status = args["status"] as? Int ?? (patch ? 200 : 0)
            guard patch || status == 0 || (100...599).contains(status) else { throw Failure(message: "status is an HTTP status (100-599), or 0 to delay the server's own answer") }
            let latency = min(max(args["latency_ms"] as? Int ?? 0, 0), 120_000)
            let body = Data((args["body"] as? String ?? "").utf8)
            if patch, (try? JSONSerialization.jsonObject(with: body)) == nil { throw Failure(message: "a patch's body is a JSON merge patch (an object)") }
            if !patch, status == 0, latency == 0 { throw Failure(message: "a rule with status 0 only delays: give latency_ms, or a status to answer with") }
            var type = (args["content_type"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if type.isEmpty { type = body.isEmpty ? "-" : ((try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])) != nil ? "application/json" : "text/plain") }
            guard type == "-" || type.range(of: "^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+(;[ A-Za-z0-9=._-]*)?$", options: .regularExpression) != nil else {
                throw Failure(message: "content_type is a media type such as application/json")
            }
            let kind = patch ? "patch" : String(status)
            _ = try command(s, "network rule add \(method) \(pattern) \(kind) \(latency) \(type.replacingOccurrences(of: " ", with: "")) \(body.isEmpty ? "-" : body.base64EncodedString())")
            return "rule added: the next \(method) to \(pattern) " + (patch ? "is patched" : status == 0 ? "waits \(latency) ms" : "gets \(status)" + (latency > 0 ? " after \(latency) ms" : ""))
                + " (the app's connections to that host are reopened)\n" + (try ruleList(s))
        case "remove":
            guard let rule = args["rule"] as? Int else { throw Failure(message: "remove needs rule: its id, from list") }
            _ = try command(s, "network rule remove \(rule)")
            return "rule \(rule) removed\n" + (try ruleList(s))
        case "clear":
            _ = try command(s, "network rule clear")
            return "every rule removed: the app's requests reach the network again"
        case "list": return try ruleList(s)
        default: throw Failure(message: "action is list, add, remove or clear")
        }
    }

    private func ruleList(_ s: Simulator) throws -> String {
        let answer = try command(s, "network rule list")
        let list = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [[String: Any]] ?? []
        if list.isEmpty { return "no rules" }
        return list.map { r in
            let what: String
            if r["patch"] as? Bool == true { what = "patch" }
            else if r["forward"] != nil { what = "forward" }
            else if let st = r["status"] as? Int, st > 0 { what = "answers \(st)" }
            else { what = "delays" }
            let latency = (r["latencyMs"] as? Int).flatMap { $0 > 0 ? " +\($0) ms" : nil } ?? ""
            return "rule \(r["id"] as? Int ?? 0): \(r["method"] as? String ?? "*") \(r["pattern"] as? String ?? "") \(what)\(latency), \(r["hits"] as? Int ?? 0) hits"
        }.joined(separator: "\n")
    }

    // MARK: Diagnostics

    private func perf(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        let wait = Double(min(max(args["sample_ms"] as? Int ?? 1000, 200), 5000)) / 1000
        let first = DiagnosticsPane.parseStats(s.sendSync("stats"))
        let t0 = ProcessInfo.processInfo.systemUptime
        Thread.sleep(forTimeInterval: wait)
        let framesReply = s.sendSync("frames")
        let statsReply = s.sendSync("stats")
        let second = DiagnosticsPane.parseStats(statsReply)
        let elapsed = ProcessInfo.processInfo.systemUptime - t0
        let m = DiagnosticsPane.parseFrames(framesReply)
        var lines = ["\(id(s)) | \(activity(s))"]
        if let fps = m.fps {
            lines.append(fps > 0 ? String(format: "frames: %.0f fps", fps) + (m.p50.map { String(format: ", p50 %.1f ms", $0) } ?? "")
                + (m.p95.map { String(format: ", p95 %.1f ms", $0) } ?? "") + (m.pace.map { ", \($0) on pace" } ?? "")
                : "frames: none drawn since the last call (the screen is still)")
        }
        if let h = second["heapUsedMb"] { lines.append(String(format: "java heap: %.1f MB", h)) }
        if let f = second["footprintMb"] { lines.append(String(format: "footprint: %.1f MB", f)) }
        if let a = first["cpuMs"], let b = second["cpuMs"], elapsed > 0 {
            lines.append(String(format: "cpu: %.0f%% of one core over %.1f s", max(0, (b - a) / (elapsed * 1000) * 100), elapsed))
        }
        let known: Set<String> = ["heapUsedMb", "footprintMb", "cpuMs"]
        let rest = second.filter { !known.contains($0.key) }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value == $0.value.rounded() ? String(Int($0.value)) : String(format: "%.1f", $0.value))" }
        if !rest.isEmpty { lines.append("engine: " + rest.joined(separator: " ")) }
        if lines.count == 1 { lines.append("the engine gave no figures: \(framesReply.prefix(200)) | \(statsReply.prefix(200))") }
        return lines.joined(separator: "\n")
    }

    private func accessibility(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        let (head, found) = DiagnosticsPane.parseAudit(try command(s, "a11y"))
        guard !found.isEmpty else { return "\(id(s)) \(head) | \(activity(s))" }
        s.tree.update(nodes(s))
        let all = s.tree.nodes
        let lines = found.map { f -> String in
            let r = f.rect
            // The node whose bounds match the finding best: the one it overlaps most.
            let best = all.max { a, b in Self.overlap(a.frame, r) < Self.overlap(b.frame, r) }
            let near = best.flatMap { Self.overlap($0.frame, r) > 0 ? " (\($0.line))" : nil } ?? ""
            return "[\(Int(r.minX)),\(Int(r.minY)),\(Int(r.maxX)),\(Int(r.maxY))] \(f.text)\(near)"
        }
        return (["\(id(s)) \(head) | \(activity(s))"] + lines).joined(separator: "\n")
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    private func background(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        var lines: [String] = []
        if let job = args["run_job"] as? Int {
            let answer = try command(s, "jobs run \(job)")
            lines.append("job \(job): \(answer.isEmpty ? "run" : answer)")
            _ = s.sendSync("settle 2500 150", timeout: 10)
        }
        for kind in ["jobs", "services", "alarms"] {
            let items = DiagnosticsPane.items(s.sendSync(kind))
            lines.append("\(kind): " + (items.isEmpty ? "none" : "\(items.count)"))
            lines += items.prefix(30).map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    private func clipboard(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        if let t = args["text"] as? String {
            guard !t.isEmpty, t.count <= 4000 else { throw Failure(message: "text is 1 to 4000 characters") }
            _ = try command(s, "clipboard set " + t.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))
            return "clipboard set (\(t.count) characters)"
        }
        let now = try command(s, "clipboard")
        return now == "(empty)" ? "the clipboard is empty" : "clipboard: " + ScreenNode.quote(now.count > 4000 ? String(now.prefix(4000)) + "…" : now)
    }

    private func inspect(_ args: [String: Any]) throws -> String {
        let s = try sim(args)
        let n: ScreenNode
        if let ref = args["ref"] as? String {
            n = try resolve(s, ref: ref)
        } else if let t = args["text"] as? String, !t.isEmpty {
            let fresh = nodes(s)
            guard let hit = fresh.first(where: { $0.label == t }) ?? fresh.first(where: { $0.label.localizedCaseInsensitiveContains(t) }) else {
                throw Failure(message: "no node with text \(ScreenNode.quote(t)) on screen: call screen")
            }
            n = hit
        } else {
            throw Failure(message: "inspect needs ref or text")
        }
        s.tree.update(nodes(s))
        let ref = s.tree.nodes.first { $0.left == n.left && $0.top == n.top && $0.right == n.right && $0.bottom == n.bottom && $0.label == n.label }?.ref ?? ""
        let kind = n.field ? (n.password ? "password field" : "text field") : (n.click ? "tappable" : "text")
        var lines = ["\(ref.isEmpty ? "node" : ref) \(kind)"]
        if n.password { lines.append("text: (\(n.text.count) characters, not shown)") }
        else if !n.text.isEmpty { lines.append("text: " + ScreenNode.quote(n.text)) }
        if !n.hint.isEmpty { lines.append("hint: " + ScreenNode.quote(n.hint)) }
        if !n.desc.isEmpty { lines.append("content description: " + ScreenNode.quote(n.desc)) }
        if !n.resourceId.isEmpty { lines.append("resource id: " + n.resourceId) }
        let w = n.right - n.left, h = n.bottom - n.top
        lines.append("bounds: [\(n.left),\(n.top),\(n.right),\(n.bottom)], \(w)x\(h) px")
        let (cx, cy) = n.center
        lines.append("a tap lands at \(cx),\(cy)")
        if let hb = n.hitBox { lines.append("taken by the box [\(hb.left),\(hb.top),\(hb.right),\(hb.bottom)] around it (a row or tab)") }
        var problems: [String] = []
        if (n.click || n.field) && n.label.isEmpty { problems.append("no label for a screen reader") }
        let density = DispatchQueue.main.sync { DevHooks.value("--density", in: s.options).flatMap { Double($0) } } ?? Self.density(of: s)
        let dpW = Double(n.frame.width) / density, dpH = Double(n.frame.height) / density
        if n.click || n.field, min(dpW, dpH) < 48 { problems.append(String(format: "touch target %.0fx%.0f dp, under 48 dp", dpW, dpH)) }
        lines.append(problems.isEmpty ? "accessibility: no problem found" : "accessibility: " + problems.joined(separator: "; "))
        return lines.joined(separator: "\n")
    }

    /// The screen's density, from its width (a phone of 1080 px wide is 2.625).
    private static func density(of s: Simulator) -> Double {
        let w = DispatchQueue.main.sync { min(s.deviceSize.width, s.deviceSize.height) }
        return w >= 1400 ? 2 : w >= 1000 ? 2.625 : w >= 700 ? 2 : 1.5
    }

    // MARK: Developer hooks

    /// Relaunches `sim` with `options` (DevHooks: same APK, same data, same place) and waits for the new simulator.
    private func relaunch(_ sim: Simulator, options: [String]) throws -> Simulator {
        let done = DispatchSemaphore(value: 0)
        var new: Simulator?
        DispatchQueue.main.async { DevHooks.shared.relaunch(sim, options: options) { new = $0; done.signal() } }
        guard done.wait(timeout: .now() + 120) == .success, let new else { throw Failure(message: "the simulator did not start again: call simulators") }
        let deadline = Date().addingTimeInterval(60)
        while DispatchQueue.main.sync(execute: { new.state }) == .starting, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        guard DispatchQueue.main.sync(execute: { new.state }) == .running else { throw Failure(message: "the simulator did not start again: \(tail(new, 5))") }
        new.logOffset = 0
        return new
    }

    private static var hars: URL { Engine.shared.engineState.appendingPathComponent("hars", isDirectory: true) }

    private func devtools(_ args: [String: Any]) throws -> String {
        let action = args["action"] as? String ?? "status"
        if action == "har_list" {
            let files = (FileManager.default.enumerator(at: Self.hars, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])?.allObjects as? [URL] ?? [])
                .filter { $0.pathExtension == "har" }
                .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                    > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
            if files.isEmpty { return "no HARs recorded (devtools har_record records one)" }
            return files.prefix(30).map { f in
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { age($0) } ?? ""
                return "\(f.deletingPathExtension().lastPathComponent) \(Self.bytes(size)) \(date)"
            }.joined(separator: "\n")
        }
        let s = try sim(args)
        let opts = DispatchQueue.main.sync { s.options }
        switch action {
        case "status":
            var lines = ["\(id(s)) | \(activity(s))"]
            let adb = DispatchQueue.main.sync { DevHooks.hasADB(s) ? DevHooks.shared.adbPort(of: s) : nil as Int? }
            lines.append(DevHooks.hasADB(s) ? (adb.map { "adb: on, adb connect localhost:\($0)" } ?? "adb: starting") : "adb: off")
            lines.append(DevHooks.debugPort(of: s).map { "debugger: JDWP on localhost:\($0)" } ?? "debugger: off")
            if let har = DevHooks.har(of: s) { lines.append("traffic: \(har.mode == "record" ? "recording to" : "answered from") \(har.file.deletingPathExtension().lastPathComponent)") }
            else { lines.append("traffic: live") }
            if let watch = DispatchQueue.main.sync(execute: { DevHooks.shared.watchLabel }) { lines.append("watching: \(watch)") }
            return lines.joined(separator: "\n")
        case "adb_on":
            var target = s
            if !DevHooks.hasADB(s) { target = try relaunch(s, options: opts + ["--adb", "auto"]) }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if let port = DispatchQueue.main.sync(execute: { DevHooks.shared.adbPort(of: target) }) {
                    return "\(id(target)) adb is on: adb connect localhost:\(port), then adb -s localhost:\(port) shell"
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            return "\(id(target)) adb is starting: call devtools status for its port"
        case "adb_off":
            guard DevHooks.hasADB(s) else { return "\(id(s)) adb is already off" }
            return "\(id(try relaunch(s, options: DevHooks.without(["--adb"], from: opts)))) adb is off"
        case "debugger_on":
            if let port = DevHooks.debugPort(of: s) { return "\(id(s)) debugger: JDWP on localhost:\(port) (Run > Edit Configurations > Remote JVM Debug)" }
            guard let port = DevHooks.freePort() else { throw Failure(message: "no free port for the debugger") }
            let new = try relaunch(s, options: opts + ["--debug", String(port)])
            return "\(id(new)) debugger: JDWP on localhost:\(port) (Android Studio: Run > Edit Configurations > Remote JVM Debug, host localhost, port \(port)). The app does not wait for it."
        case "debugger_off":
            guard DevHooks.debugPort(of: s) != nil else { return "\(id(s)) no debugger is attached" }
            return "\(id(try relaunch(s, options: DevHooks.without(["--debug"], from: opts)))) debugger detached"
        case "har_record":
            try? FileManager.default.createDirectory(at: Self.hars, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let file = Self.hars.appendingPathComponent("agent-\(stamp.string(from: Date())).har")
            let new = try relaunch(s, options: DevHooks.without(["--network"], from: opts) + ["--network", "record", file.path])
            return "\(id(new)) recording all traffic to \(file.deletingPathExtension().lastPathComponent): it is written on har_save, har_stop, or when the simulator closes"
        case "har_save":
            guard DevHooks.har(of: s)?.mode == "record" else { throw Failure(message: "this simulator is not recording traffic: devtools har_record first") }
            let answer = try command(s, "network save")
            return "saved \(DevHooks.har(of: s)?.file.deletingPathExtension().lastPathComponent ?? "the HAR")" + (answer.isEmpty || answer == "ok" ? "" : ": \(answer)")
        case "har_stop":
            guard let har = DevHooks.har(of: s) else { return "\(id(s)) its traffic is already live" }
            let new = try relaunch(s, options: DevHooks.without(["--network"], from: opts))
            return "\(id(new)) traffic is live again" + (har.mode == "record" ? "; recorded \(har.file.deletingPathExtension().lastPathComponent)" : "")
        case "har_replay":
            guard let name = args["name"] as? String, name.range(of: "^[A-Za-z0-9._-]{1,120}$", options: .regularExpression) != nil else {
                throw Failure(message: "har_replay needs name: one from devtools har_list")
            }
            let found = (FileManager.default.enumerator(at: Self.hars, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .first { $0.pathExtension == "har" && $0.deletingPathExtension().lastPathComponent == name }
            guard let file = found else { throw Failure(message: "no HAR called \(name): call devtools har_list") }
            let new = try relaunch(s, options: DevHooks.without(["--network"], from: opts) + ["--network", "replay", file.path])
            return "\(id(new)) every request is answered from \(name); one the file lacks gets a 599, and nothing leaves this Mac"
        default:
            throw Failure(message: "action is status, adb_on, adb_off, debugger_on, debugger_off, har_record, har_save, har_stop, har_list or har_replay")
        }
    }

    // MARK: Flight recorder and replay

    private func recordings() -> [Recording] {
        guard let wb = workbench else { return [] }
        let folder = DispatchQueue.main.sync { wb.recordings }
        let done = DispatchSemaphore(value: 0)
        var found: [Recording] = []
        AgentTools.recordingStore.load(from: folder) { found = $0; done.signal() }
        _ = done.wait(timeout: .now() + 20)
        return found.sorted { $0.date > $1.date }
    }

    static let recordingStore = RecordingStore()

    private func recorder(_ args: [String: Any]) throws -> String {
        let action = args["action"] as? String ?? "status"
        guard let wb = workbench else { throw Failure(message: "Greenroom is not ready") }
        if action == "list" {
            let all = recordings()
            if all.isEmpty { return "no recordings (recorder on, then save, makes one)" }
            return all.prefix(30).map { r in
                "\(r.name) | \(r.meta.replacingOccurrences(of: "  ·  ", with: ", "))" + (r.apkName.map { " | \($0)" } ?? "") + (r.package.map { " (\($0))" } ?? "")
            }.joined(separator: "\n")
        }
        let s = try sim(args)
        switch action {
        case "status":
            let since = DispatchQueue.main.sync { wb.flightRecorder(of: s) }
            return since.map { "\(id(s)) the flight recorder is on, since \(age($0)): save writes what it holds" } ?? "\(id(s)) the flight recorder is off: on starts it"
        case "on", "off":
            let on = action == "on"
            if (DispatchQueue.main.sync { wb.flightRecorder(of: s) } != nil) == on { return "\(id(s)) the flight recorder is already \(action)" }
            let done = DispatchSemaphore(value: 0)
            var problem: String?
            DispatchQueue.main.async { wb.setFlightRecorder(s, on: on) { problem = $0; done.signal() } }
            guard done.wait(timeout: .now() + 30) == .success else { throw Failure(message: "the engine did not answer") }
            if let problem { throw Failure(message: "recorder: \(problem)") }
            return on ? "\(id(s)) recording input, log, network, database and screen: save writes it" : "\(id(s)) the flight recorder is off"
        case "save":
            let done = DispatchSemaphore(value: 0)
            var file: URL?, why = ""
            DispatchQueue.main.async { wb.saveRecording(of: s) { file = $0; why = $1; done.signal() } }
            guard done.wait(timeout: .now() + 70) == .success else { throw Failure(message: "the recording is still being written: call recorder list") }
            guard let file else { throw Failure(message: "not saved: " + why.replacingOccurrences(of: "error: ", with: "")) }
            return "saved \(file.deletingPathExtension().lastPathComponent): replay replays it"
        default:
            throw Failure(message: "action is status, on, off, save or list")
        }
    }

    final class ReplayBox { let group = DispatchGroup(); var outcome: ReplayOutcome?; var apk: String? }
    private static var replays: [String: ReplayBox] = [:]
    private static let replaysLock = NSLock()

    private func replay(_ args: [String: Any]) throws -> String {
        guard let name = args["recording"] as? String, !name.isEmpty else { throw Failure(message: "replay needs recording: a name from recorder list") }
        let apk = try (args["apk"] as? String).map { try apkFile($0) }
        let key = name + "|" + (apk?.path ?? "")
        let timeout = Double(min(max(args["timeout_s"] as? Int ?? 200, 10), 200))
        Self.replaysLock.lock()
        var box = Self.replays[key]
        if let b = box, b.outcome != nil { Self.replays[key] = nil; box = nil }
        let joined = box != nil
        Self.replaysLock.unlock()
        if box == nil {
            guard let rec = recordings().first(where: { $0.name == name }) else { throw Failure(message: "no recording called \(name): call recorder list") }
            let b = ReplayBox()
            b.apk = apk?.lastPathComponent
            b.group.enter()
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            let out = Engine.shared.engineState.appendingPathComponent("replays/\(rec.name)-\(stamp.string(from: Date()))", isDirectory: true)
            let job = ReplayJob(bundle: rec.url, apk: apk, out: out)
            ReplayRunner.shared.submit(job, token: ReplayRunner.shared.token) { run in
                b.outcome = ReplayRunner.interpret(run, out: out)
                b.group.leave()
            }
            Self.replaysLock.lock(); Self.replays[key] = b; Self.replaysLock.unlock()
            box = b
        }
        guard let b = box else { throw Failure(message: "the replay did not start") }
        guard b.group.wait(timeout: .now() + timeout) == .success, let outcome = b.outcome else {
            return "the replay of \(name) is still running\(joined ? " (joined)" : ""): call replay again with the same recording to wait for it"
        }
        Self.replaysLock.lock(); Self.replays[key] = nil; Self.replaysLock.unlock()
        return "\(name) on \(b.apk ?? "its own build"): \(outcome.word) | \(outcome.detail)"
    }

    /// An APK the agent named: an existing .apk file.
    func apkFile(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var dir: ObjCBool = false
        guard url.pathExtension.lowercased() == "apk", FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), !dir.boolValue else {
            throw Failure(message: "\(path) is not an .apk file")
        }
        return url
    }

    // MARK: Instrumentation tests

    private static var lastTests: TestRun?

    private func tests(_ args: [String: Any], _ connection: Connection) throws -> String {
        let timeout = Double(min(max(args["timeout_s"] as? Int ?? 200, 10), 200))
        if args["stop"] as? Bool == true {
            guard let run = DispatchQueue.main.sync(execute: { Self.lastTests }), run.isRunning else { return "no test run is going" }
            DispatchQueue.main.sync { run.stop() }
        }
        if let testPath = args["test_apk"] as? String {
            if let run = DispatchQueue.main.sync(execute: { Self.lastTests }), run.isRunning { throw Failure(message: "a test run is going: tests answers it, stop ends it") }
            let testAPK = try apkFile(testPath)
            let appAPK: URL
            if let a = args["app_apk"] as? String { appAPK = try apkFile(a) }
            else if let s = connection.session, let b = mainSync({ workbench?.sessions.builds[s.worktree.path] ?? workbench?.sessions.session(atWorktree: s.worktree)?.build }) { appAPK = b.apk }
            else if let s = try? sim([:]) { appAPK = s.apk }
            else { throw Failure(message: "tests needs app_apk: no build of this worktree and no single running simulator to take it from") }
            var config = TestRun.Config(testAPK: testAPK, appAPK: appAPK)
            config.classFilter = (args["filter"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard config.classFilter.range(of: "^[A-Za-z0-9_.#$,]*$", options: .regularExpression) != nil else { throw Failure(message: "filter is a class, Class#method or package") }
            let run = TestRun(config: config)
            try mainSync { try run.start(); Self.lastTests = run }
        }
        guard let run = DispatchQueue.main.sync(execute: { Self.lastTests }) else { return "no test run yet: give test_apk (the androidTest APK) to start one" }
        let deadline = Date().addingTimeInterval(timeout)
        while DispatchQueue.main.sync(execute: { run.isRunning }), Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        return DispatchQueue.main.sync { Self.describe(run) }
    }

    private static func describe(_ run: TestRun) -> String {
        let name = run.config.testAPK.lastPathComponent
        var head: String
        switch run.state {
        case .idle: head = "\(name): not started"
        case .running: head = "\(name): running, \(run.done) of \(run.expected > 0 ? String(run.expected) : "?") done after \(Int(run.elapsed)) s (tests answers it again)"
        case .finished(let exit, let stopped): head = "\(name): \(stopped ? "stopped" : run.failed > 0 ? "FAILED" : run.passed > 0 ? "PASSED" : "no tests ran") in \(Int(run.elapsed)) s" + (exit != 0 && run.done == 0 ? " (exit \(exit))" : "")
        }
        head += " | \(run.passed) passed, \(run.failed) failed, \(run.ignored) ignored"
        var lines = [head]
        if let p = run.problem { lines.append("problem: \(p)") }
        for t in run.allTests where t.status == .failed {
            lines.append("FAIL \(t.id)" + (t.ms.map { " (\($0) ms)" } ?? ""))
            lines += t.stack.split(separator: "\n").prefix(6).map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Screenshot tests

    private func snapshots(_ args: [String: Any], _ connection: Connection) throws -> String {
        guard let wb = workbench else { throw Failure(message: "Greenroom is not ready") }
        let review = wb.snapshotReview
        let action = args["action"] as? String ?? "status"
        let timeout = Double(min(max(args["timeout_s"] as? Int ?? 200, 10), 200))
        func setup() -> String {
            DispatchQueue.main.sync {
                guard let spec = review.specURL else { return "no spec: the owner chooses one in Greenroom's Snapshots" }
                return "spec \(spec.lastPathComponent), APK \(review.effectiveAPK?.lastPathComponent ?? "none"), goldens \(review.goldensDir?.path ?? "none")"
            }
        }
        func results() -> String {
            DispatchQueue.main.sync {
                let list = review.results
                if review.run?.isRunning == true { return "a run is going" }
                if list.isEmpty { return "no results yet: snapshots run compares" }
                var lines = [SnapshotReview.summary(list)]
                for r in list where r.kind != .same {
                    lines.append("\(r.id): \(r.statusText)" + (r.percent.map { String(format: " (%.2f%% of pixels)", $0) } ?? "") + (r.detail.isEmpty ? "" : " | \(r.detail)"))
                }
                return lines.joined(separator: "\n")
            }
        }
        func waitForRun() -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while DispatchQueue.main.sync(execute: { review.run?.isRunning == true }), Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            return DispatchQueue.main.sync { review.run?.isRunning != true }
        }
        switch action {
        case "status":
            return setup() + "\n" + results()
        case "run", "record":
            let ready = DispatchQueue.main.sync { review.specURL != nil }
            guard ready else { throw Failure(message: setup()) }
            let started: Bool = DispatchQueue.main.sync {
                if review.run?.isRunning == true { return true }
                review.start(action == "record" ? .record : .compare)
                return review.run?.isRunning == true
            }
            guard started else { throw Failure(message: "the run did not start (it needs Python 3 and the spec's script): " + setup()) }
            guard waitForRun() else { return "the screenshot tests are still running: snapshots status answers them when done" }
            return results()
        case "accept":
            guard let ids = args["ids"] as? [String], !ids.isEmpty else { throw Failure(message: "accept needs ids (screen/combo), from snapshots status") }
            let known = DispatchQueue.main.sync { Set(review.results.map(\.id)) }
            let unknown = ids.filter { !known.contains($0) }
            guard unknown.isEmpty else { throw Failure(message: "not in the last results: \(unknown.joined(separator: ", "))") }
            let n = DispatchQueue.main.sync { review.accept(ids) }
            return "\(n) golden\(n == 1 ? "" : "s") written\n" + results()
        default:
            throw Failure(message: "action is status, run, record or accept")
        }
    }
}
