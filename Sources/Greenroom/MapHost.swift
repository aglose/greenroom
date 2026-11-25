import AppKit
import ImageIO

// The map as the Screen Map sheet and the Changes sheet's Map tab hold it (docs/MAP-HISTORY-PLAN.md, package C5): the
// navigator (MapNavigator) with the detail column (MapDetail) beside it, pictures from a store's blobs, and, while a
// walk runs, ghost cards where the screens will land. One input feeds it: a head snapshot, and when there is a base,
// the base and what the comparison found. The sheets own everything around it.

/// What a map is shown from: the snapshots and where their captures are.
struct MapSource {
    var head: MapSnapshot
    var base: MapSnapshot?
    var diff: MapDiff?
    /// Every snapshot of the head's profile, oldest first, for the detail's filmstrip.
    var history: [MapSnapshot] = []
    /// Where a capture's blob is.
    var blobURL: (String) -> URL?

    /// The comparison of two snapshots as the map shows it: the head with its lineages paired against the base, and
    /// the difference. With no base, the head alone with its lineages seeded.
    static func make(head: MapSnapshot, base: MapSnapshot?, history: [MapSnapshot] = [], blobURL: @escaping (String) -> URL?) -> MapSource {
        guard let base else {
            let (h, _) = MapPairing.pair(head: head, base: nil)
            return MapSource(head: h, base: nil, diff: nil, history: history, blobURL: blobURL)
        }
        let (h, _) = MapPairing.pair(head: head, base: base)
        return MapSource(head: h, base: MapPairing.seeded(base), diff: MapPairing.diff(head: head, base: base), history: history, blobURL: blobURL)
    }

    /// The lineage of the head's screen with this id.
    func lineage(ofHeadScreen id: String) -> String? { head.screens.first { $0.id == id }?.lineage }
}

final class MapHost: NSView {
    let navigator: MapNavigator
    let detail = MapDetail()
    let ghosts = MapGhosts()
    private let detailWell = NSView()
    private let pickNote = NSTextField(labelWithString: "Pick a screen on the map")
    private(set) var source: MapSource?
    private(set) var selected: String?
    /// "Go there" or a double click: the lineage of the screen to go to.
    var onGo: ((String) -> Void)?
    /// A screen was picked on the map (nil: none).
    var onSelect: ((String?) -> Void)?
    /// A copy of the route was made, with its commands.
    var onCopyRoute: ((String) -> Void)?
    /// A frame of a screen's filmstrip was pressed: the commit it is.
    var onPickCommit: ((String) -> Void)?
    private var blobURL: (String) -> URL? = { _ in nil }

    /// One folder for every map's picture sizes: a capture is named by its hash, so the sheets share them.
    private static let pyramid: (URL) -> MapPyramid = { folder in
        MapPyramid(folder: folder, byteLimit: 128 << 20) { blob, maxPixel, done in
            guard let url = MapHost.currentBlobURL?(blob) else { done(nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { done(nil); return }
                if maxPixel > 0 {
                    done(CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                                                      kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary))
                } else { done(CGImageSourceCreateImageAtIndex(src, 0, nil)) }
            }
        }
    }
    /// The blob lookup the pyramid's source asks (one at a time is on screen, so the latest map's is the one).
    nonisolated(unsafe) fileprivate static var currentBlobURL: ((String) -> URL?)?
    nonisolated(unsafe) private static var sharedPyramid: MapPyramid?

