import AppKit

/// The chosen simulator's log as it is written: the app's android.util.Log lines and the engine's own.
final class LogPanel: NSView, NSSearchFieldDelegate {
    private let text = NSTextView()
    private let scroll = NSScrollView()
    private let filter = NSSearchField()
    private let title = NSTextField(labelWithString: "Log")
    private var lines: [String] = []
    private var offset: UInt64 = 0
    private var timer: Timer?
    private weak var simulator: Simulator?
    private static let limit = 4000

    override init(frame: NSRect) {
        super.init(frame: frame)
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .labelColor
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 10, height: 6)
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        filter.placeholderString = "Filter"
        filter.controlSize = .small
        filter.font = .systemFont(ofSize: 11)
        filter.delegate = self
        let line = NSBox()
        line.boxType = .separator
        for v in [line, title, filter, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor), line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8), title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            filter.centerYAnchor.constraint(equalTo: title.centerYAnchor), filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            filter.widthAnchor.constraint(equalToConstant: 200),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Follows this simulator's log from its start (nil: stops).
    func follow(_ sim: Simulator?) {
        guard sim !== simulator else { return }
        simulator = sim
        lines = []
        offset = 0
        title.stringValue = sim.map { "Log · \($0.name)" } ?? "Log"
        timer?.invalidate()
        timer = sim == nil ? nil : Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.read() }
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
        render()
    }

    /// The lines shown now (for scripted checks).
    var shown: [String] {
        let f = filter.stringValue
        return f.isEmpty ? lines : lines.filter { $0.localizedCaseInsensitiveContains(f) }
    }

    private func render() {
        let atEnd = scroll.contentView.bounds.maxY >= (scroll.documentView?.frame.maxY ?? 0) - 30
        text.string = shown.joined(separator: "\n")
        if atEnd { text.scrollToEndOfDocument(nil) }
    }

    func controlTextDidChange(_ note: Notification) { render() }
}
