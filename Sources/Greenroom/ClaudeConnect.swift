import AppKit

// Claude Code's connector (docs/AGENT-FIRST-SPEC.md, "Installing, per harness"): the Connect screen shows the
// command that registers this copy of Greenroom as an MCP server of Claude Code, runs it through the person's own
// login-shell PATH, and says when it is already connected, as an MCP entry or through the plugin. Nothing here
// edits Claude Code's files: only the person's own `claude` program does, as it would if they typed the command.
//
// The Debug copy is for developing Greenroom itself, so it is never registered for every project: the Greenroom
// repository's own `.mcp.json` registers it, for agents working in that repository and its worktrees. Here the
// Debug copy only looks for an entry at user scope left by an earlier build, and removes it when asked.

enum ClaudeConnect {
    /// The name the server is registered under: the debug copy has its own (`greenroom-debug`), so connecting it never
    /// replaces the release's entry.
    static let serverName = Variant.isDebug ? "greenroom-debug" : "greenroom"

    // MARK: The claude mcp command line (the one place)
    //
    // Checked against the CLI's own `--help` (`mcp add [options] <name> <commandOrUrl> [args...]`, `-s/--scope`,
    // `mcp remove -s`, `mcp get <name>`, `mcp list`), but never RUN for real: every check of this file runs against a
    // stand-in `claude` program that records its arguments. If Claude Code's syntax changes, change it here and
    // nowhere else.
    static func addArguments(executable: String) -> [String] { ["mcp", "add", "--scope", "user", serverName, "--", executable, "--mcp"] }
    static let removeArguments = ["mcp", "remove", "--scope", "user", serverName]
    static let getArguments = ["mcp", "get", serverName]
    static let listArguments = ["mcp", "list"]
    static let pluginListArguments = ["plugin", "list"]

    /// The Debug copy: reachable from the Greenroom repository alone, through its `.mcp.json`. Never added at user scope.
    static var repositoryOnly: Bool { repositoryOnlyOverride ?? Variant.isDebug }
    /// For a check: this copy behaves as the Debug copy does (or does not).
    static var repositoryOnlyOverride: Bool?
    static let repositoryOnlyMessage = "Greenroom Debug is not added to every project. The Greenroom repository registers it in its .mcp.json, so agents working in that repository or one of its worktrees have it, and no others."

    /// This copy's program: what `claude` is told to run for the MCP server.
    static var executable: String { executableOverride ?? Bundle.main.executablePath ?? CommandLine.arguments[0] }
    /// For a check: the program this copy claims to be.
    static var executableOverride: String?

    /// macOS runs an app opened from Downloads (or a disk image) from a temporary, randomised copy; a path there stops
    /// existing, so it must not be registered.
    static var translocated: Bool { executable.contains("/AppTranslocation/") }
    static let translocatedMessage = "Greenroom is running from a temporary location macOS made for an app opened from Downloads or a disk image (App Translocation), and that path stops working. Move Greenroom.app to Applications, open it from there, then connect."

    /// The command as the person would type it (shown before it runs, and copied by the Agent popover).
    static func displayCommand(executable: String = ClaudeConnect.executable) -> String {
        "claude mcp add --scope user \(serverName) -- \"\(executable)\" --mcp"
    }

    // MARK: The plugin (the other way to connect)
    //
    // The repository is its own Claude Code marketplace (.claude-plugin/marketplace.json, plugin/): the plugin brings
    // the same server, started by a script that finds the installed app, and a skill that teaches the verify loop.
    // Typed inside Claude Code by the person; Greenroom never runs these. scripts/plugin-check.py holds the names
    // to the manifests.
    static let pluginMarketplaceCommand = "/plugin marketplace add aglose/greenroom"
    static let pluginInstallCommand = "/plugin install greenroom@greenroom"
    /// The plugin as `claude plugin list` names it.
    static let pluginID = "greenroom@greenroom"

