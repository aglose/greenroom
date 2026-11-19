import AppKit
import UniformTypeIdentifiers

/// The launcher window's content: a drop target for APKs above the list of recent ones.
final class LibraryView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var open: ((URL) -> Void)?

    private let table = NSTableView()
    private let hint = NSTextField(labelWithString: "Drop an APK here, or press ⌘O")
    private let status = NSTextField(labelWithString: "")
    private var recents: [URL] = []
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])

        hint.font = .systemFont(ofSize: 15, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        status.font = .systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        status.alignment = .center

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("apk"))
        column.title = "Recent"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.backgroundColor = .clear

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for v in [hint, scroll, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 36),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        recents = Recents.all
        table.reloadData()
    }

    func setStatus(_ text: String) { status.stringValue = text }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 12, yRadius: 12)
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    // MARK: Drops

    private func apks(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension.lowercased() == "apk" }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = !apks(sender).isEmpty
        return highlighted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = apks(sender)
        urls.forEach { open?($0) }
        return !urls.isEmpty
    }

    // MARK: Recent list

    func numberOfRows(in tableView: NSTableView) -> Int { recents.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = recents[row]
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let folder = NSTextField(labelWithString: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingHead
        let stack = NSStackView(views: [name, folder])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        return stack
    }

    @objc private func openSelected() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < recents.count else { return }
        open?(recents[row])
    }
}
