import AppKit

/// The chosen simulator's requests as they happen: conditions to apply, a filter, the list with a waterfall, and the
/// selected exchange's headers and bodies (asked of the engine when it is selected). Floats over the stage on glass.
final class NetworkPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let glass = GlassView(radius: 18)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let filter = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private var conditionButtons: [GlassButton] = []
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailStatus = NSTextField(labelWithString: "")
    private var tabButtons: [GlassButton] = []
    private let detailText = NSTextView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private weak var simulator: Simulator?
    private var shown: [NetEvent] = []
    private var detail: [String: Any]?
    private var tab = 2   // Headers, Request, Response
    private var condition = "online"
    /// The request under the timeline's playhead, marked in the list.
    private(set) var atPlayhead: Int?
    /// Called when a request is picked in the list (not when the timeline picks one).
    var onSelect: ((NetEvent) -> Void)?
    private var revealing = false

    private static let conditions = [("online", "Online"), ("3g", "3G"), ("lossy", "Lossy"), ("offline", "Offline")]
    private static let columns: [(String, String, CGFloat)] = [("method", "Method", 66), ("url", "Request", 210), ("status", "Status", 50),
                                                               ("size", "Size", 74), ("time", "Time", 60), ("fall", "Waterfall", 84)]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let title = NSTextField(labelWithString: "Network")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Design.ink
        count.font = .systemFont(ofSize: 12)
        count.textColor = Design.mute
        conditionButtons = Self.conditions.map { id, name in
            let b = GlassButton(symbol: nil, title: name, label: "Network conditions: \(name)", target: self, action: #selector(conditionPicked(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(id)
            return b
        }
        filter.placeholderString = "Filter by host, path or status"
        filter.controlSize = .small
        filter.delegate = self

        for (id, _, width) in Self.columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.width = width
            c.minWidth = id == "url" ? 120 : width
            c.resizingMask = id == "url" ? .autoresizingMask : []
            table.addTableColumn(c)
        }
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false

        let heads = NSStackView(views: Self.columns.map { _, name, width in
            let l = NSTextField(labelWithString: name)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = Design.mute
            if name != "Request" { l.widthAnchor.constraint(equalToConstant: width).isActive = true }
            else { l.setContentHuggingPriority(.init(1), for: .horizontal) }
            return l
        })
        heads.spacing = 8

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0, alpha: 0.3).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Design.stroke.cgColor
        detailTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        detailTitle.textColor = Design.ink
        detailTitle.lineBreakMode = .byTruncatingMiddle
        detailTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailStatus.font = .systemFont(ofSize: 12, weight: .semibold)
        tabButtons = ["Headers", "Request", "Response"].enumerated().map { i, name in
            let b = GlassButton(symbol: nil, title: name, label: name, target: self, action: #selector(tabPicked(_:)))
            b.tag = i
            return b
        }
        detailText.isEditable = false
        detailText.isRichText = true
        detailText.drawsBackground = false
        detailText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailText.textColor = Design.ink
        detailText.textContainerInset = NSSize(width: 4, height: 6)
        detailText.autoresizingMask = [.width]
        let detailScroll = NSScrollView()
        detailScroll.documentView = detailText
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        let tabs = NSStackView(views: tabButtons)
        tabs.spacing = 2
        let detailHead = NSStackView(views: [detailTitle, detailStatus, NSView(), tabs])
        detailHead.spacing = 8
        for v in [detailHead, detailScroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(v) }

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = Design.mute
        empty.alignment = .center
        empty.stringValue = "Requests show here as the app makes them. They are read from the app's own connections as they pass: nothing to set up and nothing changed."

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [title, count, spacer] + conditionButtons)
        top.spacing = 4
        for v in [top, filter, heads, scroll, empty, card] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            filter.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            heads.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 12),
            heads.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            heads.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: heads.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.42),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            card.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            detailHead.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            detailHead.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            detailHead.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            detailScroll.topAnchor.constraint(equalTo: detailHead.bottomAnchor, constant: 8),
            detailScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            detailScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -6),
            detailScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        refreshButtons()
        showDetail()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lists this simulator's requests from now on (nil: none).
    func follow(_ sim: Simulator?) {
        guard sim !== simulator else { return }
        simulator?.activity.onRequests = nil
        simulator = sim
        sim?.activity.onRequests = { [weak self] in self?.reload() }
        detail = nil
        atPlayhead = nil
        reload()
        showDetail()
    }

    func reload() {
        let all = simulator?.activity.requests ?? []
        let f = filter.stringValue.trimmingCharacters(in: .whitespaces)
        let selectedID = table.selectedRow >= 0 && table.selectedRow < shown.count ? shown[table.selectedRow].id : nil
        let atEnd = scroll.contentView.bounds.maxY >= table.frame.maxY - 40
        shown = f.isEmpty ? all : all.filter { $0.url.localizedCaseInsensitiveContains(f) || String($0.status) == f || $0.method.localizedCaseInsensitiveContains(f) }
        count.stringValue = all.isEmpty ? "" : (shown.count == all.count ? "\(all.count)" : "\(shown.count) of \(all.count)")
        empty.isHidden = !all.isEmpty
        revealing = true
        table.reloadData()
        if let id = selectedID, let i = shown.firstIndex(where: { $0.id == id }) { table.selectRowIndexes([i], byExtendingSelection: false) }
        revealing = false
        if atEnd, selectedID == nil, !shown.isEmpty { table.scrollRowToVisible(shown.count - 1) }
    }

    /// Selects the request at this moment (the one under way then, else the nearest to start), from the timeline.
    func reveal(at time: Date) {
        guard !shown.isEmpty else { return }
        let hit = shown.last { $0.start <= time && $0.end.addingTimeInterval(0.05) >= time }
            ?? shown.min { abs($0.start.timeIntervalSince(time)) < abs($1.start.timeIntervalSince(time)) }
        guard let hit, let i = shown.firstIndex(where: { $0.id == hit.id }) else { return }
        atPlayhead = hit.id
        revealing = true
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
        revealing = false
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<shown.count), columnIndexes: [1])
        load(hit)
    }

    // MARK: Conditions

    @objc private func conditionPicked(_ sender: GlassButton) {
        guard let id = sender.identifier?.rawValue, let sim = simulator else { return }
        sim.send("network \(id)") { [weak self] answer in
            guard let self, !answer.hasPrefix("error") else { return }
            self.condition = id
            self.refreshButtons()
        }
    }

    private func refreshButtons() {
        for b in conditionButtons {
            // The chosen condition is lit: green while online, the warning tint while the network is held back.
            let on = b.identifier?.rawValue == condition
            b.style = on && condition != "online" ? .record : .plain
            b.isOn = on
        }
        for b in tabButtons { b.isOn = b.tag == tab }
    }

    func controlTextDidChange(_ note: Notification) { reload() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RoundRow() }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let e = shown[row]
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        func label(_ s: String, _ color: NSColor = Design.ink, font: NSFont = mono) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = font
            l.textColor = color
            l.lineBreakMode = .byTruncatingTail
            return l
        }
        // Each cell's text sits on the row's middle line.
        func centred(_ l: NSView) -> NSView {
            let box = NSView()
            l.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(l)
            NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: box.leadingAnchor), l.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                                         l.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
            return box
        }
        switch column?.identifier.rawValue {
        case "method":
            let color: NSColor = e.method == "GET" ? Design.accent : e.method == "CONNECT" || e.method == "DNS" ? Design.mute : NSColor(srgbRed: 0.5, green: 0.72, blue: 1, alpha: 1)
            return centred(label(e.method, color))
        case "url":
            let text = NSMutableAttributedString(string: e.shortURL, attributes: [.font: mono, .foregroundColor: Design.ink])
            func tag(_ s: String, _ color: NSColor) {
                text.append(NSAttributedString(string: "  " + s, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color]))
            }
            if e.id == atPlayhead { tag("at playhead", NSColor(srgbRed: 1, green: 0.70, blue: 0.68, alpha: 1)) }
            if e.mocked { tag("rule", Design.difference) }
            let l = label("")
            l.attributedStringValue = text
            l.lineBreakMode = .byTruncatingMiddle
            return centred(l)
        case "status":
            let s = e.status == 0 ? "failed" : String(e.status)
            return centred(label(s, e.failed ? NSColor(srgbRed: 1, green: 0.48, blue: 0.44, alpha: 1) : Design.ink))
        case "size": return centred(label(Self.bytes(e.respBytes), Design.mute))
        case "time": return centred(label(e.ms >= 1000 ? String(format: "%.1f s", Double(e.ms) / 1000) : "\(e.ms) ms", Design.mute))
        default:
            let first = shown.first?.start ?? e.start
            let last = shown.map(\.end).max() ?? e.end
            let span = max(last.timeIntervalSince(first), 0.001)
            let bar = WaterfallBar()
            bar.from = e.start.timeIntervalSince(first) / span
            bar.to = e.end.timeIntervalSince(first) / span
            bar.color = e.failed ? NSColor(srgbRed: 1, green: 0.48, blue: 0.44, alpha: 1) : e.mocked ? Design.difference : e.ms > 1000 ? Design.warning : Design.accent
            return bar
        }
    }

    func tableViewSelectionDidChange(_ note: Notification) {
        guard !revealing else { return }
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { detail = nil; showDetail(); return }
        let e = shown[row]
        load(e)
        onSelect?(e)
    }

    static func bytes(_ n: Int) -> String {
        if n < 0 { return "?" }
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f kB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }

    // MARK: Detail

    private func load(_ e: NetEvent) {
        detailTitle.stringValue = "\(e.method) \(e.shortURL)"
        detailStatus.stringValue = e.status == 0 ? "failed" : String(e.status)
        detailStatus.textColor = e.failed ? NSColor(srgbRed: 1, green: 0.6, blue: 0.56, alpha: 1) : Design.accent
        detail = nil
        detailText.string = "Loading…"
        simulator?.send("network detail \(e.id)") { [weak self] answer in
            guard let self else { return }
            if answer.hasPrefix("error") { self.detailText.string = answer.replacingOccurrences(of: "error: ", with: ""); return }
            self.detail = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String: Any]
            self.showDetail()
        }
    }

    @objc private func tabPicked(_ sender: GlassButton) {
        tab = sender.tag
        refreshButtons()
        showDetail()
    }

    private func showDetail() {
        guard let d = detail else {
            if table.selectedRow < 0 {
                detailTitle.stringValue = "No request selected"
                detailStatus.stringValue = ""
                detailText.string = "Pick a request to see its headers and bodies, or scrub the timeline to the moment it was made."
            }
            return
        }
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let out = NSMutableAttributedString()
        func line(_ s: String, _ color: NSColor = Design.ink) { out.append(NSAttributedString(string: s + "\n", attributes: [.font: mono, .foregroundColor: color])) }
        func headers(_ key: String) {
            for h in d[key] as? [[String]] ?? [] where h.count == 2 {
                out.append(NSAttributedString(string: h[0] + ": ", attributes: [.font: mono, .foregroundColor: NSColor(srgbRed: 0.5, green: 0.72, blue: 1, alpha: 1)]))
                line(h[1])
            }
        }
        switch tab {
        case 0:
            line("Request", Design.mute); headers("reqHeaders"); line("")
            line("Response", Design.mute); headers("respHeaders")
            if d["trailers"] != nil { line(""); line("Trailers", Design.mute); headers("trailers") }
            if let e = d["error"] as? String { line(""); line("Error: " + e, NSColor(srgbRed: 1, green: 0.6, blue: 0.56, alpha: 1)) }
        default:
            let side = tab == 1 ? "req" : "resp"
            let data = Data(base64Encoded: d["\(side)Body"] as? String ?? "") ?? Data()
            if data.isEmpty { line(tab == 1 ? "No request body." : "No response body.", Design.mute) }
            else if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                    let pretty = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                line(String(decoding: pretty, as: UTF8.self))
            } else if let text = String(data: data, encoding: .utf8) {
                line(text)
            } else {
                line("\(Self.bytes(data.count)) of binary data", Design.mute)
            }
            if d["\(side)Cut"] as? Bool == true { line("(cut: only the first part of the body is kept)", Design.mute) }
        }
        detailText.textStorage?.setAttributedString(out)
    }
}

/// A request's span within the visible list's time, as a rounded bar.
private final class WaterfallBar: NSView {
    var from = 0.0, to = 0.0
    var color = Design.accent
    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let x = CGFloat(from) * w
        let width = max(5, CGFloat(to - from) * w)
        let r = NSRect(x: min(x, w - 3), y: bounds.midY - 3, width: min(width, w - min(x, w - 3)), height: 6)
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
    }
}

/// A selected row as a soft rounded tint rather than the system's bar.
private final class RoundRow: NSTableRowView {
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
