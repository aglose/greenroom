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
    // NOT RUN FOR REAL. These flags and subcommands (`mcp add --scope user NAME -- COMMAND ARGS`, `mcp remove --scope
    // user NAME`, `mcp get NAME`, `mcp list`) are written from memory of Claude Code's CLI, and every check of this
    // file runs against a stand-in `claude` program that records its arguments. If Claude Code's syntax differs,
    // change it here and nowhere else.
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
        case notConnected
        case missing
        /// `claude` answered neither way: the first lines of what it said.
        case unknown(String)
    }

    enum Outcome: Equatable {
        case connected(String)
        case alreadyConnected
        case disconnected(String)
        case notConnected
        case missing
        case failed(String)

        var message: String {
            switch self {
            case .connected(let how): return "Connected. Claude Code now has Greenroom's simulators" + (how.isEmpty ? "." : " (\(how)).") + " Start a new Claude Code session to use them."
            case .alreadyConnected: return "Already connected: Claude Code has a server called \(serverName)."
            case .disconnected: return "Disconnected: Claude Code no longer lists \(serverName)."
            case .notConnected: return "Not connected: Claude Code has no server called \(serverName)."
            case .missing: return ClaudeConnect.missingMessage
            case .failed(let why): return why
            }
        }
        var ok: Bool {
            switch self {
            case .connected, .alreadyConnected, .disconnected, .notConnected: return true
            case .missing, .failed: return false
            }
        }
    }

    static let missingMessage = "Claude Code's claude program was not found on your PATH (looked where your login shell looks). Install Claude Code, or run the command above in a terminal where claude works."

    /// For a check: the PATH `claude` is looked up on, instead of the login shell's (the real one must never be run).
    static var pathOverride: String?
    /// How long one `claude` call may take.
    static var timeout: TimeInterval = 60

    private struct Run { var status: Int32; var output: String }

    /// The `claude` program on the person's login-shell PATH, nil when there is none. Blocks (the login shell is
    /// asked the first time): off the main thread.
    private static func find() -> (exe: String, env: [String: String])? {
        var env = LoginEnvironment.resolve().env
        if let p = pathOverride { env["PATH"] = p }
        guard let exe = GH.find("claude", in: env["PATH"] ?? "") else { return nil }
        return (exe, env)
    }

    private static func run(_ exe: String, _ args: [String], env: [String: String]) -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Run(status: 126, output: "could not start \(exe)") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return Run(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private static func lines(_ s: String, _ n: Int = 6) -> String {
        let all = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return all.suffix(n).joined(separator: "\n")
    }

    /// `claude mcp get greenroom` (exit 0 and the name in its answer), else `claude mcp list` naming it at the start
    /// of a line. Off the main thread.
    static func status() -> State {
        guard let (exe, env) = find() else { return .missing }
        let got = run(exe, getArguments, env: env)
        if got.status == 0, got.output.localizedCaseInsensitiveContains(serverName) { return .connected }
        let list = run(exe, listArguments, env: env)
        if list.status == 0 {
            let named = list.output.split(whereSeparator: \.isNewline).contains { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(serverName) else { return false }
                let rest = t.dropFirst(serverName.count)
                return rest.isEmpty || rest.first == ":" || rest.first == " " || rest.first == "\t"
            }
            return named ? .connected : .notConnected
        }
        // `get` said no and `list` failed: tell "no such server" (its usual answer) from a program that is broken.
        let said = got.output.lowercased()
        if got.status != 0, said.contains("no mcp server") || said.contains("not found") { return .notConnected }
        return .unknown(lines(list.output.isEmpty ? got.output : list.output))
    }

    static func connect() -> Outcome {
        switch status() {
        case .missing: return .missing
        case .connected: return .alreadyConnected
        case .unknown, .notConnected: break
        }
        guard let (exe, env) = find() else { return .missing }
        let r = run(exe, addArguments(executable: executable), env: env)
        if r.status == 0 { return .connected(lines(r.output, 1)) }
        if r.output.lowercased().contains("already exists") { return .alreadyConnected }
        return .failed("claude mcp add failed (exit \(r.status)):\n" + lines(r.output))
    }

    static func disconnect() -> Outcome {
        guard let (exe, env) = find() else { return .missing }
        let r = run(exe, removeArguments, env: env)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(connected ? "Claude Code is connected to Greenroom" : "Give Claude Code these simulators")
                Spacer()
                if connected {
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
