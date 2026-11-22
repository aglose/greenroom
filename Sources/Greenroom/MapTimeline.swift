import AppKit

// The map's time axis (docs/MAP-HISTORY-PLAN.md, "The canvas at scale", History): the snapshots of one profile in
// commit order across a strip about 44 points high, a mark for each, two handles that say which two the map compares,
// and a popup at each end to pick by name. The owner gives it the snapshots and hears `onChange(base, head)`; the
// canvas below redraws. The strip only holds the pair, it never reads a snapshot.

/// One snapshot as the strip shows it: what it is called, when it was made, and how much it changed against the
/// snapshot before it (the first has no predecessor: all zeros).
struct MapTimelineEntry: Equatable {
    var commit: String
    /// The short label for the popup and the tag text ("53ffe80").
    var label: String
    var date: Date?
    /// A release or a name worth finding: larger mark, its text stays when the marks crowd.
    var tag: String?
    var added = 0, removed = 0, modified = 0
    var changed: Int { added + removed + modified }
}

/// Where the strip puts its marks and tag labels for a width: pure, so the check can lay out 500 snapshots without a
/// window and look for labels that touch.
enum MapTimelineLayout {
    struct Mark: Equatable {
        /// The entries this mark stands for (one when there is room, more when they merge into density).
        var entries: ClosedRange<Int>
        var x: CGFloat
        var isTag: Bool
        var changed: Int
    }

    static let pad: CGFloat = 10
    /// The least distance between two marks' centres; entries nearer than this merge.
    static let gap: CGFloat = 5

    static func x(_ index: Int, count: Int, width: CGFloat) -> CGFloat {
        count <= 1 ? width / 2 : pad + CGFloat(index) * (width - 2 * pad) / CGFloat(count - 1)
    }

    /// The entry nearest to `x`.
    static func index(at x: CGFloat, count: Int, width: CGFloat) -> Int {
        guard count > 1, width > 2 * pad else { return 0 }
        return min(count - 1, max(0, Int(((x - pad) / (width - 2 * pad) * CGFloat(count - 1)).rounded())))
    }

    /// One mark for each tag, and for each run of entries that fall within `gap` of each other. A tag never merges.
    static func marks(_ entries: [MapTimelineEntry], width: CGFloat) -> [Mark] {
        var out: [Mark] = []
        var open: Mark?
        for (i, e) in entries.enumerated() {
            let x = x(i, count: entries.count, width: width)
            if e.tag != nil {
                if let o = open { out.append(o); open = nil }
                out.append(Mark(entries: i...i, x: x, isTag: true, changed: e.changed))
            } else if var o = open, x - o.x < gap {
                o.entries = o.entries.lowerBound...i
                o.changed += e.changed
                open = o
            } else {
                if let o = open { out.append(o) }
                open = Mark(entries: i...i, x: x, isTag: false, changed: e.changed)
            }
        }
        if let o = open { out.append(o) }
        return out
    }

    /// Which tags get their text: left to right, a label that would touch the one before it (or the edge) is left out;
    /// its mark stays. `textWidth` measures a label.
    static func tagLabels(_ entries: [MapTimelineEntry], marks: [Mark], width: CGFloat, textWidth: (String) -> CGFloat) -> [(mark: Int, rect: CGRect)] {
        var out: [(mark: Int, rect: CGRect)] = []
        var right: CGFloat = -.infinity
        for (m, mark) in marks.enumerated() where mark.isTag {
            guard let text = entries[mark.entries.lowerBound].tag else { continue }
            let w = textWidth(text)
            let left = min(max(2, mark.x - w / 2), max(2, width - 2 - w))
            guard left >= right + 4 else { continue }
            out.append((m, CGRect(x: left, y: 0, width: w, height: 12)))
            right = left + w
        }
        return out
    }
}

