import AppKit

/// One layout or content difference surfaced in the Compare tab of the bottom dock.
struct CompareDiffItem {
    let symbol: String      // "+" or "↔" or "−"
    let title: String
    let detail: String
    let rect: CGRect?
    let isAdded: Bool
}

/// Unified bottom dock hosting the Log, Timeline, and Compare tabs over frosted glass, with a drag-resize top handle.
final class BottomDock: NSView {
    enum Tab: Int, CaseIterable { case log, timeline, compare }

    let logPanel: LogPanel
    let timeline: TimelineDock
    private let compareView = CompareTabView()
    private let glass = GlassView(radius: Design.glassRadius)
    private let grabber = DockResizeHandle()
    private let contentHost = NSView()

    private var tabButtons: [Tab: GlassButton] = [:]
    private var logErrorCount = 0
    private var timelineLive = false
    private var compareDiffCount = 0

    private(set) var activeTab: Tab = .log
    var onClose: (() -> Void)?
    /// Called during a vertical drag of the top resize handle with the point delta (positive = taller).
    var onResizeDelta: ((CGFloat) -> Void)?
    var onTabChange: ((Tab) -> Void)?
    var onHighlightDiff: ((CompareDiffItem?) -> Void)?

    var compareText: String { compareView.plainSummary }

