import AppKit

// Getting around the map (docs/MAP-HISTORY-PLAN.md, package C3): the surface (MapSurface) in a scroll view with what a
// map of thousands of screens needs around it: filters with counts, changes first, groups that fold, search, a
// minimap and a few keys. Everything that can be worked out without a view (what is shown, where it goes, what the
// surface and the minimap draw) is worked out off the main thread by `MapNavigatorPlan.make`, from a `MapNavigatorModel`
// that holds the map once; the view only hands the result to the surface. A plan is cached by what made it, so opening
// a map again costs the surface's own work and nothing else.

// MARK: - The map, as the navigator knows it

/// A map (a snapshot, and with a comparison the screens only the base has) flattened into what the navigator asks of
/// it: screens by key (their lineage, or their id when they have none), routes between them, each screen's section,
/// its words for search, and the counts per filter. Built once per map, off the main thread.
final class MapNavigatorModel: @unchecked Sendable {
    struct Item {
        var key: String
        var screen: MapSnapshot.Screen
        var status: MapDiff.Status?
        var change: MapDiff.ScreenChange?
        var parent: Int?
        var depth: Int
        var crashes = 0, exits = 0, loops = 0
        /// The title of the depth-1 screen it hangs from: what a search result says it is in.
        var section = ""
        /// Title, activity and visible texts, lowercased and unaccented.
        var words = ""
        var differs: Bool { status == .added || status == .removed || status == .modified }
    }

    struct Link {
        var from: Int, to: Int
        var labels: [String]
        var change: MapSurfaceEdge.Change?
        var order: Int
    }

    let id: String
    let items: [Item]
    let index: [String: Int]
    let links: [Link]
    let hasDiff: Bool
    /// One step in either direction over the links.
    let neighbours: [[Int]]
    let counts: [MapNavigator.Filter: Int]