final class MapTimeline: NSView {
    /// The pair now chosen, as commits, base first. Called when a handle moves to another snapshot.
    var onChange: ((String, String) -> Void)?
    static let height: CGFloat = 44

    private(set) var entries: [MapTimelineEntry] = []
    /// Indices into `entries`; base is never after head.
    private(set) var baseIndex = 0
    private(set) var headIndex = 0
    var base: String? { entries.indices.contains(baseIndex) ? entries[baseIndex].commit : nil }
    var head: String? { entries.indices.contains(headIndex) ? entries[headIndex].commit : nil }

    let basePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let headPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var marks: [MapTimelineLayout.Mark] = []
    private var labels: [(mark: Int, rect: CGRect)] = []
    private var dragging: Handle?
    private enum Handle { case base, head }
    private let popupWidth: CGFloat = 118
    private static let tagFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)

    /// The strip between the two popups, in this view's coordinates.
    private var track: CGRect { CGRect(x: popupWidth + 8, y: 0, width: max(0, bounds.width - 2 * (popupWidth + 8)), height: bounds.height) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Design.well.cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        for (p, side) in [(basePopup, Handle.base), (headPopup, Handle.head)] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: 11)
            p.target = self
            p.action = side == .base ? #selector(basePicked) : #selector(headPicked)
            p.translatesAutoresizingMaskIntoConstraints = false
            addSubview(p)
        }
        NSLayoutConstraint.activate([
            basePopup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), basePopup.centerYAnchor.constraint(equalTo: centerYAnchor),
            basePopup.widthAnchor.constraint(equalToConstant: popupWidth),
            headPopup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), headPopup.centerYAnchor.constraint(equalTo: centerYAnchor),
            headPopup.widthAnchor.constraint(equalToConstant: popupWidth),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Compared snapshots")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    /// Shows the snapshots, oldest first, with `base` and `head` chosen (the first and last when nil or unknown).
    func show(_ entries: [MapTimelineEntry], base: String? = nil, head: String? = nil) {
        self.entries = entries
        headIndex = head.flatMap { h in entries.firstIndex { $0.commit == h } } ?? max(0, entries.count - 1)
        baseIndex = min(headIndex, base.flatMap { b in entries.firstIndex { $0.commit == b } } ?? max(0, headIndex - 1))
        for p in [basePopup, headPopup] {
            p.removeAllItems()
            for e in entries { p.addItem(withTitle: e.label + (e.tag.map { "  " + $0 } ?? "")) }
        }
        relayout()
    }

    /// Moves a handle. Refused (false, nothing changes) when the base would come after the head or an index is
    /// outside the snapshots. `onChange` fires when the pair is another pair.
    @discardableResult
    func set(base: Int? = nil, head: Int? = nil) -> Bool {
        let b = base ?? baseIndex, h = head ?? headIndex
        guard entries.indices.contains(b), entries.indices.contains(h), b <= h else { relayout(); return false }
        let changed = b != baseIndex || h != headIndex
        baseIndex = b; headIndex = h
        relayout()
        if changed, let x = self.base, let y = self.head { onChange?(x, y) }
        return true
    }

    @objc private func basePicked() { if !set(base: basePopup.indexOfSelectedItem) { relayout() } }
    @objc private func headPicked() { if !set(head: headPopup.indexOfSelectedItem) { relayout() } }

    // MARK: Layout

    private func relayout() {
        guard !entries.isEmpty else { marks = []; labels = []; needsDisplay = true; return }
        basePopup.selectItem(at: baseIndex)
        headPopup.selectItem(at: headIndex)
        marks = MapTimelineLayout.marks(entries, width: track.width)
        labels = MapTimelineLayout.tagLabels(entries, marks: marks, width: track.width) { text in
            ceil((text as NSString).size(withAttributes: [.font: Self.tagFont]).width)
        }
        needsDisplay = true
        setAccessibilityValue(entries.isEmpty ? "" : "base \(entries[baseIndex].label), head \(entries[headIndex].label)")
    }

    override func layout() { super.layout(); relayout() }

    /// The tag labels as drawn, in this view's coordinates (for the check: none may touch another).
    var tagLabelRects: [CGRect] { labels.map { $0.rect.offsetBy(dx: track.minX, dy: bounds.height - 13) } }
    var markCount: Int { marks.count }
    /// Where a snapshot's handle stands, in this view's coordinates.
    func handleX(_ index: Int) -> CGFloat { track.minX + MapTimelineLayout.x(index, count: entries.count, width: track.width) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !entries.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = track
        let maxChanged = max(1, marks.map(\.changed).max() ?? 1)
        // The span between the handles.
        let lo = handleX(baseIndex), hi = handleX(headIndex)
        ctx.setFillColor(Design.wellOn.cgColor)
        ctx.fill(CGRect(x: lo, y: 14, width: max(1, hi - lo), height: 2))
        ctx.setFillColor(Design.stroke.cgColor)
        ctx.fill(CGRect(x: t.minX + MapTimelineLayout.pad, y: 14, width: max(0, t.width - 2 * MapTimelineLayout.pad), height: 1))

        for m in marks {
            let x = t.minX + m.x
            let inside = x >= lo - 0.5 && x <= hi + 0.5
            let size: CGFloat = m.isTag ? 7 : (m.entries.count > 1 ? 4 : 3.5)
            // A bar for how much changed, on a square-root scale so one big change does not flatten the rest.
            if m.changed > 0 {
                let h = 2 + 10 * (CGFloat(m.changed) / CGFloat(maxChanged)).squareRoot()
                ctx.setFillColor((inside ? Design.warning : Design.mute.withAlphaComponent(0.6)).cgColor)
                ctx.fill(CGRect(x: x - 1, y: 18, width: 2, height: h))
            }
            ctx.setFillColor((m.isTag ? Design.ink : (inside ? Design.ink : Design.mute)).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - size / 2, y: 15 - size / 2, width: size, height: size))
        }
        for l in labels {
            guard let text = entries[marks[l.mark].entries.lowerBound].tag else { continue }
            (text as NSString).draw(at: CGPoint(x: t.minX + l.rect.minX, y: bounds.height - 13),
                                    withAttributes: [.font: Self.tagFont, .foregroundColor: Design.mute])
        }
        for (i, color) in [(baseIndex, Design.warning), (headIndex, Design.accent)] {
            let x = handleX(i)
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: x - 1, y: 3, width: 2, height: 24))
            ctx.fillEllipse(in: CGRect(x: x - 4.5, y: 1, width: 9, height: 9))
        }
        // The handles say which is which for a person who cannot tell the colours apart.
        for (i, text) in [(baseIndex, "base"), (headIndex, "head")] where baseIndex != headIndex {
            let x = handleX(i)
            (text as NSString).draw(at: CGPoint(x: x + 5, y: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .semibold), .foregroundColor: Design.mute])
        }
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        guard !entries.isEmpty else { return }
        let x = convert(event.locationInWindow, from: nil).x
        guard x >= track.minX - 4, x <= track.maxX + 4 else { return }
        // The nearer handle takes it; on a tie, the head (the one a click most often means).
        dragging = abs(x - handleX(baseIndex)) < abs(x - handleX(headIndex)) ? .base : .head
        move(to: x)
    }
    override func mouseDragged(with event: NSEvent) { if dragging != nil { move(to: convert(event.locationInWindow, from: nil).x) } }
    override func mouseUp(with event: NSEvent) { dragging = nil }

    private func move(to x: CGFloat) {
        let i = MapTimelineLayout.index(at: x - track.minX, count: entries.count, width: track.width)
        switch dragging {
        // Dragged past the other handle, a handle stops against it.
        case .base: set(base: min(i, headIndex))
        case .head: set(head: max(i, baseIndex))
        case nil: break
        }
    }
}
