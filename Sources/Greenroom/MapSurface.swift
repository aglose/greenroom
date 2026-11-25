import AppKit

/// One screen as the map shows it, named by its lineage (MapSnapshot): what its card says, where its pictures are and
/// what its badges count.
struct MapSurfaceScreen {
    var lineage: String
    var id: String
    var title: String
    var activity: String
    var depth: Int
    /// The parent's lineage: where the left arrow goes.
    var parent: String?
    /// Combination name to the capture's blob.
    var captures: [String: String]
    var crashes = 0
    var exits = 0
    var loops = 0
    /// Set for a folded group: drawn as a wide tile (its name, counts and a few pictures), not as a card.
    var tile: MapSurfaceTile?
}

/// What a folded group's tile says: the group's name, how many screens it holds and how many of them the comparison
/// changed, and the captures of its first few screens (each by combination, as a card's).
struct MapSurfaceTile {
    var name: String
    var count: Int
    var added = 0, removed = 0, modified = 0
    var pictures: [[String: String]] = []
    static let width: CGFloat = 214
    static let shown = 4
}

/// A route between two screens, carrying every control that makes it. `change` is what a comparison says of the route
/// itself; a route into a new or gone screen takes that screen's colour without one.
struct MapSurfaceEdge {
    enum Change { case added, removed }
    var from: String
    var to: String
    var labels: [String]
    var change: Change?
}

/// Where everything goes, in the canvas's points: a card's frame per lineage (its capture and the 40 points of title
/// under it), the groups' frames and titles, and the size of the whole. The layout (MapLayout) makes these.
struct MapPlacement {
    struct Group { var frame: CGRect; var title: String }
    var frames: [String: CGRect]
    var groups: [Group] = []
    var size: CGSize
}

struct MapSurfaceInput {
    var screens: [MapSurfaceScreen]
    var edges: [MapSurfaceEdge]
    var placement: MapPlacement
    /// What a comparison found, by lineage; empty when there is no base.
    var changes: [String: MapDiff.ScreenChange] = [:]
    /// The combination whose captures the cards show.
    var combo = "light"
}

/// A clip view that keeps a map smaller than the view in the middle of it, as the old canvas did.
final class MapSurfaceClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = f.minX - (r.width - f.width) / 2 }
        if r.height > f.height { r.origin.y = f.minY - (r.height - f.height) / 2 }
        return r
    }
}

