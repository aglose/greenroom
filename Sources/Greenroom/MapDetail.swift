import AppKit

// The detail column of the map when history is on (docs/MAP-HISTORY-PLAN.md, "The canvas at scale", Detail and
// History): for the selected lineage its status in words, base, head and difference pictures, what changed as lists,
// the route and controls the old detail showed, and a filmstrip of its captures across the snapshots. It sits beside
// the map and is told which lineage is selected; it reads nothing itself: the owner hands it the two snapshots, their
// difference, the history and a way to turn a blob into a picture.

// MARK: - Pictures

/// The pictures of one lineage for a base and a head, per capture combination.
struct MapPictureSet {
    /// The combinations in order ("light", "dark"), those either side has a capture for.
    var combos: [String] = []
    var base: [String: CGImage] = [:]
    var head: [String: CGImage] = [:]
    /// Where the two differ: the head dimmed, the differing areas in magenta. Nil for a combination whose captures
    /// are the same, or whose pictures are not the same size.
    var difference: [String: CGImage] = [:]
    var differing: [String: (differing: Int, total: Int)] = [:]
    /// Both sides exist: base, head and difference make sense. Else the one picture there is, in `head`.
    var compares = false
    /// What the single picture is called ("Added", "Removed", "Head").
    var single = "Head"

    /// The share of pixels that differ, the largest over the combinations.
    var percent: Double? {
        let all = differing.values.filter { $0.total > 0 }.map { Double($0.differing) / Double($0.total) * 100 }
        return all.max()
    }

    /// Resolves the blobs of `lineage` in `base` and `head` through `image` and calls `done` (on the main thread, once)
    /// with what it got. A picture that does not come stays out of the set.
    static func load(base: MapSnapshot.Screen?, head: MapSnapshot.Screen?, order: [String], image: @escaping (String, @escaping (CGImage?) -> Void) -> Void,
                     done: @escaping (MapPictureSet) -> Void) {
        var set = MapPictureSet()
        let keys = Set(base?.captures.keys ?? [:].keys).union(head?.captures.keys ?? [:].keys)
        set.combos = order.filter(keys.contains) + keys.subtracting(order).sorted()
        set.compares = base != nil && head != nil
        set.single = head == nil ? "Removed" : (base == nil ? "Added" : "Head")
        var wanted: [(side: Int, combo: String, blob: String)] = []
        for c in set.combos {
            if let b = base?.captures[c] { wanted.append((0, c, b)) }
            if let h = head?.captures[c] { wanted.append((1, c, h)) }
        }
        // The head's picture when there is one; a removed screen has only the base's, kept as `head` so a single
        // picture is always in the same place.
        var got: [String: CGImage] = [:]
        var pending = Set(wanted.map(\.blob))
        func finish() {
            for c in set.combos {
                let b = base?.captures[c].flatMap { got[$0] }, h = head?.captures[c].flatMap { got[$0] }
                if let b { set.base[c] = b }
                if let h { set.head[c] = h }
                if !set.compares, let b { set.head[c] = b }
                if set.compares, let b, let h, base?.captures[c] != head?.captures[c], let d = difference(base: b, head: h) {
                    set.differing[c] = (d.differing, d.total)
                    if let img = d.image { set.difference[c] = img }
                }
            }
            done(set)
        }
        if pending.isEmpty { DispatchQueue.main.async(execute: finish); return }
        for blob in pending {
            image(blob) { img in
                if let img { got[blob] = img }
                pending.remove(blob)
                if pending.isEmpty { finish() }
            }
        }
    }

    /// How two captures differ, and a picture of where; nil when they are not the same size.
    static func difference(base: CGImage, head: CGImage) -> (differing: Int, total: Int, image: CGImage?)? {
        guard let p = ScreenComparison.pixels(a: base, b: head) else { return nil }
        guard p.differing > 0 else { return (0, p.total, nil) }
        var out: CGImage?
        if let png = ScreenComparison.map(b: head, cells: p.cells, maxSize: 0), let src = CGImageSourceCreateWithData(png as CFData, nil) {
            out = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        return (p.differing, p.total, out)
    }
}

enum MapPictureMode: Int, CaseIterable {
    case sideBySide, wipe, difference
    var title: String { ["Side by side", "Wipe", "Difference"][rawValue] }
    /// For the narrow column.
    var short: String { ["Sides", "Wipe", "Diff"][rawValue] }
}

// MARK: - The large viewer

/// Shared by the panes of one viewer: how far in, and which point of the picture is in the middle, as fractions of it.
/// Panes of different pictures of one screen stay on the same spot.
final class MapZoom {
    /// 1 is the picture fitted to its pane; more is nearer.
    var factor: CGFloat = 1 { didSet { factor = min(Self.most, max(1, factor)); if factor == 1 { center = CGPoint(x: 0.5, y: 0.5) } } }
    /// From the top left, 0...1.
    var center = CGPoint(x: 0.5, y: 0.5)
    static let most: CGFloat = 64
    var panes: [() -> MapZoomPane?] = []
    var onChange: (() -> Void)?
    func apply() { for p in panes { p()?.relayout() }; onChange?() }
}

/// One picture (or two, with a line between them) that zooms and pans: scrolling or dragging moves it, pinching or
/// ⌥-scrolling zooms, a double click toggles between fitted and actual pixels.
final class MapZoomPane: NSView {
    let zoom: MapZoom
    private let a = CALayer(), b = CALayer(), mask = CALayer(), line = CALayer()
    private let note = NSTextField(labelWithString: "")
    private(set) var imageA: CGImage?, imageB: CGImage?
    /// With two pictures: where the line stands, as a fraction of the pane's width; left of it `a`, right of it `b`.
    var split: CGFloat = 0.5 { didSet { relayout() } }

