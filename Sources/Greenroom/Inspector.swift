import AppKit

/// The inspector beside the simulators: every node on the chosen simulator's screen, and the details of the one
/// picked in the list or pointed at on the picture.
final class Inspector: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Filter: Int { case all, tappable, a11y }

    private let glass = GlassView(radius: 18)
    private let countBadge = NSTextField(labelWithString: "0")
    private let search = NSSearchField()
    private var filterButtons: [GlassButton] = []
    private let table = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")

    // Bottom property card views.
    private let card = NSView()
    private let cardTitle = NSTextField(labelWithString: "No node selected")
    private let targetPill = NSView()
    private let targetPillLabel = NSTextField(labelWithString: "")
    private let cardSubtitle = NSTextField(wrappingLabelWithString: "")
    private let metaGrid = NSView()
    private let kindValue = NSTextField(labelWithString: "—")
    private let boundsValue = NSTextField(labelWithString: "—")
    private let sizeValue = NSTextField(labelWithString: "—")
    private let tapsValue = NSTextField(labelWithString: "—")
    private var copyButton: GlassButton!

    private(set) var nodes: [ScreenNode] = []
    private var shown: [ScreenNode] = []
    private var filter: Filter = .all
    private var selectedNode: ScreenNode?
    private weak var simulator: Simulator?

    /// Called with the node to outline on the picture (nil for none).
    var onPick: ((ScreenNode?) -> Void)?
    /// Called when the close button is clicked.
    var onClose: (() -> Void)?
    /// Reports a short status message to the window (text, isProblem).
    var onSay: ((String, Bool) -> Void)?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.appearance = NSAppearance(named: .darkAqua)

        glass.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(glass)

        // Header row: title, muted count badge, spacer, close button.
        let title = NSTextField(labelWithString: "Inspector")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Design.ink

        countBadge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countBadge.textColor = Design.mute
        let countPill = pillContainer(containing: countBadge, fill: Design.well, radius: 7, hPad: 6, vPad: 2)

        let close = GlassButton(symbol: "xmark", label: "Close Inspector", target: self, action: #selector(closePressed))
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, countPill, headerSpacer, close])
        header.alignment = .centerY
        header.spacing = 8

        // Search field.
        search.placeholderString = "Search nodes…"
        search.controlSize = .small
        search.delegate = self

        // Filter pills: All, Tappable, a11y.
        let filters: [(Filter, String, String)] = [
            (.all, "All", "Show all screen nodes"),
            (.tappable, "Tappable", "Show tappable nodes and input fields"),
            (.a11y, "a11y", "Show accessibility issues (unlabeled or small targets)"),
        ]
        filterButtons = filters.map { kind, text, tip in
            let b = GlassButton(symbol: nil, title: text, label: tip, style: .well, target: self, action: #selector(filterPicked(_:)))
            b.tag = kind.rawValue
            b.font = .systemFont(ofSize: 11.5, weight: .medium)
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            b.layer?.cornerRadius = 12
            return b
        }
        let filterRow = NSStackView(views: filterButtons + [NSView()])
        filterRow.alignment = .centerY
        filterRow.spacing = 6

        // Node table.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("node"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
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
        emptyLabel.stringValue = "Choose a running simulator."

        // Bottom structured property card.
        buildPropertyCard()

        for v in [header, search, filterRow, scroll, emptyLabel, card] as [NSView] {
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

            search.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            filterRow.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            filterRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            filterRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: card.topAnchor, constant: -10),

            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        view = root
        refreshFilterButtons()
        show([], of: nil)
    }

    private func buildPropertyCard() {
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Design.stroke.cgColor

        cardTitle.font = .systemFont(ofSize: 12.5, weight: .semibold)
        cardTitle.textColor = Design.ink
        cardTitle.lineBreakMode = .byTruncatingTail
        cardTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        targetPillLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        targetPillLabel.setContentHuggingPriority(.required, for: .horizontal)
        targetPillLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        targetPill.wantsLayer = true
        targetPill.layer?.cornerRadius = 6
        targetPill.layer?.cornerCurve = .continuous
        targetPillLabel.translatesAutoresizingMaskIntoConstraints = false
        targetPill.addSubview(targetPillLabel)
        NSLayoutConstraint.activate([
            targetPillLabel.topAnchor.constraint(equalTo: targetPill.topAnchor, constant: 2),
            targetPillLabel.bottomAnchor.constraint(equalTo: targetPill.bottomAnchor, constant: -2),
            targetPillLabel.leadingAnchor.constraint(equalTo: targetPill.leadingAnchor, constant: 6),
            targetPillLabel.trailingAnchor.constraint(equalTo: targetPill.trailingAnchor, constant: -6),
        ])
        targetPill.isHidden = true

        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let titleRow = NSStackView(views: [cardTitle, titleSpacer, targetPill])
        titleRow.alignment = .centerY
        titleRow.spacing = 6

        cardSubtitle.font = .systemFont(ofSize: 11)
        cardSubtitle.textColor = Design.mute
        cardSubtitle.maximumNumberOfLines = 2

        // Compact 2-column metadata grid: Kind, Bounds, Size, Taps at.
        let grid = NSGridView(views: [
            [metaCell("Kind", value: kindValue), metaCell("Bounds", value: boundsValue)],
            [metaCell("Size", value: sizeValue), metaCell("Taps at", value: tapsValue)],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        for i in 0..<grid.numberOfColumns {
            grid.column(at: i).xPlacement = .fill
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        metaGrid.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: metaGrid.topAnchor),
            grid.bottomAnchor.constraint(equalTo: metaGrid.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: metaGrid.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: metaGrid.trailingAnchor),
        ])

        copyButton = GlassButton(symbol: "doc.on.doc", title: "Copy gr command", label: "Copy gr command to clipboard", style: .well, target: self, action: #selector(copyGrCommand))
        copyButton.font = .systemFont(ofSize: 12, weight: .medium)
        copyButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        copyButton.isEnabled = false

        let cardStack = NSStackView(views: [titleRow, cardSubtitle, metaGrid, copyButton])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 8
        cardStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            titleRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -24),
            cardSubtitle.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -24),
            metaGrid.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -24),
            copyButton.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -24),
        ])
    }

    private func metaCell(_ title: String, value: NSTextField) -> NSView {
        let key = NSTextField(labelWithString: title)
        key.font = .systemFont(ofSize: 10, weight: .medium)
        key.textColor = Design.mute
        value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        value.textColor = Design.ink
        value.lineBreakMode = .byTruncatingTail
        value.isSelectable = true
        let stack = NSStackView(views: [key, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private func pillContainer(containing label: NSTextField, fill: NSColor, radius: CGFloat, hPad: CGFloat, vPad: CGFloat) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = fill.cgColor
        box.layer?.cornerRadius = radius
        box.layer?.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: vPad),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -vPad),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: hPad),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -hPad),
        ])
        return box
    }

    // MARK: Public API

    /// The screen's nodes, keeping the picked one picked when it is still there.
    func show(_ fresh: [ScreenNode], of sim: Simulator?) {
        simulator = sim
        guard isViewLoaded else { nodes = fresh; return }
        let picked = selectedNode
        nodes = fresh.filter { !$0.label.isEmpty || $0.click || $0.field }
        applyFilter(preserving: picked)
    }

    /// Picks the smallest node holding a device position (what a pointer over the picture is on).
    func pick(atDeviceX x: Int, y: Int) {
        let p = CGPoint(x: x, y: y)
        let holdingShown = shown.indices.filter { shown[$0].frame.contains(p) }
        if let i = holdingShown.min(by: { area(shown[$0]) < area(shown[$1]) }) {
            if table.selectedRow != i {
                table.selectRowIndexes([i], byExtendingSelection: false)
                table.scrollRowToVisible(i)
            }
            return
        }
        let holdingAll = nodes.indices.filter { nodes[$0].frame.contains(p) }
        guard let i = holdingAll.min(by: { area(nodes[$0]) < area(nodes[$1]) }) else { return }
        let node = nodes[i]
        selectedNode = node
        describe(node)
        onPick?(node)
    }

    // MARK: Filtering & Accessibility Checks

    private func isTappable(_ n: ScreenNode) -> Bool { n.click || n.field }
    private func isMissingLabel(_ n: ScreenNode) -> Bool { isTappable(n) && n.label.isEmpty }
    private func isSmallTarget(_ n: ScreenNode) -> Bool { isTappable(n) && (n.frame.width < 120 || n.frame.height < 120) }
    private func hasA11yIssue(_ n: ScreenNode) -> Bool { isMissingLabel(n) || isSmallTarget(n) }
    private func area(_ n: ScreenNode) -> CGFloat { n.frame.width * n.frame.height }

    private func applyFilter(preserving picked: ScreenNode? = nil) {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = nodes.filter { n in
            switch filter {
            case .all: break
            case .tappable: if !isTappable(n) { return false }
            case .a11y: if !hasA11yIssue(n) { return false }
            }
            if query.isEmpty { return true }
            let kind = nodeKind(n)
            return n.label.localizedCaseInsensitiveContains(query)
                || n.text.localizedCaseInsensitiveContains(query)
                || n.desc.localizedCaseInsensitiveContains(query)
                || n.hint.localizedCaseInsensitiveContains(query)
                || kind.localizedCaseInsensitiveContains(query)
        }

        let countText = shown.count == nodes.count ? "\(nodes.count)" : "\(shown.count)/\(nodes.count)"
        countBadge.stringValue = simulator == nil ? "0" : countText
        countBadge.toolTip = simulator.map { "\($0.name): \(nodes.count) nodes" }
        refreshFilterButtons()

        emptyLabel.isHidden = !shown.isEmpty
        if simulator == nil {
            emptyLabel.stringValue = "Choose a running simulator."
        } else if nodes.isEmpty {
            emptyLabel.stringValue = "No nodes on screen."
        } else {
            emptyLabel.stringValue = filter == .a11y ? "No accessibility issues found." : "No matching nodes."
        }

        table.reloadData()
        if let picked, let i = shown.firstIndex(where: { $0.label == picked.label && $0.left == picked.left && $0.top == picked.top }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            selectedNode = shown[i]
            describe(shown[i])
        } else {
            selectedNode = nil
            describe(nil)
            onPick?(nil)
        }
    }

    private func refreshFilterButtons() {
        let issues = nodes.filter { hasA11yIssue($0) }.count
        for b in filterButtons {
            let kind = Filter(rawValue: b.tag) ?? .all
            if kind == .a11y {
                b.title = issues > 0 ? "a11y · \(issues)" : "a11y"
                if issues > 0 {
                    b.layer?.borderWidth = 1
                    b.layer?.borderColor = Design.warning.withAlphaComponent(0.65).cgColor
                } else {
                    b.layer?.borderWidth = 0
                    b.layer?.borderColor = nil
                }
            }
            b.isOn = kind == filter
            if kind == .a11y, issues > 0, !b.isOn {
                b.layer?.backgroundColor = Design.warning.withAlphaComponent(0.16).cgColor
                b.attributedTitle = NSAttributedString(
                    string: b.title,
                    attributes: [.foregroundColor: Design.warning, .font: b.font ?? .systemFont(ofSize: 11.5, weight: .medium)]
                )
            }
        }
    }

    private func nodeKind(_ n: ScreenNode) -> String {
        n.field ? (n.password ? "password field" : "field") : (n.click ? "tappable" : "text")
    }

    // MARK: Property Card

    private func describe(_ n: ScreenNode?) {
        guard let n else {
            cardTitle.stringValue = "No node selected"
            cardTitle.textColor = Design.mute
            targetPill.isHidden = true
            cardSubtitle.isHidden = false
            cardSubtitle.stringValue = simulator == nil ? "Choose a running simulator." : "Point at the picture, or pick a node above."
            metaGrid.isHidden = true
            copyButton.isEnabled = false
            return
        }

        let displayLabel = n.label.replacingOccurrences(of: "\n", with: " ")
        cardTitle.stringValue = displayLabel.isEmpty ? "(no label)" : displayLabel
        cardTitle.textColor = displayLabel.isEmpty && isTappable(n) ? Design.warning : Design.ink

        if isTappable(n) {
            targetPill.isHidden = false
            let missing = isMissingLabel(n)
            let small = isSmallTarget(n)
            if missing || small {
                targetPillLabel.stringValue = (missing && small) ? "⚠ Small / No label" : (missing ? "⚠ No label" : "⚠ Small")
                targetPillLabel.textColor = Design.warning
                targetPill.layer?.backgroundColor = Design.warning.withAlphaComponent(0.16).cgColor
                targetPill.layer?.borderWidth = 1
                targetPill.layer?.borderColor = Design.warning.withAlphaComponent(0.4).cgColor
            } else {
                targetPillLabel.stringValue = "✓ OK"
                targetPillLabel.textColor = Design.accent
                targetPill.layer?.backgroundColor = Design.accent.withAlphaComponent(0.16).cgColor
                targetPill.layer?.borderWidth = 1
                targetPill.layer?.borderColor = Design.accent.withAlphaComponent(0.4).cgColor
            }
        } else {
            targetPill.isHidden = true
        }

        var notes: [String] = []
        if !n.desc.isEmpty, n.desc != n.label { notes.append("desc: \(n.desc)") }
        if !n.hint.isEmpty, n.hint != n.label { notes.append("hint: \(n.hint)") }
        if isMissingLabel(n) { notes.append("Screen reader has no label for this control.") }
        cardSubtitle.stringValue = notes.joined(separator: " · ")
        cardSubtitle.isHidden = notes.isEmpty

        metaGrid.isHidden = false
        kindValue.stringValue = nodeKind(n)
        boundsValue.stringValue = "\(n.left), \(n.top)"
        sizeValue.stringValue = "\(Int(n.frame.width)) × \(Int(n.frame.height)) px"
        let (cx, cy) = n.center
        tapsValue.stringValue = "\(cx), \(cy)"
        copyButton.isEnabled = true
    }

    // MARK: Actions

    @objc private func closePressed() { onClose?() }

    @objc private func filterPicked(_ sender: GlassButton) {
        filter = Filter(rawValue: sender.tag) ?? .all
        applyFilter(preserving: selectedNode)
    }

    @objc private func copyGrCommand() {
        guard let n = selectedNode else { return }
        let cmd: String
        if !n.label.isEmpty {
            cmd = "gr tap-text \(ScreenNode.quote(n.label))"
        } else {
            let (cx, cy) = n.center
            cmd = "gr tap \(cx) \(cy)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        onSay?("Copied gr command", false)
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(preserving: selectedNode)
    }

    // MARK: NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { InspectorRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let n = shown[row]
        let issue = hasA11yIssue(n)
        let symbol = n.field ? "character.cursor.ibeam" : n.click ? "hand.tap" : "textformat"
        let iconImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage()
        let icon = NSImageView(image: iconImage)
        icon.contentTintColor = issue ? Design.warning : (isTappable(n) ? Design.accent : Design.mute)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = n.label.isEmpty ? "(no label)" : n.label.replacingOccurrences(of: "\n", with: " ")
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = n.label.isEmpty ? (isTappable(n) ? Design.warning : Design.mute) : Design.ink
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sizeText = "\(Int(n.frame.width))×\(Int(n.frame.height))"
        let trailingText = issue ? "⚠ \(sizeText)" : sizeText
        let badge = NSTextField(labelWithString: trailingText)
        badge.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: issue ? .semibold : .regular)
        badge.textColor = issue ? Design.warning : Design.mute
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let rowStack = NSStackView(views: [icon, label, spacer, badge])
        rowStack.alignment = .centerY
        rowStack.spacing = 6
        rowStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        return rowStack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        let n = row >= 0 && row < shown.count ? shown[row] : nil
        selectedNode = n
        describe(n)
        onPick?(n)
    }
}

private final class InspectorRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 1)
        Design.accent.withAlphaComponent(0.16).setFill()
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        p.fill()
        Design.accent.withAlphaComponent(0.45).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
    override var isEmphasized: Bool { get { false } set {} }
}
