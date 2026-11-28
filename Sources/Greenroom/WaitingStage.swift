import AppKit

/// What the stage shows with nothing running (docs/AGENT-FIRST-SPEC.md, "Onboarding"): Greenroom waits for an
/// agent. No drop target: the work arrives when an agent calls, so the stage holds the words to give the agent,
/// whether one has called, and small ways to do it by hand (the APK screen, adding a repository).
final class WaitingStage: NSView {
    /// "Connect an Agent…": the Connect screen (File > Connect Agents…).
    var onConnect: (() -> Void)?
    /// "Run an APK Yourself…": the APK screen (File > Run an APK…).
    var onRunAPK: (() -> Void)?
    var onAddRepo: (() -> Void)?

    /// What the person pastes into their agent. It names no tool: the agent's own instructions cover those.
    static let prompt = "Build this app and open it in Greenroom. Then verify the change on this branch: say what you will check, check each thing in the running app, and tell me what you found."

    private let card = NSView()
    private let statusDot = NSView()
    private let status = NSTextField(labelWithString: "")
    private var copy: GlassButton!
    private var connect: GlassButton!
    private var copied: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        card.wantsLayer = true
        card.layer?.cornerRadius = 22
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor(white: 1, alpha: 0.03).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Design.stroke.cgColor

        let iconWell = NSView()
        iconWell.wantsLayer = true
        iconWell.layer?.cornerRadius = 12
        iconWell.layer?.cornerCurve = .continuous
        iconWell.layer?.backgroundColor = Design.accent.withAlphaComponent(0.14).cgColor
        iconWell.layer?.borderWidth = 1
        iconWell.layer?.borderColor = Design.accent.withAlphaComponent(0.28).cgColor
        iconWell.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .medium)) ?? NSImage())
        icon.contentTintColor = Design.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconWell.addSubview(icon)

        let title = NSTextField(labelWithString: "Waiting for an Agent")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = Design.ink
        let lede = NSTextField(wrappingLabelWithString: "Ask your coding agent to build your app and open it in Greenroom.\nIt shows up here, running, and you can watch every step.")
        lede.font = .systemFont(ofSize: 13.5)
        lede.textColor = Design.mute
        lede.alignment = .center

        // The words for the agent, with Copy.
        let promptBox = NSView()
        promptBox.wantsLayer = true
        promptBox.layer?.cornerRadius = 12
        promptBox.layer?.cornerCurve = .continuous
        promptBox.layer?.backgroundColor = NSColor(white: 0, alpha: 0.25).cgColor
        promptBox.layer?.borderWidth = 1
        promptBox.layer?.borderColor = Design.stroke.cgColor
        promptBox.translatesAutoresizingMaskIntoConstraints = false
        let words = NSTextField(wrappingLabelWithString: Self.prompt)
        words.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        words.textColor = Design.ink
        words.isSelectable = true
        words.setAccessibilityLabel("What to ask your agent")
        words.translatesAutoresizingMaskIntoConstraints = false
        copy = GlassButton(symbol: nil, title: "Copy", label: "Copy these words to paste into your agent", style: .well, target: nil, action: nil)
        copy.onPress = { [weak self] in self?.copyPrompt() }
        promptBox.addSubview(words)
        promptBox.addSubview(copy)

        // Whether an agent has called, and the way to connect one.
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 12.5, weight: .medium)
        status.textColor = Design.ink
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        connect = GlassButton(symbol: nil, title: "Connect an Agent…", label: "Connect a coding agent to Greenroom", style: .accent, target: nil, action: nil)
        connect.onPress = { [weak self] in self?.onConnect?() }
        let statusRow = NSStackView(views: [statusDot, status, statusSpacer, connect])
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        let column = NSStackView(views: [iconWell, title, lede, promptBox, statusRow])
        column.orientation = .vertical
        column.spacing = 12
        column.setCustomSpacing(14, after: iconWell)
        column.setCustomSpacing(18, after: lede)
        column.setCustomSpacing(14, after: promptBox)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        // By hand, small.
        let runAPK = GlassButton(symbol: nil, title: "Run an APK Yourself…  ⌘O", label: "Open the APK screen to run an APK by hand", style: .plain, target: nil, action: nil)
        runAPK.onPress = { [weak self] in self?.onRunAPK?() }
        let addRepo = GlassButton(symbol: nil, title: "Add a Repository…", label: "Add a git repository to Sessions before an agent runs", style: .plain, target: nil, action: nil)
        addRepo.onPress = { [weak self] in self?.onAddRepo?() }
        for b in [runAPK, addRepo] { b.font = .systemFont(ofSize: 12, weight: .medium); b.heightAnchor.constraint(equalToConstant: 24).isActive = true }
        let byHand = NSStackView(views: [runAPK, addRepo])
        byHand.spacing = 6

        let all = NSStackView(views: [card, byHand])
        all.orientation = .vertical
        all.spacing = 14
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.centerXAnchor.constraint(equalTo: centerXAnchor),
            all.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            card.widthAnchor.constraint(equalToConstant: 560),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 32),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            iconWell.widthAnchor.constraint(equalToConstant: 44),
            iconWell.heightAnchor.constraint(equalToConstant: 44),
            icon.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            promptBox.widthAnchor.constraint(equalTo: column.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            words.topAnchor.constraint(equalTo: promptBox.topAnchor, constant: 12),
            words.bottomAnchor.constraint(equalTo: promptBox.bottomAnchor, constant: -12),
            words.leadingAnchor.constraint(equalTo: promptBox.leadingAnchor, constant: 14),
            words.trailingAnchor.constraint(equalTo: copy.leadingAnchor, constant: -10),
            copy.topAnchor.constraint(equalTo: promptBox.topAnchor, constant: 8),
            copy.trailingAnchor.constraint(equalTo: promptBox.trailingAnchor, constant: -8),
            copy.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            connect.heightAnchor.constraint(equalToConstant: 30),
        ])
        reload(client: nil, listening: false, connected: [])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// What the status line says for the agent endpoint's state, the harnesses connected, and the last agent heard
    /// from since the app started.
    static func statusText(client: String?, listening: Bool, connected: [String] = []) -> String {
        guard listening else { return "The agent endpoint is not running" }
        if let client, !client.isEmpty { return "Listening · last heard from \(ConnectModel.displayName(client: client))" }
        if !connected.isEmpty { return "Listening · \(ConnectModel.list(connected)) connected" }
        return "Listening · no agent has called yet"
    }

    func reload(client: String?, listening: Bool, connected: [String]) {
        status.stringValue = Self.statusText(client: client, listening: listening, connected: connected)
        statusDot.layer?.backgroundColor = (listening ? Design.accent : Design.warning).cgColor
        // With an agent connected, connecting another is the smaller thing to do.
        connect.title = connected.isEmpty ? "Connect an Agent…" : "Agents…"
        connect.style = connected.isEmpty ? .accent : .well
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.prompt, forType: .string)
        copy.title = "Copied"
        copied?.invalidate()
        copied = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.copy.title = "Copy" }
    }

    /// For a check: the texts on the stage.
    var texts: [String] { [status.stringValue, Self.prompt] }
}