    init(zoom: MapZoom) {
        self.zoom = zoom
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        for l in [a, b] { l.magnificationFilter = .nearest; l.minificationFilter = .trilinear; layer?.addSublayer(l) }
        b.mask = mask
        mask.backgroundColor = NSColor.black.cgColor
        line.backgroundColor = Design.accent.cgColor
        layer?.addSublayer(line)
        note.font = .systemFont(ofSize: 12)
        note.textColor = Design.mute
        note.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)
        NSLayoutConstraint.activate([note.centerXAnchor.constraint(equalTo: centerXAnchor), note.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `second` makes it a wipe: `first` on the left of the line, `second` on the right.
    func show(_ first: CGImage?, second: CGImage? = nil, empty: String) {
        imageA = first; imageB = second
        CATransaction.begin(); CATransaction.setDisableActions(true)
        a.contents = first; b.contents = second
        CATransaction.commit()
        note.stringValue = first == nil && second == nil ? empty : ""
        relayout()
    }

    private var size: CGSize { (imageB ?? imageA).map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    /// Points per picture pixel when fitted.
    private var fit: CGFloat { size.width > 0 && bounds.width > 0 ? min(bounds.width / size.width, bounds.height / size.height) : 1 }
    /// The scale at which one picture pixel is one screen pixel.
    var actualFactor: CGFloat { 1 / ((window?.backingScaleFactor ?? 2) * fit) }
    /// Points per picture pixel now.
    var scale: CGFloat { fit * zoom.factor }

    override func layout() { super.layout(); relayout() }

    func relayout() {
        guard size.width > 0 else { return }
        let s = scale, w = size.width * s, h = size.height * s
        let frame = CGRect(x: bounds.midX - zoom.center.x * w, y: bounds.midY - (1 - zoom.center.y) * h, width: w, height: h)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        a.frame = frame; b.frame = frame
        let x = bounds.width * split
        mask.frame = CGRect(x: x - frame.minX, y: 0, width: frame.width * 2, height: h)
        line.isHidden = imageB == nil
        line.frame = CGRect(x: x - 1, y: 0, width: 2, height: bounds.height)
        CATransaction.commit()
    }

    private func zoomBy(_ k: CGFloat, at point: NSPoint) {
        guard size.width > 0 else { return }
        // Keep the picture point under the pointer where it is.
        let w = size.width * scale, h = size.height * scale
        let fx = (point.x - (bounds.midX - zoom.center.x * w)) / w, fy = 1 - (point.y - (bounds.midY - (1 - zoom.center.y) * h)) / h
        zoom.factor *= k
        let w2 = size.width * scale, h2 = size.height * scale
        zoom.center = CGPoint(x: fx - (point.x - bounds.midX) / w2, y: fy + (point.y - bounds.midY) / h2)
        clampCenter()
        zoom.apply()
    }

    func setFactor(_ f: CGFloat) {
        zoom.factor = f
        clampCenter()
        zoom.apply()
    }

    private func clampCenter() {
        let w = size.width * scale, h = size.height * scale
        zoom.center.x = min(1, max(0, zoom.center.x))
        zoom.center.y = min(1, max(0, zoom.center.y))
        if w <= bounds.width { zoom.center.x = 0.5 }
        if h <= bounds.height { zoom.center.y = 0.5 }
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        guard size.width > 0 else { return }
        zoom.center.x -= dx / (size.width * scale)
        zoom.center.y += dy / (size.height * scale)
        clampCenter()
        zoom.apply()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            zoomBy(exp(event.scrollingDeltaY / 120), at: convert(event.locationInWindow, from: nil))
        } else {
            pan(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)
        }
    }
    override func magnify(with event: NSEvent) { zoomBy(1 + event.magnification, at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { pan(dx: event.deltaX, dy: -event.deltaY) }
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        if zoom.factor > 1.01 { setFactor(1) }
        else {
            zoomBy(1, at: convert(event.locationInWindow, from: nil))
            let p = convert(event.locationInWindow, from: nil)
            zoomBy(actualFactor / zoom.factor, at: p)
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: zoom.factor > 1.01 ? .openHand : .arrow) }
}

/// The large viewer: the pictures at up to actual pixels, panning together, in the three modes.
final class MapPictureViewer: NSView {
    let pics: MapPictureSet
    private(set) var mode: MapPictureMode
    private(set) var combo: String
    let zoom = MapZoom()
    private let modeControl = NSSegmentedControl(labels: MapPictureMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let comboControl: NSSegmentedControl
    private let zoomLabel = NSTextField(labelWithString: "Fit")
    private let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let panes = NSStackView()
    private var current: [MapZoomPane] = []
    var onClose: (() -> Void)?

    init(set pics: MapPictureSet, mode: MapPictureMode, combo: String) {
        self.pics = pics
        self.mode = pics.compares ? mode : .sideBySide
        self.combo = pics.combos.contains(combo) ? combo : (pics.combos.first ?? combo)
        comboControl = NSSegmentedControl(labels: pics.combos.map { $0.capitalized }, trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 820))
        wantsLayer = true
        layer?.backgroundColor = Design.stage.cgColor

        modeControl.selectedSegment = self.mode.rawValue
        modeControl.target = self; modeControl.action = #selector(modePicked)
        comboControl.selectedSegment = pics.combos.firstIndex(of: self.combo) ?? 0
        comboControl.target = self; comboControl.action = #selector(comboPicked)
        slider.target = self; slider.action = #selector(wipeMoved)
        slider.controlSize = .small
        slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.textColor = Design.mute
        zoomLabel.alignment = .right
        zoomLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let fitButton = GlassButton(symbol: nil, title: "Fit", label: "Fit the picture to the window", style: .well, target: self, action: #selector(fitPressed))
        let actualButton = GlassButton(symbol: nil, title: "100%", label: "Actual pixels", style: .well, target: self, action: #selector(actualPressed))
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var bar: [NSView] = []
        if pics.compares { bar.append(modeControl) }
        if pics.combos.count > 1 { bar.append(comboControl) }
        bar += [slider, spacer, zoomLabel, fitButton, actualButton]
        let toolbar = NSStackView(views: bar)
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        panes.spacing = 12
        panes.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar); addSubview(panes)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 12), toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            panes.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12), panes.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            panes.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), panes.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        zoom.onChange = { [weak self] in self?.updateZoomLabel() }
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func modePicked() { setMode(MapPictureMode(rawValue: modeControl.selectedSegment) ?? .sideBySide) }
    /// Switches the viewer to another mode (what the segmented control does).
    func setMode(_ m: MapPictureMode) {
        guard pics.compares else { return }
        mode = m
        modeControl.selectedSegment = m.rawValue
        zoom.factor = 1
        rebuild()
    }
    @objc private func comboPicked() { combo = pics.combos[max(0, comboControl.selectedSegment)]; rebuild() }
    @objc private func wipeMoved() { for p in current { p.split = CGFloat(slider.doubleValue) } }
    @objc private func fitPressed() { current.first?.setFactor(1) }
    @objc private func actualPressed() { if let p = current.first { p.setFactor(p.actualFactor) } }

    /// The zoom as a person reads it: fitted, or the percentage of actual pixels.
    var zoomText: String { zoomLabel.stringValue }
    private func updateZoomLabel() {
        guard let p = current.first else { return }
        zoomLabel.stringValue = zoom.factor <= 1.001 ? "Fit" : String(format: "%.0f%%", p.scale * (window?.backingScaleFactor ?? 2) * 100)
    }
    /// How many panes show now, and the scale of the first, for the check.
    var paneCount: Int { current.count }
    var firstPane: MapZoomPane? { current.first }

    private func rebuild() {
        for v in panes.arrangedSubviews { panes.removeArrangedSubview(v); v.removeFromSuperview() }
        current = []
        slider.isHidden = !(pics.compares && mode == .wipe)
        func column(_ name: String, _ pane: MapZoomPane) -> NSView {
            let l = NSTextField(labelWithString: name)
            l.font = .systemFont(ofSize: 11, weight: .medium)
            l.textColor = Design.mute
            let c = NSStackView(views: [l, pane])
            c.orientation = .vertical
            c.alignment = .centerX
            c.spacing = 4
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.widthAnchor.constraint(equalTo: c.widthAnchor).isActive = true
            return c
        }
        func pane() -> MapZoomPane { let p = MapZoomPane(zoom: zoom); current.append(p); return p }
        let base = pics.base[combo], head = pics.head[combo], diff = pics.difference[combo]
        if !pics.compares {
            let p = pane(); p.show(head, empty: "No capture")
            panes.addArrangedSubview(column(pics.single, p))
        } else {
            switch mode {
            case .sideBySide:
                let p1 = pane(), p2 = pane(), p3 = pane()
                p1.show(base, empty: "No capture"); p2.show(head, empty: "No capture")
                p3.show(diff, empty: differenceNote)
                for (n, p) in [("Base", p1), ("Head", p2), ("Difference", p3)] { panes.addArrangedSubview(column(n, p)) }
            case .wipe:
                let p = pane(); p.show(base, second: head, empty: "No capture"); p.split = CGFloat(slider.doubleValue)
                panes.addArrangedSubview(column("Base | Head", p))
            case .difference:
                let p = pane(); p.show(diff, empty: differenceNote)
                panes.addArrangedSubview(column("Difference", p))
            }
        }
        zoom.panes = current.map { p in { [weak p] in p } }
        zoom.center = CGPoint(x: 0.5, y: 0.5)
        zoom.factor = 1
        needsLayout = true
        updateZoomLabel()
    }

    private var differenceNote: String {
        pics.differing[combo] == nil ? (pics.base[combo] == nil || pics.head[combo] == nil ? "No capture" : "Same pixels") : "Pictures of different sizes"
    }

    /// Opens a viewer in a window of its own.
    @discardableResult
    static func open(_ pics: MapPictureSet, mode: MapPictureMode, combo: String, title: String) -> NSWindow {
        let v = MapPictureViewer(set: pics, mode: mode, combo: combo)
        let w = NSWindow(contentRect: v.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Design.stage
        w.isReleasedWhenClosed = false
        w.contentView = v
        w.contentMinSize = NSSize(width: 520, height: 420)
        w.center()
        w.makeKeyAndOrderFront(nil)
        return w
    }
}

// MARK: - The column

/// One row of a list: a mark, a line, and where it leads (a press goes there, when it has a target).
private final class MapDetailRow: NSView {
    var onPress: (() -> Void)?
    private var hovering = false { didSet { layer?.backgroundColor = (hovering && onPress != nil ? Design.wellOn : .clear).cgColor } }

    init(mark: String, color: NSColor, text: String, trailing: String? = nil, trailingColor: NSColor = Design.mute, textColor: NSColor = Design.ink) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        let m = NSTextField(labelWithString: mark)
        m.font = .systemFont(ofSize: 12, weight: .bold)
        m.textColor = color
        m.alignment = .center
        m.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let t = NSTextField(labelWithString: text)
        t.font = .systemFont(ofSize: 12)
        t.textColor = textColor
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.init(2), for: .horizontal)
        var views: [NSView] = [m, t]
        if let trailing {
            let to = NSTextField(labelWithString: trailing)
            to.font = .systemFont(ofSize: 12)
            to.textColor = trailingColor
            to.lineBreakMode = .byTruncatingTail
            to.alignment = .right
            to.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            views.append(to)
        }
        toolTip = text + (trailing.map { "  " + $0 } ?? "")
        let row = NSStackView(views: views)
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func resetCursorRects() { if onPress != nil { addCursorRect(bounds, cursor: .pointingHand) } }
}

private final class MapDetailFlipped: NSView { override var isFlipped: Bool { true } }

/// One frame of the filmstrip: a run of consecutive snapshots in which the screen's captures were the same.
struct MapFilmFrame: Equatable {
    /// The first and last commit of the run, oldest first.
    var first: String, last: String
    var count: Int
    /// The captures by combination; empty when the screen was not in these snapshots.
    var captures: [String: String]
    /// It differs from the frame before it (the first frame is not marked).
    var changed: Bool
    var present: Bool { !captures.isEmpty }
    /// "53ffe80" or "53ffe80 – 1f0e9a2".
    var label: String { first == last ? String(first.prefix(7)) : String(first.prefix(7)) + " – " + String(last.prefix(7)) }
}

final class MapDetail: NSView {
    // What the owner hears.
    /// A control or a changed route that leads to another screen was pressed: select that lineage.
    var onSelect: ((String) -> Void)?
    /// "Go there": replay the selected lineage's route.
    var onGo: ((String) -> Void)?
    /// The route was copied; the argument is the commands (the pasteboard has them already).
    var onCopyRoute: ((String) -> Void)?
    /// A filmstrip frame was pressed: the commit to make the base.
    var onPickCommit: ((String) -> Void)?

    static let width: CGFloat = 330

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var image: (String, @escaping (CGImage?) -> Void) -> Void = { _, done in done(nil) }
    private var generation = 0

    // State the check reads.
    private(set) var lineage: String?
    private(set) var statusText = ""
    private(set) var pictures: MapPictureSet?
    private(set) var frames: [MapFilmFrame] = []
    private(set) var textLines: [String] = []
    private(set) var controlLines: [String] = []
    private(set) var mode: MapPictureMode = .sideBySide
    private(set) var combo = "light"
    private var viewerWindow: NSWindow?
    var viewer: NSWindow? { viewerWindow }

    private var screen: MapSnapshot.Screen?
    private var changedRows: [MapDetailRow] = []
    private var snapshot: MapSnapshot?
    private var diff: MapDiff?
    private var baseSnap: MapSnapshot?
    private var statusLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Design.well.cgColor
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let flip = MapDetailFlipped()
        stack.translatesAutoresizingMaskIntoConstraints = false
        flip.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(stack)
        scroll.documentView = flip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: flip.topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: flip.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: flip.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: flip.trailingAnchor, constant: -14),
            flip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Words

    /// A screen's change in words: "modified: visual 0.35%, 1 route added, 2 texts changed", "added", "removed",
    /// "same", "not compared: it never settles". `percent` is the share of pixels, once the pictures are compared.
    static func statusWords(_ change: MapDiff.ScreenChange?, edges: [MapDiff.EdgeChange], percent: Double?) -> String {
        guard let change else { return "no comparison" }
        switch change.status {
        case .added: return "added"
        case .removed: return "removed"
        case .same: return "same"
        case .notCompared:
            let why = change.why.map { $0.components(separatedBy: ", so ").first ?? $0 }
            return "not compared" + (why.map { ": " + $0 } ?? "")
        case .modified:
            var parts: [String] = []
            for reason in [MapDiff.Reason.visual, .structure, .routes, .text] where change.reasons.contains(reason) {
                switch reason {
                case .visual:
                    let p = percent ?? change.pixels.flatMap { px in px.values.filter { $0.total > 0 }.map { Double($0.differing) / Double($0.total) * 100 }.max() }
                    parts.append(p.map { $0 > 0 && $0 < 0.01 ? "visual <0.01%" : String(format: "visual %.2f%%", $0) } ?? "visual")
                case .structure: parts.append("structure changed")
                case .routes:
                    let mine = edges.filter { $0.from == change.lineage }
                    for (status, word) in [(MapDiff.EdgeChange.Status.added, "added"), (.removed, "removed"), (.retargeted, "redirected")] {
                        let n = mine.filter { $0.status == status }.count
                        if n > 0 { parts.append("\(n) route\(n == 1 ? "" : "s") \(word)") }
                    }
                case .text:
                    let n = change.textAdded.count + change.textRemoved.count
                    parts.append("\(n) text\(n == 1 ? "" : "s") changed")
                }
            }
            return "modified" + (parts.isEmpty ? "" : ": " + parts.joined(separator: ", "))
        }
    }

    private static func color(_ status: MapDiff.Status?) -> NSColor {
        switch status {
        case .added: return Design.accent
        case .removed: return Design.record
        case .modified: return Design.warning
        default: return Design.mute
        }
    }

    /// Where a control leads, in words: a screen's title, or what the walk saw.
    private func place(_ lineage: String?, in snaps: [MapSnapshot?]) -> (text: String, target: String?, color: NSColor) {
        switch lineage {
        case nil: return ("nowhere", nil, Design.mute)
        case "EXIT": return ("closes the app", nil, Design.warning)
        case "CRASH": return ("crashes", nil, Design.record)
        case "SKIPPED": return ("not tapped", nil, Design.mute)
        case "FAILED": return ("did not replay", nil, Design.warning)
        case "UNFOLLOWED": return ("not followed", nil, Design.mute)
        case let l?:
            for s in snaps.compactMap({ $0 }) { if let t = s.screens.first(where: { $0.lineage == l }) { return (t.title, l, Design.ink) } }
            return (l, nil, Design.mute)
        }
    }

    /// The frames of a lineage over the snapshots, oldest first: consecutive snapshots with the same captures collapse
    /// into one frame. A stretch where the screen was not there is a frame without captures; before the first
    /// appearance there is none.
    static func frames(lineage: String, history: [MapSnapshot]) -> [MapFilmFrame] {
        var out: [MapFilmFrame] = []
        var started = false
        for snap in history {
            let captures = snap.screens.first { $0.lineage == lineage }?.captures ?? [:]
            if captures.isEmpty && !started { continue }
            started = true
            if var last = out.last, last.captures == captures {
                last.last = snap.commit; last.count += 1
                out[out.count - 1] = last
            } else {
                out.append(MapFilmFrame(first: snap.commit, last: snap.commit, count: 1, captures: captures, changed: !out.isEmpty))
            }
        }
        return out
    }

    // MARK: Showing

    /// Shows `lineage`. `base` and `diff` may be nil (a map without a base: the head alone). `history` is every
    /// snapshot of the profile, oldest first. `image` resolves a blob to a picture and calls back on the main thread.
    func show(lineage: String, head: MapSnapshot?, base: MapSnapshot?, diff: MapDiff?, history: [MapSnapshot],
              image: @escaping (String, @escaping (CGImage?) -> Void) -> Void) {
        generation += 1
        let mine = generation
        self.image = image
        self.lineage = lineage
        self.snapshot = head
        self.baseSnap = base
        self.diff = diff
        let h = head?.screens.first { $0.lineage == lineage }, b = base?.screens.first { $0.lineage == lineage }
        let s = h ?? b
        self.screen = s
        let change = diff?.change(lineage)
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        pictures = nil; textLines = []; controlLines = []; changedRows = []; frames = []
        guard let s else { statusText = "not in these snapshots"; stack.addArrangedSubview(label("This screen is in neither snapshot.", size: 12)); return }

        // Header.
        let title = label(s.title, size: 15, weight: .semibold, color: Design.ink)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let sub = label("\(s.activity)  ·  \(s.steps.isEmpty ? "start" : "\(s.steps.count) step\(s.steps.count == 1 ? "" : "s") in")" + (s.settled ? "" : "  ·  never settles"), size: 11.5)
        sub.lineBreakMode = .byTruncatingTail
        sub.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        statusText = Self.statusWords(change, edges: diff?.edges ?? [], percent: nil)
        statusLabel = label(statusText, size: 12, weight: .medium, color: Self.color(change?.status))
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = Self.width - 28
        for v in [title, sub, statusLabel] { stack.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.setCustomSpacing(8, after: sub)

        // Pictures, once they are in.
        let order = (head ?? base)?.profile.combos ?? ["light"]
        let pictureHost = NSStackView()
        pictureHost.orientation = .vertical
        pictureHost.alignment = .leading
        pictureHost.spacing = 6
        stack.addArrangedSubview(pictureHost)
        pictureHost.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(10, after: statusLabel)
        MapPictureSet.load(base: b, head: h, order: order, image: image) { [weak self] set in
            guard let self, self.generation == mine else { return }
            self.pictures = set
            if !set.combos.contains(self.combo) { self.combo = set.combos.first ?? "light" }
            if !set.compares { self.mode = .sideBySide }
            self.fillPictures(pictureHost)
            if change?.status == .modified, change?.reasons.contains(.visual) == true, let p = set.percent {
                self.statusText = Self.statusWords(change, edges: diff?.edges ?? [], percent: p)
                self.statusLabel.stringValue = self.statusText
            }
        }

        addLists(change: change, head: head, base: base)
        addRoute(s, head: h != nil ? head : base)
        addHistory(lineage: lineage, history: history)
    }

    // MARK: Pictures section

    private func fillPictures(_ host: NSStackView) {
        for v in host.arrangedSubviews { host.removeArrangedSubview(v); v.removeFromSuperview() }
        guard let set = pictures else { return }
        let w = Self.width - 28
        var bar: [NSView] = []
        if set.compares {
            let seg = NSSegmentedControl(labels: MapPictureMode.allCases.map(\.short), trackingMode: .selectOne, target: self, action: #selector(modePicked(_:)))
            seg.controlSize = .small
            seg.selectedSegment = mode.rawValue
            bar.append(seg)
        } else {
            bar.append(label(set.single, size: 11, weight: .medium))
        }
        if set.combos.count > 1 {
            let seg = NSSegmentedControl(labels: set.combos.map { $0.capitalized }, trackingMode: .selectOne, target: self, action: #selector(comboPicked(_:)))
            seg.controlSize = .small
            seg.selectedSegment = set.combos.firstIndex(of: combo) ?? 0
            bar.append(seg)
        }
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let expand = GlassButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Open large", style: .plain, target: self, action: #selector(openViewer))
        bar += [spacer, expand]
        let barStack = NSStackView(views: bar)
        barStack.spacing = 6
        host.addArrangedSubview(barStack)
        barStack.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true

        let base = set.base[combo], head = set.head[combo], diff = set.difference[combo]
        let aspect = ((head ?? base).map { CGFloat($0.height) / CGFloat(max(1, $0.width)) }) ?? 2.1
        func pane(_ image: CGImage?, _ empty: String) -> SnapshotPicture {
            let p = SnapshotPicture()
            p.show(image, empty: empty)
            p.translatesAutoresizingMaskIntoConstraints = false
            p.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(openViewer)))
            return p
        }
        func caption(_ t: String, _ p: SnapshotPicture) -> NSStackView {
            let c = NSStackView(views: [label(t, size: 10.5, weight: .medium), p])
            c.orientation = .vertical
            c.alignment = .centerX
            c.spacing = 3
            p.widthAnchor.constraint(equalTo: c.widthAnchor).isActive = true
            return c
        }
        let differenceNote = set.differing[combo] == nil ? (base != nil && head != nil ? "Same pixels" : "No capture") : "Sizes differ"
        if !set.compares {
            let p = pane(head, "No capture")
            host.addArrangedSubview(p)
            p.widthAnchor.constraint(equalToConstant: w * 0.7).isActive = true
            p.heightAnchor.constraint(equalToConstant: min(300, w * 0.7 * aspect)).isActive = true
        } else {
            switch mode {
            case .sideBySide:
                let third = (w - 12) / 3
                let row = NSStackView(views: [caption("Base", pane(base, "No capture")), caption("Head", pane(head, "No capture")), caption("Difference", pane(diff, differenceNote))])
                row.distribution = .fillEqually
                row.spacing = 6
                host.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true
                row.heightAnchor.constraint(equalToConstant: min(260, third * aspect) + 18).isActive = true
            case .wipe:
                let wipe = SnapshotWipe()
                wipe.translatesAutoresizingMaskIntoConstraints = false
                wipe.show(golden: base, actual: head)
                let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
                slider.controlSize = .small
                slider.isContinuous = true
                wipe.onChange = { [weak slider] p in slider?.doubleValue = Double(p) }
                let sliderTarget = WipeSliderTarget(wipe)
                slider.target = sliderTarget; slider.action = #selector(WipeSliderTarget.moved(_:))
                objc_setAssociatedObject(slider, Unmanaged.passUnretained(self).toOpaque(), sliderTarget, .OBJC_ASSOCIATION_RETAIN)
                let ends = NSStackView(views: [label("Base", size: 10.5, weight: .medium), slider, label("Head", size: 10.5, weight: .medium)])
                ends.spacing = 6
                host.addArrangedSubview(wipe); host.addArrangedSubview(ends)
                wipe.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true
                wipe.heightAnchor.constraint(equalToConstant: min(300, w * aspect)).isActive = true
                ends.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true
            case .difference:
                let p = pane(diff, differenceNote)
                host.addArrangedSubview(p)
                p.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true
                p.heightAnchor.constraint(equalToConstant: min(300, w * aspect)).isActive = true
            }
        }
    }

    @objc private func modePicked(_ s: NSSegmentedControl) { setMode(MapPictureMode(rawValue: s.selectedSegment) ?? .sideBySide) }
    @objc private func comboPicked(_ s: NSSegmentedControl) { if let set = pictures, set.combos.indices.contains(s.selectedSegment) { setCombo(set.combos[s.selectedSegment]) } }

    /// Switches the pictures to another mode or combination (what the segmented controls do).
    func setMode(_ m: MapPictureMode) { mode = m; refillPictures() }
    func setCombo(_ c: String) { combo = c; refillPictures() }
    private func refillPictures() {
        // The pictures host is the third row of the stack (title, sub, status, pictures).
        if stack.arrangedSubviews.count > 3, let host = stack.arrangedSubviews[3] as? NSStackView { fillPictures(host) }
    }

    /// Presses the i-th row of the controls that changed, as a click would (the check's hand).
    func pressChangedControl(_ i: Int) { if changedRows.indices.contains(i) { changedRows[i].onPress?() } }
    /// Presses the i-th filmstrip frame, as a click would.
    func pickFrame(_ i: Int) { if frames.indices.contains(i) { onPickCommit?(frames[i].first) } }
    /// Whether the i-th changed control leads somewhere that can be selected.
    func changedControlLeads(_ i: Int) -> Bool { changedRows.indices.contains(i) && changedRows[i].onPress != nil }

    @objc func openViewer() {
        guard let set = pictures, let s = screen else { return }
        viewerWindow?.close()
        viewerWindow = MapPictureViewer.open(set, mode: mode, combo: combo, title: s.title + (statusText.isEmpty ? "" : "  ·  " + statusText))
    }

    // MARK: Lists

    private func addLists(change: MapDiff.ScreenChange?, head: MapSnapshot?, base: MapSnapshot?) {
        let snaps = [head, base]
        var rows: [NSView] = []
        func add(_ title: String, _ items: [NSView]) {
            guard !items.isEmpty else { return }
            let t = label(title, size: 10, weight: .semibold)
            stack.addArrangedSubview(t)
            stack.setCustomSpacing(4, after: t)
            for r in items { stack.addArrangedSubview(r); r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            if let last = items.last { stack.setCustomSpacing(12, after: last) }
        }
        func capped(_ rows: [NSView], _ total: Int, limit: Int = 10) -> [NSView] {
            guard total > limit else { return rows }
            return Array(rows.prefix(limit)) + [MapDetailRow(mark: "", color: Design.mute, text: "\(total - limit) more", textColor: Design.mute)]
        }
        if let change, change.status == .modified {
            let texts = change.textAdded.map { ("+", Design.accent, $0) } + change.textRemoved.map { ("−", Design.record, $0) }
            textLines = change.textAdded.map { "+ " + $0 } + change.textRemoved.map { "- " + $0 }
            rows = texts.prefix(10).map { MapDetailRow(mark: $0.0, color: $0.1, text: $0.2) }
            add("TEXT", capped(rows, texts.count))

            let edges = (diff?.edges ?? []).filter { $0.from == change.lineage }
            var controls: [NSView] = []
            for e in edges {
                let name = e.action.isEmpty ? e.cmd : e.action
                let row: MapDetailRow
                switch e.status {
                case .added:
                    let p = place(e.headTo, in: snaps)
                    row = MapDetailRow(mark: "+", color: Design.accent, text: name, trailing: "→ " + p.text, trailingColor: p.color)
                    if let t = p.target { row.onPress = { [weak self] in self?.onSelect?(t) } }
                    controlLines.append("+ \(name) -> \(p.text)")
                case .removed:
                    let p = place(e.baseTo, in: snaps)
                    row = MapDetailRow(mark: "−", color: Design.record, text: name, trailing: "was → " + p.text, trailingColor: Design.mute)
                    if let t = p.target { row.onPress = { [weak self] in self?.onSelect?(t) } }
                    controlLines.append("- \(name) -> \(p.text)")
                case .retargeted:
                    let was = place(e.baseTo, in: snaps), now = place(e.headTo, in: snaps)
                    row = MapDetailRow(mark: "↪", color: Design.warning, text: name, trailing: "\(was.text) → \(now.text)", trailingColor: now.color)
                    if let t = now.target { row.onPress = { [weak self] in self?.onSelect?(t) } }
                    controlLines.append("~ \(name): \(was.text) -> \(now.text)")
                }
                controls.append(row)
                changedRows.append(row)
            }
            add("CONTROLS THAT CHANGED", capped(Array(controls.prefix(10)), controls.count))
        }
    }

    // MARK: Route and controls

    private func addRoute(_ s: MapSnapshot.Screen, head: MapSnapshot?) {
        let go = GlassButton(symbol: "arrow.forward.circle.fill", title: "Go there", label: "Replay the route on the selected device", style: .accent, target: self, action: #selector(goPressed))
        let copy = GlassButton(symbol: "doc.on.doc", title: "Copy route", label: "Copy the route as control commands", style: .well, target: self, action: #selector(copyRoute))
        let buttons = NSStackView(views: [go, copy])
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)
        stack.setCustomSpacing(12, after: buttons)

        let routeHead = label("ROUTE", size: 10, weight: .semibold)
        stack.addArrangedSubview(routeHead)
        stack.setCustomSpacing(4, after: routeHead)
        let startText = s.start.map { "Open \($0)" } ?? "Launch the app"
        for (i, step) in ([startText] + s.steps.map(ScreenMap.describe)).enumerated() {
            let n = label(i == 0 ? "●" : "\(i)", size: 10.5, weight: .semibold, color: i == 0 ? Design.accent : Design.mute)
            n.alignment = .right
            n.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let t = label(step, size: 12, color: Design.ink)
            t.lineBreakMode = .byTruncatingTail
            t.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [n, t])
            row.spacing = 8
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }

        guard let head else { return }
        let controlsHead = label("CONTROLS", size: 10, weight: .semibold)
        stack.addArrangedSubview(controlsHead)
        stack.setCustomSpacing(4, after: controlsHead)
        let lineage = Dictionary(head.screens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let edges = head.edges.filter { $0.from == s.id }
        for e in edges {
            let (outcome, color, target): (String, NSColor, String?) = {
                switch e.to {
                case nil: return ("not followed", Design.mute, nil)
                case let t? where t == s.id: return ("stays here", Design.mute, nil)
                case "EXIT": return ("closes the app", Design.warning, nil)
                case "CRASH": return ("crashes", Design.record, nil)
                case "SKIPPED": return ("not tapped: " + (e.note ?? "on the safety list"), Design.mute, nil)
                case "FAILED": return ("did not replay", Design.warning, nil)
                case let t?: return (lineage[t]?.title ?? t, Design.ink, lineage[t]?.lineage)
                }
            }()
            let row = MapDetailRow(mark: "›", color: Design.mute, text: e.action.isEmpty ? e.cmd : e.action, trailing: outcome, trailingColor: color)
            if let target { row.onPress = { [weak self] in self?.onSelect?(target) } }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if edges.isEmpty { stack.addArrangedSubview(label("No controls with a label.", size: 12)) }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(14, after: last) }
    }

    @objc func goPressed() { if let l = lineage { onGo?(l) } }

    /// The route as control commands, one to a line (what the old detail copies).
    var routeCommands: String? {
        guard let s = screen else { return nil }
        return ([s.start.map { "restart \($0)" } ?? "restart"] + s.steps.flatMap { [$0, "settle 1500 100"] }).joined(separator: "\n")
    }

    @objc func copyRoute() {
        guard let text = routeCommands else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onCopyRoute?(text)
    }

    // MARK: History

    private func addHistory(lineage: String, history: [MapSnapshot]) {
        frames = Self.frames(lineage: lineage, history: history)
        let head = label("HISTORY", size: 10, weight: .semibold)
        stack.addArrangedSubview(head)
        stack.setCustomSpacing(4, after: head)
        guard !frames.isEmpty else { stack.addArrangedSubview(label("Not in the snapshots given.", size: 12)); return }
        let strip = MapFilmstrip(frames: frames, image: image)
        strip.onPick = { [weak self] commit in self?.onPickCommit?(commit) }
        strip.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(strip)
        strip.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        strip.heightAnchor.constraint(equalToConstant: MapFilmstrip.height).isActive = true
        let changes = frames.filter(\.changed).count
        let caption = label(changes == 0 ? "Never changed in \(history.count) snapshots." : "Changed \(changes) time\(changes == 1 ? "" : "s") in \(history.count) snapshots. Click a frame to compare against it.",
                            size: 11)
        caption.maximumNumberOfLines = 2
        caption.lineBreakMode = .byWordWrapping
        caption.preferredMaxLayoutWidth = Self.width - 28
        stack.addArrangedSubview(caption)
    }

    private func label(_ t: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = Design.mute) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }
}

/// Moves a wipe when its slider does (a slider's target is weak, so the wipe's owner keeps this).
private final class WipeSliderTarget: NSObject {
    weak var wipe: SnapshotWipe?
    init(_ w: SnapshotWipe) { wipe = w }
    @objc func moved(_ s: NSSlider) { wipe?.position = CGFloat(s.doubleValue) }
}

/// The captures of one lineage, oldest left, newest right: one thumbnail per run of snapshots in which it looked the
/// same, labelled with the commits, a mark where it changed. A press picks that frame's first commit.
final class MapFilmstrip: NSView {
    static let height: CGFloat = 112
    var onPick: ((String) -> Void)?
    private let frames: [MapFilmFrame]
    private let scroll = NSScrollView()
    private(set) var cells: [MapFilmCell] = []

    init(frames: [MapFilmFrame], image: @escaping (String, @escaping (CGImage?) -> Void) -> Void) {
        self.frames = frames
        super.init(frame: .zero)
        let row = NSStackView()
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        for (i, f) in frames.enumerated() {
            let cell = MapFilmCell(frame: f)
            cell.onPress = { [weak self] in self?.onPick?(f.first) }
            // The first combination's capture stands for the frame.
            if let blob = f.captures.sorted(by: { $0.key > $1.key }).first?.value { image(blob) { [weak cell] img in cell?.show(img) } }
            cells.append(cell)
            row.addArrangedSubview(cell)
            _ = i
        }
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(row)
        NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: doc.topAnchor), row.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
                                     row.leadingAnchor.constraint(equalTo: doc.leadingAnchor), row.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
                                     doc.heightAnchor.constraint(equalToConstant: Self.height)])
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .allowed
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        // The newest is on the right: start there.
        scroll.layoutSubtreeIfNeeded()
        if let doc = scroll.documentView { scroll.contentView.scroll(to: NSPoint(x: max(0, doc.frame.width - scroll.contentView.bounds.width), y: 0)) }
    }
}

final class MapFilmCell: NSView {
    var onPress: (() -> Void)?
    let frameInfo: MapFilmFrame
    private let picture = SnapshotPicture()
    private var hovering = false { didSet { layer?.borderColor = (hovering ? Design.ink.withAlphaComponent(0.5) : (frameInfo.changed ? Design.warning.withAlphaComponent(0.7) : Design.stroke)).cgColor } }

