import Foundation

/// `Greenroom --connect-check DIR`: the connectors (Claude Code, Codex, Cursor) against stand-ins, in a fresh folder
/// inside DIR: a `claude` and a `codex` program, a home folder and an applications folder of the check's own. The stand-in records every call's arguments and keeps a "registered" flag, so the check can see what ran:
/// connect runs the expected `mcp add` line (and a second connect runs no second one), an already connected server is
/// found through `mcp get` and, when that answers nothing useful, through `mcp list`, a server whose name only starts
/// with ours is not ours, disconnect runs `mcp remove`, a failing `claude` says why, and a PATH with no `claude`
/// says so. The real `claude` is never run: the lookup path is the stand-in's folder alone, and the login shell is
/// not asked. One `[greenroom] connect: ok|FAIL ...` line per step, then `connect check: PASS|FAIL`; exits 0 or 1.
enum ConnectCheck {
    /// ClaudeConnect never runs on the main thread (it asserts so), so the check runs on a thread of its own.
    static func run(dir: URL) -> Never {
        Thread.detachNewThread { body(dir: dir) }
        dispatchMain()
    }

    /// The stand-ins every connector's check runs against, in BASE: `bin/claude` and `bin/codex`, which record their
    /// arguments (calls.log, codex-calls.log) and keep what was registered in files beside them, a home folder of
    /// its own, and an applications folder with a Cursor.app in it. After this no connector looks at the person's
    /// own programs, files or login shell.
    static func standIns(_ base: URL) {
        let fm = FileManager.default
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try? fm.createDirectory(at: base.appendingPathComponent("home"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: base.appendingPathComponent("apps/Cursor.app"), withIntermediateDirectories: true)
        let N = ClaudeConnect.serverName
        let script = """
        #!/bin/sh
        D="$(cd "$(dirname "$0")/.." && pwd)"
        echo "$*" >> "$D/calls.log"
        listed() { if [ -f "$D/registered" ]; then echo "$(cat "$D/registered"): $(cat "$D/registered-exe") --mcp - connected"; fi; echo "other: /x - connected"; }
        if [ -f "$D/hang" ]; then sleep 30; exit 0; fi
        case "$1 $2" in
          "mcp get")
            if [ -f "$D/get-unsupported" ]; then echo "error: unknown command 'get'" >&2; exit 2; fi
            if [ "$(cat "$D/registered" 2>/dev/null)" = "\(N)" ]; then echo "\(N):"; echo "  Scope: User config"; echo "  Command: $(cat "$D/registered-exe")"; exit 0; fi
            echo "No MCP server named \"\(N)\". Configured servers: other" >&2; exit 1 ;;
          "mcp list") echo "Checking MCP server health..."; listed; exit 0 ;;
          "mcp add")
            if [ -f "$D/fail-add" ]; then echo "error: could not write the configuration: permission denied" >&2; exit 1; fi
            echo \(N) > "$D/registered"; echo "$7" > "$D/registered-exe"; echo "Added stdio MCP server \(N) to user config"; exit 0 ;;
          "plugin list")
            echo "Installed plugins:"; echo; echo "  > other@market"; echo "    Status: enabled"; echo
            if [ -f "$D/plugin" ]; then echo "  > greenroom@greenroom"; echo "    Version: 1"; echo "    Scope: user"; echo "    Status: $(cat "$D/plugin")"; echo; fi
            exit 0 ;;
          "mcp remove")
            if [ -f "$D/registered" ]; then rm -f "$D/registered"; echo "Removed MCP server \(N)"; exit 0; fi
            echo "No MCP server named \"\(N)\". Configured servers: other" >&2; exit 1 ;;
        esac
        echo "unexpected: $*" >&2; exit 3
        """
        let codex = """
        #!/bin/sh
        D="$(cd "$(dirname "$0")/.." && pwd)"
        echo "$*" >> "$D/codex-calls.log"
        case "$1 $2" in
          "mcp get")
            if [ ! -f "$D/codex-exe" ]; then echo "Error: No MCP server named '$3' found." >&2; exit 1; fi
            if [ "$4" = "--json" ]; then
              if [ -f "$D/codex-no-json" ]; then echo "error: unexpected argument '--json' found" >&2; exit 2; fi
              printf '{"name":"%s","enabled":true,"transport":{"type":"stdio","command":"%s","args":["--mcp"],"env":null}}\\n' "$3" "$(cat "$D/codex-exe")"
            else echo "$3"; echo "  transport: stdio"; echo "  command: $(cat "$D/codex-exe")"; echo "  args: --mcp"; fi
            exit 0 ;;
          "mcp add")
            if [ -f "$D/codex-fail-add" ]; then echo "error: the configuration is read-only" >&2; exit 1; fi
            echo "$5" > "$D/codex-exe"; echo "Added global MCP server '$3'."; exit 0 ;;
          "mcp remove") rm -f "$D/codex-exe"; echo "Removed global MCP server '$3'."; exit 0 ;;
        esac
        echo "unexpected: $*" >&2; exit 3
        """
        for (name, text) in [("claude", script), ("codex", codex)] {
            let f = bin.appendingPathComponent(name)
            try? text.write(to: f, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        LoginEnvironment.override = [:]   // the login shell is not asked
        ClaudeConnect.pathOverride = bin.path + ":/usr/bin:/bin"
        Harnesses.home = base.appendingPathComponent("home")
        Harnesses.appFolders = [base.appendingPathComponent("apps")]
    }

    private static func body(dir: URL) -> Never {
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
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        standIns(base)
        let N = ClaudeConnect.serverName   // "greenroom", or the debug copy's "greenroom-debug"
        ClaudeConnect.repositoryOnlyOverride = false   // the Debug copy's own rule has its cases further down
        let log = base.appendingPathComponent("calls.log")
        func calls() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func flag(_ name: String, _ on: Bool) {
            let f = base.appendingPathComponent(name)
            if on { fm.createFile(atPath: f.path, contents: Data()) } else { try? fm.removeItem(at: f) }
        }
        func registered(as name: String?, exe: String = ClaudeConnect.executable) {
            let f = base.appendingPathComponent("registered")
            if let name { try? name.write(to: f, atomically: true, encoding: .utf8); try? exe.write(to: base.appendingPathComponent("registered-exe"), atomically: true, encoding: .utf8) }
            else { try? fm.removeItem(at: f) }
        }

        ClaudeConnect.timeout = 20
        let exe = ClaudeConnect.executable

        // The command as shown.
        expect(ClaudeConnect.displayCommand() == "claude mcp add --scope user \(N) -- \"\(exe)\" --mcp", "the command shown is claude mcp add --scope user \(N) -- \"<this app>\" --mcp", ClaudeConnect.displayCommand())
        expect(ClaudeConnect.addArguments(executable: exe) == ["mcp", "add", "--scope", "user", "\(N)", "--", exe, "--mcp"], "the arguments are the shown command's")

        // Not connected: connect runs the add line.
        expect(ClaudeConnect.status() == .notConnected, "a server list without \(N) is not connected")
        try? fm.removeItem(at: log)
        let first = ClaudeConnect.connect()
        if case .connected = first {} else { expect(false, "connect on a fresh stand-in connects", "\(first)") }
        expect(calls().contains("mcp add --scope user \(N) -- \(exe) --mcp"), "connect ran claude mcp add --scope user \(N) -- <this app> --mcp", calls().joined(separator: " | "))
        expect(ClaudeConnect.status() == .connected, "after connecting, mcp get names it")

        // Already connected: no second add.
        try? fm.removeItem(at: log)
        let again = ClaudeConnect.connect()
        expect(again == .alreadyConnected, "connecting again says already connected", "\(again)")
        expect(!calls().contains { $0.hasPrefix("mcp add") }, "... and runs no second mcp add", calls().joined(separator: " | "))

        // `get` unsupported: the list names it.
        flag("get-unsupported", true)
        expect(ClaudeConnect.status() == .connected, "with mcp get unusable, mcp list naming \(N) counts as connected")
        expect(ClaudeConnect.connect() == .alreadyConnected, "... and connect says already connected")
        // A server whose name only starts with ours is not ours.
        registered(as: "\(N)-other")
        expect(ClaudeConnect.status() == .notConnected, "a listed server called \(N)-other is not \(N)")
        registered(as: "\(N)")
        flag("get-unsupported", false)

        // An entry that runs another copy is not this one: Reconnect removes it and adds this.
        registered(as: "\(N)", exe: "/Applications/Other.app/Contents/MacOS/Greenroom")
        let other = ClaudeConnect.status()
        expect(other == .otherCopy("/Applications/Other.app/Contents/MacOS/Greenroom"), "a \(N) entry running another program is connected to another copy", "\(other)")
        try? fm.removeItem(at: log)
        expect(ClaudeConnect.connect() == .otherCopy("/Applications/Other.app/Contents/MacOS/Greenroom"), "connect does not overwrite it by itself")
        expect(!calls().contains { $0.hasPrefix("mcp add") || $0.hasPrefix("mcp remove") }, "... and runs no add or remove", calls().joined(separator: " | "))
        flag("get-unsupported", true)
        expect(ClaudeConnect.status() == .otherCopy("/Applications/Other.app/Contents/MacOS/Greenroom"), "the same through mcp list when get is unusable")
        flag("get-unsupported", false)
        try? fm.removeItem(at: log)
        let re = ClaudeConnect.reconnect()
        if case .connected = re {} else { expect(false, "reconnect connects", "\(re)") }
        let seq = calls().filter { $0.hasPrefix("mcp remove") || $0.hasPrefix("mcp add") }
        expect(seq == ["mcp remove --scope user \(N)", "mcp add --scope user \(N) -- \(exe) --mcp"], "reconnect runs remove, then add", seq.joined(separator: " | "))
        expect(ClaudeConnect.status() == .connected, "and the entry then runs this copy")
        // The whole command is compared, not a piece of it: a longer path that contains this one, or a name that only starts with it.
        for lookalike in ["/Users/me" + ClaudeConnect.executable, ClaudeConnect.executable + "2"] {
            registered(as: "\(N)", exe: lookalike)
            let st = ClaudeConnect.status()
            expect(st == .otherCopy(lookalike), "a command that only contains this program's path is another copy (\(lookalike.suffix(24)))", "\(st)")
        }
        // A path with a space is read whole, through get and through list.
        ClaudeConnect.executableOverride = "/tmp/Green room/Greenroom"
        registered(as: "\(N)", exe: "/tmp/Green room/Greenroom")
        expect(ClaudeConnect.status() == .connected, "a program path with a space is this copy (get)")
        flag("get-unsupported", true)
        expect(ClaudeConnect.status() == .connected, "... and through list")
        registered(as: "\(N)", exe: "/tmp/Green room/Other")
        expect(ClaudeConnect.status() == .otherCopy("/tmp/Green room/Other"), "a different path with the same first word is another copy, named whole")
        flag("get-unsupported", false)
        ClaudeConnect.executableOverride = nil
        registered(as: "\(N)")
        // A copy macOS runs from App Translocation is never registered.
        registered(as: nil)
        ClaudeConnect.executableOverride = "/private/var/folders/ab/xyz/T/AppTranslocation/ABC/d/Greenroom.app/Contents/MacOS/Greenroom"
        try? fm.removeItem(at: log)
        let moved = ClaudeConnect.connect()
        if case .failed(let why) = moved { expect(why.contains("Applications") && !calls().contains { $0.hasPrefix("mcp add") }, "an App Translocation path is refused with a move-to-Applications message and no add", why) }
        else { expect(false, "an App Translocation path is refused", "\(moved)") }
        expect(ClaudeConnect.reconnect().message.contains("Applications"), "so is a reconnect")
        ClaudeConnect.executableOverride = nil
        registered(as: "\(N)", exe: "/Applications/Other.app/Contents/MacOS/Greenroom")
        // Reconnect says what happened at each step: a failing add after the remove, and a remove that finds nothing.
        flag("fail-add", true)
        let half = ClaudeConnect.reconnect()
        if case .failed(let why) = half { expect(why.contains("removed") && why.contains("none") && why.contains("permission denied"), "reconnect with a failing add says the old entry is gone and why", why) }
        else { expect(false, "reconnect with a failing add fails", "\(half)") }
        flag("fail-add", false)
        let noEntry = ClaudeConnect.reconnect()
        if case .failed(let why) = noEntry { expect(why.contains("nothing was added"), "reconnect with no entry to remove says nothing was added", why) }
        else { expect(false, "reconnect with no entry fails", "\(noEntry)") }
        registered(as: "\(N)")
        // `get` saying there is no such server is final: no mcp list after it.
        registered(as: nil)
        try? fm.removeItem(at: log)
        expect(ClaudeConnect.status() == .notConnected, "no such server")
        expect(!calls().contains { $0.hasPrefix("mcp list") }, "... without asking mcp list", calls().joined(separator: " | "))
        registered(as: "\(N)")

        // Disconnect.
        try? fm.removeItem(at: log)
        let off = ClaudeConnect.disconnect()
        if case .disconnected = off {} else { expect(false, "disconnect removes it", "\(off)") }
        expect(calls().contains("mcp remove --scope user \(N)"), "disconnect ran claude mcp remove --scope user \(N)", calls().joined(separator: " | "))
        expect(ClaudeConnect.status() == .notConnected, "after disconnecting it is not connected")
        expect(ClaudeConnect.disconnect() == .notConnected, "disconnecting when it is not connected says so")

        // A failure says why.
        flag("fail-add", true)
        let bad = ClaudeConnect.connect()
        if case .failed(let why) = bad { expect(why.contains("permission denied") && why.contains("exit 1"), "a failing add reports claude's own words and its exit status", why) }
        else { expect(false, "a failing add is a failure", "\(bad)") }
        flag("fail-add", false)

        // A claude that hangs: every call answers at the deadline, the process ended.
        flag("hang", true)
        ClaudeConnect.timeout = 2
        let t0 = Date()
        let hung = ClaudeConnect.connect()
        let took = Date().timeIntervalSince(t0)
        if case .failed(let why) = hung { expect(why.contains("timed out") && took < 15, "a hanging claude is stopped at its deadline and said so (\(String(format: "%.1f", took)) s)", why) }
        else { expect(took < 15 && hung != .alreadyConnected, "a hanging claude is stopped at its deadline", "\(hung) after \(took) s") }
        expect(ClaudeConnect.disconnect().message.contains("timed out"), "disconnect says it timed out too")
        flag("hang", false)
        ClaudeConnect.timeout = 20

        // No claude.
        ClaudeConnect.pathOverride = empty.path + ":/usr/bin:/bin"
        expect(ClaudeConnect.status() == .missing, "a PATH with no claude is missing")
        expect(ClaudeConnect.connect() == .missing, "connect says claude was not found")
        expect(ClaudeConnect.connect().message.contains("not found"), "... in words")
        expect(ClaudeConnect.disconnect() == .missing, "so does disconnect")

        // What the agent's recording stores of a call: shapes, never content.
        func shape(_ tool: String, _ args: [String: Any]) -> String { AgentRecording.shape(tool: tool, args: args) }
        expect(shape("set", ["setting": "appearance", "value": "dark"]) == "set: appearance", "a known setting is named, never its value")
        expect(shape("set", ["setting": "hunter2-SECRET"]) == "set: a setting", "an unknown setting name is not stored")
        expect(AgentTools.validLocation("37.7749 -122.4194") && AgentTools.validLocation("drive") && AgentTools.validLocation("none"),
               "set location takes a latitude and longitude, a route, or none")
        expect(!AgentTools.validLocation("91 0") && !AgentTools.validLocation("0 181") && !AgentTools.validLocation("walk"),
               "set location refuses a place off the globe and an unknown route")
        let asked = "[apksim] permission request waiting: ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION (answer with the control command `permission allow` or `permission deny`)"
        expect(Simulator.permissionChange(asked) == .some(["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION"]), "a waiting permission request is read with its names")
        expect(Simulator.permissionChange("[apksim] permission allowed: CAMERA") == .some(nil) && Simulator.permissionChange("[apksim] permission denied: CAMERA") == .some(nil),
               "an answered permission request clears the prompt")
        expect(Simulator.permissionChange("[apksim] permission  something else") == nil, "other engine lines leave the prompt as it is")
        let unmappable = "java.lang.UnsatisfiedLinkError: lib/arm64-v8a/libevent_extra-2.1.so is 4 KB aligned and its writable data at 0x1f000 shares a 16 KB page with its code, which macOS cannot map (no page is writable and executable at once). Rebuild it for 16 KB pages (NDK r27 or later, or -Wl,-z,max-page-size=16384), or launch with --move-shared-data to have apksim move the data (experimental)"
        expect(Simulator.asksToMoveSharedData(unmappable) && !Simulator.asksToMoveSharedData("[apksim] exit 10: the app crashed (FATAL EXCEPTION above)"),
               "the engine's advice to launch with --move-shared-data is recognised, other lines are not")
        expect(Simulator.permissionPhrase(["ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION"]) == "location"
               && Simulator.permissionPhrase(["CAMERA", "RECORD_AUDIO"]) == "camera and microphone", "a permission request reads as what it is for")
        expect(shape("swipe", ["direction": "up"]) == "swipe: up" && shape("swipe", ["direction": "SECRET"]) == "swipe: by points", "a swipe stores only a real direction")
        expect(shape("open_url", ["url": "myapp://reset?token=SECRET#x"]) == "open_url: myapp", "an app's own link is stored as its scheme alone", shape("open_url", ["url": "myapp://reset?token=SECRET#x"]))
        let web = shape("open_url", ["url": "https://example.com/docs/0123456789abcdef0123456789abcdef/page?q=SECRET#frag"])
        expect(web == "open_url: https://example.com/docs/…/page", "a web link keeps host and path, token-like segments become an ellipsis, no query or fragment", web)
        expect(shape("type", ["text": "hunter2"]) == "type: typed 7 characters", "typing stores only a count")
        expect(shape("tap", ["text": "Sign in"]) == "tap: text of 7 characters", "a tap stores only the text's length")

        // --- The other ways in (docs/AGENT-FIRST-SPEC.md, "Installing, per harness") ---
        ClaudeConnect.pathOverride = bin.path + ":/usr/bin:/bin"
        registered(as: nil)

        // Claude Code's plugin counts as connected, and connecting on top of it is not offered.
        func plugin(_ status: String?) {
            let f = base.appendingPathComponent("plugin")
            if let status { try? status.write(to: f, atomically: true, encoding: .utf8) } else { try? fm.removeItem(at: f) }
        }
        expect(!ClaudeConnect.pluginInstalled() && Harnesses.claude.status() == .notConnected, "with no entry and no plugin, Claude Code is not connected")
        plugin("✔ enabled")
        expect(ClaudeConnect.pluginInstalled() && Harnesses.claude.status() == .connected("through the plugin"), "the plugin, enabled, is a connection", "\(Harnesses.claude.status())")
        plugin("✘ disabled")
        expect(!ClaudeConnect.pluginInstalled() && Harnesses.claude.status() == .notConnected, "a disabled plugin is not")
        plugin("✔ enabled")
        registered(as: "\(N)")
        if case .connected(let how) = Harnesses.claude.status() { expect(how.contains("twice"), "an entry and the plugin together are said to list the tools twice", how) }
        else { expect(false, "an entry and the plugin together are connected") }
        registered(as: "\(N)", exe: "/Applications/Other.app/Contents/MacOS/Greenroom")
        if case .connected(let how) = Harnesses.claude.status() { expect(how.contains("plugin") && how.contains("/Applications/Other.app"), "the plugin with an entry for another copy names that copy", how) }
        else { expect(false, "the plugin with an entry for another copy is connected") }
        plugin(nil)
        registered(as: nil)

        // The Debug copy is never added for every project: its repository's .mcp.json registers it.
        ClaudeConnect.repositoryOnlyOverride = true
        try? fm.removeItem(at: log)
        expect(ClaudeConnect.connect() == .repositoryOnly && ClaudeConnect.reconnect() == .repositoryOnly, "the Debug copy's connect adds nothing")
        expect(!calls().contains { $0.hasPrefix("mcp add") }, "... it runs no claude mcp add", calls().joined(separator: " | "))
        expect(ClaudeConnect.connect().message.contains(".mcp.json"), "... and says the repository registers it")
        plugin("✔ enabled")
        expect(!ClaudeConnect.pluginInstalled(), "the plugin, which starts the release copy, is not the Debug copy's connection")
        plugin(nil)
        registered(as: "\(N)")
        expect(ClaudeConnect.status() == .connected, "an entry for every project left by an earlier build is seen")
        if case .disconnected = ClaudeConnect.disconnect() {} else { expect(false, "... and can be removed") }
        expect(calls().contains("mcp remove --scope user \(N)") && ClaudeConnect.status() == .notConnected, "removing it runs claude mcp remove --scope user \(N)", calls().joined(separator: " | "))
        ClaudeConnect.repositoryOnlyOverride = false
        expect(AgentTools.instructions(debug: false) == AgentTools.releaseInstructions && AgentTools.releaseInstructions.hasPrefix("Drives Android apps in Greenroom"),
               "the release copy's instructions are as they were")
        let debugWords = AgentTools.instructions(debug: true)
        expect(debugWords.hasPrefix("This is Greenroom Debug") && debugWords.hasSuffix(AgentTools.releaseInstructions) && debugWords.count < 4096,
               "the Debug copy's instructions open by saying what it is, then say the same (\(debugWords.count) characters)")
        expect(AgentTools.instructions == AgentTools.instructions(debug: Variant.isDebug), "this copy sends its own variant's instructions")

        // Codex: its own command.
        let codexLog = base.appendingPathComponent("codex-calls.log")
        func codexCalls() -> [String] { ((try? String(contentsOf: codexLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func codexRegistered(_ exe: String?) {
            let f = base.appendingPathComponent("codex-exe")
            if let exe { try? exe.write(to: f, atomically: true, encoding: .utf8) } else { try? fm.removeItem(at: f) }
        }
        expect(CodexConnect.displayCommand() == "codex mcp add \(N) -- \"\(exe)\" --mcp", "Codex's command as shown", CodexConnect.displayCommand())
        expect(CodexConnect.status() == .notConnected, "a Codex without the server is not connected", "\(CodexConnect.status())")
        let cx = CodexConnect.connect()
        expect(cx.ok && cx.message.hasPrefix("Connected"), "connecting Codex connects", cx.message)
        expect(codexCalls().contains("mcp add \(N) -- \(exe) --mcp"), "... by codex mcp add \(N) -- <this app> --mcp", codexCalls().joined(separator: " | "))
        expect(CodexConnect.status() == .connected("as MCP server \(N)"), "... and codex mcp get then names this copy", "\(CodexConnect.status())")
        try? fm.removeItem(at: codexLog)
        expect(CodexConnect.connect().message.hasPrefix("Already connected") && !codexCalls().contains { $0.hasPrefix("mcp add") }, "connecting again adds nothing")
        flag("codex-no-json", true)
        expect(CodexConnect.status() == .connected("as MCP server \(N)"), "a Codex whose get has no --json is read from its plain answer", "\(CodexConnect.status())")
        flag("codex-no-json", false)
        codexRegistered("/Applications/Other.app/Contents/MacOS/Greenroom")
        expect(CodexConnect.status() == .otherCopy("/Applications/Other.app/Contents/MacOS/Greenroom"), "an entry running another program is another copy", "\(CodexConnect.status())")
        try? fm.removeItem(at: codexLog)
        expect(CodexConnect.connect().ok && !codexCalls().contains { $0.hasPrefix("mcp add") || $0.hasPrefix("mcp remove") }, "connect does not overwrite it by itself")
        let cxRe = CodexConnect.replace()
        expect(cxRe.ok && codexCalls().filter { $0.hasPrefix("mcp remove") || $0.hasPrefix("mcp add") } == ["mcp remove \(N)", "mcp add \(N) -- \(exe) --mcp"], "reconnect runs remove, then add", cxRe.message)
        expect(CodexConnect.disconnect().ok && CodexConnect.status() == .notConnected, "disconnect runs codex mcp remove")
        flag("codex-fail-add", true)
        let cxBad = CodexConnect.connect()
        expect(!cxBad.ok && cxBad.message.contains("read-only") && cxBad.message.contains("exit 1"), "a failing add reports codex's own words", cxBad.message)
        flag("codex-fail-add", false)

        // Cursor: the one file that is written. Other entries and other keys stay.
        let cursorFile = CursorConnect.file
        expect(cursorFile.path.hasPrefix(base.path), "the check writes Cursor's file in a home of its own", cursorFile.path)
        func cursorJSON() -> [String: Any] { ((try? Data(contentsOf: cursorFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
        func cursorServers() -> [String: Any] { cursorJSON()["mcpServers"] as? [String: Any] ?? [:] }
        Harnesses.appFolders = [empty]
        expect(CursorConnect.status() == .notInstalled && !CursorConnect.connect().ok && !fm.fileExists(atPath: cursorFile.path), "with no Cursor on this Mac nothing is written")
        Harnesses.appFolders = [base.appendingPathComponent("apps")]
        expect(CursorConnect.status() == .notConnected, "a Cursor with no mcp.json is not connected")
        let cu = CursorConnect.connect()
        expect(cu.ok && CursorConnect.status() == .connected("in ~/.cursor/mcp.json"), "connecting Cursor writes the entry", cu.message)
        expect((cursorServers()[N] as? [String: Any])?["command"] as? String == exe && (cursorServers()[N] as? [String: Any])?["args"] as? [String] == ["--mcp"], "... with this app as its command and --mcp", "\(cursorServers())")
        try? fm.createDirectory(at: cursorFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? #"{"mcpServers": {"other": {"url": "https://example.com/mcp"}, "\#(N)": {"command": "/Applications/Other.app/Contents/MacOS/Greenroom", "args": ["--mcp"]}}, "theirs": 7}"#.write(to: cursorFile, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cursorFile.path)
        expect(CursorConnect.status() == .otherCopy("/Applications/Other.app/Contents/MacOS/Greenroom"), "an entry running another program is another copy", "\(CursorConnect.status())")
        expect(CursorConnect.connect().ok && CursorConnect.status().isConnected, "reconnect points the entry at this copy")
        expect((cursorServers()["other"] as? [String: Any])?["url"] as? String == "https://example.com/mcp" && cursorJSON()["theirs"] as? Int == 7, "the other entries and keys are kept", "\(cursorJSON())")
        expect(((try? fm.attributesOfItem(atPath: cursorFile.path))?[.posixPermissions] as? NSNumber)?.intValue == 0o600, "... and the file keeps its permissions")
        expect(CursorConnect.disconnect().ok && cursorServers()[N] == nil && cursorServers()["other"] != nil && CursorConnect.status() == .notConnected, "disconnect takes out this entry alone", "\(cursorServers())")
        let commented = "{\n  // my servers\n  \"mcpServers\": {}\n}\n"
        try? commented.write(to: cursorFile, atomically: true, encoding: .utf8)
        if case .unknown = CursorConnect.status() {} else { expect(false, "a file that is not plain JSON is not read as empty", "\(CursorConnect.status())") }
        expect(!CursorConnect.connect().ok && !CursorConnect.disconnect().ok && (try? String(contentsOf: cursorFile, encoding: .utf8)) == commented, "... and is left exactly as it is")
        try? fm.removeItem(at: cursorFile)

        // The screen's one button connects what is ticked, found and not connected, and nothing else.
        func onMain<T>(_ work: () -> T) -> T { DispatchQueue.main.sync(execute: work) }
        func wait(_ start: (@escaping () -> Void) -> Void) { let done = DispatchSemaphore(value: 0); onMain { start { done.signal() } }; done.wait() }
        let model = ConnectModel.shared
        ConnectModel.lookups = true
        plugin("✔ enabled")
        wait { model.refresh(then: $0) }
        expect(onMain { model.pending.map(\.id) } == ["codex", "cursor"] && onMain { model.connectedNames } == ["Claude Code"], "the screen offers to connect Codex and Cursor, and Claude Code is connected through the plugin", "\(onMain { model.rows.map { "\($0.id): \(String(describing: $0.link))" } })")
        onMain { model.toggle("cursor") }
        try? fm.removeItem(at: log); try? fm.removeItem(at: codexLog)
        wait { model.connectTicked(then: $0) }
        expect(onMain { model.connectedNames } == ["Claude Code", "Codex"] && !fm.fileExists(atPath: cursorFile.path) && !calls().contains { $0.hasPrefix("mcp add") },
               "the one button connects the ticked harness alone: Codex, not the unticked Cursor, and nothing more for Claude Code", "\(onMain { model.connectedNames })")
        onMain { model.toggle("cursor") }
        wait { model.connectTicked(then: $0) }
        expect(onMain { model.connectedNames } == ["Claude Code", "Codex", "Cursor"] && onMain { model.pending.isEmpty }, "ticked again, Cursor is connected too", "\(onMain { model.connectedNames })")
        expect(WaitingStage.statusText(client: nil, listening: true, connected: onMain { model.connectedNames }) == "Listening · Claude Code, Codex and Cursor connected", "the waiting stage names what is connected")
        ClaudeConnect.repositoryOnlyOverride = true
        expect(onMain { model.pending.isEmpty && model.connectedNames.isEmpty }, "the Debug copy's screen offers no harness to connect")
        registered(as: "\(N)")
        wait { model.refresh(then: $0) }
        expect(onMain { model.debugEntry } == .connected, "the Debug copy's screen sees its entry for every project")
        wait { model.removeDebugEntry(then: $0) }
        expect(onMain { model.debugEntry } == .notConnected && calls().contains("mcp remove --scope user \(N)"), "... and Remove It runs claude mcp remove --scope user \(N)")
        ClaudeConnect.repositoryOnlyOverride = false
        ConnectModel.lookups = false
        expect(ConnectModel.displayName(client: "claude-code") == "Claude Code" && ConnectModel.displayName(client: "codex-mcp-client") == "Codex" && ConnectModel.displayName(client: "my-agent") == "my-agent",
               "an MCP client's name reads as the harness the person knows")

        if failures == 0 { try? fm.removeItem(at: base) }
        say(failures == 0 ? "done" : "stopped with \(failures) failure(s)")
        print("connect check: " + (failures == 0 ? "PASS" : "FAIL"))
        fflush(stdout)
        exit(failures == 0 ? 0 : 1)
    }
}
