import Foundation

/// Greenroom's skill, in the folders harnesses read skills from (docs/AGENT-FIRST-SPEC.md, "Installing, per
/// harness"). One text: the Claude Code plugin's `skills/verify/SKILL.md`, which the app carries, reworded where it
/// speaks of the plugin. Two places:
///
///     ~/.agents/skills/greenroom/SKILL.md    Codex, Cursor, Copilot CLI, opencode, Gemini CLI, Goose, Amp
///     ~/.claude/skills/greenroom/SKILL.md    Claude Code connected without the plugin (the plugin has the skill)
///
/// A file Greenroom wrote ends in a line saying so and who asked for it (a connected harness, or "you" from the
/// Connect screen). Connecting a harness adds its name, disconnecting takes it out, and the file goes with the last
/// name. A file at that path without the line is somebody else's: never written over, never removed.
enum Skills {
    static let name = "greenroom"

    enum Place: String, CaseIterable {
        case agents, claude

        var folder: URL { Harnesses.home.appendingPathComponent(self == .agents ? ".agents/skills/\(Skills.name)" : ".claude/skills/\(Skills.name)", isDirectory: true) }
        var file: URL { folder.appendingPathComponent("SKILL.md") }
        /// As the screen shows it.
        var shown: String { (self == .agents ? "~/.agents" : "~/.claude") + "/skills/\(Skills.name)/SKILL.md" }
    }

    enum State: Equatable {
        case none
        /// Greenroom's: who asked for it, and whether its text is this copy's.
        case ours(asked: [String], current: Bool)
        /// A file Greenroom did not write.
        case theirs

        var isOurs: Bool { if case .ours = self { return true }; return false }
    }

    struct Result: Equatable {
        let ok: Bool
        /// What happened, in a sentence. Empty when nothing changed.
        let message: String
    }

    // MARK: The text