    init(logPanel: LogPanel, timeline: TimelineDock) {
        self.logPanel = logPanel
        self.timeline = timeline
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.masksToBounds = true

        grabber.onResizeDelta = { [weak self] delta in self?.onResizeDelta?(delta) }
        compareView.onSelect = { [weak self] item in self?.onHighlightDiff?(item) }

        let logButton = makeTabButton(tab: .log, title: "Log", label: "Show Log tab")
        let timelineButton = makeTabButton(tab: .timeline, title: "Timeline", label: "Show Timeline tab")
        let compareButton = makeTabButton(tab: .compare, title: "Compare", label: "Show Compare tab")
        tabButtons[.log] = logButton
        tabButtons[.timeline] = timelineButton
        tabButtons[.compare] = compareButton

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let collapseButton = GlassButton(symbol: "chevron.down", label: "Hide dock", style: .plain, target: self, action: #selector(closePressed(_:)))
        collapseButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let tabBar = NSStackView(views: [logButton, timelineButton, compareButton, spacer, collapseButton])
        tabBar.orientation = .horizontal
        tabBar.alignment = .centerY
        tabBar.spacing = 6

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Design.stroke.cgColor

        for v in [glass, grabber, tabBar, divider, contentHost] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        for child in [logPanel, timeline, compareView] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: contentHost.topAnchor),
                child.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            ])
        }

        let contentBottom = contentHost.bottomAnchor.constraint(equalTo: bottomAnchor)
        contentBottom.priority = .init(250)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),

            grabber.topAnchor.constraint(equalTo: topAnchor),
            grabber.leadingAnchor.constraint(equalTo: leadingAnchor),
            grabber.trailingAnchor.constraint(equalTo: trailingAnchor),
            grabber.heightAnchor.constraint(equalToConstant: 12),

            tabBar.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 2),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            divider.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 6),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            contentHost.topAnchor.constraint(equalTo: divider.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentBottom,
        ])

        applyTabVisibility()
        refreshTabTitles()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeTabButton(tab: Tab, title: String, label: String) -> GlassButton {
        let button = GlassButton(symbol: nil, title: title, label: label, style: .plain, target: self, action: #selector(tabPressed(_:)))
        button.tag = tab.rawValue
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    @objc private func tabPressed(_ sender: NSButton) {
        guard let tab = Tab(rawValue: sender.tag) else { return }
        select(tab)
    }

    @objc private func closePressed(_ sender: Any?) {
        onClose?()
    }

    func select(_ tab: Tab) {
        let changed = activeTab != tab
        activeTab = tab
        applyTabVisibility()
        if changed { onTabChange?(tab) }
    }

    func setLogErrorCount(_ count: Int) {
        logErrorCount = max(0, count)
        refreshTabTitles()
    }

    func setTimelineLive(_ live: Bool) {
        timelineLive = live
        refreshTabTitles()
    }

    func setCompareSummary(text: String, items: [CompareDiffItem], counts: (added: Int, moved: Int)) {
        compareDiffCount = !items.isEmpty ? items.count : (counts.added + counts.moved)
        compareView.update(text: text, items: items, counts: counts)
        refreshTabTitles()
    }

    private func applyTabVisibility() {
        logPanel.isHidden = activeTab != .log
        timeline.isHidden = activeTab != .timeline
        compareView.isHidden = activeTab != .compare
        for (tab, button) in tabButtons {
            button.isOn = tab == activeTab
        }
    }

    private func refreshTabTitles() {
        tabButtons[.log]?.title = logErrorCount > 0 ? "Log (\(logErrorCount))" : "Log"
        tabButtons[.timeline]?.title = timelineLive ? "Timeline ●" : "Timeline"
        tabButtons[.compare]?.title = compareDiffCount > 0 ? "Compare (\(compareDiffCount))" : "Compare"
    }
}

/// Top grabber bar that lets the user drag to resize the bottom dock vertically.
private final class DockResizeHandle: NSView {
    var onResizeDelta: ((CGFloat) -> Void)?
    private let pill = NSView()
    private var lastScreenY: CGFloat = 0
    private var hovering = false { didSet { refreshPill() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 2
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            pill.widthAnchor.constraint(equalToConstant: 36),
            pill.heightAnchor.constraint(equalToConstant: 4),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        refreshPill()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func refreshPill() {
        pill.layer?.backgroundColor = (hovering ? Design.ink.withAlphaComponent(0.55) : Design.mute.withAlphaComponent(0.4)).cgColor
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.resizeUpDown.push()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        lastScreenY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        let y = NSEvent.mouseLocation.y
        let delta = y - lastScreenY
        lastScreenY = y
        if delta != 0 { onResizeDelta?(delta) }
    }
}

/// Compare tab inside the bottom dock: summary pills and a scrollable list of clickable diff rows.
final class CompareTabView: NSView {
    var plainSummary: String = ""
    var onSelect: ((CompareDiffItem?) -> Void)?

    private let addedPill = ComparePillView(color: Design.accent)
    private let movedPill = ComparePillView(color: Design.warning)
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No differences yet. Compare two screens to inspect layout changes.")
    private let scroll = NSScrollView()
    private let documentView = FlippedStackHost()
    private let stack = NSStackView()

    private var rows: [CompareDiffRow] = []
    private var selectedIndex: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let header = NSStackView(views: [addedPill, movedPill, spacer])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = Design.mute
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        scroll.documentView = documentView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for v in [header, scroll, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            documentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])

        update(text: "", items: [], counts: (added: 0, moved: 0))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(text: String, items: [CompareDiffItem], counts: (added: Int, moved: Int)) {
        plainSummary = text
        selectedIndex = nil

        addedPill.text = "+\(counts.added) added"
        movedPill.text = "↔ \(counts.moved) moved"

        for row in rows { stack.removeArrangedSubview(row); row.removeFromSuperview() }
        rows = []

        for (index, item) in items.enumerated() {
            let row = CompareDiffRow(item: item)
            row.onClick = { [weak self] in self?.toggleSelection(at: index) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append(row)
        }

        let isEmpty = items.isEmpty
        scroll.isHidden = isEmpty
        emptyLabel.isHidden = !isEmpty
        if isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            emptyLabel.stringValue = trimmed.isEmpty
                ? "No differences yet. Compare two screens to inspect layout changes."
                : trimmed
        }
    }

    private func toggleSelection(at index: Int) {
        if selectedIndex == index {
            rows[index].isSelected = false
            selectedIndex = nil
            onSelect?(nil)
            return
        }
        if let prev = selectedIndex, prev < rows.count {
            rows[prev].isSelected = false
        }
        selectedIndex = index
        rows[index].isSelected = true
        onSelect?(rows[index].item)
    }
}

private final class FlippedStackHost: NSView {
    override var isFlipped: Bool { true }
}

private final class ComparePillView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let accentColor: NSColor

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init(color: NSColor) {
        self.accentColor = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = color.withAlphaComponent(0.32).cgColor

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

private final class CompareDiffRow: NSView {
    let item: CompareDiffItem
    var onClick: (() -> Void)?
    var isSelected = false { didSet { refreshStyle() } }
    private var hovering = false { didSet { refreshStyle() } }

    init(item: CompareDiffItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        let symbolLabel = NSTextField(labelWithString: item.symbol)
        symbolLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        symbolLabel.alignment = .center
        symbolLabel.textColor = Self.symbolColor(for: item)
        symbolLabel.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: item.title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = Design.ink
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detailLabel = NSTextField(labelWithString: item.detail)
        detailLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = Design.mute
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [symbolLabel, titleLabel, spacer, detailLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            symbolLabel.widthAnchor.constraint(equalToConstant: 18),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        refreshStyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func symbolColor(for item: CompareDiffItem) -> NSColor {
        if item.isAdded || item.symbol == "+" { return Design.accent }
        if item.symbol == "−" || item.symbol == "-" { return Design.record }
        if item.symbol == "↔" { return Design.warning }
        return Design.difference
    }

    private func refreshStyle() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Design.snap)
        if isSelected {
            layer?.backgroundColor = Design.wellOn.cgColor
            layer?.borderColor = Design.accent.withAlphaComponent(0.55).cgColor
        } else if hovering {
            layer?.backgroundColor = Design.well.cgColor
            layer?.borderColor = Design.stroke.cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
        }
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
