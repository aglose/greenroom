import AppKit
import SwiftUI

// The Connect screen (docs/AGENT-FIRST-SPEC.md, "Onboarding"): first run is "Connect your agents", then "Give your
// agent something to do". It lists the harnesses found on this Mac, says what connecting each would run or write
// before it does, connects the ticked ones on one button, and then listens for the first agent to call. The same
// list is Settings > Agents. The stage shows it on first run and from File > Connect Agents….

/// What the screen knows about each harness. One for the app: the stage, Settings and the waiting stage read it.
final class ConnectModel: ObservableObject {
    static let shared = ConnectModel()

    struct Row: Identifiable {
        let harness: Harness
        /// nil: not looked at yet.
        var link: Harness.Link?
        var ticked = true
        var busy = false
        var message: String?
        var failed = false
        /// Connected: where its skill goes, and what is there. nil: it has the skill another way, or is not connected.
        var skillPlace: Skills.Place?
        var skill: Skills.State?
        /// Connected: the file its hooks go in, and what is there. nil: it has them another way, or is not connected.
        var hooksPlace: Hooks.Place?
        var hooks: Hooks.State?
        /// Connected with hooks that are in no file of Greenroom's: where they are (Claude Code's plugin).
        var hooksNote: String?
        var id: String { harness.id }
    }

    @Published private(set) var rows: [Row] = Harnesses.connectable.map { Row(harness: $0) }
    /// Found here, with no connector: the person adds the stdio command there.
    @Published private(set) var byHand: [String] = []
    /// Found here, and connected through the harness they run.
    @Published private(set) var hosts: [String] = []
    @Published private(set) var working = false
    /// The skill in the folder most harnesses read (`~/.agents/skills`), for an agent added by hand.
    @Published private(set) var sharedSkill: Skills.State = .none
    @Published private(set) var sharedMessage: String?
    @Published private(set) var sharedFailed = false
    /// The `greenroom` command on the PATH. nil: not looked at yet.
    @Published private(set) var command: CommandLink.State?
    @Published private(set) var commandMessage: String?
    @Published private(set) var commandFailed = false
    /// The Debug copy: Claude Code's entry for every project, left by an earlier build (see `ClaudeConnect.repositoryOnly`).
    @Published private(set) var debugEntry: ClaudeConnect.State?
    @Published private(set) var debugMessage: String?
    @Published private(set) var debugFailed = false

    /// Called on the main thread when what is connected changed.
    var onChange: (() -> Void)?

    private static let inCheck = CommandLine.arguments.contains { $0.hasPrefix("--") && $0.hasSuffix("-check") }
    /// Whether the harnesses' programs and files are looked at. Off in a check, which turns it on once its
    /// stand-ins are in place: the person's own `claude` is never run by one.
    static var lookups = !inCheck

    /// One harness program at a time.
    private let queue = DispatchQueue(label: "greenroom-connect", qos: .userInitiated)

    // MARK: First run

    private static var seenFile: URL { Engine.shared.state.appendingPathComponent("connect-seen") }
    private static var seenInMemory = false
    /// Whether the first-run screens were finished or left: kept in the state folder. A check on the person's own
    /// state folder keeps it in memory.
    static var firstRunDone: Bool {
        get { seenInMemory || FileManager.default.fileExists(atPath: seenFile.path) }
        set {
            seenInMemory = newValue
            if inCheck && !Engine.agentCheck { return }
            if newValue { FileManager.default.createFile(atPath: seenFile.path, contents: Data()) } else { try? FileManager.default.removeItem(at: seenFile) }
        }
    }

    // MARK: Reading

    /// The Debug copy lists no harness: it is reachable from the Greenroom repository alone.
    var repositoryOnly: Bool { ClaudeConnect.repositoryOnly }