    init(frame f: MapFilmFrame) {
        frameInfo = f
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = (f.changed ? Design.warning.withAlphaComponent(0.7) : Design.stroke).cgColor
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.show(nil, empty: f.present ? "" : "not there")
        let range = NSTextField(labelWithString: f.label)
        range.font = .monospacedSystemFont(ofSize: 8.5, weight: .regular)
        range.textColor = Design.mute
        range.lineBreakMode = .byTruncatingMiddle
        range.alignment = .center
        range.translatesAutoresizingMaskIntoConstraints = false
        let mark = NSView()
        mark.wantsLayer = true
        mark.layer?.backgroundColor = Design.warning.cgColor
        mark.layer?.cornerRadius = 3.5
        mark.isHidden = !f.changed
        mark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picture); addSubview(range); addSubview(mark)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 74), heightAnchor.constraint(equalToConstant: MapFilmstrip.height),
            picture.topAnchor.constraint(equalTo: topAnchor, constant: 4), picture.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            picture.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), picture.bottomAnchor.constraint(equalTo: range.topAnchor, constant: -3),
            range.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), range.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            range.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            mark.widthAnchor.constraint(equalToConstant: 7), mark.heightAnchor.constraint(equalToConstant: 7),
            mark.topAnchor.constraint(equalTo: topAnchor, constant: 8), mark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        toolTip = (f.changed ? "Changed here. " : "") + (f.count > 1 ? "\(f.count) snapshots: " : "") + f.label
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ image: CGImage?) { picture.show(image, empty: "") }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
