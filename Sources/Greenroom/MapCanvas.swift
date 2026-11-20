import AppKit

/// The screen map itself: one column per depth, a card per screen (its capture, title and activity), and a curve
/// for each pair of screens a control joins. Selecting a card lights its routes out (accent, with the controls'
/// names) and in, and dims the rest. While a walk runs, the levels it has reached stand as breathing ghost cards,
/// which the real cards replace when it ends. Everything is layers: nothing is redrawn as it animates.
final class MapCanvas: NSView {
    var onSelect: ((String?) -> Void)?
    var onOpen: ((String) -> Void)?
    private(set) var selected: String?
    private(set) var map: ScreenMapData?
    /// The capture each card shows (an index into the run's combinations).
    var comboIndex = 0 { didSet { if oldValue != comboIndex { loadThumbnails() } } }

    private struct Card {
        let id: String
        let frame: CGRect
        let root: CALayer
        let image: CALayer
        let ring: CALayer
    }
    private struct Route {
        let from: String, to: String
        let labels: [String]
        let line: CAShapeLayer
        let tip: CAShapeLayer
        let mid: CGPoint
        var pill: CALayer?
    }
    private var cards: [String: Card] = [:]
    private var routes: [Route] = []
    private var ghosts: [CALayer] = []
    private var ghostLevels: [Int: Int] = [:]
    private var columnCount = 1
    private var hovered: String?
    private var panStart: (NSPoint, NSPoint)?
    private let content = CALayer()

    // Geometry.
    static let thumbWidth: CGFloat = 96
    private var thumbHeight: CGFloat = 208
    private var cardHeight: CGFloat { thumbHeight + 40 }
    private let gapX: CGFloat = 150, gapY: CGFloat = 34, pad: CGFloat = 70

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(content)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private var animating: Bool { !Design.reduceMotion }

    // MARK: Ghosts while walking