    /// Ticked and waiting to be connected.
    var pending: [Row] { repositoryOnly ? [] : rows.filter { $0.ticked && $0.link == .notConnected } }
    var connectedNames: [String] { repositoryOnly ? [] : rows.filter { $0.link?.isConnected == true }.map(\.harness.name) }

    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// The name an MCP client gives for itself, as the person knows the harness.
    static func displayName(client: String) -> String {
        let c = client.lowercased()
        if c.contains("claude") { return "Claude Code" }
        if c.contains("codex") { return "Codex" }
        if c.contains("cursor") { return "Cursor" }
        if c.contains("antigravity") { return "Antigravity" }
        if c.contains("gemini") { return "Gemini CLI" }
        if c.contains("opencode") { return "opencode" }
        if c.contains("copilot") || c.contains("visual studio code") || c == "vscode" { return "Copilot" }
        if c == "zed" { return "Zed" }
        return client
    }

    // MARK: Looking and connecting

    /// Looks at every harness again. `then` runs on the main thread when all have answered.
    func refresh(then: (() -> Void)? = nil) {
        guard Self.lookups else { then?(); return }
        queue.async {
            if ClaudeConnect.repositoryOnly {
                let entry = ClaudeConnect.status()
                DispatchQueue.main.async { self.debugEntry = entry; self.onChange?(); then?() }
                return
            }
            for h in Harnesses.connectable {
                let link = h.status()
                // Looking makes no skill file (the row offers that). It keeps the ones Greenroom wrote true: this
                // harness's name on its own, and off them once it is no longer connected.
                Harnesses.settleSkill(h, link, creating: false)
                Harnesses.settleHooks(h, link, creating: false)   // the same for its hooks
                let skill = Self.skill(of: h, link), hooks = Self.hooks(of: h, link)
                DispatchQueue.main.async {
                    self.update(h.id) { $0.link = link; $0.skillPlace = skill.place; $0.skill = skill.state; $0.hooksPlace = hooks.place; $0.hooks = hooks.state; $0.hooksNote = hooks.note }
                }
            }
            for place in Skills.Place.allCases { Skills.refresh(place) }
            let also = Harnesses.alsoFound()
            let shared = Skills.state(.agents), command = CommandLink.state()
            DispatchQueue.main.async {
                self.byHand = also.byHand; self.hosts = also.hosts
                self.sharedSkill = shared; self.command = command
                self.onChange?(); then?()
            }
        }
    }

    /// A connected harness's skill: where it goes and what is there.
    private static func skill(of h: Harness, _ link: Harness.Link) -> (place: Skills.Place?, state: Skills.State?) {
        guard link.isConnected, let place = h.skill() else { return (nil, nil) }
        return (place, Skills.state(place))
    }

    /// A connected harness's hooks: the file they go in and what is there, or where else they are.
    private static func hooks(of h: Harness, _ link: Harness.Link) -> (place: Hooks.Place?, state: Hooks.State?, note: String?) {
        guard link.isConnected, !ClaudeConnect.repositoryOnly else { return (nil, nil, nil) }
        guard let place = h.hooks() else { return (nil, nil, "Session status: the plugin's hooks.") }
        return (place, Hooks.state(place), nil)
    }

    private func update(_ id: String, _ change: (inout Row) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        change(&rows[i])
    }

    func toggle(_ id: String) { update(id) { $0.ticked.toggle() } }

