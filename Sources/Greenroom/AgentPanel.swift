import AppKit

/// What agents have done, newest last, for the person at the Mac: shown in a popover from the toolbar. One feed per
/// session (by its worktree's path) and one for calls from no session; each entry says which it came from.
final class AgentActivity {
    struct Entry { let time: Date; let tool: String; let summary: String; let failed: Bool; let session: String?; let label: String? }
    static let none = ""
    private(set) var feeds: [String: [Entry]] = [:]
    private(set) var client: String?
    var onChange: (() -> Void)?

    func connected(_ name: String) { client = name; onChange?() }

    func add(_ tool: String, _ summary: String, failed: Bool, session: Session? = nil) {
        let key = session?.worktree.path ?? Self.none
        var feed = feeds[key, default: []]
        feed.append(Entry(time: Date(), tool: tool, summary: summary, failed: failed, session: session?.worktree.path, label: session.map { $0.branch ?? $0.shortHead }))
        if feed.count > 500 { feed.removeFirst(feed.count - 500) }
        feeds[key] = feed
        onChange?()
        if Engine.agentCheck, ProcessInfo.processInfo.environment["GREENROOM_CHECK_FEEDS"] != nil { dumpForCheck() }   // --agent-check only
    }

    /// For scripts/mcp-check.py --sessions: the feeds as JSON in the state folder (only when the check asks).
    private func dumpForCheck() {
        let out = feeds.mapValues { $0.map { ["tool": $0.tool, "summary": $0.summary, "label": $0.label ?? ""] } }
        guard let data = try? JSONSerialization.data(withJSONObject: out) else { return }
        try? data.write(to: Engine.shared.state.appendingPathComponent("agent-feeds-check.json"))
    }

    /// One session's feed (nil: the calls from no session), or every feed merged by time.
    func entries(session: String?, all: Bool) -> [Entry] {
        if all { return feeds.values.flatMap { $0 }.sorted { $0.time < $1.time } }
        return feeds[session ?? Self.none] ?? []
    }
}

