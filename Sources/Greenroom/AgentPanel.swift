import AppKit

/// What agents have done, newest last, for the person at the Mac: shown in the Agent right drawer. One feed per
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
    private let glass = GlassView(radius: 18)
    private let statusDot = NSView()
    private let statusCard = NSView()
    private let clientTitle = NSTextField(labelWithString: "No agent connected")
    private let clientSubtitle = NSTextField(wrappingLabelWithString: "")
    private var pauseButton: GlassButton!
    private var copyButton: GlassButton!
    private let scope = NSPopUpButton(frame: .zero, pullsDown: false)
    private var shown: [Entry] = []
    typealias Entry = AgentActivity.Entry
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Tool calls appear here as the agent works.")
    private let recordBar = NSView()
    private var recordToggle: GlassButton!
    private var revealButton: GlassButton!
    private let recordStatus = NSTextField(wrappingLabelWithString: "")
    private var recordedFile: URL?
    private let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    /// Called when the close button is clicked.
    var onClose: (() -> Void)?
    /// Reports a short status message to the window (text, isProblem).
    var onSay: ((String, Bool) -> Void)?

    /// The command that connects Claude Code to this copy of Greenroom. The Debug copy is never added to every
    /// project (its repository's .mcp.json registers it), so it gives the plain stdio command.
    static var setupCommand: String { ClaudeConnect.repositoryOnly ? Harnesses.stdioCommand : ClaudeConnect.displayCommand() }

    init(activity: AgentActivity, tools: AgentTools, selected: @escaping () -> (path: String, label: String)? = { nil }) {
        self.activity = activity
        self.tools = tools
        self.selected = selected
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: .darkAqua)

        glass.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(glass)

        // Header row: "Agent" title, live status dot, spacer, close button.
        let title = NSTextField(labelWithString: "Agent")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Design.ink

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let close = GlassButton(symbol: "xmark", label: "Close Agent panel", target: self, action: #selector(closePressed))
        let header = NSStackView(views: [title, statusDot, headerSpacer, close])
        header.alignment = .centerY
        header.spacing = 8

        // Connection status card.
        buildStatusCard()

        // Scope row.
        let showingLabel = NSTextField(labelWithString: "Showing")
        showingLabel.font = .systemFont(ofSize: 12)
        showingLabel.textColor = Design.mute
        scope.controlSize = .small
        scope.target = self
        scope.action = #selector(scopeChanged)
        let scopeRow = NSStackView(views: [showingLabel, scope])
        scopeRow.alignment = .centerY
        scopeRow.spacing = 8

        // Tool-call timeline list.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 46
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = Design.mute
        emptyLabel.alignment = .center

        // Footer recording bar.
        buildRecordBar()

        for v in [header, statusCard, scopeRow, scroll, emptyLabel, recordBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: root.topAnchor),
            glass.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            statusCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            statusCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            statusCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            scopeRow.topAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: 10),
            scopeRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            scopeRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: scopeRow.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: recordBar.topAnchor, constant: -10),

            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            recordBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            recordBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            recordBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        view = root
        refresh()
    }

    private func buildStatusCard() {
        statusCard.wantsLayer = true
        statusCard.layer?.cornerRadius = 12
        statusCard.layer?.cornerCurve = .continuous
        statusCard.layer?.borderWidth = 1

        clientTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        clientTitle.textColor = Design.ink
        clientTitle.lineBreakMode = .byTruncatingTail

        clientSubtitle.font = .systemFont(ofSize: 11.5)
        clientSubtitle.textColor = Design.mute
        clientSubtitle.maximumNumberOfLines = 3

        pauseButton = GlassButton(symbol: "pause.fill", title: "Pause", label: "Pause or resume the agent", style: .well, target: self, action: #selector(togglePause))
        pauseButton.font = .systemFont(ofSize: 12, weight: .medium)
        pauseButton.heightAnchor.constraint(equalToConstant: 28).isActive = true

        copyButton = GlassButton(symbol: "doc.on.doc", title: "Copy Setup", label: "Copy MCP setup command", style: .well, target: self, action: #selector(copySetup))
        copyButton.font = .systemFont(ofSize: 12, weight: .medium)
        copyButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        copyButton.toolTip = AgentPanel.setupCommand

        let actions = NSStackView(views: [pauseButton, copyButton])
        actions.distribution = .fillEqually
        actions.spacing = 8

        let stack = NSStackView(views: [clientTitle, clientSubtitle, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusCard.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: statusCard.topAnchor),
            stack.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor),
            clientTitle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            clientSubtitle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
    }

    private func buildRecordBar() {
        recordBar.wantsLayer = true
        recordBar.layer?.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
        recordBar.layer?.cornerRadius = 12
        recordBar.layer?.cornerCurve = .continuous
        recordBar.layer?.borderWidth = 1
        recordBar.layer?.borderColor = Design.stroke.cgColor

        recordToggle = GlassButton(symbol: "record.circle", title: "Record agent", label: "Record the agent's screen in this repository", style: .record, target: self, action: #selector(toggleRecording))
        recordToggle.font = .systemFont(ofSize: 12, weight: .medium)
        recordToggle.heightAnchor.constraint(equalToConstant: 26).isActive = true

        revealButton = GlassButton(symbol: "folder", title: "Reveal MP4", label: "Reveal recorded MP4 in Finder", style: .well, target: self, action: #selector(revealRecording))
        revealButton.font = .systemFont(ofSize: 12, weight: .medium)
        revealButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        revealButton.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [recordToggle, spacer, revealButton])
        row.alignment = .centerY
        row.spacing = 8

        recordStatus.font = .systemFont(ofSize: 11)
        recordStatus.textColor = Design.mute
        recordStatus.maximumNumberOfLines = 2

        let stack = NSStackView(views: [row, recordStatus])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        recordBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: recordBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: recordBar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: recordBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: recordBar.trailingAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            recordStatus.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
    }

    // MARK: Refresh

    func refresh() {
        guard isViewLoaded else { return }

        if let client = activity.client {
            clientTitle.stringValue = client
            clientSubtitle.stringValue = tools.paused
                ? "Agent is paused. Resume to allow tool calls on these simulators."
                : "Sees and drives the simulators in this window locally; nothing leaves this Mac."
            statusCard.layer?.backgroundColor = Design.agent.withAlphaComponent(0.16).cgColor
            statusCard.layer?.borderColor = Design.agent.withAlphaComponent(0.45).cgColor
            statusDot.layer?.backgroundColor = (tools.paused ? Design.warning : Design.accent).cgColor
        } else {
            clientTitle.stringValue = "No agent connected"
            clientSubtitle.stringValue = "Connect one in File > Connect Agents…, or copy the setup command for any other MCP client."
            statusCard.layer?.backgroundColor = Design.well.cgColor
            statusCard.layer?.borderColor = Design.stroke.cgColor
            statusDot.layer?.backgroundColor = (tools.paused ? Design.warning : Design.mute.withAlphaComponent(0.45)).cgColor
        }

        if tools.paused {
            pauseButton.title = "Resume"
            pauseButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Resume")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            pauseButton.style = .accent
            pauseButton.isOn = true
        } else {
            pauseButton.title = "Pause"
            pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            pauseButton.style = .well
            pauseButton.isOn = false
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

        emptyLabel.isHidden = !shown.isEmpty
        refreshRecording(current)
        table.reloadData()
        if !shown.isEmpty { table.scrollRowToVisible(shown.count - 1) }
    }

    /// The agent's recording of the selected session: the workspace switch, and whether one is running or the last file.
    private func refreshRecording(_ current: (path: String, label: String)?) {
        let session = current.flatMap { c in tools.workbench?.sessions.sessions.first { $0.worktree.path == c.path } }
        recordBar.isHidden = session == nil
        recordedFile = nil
        revealButton.isHidden = true
        guard let session, let sessions = tools.workbench?.sessions else { return }
        let on = sessions.recordsAgent(session)
        recordToggle.isOn = on
        recordToggle.title = on ? "Recording on" : "Record agent"
        if let r = tools.recording.recording(for: session.worktree.path) {
            recordedFile = r.file
            revealButton.isHidden = false
            recordStatus.stringValue = (r.live ? "Recording now: " : "Last recording: ") + r.file.lastPathComponent
        } else {
            recordStatus.stringValue = on
                ? "Agent screen is recorded for this repository under build evidence."
                : "Screen recording is off for this repository."
        }
    }

    // MARK: Actions

    @objc private func closePressed() { onClose?() }

    @objc private func toggleRecording() {
        guard let c = selected(), let session = tools.workbench?.sessions.sessions.first(where: { $0.worktree.path == c.path }) else { return }
        let next = !recordToggle.isOn
        tools.workbench?.sessions.setRecordsAgent(next, for: session)
        // The switch is the repository's: a live recording of any of its sessions ends at once.
        if !next {
            for other in tools.workbench?.sessions.sessions ?? [] where other.workspace.path == session.workspace.path {
                tools.recording.endTakes(forSession: other.worktree.path)
            }
        }
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

    @objc private func togglePause() {
        tools.paused.toggle()
        refresh()
    }

    @objc private func copySetup() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentPanel.setupCommand, forType: .string)
        onSay?("Setup command copied", false)
    }

    // MARK: NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = shown[row]

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0, alpha: 0.26).cgColor
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = (e.failed ? Design.record.withAlphaComponent(0.45) : Design.stroke).cgColor

        let badgeColor = e.failed ? Design.record : Design.accent
        let badgeText = NSTextField(labelWithString: e.tool)
        badgeText.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        badgeText.textColor = e.failed ? NSColor(srgbRed: 1, green: 0.68, blue: 0.66, alpha: 1) : Design.accent
        badgeText.setContentHuggingPriority(.required, for: .horizontal)
        badgeText.setContentCompressionResistancePriority(.required, for: .horizontal)
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = badgeColor.withAlphaComponent(0.16).cgColor
        badge.layer?.cornerRadius = 5
        badge.layer?.cornerCurve = .continuous
        badgeText.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeText)
        NSLayoutConstraint.activate([
            badgeText.topAnchor.constraint(equalTo: badge.topAnchor, constant: 1.5),
            badgeText.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -1.5),
            badgeText.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
            badgeText.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
        ])

        var topViews: [NSView] = [badge]
        if let tag = e.label, !tag.isEmpty {
            let tagLabel = NSTextField(labelWithString: tag)
            tagLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
            tagLabel.textColor = Design.mute
            tagLabel.lineBreakMode = .byTruncatingMiddle
            tagLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            topViews.append(tagLabel)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        topViews.append(spacer)

        let timestamp = NSTextField(labelWithString: time.string(from: e.time))
        timestamp.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        timestamp.textColor = Design.mute
        timestamp.setContentHuggingPriority(.required, for: .horizontal)
        timestamp.setContentCompressionResistancePriority(.required, for: .horizontal)
        topViews.append(timestamp)

        let topRow = NSStackView(views: topViews)
        topRow.alignment = .centerY
        topRow.spacing = 6

        let summary = NSTextField(labelWithString: e.summary)
        summary.font = .systemFont(ofSize: 11.5)
        summary.textColor = e.failed ? NSColor(srgbRed: 1, green: 0.72, blue: 0.70, alpha: 1) : Design.ink
        summary.lineBreakMode = .byTruncatingTail
        summary.toolTip = e.summary

        let content = NSStackView(views: [topRow, summary])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            topRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -20),
            summary.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -20),
        ])
        return card
    }
}