    private func act(_ ids: [String], _ work: @escaping (Harness) -> Harness.Result, then: (() -> Void)? = nil) {
        guard Self.lookups, !working else { then?(); return }
        working = true
        for id in ids { update(id) { $0.busy = true; $0.message = nil } }
        queue.async {
            for id in ids {
                guard let h = Harnesses.connectable.first(where: { $0.id == id }) else { continue }
                let r = work(h)
                let link = h.status()
                // The skill follows the connection: there once the harness is connected, gone with its last one.
                let followed = Harnesses.settleSkill(h, link)
                // So do its hooks, which are what tells the sidebar a session is working, waiting or finished.
                let hooked = Harnesses.settleHooks(h, link)
                let message = [r.message, followed?.message ?? "", hooked?.message ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
                let skill = Self.skill(of: h, link), hooks = Self.hooks(of: h, link)
                DispatchQueue.main.async {
                    self.update(id) {
                        $0.busy = false; $0.link = link; $0.message = message; $0.failed = !r.ok; $0.skillPlace = skill.place; $0.skill = skill.state
                        $0.hooksPlace = hooks.place; $0.hooks = hooks.state; $0.hooksNote = hooks.note
                    }
                }
            }
            let shared = Skills.state(.agents)
            DispatchQueue.main.async {
                // Harnesses that share a skill file see what the others did to it.
                for row in self.rows where row.skillPlace != nil && !ids.contains(row.id) { self.update(row.id) { $0.skill = Skills.state($0.skillPlace ?? .agents) } }
                self.working = false; self.sharedSkill = shared; self.onChange?(); then?()
            }
        }
    }

    /// The one button: connects every ticked harness that is found and not connected, one after the other.
    func connectTicked(then: (() -> Void)? = nil) { act(pending.map(\.id), { $0.connect() }, then: then) }
    func connect(_ id: String, then: (() -> Void)? = nil) { act([id], { $0.connect() }, then: then) }
    func replace(_ id: String, then: (() -> Void)? = nil) { act([id], { $0.replace() }, then: then) }
    func disconnect(_ id: String, then: (() -> Void)? = nil) { act([id], { $0.disconnect() }, then: then) }
    /// For a harness connected before Greenroom wrote skills, or one whose skill was deleted: settling writes it.
    func addSkill(_ id: String, then: (() -> Void)? = nil) { act([id], { _ in Harness.Result(ok: true, message: "") }, then: then) }
    /// The same for its hooks: a harness connected before Greenroom wrote hooks, or one whose hooks were taken out.
    func addHooks(_ id: String, then: (() -> Void)? = nil) { addSkill(id, then: then) }

    /// One thing beside the harnesses (the skill for an agent added by hand, the command), then what is there now.
    private func aside(_ work: @escaping () -> (ok: Bool, message: String), said: @escaping (ConnectModel, Bool, String) -> Void, then: (() -> Void)?) {
        guard Self.lookups, !working, !repositoryOnly else { then?(); return }
        working = true
        queue.async {
            let r = work()
            let shared = Skills.state(.agents), command = CommandLink.state()
            DispatchQueue.main.async {
                for row in self.rows where row.skillPlace != nil { self.update(row.id) { $0.skill = Skills.state($0.skillPlace ?? .agents) } }
                self.working = false; self.sharedSkill = shared; self.command = command
                said(self, r.ok, r.message)
                then?()
            }
        }
    }

    /// The skill for an agent the person added by hand: "you" asked for it, so it stays when a harness is disconnected.
    func addSharedSkill(then: (() -> Void)? = nil) {
        aside({
            let r = Skills.install(.agents, for: "you")
            return (r.ok, !r.ok ? r.message : r.message.isEmpty ? "Already there: \(Skills.Place.agents.shown)." : "Written: \(Skills.Place.agents.shown).")
        }, said: { $0.sharedFailed = !$1; $0.sharedMessage = $2 }, then: then)
    }
    func removeSharedSkill(then: (() -> Void)? = nil) {
        aside({ let r = Skills.remove(.agents, for: "you"); return (r.ok, r.message.replacingOccurrences(of: "Its skill", with: "The skill")) },
              said: { $0.sharedFailed = !$1; $0.sharedMessage = $2 }, then: then)
    }
    func addCommand(then: (() -> Void)? = nil) {
        aside({ let r = CommandLink.install(); return (r.ok, r.message) }, said: { $0.commandFailed = !$1; $0.commandMessage = $2 }, then: then)
    }
    func removeCommand(then: (() -> Void)? = nil) {
        aside({ let r = CommandLink.remove(); return (r.ok, r.message) }, said: { $0.commandFailed = !$1; $0.commandMessage = $2 }, then: then)
    }

    /// The Debug copy: takes its entry out of every project (`claude mcp remove --scope user greenroom-debug`).
    func removeDebugEntry(then: (() -> Void)? = nil) {
        guard Self.lookups, !working else { then?(); return }
        working = true
        queue.async {
            let o = ClaudeConnect.disconnect()
            let entry = ClaudeConnect.status()
            DispatchQueue.main.async {
                self.working = false
                self.debugEntry = entry
                self.debugMessage = o.message
                self.debugFailed = !o.ok
                then?()
            }
        }
    }
}

/// Where the first-run screens are, and what the listening step has heard.
final class ConnectFlow: ObservableObject {
    @Published var step = 1
    /// 0: the person's own project. 1: the sample app.
    @Published var kind = 0
    @Published var client: String?
    @Published var lines: [String] = []
    var onDone: (() -> Void)?
    var onRunAPK: (() -> Void)?