    /// The levels a walk has reached: `exploring` screens at `depth`. Ghost cards stand in for them.
    func walkReached(depth: Int, exploring: Int) {
        guard map == nil else { return }
        ghostLevels[depth] = exploring
        let columns = (ghostLevels.keys.max() ?? 0) + 1
        columnCount = columns
        let tallest = ghostLevels.values.max() ?? 1
        let size = CGSize(width: pad * 2 + CGFloat(columns) * Self.thumbWidth + CGFloat(columns - 1) * gapX,
                          height: pad * 2 + CGFloat(tallest) * cardHeight + CGFloat(tallest - 1) * gapY)
        setFrameSize(NSSize(width: max(size.width, superview?.bounds.width ?? 0), height: max(size.height, superview?.bounds.height ?? 0)))
        var have = Set(ghosts.compactMap { $0.name })
        for (d, n) in ghostLevels.sorted(by: { $0.key < $1.key }) {
            for i in 0..<n {
                let key = "\(d)-\(i)"
                let f = cardFrame(depth: d, row: i, rows: n, height: bounds.height)
                if let g = ghosts.first(where: { $0.name == key }) {
                    g.frame = CGRect(x: f.minX, y: f.minY, width: f.width, height: thumbHeight)
                    continue
                }
                have.insert(key)
                let g = CALayer()
                g.name = key
                g.frame = CGRect(x: f.minX, y: f.minY, width: f.width, height: thumbHeight)
                g.cornerRadius = 12
                g.cornerCurve = .continuous
                g.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
                g.borderWidth = 1
                g.borderColor = Design.stroke.cgColor
                content.addSublayer(g)
                ghosts.append(g)
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

    /// Empties the canvas for a new walk.
    func clear() {
        map = nil
        selected = nil
        ghostLevels = [:]
        ghosts = []
        cards = [:]
        routes = []
        content.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    // MARK: The map

    func show(_ map: ScreenMapData, animated: Bool) {
        let leaving = ghosts
        clear()
        self.map = map
        // Ghosts fade as the cards land on them.
        for g in leaving {
            content.addSublayer(g)
            CATransaction.begin()
            CATransaction.setAnimationDuration(Design.arrive)
            CATransaction.setCompletionBlock { g.removeFromSuperlayer() }
            g.opacity = 0
            CATransaction.commit()
        }
        if let first = map.screens.first?.captures.first?.file, let src = CGImageSourceCreateWithURL(first as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? CGFloat, let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0 {
            thumbHeight = (Self.thumbWidth * h / w).rounded()
        } else { thumbHeight = 208 }

        // Columns by depth; within one, children follow their parent's order so the curves cross least.
        var columns: [Int: [MapScreen]] = [:]
        var rowOf: [String: Int] = [:]
        for d in Set(map.screens.map(\.depth)).sorted() {
            let here = map.screens.filter { $0.depth == d }
            let order = here.enumerated().sorted { a, b in
                let pa = a.element.parent.flatMap { rowOf[$0] } ?? -1, pb = b.element.parent.flatMap { rowOf[$0] } ?? -1
                return pa != pb ? pa < pb : a.offset < b.offset
            }.map(\.element)
            for (i, s) in order.enumerated() { rowOf[s.id] = i }
            columns[d] = order
        }
        let deepest = columns.keys.max() ?? 0
        let tallest = columns.values.map(\.count).max() ?? 1
        let size = NSSize(width: pad * 2 + CGFloat(deepest + 1) * Self.thumbWidth + CGFloat(deepest) * gapX,
                          height: pad * 2 + CGFloat(tallest) * cardHeight + CGFloat(tallest - 1) * gapY)
        let view = superview?.bounds.size ?? size
        setFrameSize(NSSize(width: max(size.width, view.width), height: max(size.height, view.height)))
        columnCount = deepest + 1

        let selfLoops = Dictionary(grouping: map.edges.filter { $0.to == .screen($0.from) }, by: \.from)
        let crashes = Dictionary(grouping: map.edges.filter { $0.to == .crash }, by: \.from)
        let exits = Dictionary(grouping: map.edges.filter { $0.to == .exit }, by: \.from)
        for (d, list) in columns {
            for (i, s) in list.enumerated() {
                let f = cardFrame(depth: d, row: i, rows: list.count, height: bounds.height)
                var badges: [(String, NSColor)] = []
                if let c = crashes[s.id]?.count { badges.append(("\(c) crash" + (c == 1 ? "" : "es"), Design.record)) }
                if let e = exits[s.id]?.count { badges.append(("\(e) exit" + (e == 1 ? "" : "s"), Design.warning)) }
                if let l = selfLoops[s.id]?.count { badges.append(("↻ \(l)", Design.mute)) }
                cards[s.id] = makeCard(s, frame: f, badges: badges)
            }
        }
        // One curve per pair of screens, carrying every control that makes it.
        var pairs: [String: (String, String, [String])] = [:]
        var pairOrder: [String] = []
        for e in map.edges {
            guard case .screen(let to) = e.to, to != e.from, cards[to] != nil, cards[e.from] != nil else { continue }
            let key = e.from + ">" + to
            if pairs[key] == nil { pairs[key] = (e.from, to, []); pairOrder.append(key) }
            pairs[key]?.2.append(e.action.isEmpty ? e.cmd : e.action)
        }
        for key in pairOrder {
            guard let (from, to, labels) = pairs[key], let a = cards[from], let b = cards[to] else { continue }
            routes.append(makeRoute(from: a, to: b, labels: labels))
        }
        for c in cards.values { content.addSublayer(c.root) }   // cards over the curves
        loadThumbnails()
        if animated && animating { playEntrance(columns) }
        restyle()
    }

    private func cardFrame(depth: Int, row: Int, rows: Int, height: CGFloat) -> CGRect {
        let columnHeight = CGFloat(rows) * cardHeight + CGFloat(rows - 1) * gapY
        let top = max(pad, (height - columnHeight) / 2)
        // The columns centred across the canvas when it is wider than they are.
        let n = CGFloat(max(columnCount, 1))
        let left = max(pad, (bounds.width - (n * Self.thumbWidth + (n - 1) * gapX)) / 2)
        return CGRect(x: left + CGFloat(depth) * (Self.thumbWidth + gapX), y: top + CGFloat(row) * (cardHeight + gapY),
                      width: Self.thumbWidth, height: cardHeight)
    }

    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, width: CGFloat) -> CATextLayer {
        let t = CATextLayer()
        t.string = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        t.truncationMode = .end
        t.alignmentMode = .center
        t.contentsScale = window?.backingScaleFactor ?? 2
        t.frame = CGRect(x: 0, y: 0, width: width, height: size + 5)
        return t
    }

    private func makeCard(_ s: MapScreen, frame f: CGRect, badges: [(String, NSColor)]) -> Card {
        let root = CALayer()
        root.frame = f
        root.name = s.id
        let image = CALayer()
        image.frame = CGRect(x: 0, y: 0, width: f.width, height: thumbHeight)
        image.cornerRadius = 12
        image.cornerCurve = .continuous
        image.masksToBounds = true
        image.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        image.contentsGravity = .resizeAspectFill
        image.borderWidth = 1
        image.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        let shadow = CALayer()
        shadow.frame = image.frame
        shadow.cornerRadius = 12
        shadow.backgroundColor = Design.stage.cgColor
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.55
        shadow.shadowRadius = 14
        shadow.shadowOffset = CGSize(width: 0, height: 6)
        shadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: image.frame.size), cornerWidth: 12, cornerHeight: 12, transform: nil)
        if s.captures.isEmpty {
            let name = text(s.activity, size: 10, weight: .medium, color: Design.mute, width: f.width - 10)
            name.frame.origin = CGPoint(x: 5, y: thumbHeight / 2 - 7)
            image.addSublayer(name)
        }
        let ring = CALayer()
        ring.frame = image.frame.insetBy(dx: -4, dy: -4)
        ring.cornerRadius = 16
        ring.cornerCurve = .continuous
        ring.borderWidth = 2
        ring.borderColor = Design.accent.cgColor
        ring.opacity = 0
        ring.shadowColor = Design.accent.cgColor
        ring.shadowRadius = 10
        ring.shadowOpacity = 0.6
        ring.shadowOffset = .zero
        let title = text(s.label, size: 11.5, weight: .semibold, color: Design.ink, width: f.width + 40)
        title.frame.origin = CGPoint(x: -20, y: thumbHeight + 7)
        let sub = text(s.activity, size: 10, weight: .regular, color: Design.mute, width: f.width + 40)
        sub.frame.origin = CGPoint(x: -20, y: thumbHeight + 23)
        for l in [shadow, ring, image, title, sub] { root.addSublayer(l) }
        // Badges over the capture's top right corner.
        var y: CGFloat = -8
        for (label, color) in badges {
            let t = text(label, size: 10, weight: .semibold, color: color == Design.mute ? Design.ink : color, width: 80)
            let w = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold)]).width + 14
            let pill = CALayer()
            pill.frame = CGRect(x: f.width - w + 8, y: y, width: w, height: 18)
            pill.cornerRadius = 9
            pill.backgroundColor = (color == Design.mute ? NSColor(white: 0.22, alpha: 0.95) : color.withAlphaComponent(0.22).blended(withFraction: 0.6, of: Design.stage) ?? color).cgColor
            pill.borderWidth = 1
            pill.borderColor = color.withAlphaComponent(0.6).cgColor
            t.frame = CGRect(x: 0, y: 2, width: w, height: 15)
            pill.addSublayer(t)
            root.addSublayer(pill)
            y += 22
        }
        return Card(id: s.id, frame: f, root: root, image: image, ring: ring)
    }

    private func makeRoute(from a: Card, to b: Card, labels: [String]) -> Route {
        let path = CGMutablePath()
        let p0: CGPoint, p1: CGPoint, c0: CGPoint, c1: CGPoint
        let midY = { (c: Card) in c.frame.minY + self.thumbHeight / 2 }
        if b.frame.minX > a.frame.maxX {
            p0 = CGPoint(x: a.frame.maxX + 4, y: midY(a))
            p1 = CGPoint(x: b.frame.minX - 8, y: midY(b))
            let dx = (p1.x - p0.x) * 0.5
            c0 = CGPoint(x: p0.x + dx, y: p0.y)
            c1 = CGPoint(x: p1.x - dx, y: p1.y)
        } else if b.frame.maxX < a.frame.minX {
            // Back to an earlier column: out of the left side, into the right, a little above the forward routes.
            p0 = CGPoint(x: a.frame.minX - 4, y: a.frame.minY + thumbHeight * 0.32)
            p1 = CGPoint(x: b.frame.maxX + 8, y: b.frame.minY + thumbHeight * 0.32)
            let dx = (p0.x - p1.x) * 0.5
            c0 = CGPoint(x: p0.x - dx, y: p0.y)
            c1 = CGPoint(x: p1.x + dx, y: p1.y)
        } else {
            // The same column: a bow out to the right, wider the further apart the two are.
            let down = b.frame.minY > a.frame.minY
            p0 = CGPoint(x: a.frame.maxX + 4, y: a.frame.minY + thumbHeight * (down ? 0.68 : 0.32))
            p1 = CGPoint(x: b.frame.maxX + 8, y: b.frame.minY + thumbHeight * (down ? 0.32 : 0.68))
            let bow = 34 + abs(p1.y - p0.y) * 0.16
            c0 = CGPoint(x: p0.x + bow, y: p0.y)
            c1 = CGPoint(x: p1.x + bow, y: p1.y)
        }
        path.move(to: p0)
        path.addCurve(to: p1, control1: c0, control2: c1)
        let line = CAShapeLayer()
        line.path = path
        line.fillColor = nil
        line.lineWidth = 1.6
        line.lineCap = .round
        // The arrow tip, along the curve's last tangent.
        let angle = atan2(p1.y - c1.y, p1.x - c1.x)
        let tipPath = CGMutablePath()
        tipPath.move(to: CGPoint(x: p1.x + cos(angle) * 4, y: p1.y + sin(angle) * 4))
        tipPath.addLine(to: CGPoint(x: p1.x + cos(angle + 2.5) * 7, y: p1.y + sin(angle + 2.5) * 7))
        tipPath.addLine(to: CGPoint(x: p1.x + cos(angle - 2.5) * 7, y: p1.y + sin(angle - 2.5) * 7))
        tipPath.closeSubpath()
        let tip = CAShapeLayer()
        tip.path = tipPath
        content.addSublayer(line)
        content.addSublayer(tip)
        func bez(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            let u = 1 - t
            return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
        }
        let mid = CGPoint(x: bez(0.5, p0.x, c0.x, c1.x, p1.x), y: bez(0.5, p0.y, c0.y, c1.y, p1.y))
        return Route(from: a.id, to: b.id, labels: labels, line: line, tip: tip, mid: mid)
    }

    private func loadThumbnails() {
        guard let map else { return }
        for s in map.screens {
            guard let card = cards[s.id], !s.captures.isEmpty else { continue }
            let file = s.captures[min(comboIndex, s.captures.count - 1)].file
            SnapshotImages.load(file, maxPixel: 420) { [weak self] img in
                guard self?.cards[s.id]?.image === card.image else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(Design.snap)
                card.image.contents = img
                CATransaction.commit()
            }
        }
    }

    /// Cards land column by column, each curve drawing itself out of its card once that card is down.
    private func playEntrance(_ columns: [Int: [MapScreen]]) {
        let now = CACurrentMediaTime()
        var landed: [String: Double] = [:]
        for (d, list) in columns {
            for (i, s) in list.enumerated() {
                guard let c = cards[s.id] else { continue }
                let at = (Double(d) * 0.16 + Double(i) * 0.04) * Design.slow
                landed[s.id] = at
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0; fade.toValue = 1
                let rise = CASpringAnimation(keyPath: "transform")
                rise.fromValue = CATransform3DConcat(CATransform3DMakeScale(0.92, 0.92, 1), CATransform3DMakeTranslation(-14, 10, 0))
                rise.toValue = CATransform3DIdentity
                rise.damping = 16; rise.stiffness = 210; rise.mass = 1
                let group = CAAnimationGroup()
                group.animations = [fade, rise]
                group.duration = max(rise.settlingDuration, Design.arrive) * Design.slow
                fade.duration = Design.arrive
                group.beginTime = now + at
                group.fillMode = .backwards
                c.root.add(group, forKey: "land")
            }
        }
        for r in routes {
            let at = (landed[r.from] ?? 0) + 0.12 * Design.slow
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0; draw.toValue = 1
            draw.duration = Design.move
            draw.timingFunction = Design.moveTiming()
            draw.beginTime = now + at
            draw.fillMode = .backwards
            r.line.add(draw, forKey: "draw")
            let pop = CABasicAnimation(keyPath: "opacity")
            pop.fromValue = 0; pop.toValue = r.tip.opacity
            pop.duration = Design.snap
            pop.beginTime = now + at + Design.move * 0.8
            pop.fillMode = .backwards
            r.tip.add(pop, forKey: "pop")
        }
    }

    // MARK: Selection and hover

    func select(_ id: String?, reveal: Bool = true) {
        selected = id
        restyle()
        if reveal, let id, let c = cards[id] { scrollIntoView(c.frame.insetBy(dx: -gapX * 0.6, dy: -40)) }
        onSelect?(id)
    }

    private func restyle() {
        let focus = selected ?? hovered
        CATransaction.begin()
        CATransaction.setAnimationDuration(Design.snap)
        for c in cards.values {
            let on = c.id == selected
            c.ring.opacity = on ? 1 : 0
            let related = focus == nil || c.id == focus || routes.contains { ($0.from == focus && $0.to == c.id) || ($0.to == focus && $0.from == c.id) }
            c.root.opacity = related ? 1 : 0.38
            c.root.transform = c.id == hovered && !on ? CATransform3DMakeScale(1.035, 1.035, 1) : CATransform3DIdentity
        }
        for i in routes.indices {
            let r = routes[i]
            let out = focus != nil && r.from == focus, into = focus != nil && r.to == focus
            let color: NSColor = out ? Design.accent : (into ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 1, alpha: focus == nil ? 0.22 : 0.07))
            r.line.strokeColor = color.cgColor
            r.line.lineWidth = out ? 2.2 : 1.6
            r.tip.fillColor = color.cgColor
            r.line.zPosition = out ? 2 : (into ? 1 : 0)
            r.tip.zPosition = r.line.zPosition
            // The controls' names on the routes out of the selected card.
            let wantPill = out && r.from == selected
            if wantPill, r.pill == nil {
                let label = r.labels.count > 1 ? "\(r.labels[0])  +\(r.labels.count - 1)" : (r.labels.first ?? "")
                routes[i].pill = makePill(label, at: r.mid)
                content.addSublayer(routes[i].pill!)
            } else if !wantPill, let p = r.pill {
                p.removeFromSuperlayer()
                routes[i].pill = nil
            }
        }
        CATransaction.commit()
    }

    private func makePill(_ s: String, at p: CGPoint) -> CALayer {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let shown = s.count > 26 ? String(s.prefix(25)) + "…" : s
        let w = (shown as NSString).size(withAttributes: [.font: font]).width + 16
        let pill = CALayer()
        pill.frame = CGRect(x: p.x - w / 2, y: p.y - 10, width: w, height: 20)
        pill.cornerRadius = 10
        pill.backgroundColor = Design.accent.cgColor
        pill.zPosition = 5
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOpacity = 0.4
        pill.shadowRadius = 6
        pill.shadowOffset = CGSize(width: 0, height: 2)
        let t = CATextLayer()
        t.string = NSAttributedString(string: shown, attributes: [.font: font, .foregroundColor: Design.onAccent])
        t.alignmentMode = .center
        t.contentsScale = window?.backingScaleFactor ?? 2
        t.frame = CGRect(x: 0, y: 3, width: w, height: 15)
        pill.addSublayer(t)
        if animating {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.6; pop.toValue = 1
            pop.damping = 14; pop.stiffness = 260
            pop.duration = pop.settlingDuration
            pill.add(pop, forKey: "pop")
        }
        return pill
    }

    private func card(at p: NSPoint) -> String? {
        cards.values.first { $0.frame.insetBy(dx: -6, dy: -6).contains(p) }?.id
    }

    override func mouseMoved(with event: NSEvent) {
        let id = card(at: convert(event.locationInWindow, from: nil))
        guard id != hovered else { return }
        hovered = id
        if id != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        restyle()
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; NSCursor.arrow.set(); restyle() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let id = card(at: p) {
            if event.clickCount == 2 { onOpen?(id) } else { select(id, reveal: false) }
            return
        }
        panStart = (event.locationInWindow, enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let (start, origin) = panStart, let clip = enclosingScrollView?.contentView else { return }
        NSCursor.closedHand.set()
        let m = enclosingScrollView?.magnification ?? 1
        let dx = (event.locationInWindow.x - start.x) / m, dy = (event.locationInWindow.y - start.y) / m
        clip.scroll(to: NSPoint(x: origin.x - dx, y: origin.y + dy))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if panStart != nil, event.locationInWindow == panStart?.0 { select(nil, reveal: false) }
        panStart = nil
        NSCursor.arrow.set()
    }

    /// Arrow keys walk the map: right follows the first route out, left goes to the parent, up and down move in a column.
    override func keyDown(with event: NSEvent) {
        guard let map, let id = selected ?? map.screens.first?.id, let here = map.screen(id) else { super.keyDown(with: event); return }
        let column = map.screens.filter { $0.depth == here.depth }.sorted { (cards[$0.id]?.frame.minY ?? 0) < (cards[$1.id]?.frame.minY ?? 0) }
        let i = column.firstIndex { $0.id == id } ?? 0
        switch event.keyCode {
        case 124: select(routes.first { $0.from == id && (map.screen($0.to)?.depth ?? 0) > here.depth }?.to ?? id)
        case 123: select(here.parent ?? id)
        case 125: select(column[min(i + 1, column.count - 1)].id)
        case 126: select(column[max(i - 1, 0)].id)
        case 36, 76: onOpen?(id)
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
        o.x = max(0, min(o.x, bounds.width - visible.width))
        o.y = max(0, min(o.y, bounds.height - visible.height))
        Design.animate(Design.move, { clip.animator().setBoundsOrigin(o) }, done: { scroll.reflectScrolledClipView(clip) })
    }

    /// Where a screen's card is, in the canvas: for checks.
    func frame(of id: String) -> CGRect? { cards[id]?.frame }
    var routeCount: Int { routes.count }
}
