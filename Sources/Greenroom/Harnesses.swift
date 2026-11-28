import AppKit

/// An agent harness the Connect screen can connect (docs/AGENT-FIRST-SPEC.md, "Installing, per harness"): what it
/// would run or write, said before it does, whether it is connected, and the way in and out. Each connector uses
/// the harness's own command where it has one and writes the harness's file only where there is none.
///
/// Every call here may run a program or read a file: never on the main thread.
struct Harness {
    enum Link: Equatable {
        /// Connected to this copy: how, to read after the harness's name ("as MCP server greenroom").
        case connected(String)
        /// An entry called greenroom runs another program than this copy (what it runs).
        case otherCopy(String)
        case notConnected
        case notInstalled
        /// The harness answered neither way: what it said.
        case unknown(String)

        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    struct Result: Equatable {
        let ok: Bool
        let message: String
    }

    let id: String
    let name: String
    /// Two letters for the row's badge.
    let badge: String
    let color: NSColor
    /// What connecting runs or writes, exactly.
    let how: () -> String
    let status: () -> Link
    let connect: () -> Result
    /// Points an entry that runs another copy at this one.
    let replace: () -> Result
    let disconnect: () -> Result
    /// Where this harness reads Greenroom's skill from, nil when it has the skill another way (Claude Code's plugin).
    let skill: () -> Skills.Place?
}

enum Harnesses {
    /// The harnesses with a connector, in the order the screen lists them.
    static let connectable: [Harness] = [claude, codex, cursor]

    /// The home folder the connectors read and write in (for a check: a folder of its own).
    static var home = FileManager.default.homeDirectoryForCurrentUser
    /// Where applications are looked for (for a check: nowhere).
    static var appFolders: [URL] = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]