    /// Whether Claude Code has the Greenroom plugin, enabled: `claude plugin list` names it and its block says
    /// enabled. The plugin's script starts the installed release app, so the Debug copy never counts it. Off the main thread.
    static func pluginInstalled() -> Bool {
        guard !repositoryOnly, let (exe, env) = find() else { return false }
        let r = run(exe, pluginListArguments, env: env)
        guard r.status == 0 else { return false }
        var mine = false
        for line in r.output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { mine = false; continue }
            if t.split(separator: " ").contains(where: { $0 == pluginID }) { mine = true; continue }
            if mine, t.lowercased().hasPrefix("status:") { return t.lowercased().contains("enabled") }
        }
        return false
    }

    /// Whether the installed plugin carries Greenroom's hooks (plugins from before A4 do not): a `hooks/hooks.json`
    /// in a copy of it in Claude Code's plugin cache (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>`).
    /// That folder is Claude Code's own, so a layout this does not know answers no: Greenroom's hooks then go in
    /// Claude Code's settings as well, and a session's hooks arrive twice, which changes nothing it shows.
    static func pluginHasHooks() -> Bool {
        let fm = FileManager.default
        let parts = pluginID.split(separator: "@").map(String.init)   // plugin@marketplace
        guard parts.count == 2 else { return false }
        let copies = Harnesses.home.appendingPathComponent(".claude/plugins/cache/\(parts[1])/\(parts[0])", isDirectory: true)
        for version in (try? fm.contentsOfDirectory(at: copies, includingPropertiesForKeys: nil)) ?? []
        where fm.fileExists(atPath: version.appendingPathComponent("hooks/hooks.json").path) { return true }
        return false
    }

    // MARK: Running claude

    enum State: Equatable {
        case connected
        /// A `greenroom` entry exists but runs another program than this copy (the path it names).
        case otherCopy(String)
        case notConnected
        case missing
        /// `claude` answered neither way: the first lines of what it said.
        case unknown(String)
    }

    enum Outcome: Equatable {
        case connected(String)
        case alreadyConnected
        case otherCopy(String)
        case disconnected(String)
        case notConnected
        case missing
        /// The Debug copy: nothing was added (see `repositoryOnly`).
        case repositoryOnly
        case failed(String)

        var message: String {
            switch self {
            case .connected(let how): return "Connected. Claude Code now has Greenroom's simulators" + (how.isEmpty ? "." : " (\(how)).") + " Start a new Claude Code session to use them."
            case .alreadyConnected: return "Already connected: Claude Code has a server called \(serverName)."
            case .otherCopy(let path): return "Claude Code's \(serverName) server runs another copy of Greenroom (\(path)). Reconnect points it at this one."
            case .disconnected: return "Disconnected: Claude Code no longer lists \(serverName)."
            case .notConnected: return "Not connected: Claude Code has no server called \(serverName)."
            case .missing: return ClaudeConnect.missingMessage
            case .repositoryOnly: return ClaudeConnect.repositoryOnlyMessage
            case .failed(let why): return why
            }
        }
        var ok: Bool {
            switch self {
            case .connected, .alreadyConnected, .otherCopy, .disconnected, .notConnected, .repositoryOnly: return true
            case .missing, .failed: return false
            }
        }
    }

    static let missingMessage = "Claude Code's claude program was not found on your PATH (looked where your login shell looks). Install Claude Code, or run the command above in a terminal where claude works."

    /// For a check: the PATH `claude` is looked up on, instead of the login shell's (the real one must never be run).
    static var pathOverride: String?
    /// How long one `claude` call may take.
    static var timeout: TimeInterval = 60

    struct Run { var status: Int32; var output: String; var timedOut = false }

    /// The `claude` program on the person's login-shell PATH, nil when there is none. Blocks (the login shell is
    /// asked the first time): never on the main thread.
    private static func find() -> (exe: String, env: [String: String])? { find("claude") }

    /// A program on the person's login-shell PATH, with the environment to run it in. The other connectors use it too.
    static func find(_ program: String) -> (exe: String, env: [String: String])? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var env = LoginEnvironment.resolve().env
        if let p = pathOverride { env["PATH"] = p }
        guard let exe = GH.find(program, in: env["PATH"] ?? "") else { return nil }
        return (exe, env)
    }

    /// Runs one `claude` call. Its output goes to a file, not a pipe, so nothing a grandchild holds open can keep this
    /// waiting; at the deadline the process is ended (SIGTERM, then SIGKILL after 2 s) and the call answers.
    static func run(_ exe: String, _ args: [String], env: [String: String]) -> Run {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("greenroom-claude-\(UUID().uuidString.prefix(8)).out")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: log) }
        guard let out = try? FileHandle(forWritingTo: log) else { return Run(status: 126, output: "could not start \(exe)") }
        defer { try? out.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Run(status: 126, output: "could not start \(exe)") }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline {
                timedOut = true
                p.terminate()
                let grace = Date().addingTimeInterval(2)
                while p.isRunning, Date() < grace { usleep(50_000) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                break
            }
            usleep(30_000)
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return Run(status: timedOut ? 124 : p.terminationStatus, output: text, timedOut: timedOut)
    }

    static func lines(_ s: String, _ n: Int = 6) -> String {
        let all = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return all.suffix(n).joined(separator: "\n")
    }

    static func same(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// What `get` or `list` said about the server: connected here (the whole command equals this program's path),
    /// connected to another program, or not at all.
    private static func judge(_ text: String) -> State {
        guard let cmd = command(in: text) else { return .otherCopy("an unknown program") }
        return same(cmd, executable) ? .connected : .otherCopy(cmd)
    }

    /// The program an answer names, whole (a path may hold spaces): the rest of `get`'s `Command:` line, or, for a
    /// `list` line `greenroom: PATH --mcp - status`, what lies between the colon and ` --mcp` (else ` - `).
    private static func command(in text: String) -> String? {
        func trimmed(_ s: Substring) -> String? {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(" --mcp") { t = String(t.dropLast(6)).trimmingCharacters(in: .whitespaces) }
            return t.isEmpty ? nil : t
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("command:") { return trimmed(t.dropFirst(8)) }
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(serverName + ":") else { continue }
            var rest = String(t.dropFirst(serverName.count + 1)).trimmingCharacters(in: .whitespaces)
            if let r = rest.range(of: " --mcp", options: .backwards) { rest = String(rest[..<r.lowerBound]) }
            else if let r = rest.range(of: " - ") { rest = String(rest[..<r.lowerBound]) }
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    /// `claude mcp get greenroom`. The exit code is the rule: 0 and the name is an entry, 1 is "no such server" (the CLI
    /// says `No MCP server named "greenroom". Configured servers: ...`; the words are only a hint). Only when `get`
    /// itself is not there (an old claude) is `claude mcp list` asked, naming it at the start of a line. Off the main thread.
    static func status() -> State {
        guard let (exe, env) = find() else { return .missing }
        let got = run(exe, getArguments, env: env)
        if got.timedOut { return .unknown("claude did not answer within \(Int(timeout)) s") }
        let said = got.output.lowercased()
        if got.status == 0, said.contains(serverName) { return judge(got.output) }
        let unsupported = said.contains("unknown command") || said.contains("unrecognized") || said.contains("unknown argument")
        // Exit 1 is "no such server" only when the answer says so: a broken configuration also exits 1.
        let missing = said.contains("no mcp server") || said.contains("not found") || said.contains(serverName) || said.isEmpty
        if got.status == 1, !unsupported { return missing ? .notConnected : .unknown(lines(got.output)) }
        guard unsupported else { return .unknown(lines(got.output)) }
        let list = run(exe, listArguments, env: env)
        if list.timedOut { return .unknown("claude did not answer within \(Int(timeout)) s") }
        guard list.status == 0 else { return .unknown(lines(list.output)) }
        for line in list.output.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(serverName) else { continue }
            let rest = t.dropFirst(serverName.count)
            if rest.isEmpty || rest.first == ":" || rest.first == " " || rest.first == "\t" { return judge(t) }
        }
        return .notConnected
    }

    static func connect() -> Outcome {
        if repositoryOnly { return .repositoryOnly }
        switch status() {
        case .missing: return .missing
        case .connected: return .alreadyConnected
        case .otherCopy(let path): return .otherCopy(path)
        case .unknown, .notConnected: break
        }
        return add()
    }

    /// `claude mcp add`, then a `get` to see that the entry runs this copy: "Connected" only when it does.
    private static func add() -> Outcome {
        if translocated { return .failed(translocatedMessage) }
        guard let (exe, env) = find() else { return .missing }
        let r = run(exe, addArguments(executable: executable), env: env)
        if r.timedOut { return .failed("claude mcp add did not finish within \(Int(timeout)) s and was stopped (timed out)") }
        if r.status != 0 {
            if r.output.lowercased().contains("already exists") { return .alreadyConnected }
            return .failed("claude mcp add failed (exit \(r.status)):\n" + lines(r.output))
        }
        switch status() {
        case .connected: return .connected(lines(r.output, 1))
        case .otherCopy(let path): return .failed("claude mcp add said it worked, but Claude Code's \(serverName) entry runs \(path), not this copy.")
        case .notConnected: return .failed("claude mcp add said it worked, but claude mcp get finds no \(serverName) server.")
        case .missing: return .missing
        case .unknown(let why): return .failed("claude mcp add said it worked, but the entry could not be checked: \(why)")
        }
    }

    /// Points an entry that runs another copy at this one: remove, then add. Each step's own words are reported, and
    /// "Connected" only when a `get` afterwards shows this copy.
    static func reconnect() -> Outcome {
        if repositoryOnly { return .repositoryOnly }
        if translocated { return .failed(translocatedMessage) }
        let off = disconnect()
        switch off {
        case .disconnected: break
        case .notConnected: return .failed("claude mcp remove said there is no \(serverName) server, so there was nothing to replace and nothing was added. Choose Connect Claude Code.")
        case .missing: return .missing
        case .failed(let why): return .failed("Reconnect stopped at the remove step, and nothing was added. " + why)
        default: return off
        }
        switch add() {
        case .connected(let how): return .connected(how)
        case .failed(let why): return .failed("The old greenroom entry was removed, but adding this copy failed, so Claude Code now has none. " + why)
        case let other: return other
        }
    }

    static func disconnect() -> Outcome {
        guard let (exe, env) = find() else { return .missing }
        let r = run(exe, removeArguments, env: env)
        if r.timedOut { return .failed("claude mcp remove did not finish within \(Int(timeout)) s and was stopped (timed out)") }
        if r.status == 0 { return .disconnected(lines(r.output, 1)) }
        let said = r.output.lowercased()
        if said.contains("no mcp server") || said.contains("not found") { return .notConnected }
        return .failed("claude mcp remove failed (exit \(r.status)):\n" + lines(r.output))
    }
}
