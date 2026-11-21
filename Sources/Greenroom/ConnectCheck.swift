import Foundation

/// `Greenroom --connect-check DIR`: Connect Claude Code against a stand-in `claude` program, in a fresh folder inside
/// DIR. The stand-in records every call's arguments and keeps a "registered" flag, so the check can see what ran:
/// connect runs the expected `mcp add` line (and a second connect runs no second one), an already connected server is
/// found through `mcp get` and, when that answers nothing useful, through `mcp list`, a server whose name only starts
/// with ours is not ours, disconnect runs `mcp remove`, a failing `claude` says why, and a PATH with no `claude`
/// says so. The real `claude` is never run: the lookup path is the stand-in's folder alone, and the login shell is
/// not asked. One `[greenroom] connect: ok|FAIL ...` line per step, then `connect check: PASS|FAIL`; exits 0 or 1.
enum ConnectCheck {
    static func run(dir: URL) -> Never {
        var failures = 0
        func say(_ s: String) { fputs("[greenroom] connect: \(s)\n", stdout); fflush(stdout) }
        func expect(_ ok: Bool, _ what: String, _ got: String = "") {
            if !ok { failures += 1 }
            say((ok ? "ok " : "FAIL ") + what + (ok || got.isEmpty ? "" : " (got: \(got))"))
        }
        let fm = FileManager.default
        let base = dir.resolvingSymlinksInPath().appendingPathComponent("connect-check-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        let empty = base.appendingPathComponent("empty", isDirectory: true)
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        D="$(cd "$(dirname "$0")/.." && pwd)"
        echo "$*" >> "$D/calls.log"
        listed() { if [ -f "$D/registered" ]; then echo "$(cat "$D/registered"): /some/path --mcp - connected"; fi; echo "other: /x - connected"; }
        case "$1 $2" in
          "mcp get")
            if [ -f "$D/get-unsupported" ]; then echo "error: unknown command 'get'" >&2; exit 2; fi
            if [ "$(cat "$D/registered" 2>/dev/null)" = "greenroom" ]; then echo "greenroom:"; echo "  Scope: User config"; exit 0; fi
            echo "No MCP server found with name: greenroom" >&2; exit 1 ;;
          "mcp list") echo "Checking MCP server health..."; listed; exit 0 ;;
          "mcp add")
            if [ -f "$D/fail-add" ]; then echo "error: could not write the configuration: permission denied" >&2; exit 1; fi
            echo greenroom > "$D/registered"; echo "Added stdio MCP server greenroom to user config"; exit 0 ;;
          "mcp remove")
            if [ -f "$D/registered" ]; then rm -f "$D/registered"; echo "Removed MCP server greenroom"; exit 0; fi
            echo "No MCP server found with name: greenroom" >&2; exit 1 ;;
        esac
        echo "unexpected: $*" >&2; exit 3
        """
        let claude = bin.appendingPathComponent("claude")
        try? script.write(to: claude, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let log = base.appendingPathComponent("calls.log")
        func calls() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func flag(_ name: String, _ on: Bool) {
            let f = base.appendingPathComponent(name)
            if on { fm.createFile(atPath: f.path, contents: Data()) } else { try? fm.removeItem(at: f) }
        }
        func registered(as name: String?) {
            let f = base.appendingPathComponent("registered")
            if let name { try? name.write(to: f, atomically: true, encoding: .utf8) } else { try? fm.removeItem(at: f) }
        }

        LoginEnvironment.override = [:]   // the login shell is not asked
        ClaudeConnect.pathOverride = bin.path + ":/usr/bin:/bin"
        ClaudeConnect.timeout = 20
        let exe = ClaudeConnect.executable

        // The command as shown.
        expect(ClaudeConnect.displayCommand() == "claude mcp add --scope user greenroom -- \"\(exe)\" --mcp", "the command shown is claude mcp add --scope user greenroom -- \"<this app>\" --mcp", ClaudeConnect.displayCommand())
        expect(ClaudeConnect.addArguments(executable: exe) == ["mcp", "add", "--scope", "user", "greenroom", "--", exe, "--mcp"], "the arguments are the shown command's")

        // Not connected: connect runs the add line.
        expect(ClaudeConnect.status() == .notConnected, "a server list without greenroom is not connected")
        try? fm.removeItem(at: log)
        let first = ClaudeConnect.connect()
        if case .connected = first {} else { expect(false, "connect on a fresh stand-in connects", "\(first)") }
        expect(calls().contains("mcp add --scope user greenroom -- \(exe) --mcp"), "connect ran claude mcp add --scope user greenroom -- <this app> --mcp", calls().joined(separator: " | "))
        expect(ClaudeConnect.status() == .connected, "after connecting, mcp get names it")

        // Already connected: no second add.
        try? fm.removeItem(at: log)
        let again = ClaudeConnect.connect()
        expect(again == .alreadyConnected, "connecting again says already connected", "\(again)")
        expect(!calls().contains { $0.hasPrefix("mcp add") }, "... and runs no second mcp add", calls().joined(separator: " | "))

        // `get` unsupported: the list names it.
        flag("get-unsupported", true)
        expect(ClaudeConnect.status() == .connected, "with mcp get unusable, mcp list naming greenroom counts as connected")
        expect(ClaudeConnect.connect() == .alreadyConnected, "... and connect says already connected")
        // A server whose name only starts with ours is not ours.
        registered(as: "greenroom-other")
        expect(ClaudeConnect.status() == .notConnected, "a listed server called greenroom-other is not greenroom")
        registered(as: "greenroom")
        flag("get-unsupported", false)

        // Disconnect.
        try? fm.removeItem(at: log)
        let off = ClaudeConnect.disconnect()
        if case .disconnected = off {} else { expect(false, "disconnect removes it", "\(off)") }
        expect(calls().contains("mcp remove --scope user greenroom"), "disconnect ran claude mcp remove --scope user greenroom", calls().joined(separator: " | "))
        expect(ClaudeConnect.status() == .notConnected, "after disconnecting it is not connected")
        expect(ClaudeConnect.disconnect() == .notConnected, "disconnecting when it is not connected says so")

        // A failure says why.
        flag("fail-add", true)
        let bad = ClaudeConnect.connect()
        if case .failed(let why) = bad { expect(why.contains("permission denied") && why.contains("exit 1"), "a failing add reports claude's own words and its exit status", why) }
        else { expect(false, "a failing add is a failure", "\(bad)") }
        flag("fail-add", false)

        // No claude.
        ClaudeConnect.pathOverride = empty.path + ":/usr/bin:/bin"
        expect(ClaudeConnect.status() == .missing, "a PATH with no claude is missing")
        expect(ClaudeConnect.connect() == .missing, "connect says claude was not found")
        expect(ClaudeConnect.connect().message.contains("not found"), "... in words")
        expect(ClaudeConnect.disconnect() == .missing, "so does disconnect")

        if failures == 0 { try? fm.removeItem(at: base) }
        say(failures == 0 ? "done" : "stopped with \(failures) failure(s)")
        print("connect check: " + (failures == 0 ? "PASS" : "FAIL"))
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