    static func key(for head: MapSnapshot, _ diff: MapDiff?, _ base: MapSnapshot?) -> String {
        [head.commit, head.tree, "\(head.screens.count)/\(head.edges.count)", base?.commit ?? "-",
         diff.map { "\($0.counts.added).\($0.counts.removed).\($0.counts.modified).\($0.counts.notCompared)" } ?? "-"].joined(separator: "|")
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    init(head: MapSnapshot, diff: MapDiff?, base: MapSnapshot?) {
        id = Self.key(for: head, diff, base)
        hasDiff = diff != nil
        let changes = Dictionary((diff?.screens ?? []).map { ($0.lineage, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [Item] = []
        var index: [String: Int] = [:]
        var headKey: [String: String] = [:], baseKey: [String: String] = [:]
        func add(_ s: MapSnapshot.Screen) -> String {
            var key = s.lineage.isEmpty ? s.id : s.lineage
            if index[key] != nil { key = s.id; var n = 1; while index[key] != nil { key = s.id + "#\(n)"; n += 1 } }
            index[key] = items.count
            let change = changes[s.lineage.isEmpty ? s.id : s.lineage]
            items.append(Item(key: key, screen: s, status: change?.status, change: change, parent: nil, depth: max(0, s.depth)))
            return key
        }
        for s in head.screens { let k = add(s); if headKey[s.id] == nil { headKey[s.id] = k } }
        var baseOnly = Set<String>()
        if let base {
            for s in base.screens {
                let lineage = s.lineage.isEmpty ? s.id : s.lineage
                if let at = index[lineage] { if baseKey[s.id] == nil { baseKey[s.id] = items[at].key }; continue }
                guard let c = changes[lineage], c.head == nil else { continue }
                let k = add(s)
                baseKey[s.id] = k
                baseOnly.insert(k)
            }
        }
        for i in items.indices {
            let own = baseOnly.contains(items[i].key) ? baseKey : headKey
            items[i].parent = items[i].screen.parent.flatMap { own[$0] }.flatMap { index[$0] }.flatMap { $0 == i ? nil : $0 }
        }

        // What each screen's own walk found behind its controls, and the routes between screens.
        let changedEdges = Dictionary((diff?.edges ?? []).map { ($0.from + "\u{1}" + $0.cmd, $0.status) }, uniquingKeysWith: { a, _ in a })
        var links: [Link] = []
        var linkAt: [String: Int] = [:]
        func link(_ a: Int, _ b: Int, _ label: String, _ change: MapSurfaceEdge.Change?, _ order: Int) {
            let k = "\(a)>\(b)\(change == .removed ? "-" : "")"
            if let at = linkAt[k] { links[at].labels.append(label); links[at].order = min(links[at].order, order); return }
            linkAt[k] = links.count
            links.append(Link(from: a, to: b, labels: [label], change: change, order: order))
        }
        for e in head.edges {
            guard let fk = headKey[e.from], let a = index[fk] else { continue }
            if e.to == "CRASH" { items[a].crashes += 1 } else if e.to == "EXIT" { items[a].exits += 1 } else if e.to == e.from { items[a].loops += 1 }
            guard let t = e.to, let tk = headKey[t], let b = index[tk], a != b else { continue }
            let status = changedEdges[fk + "\u{1}" + e.cmd]
            link(a, b, e.action, status == .added || status == .retargeted ? .added : nil, e.order)
        }
        if let base {
            for e in base.edges {
                guard let fk = baseKey[e.from], let a = index[fk] else { continue }
                if baseOnly.contains(fk) {
                    if e.to == "CRASH" { items[a].crashes += 1 } else if e.to == "EXIT" { items[a].exits += 1 } else if e.to == e.from { items[a].loops += 1 }
                }
                guard let t = e.to, let tk = baseKey[t], let b = index[tk], a != b else { continue }
                let status = changedEdges[fk + "\u{1}" + e.cmd]
                if status == .removed || status == .retargeted { link(a, b, e.action, .removed, e.order) }
            }
        }
        // Statuses read by the screen's own key (a screen is named by lineage in the comparison).
        for i in items.indices {
            var hops = 0, cur = i
            while items[cur].depth > 1, let p = items[cur].parent, hops < 10_000 { cur = p; hops += 1 }
            items[i].section = items[cur].screen.title
            items[i].words = Self.fold(([items[i].screen.title, items[i].screen.activity] + items[i].screen.texts).joined(separator: "\n"))
        }
        var near = Array(repeating: [Int](), count: items.count)
        for l in links {
            if !near[l.from].contains(l.to) { near[l.from].append(l.to) }
            if !near[l.to].contains(l.from) { near[l.to].append(l.from) }
        }
        var counts: [MapNavigator.Filter: Int] = [:]
        for f in MapNavigator.Filter.allCases { counts[f] = items.filter { f.matches($0) }.count }
        self.items = items
        self.index = index
        self.links = links
        self.neighbours = near
        self.counts = counts
    }
}

// MARK: - What is shown and where

/// One arrangement of the map for a filter, a fold and a set of collapsed groups: the layout, the input the surface
/// takes, the minimap's picture and what the navigator needs to answer questions about it. A value; made anywhere.
struct MapNavigatorPlan {
    struct GroupInfo {
        var id: String
        var title: String
        var members: [String]
        var changed: Int
        var collapsed: Bool
        var summary: String { "\(title): \(members.count) screen\(members.count == 1 ? "" : "s")" + (changed > 0 ? ", \(changed) changed" : "") }
    }

    let id = UUID().uuidString
    var layout: MapLayout
    var input: MapSurfaceInput
    /// The groups the surface draws titles for, parallel to `input.placement.groups`.
    var titledGroups: [String]
    var groups: [String: GroupInfo]
    var groupOf: [String: String]
    var collapsed: Set<String>
    /// The screens the filter and the fold let through, by key.
    var shown: Set<String>
    /// The differing screens of `shown`, in reading order (group by group, column by column).
    var changedOrder: [String]
    /// Everything left out by the fold.
    var folded: Int
    var minimap: CGImage?

    /// A map over this many shown screens opens with its groups collapsed, but those holding changes.
    static let collapseAbove = 300

    static func shownItems(_ m: MapNavigatorModel, filter: MapNavigator.Filter, fold: Bool) -> [Int] {
        if filter != .all { return m.items.indices.filter { filter.matches(m.items[$0]) } }
        let changed = m.items.indices.filter { m.items[$0].differs }
        guard fold, m.hasDiff, !changed.isEmpty else { return Array(m.items.indices) }
        var keep = Set(changed)
        for i in changed { keep.formUnion(m.neighbours[i]) }
        return m.items.indices.filter { keep.contains($0) }
    }

    static func make(_ m: MapNavigatorModel, filter: MapNavigator.Filter, fold: Bool, overrides: [String: Bool], previous: MapLayout?) -> MapNavigatorPlan {
        let shownList = shownItems(m, filter: filter, fold: fold)
        var inShown = Array(repeating: false, count: m.items.count)
        for i in shownList { inShown[i] = true }

        // Parents and depths among the shown: a screen hangs from its nearest shown ancestor, a column to the right of it;
        // one with none starts a section of its own.
        var parent: [Int?] = m.items.map(\.parent), depth: [Int] = m.items.map(\.depth)
        if shownList.count != m.items.count {
            var done = Array(repeating: false, count: m.items.count), visiting = Array(repeating: false, count: m.items.count)
            func settle(_ i: Int) {
                guard !done[i], !visiting[i] else { return }
                visiting[i] = true
                var p = m.items[i].parent, hops = 0
                while let q = p, !inShown[q], hops < 10_000 { p = m.items[q].parent; hops += 1 }
                if let p, inShown[p], p != i {
                    settle(p)
                    parent[i] = p
                    depth[i] = visiting[p] && !done[p] ? m.items[i].depth : depth[p] + 1
                } else {
                    parent[i] = nil
                    depth[i] = m.items[i].depth == 0 ? 0 : 1
                }
                visiting[i] = false
                done[i] = true
            }
            for i in shownList { settle(i) }
        }

        // Groups, the layout's way: the depth-1 ancestor on the parent chain.
        func anchor(_ i: Int) -> Int {
            var cur = i, hops = 0
            while depth[cur] > 1, let p = parent[cur], hops < 10_000 { cur = p; hops += 1 }
            return cur
        }
        var members: [String: [Int]] = [:]
        for i in shownList { members["g:" + m.items[anchor(i)].key, default: []].append(i) }
        var collapsed = Set<String>()
        if shownList.count > collapseAbove {
            for (g, list) in members where !list.contains(where: { m.items[$0].differs }) { collapsed.insert(g) }
        }
        for (g, v) in overrides where members[g] != nil { if v { collapsed.insert(g) } else { collapsed.remove(g) } }

        // The layout over just what is shown.
        func key(_ i: Int) -> String { m.items[i].key }
        let screens = shownList.map { i -> MapSnapshot.Screen in
            var s = m.items[i].screen
            s.id = key(i); s.lineage = key(i); s.depth = depth[i]; s.parent = parent[i].map(key)
            s.captures = [:]; s.texts = []
            return s
        }
        let edges = m.links.filter { inShown[$0.from] && inShown[$0.to] }.map {
            MapSnapshot.Edge(from: key($0.from), order: $0.order, action: $0.labels.first ?? "", cmd: "\($0.from)>\($0.to)", to: key($0.to), note: nil)
        }
        let snapshot = MapSnapshot(commit: "", tree: "", profile: MapProfile(), engine: "", walked: "", screens: screens, edges: edges)
        let layout = MapLayout.make(snapshot, previous: previous, collapsed: collapsed)

        // What the surface is given: cards for the open groups, one tile for each folded one.
        var groups: [String: GroupInfo] = [:], groupOf: [String: String] = [:]
        for g in layout.groups {
            let list = members[g.id] ?? []
            groups[g.id] = GroupInfo(id: g.id, title: g.title, members: g.members, changed: list.filter { m.items[$0].differs }.count, collapsed: g.collapsed)
            for k in g.members { groupOf[k] = g.id }
        }
        var frames = layout.frames
        var surfaceScreens: [MapSurfaceScreen] = []
        var changes: [String: MapDiff.ScreenChange] = [:]
        for i in shownList {
            let k = key(i)
            let g = groupOf[k] ?? ""
            if collapsed.contains(g) { continue }
            let it = m.items[i]
            surfaceScreens.append(MapSurfaceScreen(lineage: k, id: it.screen.id, title: it.screen.title, activity: it.screen.activity, depth: depth[i],
                                                   parent: parent[i].flatMap { p in collapsed.contains(groupOf[key(p)] ?? "") ? groupOf[key(p)] : key(p) },
                                                   captures: it.screen.captures, crashes: it.crashes, exits: it.exits, loops: it.loops))
            if let c = it.change { changes[k] = c }
        }
        var titled: [String] = [], placed: [MapPlacement.Group] = []
        for g in layout.groups {
            guard let info = groups[g.id] else { continue }
            if g.collapsed {
                frames[g.id] = g.frame
                surfaceScreens.append(MapSurfaceScreen(lineage: g.id, id: g.id, title: info.summary, activity: "click to open", depth: g.minDepth, parent: nil, captures: [:]))
                changes[g.id] = MapDiff.ScreenChange(lineage: g.id, base: nil, head: nil, status: info.changed > 0 ? .modified : .same)
            } else {
                titled.append(g.id)
                placed.append(MapPlacement.Group(frame: g.frame, title: "▾ \(info.title) · \(info.members.count)"))
            }
        }
        func end(_ i: Int) -> String { groupOf[key(i)].flatMap { collapsed.contains($0) ? $0 : nil } ?? key(i) }
        var merged: [String: MapSurfaceEdge] = [:], order: [String] = []
        for l in m.links where inShown[l.from] && inShown[l.to] {
            let a = end(l.from), b = end(l.to)
            guard a != b else { continue }
            let k = "\(a)>\(b)\(l.change == .removed ? "-" : "")"
            if merged[k] == nil { merged[k] = MapSurfaceEdge(from: a, to: b, labels: [], change: l.change); order.append(k) }
            if merged[k]!.labels.count < 8 { merged[k]!.labels += l.labels.prefix(8 - merged[k]!.labels.count) }
        }
        let input = MapSurfaceInput(screens: surfaceScreens, edges: order.map { merged[$0]! }, placement: MapPlacement(frames: frames, groups: placed, size: layout.size), changes: changes)

        var changedOrder: [String] = []
        for g in layout.groups { for k in g.members { if let i = m.index[k], m.items[i].differs { changedOrder.append(k) } } }
        return MapNavigatorPlan(layout: layout, input: input, titledGroups: titled, groups: groups, groupOf: groupOf, collapsed: collapsed,
                                shown: Set(shownList.map(key)), changedOrder: changedOrder, folded: m.items.count - shownList.count,
                                minimap: minimapPicture(m, layout: layout, frames: frames))
    }

    /// The whole map as marks in its statuses' colours, as sharp as the corner it goes in needs. Any thread.
    static func minimapPicture(_ m: MapNavigatorModel, layout: MapLayout, frames: [String: CGRect]) -> CGImage? {
        let box = MapMinimap.box, scale: CGFloat = 2
        let s = min(box.width / max(layout.size.width, 1), box.height / max(layout.size.height, 1))
        let w = max(1, Int((layout.size.width * s * scale).rounded())), h = max(1, Int((layout.size.height * s * scale).rounded()))
        guard let ctx = MapPyramid.context(w, h) else { return nil }
        let k = s * scale
        func rect(_ f: CGRect) -> CGRect {
            // The canvas runs down, the bitmap up.
            CGRect(x: f.minX * k, y: CGFloat(h) - f.maxY * k, width: max(2, f.width * k), height: max(2.5, f.height * k * 0.8))
        }
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor)
        ctx.setLineWidth(1)
        for g in layout.groups where !g.collapsed { ctx.stroke(rect(g.frame).insetBy(dx: 0.5, dy: 0.5)) }
        // Same first, so the screens that say something are drawn over it.
        let colors: [(MapDiff.Status, NSColor)] = [(.same, NSColor(white: 1, alpha: 0.34)), (.notCompared, Design.mute), (.modified, Design.warning),
                                                   (.added, Design.accent), (.removed, Design.record)]
        for (status, color) in colors {
            ctx.setFillColor(color.cgColor)
            for (key, f) in frames {
                // A folded group's tile has no screen of its own: it is drawn as modified, as the surface does.
                let it = m.index[key].map { m.items[$0] }
                if (it == nil ? .modified : (it!.status ?? .same)) == status { ctx.fill(rect(f)) }
            }
        }
        return ctx.makeImage()
    }
}

/// Plans and models by what made them, shared by every navigator in the process.
private enum MapNavigatorCache {
    private static let lock = NSLock()
    private static var models: [String: MapNavigatorModel] = [:], modelOrder: [String] = []
    private static var plans: [String: MapNavigatorPlan] = [:], planOrder: [String] = []

    static func model(_ key: String) -> MapNavigatorModel? { lock.lock(); defer { lock.unlock() }; return models[key] }
    static func plan(_ key: String) -> MapNavigatorPlan? { lock.lock(); defer { lock.unlock() }; return plans[key] }
    static func store(_ m: MapNavigatorModel) {
        lock.lock(); defer { lock.unlock() }
        if models[m.id] == nil { modelOrder.append(m.id) }
        models[m.id] = m
        while modelOrder.count > 4 { models[modelOrder.removeFirst()] = nil }
    }
    static func store(_ p: MapNavigatorPlan, _ key: String) {
        lock.lock(); defer { lock.unlock() }
        if plans[key] == nil { planOrder.append(key) }
        plans[key] = p
        while planOrder.count > 12 { plans[planOrder.removeFirst()] = nil }
    }
    static func clear() { lock.lock(); models = [:]; modelOrder = []; plans = [:]; planOrder = []; lock.unlock() }
}

// MARK: - The minimap

/// The whole map in a corner: a picture drawn once per layout and a rectangle for what is in view. A click or a drag
/// moves the view there.
final class MapMinimap: NSView {
    static let box = CGSize(width: 190, height: 130)
    var onMove: ((CGPoint) -> Void)?
    private var canvas = CGSize(width: 1, height: 1)
    private let picture = CALayer(), viewport = CALayer()
    private var shown = CGRect.zero

    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Design.controlRadius
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(srgbRed: 0.043, green: 0.047, blue: 0.055, alpha: 0.86).cgColor
        layer?.borderColor = Design.stroke.cgColor
        layer?.borderWidth = 1
        picture.contentsGravity = .resize
        viewport.borderColor = Design.ink.cgColor
        viewport.borderWidth = 1.5
        viewport.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.addSublayer(picture)
        layer?.addSublayer(viewport)
        setAccessibilityLabel("Minimap")
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The picture sits in the middle of the corner, as large as the box allows.
    private var scale: CGFloat { min(Self.box.width / max(canvas.width, 1), Self.box.height / max(canvas.height, 1)) }
    private var origin: CGPoint {
        CGPoint(x: (bounds.width - canvas.width * scale) / 2, y: (bounds.height - canvas.height * scale) / 2)
    }

    func set(_ image: CGImage?, canvas size: CGSize) {
        canvas = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        picture.contentsScale = 2
        picture.frame = CGRect(x: origin.x, y: origin.y, width: canvas.width * scale, height: canvas.height * scale)
        CATransaction.commit()
        show(shown)
    }

    override func layout() {
        super.layout()
        set(picture.contents.map { $0 as! CGImage }, canvas: canvas)
    }

    /// The rectangle of the canvas that is in view.
    func show(_ visible: CGRect) {
        shown = visible
        let k = scale, o = origin
        let r = visible.intersection(CGRect(origin: .zero, size: canvas))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewport.isHidden = r.isNull || r.isEmpty || (r.width >= canvas.width - 1 && r.height >= canvas.height - 1)
        // Canvas y runs down, this view's up.
        viewport.frame = CGRect(x: o.x + r.minX * k, y: o.y + (canvas.height - r.maxY) * k, width: r.width * k, height: r.height * k)
        CATransaction.commit()
    }

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil), o = origin, k = scale
        return CGPoint(x: (p.x - o.x) / k, y: canvas.height - (p.y - o.y) / k)
    }
    override func mouseDown(with event: NSEvent) { onMove?(canvasPoint(event)) }
    override func mouseDragged(with event: NSEvent) { onMove?(canvasPoint(event)) }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - The navigator

final class MapNavigator: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Filter: Int, CaseIterable {
        case all, changed, added, removed, modified, crashes, notCompared

        var name: String {
            switch self {
            case .all: "All"
            case .changed: "Changed"
            case .added: "Added"
            case .removed: "Removed"
            case .modified: "Modified"
            case .crashes: "Crashes"
            case .notCompared: "Not compared"
            }
        }
        /// Whether it needs a comparison to mean anything.
        var needsDiff: Bool { self != .all && self != .crashes }

        func matches(_ it: MapNavigatorModel.Item) -> Bool {
            switch self {
            case .all: true
            case .changed: it.differs
            case .added: it.status == .added
            case .removed: it.status == .removed
            case .modified: it.status == .modified
            case .crashes: it.crashes > 0
            case .notCompared: it.status == .notCompared
            }
        }
    }

    struct Result {
        var key: String
        var title: String
        var group: String
        var activity: String
    }

    let surface: MapSurface
    let scroll: NSScrollView
    /// A screen was selected (nil: none), or opened by a double click or Return.
    var onSelect: ((String?) -> Void)?
    var onOpen: ((String) -> Void)?

    // The map and how it is being looked at.
    private(set) var model: MapNavigatorModel?
    private(set) var plan: MapNavigatorPlan?
    private(set) var filter: Filter = .all
    /// Whether what the comparison leaves unchanged is folded away (only with a comparison, under "All").
    private(set) var folded = true
    private var overrides: [String: Bool] = [:]
    private var generation = 0
    private var pendingReveal: String?
    private var selectedKey: String?
    private(set) var busy = false
    /// How long the last plan took to reach the surface, and whether it came from the cache: for checks.
    private(set) var lastOpen: (seconds: Double, cached: Bool) = (0, false)

    // The controls.
    private let segments = NSSegmentedControl()
    private let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let fitButton = GlassButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Fit the map (F)", target: nil, action: nil)
    private let nextButton = GlassButton(symbol: "chevron.down", label: "Next changed screen (N)", target: nil, action: nil)
    private let previousButton = GlassButton(symbol: "chevron.up", label: "Previous changed screen (P)", target: nil, action: nil)
    private let foldButton = GlassButton(symbol: nil, title: "", label: "Show the screens the comparison left unchanged", style: .well, target: nil, action: nil)
    private let minimap = MapMinimap(frame: NSRect(origin: .zero, size: MapMinimap.box))
    private let resultsScroll = NSScrollView()
    private let table = NSTableView()
    private var results: [Result] = []
    private var matches = 0

    init(pyramid: MapPyramid) {
        (scroll, surface) = MapSurface.scrollView(pyramid: pyramid)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Design.stage.cgColor

        segments.segmentStyle = .rounded
        segments.controlSize = .small
        segments.trackingMode = .selectOne
        segments.segmentCount = Filter.allCases.count
        for f in Filter.allCases { segments.setLabel(f.name, forSegment: f.rawValue) }
        segments.selectedSegment = 0
        segments.target = self
        segments.action = #selector(segmentPicked)
        segments.setAccessibilityLabel("Show")
        field.placeholderString = "Search titles, texts, activities  ⌘F"
        field.controlSize = .small
        field.font = .systemFont(ofSize: 12)
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.widthAnchor.constraint(equalToConstant: 250).isActive = true
        field.setAccessibilityLabel("Search the map")
        count.font = .systemFont(ofSize: 11)
        count.textColor = Design.mute
        count.lineBreakMode = .byTruncatingTail
        count.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        fitButton.onPress = { [weak self] in self?.surface.fitAll() }
        nextButton.onPress = { [weak self] in self?.step(1) }
        previousButton.onPress = { [weak self] in self?.step(-1) }
        foldButton.onPress = { [weak self] in self?.toggleFold() }
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [segments, spacer, previousButton, nextButton, field, count, fitButton])
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        minimap.translatesAutoresizingMaskIntoConstraints = false
        foldButton.translatesAutoresizingMaskIntoConstraints = false
        foldButton.isHidden = true
        minimap.isHidden = true
        minimap.onMove = { [weak self] p in self?.centre(on: p) }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(resultClicked)
        table.setAccessibilityLabel("Search results")
        resultsScroll.documentView = table
        resultsScroll.hasVerticalScroller = true
        resultsScroll.drawsBackground = false
        resultsScroll.wantsLayer = true
        resultsScroll.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.095, blue: 0.11, alpha: 0.97).cgColor
        resultsScroll.layer?.cornerRadius = Design.controlRadius
        resultsScroll.layer?.cornerCurve = .continuous
        resultsScroll.layer?.borderColor = Design.stroke.cgColor
        resultsScroll.layer?.borderWidth = 1
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.isHidden = true

