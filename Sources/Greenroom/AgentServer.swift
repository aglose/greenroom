import Foundation
import Network

/// The agent interface: the Model Context Protocol, served by the running app so an agent and the person at the Mac
/// work on the same simulators. It listens on this Mac's loopback interface only, on a port of the system's
/// choosing, and answers only requests that carry the token it wrote to a file readable by the user alone
/// (`agent.json` in the state folder). A request with an `Origin` header, which every browser adds to a page's
/// cross-site request, is refused: no web page can drive it. Agents reach it through `Greenroom --mcp` (AgentShim).
final class AgentServer {
    static let modern = "2026-07-28"
    static let legacy = ["2025-11-25", "2025-06-18"]
    static let info: [String: Any] = ["name": "greenroom", "title": Variant.name, "version": "1"]

    let tools = AgentTools()
    private var listener: NWListener?
    private let token: String
    private let queue = DispatchQueue(label: "greenroom-agent-connections")
    /// Tool calls run one at a time, off the main thread (they wait for answers delivered there).
    private let work = DispatchQueue(label: "greenroom-agent-tools")
    /// build and changes wait for minutes: they must not hold up the other tools' answers.
    private let slow = DispatchQueue(label: "greenroom-agent-slow-tools", attributes: .concurrent)
    private(set) var port: UInt16 = 0
    /// Called on the main thread when an agent first talks to the server.
    var onClient: ((String) -> Void)?
    /// Called on the main thread once the endpoint listens (the waiting stage says so).
    var onReady: (() -> Void)?