final class AgentPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let activity: AgentActivity
    private let tools: AgentTools
    /// The worktree of the session selected in the window (nil: none).
    private let selected: () -> (path: String, label: String)?
    private let scope = NSPopUpButton(frame: .zero, pullsDown: false)
    private var shown: [Entry] = []
    typealias Entry = AgentActivity.Entry
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let pause = NSButton(checkboxWithTitle: "Pause the agent", target: nil, action: nil)
    private let recordSwitch = NSButton(checkboxWithTitle: "Record the agent's screen in this repository", target: nil, action: nil)
    private let recordStatus = NSTextField(wrappingLabelWithString: "")
    private let showRecording = NSButton(title: "Show Recording", target: nil, action: nil)
    private var recordedFile: URL?
    private let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    /// The command that connects Claude Code to this copy of Greenroom.
    static var setupCommand: String { ClaudeConnect.displayCommand() }

    init(activity: AgentActivity, tools: AgentTools, selected: @escaping () -> (path: String, label: String)? = { nil }) {
        self.activity = activity
        self.tools = tools
        self.selected = selected
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        pause.target = self
        pause.action = #selector(togglePause)
        let copy = NSButton(title: "Copy Setup Command", target: self, action: #selector(copySetup))
        copy.bezelStyle = .rounded
        copy.toolTip = AgentPanel.setupCommand
        let buttons = NSStackView(views: [pause, NSView(), copy])
        recordSwitch.target = self
        recordSwitch.action = #selector(toggleRecording)
        recordStatus.font = .systemFont(ofSize: 12)
        recordStatus.textColor = .secondaryLabelColor
        showRecording.target = self
        showRecording.action = #selector(revealRecording)
        showRecording.bezelStyle = .rounded
        let recordRow = NSStackView(views: [recordSwitch, NSView(), showRecording])
        scope.target = self
        scope.action = #selector(scopeChanged)
        let feed = NSStackView(views: [NSTextField(labelWithString: "Showing"), scope])

        let stack = NSStackView(views: [status, feed, scroll, recordRow, recordStatus, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for v in [status, scroll, recordRow, recordStatus, buttons] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 520, height: 430)
        view = stack
        preferredContentSize = stack.frame.size
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        pause.state = tools.paused ? .on : .off
        if let client = activity.client {
            status.stringValue = "\(client) is connected. It sees and drives the simulators in this window; nothing about your apps leaves this Mac through Greenroom."
        } else {
            status.stringValue = "No agent has connected. Copy the setup command and run it in a terminal to give Claude Code these simulators; other MCP clients run the same program with --mcp."
        }
        // "This session" follows the selection in the window; "No session" is calls from folders that are not a worktree.
        let choice = scope.selectedItem?.representedObject as? String ?? "selected"
        let current = selected()
        scope.removeAllItems()
        for (title, key) in [(current.map { "This session (\($0.label))" } ?? "This simulator (in no session)", "selected"), ("All sessions", "all"), ("No session", "none")] {
            scope.addItem(withTitle: title)
            scope.lastItem?.representedObject = key
        }
        if let i = scope.itemArray.firstIndex(where: { $0.representedObject as? String == choice }) { scope.selectItem(at: i) }
        switch scope.selectedItem?.representedObject as? String ?? "selected" {
        case "all": shown = activity.entries(session: nil, all: true)
        case "none": shown = activity.entries(session: nil, all: false)
        default: shown = activity.entries(session: current?.path, all: false)
        }
        refreshRecording(current)
        table.reloadData()
        if !shown.isEmpty { table.scrollRowToVisible(shown.count - 1) }
    }

    /// The agent's recording of the selected session: the workspace switch, and whether one is running or the last file.
    private func refreshRecording(_ current: (path: String, label: String)?) {
        let session = current.flatMap { c in tools.workbench?.sessions.sessions.first { $0.worktree.path == c.path } }
        recordSwitch.isHidden = session == nil
        recordStatus.isHidden = session == nil
        recordedFile = nil
        showRecording.isHidden = true
        guard let session, let sessions = tools.workbench?.sessions else { return }
        let on = sessions.recordsAgent(session)
        recordSwitch.state = on ? .on : .off
        if let r = tools.recording.recording(for: session.worktree.path) {
            recordedFile = r.file
            showRecording.isHidden = false
            recordStatus.stringValue = (r.live ? "Recording the agent's screen now: " : "Last recording: ") + r.file.lastPathComponent
                + ". Kept on this Mac under this build's evidence."
        } else {
            recordStatus.stringValue = on ? "The agent's screen is recorded while it drives this session's simulator (one file per run, kept on this Mac under the build's evidence)."
                                          : "Recording the agent is off for this repository."
        }
    }

    @objc private func toggleRecording() {
        guard let c = selected(), let session = tools.workbench?.sessions.sessions.first(where: { $0.worktree.path == c.path }) else { return }
        tools.workbench?.sessions.setRecordsAgent(recordSwitch.state == .on, for: session)
        refresh()
    }

    @objc private func revealRecording() {
        guard let f = recordedFile else { return }
        let part = URL(fileURLWithPath: f.path + ".part")
        let there = [f, part].first { FileManager.default.fileExists(atPath: $0.path) }
        if let there { NSWorkspace.shared.activateFileViewerSelecting([there]) }
        else { NSWorkspace.shared.open(f.deletingLastPathComponent()) }
    }

    @objc private func scopeChanged() { refresh() }

    @objc private func togglePause() { tools.paused = pause.state == .on }

    @objc private func copySetup() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentPanel.setupCommand, forType: .string)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = shown[row]
        let from = e.label.map { "[\($0)]  " } ?? ""
        let label = NSTextField(labelWithString: "\(time.string(from: e.time))  \(from)\(e.tool)  \(e.summary)")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = e.failed ? .systemRed : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = e.summary
        return label
    }
}
