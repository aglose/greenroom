import AppKit

/// The inspector beside the simulators: every node on the chosen simulator's screen, and the details of the one
/// picked in the list or pointed at on the picture.
final class Inspector: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let header = NSTextField(labelWithString: "")
    private(set) var nodes: [ScreenNode] = []
    /// Called with the node to outline on the picture (nil for none).
    var onPick: ((ScreenNode?) -> Void)?

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("node"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.isSelectable = true
        detail.maximumNumberOfLines = 12

        let root = NSView()
        for v in [header, scroll, detail] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: detail.topAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            detail.heightAnchor.constraint(equalToConstant: 150),
        ])
        view = root
        show([], of: nil)
    }

    /// The screen's nodes, keeping the picked one picked when it is still there.
    func show(_ fresh: [ScreenNode], of sim: Simulator?) {
        guard isViewLoaded else { nodes = fresh; return }
        let picked = table.selectedRow >= 0 && table.selectedRow < nodes.count ? nodes[table.selectedRow] : nil
        nodes = fresh.filter { !$0.label.isEmpty || $0.click || $0.field }
        header.stringValue = sim == nil ? "Inspector" : "\(nodes.count) nodes · \(sim!.name)"
        table.reloadData()
        if let picked, let i = nodes.firstIndex(where: { $0.label == picked.label && $0.left == picked.left && $0.top == picked.top }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            describe(nil)
            onPick?(nil)
        }
        if nodes.isEmpty { detail.stringValue = sim == nil ? "Choose a running simulator." : "Point at the picture, or pick a node above." }
    }

    /// Picks the smallest node holding a device position (what a pointer over the picture is on).
    func pick(atDeviceX x: Int, y: Int) {
        let p = CGPoint(x: x, y: y)
        let holding = nodes.indices.filter { nodes[$0].frame.contains(p) }
        guard let i = holding.min(by: { area(nodes[$0]) < area(nodes[$1]) }) else { return }
        if table.selectedRow != i {
            table.selectRowIndexes([i], byExtendingSelection: false)
            table.scrollRowToVisible(i)
        }
    }

    private func area(_ n: ScreenNode) -> CGFloat { n.frame.width * n.frame.height }

    private func describe(_ n: ScreenNode?) {
        guard let n else { detail.stringValue = "Point at the picture, or pick a node above."; return }
        var lines: [String] = []
        if !n.text.isEmpty { lines.append("text    \(ScreenNode.quote(n.text))") }
        if !n.desc.isEmpty { lines.append("desc    \(ScreenNode.quote(n.desc))") }
        if !n.hint.isEmpty { lines.append("hint    \(ScreenNode.quote(n.hint))") }
        lines.append("kind    " + (n.field ? (n.password ? "password field" : "field") : n.click ? "tappable" : "text"))
        lines.append("at      \(n.left),\(n.top)")
        lines.append("size    \(n.right - n.left) × \(n.bottom - n.top) px")
        if n.hitBox != nil { lines.append("target  \(Int(n.frame.width)) × \(Int(n.frame.height)) px at \(Int(n.frame.minX)),\(Int(n.frame.minY))") }
        let (cx, cy) = n.center
        lines.append("taps at \(cx),\(cy)")
        if (n.click || n.field), n.label.isEmpty { lines.append("⚠ no label: a screen reader has nothing to say for it") }
        detail.stringValue = lines.joined(separator: "\n")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { nodes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let n = nodes[row]
        let symbol = n.field ? "character.cursor.ibeam" : n.click ? "hand.tap" : "textformat"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: n.label.isEmpty ? "(no label)" : n.label.replacingOccurrences(of: "\n", with: " "))
        label.font = .systemFont(ofSize: 12)
        label.textColor = n.label.isEmpty ? .tertiaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 5
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        let n = row >= 0 && row < nodes.count ? nodes[row] : nil
        describe(n)
        onPick?(n)
    }
}