    static var file: URL { Engine.shared.state.appendingPathComponent("agent.json") }

    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = listener.port?.rawValue else { return }
            self.port = port
            self.publish()
            DispatchQueue.main.async { self.onReady?() }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        try? FileManager.default.removeItem(at: AgentServer.file)
    }

    /// Where the server is and the token it wants, for the shim: a file only the user can read.
    private func publish() {
        try? Engine.shared.prepare()
        let json: [String: Any] = ["port": Int(port), "token": token, "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        let file = AgentServer.file
        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 8 << 20 { self.respond(connection, 413, "too large"); return }
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() } else { self.read(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in head.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let body = buffer[headEnd.upperBound...]
            if body.count < length {
                if done || error != nil { connection.cancel() } else { self.read(connection, buffer: buffer) }
                return
            }
            self.handle(connection, requestLine: head.first ?? "", headers: headers, body: Data(body.prefix(length)))
        }
    }

    private func handle(_ connection: NWConnection, requestLine: String, headers: [String: String], body: Data) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { respond(connection, 400, "bad request"); return }
        // A browser adds Origin to a page's request to another site, and cannot be told not to.
        if headers["origin"] != nil { respond(connection, 403, "requests from web pages are refused"); return }
        let host = headers["host"] ?? ""
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { respond(connection, 403, "wrong host"); return }
        guard parts[0] == "POST", parts[1] == "/mcp" else { respond(connection, 404, "not found"); return }
        guard let given = headers["authorization"], AgentServer.same(given, "Bearer \(token)") else {
            respond(connection, 401, "the token in agent.json is required")
            return
        }
        guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            respond(connection, 200, json: ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
            return
        }
        // Hints from a local program that already holds the token: they select a row and grant nothing.
        let hint = AgentServer.hint(headers)
        let isSlow = message["method"] as? String == "tools/call"
            && AgentTools.slow.contains(((message["params"] as? [String: Any])?["name"] as? String) ?? "")
        (isSlow ? slow : work).async { [weak self] in
            guard let self else { return }
            let who = message["method"] as? String == "tools/call" ? self.connect(hint) : self.note(hint)
            if let answer = self.dispatch(message, connection: who) { self.respond(connection, 200, json: answer) }
            else { self.respond(connection, 202, "") }   // a notification: nothing to answer
        }
    }

    /// What the shim said about itself: its working folder and its parent's process id. Both optional (an older
    /// shim sends neither), and a folder that is not an absolute path to a folder is dropped.
    static func hint(_ headers: [String: String]) -> (cwd: URL?, parent: Int32?) {
        var cwd: URL?
        if let raw = headers["x-greenroom-cwd"]?.removingPercentEncoding, raw.hasPrefix("/"), !raw.contains("\0") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: raw, isDirectory: &isDir), isDir.boolValue { cwd = URL(fileURLWithPath: raw, isDirectory: true) }
        }
        let parent = headers["x-greenroom-parent"].flatMap { Int32($0) }.flatMap { $0 > 0 ? $0 : nil }
        return (cwd, parent)
    }

    /// One shim: found again by its parent process (the agent) and its folder, so several agents in different
    /// worktrees stay apart. `session` is the worktree the folder is in, if it is in one of an added repository.
    private var known: [String: AgentTools.Connection] = [:]
    private let knownLock = NSLock()

    /// Every connection seen since the app started (the agent's parent process id is kept for W1 to join with
    /// Claude Code's own session files).
    var connections: [AgentTools.Connection] { knownLock.lock(); defer { knownLock.unlock() }; return Array(known.values) }

    private func note(_ hint: (cwd: URL?, parent: Int32?)) -> AgentTools.Connection {
        var c = AgentTools.Connection(cwd: hint.cwd, parent: hint.parent)
        let key = "\(hint.parent.map(String.init) ?? "-")|\(hint.cwd?.path ?? "-")"
        knownLock.lock(); defer { knownLock.unlock() }
        // Agents that have exited are forgotten.
        known = known.filter { $0.value.parent.map { kill($0, 0) == 0 || errno == EPERM } ?? true }
        if let old = known[key] { c.session = old.session }
        known[key] = c
        return c
    }

    /// The connection of a request, tied to the session of its folder. On the tool queue, never the main thread.
    private func connect(_ hint: (cwd: URL?, parent: Int32?)) -> AgentTools.Connection {
        var c = note(hint)
        c.session = nil
        if let cwd = hint.cwd {
            let done = DispatchSemaphore(value: 0)
            var top: URL?
            Task.detached { top = await Git.toplevel(of: cwd); done.signal() }
            done.wait()
            if let top {
                c.session = DispatchQueue.main.sync { tools.workbench?.sessions.session(atWorktree: top) }
                if c.session == nil { (c.session, c.why) = adopt(top) }
            }
        }
        let key = "\(hint.parent.map(String.init) ?? "-")|\(hint.cwd?.path ?? "-")"
        knownLock.lock(); known[key] = c; knownLock.unlock()
        return c
    }

    /// A repository adds itself (AgentAdoption): a call from a worktree no session has adds its repository, when the
    /// worktree holds an Android app, the person did not remove that repository, and agents are not paused. A new
    /// worktree of a repository already added is only shown. Answers the session, or why there is none. On the tool
    /// queue, never the main thread.
    private func adopt(_ top: URL) -> (Session?, String?) {
        guard AgentAdoption.enabled, let sessions = DispatchQueue.main.sync(execute: { tools.workbench?.sessions }) else { return (nil, nil) }
        let done = DispatchSemaphore(value: 0)
        var found: URL?
        Task.detached { found = await Git.mainCheckout(of: top)?.resolvingSymlinksInPath(); done.signal() }
        done.wait()
        guard let root = found else { return (nil, nil) }
        let name = root.lastPathComponent
        let known = DispatchQueue.main.sync { sessions.workspace(at: root) != nil }
        if !known {
            if AgentAdoption.isRemoved(root) {
                return (nil, "\(name) was removed from Greenroom by the person at the Mac: only they can add it back, with File > Add Repository…")
            }
            if tools.paused || AgentCheckHooks.pausedByCheck { return (nil, "agents are paused, so \(name) was not added") }
            // An agent that launches an APK by its path from some other repository adds nothing.
            guard AndroidProject.isApp(top) else { return (nil, "no Android app was found in \(top.lastPathComponent), so it was not added") }
        }
        let task = DispatchQueue.main.sync { sessions.addRepository(top, quietIfExisting: true, byAgent: true) }
        Task.detached { _ = await task.value; done.signal() }
        done.wait()
        // The row is there at once; its branch, commit and build are read from git a moment later. The call that
        // added it is answered from what was read, not from the empty row (ten seconds at most, for a large one).
        let end = Date().addingTimeInterval(10)
        var session = DispatchQueue.main.sync { sessions.session(atWorktree: top) }
        while session?.head.isEmpty ?? false, Date() < end {
            Thread.sleep(forTimeInterval: 0.1)
            session = DispatchQueue.main.sync { sessions.session(atWorktree: top) }
        }
        return (session, nil)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private func respond(_ connection: NWConnection, _ status: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        send(connection, status, "application/json", data)
    }

    private func respond(_ connection: NWConnection, _ status: Int, _ text: String) {
        send(connection, status, "text/plain; charset=utf-8", Data(text.utf8))
    }

    private func send(_ connection: NWConnection, _ status: Int, _ type: String, _ body: Data) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 413: "Too Large"][status] ?? "Error"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: The protocol

    /// One JSON-RPC message in, its answer out (nil for a notification).
    func dispatch(_ m: [String: Any], connection: AgentTools.Connection = AgentTools.Connection()) -> [String: Any]? {
        guard let method = m["method"] as? String, let id = m["id"], !(id is NSNull) else { return nil }
        func result(_ r: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": r] }
        func failure(_ code: Int, _ message: String, _ data: Any? = nil) -> [String: Any] {
            var e: [String: Any] = ["code": code, "message": message]
            if let data { e["data"] = data }
            return ["jsonrpc": "2.0", "id": id, "error": e]
        }
        let params = m["params"] as? [String: Any] ?? [:]
        if let p = m["params"], !(p is [String: Any]), !(p is NSNull) { return failure(-32602, "params must be an object") }
        let meta = params["_meta"] as? [String: Any] ?? [:]
        if let version = meta["io.modelcontextprotocol/protocolVersion"] as? String, version != AgentServer.modern, method != "initialize" {
            return failure(-32022, "Unsupported protocol version",
                           ["supported": [AgentServer.modern] + AgentServer.legacy, "requested": version])
        }
        switch method {
        case "initialize":
            let want = params["protocolVersion"] as? String ?? ""
            let version = AgentServer.legacy.contains(want) ? want : (want == AgentServer.modern ? AgentServer.modern : AgentServer.legacy[0])
            let client = ((params["clientInfo"] as? [String: Any])?["name"] as? String) ?? "an agent"
            DispatchQueue.main.async { self.onClient?(client) }
            return result(["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]],
                           "serverInfo": AgentServer.info, "instructions": AgentTools.instructions])
        case "server/discover":
            return result(["resultType": "complete", "supportedVersions": [AgentServer.modern] + AgentServer.legacy,
                           "capabilities": ["tools": [String: Any]()], "instructions": AgentTools.instructions,
                           "ttlMs": 3_600_000, "cacheScope": "public",
                           "_meta": ["io.modelcontextprotocol/serverInfo": AgentServer.info]])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["resultType": "complete", "tools": AgentTools.list(), "ttlMs": 3_600_000, "cacheScope": "public"])
        case "tools/call":
            guard let name = params["name"] as? String else { return failure(-32602, "name is required") }
            if let a = params["arguments"], !(a is [String: Any]), !(a is NSNull) { return failure(-32602, "arguments must be an object") }
            guard AgentTools.tools.contains(where: { $0.name == name }) else { return failure(-32602, "unknown tool \(name)") }
            do {
                let content = try tools.call(name, params["arguments"] as? [String: Any] ?? [:], connection: connection)
                return result(["resultType": "complete", "content": content])
            } catch let f as AgentTools.Failure {
                return result(["resultType": "complete", "isError": true, "content": [["type": "text", "text": f.message]]])
            } catch {
                return result(["resultType": "complete", "isError": true, "content": [["type": "text", "text": "internal error: \(error)"]]])
            }
        default:
            return failure(-32601, "method not found: \(method)")
        }
    }
}