        addSubview(scroll)
        addSubview(bar)
        addSubview(minimap)
        addSubview(foldButton)
        addSubview(resultsScroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor), bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            minimap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), minimap.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            minimap.widthAnchor.constraint(equalToConstant: MapMinimap.box.width), minimap.heightAnchor.constraint(equalToConstant: MapMinimap.box.height),
            foldButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), foldButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            resultsScroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: -2), resultsScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            resultsScroll.widthAnchor.constraint(equalToConstant: 420), resultsScroll.heightAnchor.constraint(equalToConstant: 8 * 38 + 4),
        ])

        surface.onSelect = { [weak self] key in self?.surfaceSelected(key) }
        surface.onOpen = { [weak self] key in self?.onOpen?(key) }
        surface.onGroup = { [weak self] i in
            guard let self, let p = self.plan, i < p.titledGroups.count else { return }
            self.toggleGroup(p.titledGroups[i])
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Opening a map

    /// Shows `head`. With a comparison it opens on the changes and what is one step from them; the screens only the
    /// base has (`base` is needed for them) stand in their base places, marked removed. Layout runs off the main thread,
    /// except when this map has been laid out before: then it is in place when this returns.
    func show(_ head: MapSnapshot, diff: MapDiff? = nil, base: MapSnapshot? = nil) {
        generation += 1
        let gen = generation
        filter = .all
        folded = true
        overrides = [:]
        pendingReveal = nil
        selectedKey = nil
        plan = nil
        clearSearch(refocus: false)
        let key = MapNavigatorModel.key(for: head, diff, base)
        if let cached = MapNavigatorCache.model(key) { adopt(cached, fit: true); return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let m = MapNavigatorModel(head: head, diff: diff, base: base)
            MapNavigatorCache.store(m)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.adopt(m, fit: true)
            }
        }
    }

    private func adopt(_ m: MapNavigatorModel, fit: Bool) {
        model = m
        refreshControls()
        rebuild(previous: nil, fit: fit)
    }

    /// Makes the plan for the present filter, fold and groups and hands it to the surface.
    private func rebuild(previous: MapLayout?, fit: Bool) {
        guard let m = model else { return }
        let gen = generation
        let started = CACurrentMediaTime()
        let cacheKey = [m.id, "\(filter.rawValue)", folded ? "f" : "u", overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","), previous?.hashKey ?? "-"].joined(separator: "#")
        if let hit = MapNavigatorCache.plan(cacheKey) {
            busy = false
            apply(hit, fit: fit, started: started, cached: true)
            return
        }
        busy = true
        let (f, fo, o) = (filter, folded, overrides)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = MapNavigatorPlan.make(m, filter: f, fold: fo, overrides: o, previous: previous)
            MapNavigatorCache.store(p, cacheKey)
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.filter == f, self.folded == fo, self.overrides == o else { return }
                self.busy = false
                self.apply(p, fit: fit, started: started, cached: false)
            }
        }
    }

    private func apply(_ p: MapNavigatorPlan, fit: Bool, started: Double, cached: Bool) {
        plan = p
        let clip = scroll.contentView
        let (m, o) = (scroll.magnification, clip.bounds.origin)
        let keep = selectedKey
        surface.show(p.input)
        if fit && p.shown.count <= 80 {
            // A few screens stacked in a long strip would fit as a thread: show them as cards, from the top.
            scroll.magnification = 1
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: .zero, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            surface.update()
        } else if fit { surface.fitAll() } else {
            scroll.magnification = max(scroll.minMagnification, m)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: o, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
            surface.update()
        }
        minimap.isHidden = p.input.screens.isEmpty
        minimap.set(p.minimap, canvas: p.layout.size)
        viewChanged()
        refreshControls()
        lastOpen = (CACurrentMediaTime() - started, cached)
        if continueReveal() { return }
        if let keep, p.input.screens.contains(where: { $0.lineage == keep }) { surface.select(keep, reveal: false) }
        if !field.stringValue.isEmpty { runSearch() }
    }

    // MARK: Filters and the fold

    func setFilter(_ f: Filter) {
        guard f != filter, model != nil else { return }
        filter = f
        overrides = [:]
        rebuild(previous: nil, fit: true)
    }

    func toggleFold() {
        guard model?.hasDiff == true else { return }
        folded.toggle()
        overrides = [:]
        rebuild(previous: nil, fit: true)
    }

    @objc private func segmentPicked() {
        if let f = Filter(rawValue: segments.selectedSegment) { setFilter(f) }
    }

    private func refreshControls() {
        guard let m = model else { return }
        for f in Filter.allCases {
            segments.setLabel("\(f.name) \(m.counts[f] ?? 0)", forSegment: f.rawValue)
            segments.setEnabled(!f.needsDiff || m.hasDiff, forSegment: f.rawValue)
        }
        segments.selectedSegment = filter.rawValue
        let canFold = m.hasDiff && filter == .all && (m.counts[.changed] ?? 0) > 0
        let n = plan?.folded ?? 0
        foldButton.isHidden = !(canFold && (folded ? n > 0 : true))
        foldButton.title = folded ? "\(n) unchanged  ·  show" : "Changes only"
        foldButton.toolTip = folded ? "Show the screens the comparison left unchanged" : "Fold the unchanged screens away again"
        let any = !(plan?.changedOrder.isEmpty ?? true)
        nextButton.isEnabled = any
        previousButton.isEnabled = any
    }

    // MARK: Groups

    /// Opens a folded group or folds an open one. Every other screen stays where it is.
    func toggleGroup(_ id: String) {
        guard let p = plan, p.groups[id] != nil else { return }
        overrides[id] = !p.collapsed.contains(id)
        rebuild(previous: p.layout, fit: false)
    }

    // MARK: Selection and keys

    private func surfaceSelected(_ key: String?) {
        if let key, key.hasPrefix("g:"), plan?.groups[key] != nil { toggleGroup(key); return }
        selectedKey = key
        onSelect?(key)
    }

    /// Selects `key` and brings it into view: opening its group, lifting the filter and the fold when they hide it.
    func reveal(_ key: String) {
        guard model?.index[key] != nil else { return }
        pendingReveal = key
        _ = continueReveal()
    }

    /// Takes the next step towards the pending reveal; true while a new plan is on its way.
    private func continueReveal() -> Bool {
        guard let key = pendingReveal, let p = plan, model != nil else { return false }
        if !p.shown.contains(key) {
            if filter != .all { filter = .all; overrides = [:] } else if folded { folded = false; overrides = [:] } else { pendingReveal = nil; return false }
            rebuild(previous: nil, fit: true)
            return true
        }
        if let g = p.groupOf[key], p.collapsed.contains(g) {
            overrides[g] = false
            rebuild(previous: p.layout, fit: false)
            return true
        }
        pendingReveal = nil
        selectedKey = key
        surface.select(key, reveal: true)
        return false
    }

    /// The next (1) or previous (-1) changed screen from the selected one, round the map in reading order.
    func step(_ by: Int) {
        guard let order = plan?.changedOrder, !order.isEmpty else { return }
        let at = selectedKey.flatMap { order.firstIndex(of: $0) }
        let next = at.map { (($0 + by) % order.count + order.count) % order.count } ?? (by > 0 ? 0 : order.count - 1)
        reveal(order[next])
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "f", window != nil {
            focusSearch()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// What the surface leaves unhandled arrives here: Escape clears the search, F fits, N and P walk the changes.
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if event.keyCode == 53 {
            if !field.stringValue.isEmpty || !resultsScroll.isHidden { clearSearch(refocus: true) } else if selectedKey != nil { surface.select(nil, reveal: false) }
            return
        }
        guard plain, let c = event.charactersIgnoringModifiers?.lowercased() else { super.keyDown(with: event); return }
        switch c {
        case "f": surface.fitAll()
        case "n": step(1)
        case "p": step(-1)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Search

    func focusSearch() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// Looks for every word of `text` in the screens' titles, texts and activity names.
    func search(_ text: String) {
        field.stringValue = text
        runSearch()
    }

    private func runSearch() {
        guard let m = model else { return }
        let words = MapNavigatorModel.fold(field.stringValue).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { results = []; matches = 0; table.reloadData(); resultsScroll.isHidden = true; count.stringValue = ""; return }
        var hits = m.items.filter { it in words.allSatisfy { it.words.contains($0) } }
        let q = words.joined(separator: " ")
        hits.sort { a, b in
            let ta = MapNavigatorModel.fold(a.screen.title).contains(q), tb = MapNavigatorModel.fold(b.screen.title).contains(q)
            return ta != tb ? ta : (a.screen.title, a.key) < (b.screen.title, b.key)
        }
        matches = hits.count
        results = hits.prefix(300).map { Result(key: $0.key, title: $0.screen.title, group: $0.section, activity: $0.screen.activity) }
        count.stringValue = matches == 0 ? "No screen" : "\(matches) screen\(matches == 1 ? "" : "s")"
        resultsScroll.isHidden = results.isEmpty
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func clearSearch(refocus: Bool) {
        field.stringValue = ""
        results = []
        matches = 0
        table.reloadData()
        resultsScroll.isHidden = true
        count.stringValue = ""
        if refocus { window?.makeFirstResponder(surface) }
    }

    private func revealResult(_ row: Int) {
        guard results.indices.contains(row) else { return }
        let key = results[row].key
        resultsScroll.isHidden = true
        window?.makeFirstResponder(surface)
        reveal(key)
    }

    @objc private func resultClicked() { revealResult(table.clickedRow) }

    func controlTextDidChange(_ obj: Notification) { runSearch() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): revealResult(max(table.selectedRow, 0)); return true
        case #selector(NSResponder.cancelOperation(_:)): clearSearch(refocus: true); return true
        case #selector(NSResponder.moveDown(_:)): table.selectRowIndexes([min(table.selectedRow + 1, results.count - 1)], byExtendingSelection: false); table.scrollRowToVisible(table.selectedRow); return true
        case #selector(NSResponder.moveUp(_:)): table.selectRowIndexes([max(table.selectedRow - 1, 0)], byExtendingSelection: false); table.scrollRowToVisible(table.selectedRow); return true
        default: return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("resultCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = id
            t.lineBreakMode = .byTruncatingTail
            t.maximumNumberOfLines = 2
            return t
        }()
        let r = results[row]
        let text = NSMutableAttributedString(string: r.title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Design.ink])
        text.append(NSAttributedString(string: "\n\(r.group)  ·  \(r.activity)", attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: Design.mute]))
        cell.attributedStringValue = text
        return cell
    }

    // MARK: The minimap

    @objc private func viewChanged() {
        minimap.show(surface.convert(scroll.contentView.bounds, from: scroll.contentView))
    }

    /// Moves the view so `point` of the canvas is in the middle of it.
    private func centre(on point: CGPoint) {
        let clip = scroll.contentView
        let size = clip.bounds.size
        let o = clip.constrainBoundsRect(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)).origin
        clip.scroll(to: o)
        scroll.reflectScrolledClipView(clip)
        surface.update()
    }

    // MARK: For checks

    /// The segment titles, in order.
    var segmentTitles: [String] { Filter.allCases.map { segments.label(forSegment: $0.rawValue) ?? "" } }
    var foldTitle: String { foldButton.isHidden ? "" : foldButton.title }
    var searchMatches: Int { matches }
    var searchResultKeys: [String] { results.map(\.key) }
    var minimapView: MapMinimap { minimap }
    var minimapIsVisible: Bool { !minimap.isHidden }
    func clearCaches() { MapNavigatorCache.clear() }
}

private extension MapLayout {
    /// Names a layout for the plan cache: cheap, and the same for the same frames.
    var hashKey: String {
        var h = Hasher()
        h.combine(size.width); h.combine(size.height); h.combine(groups.count); h.combine(frames.count)
        for g in groups { h.combine(g.id); h.combine(g.collapsed); h.combine(g.startRow); h.combine(g.rows) }
        return "\(h.finalize())"
    }
}