    init() {
        let folder = Engine.shared.state.appendingPathComponent("map-pyramid", isDirectory: true)
        let pyramid = MapHost.sharedPyramid ?? MapHost.pyramid(folder)
        MapHost.sharedPyramid = pyramid
        navigator = MapNavigator(pyramid: pyramid)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        navigator.translatesAutoresizingMaskIntoConstraints = false
        ghosts.translatesAutoresizingMaskIntoConstraints = false
        ghosts.isHidden = true
        detailWell.wantsLayer = true
        detailWell.layer?.backgroundColor = Design.well.cgColor
        detailWell.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.isHidden = true
        pickNote.font = .systemFont(ofSize: 12)
        pickNote.textColor = Design.mute
        pickNote.translatesAutoresizingMaskIntoConstraints = false
        detailWell.addSubview(detail)
        detailWell.addSubview(pickNote)
        addSubview(navigator)
        addSubview(ghosts)
        addSubview(detailWell)
        NSLayoutConstraint.activate([
            navigator.topAnchor.constraint(equalTo: topAnchor), navigator.bottomAnchor.constraint(equalTo: bottomAnchor), navigator.leadingAnchor.constraint(equalTo: leadingAnchor),
            ghosts.topAnchor.constraint(equalTo: navigator.topAnchor), ghosts.bottomAnchor.constraint(equalTo: navigator.bottomAnchor),
            ghosts.leadingAnchor.constraint(equalTo: navigator.leadingAnchor), ghosts.trailingAnchor.constraint(equalTo: navigator.trailingAnchor),
            detailWell.topAnchor.constraint(equalTo: topAnchor), detailWell.bottomAnchor.constraint(equalTo: bottomAnchor), detailWell.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailWell.leadingAnchor.constraint(equalTo: navigator.trailingAnchor, constant: 1),
            detailWell.widthAnchor.constraint(equalToConstant: MapDetail.width + 16),
            detail.topAnchor.constraint(equalTo: detailWell.topAnchor, constant: 8), detail.bottomAnchor.constraint(equalTo: detailWell.bottomAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: detailWell.leadingAnchor, constant: 8), detail.trailingAnchor.constraint(equalTo: detailWell.trailingAnchor, constant: -8),
            pickNote.centerXAnchor.constraint(equalTo: detailWell.centerXAnchor), pickNote.centerYAnchor.constraint(equalTo: detailWell.centerYAnchor),
        ])
        navigator.onSelect = { [weak self] key in self?.picked(key) }
        navigator.onOpen = { [weak self] key in self?.onGo?(key) }
        detail.onSelect = { [weak self] key in self?.navigator.reveal(key) }
        detail.onGo = { [weak self] key in self?.onGo?(key) }
        detail.onCopyRoute = { [weak self] text in self?.onCopyRoute?(text) }
        detail.onPickCommit = { [weak self] commit in self?.onPickCommit?(commit) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Showing

    /// Draws `source`. `keepingPlace`: it is another pair of the same map (the timeline moved), so what is unchanged
    /// stays where it is and the view stays where it is.
    func show(_ source: MapSource, keepingPlace: Bool = false) {
        self.source = source
        blobURL = source.blobURL
        MapHost.currentBlobURL = source.blobURL
        ghosts.stop()
        navigator.isHidden = false
        navigator.show(source.head, diff: source.diff, base: source.base, keepingPlace: keepingPlace)
        if let sel = selected, source.head.screens.contains(where: { $0.lineage == sel }) || source.base?.screens.contains(where: { $0.lineage == sel }) == true {
            showDetail(sel)
        } else { picked(nil) }
    }

    /// Empties the map for a walk to fill (the ghosts take its place).
    func clear() {
        source = nil
        selected = nil
        navigator.isHidden = false
        detail.isHidden = true
        pickNote.isHidden = false
        ghosts.clear()
        ghosts.isHidden = false
        navigator.isHidden = true
    }

    func walkReached(depth: Int, exploring: Int) {
        ghosts.isHidden = false
        navigator.isHidden = true
        ghosts.walkReached(depth: depth, exploring: exploring)
    }

    /// A screen the walk has finished with: one ghost of its level stops breathing and takes its title.
    func walkExplored(depth: Int, title: String) { ghosts.explored(depth: depth, title: title) }

    /// The ghosts go and the map shows (a walk is over).
    func endWalk() {
        ghosts.stop()
        navigator.isHidden = false
    }

    /// Selects a screen by its lineage and brings it into view.
    func select(_ lineage: String?, reveal: Bool = true) {
        guard let lineage else { navigator.surface.select(nil, reveal: false); return }
        if reveal { navigator.reveal(lineage) } else { navigator.surface.select(lineage, reveal: false) }
    }

    private func picked(_ key: String?) {
        selected = key
        if let key { showDetail(key) } else {
            detail.isHidden = true
            pickNote.isHidden = false
        }
        onSelect?(key)
    }

    private func showDetail(_ lineage: String) {
        guard let s = source else { return }
        selected = lineage
        detail.isHidden = false
        pickNote.isHidden = true
        detail.show(lineage: lineage, head: s.head, base: s.base, diff: s.diff, history: s.history.isEmpty ? [s.head] : s.history,
                    image: { [weak self] blob, done in
            guard let url = self?.blobURL(blob) else { done(nil); return }
            SnapshotImages.load(url, maxPixel: 2400, done: done)
        })
    }

    /// The combination (light, dark) the cards and the detail show.
    func setCombo(_ combo: String) {
        navigator.surface.combo = combo
        detail.setCombo(combo)
    }

    // MARK: Zoom

    func zoom(by factor: CGFloat) {
        let s = navigator.scroll
        let m = min(s.maxMagnification, max(s.minMagnification, s.magnification * factor))
        let c = NSPoint(x: s.contentView.bounds.midX, y: s.contentView.bounds.midY)
        Design.animate(Design.move, { s.animator().setMagnification(m, centeredAt: c) })
        DispatchQueue.main.asyncAfter(deadline: .now() + Design.move + 0.05) { [weak self] in self?.navigator.surface.update() }
    }

    /// The whole map in view (the zoom buttons' Fit).
    func fit() { navigator.surface.fitAll() }

    /// The view as the navigator opens a map: a few screens as cards from the top left at full size, a big map fitted. For
    /// when the map was laid out while hidden or the sheet has just opened; a one-screen map is never zoomed up to fill the pane.
    func settle() {
        guard let plan = navigator.plan else { return }
        if plan.shown.count > 80 { navigator.surface.fitAll(); return }
        let s = navigator.scroll, clip = s.contentView
        s.magnification = 1
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: .zero, size: clip.bounds.size)).origin)
        s.reflectScrolledClipView(clip)
        navigator.surface.update()
    }

    // MARK: Export

    /// Whether there is a map to export.
    var canExport: Bool { source != nil }

    /// Writes the HTML export (MapExport) of the map on screen into `folder`: with a comparison, base, head and difference;
    /// without, the single map. Off the main thread; `done` is called on it with `index.html`, or the error.
    func export(to folder: URL, title: String, names: (base: String, head: String), done: @escaping (Result<URL, Error>) -> Void) {
        guard let s = source else { done(.failure(CocoaError(.fileNoSuchFile))); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> URL in
                try MapExport.write(head: s.head, base: s.base, diff: s.diff, blob: s.blobURL, to: folder, title: title, names: names)
                return folder.appendingPathComponent("index.html")
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    /// Asks where (a folder, which the save panel makes) and exports there; a cancelled panel calls nothing.
    func exportWithPanel(title: String, names: (base: String, head: String), suggested: String, done: @escaping (Result<URL, Error>) -> Void) {
        guard canExport, let window else { return }
        let panel = NSSavePanel()
        panel.title = "Export the map"
        panel.message = "Makes a folder with an index.html anyone can open in a browser: the map, changes first, with each changed screen's base, head and difference. No Greenroom needed."
        panel.prompt = "Export"
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.export(to: url, title: title, names: names, done: done)
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(navigator.surface) ?? false }
}

// MARK: - Ghosts

/// While a walk runs: a breathing ghost card for each screen a level has found, a column to a level, standing where the
/// map's cards will land.
final class MapGhosts: NSView {
    private var levels: [Int: Int] = [:]
    private var layers: [String: CALayer] = [:]
    /// Explored screens: how many of each level, and the title each settled ghost shows.
    private var named: [Int: Int] = [:]
    private var titles: [String: String] = [:]
    private var labels: [String: CATextLayer] = [:]
    private let metrics = MapLayout.Metrics()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() { super.layout(); place() }

    func walkReached(depth: Int, exploring: Int) {
        levels[depth] = exploring
        place()
    }

    /// A screen of level `depth` is explored: the level's next ghost settles and is named.
    func explored(depth: Int, title: String) {
        let i = named[depth, default: 0]
        named[depth] = i + 1
        titles["\(depth)-\(i)"] = title
        place()
    }

    /// Hides them, their columns forgotten.
    func stop() {
        isHidden = true
        clear()
    }

    func clear() {
        levels = [:]
        layers.values.forEach { $0.removeFromSuperlayer() }
        layers = [:]
        named = [:]; titles = [:]; labels = [:]
    }

    /// A ghost whose screen is explored: steady, a little brighter, its title inside.
    private func settle(_ g: CALayer, key: String, scale: CGFloat) {
        guard let title = titles[key] else { return }
        let label: CATextLayer
        if let l = labels[key] { label = l } else {
            g.removeAnimation(forKey: "breathe")
            g.backgroundColor = NSColor(white: 1, alpha: 0.13).cgColor
            label = CATextLayer()
            label.string = title.isEmpty ? "Untitled" : title
            label.foregroundColor = Design.mute.cgColor
            label.alignmentMode = .center
            label.isWrapped = true
            label.truncationMode = .end
            label.contentsScale = window?.backingScaleFactor ?? 2
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            g.addSublayer(label)
            labels[key] = label
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        label.fontSize = max(6, 11 * scale)
        label.frame = g.bounds.insetBy(dx: 6 * scale, dy: g.bounds.height * 0.38)
        label.isHidden = g.bounds.width < 44
        CATransaction.commit()
    }

    private func place() {
        guard let root = layer, !levels.isEmpty, bounds.width > 0 else { return }
        let columns = (levels.keys.max() ?? 0) + 1
        let tallest = levels.values.max() ?? 1
        let w = metrics.cardWidth, h = metrics.cardHeight - 40
        let totalW = CGFloat(columns) * metrics.columnPitch - metrics.gapX + metrics.pad * 2
        let totalH = CGFloat(tallest) * metrics.rowPitch - metrics.gapY + metrics.pad * 2
        let scale = min(1, bounds.width / totalW, bounds.height / totalH)
        let originX = (bounds.width - (totalW - 2 * metrics.pad) * scale) / 2
        let animating = !Design.reduceMotion
        for (d, n) in levels.sorted(by: { $0.key < $1.key }) {
            let colHeight = (CGFloat(n) * metrics.rowPitch - metrics.gapY) * scale
            let top = (bounds.height - colHeight) / 2
            for i in 0..<n {
                let key = "\(d)-\(i)"
                let frame = CGRect(x: originX + CGFloat(d) * metrics.columnPitch * scale, y: top + CGFloat(i) * metrics.rowPitch * scale, width: w * scale, height: h * scale)
                if let g = layers[key] { g.frame = frame; settle(g, key: key, scale: scale); continue }
                let g = CALayer()
                g.frame = frame
                g.cornerRadius = 12
                g.cornerCurve = .continuous
                g.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
                g.borderWidth = 1
                g.borderColor = Design.stroke.cgColor
                root.addSublayer(g)
                layers[key] = g
                guard animating else { continue }
                let rise = CABasicAnimation(keyPath: "opacity")
                rise.fromValue = 0; rise.toValue = 1; rise.duration = Design.arrive
                rise.beginTime = CACurrentMediaTime() + Double(i) * 0.05 * Design.slow
                rise.fillMode = .backwards
                g.add(rise, forKey: "rise")
                let breathe = CABasicAnimation(keyPath: "backgroundColor")
                breathe.fromValue = NSColor(white: 1, alpha: 0.04).cgColor
                breathe.toValue = NSColor(white: 1, alpha: 0.11).cgColor
                breathe.duration = 1.1 * Design.slow
                breathe.autoreverses = true
                breathe.repeatCount = .infinity
                breathe.timeOffset = Double(d) * 0.3 + Double(i) * 0.12
                g.add(breathe, forKey: "breathe")
            }
        }
    }

    /// For checks: how many ghost cards stand.
    var ghostCount: Int { layers.count }
}
