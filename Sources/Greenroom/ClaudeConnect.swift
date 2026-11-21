import AppKit
import SwiftUI

// "Connect Claude Code" (docs/SESSIONS-PLAN.md, "5. The Claude Code link"): Settings > Claude Code shows the command
// that registers this copy of Greenroom as an MCP server of Claude Code, runs it on a click through the person's
// own login-shell PATH, and says when it is already connected. Nothing here edits Claude Code's files: only the
// person's own `claude` program does, as it would if they typed the command.

enum ClaudeConnect {
    /// The name the server is registered under.
    static let serverName = "greenroom"

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

    /// This copy's program: what `claude` is told to run for the MCP server.
    static var executable: String { Bundle.main.executablePath ?? CommandLine.arguments[0] }

    /// The command as the person would type it (shown before it runs, and copied by the Agent popover).
    static func displayCommand(executable: String = ClaudeConnect.executable) -> String {
        "claude mcp add --scope user \(serverName) -- \"\(executable)\" --mcp"
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
        case failed(String)

        var message: String {
            switch self {
            case .connected(let how): return "Connected. Claude Code now has Greenroom's simulators" + (how.isEmpty ? "." : " (\(how)).") + " Start a new Claude Code session to use them."
            case .alreadyConnected: return "Already connected: Claude Code has a server called \(serverName)."
            case .otherCopy(let path): return "Claude Code's \(serverName) server runs another copy of Greenroom (\(path)). Reconnect points it at this one."
            case .disconnected: return "Disconnected: Claude Code no longer lists \(serverName)."
            case .notConnected: return "Not connected: Claude Code has no server called \(serverName)."
            case .missing: return ClaudeConnect.missingMessage
            case .failed(let why): return why
            }
        }
        var ok: Bool {
            switch self {
            case .connected, .alreadyConnected, .otherCopy, .disconnected, .notConnected: return true
            case .missing, .failed: return false
            }
        }
    }

    static let missingMessage = "Claude Code's claude program was not found on your PATH (looked where your login shell looks). Install Claude Code, or run the command above in a terminal where claude works."

    /// For a check: the PATH `claude` is looked up on, instead of the login shell's (the real one must never be run).
    static var pathOverride: String?
    /// How long one `claude` call may take.
    static var timeout: TimeInterval = 60

    private struct Run { var status: Int32; var output: String; var timedOut = false }

    /// The `claude` program on the person's login-shell PATH, nil when there is none. Blocks (the login shell is
    /// asked the first time): never on the main thread.
    private static func find() -> (exe: String, env: [String: String])? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var env = LoginEnvironment.resolve().env
        if let p = pathOverride { env["PATH"] = p }
        guard let exe = GH.find("claude", in: env["PATH"] ?? "") else { return nil }
        return (exe, env)
    }

    /// Runs one `claude` call. Its output goes to a file, not a pipe, so nothing a grandchild holds open can keep this
    /// waiting; at the deadline the process is ended (SIGTERM, then SIGKILL after 2 s) and the call answers.
    private static func run(_ exe: String, _ args: [String], env: [String: String]) -> Run {
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

    private static func lines(_ s: String, _ n: Int = 6) -> String {
        let all = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return all.suffix(n).joined(separator: "\n")
    }

    /// What `get` or `list` said about the server: connected here, connected to another program, or not at all.
    private static func judge(_ text: String) -> State {
        text.contains(executable) ? .connected : .otherCopy(command(in: text) ?? "an unknown program")
    }

    /// The program path a `get` answer names: its `Command:` line, or the first absolute path.
    private static func command(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("command:") { return t.dropFirst(8).trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first }
        }
        return text.split(whereSeparator: { $0.isWhitespace }).map(String.init).first { $0.hasPrefix("/") }
    }

    /// `claude mcp get greenroom`: an answer naming it, or "no such server", is final. Only when `get` itself is not
    /// there (an old claude) is `claude mcp list` asked, naming it at the start of a line. Off the main thread.
    static func status() -> State {
        guard let (exe, env) = find() else { return .missing }
        let got = run(exe, getArguments, env: env)
        if got.timedOut { return .unknown("claude did not answer within \(Int(timeout)) s") }
        let said = got.output.lowercased()
        if got.status == 0, said.contains(serverName) { return judge(got.output) }
        if said.contains("no mcp server") || said.contains("not found") { return .notConnected }
        let unsupported = said.contains("unknown command") || said.contains("unrecognized") || said.contains("unknown argument")
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
        switch status() {
        case .missing: return .missing
        case .connected: return .alreadyConnected
        case .otherCopy(let path): return .otherCopy(path)
        case .unknown, .notConnected: break
        }
        return add()
    }

    private static func add() -> Outcome {
        guard let (exe, env) = find() else { return .missing }
        let r = run(exe, addArguments(executable: executable), env: env)
        if r.timedOut { return .failed("claude mcp add did not finish within \(Int(timeout)) s and was stopped (timed out)") }
        if r.status == 0 { return .connected(lines(r.output, 1)) }
        if r.output.lowercased().contains("already exists") { return .alreadyConnected }
        return .failed("claude mcp add failed (exit \(r.status)):\n" + lines(r.output))
    }

    /// Points an entry that runs another copy at this one: remove, then add.
    static func reconnect() -> Outcome {
        let off = disconnect()
        if case .failed = off { return off }
        if off == .missing { return off }
        return add()
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

/// Settings > Claude Code, "Connect Claude Code": the command, a button, and what happened.
struct ClaudeConnectView: View {
    @State private var state: ClaudeConnect.State?
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false

    private var connected: Bool { state == .connected }
    private var otherCopy: Bool { if case .otherCopy = state { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(connected ? "Claude Code is connected to Greenroom" : (otherCopy ? "Claude Code is connected to another copy of Greenroom" : "Give Claude Code these simulators"))
                Spacer()
                if otherCopy {
                    Button("Reconnect") { act { ClaudeConnect.reconnect() } }.disabled(busy)
                } else if connected {
                    Button("Disconnect") { act { ClaudeConnect.disconnect() } }.disabled(busy)
                } else {
                    Button("Connect Claude Code") { act { ClaudeConnect.connect() } }.disabled(busy || state == .missing)
                }
            }
            Text(ClaudeConnect.displayCommand())
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .foregroundStyle(.secondary)
            if state == .missing {
                Text(ClaudeConnect.missingMessage).font(.caption).foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(failed ? .red : .secondary).textSelection(.enabled)
            }
            Text("Runs the command above with your own claude program, from your login shell\u{2019}s PATH. It changes only Claude Code\u{2019}s own list of servers; \"Disconnect\" removes it again.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { look() }
    }

    private func look() {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = ClaudeConnect.status()
            DispatchQueue.main.async { state = s }
        }
    }

    private func act(_ work: @escaping () -> ClaudeConnect.Outcome) {
        busy = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let o = work()
            DispatchQueue.main.async {
                busy = false
                message = o.message
                failed = !o.ok
                look()
            }
        }
    }
}