/// The screen map at any size: the document view of an `NSScrollView` that magnifies from the whole map to 8x. Only
/// what is in view has layers, taken from a pool and given back as it scrolls away; the routes are a handful of shape
/// layers, one path per style, built for the region in view. How much a card shows follows the magnification: far, a
/// tile in its status's colour and the groups' titles; then a small picture; then the card as the old canvas drew it
/// (capture, title, activity, badges); and up close the capture itself. Selecting a card lights its routes out (accent,
/// with the controls' names) and in, and dims the rest, as before.
final class MapSurface: NSView {
    enum Detail: Int, Comparable {
        case far, middle, near, closest
        static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }
    }
    /// Where each detail starts, as a magnification.
    static let middleFrom: CGFloat = 0.4, nearFrom: CGFloat = 0.8, closestFrom: CGFloat = 2.5, maxMagnification: CGFloat = 8
    static func detail(at m: CGFloat) -> Detail {
        m < middleFrom ? .far : m < nearFrom ? .middle : m < closestFrom ? .near : .closest
    }

    /// The routes' styles, bottom to top.
    enum EdgeStyle: Int, CaseIterable { case dim, added, removed, into, out }

    var onSelect: ((String?) -> Void)?
    var onOpen: ((String) -> Void)?
    /// A click on a group's title, by its place in the placement's `groups` (the navigator folds and unfolds it).
    var onGroup: ((Int) -> Void)?
    private(set) var selected: String?
    private(set) var detail: Detail = .near
    let pyramid: MapPyramid
    /// The combination the cards show.
    var combo = "light" { didSet { if oldValue != combo { reloadImages() } } }

    // The map, by index.
    private var screens: [MapSurfaceScreen] = []
    private var indexOf: [String: Int] = [:]
    private var cardFrames: [CGRect] = []
    private var captureFrames: [CGRect] = []
    private var status: [MapDiff.Status?] = []
    private var badges: [[(String, NSColor)]] = []
    private var groups: [MapPlacement.Group] = []
    private struct Route {
        let from: Int, to: Int
        let labels: [String]
        let change: MapSurfaceEdge.Change?
        /// From a screen to one directly behind it (its parent's route to it).
        let tree: Bool
        let p0: CGPoint, c0: CGPoint, c1: CGPoint, p1: CGPoint
        let box: CGRect
        var mid: CGPoint {
            func bez(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat { 0.125 * a + 0.375 * b + 0.375 * c + 0.125 * d }
            return CGPoint(x: bez(p0.x, c0.x, c1.x, p1.x), y: bez(p0.y, c0.y, c1.y, p1.y))
        }
    }
    private var routes: [Route] = []
    private var routesOut: [[Int]] = [], routesIn: [[Int]] = []
    /// Cards by square of the canvas, for finding what is in a rect without looking at every card.
    private var grid: [Int64: [Int]] = [:]
    private let cell: CGFloat = 1024
    /// Each depth's cards in reading order (left to right, top to bottom): the up and down arrows.
    private var columnOrder: [Int: [Int]] = [:]

    // Layers. Containers first, then what lives in them.
    private let content = CALayer()
    private let groupOutlines = CAShapeLayer()
    private var groupTitles: [CATextLayer] = []
    /// Far away: a filled path per status, dim and lit.
    private var dotLayers: [[CAShapeLayer]] = []
    /// Far away, over the tiles: the cards' pictures in one bitmap for the region in view (MapMosaic).
    private let mosaicLayer = CALayer()
    private let mosaic: MapMosaic
    private struct MosaicKey: Equatable { let region: CGRect; let scale: CGFloat; let focus: Int?; let combo: String; let version: Int }
    private var builtMosaic: MosaicKey?
    private var askedMosaic: MosaicKey?
    /// Bumped when small copies were loaded (there is more to draw) and when the map changes.
    private var mosaicVersion = 0
    private var mosaicMap = 0
    private let edgesLayer = CALayer()
    private var lines: [CAShapeLayer] = [], tips: [CAShapeLayer] = []
    private let cardsLayer = CALayer()
    private let ring = CALayer()
    private let pillsLayer = CALayer()

    private final class Card {
        let root = CALayer()
        let label = CALayer()
        /// Bumped whenever the card is asked for another title, so a late one is dropped.
        var labelToken = 0
        let badge = CALayer()
        var index = -1
        var labelled = -1
        var wanted: MapPyramid.Tier?
        var ticket: MapPyramid.Ticket?
        /// A folded group's tile: its little pictures and the words under them.
        var thumbs: [CALayer] = []
        var thumbTickets: [MapPyramid.Ticket] = []
        let words = CALayer()
        var isTile = false
    }
    private var live: [Int: Card] = [:]
    private var pool: [Card] = []
    private let poolLimit = 48
    private var hovered: Int?
    private var related: Set<Int> = []
    private var panStart: (NSPoint, NSPoint)?
    private var lastVisible = CGRect.zero
    private var magnification: CGFloat = 1
    private var textScale: CGFloat = 1
    private struct EdgeKey: Equatable { let detail: Detail; let focus: Int?; let weight: CGFloat; let all: Bool; let cards: Int }
    /// Bumped whenever a card comes or goes: near, the tree's routes follow the cards in view.
    private var liveVersion = 0

    /// Every route faintly behind the cards, as the old canvas drew them. Off, only what says something is drawn:
    /// the routes that changed, the focused screen's, and near, the tree's routes between the cards in view. Five
    /// thousand faint routes are a texture, not a map.
    var showAllEdges = false { didSet { if oldValue != showAllEdges { builtEdges = nil; update() } } }
    private var builtEdges: (region: CGRect, key: EdgeKey)?
    private var dotsFocus: Int?? = .none
    private static var badgeImages: [String: CGImage] = [:]

    // For checks.
    /// The longest time the scroll handler took, culling and paths together, in seconds; and the last.
    private(set) var slowestUpdate: Double = 0
    private(set) var lastUpdate: Double = 0
    private(set) var drawnRoutes: [EdgeStyle: Int] = [:]
    var liveCards: Int { live.count }
    var pooledCount: Int { pool.count }
    /// Live cards in view whose layer holds a picture now.
    var picturedCards: Int { live.filter { lastVisible.intersects(cardFrames[$0.key]) && $0.value.root.contents != nil }.count }
    var imagesInMemory: Int { pyramid.imagesInMemory }
    /// Every layer under this view's, itself included: what Core Animation has to keep.
    var layerCount: Int {
        func count(_ l: CALayer) -> Int { 1 + (l.sublayers ?? []).reduce(0) { $0 + count($1) } }
        return layer.map(count) ?? 0
    }
    func resetTiming() { slowestUpdate = 0 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(pyramid: MapPyramid) {
        self.pyramid = pyramid
        mosaic = MapMosaic(pyramid: pyramid)
        super.init(frame: .zero)
        mosaic.onLoaded = { [weak self] in
            guard let self else { return }
            self.mosaicVersion += 1
            if self.detail == .far { self.update() }
        }
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.addSublayer(content)
        groupOutlines.fillColor = NSColor(white: 1, alpha: 0.018).cgColor
        groupOutlines.strokeColor = NSColor(white: 1, alpha: 0.08).cgColor
        content.addSublayer(groupOutlines)
        let fills: [NSColor] = [NSColor(white: 1, alpha: 0.34), Design.accent, Design.record, Design.warning, Design.mute.withAlphaComponent(0.6)]
        for color in fills {
            let pair = [CAShapeLayer(), CAShapeLayer()]
            pair[0].opacity = 0.28
            for l in pair { l.fillColor = color.cgColor; l.isHidden = true; content.addSublayer(l) }
            dotLayers.append(pair)
        }
        mosaicLayer.isHidden = true
        mosaicLayer.contentsGravity = .resize
        mosaicLayer.minificationFilter = .trilinear
        content.addSublayer(mosaicLayer)
        content.addSublayer(edgesLayer)
        for s in EdgeStyle.allCases {
            let line = CAShapeLayer(), tip = CAShapeLayer()
            line.fillColor = nil
            line.lineCap = .round
            if s == .removed { line.lineDashPattern = [5, 4] }
            line.zPosition = CGFloat(s.rawValue)
            tip.zPosition = CGFloat(s.rawValue)
            edgesLayer.addSublayer(line)
            edgesLayer.addSublayer(tip)
            lines.append(line)
            tips.append(tip)
        }
        content.addSublayer(cardsLayer)
        ring.cornerRadius = 16
        ring.cornerCurve = .continuous
        ring.borderWidth = 2
        ring.borderColor = Design.accent.cgColor
        ring.shadowColor = Design.accent.cgColor
        ring.shadowRadius = 10
        ring.shadowOpacity = 0.6
        ring.shadowOffset = .zero
        ring.isHidden = true
        ring.zPosition = 10
        content.addSublayer(ring)
        pillsLayer.zPosition = 20
        content.addSublayer(pillsLayer)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A scroll view with this surface in it, magnifying from the whole map to 8x and keeping a small map centred.
    static func scrollView(pyramid: MapPyramid) -> (NSScrollView, MapSurface) {
        let scroll = NSScrollView()
        scroll.contentView = MapSurfaceClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Design.stage
        scroll.allowsMagnification = true
        scroll.maxMagnification = maxMagnification
        let surface = MapSurface(pyramid: pyramid)
        scroll.documentView = surface
        return (scroll, surface)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self)
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleChanged), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportResized), name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func visibleChanged() { update() }
    @objc private func viewportResized() { fitLimits(); update() }

    // MARK: The map

    func show(_ input: MapSurfaceInput) {
        for i in Array(live.keys) { release(i) }
        selected = nil; hovered = nil; related = []
        combo = input.combo
        screens = input.screens.filter { input.placement.frames[$0.lineage] != nil }
        indexOf = Dictionary(screens.enumerated().map { ($1.lineage, $0) }, uniquingKeysWith: { a, _ in a })
        cardFrames = screens.map { s in
            let f = input.placement.frames[s.lineage]!
            // A folded group is a wide tile: it stands where its slot is and reaches into the gap beside it.
            return s.tile == nil ? f : CGRect(x: f.minX, y: f.minY, width: max(f.width, MapSurfaceTile.width), height: f.height)
        }
        captureFrames = cardFrames.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: max(1, $0.height - 40)) }
        status = screens.map { input.changes[$0.lineage]?.status }
        badges = screens.indices.map { i in
            let s = screens[i]
            var list: [(String, NSColor)] = []
            switch status[i] {
            case .added?: list.append(("new", Design.accent))
            case .removed?: list.append(("gone", Design.record))
            case .modified?: list.append(("changed", Design.warning))
            case .notCompared?: list.append(("not reached", Design.mute))
            default: break
            }
            if s.crashes > 0 { list.append(("\(s.crashes) crash" + (s.crashes == 1 ? "" : "es"), Design.record)) }
            if s.exits > 0 { list.append(("\(s.exits) exit" + (s.exits == 1 ? "" : "s"), Design.warning)) }
            if s.loops > 0 { list.append(("↻ \(s.loops)", Design.mute)) }
            return list
        }
        groups = input.placement.groups

        grid = [:]
        for (i, f) in cardFrames.enumerated() { forCells(f) { grid[$0, default: []].append(i) } }
        columnOrder = Dictionary(grouping: screens.indices, by: { screens[$0].depth }).mapValues { list in
            list.sorted { (cardFrames[$0].minX, cardFrames[$0].minY) < (cardFrames[$1].minX, cardFrames[$1].minY) }
        }

        routes = []
        routesOut = Array(repeating: [], count: screens.count)
        routesIn = Array(repeating: [], count: screens.count)
        for e in input.edges {
            guard let a = indexOf[e.from], let b = indexOf[e.to], a != b else { continue }
            routesOut[a].append(routes.count)
            routesIn[b].append(routes.count)
            routes.append(makeRoute(a, b, labels: e.labels, change: e.change ?? (status[b] == .added ? .added : status[b] == .removed ? .removed : nil),
                                    tree: screens[b].parent == screens[a].lineage))
        }

        setFrameSize(input.placement.size)
        content.frame = CGRect(origin: .zero, size: input.placement.size)

        let outlines = CGMutablePath()
        groupTitles.forEach { $0.removeFromSuperlayer() }
        groupTitles = groups.map { g in
            outlines.addRoundedRect(in: g.frame, cornerWidth: 22, cornerHeight: 22)
            let t = CATextLayer()
            t.string = NSAttributedString(string: g.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Design.mute])
            t.contentsScale = window?.backingScaleFactor ?? 2
            t.anchorPoint = CGPoint(x: 0, y: 1)
            t.bounds = CGRect(x: 0, y: 0, width: max(60, (g.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width + 8), height: 18)
            t.position = CGPoint(x: g.frame.minX + 6, y: g.frame.minY - 6)
            content.addSublayer(t)
            return t
        }
        groupOutlines.path = outlines

        builtEdges = nil
        dotsFocus = .none
        mosaicMap += 1
        builtMosaic = nil
        askedMosaic = nil
        mosaicLayer.contents = nil
        fitLimits()
        detail = Self.detail(at: enclosingScrollView?.magnification ?? 1)
        levelChanged()
        update()
    }

    /// The least magnification shows the whole map (and never more than 1x for a small one).
    private func fitLimits() {
        guard let scroll = enclosingScrollView, bounds.width > 0, bounds.height > 0 else { return }
        let view = scroll.contentView.frame.size
        let fit = min(view.width / bounds.width, view.height / bounds.height, 1)
        scroll.minMagnification = max(0.001, fit)
    }

    /// The whole map in view.
    func fitAll() {
        guard let scroll = enclosingScrollView else { return }
        fitLimits()
        scroll.magnification = scroll.minMagnification
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: .zero, size: scroll.contentView.bounds.size)).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        update()
    }

    private func forCells(_ r: CGRect, _ body: (Int64) -> Void) {
        let x0 = Int((r.minX / cell).rounded(.down)), x1 = Int((r.maxX / cell).rounded(.down))
        let y0 = Int((r.minY / cell).rounded(.down)), y1 = Int((r.maxY / cell).rounded(.down))
        guard x1 >= x0, y1 >= y0 else { return }
        for x in x0...x1 { for y in y0...y1 { body(Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y)))) } }
    }

    /// Every card whose frame meets `r`, once each.
    private func cards(in r: CGRect, _ body: (Int) -> Void) {
        var seen = Set<Int>()
        forCells(r) { key in
            for i in grid[key] ?? [] where cardFrames[i].intersects(r) && seen.insert(i).inserted { body(i) }
        }
    }

    /// The old canvas's curve: out of a card's right side into the next one's left, back to an earlier column from the
    /// left side into the right, and a bow out to the right within one column.
    private func makeRoute(_ ia: Int, _ ib: Int, labels: [String], change: MapSurfaceEdge.Change?, tree: Bool) -> Route {
        let a = captureFrames[ia], b = captureFrames[ib]
        let p0: CGPoint, p1: CGPoint, c0: CGPoint, c1: CGPoint
        if b.minX > a.maxX {
            p0 = CGPoint(x: a.maxX + 4, y: a.midY)
            p1 = CGPoint(x: b.minX - 8, y: b.midY)
            let dx = (p1.x - p0.x) * 0.5
            c0 = CGPoint(x: p0.x + dx, y: p0.y)
            c1 = CGPoint(x: p1.x - dx, y: p1.y)
        } else if b.maxX < a.minX {
            p0 = CGPoint(x: a.minX - 4, y: a.minY + a.height * 0.32)
            p1 = CGPoint(x: b.maxX + 8, y: b.minY + b.height * 0.32)
            let dx = (p0.x - p1.x) * 0.5
            c0 = CGPoint(x: p0.x - dx, y: p0.y)
            c1 = CGPoint(x: p1.x + dx, y: p1.y)
        } else {
            let down = b.minY > a.minY
            p0 = CGPoint(x: a.maxX + 4, y: a.minY + a.height * (down ? 0.68 : 0.32))
            p1 = CGPoint(x: b.maxX + 8, y: b.minY + b.height * (down ? 0.32 : 0.68))
            let bow = 34 + abs(p1.y - p0.y) * 0.16
            c0 = CGPoint(x: p0.x + bow, y: p0.y)
            c1 = CGPoint(x: p1.x + bow, y: p1.y)
        }
        let xs = [p0.x, c0.x, c1.x, p1.x], ys = [p0.y, c0.y, c1.y, p1.y]
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -12, dy: -12)
        return Route(from: ia, to: ib, labels: labels, change: change, tree: tree, p0: p0, c0: c0, c1: c1, p1: p1, box: box)
    }

    // MARK: Following the view

    /// Called whenever the clip view's bounds change: a scroll, a pan, a magnification. Culls, recycles and rebuilds
    /// what the new rect needs, with no implicit animations.
    func update() {
        guard !screens.isEmpty, let scroll = enclosingScrollView else { return }
        let t0 = CACurrentMediaTime()
        let m = scroll.magnification
        let visible = convert(scroll.contentView.bounds, from: scroll.contentView)
        lastVisible = visible
        magnification = m
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let level = affordable(Self.detail(at: m), visible, m)
        if level != detail { detail = level; levelChanged() }
        let scale = m < 1.5 ? 1 : m < 3 ? 2 : m < 6 ? 4 : 8 as CGFloat
        if scale != textScale {
            // Sharper titles for the closer view, a few cards a frame (`decorate`).
            textScale = scale
            for (i, c) in live where c.label.superlayer != nil { c.labelled = -1; undecorated.insert(i) }
        }
        placeGroups(m)
        let t1 = CACurrentMediaTime()
        cull(visible, m)
        let t2 = CACurrentMediaTime()
        decorate()
        let t3 = CACurrentMediaTime()
        buildEdges(visible, m)
        buildMosaic(visible, m)
        placeRing(m)
        CATransaction.commit()
        let t4 = CACurrentMediaTime()
        lastUpdate = t4 - t0
        slowestUpdate = max(slowestUpdate, lastUpdate)
        if Self.trace, lastUpdate > 0.004 {
            print(String(format: "[greenroom] map-surface trace: %.2fx %@ %.1f ms: level and groups %.1f, cull %.1f (%d live), titles %.1f, routes %.1f",
                         m, "\(detail)", lastUpdate * 1000, (t1 - t0) * 1000, (t2 - t1) * 1000, live.count, (t3 - t2) * 1000, (t4 - t3) * 1000))
        }
    }
    static let trace = ProcessInfo.processInfo.environment["GREENROOM_SURFACE_TRACE"] != nil

    /// Cards still waiting for their titles. Titles are drawn off the main thread (text drawn by a CATextLayer at 8x
    /// took 40 ms of a frame), a few asked for per frame, those in view first; the rest follow on the next turns of
    /// the run loop.
    private var undecorated = Set<Int>()
    private var decorateQueued = false
    private let titlesPerPass = 8

    private func decorate() {
        guard detail >= .near, !undecorated.isEmpty else { undecorated = []; return }
        let todo = undecorated.filter { live[$0] != nil }.sorted { a, b in
            let va = lastVisible.intersects(cardFrames[a]), vb = lastVisible.intersects(cardFrames[b])
            return va != vb ? va : a < b
        }
        for i in todo.prefix(titlesPerPass) {
            undecorated.remove(i)
            guard let c = live[i] else { continue }
            let f = captureFrames[i]
            c.labelled = i
            c.labelToken += 1
            let token = c.labelToken, scale = (window?.backingScaleFactor ?? 2) * textScale
            let title = screens[i].title, activity = screens[i].activity, width = f.width + 40
            c.label.frame = CGRect(x: -20, y: f.height + 6, width: width, height: 34)
            if c.label.superlayer == nil { c.root.addSublayer(c.label) }
            Self.titles.async {
                let picture = Self.drawTitle(title, activity, width: width, scale: scale)
                DispatchQueue.main.async { [weak c] in
                    guard let c, c.labelToken == token, let picture else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    c.label.contents = picture.contents
                    CATransaction.commit()
                }
            }
        }
        undecorated = undecorated.filter { live[$0] != nil }
        if !undecorated.isEmpty, !decorateQueued {
            decorateQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [weak self] in
                guard let self else { return }
                self.decorateQueued = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.decorate()
                CATransaction.commit()
            }
        }
    }

    /// The layer budget: a big window or a dense map steps down a detail rather than keep more layers than this.
    static let layerBudget = 240
    private func affordable(_ wanted: Detail, _ visible: CGRect, _ m: CGFloat) -> Detail {
        var level = wanted
        while level == .middle || level == .near {
            // A card is one layer in the middle and up to three near (capture, title, badges).
            let perCard = level == .middle ? 1 : 3, cap = Self.layerBudget / perCard
            let margin = 48 / m
            var n = 0
            cards(in: visible.insetBy(dx: -margin, dy: -margin)) { _ in n += 1 }
            guard n > cap else { break }
            level = level == .near ? .middle : .far
        }
        return level
    }

    private func levelChanged() {
        let far = detail == .far
        for pair in dotLayers { for l in pair { l.isHidden = !far } }
        cardsLayer.isHidden = far
        mosaicLayer.isHidden = !far
        if !far {
            mosaicLayer.contents = nil
            builtMosaic = nil
        }
        groupOutlines.isHidden = detail > .middle
        for t in groupTitles { t.isHidden = detail > .middle }
        if far {
            for i in Array(live.keys) { release(i) }
            buildDots()
        } else {
            for (i, c) in live { configure(c, i) }
        }
        builtEdges = nil
        placePills()
    }

    private func placeGroups(_ m: CGFloat) {
        guard detail <= .middle else { return }
        let k = max(1, 1 / m)
        groupOutlines.lineWidth = k
        for (t, g) in zip(groupTitles, groups) {
            // A title wider than its group would run into the next one's.
            t.isHidden = t.bounds.width * k > g.frame.width + 120
            t.transform = CATransform3DMakeScale(k, k, 1)
            t.position = CGPoint(x: g.frame.minX + 6 * k, y: g.frame.minY - 6 * k)
        }
    }

    private let cardsPerPass = 60
    private var cullQueued = false

    private func cull(_ visible: CGRect, _ m: CGFloat) {
        guard detail != .far else { return }
        let margin = 48 / m
        let around = visible.insetBy(dx: -margin, dy: -margin), keep = visible.insetBy(dx: -margin * 2, dy: -margin * 2)
        for (i, _) in live where !keep.intersects(cardFrames[i]) { release(i) }
        // At most `cardsPerPass` new cards a frame, those in view first: stepping in from far away would otherwise
        // make two hundred in one. The rest come on the next turn of the run loop.
        var missing: [Int] = []
        cards(in: around) { i in if live[i] == nil { missing.append(i) } }
        if missing.count > cardsPerPass {
            missing.sort { a, b in
                let va = visible.intersects(cardFrames[a]), vb = visible.intersects(cardFrames[b])
                return va != vb ? va : a < b
            }
            if !cullQueued {
                cullQueued = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [weak self] in self?.cullQueued = false; self?.update() }
            }
        }
        for i in missing.prefix(cardsPerPass) { acquire(i) }
        if detail == .closest {
            // Only the cards actually in view get the capture itself; the margin keeps the 384-pixel picture.
            for (i, c) in live { want(c, i, visible.intersects(captureFrames[i]) ? .full : .large) }
        }
    }

    // MARK: Cards and the pool

    private func acquire(_ i: Int) {
        let c = pool.popLast() ?? makeCard()
        c.index = i
        configure(c, i)
        cardsLayer.addSublayer(c.root)
        live[i] = c
        liveVersion += 1
    }

    private func release(_ i: Int) {
        guard let c = live.removeValue(forKey: i) else { return }
        c.ticket?.cancel()
        c.ticket = nil
        c.wanted = nil
        c.index = -1
        c.root.contents = nil
        clearTile(c)
        c.root.removeFromSuperlayer()
        c.badge.removeFromSuperlayer()
        c.label.contents = nil
        c.labelled = -1
        c.labelToken += 1
        undecorated.remove(i)
        liveVersion += 1
        if pool.count < poolLimit { pool.append(c) }
    }

    private func makeCard() -> Card {
        let c = Card()
        c.root.cornerRadius = 12
        c.root.cornerCurve = .continuous
        c.root.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        c.root.contentsGravity = .resizeAspectFill
        c.root.shadowColor = NSColor.black.cgColor
        c.root.shadowOffset = CGSize(width: 0, height: 6)
        c.root.shadowRadius = 14
        c.label.contentsGravity = .resize
        c.badge.contentsGravity = .topRight
        c.badge.zPosition = 1
        return c
    }

    /// Sets a card up for its screen at the current detail: its frame, border, picture, title and badges.
    private func configure(_ c: Card, _ i: Int) {
        let f = captureFrames[i]
        c.root.frame = f
        if let tile = screens[i].tile { configureTile(c, i, tile); return }
        clearTile(c)
        let color: NSColor? = switch status[i] {
        case .added?: Design.accent
        case .removed?: Design.record
        case .modified?: Design.warning
        case .notCompared?: Design.mute
        default: nil
        }
        c.root.borderWidth = color == nil ? 1 : 2.5
        c.root.borderColor = (color ?? NSColor(white: 1, alpha: 0.12)).cgColor
        let near = detail >= .near
        c.root.shadowOpacity = near ? 0.55 : 0
        if near { c.root.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: f.size), cornerWidth: 12, cornerHeight: 12, transform: nil) }
        if near {
            if c.labelled != i || c.label.superlayer == nil { undecorated.insert(i) }
            // The badges sit beside the card, not in it: a layer's border is drawn over its sublayers.
            if let image = badgeImage(badges[i]) {
                let scale = Self.badgeScale
                let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
                c.badge.contents = image
                c.badge.contentsScale = scale
                c.badge.frame = CGRect(x: f.maxX - size.width + 8, y: f.minY - 8, width: size.width, height: size.height)
                if c.badge.superlayer == nil { cardsLayer.addSublayer(c.badge) }
            } else { c.badge.removeFromSuperlayer() }
        } else {
            c.label.removeFromSuperlayer()
            c.label.contents = nil
            c.labelled = -1
            c.badge.removeFromSuperlayer()
        }
        style(c, i)
        want(c, i, detail == .middle ? .small : .large)
    }


    // MARK: A folded group's tile

    private func clearTile(_ c: Card) {
        guard c.isTile || !c.thumbs.isEmpty else { return }
        c.thumbTickets.forEach { $0.cancel() }
        c.thumbTickets = []
        c.thumbs.forEach { $0.removeFromSuperlayer(); $0.contents = nil }
        c.thumbs = []
        c.words.removeFromSuperlayer()
        c.words.contents = nil
        c.isTile = false
        c.root.cornerRadius = 12
        c.root.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
    }

    /// The tile: a few small pictures in a row along its top, its name, its screen count and its changes in the status
    /// colours under them. Not a card, so it never reads as a screen whose picture is missing.
    private func configureTile(_ c: Card, _ i: Int, _ tile: MapSurfaceTile) {
        clearTile(c)
        c.isTile = true
        let f = captureFrames[i]
        let color: NSColor? = switch status[i] {
        case .modified?: Design.warning
        default: nil
        }
        c.root.frame = CGRect(x: f.minX, y: f.minY, width: max(f.width, MapSurfaceTile.width), height: f.height)
        c.root.cornerRadius = 16
        c.root.backgroundColor = NSColor(srgbRed: 0.145, green: 0.155, blue: 0.175, alpha: 1).cgColor
        c.root.contents = nil
        c.root.borderWidth = color == nil ? 1.5 : 2.5
        c.root.borderColor = (color ?? NSColor(white: 1, alpha: 0.22)).cgColor
        c.root.shadowOpacity = detail >= .near ? 0.55 : 0
        c.root.shadowPath = nil
        c.label.removeFromSuperlayer()
        c.labelled = -1
        c.badge.removeFromSuperlayer()
        style(c, i)

        let w = c.root.bounds.width, h = c.root.bounds.height
        let pad: CGFloat = 12, gap: CGFloat = 6
        let n = MapSurfaceTile.shown
        let tw = (w - 2 * pad - CGFloat(n - 1) * gap) / CGFloat(n)
        let th = min(tw * 2.17, h - 100)
        for k in 0..<n {
            let t = CALayer()
            t.frame = CGRect(x: pad + CGFloat(k) * (tw + gap), y: pad, width: tw, height: th)
            t.cornerRadius = 6
            t.cornerCurve = .continuous
            t.masksToBounds = true
            t.contentsGravity = .resizeAspectFill
            t.backgroundColor = NSColor(white: 1, alpha: k < tile.pictures.count ? 0.08 : 0.025).cgColor
            c.root.addSublayer(t)
            c.thumbs.append(t)
            guard k < tile.pictures.count, let blob = tile.pictures[k][combo] ?? tile.pictures[k].values.sorted().first else { continue }
            t.contents = pyramid.best(blob, upTo: .small)?.contents
            if let ticket = pyramid.request(blob, .small, done: { [weak t] image in
                guard let t else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                t.contents = image.contents
                CATransaction.commit()
            }) { c.thumbTickets.append(ticket) }
        }

        let scale = (window?.backingScaleFactor ?? 2) * textScale
        let textHeight = h - th - 2 * pad - 8
        var changes: [(String, NSColor)] = []
        if tile.added > 0 { changes.append(("\(tile.added) new", Design.accent)) }
        if tile.modified > 0 { changes.append(("\(tile.modified) changed", Design.warning)) }
        if tile.removed > 0 { changes.append(("\(tile.removed) gone", Design.record)) }
        let name = Self.fit(tile.name, NSFont.systemFont(ofSize: 14, weight: .semibold), w - 2 * pad)
        let count = "\(tile.count) screen\(tile.count == 1 ? "" : "s")"
        let picture = MapPicture.draw(Int(((w - 2 * pad) * scale).rounded(.up)), Int((textHeight * scale).rounded(.up))) { ctx in
            ctx.scaleBy(x: scale, y: scale)
            func line(_ parts: [(String, NSFont, NSColor)], baseline: CGFloat) {
                var x: CGFloat = 0
                for (text, font, color) in parts {
                    let l = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
                    ctx.textPosition = CGPoint(x: x, y: baseline)
                    CTLineDraw(l, ctx)
                    x += CTLineGetTypographicBounds(l, nil, nil, nil)
                }
            }
            line([(name, .systemFont(ofSize: 14, weight: .semibold), Design.ink)], baseline: textHeight - 22)
            line([(count, .systemFont(ofSize: 11.5), Design.mute)], baseline: textHeight - 42)
            if changes.isEmpty {
                line([("none changed", .systemFont(ofSize: 11.5), Design.mute)], baseline: textHeight - 62)
            } else {
                var parts: [(String, NSFont, NSColor)] = []
                for (k, ch) in changes.enumerated() {
                    if k > 0 { parts.append(("  ·  ", .systemFont(ofSize: 11.5), Design.mute)) }
                    parts.append((ch.0, .systemFont(ofSize: 11.5, weight: .semibold), ch.1))
                }
                line(parts, baseline: textHeight - 62)
            }
        }
        c.words.frame = CGRect(x: pad, y: pad + th + 8, width: w - 2 * pad, height: textHeight)
        c.words.contents = picture?.contents
        c.root.addSublayer(c.words)
    }

    /// Asks for the card's picture at `tier`, showing the best one already in memory until it comes.
    private func want(_ c: Card, _ i: Int, _ tier: MapPyramid.Tier) {
        guard c.wanted != tier else { return }
        c.ticket?.cancel()
        c.ticket = nil
        c.wanted = tier
        guard let blob = screens[i].captures[combo] ?? screens[i].captures.values.sorted().first else {
            c.root.contents = nil
            return
        }
        c.root.contents = pyramid.best(blob, upTo: tier)?.contents
        c.ticket = pyramid.request(blob, tier) { [weak c] image in
            guard let c, c.index == i, c.wanted == tier else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            c.root.contents = image.contents
            CATransaction.commit()
            c.ticket = nil
        }
    }

    private func reloadImages() {
        for (i, c) in live {
            let tier = c.wanted
            c.wanted = nil
            want(c, i, tier ?? .large)
        }
        if !screens.isEmpty { buildMosaic(lastVisible, magnification) }
    }

    private static let titles = DispatchQueue(label: "greenroom-map-titles", qos: .userInitiated)

    /// A card's title over its activity, centred and cut to `width` points, at `scale` pixels a point. Any thread.
    private static func drawTitle(_ title: String, _ activity: String, width: CGFloat, scale: CGFloat) -> MapPicture? {
        let bold = NSFont.systemFont(ofSize: 11.5, weight: .semibold), plain = NSFont.systemFont(ofSize: 10, weight: .regular)
        let lines = [(fit(title, bold, width), bold, Design.ink, CGFloat(22)), (fit(activity, plain, width), plain, Design.mute, CGFloat(6.5))]
        return MapPicture.draw(Int((width * scale).rounded(.up)), Int((34 * scale).rounded(.up))) { ctx in
            ctx.scaleBy(x: scale, y: scale)
            for (text, font, color, baseline) in lines {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
                let w = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.textPosition = CGPoint(x: (width - w) / 2, y: baseline)
                CTLineDraw(line, ctx)
            }
        }
    }

    private static func fit(_ s: String, _ font: NSFont, _ width: CGFloat) -> String {
        func w(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width }
        guard w(s) > width else { return s }
        var t = s
        while !t.isEmpty, w(t + "…") > width { t.removeLast() }
        return t + "…"
    }

    private static let badgeScale: CGFloat = 4
    /// The badges of a card as one picture (pills stacked down its top right corner), made once per set of words.
    private func badgeImage(_ list: [(String, NSColor)]) -> CGImage? {
        guard !list.isEmpty else { return nil }
        let key = list.map(\.0).joined(separator: "|")
        if let hit = Self.badgeImages[key] { return hit }
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let widths = list.map { ($0.0 as NSString).size(withAttributes: [.font: font]).width + 14 }
        let w = ceil(widths.max() ?? 0), h = CGFloat(list.count) * 22 - 4
        let scale = Self.badgeScale
        guard let ctx = MapPyramid.context(Int(w * scale), Int(h * scale)) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Drawn top down.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for (n, (text, color)) in list.enumerated() {
            let pw = widths[n]
            let rect = CGRect(x: w - pw, y: CGFloat(n) * 22, width: pw, height: 18)
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
            (color == Design.mute ? NSColor(white: 0.22, alpha: 0.95) : color.withAlphaComponent(0.22).blended(withFraction: 0.6, of: Design.stage) ?? color).setFill()
            pill.fill()
            color.withAlphaComponent(0.6).setStroke()
            pill.lineWidth = 1
            pill.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color == Design.mute ? Design.ink : color]
            let tw = (text as NSString).size(withAttributes: attrs).width
            (text as NSString).draw(at: CGPoint(x: rect.midX - tw / 2, y: rect.minY + 2), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = ctx.makeImage()
        Self.badgeImages[key] = image
        return image
    }

    // MARK: Far away

    /// A tile per screen in its status's colour, one path per status; with a focus, the screens it is not joined to
    /// go in the dim copy.
    private func buildDots() {
        let focus = focusIndex
        if case .some(let was) = dotsFocus, was == focus { return }
        dotsFocus = .some(focus)
        let paths = (0..<dotLayers.count).map { _ in [CGMutablePath(), CGMutablePath()] }
        for i in screens.indices {
            let bucket = switch status[i] {
            case .added?: 1
            case .removed?: 2
            case .modified?: 3
            case .notCompared?: 4
            default: 0
            }
            let lit = focus == nil || i == focus || related.contains(i)
            paths[bucket][lit ? 1 : 0].addRoundedRect(in: captureFrames[i], cornerWidth: 12, cornerHeight: 12)
        }
        for (b, pair) in dotLayers.enumerated() { for k in 0..<2 { pair[k].path = paths[b][k] } }
    }

    /// The pictures over the tiles: one bitmap for the region around the view, drawn off the main thread at the
    /// view's resolution or the mosaic's finest, whichever is coarser. Asked for again when the view leaves the
    /// region, the magnification moves well away from what was drawn, the focus moves or more small copies came; one
    /// at a time, the tiles showing through wherever a picture is not there yet.
    private func buildMosaic(_ visible: CGRect, _ m: CGFloat) {
        guard detail == .far, askedMosaic == nil else { return }
        let seen = visible.intersection(bounds)
        guard !seen.isEmpty else { return }
        let focus = focusIndex
        let region = visible.insetBy(dx: -visible.width * 0.25, dy: -visible.height * 0.25).intersection(bounds).integral
        var scale = min(m * (window?.backingScaleFactor ?? 2), MapMosaic.finest)
        let pixels = region.width * region.height * scale * scale
        if pixels > MapMosaic.pixelBudget { scale *= (MapMosaic.pixelBudget / pixels).squareRoot() }
        if let b = builtMosaic, b.focus == focus, b.combo == combo, b.version == mosaicVersion, b.region.insetBy(dx: -1, dy: -1).contains(seen),
           scale <= b.scale * 1.3, scale >= b.scale * 0.6 { return }
        var items: [MapMosaic.Item] = []
        cards(in: region) { i in
            guard screens[i].tile == nil, let blob = screens[i].captures[combo] ?? screens[i].captures.values.sorted().first else { return }
            let color: NSColor? = switch status[i] {
            case .added?: Design.accent
            case .removed?: Design.record
            case .modified?: Design.warning
            case .notCompared?: Design.mute
            default: nil
            }
            items.append(MapMosaic.Item(frame: captureFrames[i], blob: blob, border: color?.cgColor, lit: focus == nil || i == focus || related.contains(i)))
        }
        let key = MosaicKey(region: region, scale: scale, focus: focus, combo: combo, version: mosaicVersion)
        askedMosaic = key
        let map = mosaicMap
        mosaic.render(items, region: region, scale: scale) { [weak self] picture in
            guard let self, self.mosaicMap == map else { return }
            self.askedMosaic = nil
            guard self.detail == .far else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let picture {
                self.mosaicLayer.frame = region
                self.mosaicLayer.contents = picture.contents
                self.builtMosaic = key
            }
            // The view may have moved on while this was drawn.
            if picture != nil { self.buildMosaic(self.lastVisible, self.magnification) }
            CATransaction.commit()
        }
    }
    /// Whether the far view has its pictures now, and the small copies in memory: for checks.
    var mosaicShown: Bool { !mosaicLayer.isHidden && mosaicLayer.contents != nil }
    var mosaicCopies: Int { mosaic.copiesInMemory }

    // MARK: Routes

    private var focusIndex: Int? { selected.flatMap { indexOf[$0] } ?? hovered }

    private func style(of r: Route, focus: Int?) -> EdgeStyle {
        if let focus {
            if r.from == focus { return .out }
            if r.to == focus { return .into }
        }
        switch r.change {
        case .added?: return .added
        case .removed?: return .removed
        case nil: return .dim
        }
    }

    /// One path per style for the routes that cross the region around the view; rebuilt when the view leaves that
    /// region, the focus moves or the detail changes. Drawn: the focused screen's routes and the changed ones; near,
    /// the tree's routes between cards that are both alive (in view or just outside it); everything only with
    /// `showAllEdges`, and never far away.
    private func buildEdges(_ visible: CGRect, _ m: CGFloat, force: Bool = false) {
        let focus = focusIndex
        // Lines keep at least a pixel's width far out (steps of a quarter keep the rebuilds rare while zooming), and
        // up close they thin by the titles' steps so a route stays a line, not a band.
        let weight = m < 1 ? max(1, ((0.9 / m) * 4).rounded(.up) / 4) : 1 / textScale
        let treeNear = detail == .near && !showAllEdges
        let key = EdgeKey(detail: detail, focus: focus, weight: weight, all: showAllEdges, cards: treeNear ? liveVersion : 0)
        if !force, let b = builtEdges, b.key == key, b.region.contains(visible) { return }
        let region = detail == .far ? CGRect.infinite : visible.insetBy(dx: -visible.width * 0.5, dy: -visible.height * 0.5)
        builtEdges = (region, key)
        let linePaths = EdgeStyle.allCases.map { _ in CGMutablePath() }, tipPaths = EdgeStyle.allCases.map { _ in CGMutablePath() }
        var counts: [EdgeStyle: Int] = [:]
        func add(_ r: Route, _ s: EdgeStyle) {
            linePaths[s.rawValue].move(to: r.p0)
            linePaths[s.rawValue].addCurve(to: r.p1, control1: r.c0, control2: r.c1)
            let angle = atan2(r.p1.y - r.c1.y, r.p1.x - r.c1.x), p1 = r.p1, t = tipPaths[s.rawValue]
            t.move(to: CGPoint(x: p1.x + cos(angle) * 4 * weight, y: p1.y + sin(angle) * 4 * weight))
            t.addLine(to: CGPoint(x: p1.x + cos(angle + 2.5) * 7 * weight, y: p1.y + sin(angle + 2.5) * 7 * weight))
            t.addLine(to: CGPoint(x: p1.x + cos(angle - 2.5) * 7 * weight, y: p1.y + sin(angle - 2.5) * 7 * weight))
            t.closeSubpath()
            counts[s, default: 0] += 1
        }
        if detail == .far {
            if let focus { for k in routesOut[focus] + routesIn[focus] { add(routes[k], style(of: routes[k], focus: focus)) } }
            for r in routes where r.change != nil && r.from != focus && r.to != focus { add(r, style(of: r, focus: focus)) }
        } else {
            for r in routes where r.box.intersects(region) {
                let s = style(of: r, focus: focus)
                if s == .dim && !showAllEdges && !(treeNear && r.tree && live[r.from] != nil && live[r.to] != nil) { continue }
                add(r, s)
            }
        }
        drawnRoutes = counts
        for s in EdgeStyle.allCases {
            let color: NSColor = switch s {
            case .out: Design.accent
            case .into: NSColor(white: 1, alpha: 0.55)
            // Where routes are many they are a texture, not lines to follow: fainter, so the cards stay readable.
            case .dim: NSColor(white: 1, alpha: focus != nil ? 0.07 : showAllEdges ? ((counts[.dim] ?? 0) > 400 ? 0.1 : 0.22) : 0.16)
            case .added: Design.accent.withAlphaComponent(focus == nil ? 0.8 : 0.25)
            case .removed: Design.record.withAlphaComponent(focus == nil ? 0.8 : 0.25)
            }
            lines[s.rawValue].path = linePaths[s.rawValue]
            lines[s.rawValue].strokeColor = color.cgColor
            lines[s.rawValue].lineWidth = (s == .out ? 2.2 : 1.6) * weight
            lines[s.rawValue].lineDashPattern = s == .removed ? [NSNumber(value: 5 * weight), NSNumber(value: 4 * weight)] : nil
            tips[s.rawValue].path = tipPaths[s.rawValue]
            tips[s.rawValue].fillColor = color.cgColor
        }
    }

    /// The controls' names on the routes out of the selected card, near enough to read them.
    private func placePills() {
        pillsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard detail >= .near, let s = selected.flatMap({ indexOf[$0] }) else { return }
        let region = lastVisible.insetBy(dx: -lastVisible.width * 0.25, dy: -lastVisible.height * 0.25)
        for k in routesOut[s].prefix(24) where region.contains(routes[k].mid) {
            let r = routes[k]
            let label = r.labels.count > 1 ? "\(r.labels[0])  +\(r.labels.count - 1)" : (r.labels.first ?? "")
            pillsLayer.addSublayer(makePill(label, at: r.mid))
        }
    }

    private func makePill(_ s: String, at p: CGPoint) -> CALayer {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let shown = s.count > 26 ? String(s.prefix(25)) + "…" : s
        let w = (shown as NSString).size(withAttributes: [.font: font]).width + 16
        let pill = CALayer()
        pill.frame = CGRect(x: p.x - w / 2, y: p.y - 10, width: w, height: 20)
        pill.cornerRadius = 10
        pill.backgroundColor = Design.accent.cgColor
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOpacity = 0.4
        pill.shadowRadius = 6
        pill.shadowOffset = CGSize(width: 0, height: 2)
        pill.shadowPath = CGPath(roundedRect: pill.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let t = CATextLayer()
        t.string = NSAttributedString(string: shown, attributes: [.font: font, .foregroundColor: Design.onAccent])
        t.alignmentMode = .center
        t.contentsScale = (window?.backingScaleFactor ?? 2) * textScale
        t.frame = CGRect(x: 0, y: 3, width: w, height: 15)
        pill.addSublayer(t)
        if !Design.reduceMotion {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.6; pop.toValue = 1
            pop.damping = 14; pop.stiffness = 260
            pop.duration = pop.settlingDuration
            pill.add(pop, forKey: "pop")
        }
        return pill
    }

    // MARK: Selection and hover

    func select(_ lineage: String?, reveal: Bool = true) {
        selected = lineage.flatMap { indexOf[$0] != nil ? $0 : nil }
        restyle()
        if reveal, let i = selected.flatMap({ indexOf[$0] }) { scrollIntoView(cardFrames[i].insetBy(dx: -90, dy: -40)) }
        onSelect?(selected)
    }

    private func restyle() {
        let focus = focusIndex
        related = focus.map { f in Set(routesOut[f].map { routes[$0].to } + routesIn[f].map { routes[$0].from }) } ?? []
        CATransaction.begin()
        CATransaction.setAnimationDuration(Design.snap)
        for (i, c) in live { style(c, i) }
        CATransaction.setDisableActions(true)
        if detail == .far { buildDots() }
        buildMosaic(lastVisible, magnification)
        buildEdges(lastVisible, magnification, force: true)
        placeRing(magnification)
        placePills()
        CATransaction.commit()
    }

    private func style(_ c: Card, _ i: Int) {
        let focus = focusIndex
        let on = selected.flatMap { indexOf[$0] } == i
        c.root.opacity = focus == nil || i == focus || related.contains(i) ? 1 : 0.38
        c.badge.opacity = c.root.opacity
        c.root.transform = i == hovered && !on && detail >= .middle ? CATransform3DMakeScale(1.035, 1.035, 1) : CATransform3DIdentity
    }

    private func placeRing(_ m: CGFloat) {
        guard let i = selected.flatMap({ indexOf[$0] }) else { ring.isHidden = true; return }
        let k = max(1, 1 / m)
        ring.isHidden = false
        ring.frame = captureFrames[i].insetBy(dx: -4 * k, dy: -4 * k)
        ring.cornerRadius = 12 + 4 * k
        ring.borderWidth = 2 * k
        ring.shadowRadius = 10 * k
    }

    private func card(at p: NSPoint) -> Int? {
        let slop = max(6, 4 / magnification)
        var hit: Int?
        cards(in: CGRect(x: p.x - slop, y: p.y - slop, width: slop * 2, height: slop * 2)) { i in
            if hit == nil, (detail == .far ? captureFrames[i] : cardFrames[i]).insetBy(dx: -slop, dy: -slop).contains(p) { hit = i }
        }
        return hit
    }

    override func mouseMoved(with event: NSEvent) {
        let i = card(at: convert(event.locationInWindow, from: nil))
        guard i != hovered else { return }
        hovered = i
        if i != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        restyle()
    }
    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        NSCursor.arrow.set()
        restyle()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let i = card(at: convert(event.locationInWindow, from: nil)) {
            if event.clickCount == 2 { onOpen?(screens[i].lineage) } else { select(screens[i].lineage, reveal: false) }
            return
        }
        if let g = groupTitle(at: convert(event.locationInWindow, from: nil)) { onGroup?(g); return }
        panStart = (event.locationInWindow, enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }

    /// The group whose title is at `p`: the words, a little around them, while titles are showing.
    private func groupTitle(at p: NSPoint) -> Int? {
        guard onGroup != nil, detail <= .middle else { return nil }
        let k = max(1, 1 / magnification)
        for (i, (t, g)) in zip(groupTitles, groups).enumerated() where !t.isHidden {
            let r = CGRect(x: g.frame.minX, y: g.frame.minY - 34 * k, width: t.bounds.width * k + 12 * k, height: 42 * k)
            if r.contains(p) { return i }
        }
        return nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (start, origin) = panStart, let clip = enclosingScrollView?.contentView else { return }
        NSCursor.closedHand.set()
        let m = enclosingScrollView?.magnification ?? 1
        let dx = (event.locationInWindow.x - start.x) / m, dy = (event.locationInWindow.y - start.y) / m
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: origin.x - dx, y: origin.y + dy), size: clip.bounds.size)).origin)
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if panStart != nil, event.locationInWindow == panStart?.0 { select(nil, reveal: false) }
        panStart = nil
        NSCursor.arrow.set()
    }

    /// Arrow keys walk the map: right follows the first route out, left goes to the parent, up and down move in a column.
    override func keyDown(with event: NSEvent) {
        guard let id = selected.flatMap({ indexOf[$0] }) ?? (screens.isEmpty ? nil : 0) else { super.keyDown(with: event); return }
        let here = screens[id]
        let column = columnOrder[here.depth] ?? [id]
        let n = column.firstIndex(of: id) ?? 0
        switch event.keyCode {
        case 124: select(screens[routesOut[id].first { screens[routes[$0].to].depth > here.depth }.map { routes[$0].to } ?? id].lineage)
        case 123: select(here.parent ?? here.lineage)
        case 125: select(screens[column[min(n + 1, column.count - 1)]].lineage)
        case 126: select(screens[column[max(n - 1, 0)]].lineage)
        case 36, 76: onOpen?(here.lineage)
        default: super.keyDown(with: event)
        }
    }

    private func scrollIntoView(_ rect: CGRect) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let visible = clip.bounds
        guard !visible.contains(rect) else { return }
        var o = visible.origin
        if rect.minX < visible.minX { o.x = rect.minX } else if rect.maxX > visible.maxX { o.x = rect.maxX - visible.width }
        if rect.minY < visible.minY { o.y = rect.minY } else if rect.maxY > visible.maxY { o.y = rect.maxY - visible.height }
        o = clip.constrainBoundsRect(NSRect(origin: o, size: visible.size)).origin
        Design.animate(Design.move, { clip.animator().setBoundsOrigin(o) }, done: { scroll.reflectScrolledClipView(clip) })
    }

    /// Where a screen's card is, in the canvas: for checks.
    func frame(of lineage: String) -> CGRect? { indexOf[lineage].map { cardFrames[$0] } }
    /// The routes out of and into a screen, drawn or not.
    func routeCount(of lineage: String) -> (out: Int, into: Int) {
        guard let i = indexOf[lineage] else { return (0, 0) }
        return (routesOut[i].count, routesIn[i].count)
    }
    var routeCount: Int { routes.count }
    /// Routes a comparison marks (added, removed, retargeted, or into a new or gone screen).
    var changedRouteCount: Int { routes.filter { $0.change != nil }.count }
    /// Tree routes whose two cards are alive now.
    var liveTreeRouteCount: Int { routes.filter { $0.tree && live[$0.from] != nil && live[$0.to] != nil }.count }
    var drawnRouteCount: Int { drawnRoutes.values.reduce(0, +) }
}