    /// What the person pastes into their agent for the sample app, which needs no project and no build.
    static let samplePrompt = "Use Greenroom to launch its sample app (launch with apk \"sample\"). Tap Add twice and check that it says \"FAB clicks: 2\", then open Trips and tell me which trips it lists."
    var prompt: String { kind == 0 ? WaitingStage.prompt : Self.samplePrompt }

    static func heard(client: String?) -> String {
        guard let client, !client.isEmpty else { return "Listening for an agent…" }
        return "\(ConnectModel.displayName(client: client)) is connected"
    }
}

// MARK: - The list of harnesses

/// One line of monospaced text that copies, however many lines it has.
private struct CopyBox: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(SettingsTheme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(copied ? SettingsTheme.accent : SettingsTheme.ink)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.09)))
            .accessibilityLabel("Copy")
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SettingsTheme.wellFill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(color.opacity(0.3), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

private struct SmallButton: View {
    let title: String
    var accent = false
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(accent ? SettingsTheme.onAccent : SettingsTheme.ink)
            .padding(.horizontal, 10).padding(.vertical, 4.5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(accent ? SettingsTheme.accent : Color.white.opacity(0.09)))
    }
}

private struct LinkButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(SettingsTheme.accent)
    }
}

/// The harnesses, each with what connecting does and where it stands. The Debug copy shows what it is instead.
struct HarnessList: View {
    @ObservedObject var model: ConnectModel
    /// On the first-run screen a found harness has a tick, and one button connects the ticked. In Settings each
    /// row has a button of its own.
    var ticks = true
    @State private var open: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.repositoryOnly {
                debugCard
            } else {
                ForEach(model.rows) { row in
                    rowView(row)
                    Divider().overlay(SettingsTheme.stroke)
                }
                otherRow
                Divider().overlay(SettingsTheme.stroke)
                commandRow
            }
        }
    }

    private func subtitle(_ row: ConnectModel.Row) -> String {
        switch row.link {
        case nil: return ConnectModel.lookups ? "Looking…" : "Not looked at"
        case .notInstalled: return "Not found on this Mac"
        case .notConnected: return "Adds Greenroom's tools, a skill and session status"
        case .connected(let how): return "Connected " + how
        case .otherCopy(let path): return "Its \(ClaudeConnect.serverName) server runs another copy of Greenroom (\(path))"
        case .unknown(let why): return why
        }
    }

    @ViewBuilder private func state(_ row: ConnectModel.Row) -> some View {
        if row.busy {
            Text("Working…").font(.system(size: 12, weight: .medium)).foregroundStyle(SettingsTheme.mute)
        } else {
            switch row.link {
            case .connected:
                Text("✓ Connected").font(.system(size: 12, weight: .semibold)).foregroundStyle(SettingsTheme.accent)
            case .otherCopy:
                SmallButton(title: "Reconnect", accent: true) { model.replace(row.id) }.disabled(model.working)
            case .notConnected:
                if ticks {
                    Text("Found").font(.system(size: 12, weight: .medium)).foregroundStyle(SettingsTheme.mute)
                } else {
                    SmallButton(title: "Connect", accent: true) { model.connect(row.id) }.disabled(model.working)
                }
            case .unknown:
                SmallButton(title: "Connect") { model.connect(row.id) }.disabled(model.working)
            case nil, .notInstalled:
                EmptyView()
            }
        }
    }

    private func rowView(_ row: ConnectModel.Row) -> some View {
        let off = row.link == .notInstalled
        let warn: Bool = { if case .otherCopy = row.link { return true }; if case .unknown = row.link { return true }; return false }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                if ticks {
                    Toggle("", isOn: Binding(get: { row.ticked && row.link == .notConnected }, set: { _ in model.toggle(row.id) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(row.link != .notConnected || model.working)
                        .opacity(row.link == .notConnected ? 1 : 0)
                        .accessibilityLabel("Connect \(row.harness.name)")
                }
                Badge(text: row.harness.badge, color: Color(nsColor: row.harness.color))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.harness.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsTheme.ink)
                    HStack(spacing: 6) {
                        Text(subtitle(row))
                            .font(.system(size: 11.5))
                            .foregroundStyle(warn ? SettingsTheme.warning : SettingsTheme.mute)
                            .fixedSize(horizontal: false, vertical: true)
                        if !off, row.link != nil {
                            LinkButton(title: open == row.id ? "hide" : (row.link?.isConnected == true ? "details" : "what this runs")) { open = open == row.id ? nil : row.id }
                        }
                    }
                }
                Spacer(minLength: 8)
                state(row)
            }
            if open == row.id {
                CopyBox(text: row.harness.how())
                if let place = row.skillPlace, let skill = row.skill {
                    HStack(spacing: 8) {
                        Text(Skills.words(place, skill))
                            .font(.system(size: 11.5)).foregroundStyle(skill == .theirs ? SettingsTheme.warning : SettingsTheme.mute)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if skill == .none { SmallButton(title: "Add the Skill") { model.addSkill(row.id) }.disabled(model.working) }
                    }
                }
                if let place = row.hooksPlace, let hooks = row.hooks {
                    HStack(spacing: 8) {
                        Text(Hooks.words(place, hooks))
                            .font(.system(size: 11.5)).foregroundStyle(hooks == .unreadable ? SettingsTheme.warning : SettingsTheme.mute)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if hooks == .none { SmallButton(title: "Add the Hooks") { model.addHooks(row.id) }.disabled(model.working) }
                    }
                    if hooks == .unreadable { CopyBox(text: Hooks.byHand(place)) }
                } else if let note = row.hooksNote {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(SettingsTheme.mute)
                }
                if row.link?.isConnected == true || { if case .otherCopy = row.link { return true }; return false }() {
                    SmallButton(title: "Disconnect") { model.disconnect(row.id) }.disabled(model.working)
                }
            }
            // On the first-run screen a connection that worked needs no words of its own: the row says Connected.
            if let message = row.message, row.failed || !ticks || row.link?.isConnected != true {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(row.failed ? SettingsTheme.record : SettingsTheme.accent)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .opacity(off ? 0.45 : 1)
    }

    private var otherRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                if ticks { Toggle("", isOn: .constant(false)).toggleStyle(.checkbox).labelsHidden().opacity(0).accessibilityHidden(true) }
                Badge(text: "···", color: SettingsTheme.mute)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Another agent").font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsTheme.ink)
                    Text(model.byHand.isEmpty ? "Any MCP client can run Greenroom as a stdio server" : "\(ConnectModel.list(model.byHand)) \(model.byHand.count == 1 ? "is" : "are") on this Mac: add Greenroom there as a stdio server")
                        .font(.system(size: 11.5)).foregroundStyle(SettingsTheme.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                LinkButton(title: open == "other" ? "hide" : "show the command") { open = open == "other" ? nil : "other" }
            }
            if open == "other" {
                CopyBox(text: Harnesses.stdioCommand)
                CopyBox(text: Harnesses.stdioJSON)
                sharedSkill
            }
            if let message = model.sharedMessage {
                Text(message).font(.system(size: 11.5)).foregroundStyle(model.sharedFailed ? SettingsTheme.record : SettingsTheme.accent)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !model.hosts.isEmpty {
                Text("\(ConnectModel.list(model.hosts)) \(model.hosts.count == 1 ? "runs" : "run") Claude Code and Codex, so \(model.hosts.count == 1 ? "it is" : "they are") connected through them.")
                    .font(.system(size: 11.5)).foregroundStyle(SettingsTheme.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
    }

    /// The skill for an agent added by hand, in the folder most harnesses read.
    private var sharedSkill: some View {
        let place = Skills.Place.agents
        let asked: [String] = { if case .ours(let names, _) = model.sharedSkill { return names }; return [] }()
        let words: String = {
            switch model.sharedSkill {
            case .none: return "A skill teaches the agent Greenroom's loop. Greenroom can write it to \(place.shown), which Codex, Cursor, Copilot CLI, opencode, Gemini CLI, Goose and Amp read."
            case .theirs: return Skills.words(place, .theirs) + ", so it is left alone."
            case .ours: return Skills.words(place, model.sharedSkill) + ", there for \(ConnectModel.list(asked.map(Skills.asker)))."
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(words).font(.system(size: 11.5)).foregroundStyle(model.sharedSkill == .theirs ? SettingsTheme.warning : SettingsTheme.mute)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            switch model.sharedSkill {
            case .none: SmallButton(title: "Add the Skill") { model.addSharedSkill() }.disabled(model.working)
            case .ours where asked.contains("you"): SmallButton(title: "Remove It") { model.removeSharedSkill() }.disabled(model.working)
            // There for a connected harness, and gone when that one is disconnected unless the person asks for it too.
            case .ours: SmallButton(title: "Keep It") { model.addSharedSkill() }.disabled(model.working)
            case .theirs: EmptyView()
            }
        }
    }

    /// The `greenroom` command: the same tools from a shell.
    private var commandRow: some View {
        let state = model.command
        let warn: Bool = { switch state { case .otherCopy, .taken: return true; default: return false } }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                if ticks { Toggle("", isOn: .constant(false)).toggleStyle(.checkbox).labelsHidden().opacity(0).accessibilityHidden(true) }
                Badge(text: ">_", color: SettingsTheme.mute)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The greenroom command").font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsTheme.ink)
                    HStack(spacing: 6) {
                        Text(state.map(CommandLink.words) ?? (ConnectModel.lookups ? "Looking…" : "Not looked at"))
                            .font(.system(size: 11.5)).foregroundStyle(warn ? SettingsTheme.warning : SettingsTheme.mute)
                            .fixedSize(horizontal: false, vertical: true)
                        if let state, CommandLink.script != nil {
                            LinkButton(title: open == "command" ? "hide" : ({ if case .installed = state { return "details" }; return "what this runs" }())) { open = open == "command" ? nil : "command" }
                        }
                    }
                }
                Spacer(minLength: 8)
                switch state {
                case .installed: Text("✓ Added").font(.system(size: 12, weight: .semibold)).foregroundStyle(SettingsTheme.accent)
                case .available: SmallButton(title: "Add", accent: !ticks) { model.addCommand() }.disabled(model.working)
                case .otherCopy: SmallButton(title: "Point It Here", accent: true) { model.addCommand() }.disabled(model.working)
                case .taken, .unavailable, nil: EmptyView()
                }
            }
            if open == "command", let state {
                CopyBox(text: CommandLink.displayCommand(state))
                Text("greenroom tools lists what it can do; greenroom help TOOL gives one tool's arguments. It is a link to a script inside this app, so it goes away with the app.")
                    .font(.system(size: 11.5)).foregroundStyle(SettingsTheme.mute).fixedSize(horizontal: false, vertical: true)
                if case .installed = state { SmallButton(title: "Remove") { model.removeCommand() }.disabled(model.working) }
            }
            if let message = model.commandMessage {
                Text(message).font(.system(size: 11.5)).foregroundStyle(model.commandFailed ? SettingsTheme.record : SettingsTheme.accent)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
    }

    /// The Debug copy: what it is, and its entry for every project if an earlier build left one.
    private var debugCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Badge(text: "DBG", color: Color(nsColor: Variant.debugColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Greenroom Debug is for developing Greenroom itself").font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsTheme.ink)
                    Text("It is not added to every project. The Greenroom repository registers it in its .mcp.json, so agents working in that repository or one of its worktrees have it, and no others. To test an Android app, connect the release copy of Greenroom.")
                        .font(.system(size: 11.5)).foregroundStyle(SettingsTheme.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch model.debugEntry {
            case nil:
                Text(ConnectModel.lookups ? "Looking at Claude Code…" : "Claude Code was not looked at.").font(.system(size: 11.5)).foregroundStyle(SettingsTheme.mute)
            case .connected, .otherCopy:
                Text("Claude Code also has a \(ClaudeConnect.serverName) entry for every project, from an earlier build. An agent working on another app can pick it by mistake. Removing it runs:")
                    .font(.system(size: 11.5)).foregroundStyle(SettingsTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                CopyBox(text: "claude " + ClaudeConnect.removeArguments.joined(separator: " "))
                SmallButton(title: model.working ? "Working…" : "Remove It", accent: true) { model.removeDebugEntry() }.disabled(model.working)
            case .notConnected:
                Text("✓ Claude Code has no \(ClaudeConnect.serverName) entry for every project.").font(.system(size: 11.5, weight: .medium)).foregroundStyle(SettingsTheme.accent)
            case .missing:
                Text("Claude Code's claude program was not found on your PATH, so its entries were not looked at.").font(.system(size: 11.5)).foregroundStyle(SettingsTheme.mute)
            case .unknown(let why):
                Text(why).font(.system(size: 11.5)).foregroundStyle(SettingsTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.debugMessage {
                Text(message).font(.system(size: 11.5)).foregroundStyle(model.debugFailed ? SettingsTheme.record : SettingsTheme.accent)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - The two first-run screens

struct ConnectFlowView: View {
    @ObservedObject var model: ConnectModel
    @ObservedObject var flow: ConnectFlow
    @State private var copied = false

    var body: some View {
        GeometryReader { area in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    sheet
                    HStack(spacing: 6) {
                        Text("Only want to run an APK?").font(.system(size: 12)).foregroundStyle(SettingsTheme.mute)
                        LinkButton(title: "Run one yourself…  ⌘O") { flow.onRunAPK?() }
                    }
                }
                .padding(.vertical, 48)   // clear of the bar that says what the agent is doing
                .frame(maxWidth: .infinity, minHeight: area.size.height)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                trail("1", "Connect", on: flow.step == 1, done: flow.step > 1)
                Rectangle().fill(SettingsTheme.stroke).frame(width: 22, height: 1)
                trail("2", "First task", on: flow.step == 2, done: false)
                Spacer()
                Button { flow.onDone?() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(SettingsTheme.mute)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                    .accessibilityLabel("Close")
                    .help("Close (Esc)")
            }
            if flow.step == 1 { connect } else { task }
        }
        .padding(26)
        .frame(width: 620, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(nsColor: Design.stage).opacity(0.94)))
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
    }

    private func trail(_ n: String, _ title: String, on: Bool, done: Bool) -> some View {
        HStack(spacing: 6) {
            Text(done ? "✓" : n)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(on || done ? SettingsTheme.onAccent : SettingsTheme.mute)
                .frame(width: 18, height: 18)
                .background(Circle().fill(on || done ? SettingsTheme.accent : Color.white.opacity(0.09)))
            Text(title).font(.system(size: 12, weight: on ? .semibold : .medium)).foregroundStyle(on ? SettingsTheme.ink : SettingsTheme.mute)
        }
        .accessibilityElement(children: .combine)
    }

    private func heading(_ title: String, _ lede: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(SettingsTheme.ink)
            Text(lede).font(.system(size: 13.5)).foregroundStyle(SettingsTheme.mute).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(SettingsTheme.onAccent)
            .padding(.horizontal, 16).padding(.vertical, 7.5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(SettingsTheme.accent))
    }

    /// After the button: what the person does next for the connection to take.
    private var connectedNote: String? {
        let fresh = model.rows.filter { $0.message != nil && !$0.failed && $0.link?.isConnected == true }
        guard !fresh.isEmpty else { return nil }
        return "Start a new session in \(fresh.count == 1 ? fresh[0].harness.name : "each agent"): it takes up Greenroom's tools when it starts."
            + (fresh.contains { $0.id == "cursor" } ? " Cursor may ask you to enable the server under Settings > MCP." : "")
    }

    // Step 1.
    private var connect: some View {
        let pending = model.pending.count
        return VStack(alignment: .leading, spacing: 14) {
            heading("Connect your agents",
                    "Greenroom runs the Android app your agent is working on, so you can watch it, check it and steer it. Agents bring the work here.")
            HarnessList(model: model)
                .padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SettingsTheme.cardFill))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
            if let note = connectedNote {
                Text(note).font(.system(size: 12)).foregroundStyle(SettingsTheme.mute).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if pending > 0 {
                    primary(model.working ? "Connecting…" : "Connect \(pending) agent\(pending == 1 ? "" : "s")") { model.connectTicked() }
                        .disabled(model.working)
                    LinkButton(title: "Continue without") { flow.step = 2 }
                } else {
                    primary("Continue") { flow.step = 2 }.disabled(model.working)
                }
                Spacer()
            }
        }
    }

    // Step 2.
    private var task: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Give your agent something to do",
                    "Paste this into an agent you connected. Greenroom opens the app the moment the agent launches it.")
            HStack(spacing: 2) {
                kindTab("In my project", 0)
                kindTab("With the sample app", 1)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.wellFill))
            CopyBox(text: flow.prompt)
            Text(flow.kind == 0 ? "Start the agent in your app's repository. Its first call adds the repository to Greenroom." : "Needs no project and no build: the sample app comes with Greenroom.")
                .font(.system(size: 11.5)).foregroundStyle(SettingsTheme.mute)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(flow.client == nil ? SettingsTheme.mute : SettingsTheme.accent).frame(width: 8, height: 8)
                    Text(ConnectFlow.heard(client: flow.client)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SettingsTheme.ink)
                }
                ForEach(Array(flow.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(SettingsTheme.mute).lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SettingsTheme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
            HStack(spacing: 12) {
                primary("Done") { flow.onDone?() }
                LinkButton(title: "Back") { flow.step = 1 }
                Spacer()
            }
        }
    }

    private func kindTab(_ title: String, _ index: Int) -> some View {
        Button(title) { flow.kind = index }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(flow.kind == index ? SettingsTheme.ink : SettingsTheme.mute)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(flow.kind == index ? Color.white.opacity(0.14) : Color.clear))
            .accessibilityAddTraits(flow.kind == index ? .isSelected : [])
    }
}

/// The Connect screen on the stage: it takes the stage as the APK screen does, with its own floor.
final class ConnectStage: NSView {
    let flow = ConnectFlow()

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        let floor = StageBackground()
        let host = NSHostingView(rootView: ConnectFlowView(model: .shared, flow: flow))
        for v in [floor, host] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
                v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { flow.onDone?() }
}