/// `Greenroom --mcp`: what an agent runs. Speaks the protocol on stdin and stdout (one JSON message a line) and
/// passes each message to the running app, starting Greenroom first if it is not open. It holds no state: the
/// simulators belong to the app, where the person can see them.
enum AgentShim {
    private struct Endpoint { let port: Int; let token: String; let pid: Int32 }

    private static func endpoint() -> Endpoint? {
        guard let data = try? Data(contentsOf: AgentServer.file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let port = json["port"] as? Int, let token = json["token"] as? String, let pid = json["pid"] as? Int,
              kill(Int32(pid), 0) == 0 else { return nil }
        return Endpoint(port: port, token: token, pid: Int32(pid))
    }

    /// The running app's endpoint, starting the app (in the background) when there is none.
    private static func connect() -> Endpoint? {
        if let e = endpoint() { return e }
        let p = Process()
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", bundle.path]
        } else {
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])   // a development build: the bare executable
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
        }
        guard (try? p.run()) != nil else { return nil }
        for _ in 0..<150 {
            if let e = endpoint() { return e }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private static func post(_ body: Data, to e: Endpoint, cwdOverride: String? = nil) -> (status: Int, data: Data)? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(e.port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(e.token)", forHTTPHeaderField: "Authorization")
        // Where the agent works and who started this shim: the app ties the connection to a worktree's session.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-_.~")
        let cwdPath = cwdOverride ?? FileManager.default.currentDirectoryPath
        if let cwd = cwdPath.addingPercentEncoding(withAllowedCharacters: allowed) {
            request.setValue(cwd, forHTTPHeaderField: "X-Greenroom-Cwd")
        }
        request.setValue(String(getppid()), forHTTPHeaderField: "X-Greenroom-Parent")
        let done = DispatchSemaphore(value: 0)
        var out: (Int, Data)?
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 300
        config.connectionProxyDictionary = [:]   // loopback only: never through a proxy
        URLSession(configuration: config).dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { out = (http.statusCode, data ?? Data()) }
            done.signal()
        }.resume()
        done.wait()
        return out.map { (status: $0.0, data: $0.1) }
    }

    /// `Greenroom --link-apk APK [--pr N] [--worktree DIR] [--open]`: notifies the running Greenroom app that a
    /// local APK file is meant for a PR and/or worktree session and links it over the authenticated loopback channel.
    static func linkAPK(args: [String]) -> Never {
        func usage() -> Never {
            FileHandle.standardError.write(Data("usage: Greenroom --link-apk PATH.apk [--pr NUMBER] [--worktree DIR] [--open]\n".utf8))
            exit(2)
        }
        guard !args.isEmpty else { usage() }
        var apkPath = ""
        var prNumber: Int?
        var worktreePath: String?
        var shouldOpen = false
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--pr":
                guard i + 1 < args.count, let n = Int(args[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "#"))), n > 0 else { usage() }
                prNumber = n; i += 2
            case "--worktree":
                guard i + 1 < args.count else { usage() }
                worktreePath = (args[i + 1] as NSString).expandingTildeInPath; i += 2
            case "--open":
                shouldOpen = true; i += 1
            case "--agent-check":
                i += 1
            default:
                if apkPath.isEmpty && !a.hasPrefix("-") { apkPath = (a as NSString).expandingTildeInPath; i += 1 }
                else { usage() }
            }
        }
        guard !apkPath.isEmpty else { usage() }
        let absAPK = apkPath.hasPrefix("/") ? apkPath : URL(fileURLWithPath: apkPath).path
        var toolArgs: [String: Any] = ["apk": absAPK, "open": shouldOpen]
        if let prNumber { toolArgs["pr_number"] = prNumber }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "link_apk", "arguments": toolArgs],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let e = connect(),
              let r = post(body, to: e, cwdOverride: worktreePath),
              r.status == 200,
              let json = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any] else {
            FileHandle.standardError.write(Data("error: could not contact Greenroom to link \(absAPK)\n".utf8))
            exit(1)
        }
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
            FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
            exit(1)
        }
        if let res = json["result"] as? [String: Any] {
            let content = (res["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            if (res["isError"] as? Bool) == true {
                FileHandle.standardError.write(Data("error: \(content)\n".utf8))
                exit(1)
            }
            if !content.isEmpty { print(content) }
            exit(0)
        }
        FileHandle.standardError.write(Data("error: unexpected response from Greenroom\n".utf8))
        exit(1)
    }

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let body = trimmed.data(using: .utf8) else { continue }
            let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let id = message?["id"]
            let wantsAnswer = message?["method"] != nil && id != nil && !(id is NSNull)
            var answer: Data?
            for attempt in 0..<2 {
                guard let e = connect() else { break }
                if let r = post(body, to: e) {
                    if r.status == 200 { answer = r.data }
                    if r.status == 200 || r.status == 202 { break }
                }
                if attempt == 0 { Thread.sleep(forTimeInterval: 0.5) }   // the app may have just quit: look again
            }
            if message == nil, answer == nil {
                answer = Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}"#.utf8)
            } else if wantsAnswer, answer == nil {
                let failure: [String: Any] = ["jsonrpc": "2.0", "id": id!, "error": ["code": -32603, "message": "Greenroom is not running and could not be started"]]
                answer = try? JSONSerialization.data(withJSONObject: failure)
            }
            if let answer, wantsAnswer || message == nil {
                FileHandle.standardOutput.write(answer)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
        exit(0)
    }
}
