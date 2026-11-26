import AppKit

/// The chosen simulator's log as it is written: the app's android.util.Log lines and the engine's own.
final class LogPanel: NSView, NSSearchFieldDelegate {
    private enum LevelFilter: Int, CaseIterable {
        case all, error, warn, info, debug
    }

    private enum Severity {
        case error, warn, info, debug, other
    }

    private let text = NSTextView()
    private let scroll = NSScrollView()
    private let filter = NSSearchField()
    private var allButton: GlassButton!
    private var errorButton: GlassButton!
    private var warnButton: GlassButton!
    private var infoButton: GlassButton!
    private var debugButton: GlassButton!
    private var activeFilter: LevelFilter = .all

    private var lines: [String] = []
    private var offset: UInt64 = 0
    private var timer: Timer?
    private weak var simulator: Simulator?
    private var lastErrorCount = 0
    private static let limit = 4000

    private static let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let errorColor = NSColor(srgbRed: 1.0, green: 0.482, blue: 0.447, alpha: 1) // #FF7B72
    private static let infoColor = NSColor(srgbRed: 0.576, green: 0.773, blue: 0.992, alpha: 1)  // #93C5FD
    private static let debugColor = Design.mute
    private static let defaultColor = Design.ink.withAlphaComponent(0.85)