    /// The plugin's skill as the app carries it, else (a `swift run` build) the source tree's.
    static var source: String? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("skill/SKILL.md")
        let tree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plugin/skills/verify/SKILL.md")
        for f in [bundled, tree].compactMap({ $0 }) {
            if let s = try? String(contentsOf: f, encoding: .utf8), !s.isEmpty { return s }
        }
        return nil
    }

    /// What each rewording replaces. Every one must be found: a skill that changed under them gives no text, and
    /// the check says so, sooner than a half-reworded file reaches a harness.
    private static let rewordings: [(from: String, to: String)] = [
        ("name: verify\n", "name: \(name)\n"),
        ("argument-hint: \"[what to verify]\"\n", ""),
        ("Its tools are this plugin's `greenroom` server (", "Its tools are the `greenroom` MCP server's ("),
        ("What to verify: $ARGUMENTS\n\nIf that is empty, verify the change this worktree makes:", "With no more specific request, verify the change this worktree makes:"),
        ("Greenroom.app is not installed where the plugin looks\n(`/Applications`, `~/Applications`, Spotlight): say so instead of falling back to an emulator silently.",
         "Greenroom was moved or removed since it was\nconnected: say so instead of falling back to an emulator silently. The person connects it again from Greenroom's\nFile > Connect Agents…."),
    ]

    /// The skill as a harness without the plugin reads it, nil when this copy has none.
    static func text(from source: String? = Skills.source) -> String? {
        guard var s = source else { return nil }
        for r in rewordings {
            guard s.contains(r.from) else { return nil }
            s = s.replacingOccurrences(of: r.from, with: r.to)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: The line that says the file is Greenroom's

    private static let markerStart = "<!-- greenroom-skill: "
    private static func marker(_ asked: [String]) -> String {
        markerStart + "written by Greenroom (File > Connect Agents…), which rewrites this file. Asked for by: \(asked.joined(separator: ", ")). -->"
    }

    /// A file's text without the line, and who the line names. nil: the file has no such line.
    private static func split(_ whole: String) -> (body: String, asked: [String])? {
        var lines = whole.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let last = lines.last, last.hasPrefix(markerStart), last.hasSuffix("-->") else { return nil }
        lines.removeLast()
        var asked: [String] = []
        if let r = last.range(of: "Asked for by: ") {
            asked = last[r.upperBound...].replacingOccurrences(of: "-->", with: "")
                .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }.filter { !$0.isEmpty }
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n", asked)
    }

    static func state(_ place: Place) -> State {
        guard FileManager.default.fileExists(atPath: place.file.path) else { return .none }
        guard let whole = try? String(contentsOf: place.file, encoding: .utf8), let (body, asked) = split(whole) else { return .theirs }
        return .ours(asked: asked, current: body == text())
    }

    private static func theirs(_ place: Place) -> Result {
        Result(ok: false, message: "\(place.shown) is not Greenroom's (it does not end in Greenroom's line), so it was left as it is.")
    }

    private static func write(_ place: Place, asked: [String]) -> Bool {
        guard let body = text() else { return false }
        try? FileManager.default.createDirectory(at: place.folder, withIntermediateDirectories: true)
        return (try? (body + "\n" + marker(asked) + "\n").write(to: place.file, atomically: true, encoding: .utf8)) != nil
    }

    /// Writes the skill for WHO (a harness's id, or "you"), or adds WHO to the one that is there.
    @discardableResult
    static func install(_ place: Place, for who: String) -> Result {
        guard text() != nil else { return Result(ok: false, message: "This copy of Greenroom carries no skill to write.") }
        var asked: [String] = []
        switch state(place) {
        case .theirs: return theirs(place)
        case .ours(let names, let current):
            if current && names.contains(who) { return Result(ok: true, message: "") }
            asked = names
        case .none: break
        }
        if !asked.contains(who) { asked.append(who) }
        guard write(place, asked: asked.sorted()) else { return Result(ok: false, message: "\(place.shown) could not be written.") }
        return Result(ok: true, message: "Its skill is \(place.shown).")
    }

    /// Takes WHO off the skill. With nobody left the file goes, and its folder when nothing else is in it.
    @discardableResult
    static func remove(_ place: Place, for who: String) -> Result {
        let fm = FileManager.default
        switch state(place) {
        case .none, .theirs: return Result(ok: true, message: "")   // not Greenroom's to remove
        case .ours(let names, _):
            guard names.contains(who) || names.isEmpty else { return Result(ok: true, message: "") }
            let left = names.filter { $0 != who }
            if !left.isEmpty {
                guard write(place, asked: left) else { return Result(ok: false, message: "\(place.shown) could not be written.") }
                return Result(ok: true, message: "The skill at \(place.shown) stays: \(left.map(asker).joined(separator: " and ")) asked for it too.")
            }
            guard (try? fm.removeItem(at: place.file)) != nil else { return Result(ok: false, message: "\(place.shown) could not be removed.") }
            if (try? fm.contentsOfDirectory(atPath: place.folder.path))?.isEmpty == true { try? fm.removeItem(at: place.folder) }
            return Result(ok: true, message: "Its skill (\(place.shown)) was removed.")
        }
    }

    /// Brings a file Greenroom wrote up to this copy's text. Nothing else is touched.
    static func refresh(_ place: Place) {
        if case .ours(let names, false) = state(place), text() != nil { _ = write(place, asked: names) }
    }

    /// A name in the line, as the screen says it.
    static func asker(_ id: String) -> String {
        id == "you" ? "you" : (Harnesses.connectable.first { $0.id == id }?.name ?? id)
    }

    /// What a row says of a place.
    static func words(_ place: Place, _ state: State) -> String {
        switch state {
        case .none: return "No skill at \(place.shown)"
        case .theirs: return "\(place.shown) is a skill Greenroom did not write"
        case .ours(_, let current): return "Skill: \(place.shown)" + (current ? "" : " (from an earlier Greenroom)")
        }
    }
}

/// The `greenroom` command on the PATH: a link to the script inside this app (`Contents/Resources/bin/greenroom`),
/// in the first folder on the login shell's PATH that can be written without a password. Nothing is copied, so the
/// command is always this app's; a program called greenroom that is not a link into a Greenroom.app is left alone.
enum CommandLink {
    static let name = "greenroom"
    /// The folders tried, in order, after the home folder's own (for a check: none).
    static var systemFolders = ["/usr/local/bin", "/opt/homebrew/bin"]
    /// For a check: the script to link to.
    static var scriptOverride: URL?

    enum State: Equatable {
        /// On the PATH and this app's: where.
        case installed(String)
        /// A link into another Greenroom.app: where, and that app.
        case otherCopy(String, String)
        /// Some other program called greenroom is on the PATH: where.
        case taken(String)
        /// Not there: where the link would go.
        case available(String)
        /// Not there, and why it cannot be added.
        case unavailable(String)
    }

    struct Result: Equatable { let ok: Bool; let message: String }

    /// The script inside this app, nil for a build that is not an app.
    static var script: URL? {
        if let s = scriptOverride { return s }
        guard let s = Bundle.main.resourceURL?.appendingPathComponent("bin/greenroom"), FileManager.default.isExecutableFile(atPath: s.path) else { return nil }
        return s
    }

    private static func path() -> [String] {
        let p = ClaudeConnect.pathOverride ?? LoginEnvironment.resolve().env["PATH"] ?? ""
        return p.split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
    }

    private static var candidates: [String] {
        [Harnesses.home.appendingPathComponent(".local/bin").path, Harnesses.home.appendingPathComponent("bin").path] + systemFolders
    }

    private static func shown(_ path: String) -> String {
        let home = Harnesses.home.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// What to type where no folder can be written.
    static var byHand: String {
        "sudo ln -sf \"\(script?.path ?? "/Applications/Greenroom.app/Contents/Resources/bin/greenroom")\" /usr/local/bin/\(name)"
    }

    /// What adding the command runs, as the person would type it.
    static func displayCommand(_ state: State) -> String {
        guard let script else { return "" }
        switch state {
        case .available(let at), .installed(let at), .otherCopy(let at, _): return "ln -sf \"\(script.path)\" \"\(at)\""
        case .taken, .unavailable: return byHand
        }
    }

    /// Blocks the first time (the login shell is asked for its PATH): never on the main thread.
    static func state() -> State {
        let fm = FileManager.default
        guard let script else { return .unavailable("This is a build without the \(name) command: it is inside Greenroom.app.") }
        if ClaudeConnect.translocated { return .unavailable(ClaudeConnect.translocatedMessage) }
        let dirs = path()
        for dir in dirs {
            let at = dir + "/" + name
            // A link that leads nowhere (its app was moved) still exists as a link.
            guard fm.fileExists(atPath: at) || (try? fm.destinationOfSymbolicLink(atPath: at)) != nil else { continue }
            let target = (try? fm.destinationOfSymbolicLink(atPath: at)).map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: dir, isDirectory: true)).standardizedFileURL.path }
            let real = fm.fileExists(atPath: at) ? URL(fileURLWithPath: at).resolvingSymlinksInPath().path : target ?? at
            if real == script.resolvingSymlinksInPath().path { return .installed(at) }
            if target != nil, real.hasSuffix("/Contents/Resources/bin/" + name) {
                return .otherCopy(at, String(real.dropLast(("/Contents/Resources/bin/" + name).count)))
            }
            return .taken(at)
        }
        for dir in candidates where dirs.contains(URL(fileURLWithPath: dir).standardizedFileURL.path) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue, fm.isWritableFile(atPath: dir) { return .available(dir + "/" + name) }
        }
        return .unavailable("None of \(candidates.map(shown).joined(separator: ", ")) is on your PATH and writable without a password.")
    }

    static func words(_ state: State) -> String {
        switch state {
        case .installed(let at): return "On your PATH (\(shown(at)))"
        case .otherCopy(let at, let app): return "\(shown(at)) runs another copy of Greenroom (\(app))"
        case .taken(let at): return "Another program called \(name) is on your PATH (\(shown(at))), and is left alone"
        case .available(let at): return "Greenroom's tools from a shell and in scripts. Links \(shown(at)) to this app"
        case .unavailable(let why): return why
        }
    }

    /// Makes the link, or points another copy's link at this app.
    static func install() -> Result {
        let fm = FileManager.default
        guard let script else { return Result(ok: false, message: words(state())) }
        let at: String
        switch state() {
        case .installed(let p): return Result(ok: true, message: "Already there: \(shown(p)).")
        case .taken(let p): return Result(ok: false, message: "\(shown(p)) is another program, so it was left as it is.")
        case .unavailable(let why): return Result(ok: false, message: why)
        case .otherCopy(let p, _):
            guard (try? fm.removeItem(atPath: p)) != nil else { return Result(ok: false, message: "\(shown(p)) could not be replaced.") }
            at = p
        case .available(let p): at = p
        }
        guard (try? fm.createSymbolicLink(atPath: at, withDestinationPath: script.path)) != nil else { return Result(ok: false, message: "\(shown(at)) could not be written.") }
        guard case .installed = state() else { return Result(ok: false, message: "\(shown(at)) was written, but \(name) on your PATH is not it.") }
        return Result(ok: true, message: "Added: \(name) in a new terminal runs this app (\(shown(at))).")
    }

    /// Removes the link, when it is a link to this app.
    static func remove() -> Result {
        switch state() {
        case .installed(let p):
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: p)) != nil else { return Result(ok: false, message: "\(shown(p)) is not a link, so it was left as it is.") }
            guard (try? FileManager.default.removeItem(atPath: p)) != nil else { return Result(ok: false, message: "\(shown(p)) could not be removed.") }
            return Result(ok: true, message: "Removed \(shown(p)).")
        case .otherCopy(let p, _), .taken(let p): return Result(ok: false, message: "\(shown(p)) is not this app's, so it was left as it is.")
        case .available, .unavailable: return Result(ok: true, message: "The \(name) command is not on your PATH.")
        }
    }
}
