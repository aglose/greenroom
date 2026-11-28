import Foundation

// Session status from the harness itself (docs/AGENT-FIRST-SPEC.md, "Installing, per harness", the Status column):
// each connected harness runs `greenroom hook EVENT` at a session's start, when a prompt is sent, after a tool, when
// it asks the person something, and when the turn ends. This file is the part that puts those hooks into the
// harness's own hooks file and takes them out again. What the app does with what they say is HookSessions.swift.
//
// A hooks file is the person's: it may hold their own hooks, and for Claude Code it is their whole settings file.
// So Greenroom changes one thing in it, the value of its top-level "hooks" key, and inside that value only its own
// entries. Every other byte of the file stays as it was written, key order and spacing included.

/// JSON kept the way it was written: the order of an object's keys, and each string and number as its text.
indirect enum OrderedJSON {
    case object([(key: String, value: OrderedJSON)])
    case array([OrderedJSON])
    /// A string, number, true, false or null, as written.
    case raw(String)

    static func string(_ s: String) -> OrderedJSON { .raw(quote(s)) }

    /// S as a JSON string, slashes left as they are.
    static func quote(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              let t = String(data: d, encoding: .utf8), t.count >= 2 else { return "\"\"" }
        return String(t.dropFirst().dropLast())
    }

    /// The text of a string value, nil for anything else.
    var text: String? {
        guard case .raw(let r) = self, r.hasPrefix("\"") else { return nil }
        return ((try? JSONSerialization.jsonObject(with: Data("[\(r)]".utf8))) as? [String])?.first
    }

    subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var members: [(key: String, value: OrderedJSON)]? { if case .object(let m) = self { return m }; return nil }
    var items: [OrderedJSON]? { if case .array(let a) = self { return a }; return nil }

    /// Written out, two spaces a level, with INDENT before every line after the first.
    func written(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .raw(let r): return r
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { inner + $0.written(indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            return "{\n" + members.map { inner + Self.quote($0.key) + ": " + $0.value.written(indent: inner) }.joined(separator: ",\n") + "\n" + indent + "}"
        }
    }
}

/// A JSON file whose top-level object is read with the place of every member, so one member's value can be
/// replaced, added or taken out and the rest of the file left byte for byte.
struct OrderedJSONFile {
    struct Member { let key: String; let value: OrderedJSON; let keyStart: Int; let valueRange: Range<Int> }
    private(set) var bytes: [UInt8]
    private(set) var members: [Member] = []
    private var open = 0, close = 0

    /// nil when DATA is not a JSON object (comments and trailing commas are not JSON).
    init?(_ data: Data) {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { return nil }
        bytes = [UInt8](data)
        guard read() else { return nil }
    }

    /// An empty object, for a file that is not there.
    init() { bytes = Array("{}\n".utf8); _ = read() }

    var data: Data { Data(bytes) }
    subscript(key: String) -> OrderedJSON? { members.first { $0.key == key }?.value }

    private mutating func read() -> Bool {
        var r = Reader(b: bytes)
        r.space()
        guard r.peek == UInt8(ascii: "{") else { return false }
        open = r.i
        r.i += 1
        members = []
        r.space()
        if r.peek == UInt8(ascii: "}") { close = r.i; return true }
        while true {
            r.space()
            let keyStart = r.i
            guard let raw = r.string(), let key = OrderedJSON.raw(raw).text else { return false }
            r.space()
            guard r.peek == UInt8(ascii: ":") else { return false }
            r.i += 1
            r.space()
            let start = r.i
            guard let value = r.value() else { return false }
            members.append(Member(key: key, value: value, keyStart: keyStart, valueRange: start..<r.i))
            r.space()
            if r.peek == UInt8(ascii: ",") { r.i += 1; continue }
            guard r.peek == UInt8(ascii: "}") else { return false }
            close = r.i
            return true
        }
    }

    /// The spaces before the first member, when it starts a line of its own: what a new member is indented by.
    private var indent: String {
        guard let first = members.first else { return "  " }
        var i = first.keyStart
        while i > 0, bytes[i - 1] == 0x20 || bytes[i - 1] == 0x09 { i -= 1 }
        guard i > 0, bytes[i - 1] == 0x0A, i < first.keyStart else { return "  " }
        return String(decoding: bytes[i..<first.keyStart], as: UTF8.self)
    }

    /// Sets KEY's value, adding the member after the others when it is not there; nil takes the member out.
    mutating func set(_ key: String, _ value: OrderedJSON?) {
        let pad = indent
        if let at = members.firstIndex(where: { $0.key == key }) {
            let m = members[at]
            if let value {
                bytes.replaceSubrange(m.valueRange, with: Array(value.written(indent: pad).utf8))
            } else if at > 0 {
                bytes.removeSubrange(members[at - 1].valueRange.upperBound..<m.valueRange.upperBound)
            } else if members.count > 1 {
                bytes.removeSubrange(m.keyStart..<members[1].keyStart)
            } else {
                bytes.replaceSubrange((open + 1)..<close, with: [])
            }
        } else if let value {
            let text = OrderedJSON.quote(key) + ": " + value.written(indent: pad)
            if let last = members.last {
                bytes.insert(contentsOf: Array((",\n" + pad + text).utf8), at: last.valueRange.upperBound)
            } else {
                bytes.replaceSubrange((open + 1)..<close, with: Array(("\n" + pad + text + "\n").utf8))
            }
        }
        _ = read()
    }

    private struct Reader {
        let b: [UInt8]
        var i = 0
        var peek: UInt8? { i < b.count ? b[i] : nil }

        mutating func space() { while let c = peek, c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 } }

        /// A string as written, quotes included.
        mutating func string() -> String? {
            guard peek == UInt8(ascii: "\"") else { return nil }
            let start = i
            i += 1
            while let c = peek {
                if c == UInt8(ascii: "\\") { i += 2; continue }
                i += 1
                if c == UInt8(ascii: "\"") { return String(decoding: b[start..<i], as: UTF8.self) }
            }
            return nil
        }

        mutating func value() -> OrderedJSON? {
            guard let c = peek else { return nil }
            switch c {
            case UInt8(ascii: "\""): return string().map { .raw($0) }
            case UInt8(ascii: "{"):
                i += 1
                var members: [(key: String, value: OrderedJSON)] = []
                space()
                if peek == UInt8(ascii: "}") { i += 1; return .object([]) }
                while true {
                    space()
                    guard let raw = string(), let key = OrderedJSON.raw(raw).text else { return nil }
                    space()
                    guard peek == UInt8(ascii: ":") else { return nil }
                    i += 1
                    space()
                    guard let v = value() else { return nil }
                    members.append((key, v))
                    space()
                    if peek == UInt8(ascii: ",") { i += 1; continue }
                    guard peek == UInt8(ascii: "}") else { return nil }
                    i += 1
                    return .object(members)
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [OrderedJSON] = []
                space()
                if peek == UInt8(ascii: "]") { i += 1; return .array([]) }
                while true {
                    space()
                    guard let v = value() else { return nil }
                    items.append(v)
                    space()
                    if peek == UInt8(ascii: ",") { i += 1; continue }
                    guard peek == UInt8(ascii: "]") else { return nil }
                    i += 1
                    return .array(items)
                }
            default:
                let start = i
                while let c = peek, c != UInt8(ascii: ","), c != UInt8(ascii: "}"), c != UInt8(ascii: "]"), c != 0x20, c != 0x0A, c != 0x0D, c != 0x09 { i += 1 }
                return i > start ? .raw(String(decoding: b[start..<i], as: UTF8.self)) : nil
            }
        }
    }
}

/// Greenroom's hooks in a harness's hooks file.
enum Hooks {
    /// One hook: the harness's name for the event, and what it runs.
    struct Spec: Equatable {
        /// The key in the harness's file.
        let event: String
        /// What `greenroom hook` is told, when it is not the event's own name.
        var word: String?
        /// Which of the event's kinds it is for (Claude Code's `matcher`), nil for all.
        var matcher: String?
    }

    /// A harness's hooks file. Claude Code's and Codex's hold, for each event, groups with a `matcher` and a list
    /// of `hooks`; Cursor's holds a `version` and, for each event, a plain list of commands.
    struct Place: Equatable {
        /// The harness's id, as `Harness.id`.
        let id: String
        let name: String
        /// Under the home folder.
        let path: String
        let flat: Bool
        let specs: [Spec]

        var file: URL { Harnesses.home.appendingPathComponent(path) }
        var shown: String { "~/" + path }

        /// Claude Code connected without the plugin (the plugin carries the same hooks). The events are ones every
        /// Claude Code with hooks knows: its settings file is refused whole over an event it does not know.
        static let claude = Place(id: "claude", name: "Claude Code", path: ".claude/settings.json", flat: false, specs: [
            Spec(event: "SessionStart"), Spec(event: "UserPromptSubmit"), Spec(event: "PostToolUse"),
            Spec(event: "Notification", matcher: "permission_prompt|elicitation_dialog|agent_needs_input"),
            Spec(event: "Notification", word: "Idle", matcher: "idle_prompt"),
            Spec(event: "Stop"), Spec(event: "SessionEnd"),
        ])
        static let codex = Place(id: "codex", name: "Codex", path: ".codex/hooks.json", flat: false, specs: [
            Spec(event: "SessionStart"), Spec(event: "UserPromptSubmit"), Spec(event: "PermissionRequest"), Spec(event: "PostToolUse"), Spec(event: "Stop"),
        ])
        static let cursor = Place(id: "cursor", name: "Cursor", path: ".cursor/hooks.json", flat: true, specs: [
            Spec(event: "sessionStart"), Spec(event: "beforeSubmitPrompt"), Spec(event: "postToolUse"), Spec(event: "afterFileEdit"),
            Spec(event: "stop"), Spec(event: "sessionEnd"),
        ])
        static let all = [claude, codex, cursor]
    }

    enum State: Equatable {
        case none
        /// This copy's hooks are there. `current`: exactly the ones this copy would write.
        case ours(current: Bool)
        /// Greenroom hooks that run another copy (its program).
        case otherCopy(String)
        /// The file is not plain JSON, or its hooks are not laid out as the harness documents.
        case unreadable

        var isOurs: Bool { if case .ours = self { return true }; return false }
    }

    struct Result: Equatable {
        let ok: Bool
        let message: String
    }

    // MARK: The command

    /// What a hook runs: this copy's own program, so the line stays the same from one version of the app to the
    /// next (Codex asks the person to trust a hook again when its text changes).
    static func command(_ spec: Spec, harness: String, executable: String = ClaudeConnect.executable) -> String {
        "\"\(executable)\" --cli hook \(spec.word ?? spec.event) --harness \(harness)"
    }

    private static let ours = try! NSRegularExpression(pattern: #"^"(/[^"]*/Greenroom[^/"]*)" --cli hook [A-Za-z]+ --harness [a-z-]+$"#)

    /// The Greenroom program a hook's command runs, nil for anybody else's hook.
    static func program(of command: String) -> String? {
        guard let m = ours.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)), let r = Range(m.range(at: 1), in: command) else { return nil }
        return String(command[r])
    }

    // MARK: Reading

    private enum Loaded { case absent, file(OrderedJSONFile), unreadable }

    private static func load(_ place: Place) -> Loaded {
        guard let data = try? Data(contentsOf: place.file) else {
            return FileManager.default.fileExists(atPath: place.file.path) ? .unreadable : .absent
        }
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { return .file(OrderedJSONFile()) }
        guard let file = OrderedJSONFile(data) else { return .unreadable }
        // Laid out as documented, or left alone: an object of events, each a list of objects.
        if let hooks = file["hooks"] {
            guard let events = hooks.members else { return .unreadable }
            for (_, list) in events {
                guard let entries = list.items, entries.allSatisfy({ $0.members != nil }) else { return .unreadable }
                if !place.flat, !entries.allSatisfy({ $0["hooks"] == nil || $0["hooks"]?.items?.allSatisfy { $0.members != nil } == true }) { return .unreadable }
            }
        }
        return .file(file)
    }

    /// One hook as it stands in a file.
    private struct Found: Equatable { let event: String; let matcher: String?; let command: String }

    /// Greenroom's hooks in a file's `hooks` value.
    private static func found(_ hooks: OrderedJSON?, flat: Bool) -> [Found] {
        var out: [Found] = []
        for (event, list) in hooks?.members ?? [] {
            for entry in list.items ?? [] {
                let handlers = flat ? [entry] : (entry["hooks"]?.items ?? [])
                for h in handlers {
                    guard let c = h["command"]?.text, program(of: c) != nil else { continue }
                    out.append(Found(event: event, matcher: flat ? nil : entry["matcher"]?.text, command: c))
                }
            }
        }
        return out
    }

    private static func wanted(_ place: Place) -> [Found] {
        place.specs.map { Found(event: $0.event, matcher: $0.matcher, command: command($0, harness: place.id)) }
    }

    static func state(_ place: Place) -> State {
        switch load(place) {
        case .absent: return .none
        case .unreadable: return .unreadable
        case .file(let file):
            let there = found(file["hooks"], flat: place.flat)
            if there.isEmpty { return .none }
            if let other = there.compactMap({ program(of: $0.command) }).first(where: { !ClaudeConnect.same($0, ClaudeConnect.executable) }) { return .otherCopy(other) }
            let key: (Found) -> String = { "\($0.event)\n\($0.matcher ?? "")\n\($0.command)" }
            return .ours(current: there.map(key).sorted() == wanted(place).map(key).sorted())
        }
    }

    // MARK: Writing

    /// The `hooks` value without Greenroom's hooks (every copy's, or this copy's alone), and with nothing left
    /// behind where they were: a group, or an event, that held only them goes too.
    private static func without(_ hooks: OrderedJSON?, flat: Bool, thisCopyOnly: Bool) -> [(key: String, value: OrderedJSON)] {
        func mine(_ handler: OrderedJSON) -> Bool {
            guard let c = handler["command"]?.text, let p = program(of: c) else { return false }
            return !thisCopyOnly || ClaudeConnect.same(p, ClaudeConnect.executable)
        }
        var out: [(key: String, value: OrderedJSON)] = []
        for (event, list) in hooks?.members ?? [] {
            guard let entries = list.items else { out.append((event, list)); continue }
            var kept: [OrderedJSON] = []
            for entry in entries {
                if flat {
                    if !mine(entry) { kept.append(entry) }
                } else if let handlers = entry["hooks"]?.items, handlers.contains(where: mine) {
                    let rest = handlers.filter { !mine($0) }
                    if !rest.isEmpty { kept.append(.object((entry.members ?? []).map { $0.key == "hooks" ? ($0.key, .array(rest)) : $0 })) }
                } else {
                    kept.append(entry)
                }
            }
            if !kept.isEmpty || entries.isEmpty { out.append((event, .array(kept))) }
        }
        return out
    }

    /// EVENTS with this copy's hooks after whatever each event already runs.
    private static func adding(_ place: Place, to events: [(key: String, value: OrderedJSON)]) -> [(key: String, value: OrderedJSON)] {
        var events = events
        for spec in place.specs {
            let cmd = OrderedJSON.string(command(spec, harness: place.id))
            var entry: [(key: String, value: OrderedJSON)] = []
            if place.flat {
                entry = [("command", cmd)]
            } else {
                if let m = spec.matcher { entry.append(("matcher", .string(m))) }
                entry.append(("hooks", .array([.object([("type", .string("command")), ("command", cmd)])])))
            }
            if let at = events.firstIndex(where: { $0.key == spec.event }) {
                events[at].value = .array((events[at].value.items ?? []) + [.object(entry)])
            } else {
                events.append((spec.event, .array([.object(entry)])))
            }
        }
        return events
    }

    private static func write(_ file: OrderedJSONFile, to place: Place) -> Bool {
        let fm = FileManager.default
        let mode = (try? fm.attributesOfItem(atPath: place.file.path))?[.posixPermissions]
        try? fm.createDirectory(at: place.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Through a symlink (a settings file kept in a dotfiles folder), to the file it names.
        let target = place.file.resolvingSymlinksInPath()
        guard (try? file.data.write(to: target, options: .atomic)) != nil else { return false }
        if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path) }
        return true
    }

    static func unreadableMessage(_ place: Place) -> String {
        "\(place.shown) is not plain JSON that Greenroom can read, so it was left as it is and \(place.name) reports no session status. The details show the hooks to add by hand."
    }

    /// Puts this copy's hooks in, in place of any Greenroom hooks that are there. The message is empty when the
    /// file already held exactly them.
    @discardableResult
    static func install(_ place: Place) -> Result {
        var file: OrderedJSONFile
        switch load(place) {
        case .unreadable: return Result(ok: false, message: unreadableMessage(place))
        case .absent: file = OrderedJSONFile()
        case .file(let f): file = f
        }
        if state(place) == .ours(current: true) { return Result(ok: true, message: "") }
        let events = adding(place, to: without(file["hooks"], flat: place.flat, thisCopyOnly: false))
        if place.flat, file["version"] == nil { file.set("version", .raw("1")) }
        file.set("hooks", .object(events))
        guard write(file, to: place) else { return Result(ok: false, message: "\(place.shown) could not be written, so \(place.name) reports no session status.") }
        guard state(place) == .ours(current: true) else { return Result(ok: false, message: "\(place.shown) was written, but it does not hold Greenroom's hooks.") }
        return Result(ok: true, message: "Session status: hooks written to \(place.shown)." + (trustNote(place).map { " " + $0 } ?? ""))
    }

    /// Takes Greenroom's hooks out: this copy's, or with EVERY any copy's. A file that then holds nothing goes.
    @discardableResult
    static func remove(_ place: Place, every: Bool = false) -> Result {
        guard case .file(var file) = load(place) else { return Result(ok: true, message: "") }
        let before = found(file["hooks"], flat: place.flat)
        guard before.contains(where: { every || ClaudeConnect.same(program(of: $0.command) ?? "", ClaudeConnect.executable) }) else { return Result(ok: true, message: "") }
        let events = without(file["hooks"], flat: place.flat, thisCopyOnly: !every)
        file.set("hooks", events.isEmpty ? nil : .object(events))
        let left = file.members.map(\.key).filter { !(place.flat && $0 == "version") }
        if left.isEmpty {
            guard (try? FileManager.default.removeItem(at: place.file)) != nil else { return Result(ok: false, message: "\(place.shown) could not be removed.") }
        } else {
            guard write(file, to: place) else { return Result(ok: false, message: "\(place.shown) could not be written, so Greenroom's hooks are still in it.") }
        }
        return Result(ok: true, message: "Greenroom's hooks were removed from \(place.shown).")
    }

    // MARK: Words

    /// What the person does once, where the harness asks for it.
    static func trustNote(_ place: Place) -> String? {
        place.id == "codex" ? "Codex runs a new hook only once you trust it: type /hooks in Codex, or open Settings > Hooks in its app." : nil
    }

    /// What connecting writes, said before it does.
    static func display(_ place: Place) -> String {
        var events: [String] = []
        for s in place.specs where !events.contains(s.event) { events.append(s.event) }
        let example = place.specs.first { $0.event.lowercased() == "stop" } ?? place.specs[0]
        return "And adds hooks to \(place.shown) so the sidebar knows when a session is working, waiting or finished (your other hooks, and everything else in the file, are kept). "
            + "For \(ConnectModel.list(events)), each runs a line like:\n\(command(example, harness: place.id))\n"
            + "A hook tells Greenroom the session's id, its folder and the event's name. Never a prompt, a transcript or a file."
            + (trustNote(place).map { "\n" + $0 } ?? "")
    }

    /// The row's line for a connected harness.
    static func words(_ place: Place, _ state: State) -> String {
        switch state {
        case .none: return "No session status yet: Greenroom's hooks are not in \(place.shown)."
        case .ours(true): return "Session status: hooks in \(place.shown)." + (trustNote(place).map { " " + $0 } ?? "")
        case .ours(false): return "The hooks in \(place.shown) are an earlier Greenroom's."
        case .otherCopy(let path): return "The hooks in \(place.shown) run another copy of Greenroom (\(path))."
        case .unreadable: return unreadableMessage(place)
        }
    }

    /// The hooks to paste, for a file Greenroom could not read: the value of the file's "hooks" key.
    static func byHand(_ place: Place) -> String {
        var file = OrderedJSONFile()
        let events = adding(place, to: [])
        if place.flat { file.set("version", .raw("1")) }
        file.set("hooks", .object(events))
        return String(decoding: file.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
