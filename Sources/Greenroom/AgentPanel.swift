import AppKit

/// What agents have done, newest last, for the person at the Mac: shown in a popover from the toolbar.
final class AgentActivity {
    struct Entry { let time: Date; let tool: String; let summary: String; let failed: Bool }
    private(set) var entries: [Entry] = []
    private(set) var client: String?
    var onChange: (() -> Void)?

    func connected(_ name: String) { client = name; onChange?() }

    func add(_ tool: String, _ summary: String, failed: Bool) {
        entries.append(Entry(time: Date(), tool: tool, summary: summary, failed: failed))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        onChange?()
    }
}

final class AgentPanel: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let activity: AgentActivity
    private let tools: AgentTools
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let pause = NSButton(checkboxWithTitle: "Pause the agent", target: nil, action: nil)
    private let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    /// The command that connects Claude Code to this copy of Greenroom.
    static var setupCommand: String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "claude mcp add greenroom -- \"\(exe)\" --mcp"
    }

    init(activity: AgentActivity, tools: AgentTools) {
        self.activity = activity
        self.tools = tools
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

        let stack = NSStackView(views: [status, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for v in [status, scroll, buttons] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        stack.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
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
        table.reloadData()
        if !activity.entries.isEmpty { table.scrollRowToVisible(activity.entries.count - 1) }
    }

    @objc private func togglePause() { tools.paused = pause.state == .on }

    @objc private func copySetup() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentPanel.setupCommand, forType: .string)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { activity.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = activity.entries[row]
        let label = NSTextField(labelWithString: "\(time.string(from: e.time))  \(e.tool)  \(e.summary)")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = e.failed ? .systemRed : .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = e.summary
        return label
    }
}