    /// What any other MCP client is told to run: this copy as a stdio server.
    static var stdioCommand: String { "\"\(ClaudeConnect.executable)\" --mcp" }
    /// The same, as the JSON most clients' settings take.
    static var stdioJSON: String {
        let entry: [String: Any] = ["mcpServers": [ClaudeConnect.serverName: ["command": ClaudeConnect.executable, "args": ["--mcp"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func app(_ name: String) -> URL? {
        appFolders.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func onPath(_ program: String) -> Bool { ClaudeConnect.find(program) != nil }

    /// Harnesses found on this Mac that Greenroom has no connector for yet (the person adds the stdio command there),
    /// and the hosts that run a connected harness and so need nothing of their own.
    static func alsoFound() -> (byHand: [String], hosts: [String]) {
        var byHand: [String] = []
        if app("Antigravity.app") != nil { byHand.append("Antigravity") }
        if onPath("gemini") { byHand.append("Gemini CLI") }
        if app("Visual Studio Code.app") != nil || onPath("code") { byHand.append("VS Code") }
        if onPath("copilot") { byHand.append("Copilot CLI") }
        if onPath("opencode") { byHand.append("opencode") }
        if app("Zed.app") != nil { byHand.append("Zed") }
        if onPath("goose") { byHand.append("Goose") }
        var hosts: [String] = []
        if app("T3 Code.app") != nil || onPath("t3") { hosts.append("T3 Code") }
        if app("Conductor.app") != nil { hosts.append("Conductor") }
        return (byHand, hosts)
    }

    private static func result(_ o: ClaudeConnect.Outcome) -> Harness.Result { Harness.Result(ok: o.ok, message: o.message) }

    private static func alsoWrites(_ place: Skills.Place, _ more: String) -> String {
        "\n\nAnd writes Greenroom's skill to \(place.shown)\(more)."
    }

    /// After a harness was connected or disconnected, its skill follows: written (or this harness's name added to
    /// the one that is there) when LINK says it is connected to this copy, its name taken off when it is not
    /// connected. A harness on another copy, or one that did not answer, is left as it is. Answers what happened,
    /// nil when nothing changed. Without CREATING no file is made: a file Greenroom wrote is kept true, and that is
    /// all (what looking does, as against connecting). The Debug copy writes no skill.
    @discardableResult
    static func settleSkill(_ h: Harness, _ link: Harness.Link, creating: Bool = true) -> Skills.Result? {
        if ClaudeConnect.repositoryOnly { return nil }
        var said: [Skills.Result] = []
        switch link {
        case .connected:
            let place = h.skill()
            for other in Skills.Place.allCases where other != place { said.append(Skills.remove(other, for: h.id)) }
            if let place, creating || Skills.state(place).isOurs { said.append(Skills.install(place, for: h.id)) }
        case .notConnected:
            for place in Skills.Place.allCases { said.append(Skills.remove(place, for: h.id)) }
        case .otherCopy, .notInstalled, .unknown:
            return nil
        }
        let spoken = said.filter { !$0.message.isEmpty }
        guard !spoken.isEmpty else { return nil }
        return Skills.Result(ok: !spoken.contains { !$0.ok }, message: spoken.map(\.message).joined(separator: " "))
    }

    /// Whether Claude Code has the plugin, as its last status found it: the plugin carries the skill.
    private static var claudePlugin = false

    // MARK: Claude Code

    static let claude = Harness(
        id: "claude", name: "Claude Code", badge: "CC", color: NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1),
        how: { ClaudeConnect.displayCommand() + alsoWrites(.claude, "") + "\n\nOr, typed inside Claude Code, the plugin (the same tools, with the skill and the greenroom command in it):\n" + ClaudeConnect.pluginMarketplaceCommand + "\n" + ClaudeConnect.pluginInstallCommand },
        status: {
            let entry = ClaudeConnect.status()
            if entry == .missing { return .notInstalled }
            let plugin = ClaudeConnect.pluginInstalled()
            claudePlugin = plugin
            switch entry {
            case .connected:
                return .connected(plugin ? "as MCP server \(ClaudeConnect.serverName) and through the plugin, so its tools are listed twice" : "as MCP server \(ClaudeConnect.serverName)")
            case .otherCopy(let path):
                return plugin ? .connected("through the plugin. An MCP entry called \(ClaudeConnect.serverName) also runs another copy (\(path))") : .otherCopy(path)
            case .notConnected: return plugin ? .connected("through the plugin") : .notConnected
            case .unknown(let why): return plugin ? .connected("through the plugin") : .unknown(why)
            case .missing: return .notInstalled
            }
        },
        connect: { result(ClaudeConnect.connect()) },
        replace: { result(ClaudeConnect.reconnect()) },
        disconnect: { result(ClaudeConnect.disconnect()) },
        skill: { claudePlugin ? nil : .claude })

    // MARK: Codex

    static let codex = Harness(
        id: "codex", name: "Codex", badge: "CX", color: NSColor(srgbRed: 0.45, green: 0.62, blue: 0.95, alpha: 1),
        how: { CodexConnect.displayCommand() + alsoWrites(.agents, ", which Cursor and other harnesses read too") },
        status: { CodexConnect.status() },
        connect: { CodexConnect.connect() },
        replace: { CodexConnect.replace() },
        disconnect: { CodexConnect.disconnect() },
        skill: { .agents })

    // MARK: Cursor

    static let cursor = Harness(
        id: "cursor", name: "Cursor", badge: "CU", color: NSColor(srgbRed: 0.78, green: 0.78, blue: 0.82, alpha: 1),
        how: { CursorConnect.displayChange() + alsoWrites(.agents, ", which Codex and other harnesses read too") },
        status: { CursorConnect.status() },
        connect: { CursorConnect.connect() },
        replace: { CursorConnect.connect() },
        disconnect: { CursorConnect.disconnect() },
        skill: { .agents })
}

/// Codex's connector: `codex mcp add`, as the person would type it. The syntax is from Codex's documentation
/// (`codex mcp add <name> -- <command>`, `mcp get <name> --json`, `mcp remove <name>`) and was never run against a
/// real Codex: every check runs a stand-in that records its arguments. If Codex's syntax changes, change it here.
enum CodexConnect {
    static var serverName: String { ClaudeConnect.serverName }
    static func addArguments(executable: String) -> [String] { ["mcp", "add", serverName, "--", executable, "--mcp"] }
    static var getArguments: [String] { ["mcp", "get", serverName, "--json"] }
    static var removeArguments: [String] { ["mcp", "remove", serverName] }

    static func displayCommand(executable: String = ClaudeConnect.executable) -> String {
        "codex mcp add \(serverName) -- \"\(executable)\" --mcp"
    }

    /// `codex` on the login-shell PATH, else the one inside the Codex or ChatGPT app.
    private static func find() -> (exe: String, env: [String: String])? {
        if let found = ClaudeConnect.find("codex") { return found }
        for name in ["Codex.app", "ChatGPT.app"] {
            guard let app = Harnesses.app(name) else { continue }
            let exe = app.appendingPathComponent("Contents/Resources/codex").path
            if FileManager.default.isExecutableFile(atPath: exe) { return (exe, LoginEnvironment.resolve().env) }
        }
        return nil
    }

    /// The program a `get` answer names: the `command` of its JSON, wherever it sits, else a `command` line.
    static func command(in text: String) -> String? {
        func dig(_ any: Any) -> String? {
            guard let d = any as? [String: Any] else { return nil }
            if let c = d["command"] as? String, !c.isEmpty { return c }
            for (_, v) in d.sorted(by: { $0.key < $1.key }) { if let c = dig(v) { return c } }
            return nil
        }
        if let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data), let c = dig(obj) { return c }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.lowercased().hasPrefix("command") else { continue }
            let rest = t.dropFirst(7).drop { $0 == ":" || $0 == "=" || $0 == " " }
            var c = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if c.hasSuffix(" --mcp") { c = String(c.dropLast(6)) }
            if !c.isEmpty { return c }
        }
        return nil
    }

    static func status() -> Harness.Link {
        guard let (exe, env) = find() else { return .notInstalled }
        var got = ClaudeConnect.run(exe, getArguments, env: env)
        if got.status != 0, !got.timedOut, got.output.lowercased().contains("--json") {
            got = ClaudeConnect.run(exe, Array(getArguments.dropLast()), env: env)   // a Codex without --json on get
        }
        if got.timedOut { return .unknown("codex did not answer within \(Int(ClaudeConnect.timeout)) s") }
        guard got.status == 0 else { return .notConnected }
        guard let cmd = command(in: got.output) else {
            return got.output.contains(ClaudeConnect.executable) ? .connected("as MCP server \(serverName)") : .otherCopy("an unknown program")
        }
        return ClaudeConnect.same(cmd, ClaudeConnect.executable) ? .connected("as MCP server \(serverName)") : .otherCopy(cmd)
    }

    static func connect() -> Harness.Result {
        switch status() {
        case .notInstalled: return Harness.Result(ok: false, message: missingMessage)
        case .connected: return Harness.Result(ok: true, message: "Already connected: Codex has a server called \(serverName).")
        case .otherCopy(let path): return Harness.Result(ok: true, message: "Codex's \(serverName) server runs another copy of Greenroom (\(path)). Reconnect points it at this one.")
        case .notConnected, .unknown: return add()
        }
    }

    static let missingMessage = "Codex's codex program was not found on your PATH or inside the Codex app. Install Codex, or run the command above in a terminal where codex works."

    private static func add() -> Harness.Result {
        if ClaudeConnect.translocated { return Harness.Result(ok: false, message: ClaudeConnect.translocatedMessage) }
        guard let (exe, env) = find() else { return Harness.Result(ok: false, message: missingMessage) }
        let r = ClaudeConnect.run(exe, addArguments(executable: ClaudeConnect.executable), env: env)
        if r.timedOut { return Harness.Result(ok: false, message: "codex mcp add did not finish within \(Int(ClaudeConnect.timeout)) s and was stopped (timed out)") }
        guard r.status == 0 else { return Harness.Result(ok: false, message: "codex mcp add failed (exit \(r.status)):\n" + ClaudeConnect.lines(r.output)) }
        switch status() {
        case .connected: return Harness.Result(ok: true, message: "Connected. Codex now has Greenroom's simulators. Start a new Codex session to use them.")
        case .otherCopy(let path): return Harness.Result(ok: false, message: "codex mcp add said it worked, but Codex's \(serverName) entry runs \(path), not this copy.")
        case .notConnected: return Harness.Result(ok: false, message: "codex mcp add said it worked, but codex mcp get finds no \(serverName) server.")
        case .notInstalled: return Harness.Result(ok: false, message: missingMessage)
        case .unknown(let why): return Harness.Result(ok: false, message: "codex mcp add said it worked, but the entry could not be checked: \(why)")
        }
    }

    static func replace() -> Harness.Result {
        let off = disconnect()
        guard off.ok else { return Harness.Result(ok: false, message: "Reconnect stopped at the remove step, and nothing was added. " + off.message) }
        return add()
    }

    static func disconnect() -> Harness.Result {
        guard let (exe, env) = find() else { return Harness.Result(ok: false, message: missingMessage) }
        let r = ClaudeConnect.run(exe, removeArguments, env: env)
        if r.timedOut { return Harness.Result(ok: false, message: "codex mcp remove did not finish within \(Int(ClaudeConnect.timeout)) s and was stopped (timed out)") }
        guard r.status == 0 else { return Harness.Result(ok: false, message: "codex mcp remove failed (exit \(r.status)):\n" + ClaudeConnect.lines(r.output)) }
        return Harness.Result(ok: true, message: "Disconnected: Codex no longer lists \(serverName).")
    }
}

/// Cursor's connector. Cursor has no command that adds a server, and its install link cannot be seen to have
/// worked, so this is the one connector that writes the harness's file: the `greenroom` entry of
/// `~/.cursor/mcp.json`, which Cursor's editor and its CLI both read. The other entries are kept as they are; the
/// file is written again as sorted, indented JSON. A file that is not plain JSON is left alone, and said so.
enum CursorConnect {
    static var serverName: String { ClaudeConnect.serverName }
    static var file: URL { Harnesses.home.appendingPathComponent(".cursor/mcp.json") }
    static let shownPath = "~/.cursor/mcp.json"

    static func entry(executable: String = ClaudeConnect.executable) -> [String: Any] { ["command": executable, "args": ["--mcp"]] }

    static func displayChange() -> String {
        "Adds to \(shownPath), under mcpServers (the other entries are kept):\n\"\(serverName)\": { \"command\": \"\(ClaudeConnect.executable)\", \"args\": [\"--mcp\"] }"
    }

    static func installed() -> Bool {
        Harnesses.app("Cursor.app") != nil || ClaudeConnect.find("cursor-agent") != nil || ClaudeConnect.find("cursor") != nil
    }

    private enum Loaded { case none, json([String: Any]), unreadable }

    private static func load() -> Loaded {
        guard let data = try? Data(contentsOf: file) else { return .none }
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { return .none }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        if let servers = obj["mcpServers"], !(servers is [String: Any]) { return .unreadable }
        return .json(obj)
    }

    static let unreadableMessage = "\(shownPath) is not plain JSON that Greenroom can read, so it was left as it is. Add the entry above to it by hand."

    static func status() -> Harness.Link {
        guard installed() else { return .notInstalled }
        switch load() {
        case .none: return .notConnected
        case .unreadable: return .unknown(unreadableMessage)
        case .json(let obj):
            guard let mine = (obj["mcpServers"] as? [String: Any])?[serverName] else { return .notConnected }
            guard let cmd = (mine as? [String: Any])?["command"] as? String, !cmd.isEmpty else { return .otherCopy("an unknown program") }
            return ClaudeConnect.same(cmd, ClaudeConnect.executable) ? .connected("in \(shownPath)") : .otherCopy(cmd)
        }
    }

    private static func write(_ obj: [String: Any]) -> Bool {
        let fm = FileManager.default
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        let mode = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions]
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? (data + Data("\n".utf8)).write(to: file, options: .atomic)) != nil else { return false }
        if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
        return true
    }

    /// Sets the entry to this copy, whatever it ran before.
    static func connect() -> Harness.Result {
        if ClaudeConnect.translocated { return Harness.Result(ok: false, message: ClaudeConnect.translocatedMessage) }
        guard installed() else { return Harness.Result(ok: false, message: "Cursor was not found on this Mac.") }
        var obj: [String: Any]
        switch load() {
        case .unreadable: return Harness.Result(ok: false, message: unreadableMessage)
        case .none: obj = [:]
        case .json(let o): obj = o
        }
        var servers = obj["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = entry()
        obj["mcpServers"] = servers
        guard write(obj) else { return Harness.Result(ok: false, message: "\(shownPath) could not be written.") }
        guard status().isConnected else { return Harness.Result(ok: false, message: "\(shownPath) was written, but it does not hold the \(serverName) entry.") }
        return Harness.Result(ok: true, message: "Connected. Cursor now has Greenroom's simulators (\(shownPath)). It may ask you to enable the server under Settings > MCP.")
    }

    static func disconnect() -> Harness.Result {
        switch load() {
        case .unreadable: return Harness.Result(ok: false, message: unreadableMessage)
        case .none: return Harness.Result(ok: true, message: "Not connected: \(shownPath) has no \(serverName) entry.")
        case .json(var obj):
            guard var servers = obj["mcpServers"] as? [String: Any], servers[serverName] != nil else {
                return Harness.Result(ok: true, message: "Not connected: \(shownPath) has no \(serverName) entry.")
            }
            servers[serverName] = nil
            obj["mcpServers"] = servers
            guard write(obj) else { return Harness.Result(ok: false, message: "\(shownPath) could not be written.") }
            return Harness.Result(ok: true, message: "Disconnected: \(shownPath) no longer has a \(serverName) entry.")
        }
    }
}
