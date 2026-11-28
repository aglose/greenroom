import Foundation

/// The `greenroom` command (`bin/greenroom` runs `Greenroom --cli ...`): Greenroom from a shell, for an agent whose
/// harness has a shell and no MCP client, for a harness's hooks, and for a person's own scripts.
///
///     greenroom mcp                       the MCP server on stdin and stdout (AgentShim)
///     greenroom hook EVENT                a harness's hook: tells the running app where the agent's turn is
///     greenroom open [APK | DIR | LINK]   the window; an APK run in it; a worktree's session; a greenroom:// link
///     greenroom tools                     the tools, one a line
///     greenroom help [TOOL]               this, or one tool's arguments
///     greenroom TOOL [ARGUMENTS]          any tool the MCP server has, with the same answer
///
/// A tool's arguments are its MCP arguments as flags: `greenroom tap --text Add`, `greenroom set appearance dark`,
/// `greenroom check Saved --absent Error`. It talks to the running app over the same loopback channel as the MCP
/// shim, with the same token, and says the folder it was run in, so a call from a worktree is that worktree's.
///
/// Exit status: 0 done, 1 the tool failed (or `check` answered FAIL), 2 the command line is wrong, 3 Greenroom is
/// not running and could not be started.
enum CLI {
    static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let first = args.first else { print(overview()); exit(0) }
        let rest = Array(args.dropFirst())
        switch first {
        case "mcp": AgentShim.run()
        case "hook": hook(rest)
        case "open": open(rest)
        case "tools": print(toolLines()); exit(0)
        case "help", "--help", "-h":
            if let name = rest.first { help(tool: name) }
            print(overview()); exit(0)
        case "version", "--version":
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String
            print(version.map { "\(Variant.name) \($0)" } ?? "\(Variant.name), a development build")
            exit(0)
        default:
            tool(first, rest)
        }
    }

    // MARK: Saying

    private static func err(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    private static func usage(_ text: String) -> Never {
        err("greenroom: \(text)")
        exit(2)
    }

    private static func overview() -> String {
        """
        greenroom: Greenroom from a shell. The simulators are the app's, where the person at the Mac sees them.

          greenroom TOOL [ARGUMENTS]         a tool, as an agent has it over MCP (greenroom tools lists them)
          greenroom help TOOL                one tool's arguments
          greenroom open [APK | DIR | LINK]  the window; an APK run in it; a worktree's session; a \(Links.scheme):// link
          greenroom mcp                      the MCP server on stdin and stdout, for a harness's configuration
          greenroom hook EVENT [--harness NAME]
                                             for a harness's hooks: tells the running app that EVENT happened in
                                             this folder. Sends the harness's name, its session id, the folder
                                             and the event; never a prompt, a transcript or a file's content.
          greenroom version

        A tool's arguments are flags: --text Add, --max-size 600, --annotate, --no-annotate; a list repeats its flag.
        The arguments a tool needs can be given bare, in order: greenroom type "hello", greenroom set appearance dark.
          -C DIR       act as if run in DIR (a call from a worktree is that worktree's session)
          --out FILE   where a picture is written (default: a file in the temporary folder; its path is printed)
          --json '{}'  the arguments as JSON

        For example:
          greenroom launch                   this worktree's app, from its newest build
          greenroom tap --text "Add item"
          greenroom check Saved --absent Error
          greenroom screenshot --out shot.png

        Exit status: 0 done, 1 the tool failed or check answered FAIL, 2 wrong usage, 3 Greenroom could not be reached.
        """
    }

    private static func toolLines() -> String {
        let width = (AgentTools.tools.map(\.name.count).max() ?? 0) + 2
        return AgentTools.tools.map { t in
            let cut = t.description.range(of: ". ").map { String(t.description[..<$0.lowerBound]) + "." } ?? t.description
            let first = cut.count > 110 ? String(cut.prefix(107)) + "…" : cut
            return t.name.padding(toLength: width, withPad: " ", startingAt: 0) + first
        }.joined(separator: "\n")
    }

    // MARK: A tool's arguments

    /// Arguments that may be given bare besides the ones a tool needs, in this order after those.
    private static let bare: [String: [String]] = [
        "launch": ["apk"], "tap": ["text"], "set": ["value"], "swipe": ["direction"], "build": ["recipe"], "changes": ["base"],
        "check": ["visible"], "screen": ["text"], "logs": ["filter"], "session_action": ["session"], "history": ["screen"],
    ]
    /// Arguments that are paths: one given relative to the shell's folder is made whole, as the app runs elsewhere.
    private static let paths: Set<String> = ["apk", "test_apk", "app_apk", "path"]

    private static func find(_ name: String) -> (name: String, description: String, schema: [String: Any])? {
        let wanted = name.replacingOccurrences(of: "-", with: "_")
        return AgentTools.tools.first { $0.name == wanted }
    }

    private static func properties(_ schema: [String: Any]) -> [String: [String: Any]] {
        (schema["properties"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
    }

    private static func bareOrder(_ t: (name: String, description: String, schema: [String: Any])) -> [String] {
        var order = t.schema["required"] as? [String] ?? []
        for extra in bare[t.name] ?? [] where !order.contains(extra) { order.append(extra) }
        return order
    }

    private static func flag(_ key: String) -> String { "--" + key.replacingOccurrences(of: "_", with: "-") }

    private static func help(tool name: String) -> Never {
        guard let t = find(name) else { usage("there is no tool \(name): greenroom tools lists them") }
        let props = properties(t.schema)
        let order = bareOrder(t)
        let required = Set(t.schema["required"] as? [String] ?? [])
        var line = "usage: greenroom \(t.name)"
        for key in order {
            let word = key.uppercased() + (props[key]?["type"] as? String == "array" ? "..." : "")
            line += required.contains(key) ? " \(word)" : " [\(word)]"
        }
        if props.keys.contains(where: { !required.contains($0) }) { line += " [options]" }
        var out = [line, "", t.description, ""]
        for key in order + props.keys.sorted().filter({ !order.contains($0) }) {
            guard let p = props[key] else { continue }
            var kind = p["type"] as? String ?? "string"
            if let values = p["enum"] as? [String] { kind = values.joined(separator: "|") }
            else if kind == "array" { kind = "list (repeat the flag)" }
            else if kind == "boolean" { kind = "flag (\(flag("no_" + key)) for false)" }
            let what = (p["description"] as? String).map { "  \($0)" } ?? ""
            out.append("  \(flag(key))  \(kind)\(required.contains(key) ? ", needed" : "")\(what)")
        }
        print(out.joined(separator: "\n"))
        exit(0)
    }

    private static func value(_ raw: String, for key: String, _ p: [String: Any], tool: String) -> Any {
        switch p["type"] as? String ?? "string" {
        case "integer":
            guard let n = Int(raw) else { usage("\(tool): \(flag(key)) is a whole number, not \(raw)") }
            return n
        case "number":
            guard let n = Double(raw), n.isFinite else { usage("\(tool): \(flag(key)) is a number, not \(raw)") }
            return n
        case "boolean":
            switch raw.lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off": return false
            default: usage("\(tool): \(flag(key)) is true or false, not \(raw)")
            }
        default:
            if paths.contains(key) || (key == "base" && raw.lowercased().hasSuffix(".apk")) { return whole(raw) }
            return raw
        }
    }

    /// A path as the app can read it: one relative to the shell's folder, made whole when something is there.
    private static func whole(_ raw: String) -> String {
        if raw.hasPrefix("/") { return raw }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent(raw).standardizedFileURL.path
        return FileManager.default.fileExists(atPath: here) ? here : raw
    }

    private static func tool(_ name: String, _ args: [String]) -> Never {
        guard let t = find(name) else {
            usage("there is no \(name): greenroom tools lists the tools, greenroom help the rest")
        }
        let props = properties(t.schema)
        var object: [String: Any] = [:]
        var cwd: String?, out: String?
        var loose: [String] = []
        var i = 0
        func next(_ what: String) -> String {
            i += 1
            guard i < args.count else { usage("\(t.name): \(what) needs a value") }
            return args[i]
        }
        func put(_ key: String, _ raw: String) {
            guard let p = props[key] else { return }
            if p["type"] as? String == "array" {
                let item = (p["items"] as? [String: Any]) ?? ["type": "string"]
                object[key] = (object[key] as? [Any] ?? []) + [value(raw, for: key, item, tool: t.name)]
            } else {
                object[key] = value(raw, for: key, p, tool: t.name)
            }
        }
        while i < args.count {
            let a = args[i]
            defer { i += 1 }
            if a == "--" { loose += args[(i + 1)...]; break }
            if a == "-C" { cwd = next("-C"); continue }
            if a == "-h" || (a == "--help" && props["help"] == nil) { help(tool: t.name) }
            guard a.hasPrefix("--"), a.count > 2 else { loose.append(a); continue }
            var key = String(a.dropFirst(2)), given: String?
            if let eq = key.firstIndex(of: "=") { given = String(key[key.index(after: eq)...]); key = String(key[..<eq]) }
            key = key.replacingOccurrences(of: "-", with: "_")
            if props[key] == nil {
                if key == "out" { out = given ?? next("--out"); continue }
                if key == "json" {
                    let raw = given ?? next("--json")
                    guard let more = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
                        usage("\(t.name): --json takes an object, like '{\"text\": \"Add\"}'")
                    }
                    object.merge(more) { _, new in new }
                    continue
                }
                if key.hasPrefix("no_"), props[String(key.dropFirst(3))]?["type"] as? String == "boolean", given == nil {
                    object[String(key.dropFirst(3))] = false
                    continue
                }
                let takes = props.keys.sorted().map(flag).joined(separator: " ")
                usage("\(t.name) has no \(a.split(separator: "=").first ?? ""). It takes: \(takes.isEmpty ? "nothing" : takes)")
            }
            if props[key]?["type"] as? String == "boolean" {
                // A flag alone is true; `--annotate false` and `--annotate=false` say otherwise.
                if let given { put(key, given) }
                else if i + 1 < args.count, ["true", "false"].contains(args[i + 1].lowercased()) { put(key, next(a)) }
                else { object[key] = true }
            } else {
                put(key, given ?? next(a))
            }
        }
        // Bare arguments fill what the tool needs, in order; a list takes all that are left.
        var slots = bareOrder(t).filter { object[$0] == nil }
        var j = 0
        while j < loose.count {
            guard let key = slots.first else {
                usage("\(t.name): \(loose[j]) is one argument too many (greenroom help \(t.name))")
            }
            if props[key]?["type"] as? String == "array" { for raw in loose[j...] { put(key, raw) }; break }
            put(key, loose[j])
            slots.removeFirst()
            j += 1
        }
        for key in t.schema["required"] as? [String] ?? [] where object[key] == nil {
            usage("\(t.name) needs \(key) (greenroom help \(t.name))")
        }
        if let cwd, cwd.isEmpty { usage("-C needs a folder") }
        let answer = rpc("tools/call", ["name": t.name, "arguments": object], cwd: cwd.map(folder))
        exit(emit(answer, tool: t.name, out: out))
    }

    private static func folder(_ raw: String) -> String {
        let path = whole(raw)
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            usage("\(raw) is not a folder")
        }
        return path
    }

    // MARK: The app

    private static var nextID = 0

    /// One request to the running app, started if it is not open. Its answer, or exit 3.
    private static func rpc(_ method: String, _ params: [String: Any], cwd: String? = nil) -> [String: Any] {
        nextID += 1
        let message: [String: Any] = ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params]
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { usage("the arguments could not be written as JSON") }
        let timeout = AgentShim.timeout(for: message)
        for attempt in 0..<2 {
            guard let e = AgentShim.connect() else { break }
            let r = AgentShim.post(body, to: e, cwdOverride: cwd, timeout: timeout)
            if let r, r.status == 200,
               let json = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any] { return json }
            if r == nil, AgentShim.stillRunning(e) {
                err("greenroom: \(Variant.name) is running but did not answer within \(Int(timeout)) s.")
                exit(3)
            }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.5) }   // the app may have just quit: look again
        }
        err("greenroom: \(Variant.name) is not running and could not be started.")
        exit(3)
    }

    /// Prints an answer: text to stdout (a failure's to stderr), a picture to a file whose path is printed.
    private static func emit(_ answer: [String: Any], tool: String, out: String?) -> Int32 {
        if let e = answer["error"] as? [String: Any] {
            err("greenroom: \(e["message"] as? String ?? "the request was refused")")
            return (e["code"] as? Int) == -32602 ? 2 : 1
        }
        let result = answer["result"] as? [String: Any] ?? [:]
        let failed = result["isError"] as? Bool == true
        var status: Int32 = failed ? 1 : 0
        var pictures = 0
        for block in result["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                if failed { err(text) } else { print(text) }
                if tool == "check", text.hasPrefix("FAIL") { status = 1 }
            case "image":
                guard let data = (block["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { continue }
                pictures += 1
                let file = picture(tool: tool, out: out, number: pictures)
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: file)
                    print("picture: \(file.path)")
                } catch {
                    err("greenroom: the picture could not be written to \(file.path): \(error.localizedDescription)")
                    status = 1
                }
            default: break
            }
        }
        return status
    }

    private static func picture(tool: String, out: String?, number: Int) -> URL {
        if let out {
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            if number == 1 { return url }
            let ext = url.pathExtension
            return url.deletingPathExtension().deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(number)" + (ext.isEmpty ? "" : ".\(ext)"))
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(tool)-\(f.string(from: Date()))-\(getpid())" + (number > 1 ? "-\(number)" : "") + ".png"
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("greenroom", isDirectory: true).appendingPathComponent(name)
    }

    // MARK: open

    /// `greenroom open`: brings the window forward; with an APK runs it there; with a folder opens its worktree's
    /// session (as a click on its row would); with a link goes where the link says.
    private static func open(_ args: [String]) -> Never {
        if args.first == "--help" || args.first == "-h" {
            print("""
            usage: greenroom open [APK | DIR | LINK]

              greenroom open                 Greenroom's window, brought forward (the app is started if it is not open)
              greenroom open app.apk         the APK, run in a simulator
              greenroom open DIR             the session of the worktree DIR is in, opened as a click on its row would
              greenroom open \(Links.scheme)://connect            the Connect screen
              greenroom open \(Links.scheme)://apk                the APK screen
              greenroom open "\(Links.scheme)://session?path=DIR"  a session Greenroom already has (a link adds nothing)
            """)
            exit(0)
        }
        guard args.count <= 1 else { usage("open takes one thing: an APK, a folder or a link") }
        guard let what = args.first else { exit(emit(rpc("greenroom/open", [:]), tool: "open", out: nil)) }
        if let url = URL(string: what), let scheme = url.scheme?.lowercased(), scheme.hasPrefix("greenroom") {
            guard scheme == Links.scheme else { usage("\(what) is \(scheme == "greenroom" ? "Greenroom's" : "Greenroom Debug's") link, and this is \(Variant.name)") }
            exit(emit(rpc("greenroom/open", ["link": what]), tool: "open", out: nil))
        }
        let path = whole(what)
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { usage("there is no \(what)") }
        var status: Int32
        if isDir.boolValue {
            status = emit(rpc("tools/call", ["name": "session_action", "arguments": ["action": "open"]], cwd: path), tool: "session_action", out: nil)
        } else {
            guard path.lowercased().hasSuffix(".apk") else { usage("\(what) is not an .apk, a folder or a \(Links.scheme):// link") }
            status = emit(rpc("tools/call", ["name": "launch", "arguments": ["apk": path]]), tool: "launch", out: nil)
        }
        // The window, on what was just opened: a session takes the stage back from the Connect and APK screens.
        let shown = isDir.boolValue ? rpc("greenroom/open", ["session": true], cwd: path) : rpc("greenroom/open", [:])
        if shown["error"] != nil { status = max(status, 1) }
        exit(status)
    }

    // MARK: hook

    /// `greenroom hook EVENT [--harness NAME] [--session ID] [--cwd DIR]`: what a harness's hook runs. It reads the
    /// JSON the harness writes to the hook's stdin and takes two things from it, the session's id and the working
    /// folder, then tells the running app: harness, session id, folder, event. Nothing else leaves this process: no
    /// prompt, no tool input, no transcript, no file, and not the account Cursor names there. With no app running it
    /// tells nobody (it never starts one). It exits 0 always, so it can never hold up or fail an agent's turn.
    ///
    /// What it prints is what the harness reads as the hook's answer, and it is the same with or without the app.
    /// Claude Code and Codex take silence as "go on", so for them it prints nothing. Cursor reads JSON from a hook:
    /// `{"continue":true}` for `beforeSubmitPrompt` (the one hook of ours that could hold a prompt back) and `{}`
    /// for the rest, neither of which changes anything Cursor does.
    private static func hook(_ args: [String]) -> Never {
        var event: String?, harness = "agent", session: String?, cwd: String?
        var i = 0
        while i < args.count {
            let a = args[i]
            func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
            switch a {
            case "--harness": harness = value() ?? harness
            case "--session": session = value()
            case "--cwd": cwd = value()
            case "--help", "-h":
                print("usage: greenroom hook EVENT [--harness NAME] [--session ID] [--cwd DIR]\n\n"
                    + "For a harness's hooks. Tells the running Greenroom that EVENT happened: the harness's name, its\n"
                    + "session id and working folder (read from the JSON on stdin, or given here) and the event's name.\n"
                    + "Never a prompt, a transcript or a file's content. Exits 0, app open or not. Prints nothing,\n"
                    + "except for Cursor, which reads a hook's answer ({\"continue\":true} or {}), and at a turn's end\n"
                    + "when the person said something in Greenroom the agent has not been given: then it prints what\n"
                    + "makes the harness carry on with those words (decision block and reason; Cursor: followup_message).")
                exit(0)
            default: if event == nil, !a.hasPrefix("-") { event = a }
            }
            i += 1
        }
        /// Cursor's answer, and the end.
        func done(cursor: Bool, _ name: String) -> Never {
            if cursor { print(name.lowercased().filter(\.isLetter) == "beforesubmitprompt" ? "{\"continue\":true}" : "{}") }
            exit(0)
        }
        // The answer follows the hook file the command was written into (its --harness), so it is the same whether
        // or not the app is there to hear it: Cursor running Claude Code's hooks is answered as Claude Code is.
        let cursor = harness.lowercased() == "cursor"
        let flag = harness   // as the hooks file wrote it: `harness` below may become what the input says
        // No app: nothing to tell, and none is started.
        guard let e = AgentShim.endpoint() else { done(cursor: cursor, event ?? "") }
        let input = (try? JSONSerialization.jsonObject(with: stdin(seconds: 0.25, limit: 4 << 20))) as? [String: Any] ?? [:]
        func text(_ keys: String...) -> String? { keys.lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty } }
        // Cursor also runs the hooks in Claude Code's settings, as itself: what it writes says whose session it is.
        if input["cursor_version"] != nil { harness = "cursor" }
        let name = event ?? text("hook_event_name", "event", "type") ?? ""
        let folder = cwd ?? text("cwd") ?? (input["workspace_roots"] as? [String])?.first ?? FileManager.default.currentDirectoryPath
        var params: [String: Any] = ["harness": harness, "event": name, "cwd": folder,
                                     "session": session ?? text("session_id", "conversation_id", "thread_id") ?? ""]
        // A turn's end can be answered with what the person said in Greenroom, where this command knows how the
        // harness reads an answer: Claude Code and Codex by their own hooks, Cursor by its own (not when it runs
        // Claude Code's, whose answer it may read differently), and not for a turn the person stopped.
        let turnEnd = name.lowercased().filter(\.isLetter) == "stop"
        let written = flag.lowercased()
        let knows = cursor ? true : (["claude", "claude-code", "codex"].contains(written) && input["cursor_version"] == nil)
        let stopped = (input["status"] as? String).map { $0 != "completed" } ?? false
        let answers = turnEnd && knows && !stopped
        if answers { params["answers"] = true }
        let message: [String: Any] = ["jsonrpc": "2.0", "method": "greenroom/hook", "params": params]
        if !name.isEmpty, let body = try? JSONSerialization.data(withJSONObject: message) {
            let got = AgentShim.post(body, to: e, cwdOverride: folder.hasPrefix("/") ? folder : nil, timeout: answers ? 3 : 1)
            if answers, let got, got.status == 200, let say = ((try? JSONSerialization.jsonObject(with: got.data)) as? [String: Any])?["say"] as? String, !say.isEmpty {
                let out: [String: Any] = cursor ? ["followup_message": say] : ["decision": "block", "reason": say]
                if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) {
                    print(String(decoding: data, as: UTF8.self))
                    exit(0)
                }
            }
        }
        done(cursor: cursor, name)
    }

    /// What is on stdin, if anything arrives in time: a hook must not wait for a harness that writes nothing.
    private static func stdin(seconds: TimeInterval, limit: Int) -> Data {
        guard isatty(0) == 0 else { return Data() }
        var data = Data()
        let end = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while data.count < limit {
            var fds = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            guard poll(&fds, 1, Int32(max(0, end.timeIntervalSinceNow * 1000))) > 0 else { break }
            let n = read(0, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
