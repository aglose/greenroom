import AppKit

/// One thing the palette can do: a command, a device to switch to, an app or recording to open.
struct PaletteItem {
    let id: String
    let title: String
    let group: String
    let symbol: String
    var shortcut: String = ""
    var keywords: String = ""
    let run: () -> Void
}

/// ⌘K: every command, device, app and recording in one search. Matches letters in order (so "dka" finds "Dark
/// appearance"); a word that starts with what was typed ranks first, then the text containing it, then letters
/// at word starts, and the commands used last come first when nothing
/// is typed.
final class Palette: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let glass = GlassView(radius: 16)
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let none = NSTextField(labelWithString: "Nothing matches")
    private var items: [PaletteItem] = []
    private var shown: [PaletteItem] = []
    private var height: NSLayoutConstraint!
    /// Builds the list each time the palette opens, so it reflects what is running now.
    var source: () -> [PaletteItem] = { [] }
    var onClose: (() -> Void)?
    private static let recentKey = "paletteRecent"

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        shadow = NSShadow()
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.6
        layer?.shadowRadius = 30
        layer?.shadowOffset = CGSize(width: 0, height: -12)

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium)) ?? NSImage())
        icon.contentTintColor = Design.accent
        field.placeholderString = Self.placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.textColor = Design.ink
        field.delegate = self
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Design.stroke.cgColor

        let footerLine = NSView()
        footerLine.wantsLayer = true
        footerLine.layer?.backgroundColor = Design.stroke.cgColor
        let footer = NSTextField(labelWithString: "↑↓ Navigate   ·   ↵ Run   ·   Esc Close")
        footer.font = .systemFont(ofSize: 11, weight: .medium)
        footer.textColor = Design.mute
        let footerWrap = NSView()
        footerWrap.wantsLayer = true
        footerWrap.layer?.backgroundColor = NSColor(white: 0, alpha: 0.18).cgColor
        footerWrap.layer?.cornerRadius = 16
        footerWrap.layer?.cornerCurve = .continuous
        footerWrap.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        footerWrap.layer?.masksToBounds = true
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerWrap.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: footerWrap.leadingAnchor, constant: 16),
            footer.centerYAnchor.constraint(equalTo: footerWrap.centerYAnchor),
        ])

        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item")))
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 36
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        none.font = .systemFont(ofSize: 13)
        none.textColor = Design.mute
        none.isHidden = true

        // A darker tint over the glass, so a light app behind it does not wash the list out.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.11, green: 0.115, blue: 0.13, alpha: 0.85).cgColor
        tint.layer?.cornerRadius = 16
        tint.layer?.cornerCurve = .continuous
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)
        NSLayoutConstraint.activate([tint.topAnchor.constraint(equalTo: topAnchor), tint.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     tint.leadingAnchor.constraint(equalTo: leadingAnchor), tint.trailingAnchor.constraint(equalTo: trailingAnchor)])
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass, positioned: .below, relativeTo: tint)
        for v in [icon, field, line, scroll, none, footerLine, footerWrap] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        height = heightAnchor.constraint(equalToConstant: 440)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: 620), height,
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            line.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 13),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footerLine.topAnchor, constant: -6),
            footerLine.leadingAnchor.constraint(equalTo: leadingAnchor), footerLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerLine.heightAnchor.constraint(equalToConstant: 1),
            footerLine.bottomAnchor.constraint(equalTo: footerWrap.topAnchor),
            footerWrap.leadingAnchor.constraint(equalTo: leadingAnchor), footerWrap.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerWrap.bottomAnchor.constraint(equalTo: bottomAnchor), footerWrap.heightAnchor.constraint(equalToConstant: 30),
            none.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            none.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static let placeholder = "Search commands, devices, apps and recordings"
    /// Open as a picker of given items: what is picked is not one of the commands used lately.
    private var isPicker = false

    /// Opens with an empty search (the commands used lately first) and the cursor in the field. With `items`, only
    /// those are searched (a picker, such as the + menu's worktree search), under `placeholder`.
    func open(items scoped: [PaletteItem]? = nil, placeholder: String? = nil) {
        items = scoped ?? source()
        isPicker = scoped != nil
        field.placeholderString = placeholder ?? Self.placeholder
        field.stringValue = ""
        filter()
        window?.makeFirstResponder(field)
    }

    var results: [String] { shown.map(\.title) }

    func search(_ text: String) {
        field.stringValue = text
        filter()
    }

    // MARK: Matching

    /// A score for `query` in `text`, or nil: every letter in order; consecutive letters, word starts and an early
    /// first letter score higher.
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let t = Array(text.lowercased())
        var i = 0, score = 0, last = -2
        for (j, ch) in t.enumerated() where i < q.count && ch == q[i] {
            let wordStart = j == 0 || !t[j - 1].isLetter && !t[j - 1].isNumber
            score += 1 + (j == last + 1 ? 4 : 0) + (wordStart ? 6 : 0) + (j == 0 ? 8 : 0)
            last = j
            i += 1
        }
        guard i == q.count else { return nil }
        // Typed text that starts a word ("fr" in "Language: French") or appears whole outranks scattered letters.
        let typed = String(q)
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(typed) }) { score += 30 }
        else if text.lowercased().contains(typed) { score += 12 }
        return score
    }

    private func filter() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        let recent = isPicker ? [] : UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
        if q.isEmpty {
            let used = recent.compactMap { id in items.first { $0.id == id } }
            shown = used + items.filter { i in !used.contains { $0.id == i.id } }
        } else {
            shown = items.compactMap { item -> (PaletteItem, Int)? in
                // Keywords: word-prefix matches rank higher; non-Recent items also allow fuzzy subsequence matching
                // (so "dkm" finds "dark mode" while an APK path in Recent won't match arbitrary letters).
                let ql = q.lowercased()
                let kwPrefix: Int? = item.keywords.lowercased().split(separator: " ").contains { $0.hasPrefix(ql) } ? 20 : nil
                let kwFuzzy: Int? = (kwPrefix == nil && item.group != "Recent" && !item.keywords.isEmpty)
                    ? Self.score(q, item.keywords).map { max(1, $0 - 8) }
                    : nil
                let best = [Self.score(q, item.title), kwPrefix, kwFuzzy].compactMap { $0 }.max()
                guard let s = best else { return nil }
                let boost = recent.firstIndex(of: item.id).map { max(0, 6 - $0) } ?? 0
                return (item, s + boost)
            }.sorted { $0.1 > $1.1 }.map(\.0)
        }
        none.isHidden = !shown.isEmpty
        let rowsHeight = shown.isEmpty ? 64 : CGFloat(min(shown.count, 9)) * 38
        height.constant = min(440, max(150, 96 + rowsHeight))
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
    }

    func controlTextDidChange(_ note: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): step(1); return true
        case #selector(NSResponder.moveUp(_:)): step(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): onClose?(); return true
        default: return false
        }
    }

    private func step(_ by: Int) {
        guard !shown.isEmpty else { return }
        let next = min(max(table.selectedRow + by, 0), shown.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func clicked() { if table.clickedRow >= 0 { table.selectRowIndexes([table.clickedRow], byExtendingSelection: false); runSelected() } }

    /// Runs the selected item after the palette has gone (so a command that opens a sheet or pane is not covered).
    func runSelected() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        let item = shown[row]
        if !isPicker {
            var recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
            recent.removeAll { $0 == item.id }
            recent.insert(item.id, at: 0)
            UserDefaults.standard.set(Array(recent.prefix(8)), forKey: Self.recentKey)
        }
        onClose?()
        DispatchQueue.main.async { item.run() }
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = shown[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13.5, weight: .medium)) ?? NSImage())
        icon.contentTintColor = Design.mute
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let title = NSTextField(labelWithString: "")
        title.attributedStringValue = highlightedTitle(item.title, query: field.stringValue)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let group = NSTextField(labelWithString: item.group)
        group.font = .systemFont(ofSize: 11, weight: .medium)
        group.textColor = Design.mute.withAlphaComponent(0.75)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        var views: [NSView] = [icon, title, spacer, group]
        if !item.shortcut.isEmpty {
            let keys = NSTextField(labelWithString: item.shortcut)
            keys.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            keys.textColor = Design.mute
            let cap = NSView()
            cap.wantsLayer = true
            cap.layer?.cornerRadius = 5
            cap.layer?.backgroundColor = Design.well.cgColor
            cap.layer?.borderWidth = 1
            cap.layer?.borderColor = Design.stroke.cgColor
            keys.translatesAutoresizingMaskIntoConstraints = false
            cap.addSubview(keys)
            NSLayoutConstraint.activate([
                keys.topAnchor.constraint(equalTo: cap.topAnchor, constant: 2),
                keys.bottomAnchor.constraint(equalTo: cap.bottomAnchor, constant: -2),
                keys.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: 6),
                keys.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -6),
            ])
            views.append(cap)
        }
        let r = NSStackView(views: views)
        r.alignment = .centerY
        r.spacing = 9
        r.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        return r
    }

    private func highlightedTitle(_ text: String, query: String) -> NSAttributedString {
        let base = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: Design.ink,
        ])
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return base }
        var qi = 0
        var idx = text.startIndex
        while idx < text.endIndex && qi < q.count {
            let next = text.index(after: idx)
            if String(text[idx]).lowercased().first == q[qi] {
                let nsRange = NSRange(idx..<next, in: text)
                if nsRange.location + nsRange.length <= base.length {
                    base.addAttributes([
                        .foregroundColor: Design.accent,
                        .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
                    ], range: nsRange)
                }
                qi += 1
            }
            idx = next
        }
        return base
    }
}

private final class PaletteRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Design.accent.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}