    /// Fired on the main queue whenever the number of error/fatal (`E`/`F`) lines changes.
    var onErrorCount: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)

        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.font = Self.monoFont
        text.textColor = Self.defaultColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 12, height: 6)
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true

        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        allButton = makeFilterButton(title: "All", label: "Show all log lines", filter: .all)
        errorButton = makeFilterButton(title: "Errors", label: "Show error log lines", filter: .error)
        warnButton = makeFilterButton(title: "Warn", label: "Show warning log lines", filter: .warn)
        infoButton = makeFilterButton(title: "Info", label: "Show info log lines", filter: .info)
        debugButton = makeFilterButton(title: "Debug", label: "Show debug log lines", filter: .debug)

        filter.placeholderString = "Filter tag or text"
        filter.controlSize = .small
        filter.font = .systemFont(ofSize: 11)
        filter.delegate = self
        filter.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = GlassButton(symbol: "trash", label: "Clear log", style: .well, target: self, action: #selector(clearLog(_:)))
        let copyButton = GlassButton(symbol: "doc.on.doc", label: "Copy shown log", style: .well, target: self, action: #selector(copyLog(_:)))
        for b in [clearButton, copyButton] {
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let topBar = NSStackView(views: [allButton, errorButton, warnButton, infoButton, debugButton, spacer, filter, clearButton, copyButton])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 6
        topBar.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBar)
        addSubview(scroll)

        let scrollBottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        scrollBottom.priority = .init(250)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            filter.widthAnchor.constraint(equalToConstant: 190),
            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollBottom,
        ])

        refreshFilterButtons()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeFilterButton(title: String, label: String, filter: LevelFilter) -> GlassButton {
        let button = GlassButton(symbol: nil, title: title, label: label, style: .well, target: self, action: #selector(selectFilter(_:)))
        button.tag = filter.rawValue
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    @objc private func selectFilter(_ sender: NSButton) {
        guard let next = LevelFilter(rawValue: sender.tag) else { return }
        activeFilter = next
        refreshFilterButtons()
        render()
    }

    @objc private func clearLog(_ sender: Any?) {
        lines = []
        notifyErrorCountIfNeeded()
        refreshFilterButtons()
        render()
    }

    @objc private func copyLog(_ sender: Any?) {
        let content = shown.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    /// Follows this simulator's log from its start (nil: stops).
    func follow(_ sim: Simulator?) {
        guard sim !== simulator else { return }
        simulator = sim
        lines = []
        offset = 0
        timer?.invalidate()
        timer = sim == nil ? nil : Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.read() }
        notifyErrorCountIfNeeded()
        refreshFilterButtons()
        render()
        read()
    }

    private func read() {
        guard let sim = simulator, let handle = try? FileHandle(forReadingFrom: sim.log) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        // Whole lines only: the rest is read next time.
        guard let end = data.lastIndex(of: 10) else { return }
        let whole = data[...end]
        offset += UInt64(whole.count)
        let fresh = String(decoding: whole, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { !$0.contains("[apksim] control ") }   // the engine's echo of every command sent to it
        guard !fresh.isEmpty else { return }
        lines += fresh
        if lines.count > LogPanel.limit { lines.removeFirst(lines.count - LogPanel.limit) }
        notifyErrorCountIfNeeded()
        refreshFilterButtons()
        render()
    }

    /// The lines shown now (for scripted checks).
    var shown: [String] {
        let levelFiltered: [String]
        switch activeFilter {
        case .all:
            levelFiltered = lines
        case .error:
            levelFiltered = lines.filter { Self.severity(of: $0) == .error }
        case .warn:
            levelFiltered = lines.filter { Self.severity(of: $0) == .warn }
        case .info:
            levelFiltered = lines.filter { Self.severity(of: $0) == .info }
        case .debug:
            levelFiltered = lines.filter { Self.severity(of: $0) == .debug }
        }
        let q = filter.stringValue
        return q.isEmpty ? levelFiltered : levelFiltered.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private static func severity(of line: String) -> Severity {
        if line.contains(" E/") || line.contains(" E ") || line.contains(" F/") || line.contains(" F ")
            || line.hasPrefix("E/") || line.hasPrefix("F/")
            || line.localizedCaseInsensitiveContains("error:") {
            return .error
        }
        if line.contains(" W/") || line.contains(" W ") || line.hasPrefix("W/") {
            return .warn
        }
        if line.contains(" I/") || line.contains(" I ") || line.hasPrefix("I/") {
            return .info
        }
        if line.contains(" D/") || line.contains(" D ") || line.hasPrefix("D/") {
            return .debug
        }
        return .other
    }

    private static func color(for severity: Severity) -> NSColor {
        switch severity {
        case .error: return errorColor
        case .warn: return Design.warning
        case .info: return infoColor
        case .debug: return debugColor
        case .other: return defaultColor
        }
    }

    private func levelCounts() -> (all: Int, error: Int, warn: Int, info: Int, debug: Int) {
        var e = 0, w = 0, i = 0, d = 0
        for line in lines {
            switch Self.severity(of: line) {
            case .error: e += 1
            case .warn: w += 1
            case .info: i += 1
            case .debug: d += 1
            case .other: break
            }
        }
        return (lines.count, e, w, i, d)
    }

    private func notifyErrorCountIfNeeded() {
        let count = lines.reduce(0) { $0 + (Self.severity(of: $1) == .error ? 1 : 0) }
        guard count != lastErrorCount else { return }
        lastErrorCount = count
        if Thread.isMainThread {
            onErrorCount?(count)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onErrorCount?(count) }
        }
    }

    private func refreshFilterButtons() {
        let c = levelCounts()
        allButton.title = c.all > 0 ? "All (\(c.all))" : "All"
        errorButton.title = c.error > 0 ? "Errors (\(c.error))" : "Errors"
        warnButton.title = c.warn > 0 ? "Warn (\(c.warn))" : "Warn"
        infoButton.title = c.info > 0 ? "Info (\(c.info))" : "Info"
        debugButton.title = c.debug > 0 ? "Debug (\(c.debug))" : "Debug"

        allButton.isOn = activeFilter == .all
        errorButton.isOn = activeFilter == .error
        warnButton.isOn = activeFilter == .warn
        infoButton.isOn = activeFilter == .info
        debugButton.isOn = activeFilter == .debug
    }

    private func render() {
        let atEnd = scroll.contentView.bounds.maxY >= (scroll.documentView?.frame.maxY ?? 0) - 30
        let visible = shown
        let attributed = NSMutableAttributedString()
        for (idx, line) in visible.enumerated() {
            let color = Self.color(for: Self.severity(of: line))
            let piece = idx + 1 < visible.count ? line + "\n" : line
            attributed.append(NSAttributedString(string: piece, attributes: [
                .font: Self.monoFont,
                .foregroundColor: color,
            ]))
        }
        text.textStorage?.setAttributedString(attributed)
        if atEnd { text.scrollToEndOfDocument(nil) }
    }

    func controlTextDidChange(_ note: Notification) { render() }
}
