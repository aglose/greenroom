import Foundation

/// The hooks' cases of `Greenroom --connect-check DIR` (docs/AGENT-FIRST-SPEC.md, A4), run at its end against the
/// same stand-ins: a home folder of its own and stand-in `claude` and `codex`. Three parts: a JSON file changed in
/// one place and nowhere else (OrderedJSONFile), Greenroom's hooks put into and taken out of each harness's file
/// (Hooks, Harnesses.settleHooks), and what the hooks say turned into sessions (HookSessions).
///
/// Never the person's own files: every path is under BASE.
enum HooksCheck {
    static func cases(base: URL, check: (Bool, String, String) -> Void) {
        func expect(_ ok: Bool, _ what: String, _ got: String = "") { check(ok, what, got) }
        let fm = FileManager.default
        let home = base.appendingPathComponent("home")
        let N = ClaudeConnect.serverName
        let exe = ClaudeConnect.executable
        func read(_ f: URL) -> String { (try? String(contentsOf: f, encoding: .utf8)) ?? "" }
        func write(_ text: String, _ f: URL) {
            try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: f, atomically: true, encoding: .utf8)
        }
        func json(_ f: URL) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any] }
        /// Every command in a hooks file, by event.
        func commands(_ f: URL, flat: Bool) -> [String: [String]] {
            var out: [String: [String]] = [:]
            for (event, list) in (json(f)?["hooks"] as? [String: Any]) ?? [:] {
                for entry in (list as? [[String: Any]]) ?? [] {
                    let handlers = flat ? [entry] : (entry["hooks"] as? [[String: Any]]) ?? []
                    out[event, default: []] += handlers.compactMap { $0["command"] as? String }
                }
            }
            return out
        }
        func plugin(_ status: String?) {
            let f = base.appendingPathComponent("plugin")
            if let status { write(status, f) } else { try? fm.removeItem(at: f) }
        }
        func registered(_ on: Bool) {
            if on { write(N, base.appendingPathComponent("registered")); write(exe, base.appendingPathComponent("registered-exe")) }
            else { try? fm.removeItem(at: base.appendingPathComponent("registered")) }
        }
        func codexAdded(_ on: Bool) {
            if on { write(exe, base.appendingPathComponent("codex-exe")) } else { try? fm.removeItem(at: base.appendingPathComponent("codex-exe")) }
        }
        let claude = Hooks.Place.claude, codex = Hooks.Place.codex, cursor = Hooks.Place.cursor
        for place in Hooks.Place.all { try? fm.removeItem(at: place.file) }
        try? fm.removeItem(at: home.appendingPathComponent(".claude/plugins"))
        expect(claude.file.path == home.path + "/.claude/settings.json" && codex.file.path == home.path + "/.codex/hooks.json" && cursor.file.path == home.path + "/.cursor/hooks.json",
               "the check's hooks files are in a home of its own", claude.file.path)

        // --- One member of a JSON file changed, the rest left byte for byte ---
        let odd = "{\n    \"model\": \"opus\",\n\t\"note\": \"a \\\"quoted\\\" } brace, é\",\n    \"hooks\": {\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"x\"}]}]},\n    \"list\": [1, 2,   3],\n    \"deep\": {\"a\": {\"b\": [true, null, 1.5e3]}}\n}\n"
        if var file = OrderedJSONFile(Data(odd.utf8)) {
            expect(file.members.map(\.key) == ["model", "note", "hooks", "list", "deep"], "a file's members are read in their order", "\(file.members.map(\.key))")
            let before = odd.range(of: "\"hooks\": ")!.upperBound, after = odd.range(of: ",\n    \"list\"")!.lowerBound
            file.set("hooks", .object([("Stop", .array([.object([("command", .string("y"))])]))]))
            let now = String(decoding: file.data, as: UTF8.self)
            expect(now.hasPrefix(String(odd[..<before])) && now.hasSuffix(String(odd[after...])), "replacing one member's value leaves every other byte of the file", now)
            expect((json2(now)?["hooks"] as? [String: Any])?["Stop"] != nil && (json2(now)?["note"] as? String) == "a \"quoted\" } brace, é", "... and the file is still JSON, saying the same elsewhere")
            file.set("hooks", nil)
            let gone = String(decoding: file.data, as: UTF8.self)
            expect(gone == odd.replacingOccurrences(of: ",\n    \"hooks\": {\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"x\"}]}]}", with: ""), "taking a member out leaves the file as if it was never there", gone)
            file.set("added", .string("z"))
            let added = String(decoding: file.data, as: UTF8.self)
            expect(added.hasSuffix("\"deep\": {\"a\": {\"b\": [true, null, 1.5e3]}},\n    \"added\": \"z\"\n}\n"), "a new member goes after the last one, indented as the file is", added)
        } else { expect(false, "a JSON object is read", "") }
        var one = OrderedJSONFile(Data("{\"only\": 1}".utf8))
        one?.set("only", nil)
        expect(one.map { String(decoding: $0.data, as: UTF8.self) } == "{}", "the only member taken out leaves an empty object", one.map { String(decoding: $0.data, as: UTF8.self) } ?? "nil")
        var first = OrderedJSONFile(Data("{\n  \"a\": 1,\n  \"b\": 2\n}".utf8))
        first?.set("a", nil)
        expect(first.map { String(decoding: $0.data, as: UTF8.self) } == "{\n  \"b\": 2\n}", "the first member taken out leaves the second in its place", first.map { String(decoding: $0.data, as: UTF8.self) } ?? "nil")
        var blank = OrderedJSONFile()
        blank.set("hooks", .object([]))
        expect(String(decoding: blank.data, as: UTF8.self) == "{\n  \"hooks\": {}\n}\n", "a member added to an empty object", String(decoding: blank.data, as: UTF8.self))
        expect(OrderedJSONFile(Data("[1]".utf8)) == nil && OrderedJSONFile(Data("{\"a\": 1, // no\n}".utf8)) == nil && OrderedJSONFile(Data("{\"a\": 1,}".utf8)) == nil,
               "a list, a comment or a trailing comma is not a file this changes")

        // --- Greenroom's hooks in each harness's file ---
        // The command: this copy's own program, the same line from one version to the next.
        let stop = Hooks.command(Hooks.Spec(event: "Stop"), harness: "codex")
        expect(stop == "\"\(exe)\" --cli hook Stop --harness codex" && Hooks.program(of: stop) == exe, "a hook runs \"<this app>\" --cli hook EVENT --harness NAME", stop)
        expect(Hooks.program(of: "'/Users/x/.codex/hooks/allow-sleep.sh'") == nil && Hooks.program(of: "\"/Applications/Greenroom.app/Contents/MacOS/Greenroom\" --cli hook Stop --harness codex; rm -rf /") == nil
               && Hooks.program(of: "\"/Applications/Greenroom Debug.app/Contents/MacOS/Greenroom Debug\" --cli hook stop --harness cursor") != nil,
               "only a line that is exactly that is taken for Greenroom's")

        // Codex: beside the person's own hooks, which stay as they are.
        let theirs = "{\n  \"hooks\": {\n    \"UserPromptSubmit\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"'/Users/x/.codex/hooks/prevent-sleep.sh'\"\n          }\n        ]\n      }\n    ],\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"'/Users/x/.codex/hooks/allow-sleep.sh'\",\n            \"timeout\": 5\n          }\n        ]\n      }\n    ]\n  }\n}\n"
        write(theirs, codex.file)
        expect(Hooks.state(codex) == .none, "a hooks file with only the person's hooks has none of Greenroom's")
        let put = Hooks.install(codex)
        var got = commands(codex.file, flat: false)
        expect(put.ok && put.message.contains("~/.codex/hooks.json") && put.message.contains("/hooks") && Hooks.state(codex) == .ours(current: true), "Codex's hooks are written, and the person is told to trust them", put.message)
        expect(got["Stop"] == ["'/Users/x/.codex/hooks/allow-sleep.sh'", "\"\(exe)\" --cli hook Stop --harness codex"]
               && got["UserPromptSubmit"] == ["'/Users/x/.codex/hooks/prevent-sleep.sh'", "\"\(exe)\" --cli hook UserPromptSubmit --harness codex"],
               "... after the person's own, which still run first", "\(got)")
        expect(Set(got.keys) == ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop"], "... for the five events Codex's status needs", "\(got.keys.sorted())")
        expect(read(codex.file).contains("\"command\": \"'/Users/x/.codex/hooks/allow-sleep.sh'\",\n            \"timeout\": 5"), "... and their own entry keeps what else it said")
        let written = read(codex.file)
        expect(Hooks.install(codex) == Hooks.Result(ok: true, message: "") && read(codex.file) == written, "writing them again changes nothing, so Codex is not asked to trust them twice")
        // Another copy's are replaced, not added to.
        write(written.replacingOccurrences(of: exe, with: "/Applications/Other/Greenroom.app/Contents/MacOS/Greenroom"), codex.file)
        expect(Hooks.state(codex) == .otherCopy("/Applications/Other/Greenroom.app/Contents/MacOS/Greenroom"), "hooks that run another copy of Greenroom are seen as that", "\(Hooks.state(codex))")
        expect(Hooks.remove(codex).message.isEmpty && Hooks.state(codex) != .none, "... and are not this copy's to take out")
        expect(Hooks.install(codex).ok && read(codex.file) == written, "... and writing replaces them with this copy's, one of each")
        // An earlier Greenroom's set (an event since dropped) is brought up to date.
        write(written.replacingOccurrences(of: "hook PostToolUse --harness", with: "hook PreToolUse --harness"), codex.file)
        expect(Hooks.state(codex) == .ours(current: false), "a set that is not what this version writes is seen as an earlier one", "\(Hooks.state(codex))")
        expect(Hooks.install(codex).ok && read(codex.file) == written, "... and is brought up to date")
        // Taken out: the file is the person's again, byte for byte where it matters.
        let off = Hooks.remove(codex)
        got = commands(codex.file, flat: false)
        expect(off.ok && off.message.contains("removed") && Hooks.state(codex) == .none && got == ["Stop": ["'/Users/x/.codex/hooks/allow-sleep.sh'"], "UserPromptSubmit": ["'/Users/x/.codex/hooks/prevent-sleep.sh'"]],
               "taken out, the person's hooks are what is left", "\(got)")
        expect(read(codex.file).contains("\"timeout\": 5") && json(codex.file) != nil, "... in a file that is still JSON")
        try? fm.removeItem(at: codex.file)
        expect(Hooks.install(codex).ok && Hooks.remove(codex).ok && !fm.fileExists(atPath: codex.file.path), "a file Greenroom made goes when its hooks do")

        // Cursor: a flat list for each event, and a version.
        expect(Hooks.install(cursor).ok && (json(cursor.file)?["version"] as? Int) == 1, "Cursor's hooks file is made with its version")
        got = commands(cursor.file, flat: true)
        expect(got["stop"] == ["\"\(exe)\" --cli hook stop --harness cursor"] && Set(got.keys) == ["sessionStart", "beforeSubmitPrompt", "postToolUse", "afterFileEdit", "stop", "sessionEnd"],
               "... with a command for each of Cursor's six events", "\(got)")
        expect(Hooks.remove(cursor).ok && !fm.fileExists(atPath: cursor.file.path), "... and goes when they do, the version being all that was left")
        write("{\n  \"version\": 1,\n  \"hooks\": {\n    \"stop\": [{ \"command\": \"./mine.sh\" }]\n  }\n}\n", cursor.file)
        expect(Hooks.install(cursor).ok && commands(cursor.file, flat: true)["stop"] == ["./mine.sh", "\"\(exe)\" --cli hook stop --harness cursor"], "a Cursor file with the person's hooks keeps them", "\(commands(cursor.file, flat: true))")
        expect(Hooks.remove(cursor).ok && commands(cursor.file, flat: true) == ["stop": ["./mine.sh"]] && (json(cursor.file)?["version"] as? Int) == 1, "... and is theirs again once Greenroom's are out")
        try? fm.removeItem(at: cursor.file)

        // Claude Code's settings: one key among the person's others.
        let settings = "{\n  \"permissions\": {\n    \"allow\": [\"Bash(ls:*)\"]\n  },\n  \"hooks\": {\n    \"Stop\": [\n      { \"hooks\": [ { \"type\": \"command\", \"command\": \"$HOME/.claude/hooks/allow-sleep.sh\" } ] }\n    ]\n  },\n  \"model\": \"opus\"\n}\n"
        write(settings, claude.file)
        expect(Hooks.install(claude).ok && Hooks.state(claude) == .ours(current: true), "Claude Code's hooks go in its settings file")
        let after = read(claude.file)
        expect(after.hasPrefix("{\n  \"permissions\": {\n    \"allow\": [\"Bash(ls:*)\"]\n  },\n  \"hooks\": ") && after.hasSuffix(",\n  \"model\": \"opus\"\n}\n"), "... with every other setting left byte for byte", after)
        got = commands(claude.file, flat: false)
        expect(got["Stop"] == ["$HOME/.claude/hooks/allow-sleep.sh", "\"\(exe)\" --cli hook Stop --harness claude"]
               && got["Notification"] == ["\"\(exe)\" --cli hook Notification --harness claude", "\"\(exe)\" --cli hook Idle --harness claude"],
               "... after the person's own, with the two kinds of notification told apart", "\(got)")
        let matchers = (((json(claude.file)?["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]]) ?? []).compactMap { $0["matcher"] as? String }
        expect(matchers == ["permission_prompt|elicitation_dialog|agent_needs_input", "idle_prompt"], "... by Claude Code's matcher", "\(matchers)")
        expect(Hooks.remove(claude).ok && read(claude.file).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "") == settings.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: ""),
               "taken out, the settings say what they said", read(claude.file))
        // A file that is not plain JSON, or not laid out as documented, is left alone.
        for (text, what) in [("{\n  // mine\n  \"hooks\": {}\n}\n", "a settings file with a comment"), ("{\"hooks\": [\"x\"]}", "hooks that are a list"), ("{\"hooks\": {\"Stop\": \"x\"}}", "an event that is not a list")] {
            write(text, claude.file)
            let r = Hooks.install(claude)
            expect(Hooks.state(claude) == .unreadable && !r.ok && r.message.contains("left as it is") && read(claude.file) == text && Hooks.remove(claude).ok && read(claude.file) == text, "\(what) is left as it is, and said so", r.message)
        }
        expect(json2(Hooks.byHand(claude)) != nil && Hooks.byHand(cursor).contains("\"version\": 1"), "... with the hooks to add by hand shown as JSON")
        try? fm.removeItem(at: claude.file)

        // --- The hooks follow the connection (Harnesses.settleHooks) ---
        plugin(nil); registered(true); codexAdded(true)
        let cc = Harnesses.claude, cx = Harnesses.codex
        expect(cc.status().isConnected && cc.hooks() == .claude, "Claude Code connected without the plugin takes its hooks from its settings")
        expect(Harnesses.settleHooks(cc, cc.status(), creating: false) == nil && !fm.fileExists(atPath: claude.file.path), "looking at a connected harness writes no hooks")
        expect(Harnesses.settleHooks(cc, .otherCopy("/x")) == nil && Harnesses.settleHooks(cc, .unknown("?")) == nil && Harnesses.settleHooks(cc, .notInstalled) == nil && !fm.fileExists(atPath: claude.file.path),
               "a harness on another copy, or one that did not answer, changes no hooks")
        let on = Harnesses.settleHooks(cc, cc.status())
        expect(on?.ok == true && on?.message.contains("~/.claude/settings.json") == true && Hooks.state(claude) == .ours(current: true), "connecting writes them", on?.message ?? "nil")
        expect(Harnesses.settleHooks(cc, cc.status()) == nil, "... once")
        // The plugin from before it had hooks: the settings keep them. With hooks in it: the plugin's alone.
        plugin("✔ enabled")
        expect(cc.status().isConnected && cc.hooks() == .claude, "a plugin from before it had hooks leaves them in the settings")
        Harnesses.settleHooks(cc, cc.status(), creating: false)
        expect(Hooks.state(claude) == .ours(current: true), "... where they stay")
        write("{}", home.appendingPathComponent(".claude/plugins/cache/greenroom/greenroom/abc123/hooks/hooks.json"))
        expect(cc.status().isConnected && cc.hooks() == nil, "a plugin with hooks carries them")
        let moved = Harnesses.settleHooks(cc, cc.status(), creating: false)
        expect(moved?.message.contains("removed") == true && Hooks.state(claude) == .none && !fm.fileExists(atPath: claude.file.path), "... and Greenroom's go from the settings at the next look, so none runs twice", moved?.message ?? "nil")
        expect(Harnesses.settleHooks(cc, cc.status()) == nil && !fm.fileExists(atPath: claude.file.path), "... and connecting writes none there")
        try? fm.removeItem(at: home.appendingPathComponent(".claude/plugins"))
        plugin(nil)
        Harnesses.settleHooks(cc, cc.status())
        // Disconnected outside Greenroom: looking takes them out.
        registered(false)
        let out = Harnesses.settleHooks(cc, cc.status(), creating: false)
        expect(cc.status() == .notConnected && out?.message.contains("removed") == true && !fm.fileExists(atPath: claude.file.path), "a harness disconnected elsewhere loses its hooks at the next look", out?.message ?? "nil")
        // An earlier or another copy's hooks follow a harness connected to this copy.
        expect(cx.status().isConnected && Harnesses.settleHooks(cx, cx.status())?.ok == true, "Codex connected: its hooks are written")
        let codexWritten = read(codex.file)
        write(codexWritten.replacingOccurrences(of: exe, with: "/Applications/Other/Greenroom.app/Contents/MacOS/Greenroom"), codex.file)
        Harnesses.settleHooks(cx, cx.status(), creating: false)
        expect(read(codex.file) == codexWritten, "hooks left pointing at another copy are pointed at the connected one when looked at")
        // The Debug copy belongs to one repository: it writes and removes nothing.
        ClaudeConnect.repositoryOnlyOverride = true
        expect(Harnesses.settleHooks(cx, .notConnected) == nil && read(codex.file) == codexWritten, "the Debug copy takes no hooks out")
        try? fm.removeItem(at: codex.file)
        expect(Harnesses.settleHooks(cx, .connected("x")) == nil && !fm.fileExists(atPath: codex.file.path), "... and writes none")
        ClaudeConnect.repositoryOnlyOverride = false
        codexAdded(false)
        // What is shown before anything is written.
        expect(cx.how().contains("~/.codex/hooks.json") && cx.how().contains("--cli hook Stop --harness codex") && cx.how().contains("/hooks") && Harnesses.cursor.how().contains("~/.cursor/hooks.json")
               && cc.how().contains("~/.claude/settings.json") && cc.how().contains("Never a prompt"), "what connecting shows names the hooks file, the line a hook runs and what it tells")

        // --- What the hooks say, as sessions (HookSessions) ---
        DispatchQueue.main.sync { sessions(base: base, check: check) }
        plugin("✔ enabled")
    }

    private static func json2(_ text: String) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] }

    /// On the main thread, as the app hears hooks.
    private static func sessions(base: URL, check: (Bool, String, String) -> Void) {
        func expect(_ ok: Bool, _ what: String, _ got: String = "") { check(ok, what, got) }
        let fm = FileManager.default
        let hs = HookSessions.shared
        let repo = base.appendingPathComponent("hook-repo").resolvingSymlinksInPath(), other = base.appendingPathComponent("hook-repo-2").resolvingSymlinksInPath()
        try? fm.createDirectory(at: repo.appendingPathComponent("app"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: other, withIntermediateDirectories: true)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        HookSessions.now = { clock }
        hs.reset()
        var changes = 0, ends: [String] = []
        let keptChange = hs.onChange, keptEnd = hs.onTurnEnd
        hs.onChange = { changes += 1 }
        hs.onTurnEnd = { ends.append($0.path) }
        func hook(_ event: String, harness: String = "codex", session: String = "s1", in folder: URL? = nil) {
            if let e = HookLog.shared.add(["harness": harness, "event": event, "cwd": (folder ?? repo).path, "session": session]) { hs.heard(e) }
        }
        func one() -> AgentSession? { hs.sessions.count == 1 ? hs.sessions[0] : nil }

        expect(HookSessions.kind("Stop") == .turnEnd && HookSessions.kind("stop") == .turnEnd && HookSessions.kind("beforeSubmitPrompt") == .working && HookSessions.kind("UserPromptSubmit") == .working
               && HookSessions.kind("PermissionRequest") == .waiting && HookSessions.kind("Notification") == .waiting && HookSessions.kind("Idle") == .idle && HookSessions.kind("SessionEnd") == .end
               && HookSessions.kind("sessionStart") == .start && HookSessions.kind("somethingNew") == .other, "each harness's events mean one of six things, however it spells them")

        hook("SessionStart")
        expect(one()?.status == .idle && one()?.running == true && one()?.source == .hook && one()?.harness == "Codex" && one()?.id == "s1" && one()?.folder.path == repo.path,
               "a session that started is known by its harness, its id and its folder, and is not working yet", "\(String(describing: one()))")
        expect(one()?.sourceName == "Codex" && one()?.appName == "Codex", "... and is called what the person calls its harness")
        hook("UserPromptSubmit")
        expect(one()?.status == .working && hs.midTurn(in: repo) && !hs.midTurn(in: other), "a prompt puts it to work, in its worktree and no other")
        hook("PermissionRequest")
        expect(one()?.status == .waiting && hs.midTurn(in: repo), "asking for a permission is waiting for the person")
        hook("PostToolUse")
        expect(one()?.status == .working, "the tool having run, it is working again")
        expect(ends.isEmpty, "none of which is the end of a turn")
        hook("Stop")
        expect(one()?.status == .idle && one()?.running == true && ends == [repo.path] && !hs.midTurn(in: repo), "Stop ends the turn, once, for its folder", "\(ends)")
        hook("Stop")
        expect(ends == [repo.path], "a second hook for the same end (a harness that runs two) is not a second turn")
        clock += 5
        hook("UserPromptSubmit"); hook("Stop")
        expect(ends == [repo.path, repo.path], "the next turn's end is")
        expect(changes >= 5, "each change of what is shown is announced", "\(changes)")
        let quiet = changes
        hook("somethingNew"); hook("SessionStart")
        expect(one()?.status == .idle && changes == quiet, "an event Greenroom does not know, or a start in the middle, changes nothing shown")

        // Time: a session heard working and then not at all is taken to have stopped; an idle one closes, then goes.
        hook("UserPromptSubmit")
        clock += HookSessions.stale - 1
        expect(one()?.status == .working && hs.midTurn(in: repo), "a session is still working a quarter of an hour after its last hook, less a second")
        clock += 2
        hs.tick()
        expect(one()?.status == .idle && one()?.running == true && !hs.midTurn(in: repo), "... and not after it: an interrupt no hook reported")
        clock += HookSessions.open
        expect(one()?.running == false, "an hour on it is no longer open")
        clock += HookSessions.forget
        hs.tick()
        expect(hs.sessions.isEmpty, "a day on it is forgotten")

        // Sessions are kept apart by harness and id; one with no id is its folder's.
        hook("beforeSubmitPrompt", harness: "cursor", session: "c1")
        hook("UserPromptSubmit", harness: "claude", session: "c1", in: repo.appendingPathComponent("app"))
        hook("UserPromptSubmit", harness: "my-agent", session: "", in: other)
        hook("Stop", harness: "my-agent", session: "", in: other)
        expect(Set(hs.sessions.map { "\($0.harness ?? "") \($0.id ?? "-") \($0.status)" }) == ["Cursor c1 working", "Claude Code c1 working", "my-agent - idle"], "three harnesses' sessions are three sessions",
               "\(hs.sessions.map { "\($0.harness ?? "") \($0.id ?? "-") \($0.status)" })")
        expect(hs.midTurn(in: repo) && !hs.midTurn(in: other) && ends.last == other.path, "a session in a subfolder is in its worktree's turn")
        hook("sessionEnd", harness: "cursor", session: "c1")
        expect(hs.sessions.count == 2 && !hs.sessions.contains { $0.harness == "Cursor" }, "a session that ended is gone")

        // Joined with what the files say: the files give the title, the hook says what it is doing now.
        hs.reset()
        hook("UserPromptSubmit", harness: "claude", session: "abc")
        var file = AgentSession(folder: repo, status: .idle, lastActivity: clock.addingTimeInterval(-600), running: false, source: .claude, id: "abc")
        file.title = "Fix the list"
        var joined = hs.joined(with: [file])
        expect(joined.count == 1 && joined[0].title == "Fix the list" && joined[0].status == .working && joined[0].running && joined[0].source == .claude && joined[0].lastActivity == clock,
               "a session the files know by the hook's id is that session, with the hook's status", "\(joined.map { "\($0.source) \($0.status) \($0.running)" })")
        var resumed = file
        resumed.id = "new"; resumed.ids = ["abc", "new"]
        expect(hs.joined(with: [resumed]).count == 1 && hs.joined(with: [resumed])[0].status == .working, "... by an id it had before it was resumed, too")
        var elsewhere = file
        elsewhere.id = "zzz"
        joined = hs.joined(with: [elsewhere])
        expect(joined.count == 2 && joined[1].source == .hook && joined[1].status == .working, "a session the files do not know is one of its own", "\(joined.count)")
        var live = elsewhere
        live.running = true
        expect(hs.joined(with: [live]).count == 1, "... unless that harness already has a live session shown for the folder, which it then is")
        var thread = AgentSession(folder: repo, status: .working, lastActivity: clock, running: true, source: .t3, id: "t3-1")
        thread.provider = "codex"
        expect(hs.joined(with: [thread]).count == 2, "a T3 Code thread running another harness is not it")
        thread.provider = "claudeAgent"
        expect(hs.joined(with: [thread]).count == 1, "a T3 Code thread running that harness is")
        expect(hs.joined(with: []).map(\.sourceName) == ["Claude Code"] && hs.joined(with: [])[0].appName == "Claude", "alone, it is shown as its harness's")

        hs.reset()
        hs.onChange = keptChange; hs.onTurnEnd = keptEnd
        HookSessions.now = { Date() }
    }
}
