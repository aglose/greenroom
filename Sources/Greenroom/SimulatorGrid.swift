import AppKit

/// The stage's simulators. Left alone they are tiled so each picture is as large as the space allows. Side by side a
/// person can also arrange them: drag a device by its body or caption to move it (it snaps to the stage's edges and
/// to the other devices), drag the grip at its bottom right to resize it (it keeps its shape, never gets smaller than
/// `SimulatorView.minimumLongSide` nor larger than the stage), and close it with the button at its top left. Once one
/// is moved or resized, every device stays where it is until Tidy Up tiles them again.
final class SimulatorGrid: NSView {
    private(set) var views: [SimulatorView] = []
    private let placeholder = SimulatorView(frame: .zero)
    /// How much memory the simulators take, in the top left corner, once that is a lot.
    let memoryLabel = MemoryLabel()
    /// Closes a simulator (its close button or menu).
    var onClose: ((Simulator) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(placeholder)
        addSubview(memoryLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    /// The next layout moves the devices to their places rather than jumping (set when devices come or go).
    private var animateNext = false
    private var lastSideBySide = false
    private var arriving: [SimulatorView] = []

    /// Where a person put a device: its top left and its picture's long side, in this view's points. Kept to the
    /// stage when laid out rather than when stored, so a device a smaller window pushed in goes back when it grows.
    private struct Placement { var origin: CGPoint; var longSide: CGFloat }
    private var placements: [ObjectIdentifier: Placement] = [:]
    /// Devices brought forward by arranging them, frontmost last.
    private var stacking: [ObjectIdentifier] = []
    private var arrangeable = false
    private var gesture: (view: SimulatorView, start: CGPoint, from: Placement, resizing: Bool)?
    /// Whether the devices were put where they are by hand (Tidy Up undoes it).
    var isArranged: Bool { !placements.isEmpty }

    func view(for sim: Simulator) -> SimulatorView? { views.first { $0.simulator === sim } }

    /// Shows these simulators, keeping the views of those already shown (so their pictures do not blink).
    func show(_ sims: [Simulator], chosen: Simulator?, sideBySide: Bool, hint: String, configure: (SimulatorView) -> Void) {
        var next: [SimulatorView] = []
        for sim in sims {
            if let v = view(for: sim) {
                next.append(v)
            } else {
                let v = SimulatorView(frame: .zero)
                configure(v)
                addSubview(v, positioned: .below, relativeTo: memoryLabel)
                v.show(sim)
                next.append(v)
            }
        }
        for v in views where !next.contains(where: { $0 === v }) {
            // A device leaving fades and sinks a little; the others close the gap as it goes.
            v.show(nil)
            v.arrangeable = false
            if Design.reduceMotion || window == nil { v.removeFromSuperview(); continue }
            Design.animate(Design.arrive, {
                v.animator().alphaValue = 0
                v.animator().setFrameOrigin(NSPoint(x: v.frame.minX, y: v.frame.minY + 18))
            }, done: { v.removeFromSuperview(); v.alphaValue = 1 })
        }
        let arriving = next.filter { v in !views.contains { $0 === v } }
        let leaving = views.filter { v in !next.contains { $0 === v } }
        views = next
        if !arriving.isEmpty || !leaving.isEmpty || lastSideBySide != sideBySide { animateNext = true }
        lastSideBySide = sideBySide
        self.arriving = arriving
        // Forget the places of simulators that are gone.
        let known = Set(Engine.shared.simulators.map(ObjectIdentifier.init))
        placements = placements.filter { known.contains($0.key) }
        stacking.removeAll { !known.contains($0) }
        arrangeable = sideBySide && views.count > 1
        restoreSaved()
        if let g = gesture, !arrangeable || !views.contains(where: { $0 === g.view }) { gesture = nil }
        for v in views {
            v.showsCaption = sideBySide && views.count > 1
            v.isChosen = v.simulator === chosen
            v.arranger = self
            v.arrangeable = arrangeable
        }
        placeholder.isHidden = !views.isEmpty
        if views.isEmpty { placeholder.show(nil, placeholder: hint) }
        applyStacking()
        needsLayout = true
    }

    /// Tiles the devices again, forgetting where they were put.
    func tidy() {
        guard isArranged else { return }
        placements = [:]
        stacking = []
        gesture = nil
        save()
        animateNext = true
        applyStacking()
        needsLayout = true
    }

    func close(_ sim: Simulator) { onClose?(sim) }

    /// Brings a device in front of the others (a click on it while they are arranged).
    func raise(_ v: SimulatorView) {
        guard isArranged, let id = v.simulator.map(ObjectIdentifier.init), stacking.last != id else { return }
        stacking.removeAll { $0 == id }
        stacking.append(id)
        applyStacking()
        refreshHover()
    }

    /// Marks the one device under the pointer, the frontmost where they overlap, so only its close button and grip
    /// show. Asked again after every layout, since a device moving out from under a still pointer gets no exit event.
    func refreshHover() {
        guard let window, let content = window.contentView else { return }
        let hit = arrangeable ? content.hitTest(content.convert(window.mouseLocationOutsideOfEventStream, from: nil)) : nil
        for v in views { v.hovering = hit.map { $0 === v || $0.isDescendant(of: v) } ?? false }
    }

    override func layout() {
        super.layout()
        placeholder.frame = bounds
        memoryLabel.sizeToFit()
        memoryLabel.frame.origin = CGPoint(x: 16, y: 0)
        guard !views.isEmpty else { return }
        let target = arrangeable && isArranged ? arrangedFrames() : tiledFrames()
        let animate = animateNext && window != nil && !Design.reduceMotion && gesture == nil
        animateNext = false
        let fresh = arriving
        arriving = []
        defer { if arrangeable { DispatchQueue.main.async { [weak self] in self?.refreshHover() } } }
        guard animate else { for (v, frame) in zip(views, target) { v.frame = frame }; return }
        for v in fresh {
            // A new device rises into its place from just below, fading in.
            if let i = views.firstIndex(where: { $0 === v }) { v.frame = target[i].offsetBy(dx: 0, dy: 24) }
            v.alphaValue = 0
        }
        Design.animate(Design.move, {
            for (v, frame) in zip(views, target) {
                v.animateLayout = true
                v.animator().frame = frame
                if fresh.contains(where: { $0 === v }) { v.animator().alphaValue = 1 }
            }
        }, done: { [weak self] in self?.views.forEach { $0.animateLayout = false } })
    }

    // MARK: Tiling

    private func tiledFrames() -> [CGRect] {
        // Rows of up to `cols` views. Within a row a view's width is in proportion to the square root of its
        // device's aspect ratio, which gives a phone and a tablet side by side pictures of about the same area.
        // Try every `cols` and keep the one whose smallest picture is largest.
        let aspects = views.map { v -> CGFloat in
            let s = v.simulator?.deviceSize ?? .zero
            return s.width > 0 ? s.width / s.height : 0.46
        }
        func frames(cols: Int) -> [CGRect] {
            let rows = Int(ceil(Double(views.count) / Double(cols)))
            let ch = bounds.height / CGFloat(rows)
            var out: [CGRect] = []
            for row in 0..<rows {
                let items = Array(aspects[(row * cols)..<min((row + 1) * cols, aspects.count)])
                let total = items.reduce(0) { $0 + $1.squareRoot() }
                var x: CGFloat = 0
                for a in items {
                    let w = bounds.width * a.squareRoot() / total
                    out.append(CGRect(x: x, y: CGFloat(row) * ch, width: w, height: ch))
                    x += w
                }
            }
            return out
        }
        func smallestPicture(_ cells: [CGRect]) -> CGFloat {
            zip(cells, aspects).map { cell, a in
                let w = min(cell.width, cell.height * a)
                return w * w / a
            }.min() ?? 0
        }
        var best = frames(cols: 1)
        for cols in 2...max(views.count, 2) where cols <= views.count {
            let candidate = frames(cols: cols)
            if smallestPicture(candidate) > smallestPicture(best) { best = candidate }
        }
        return best
    }

    // MARK: Arranging

    private func arrangedFrames() -> [CGRect] {
        // Devices that arrived since the arranging began are given a free spot at the others' usual size.
        var taken = views.compactMap { v in v.simulator.flatMap { placements[ObjectIdentifier($0)] }.map { frame(v, $0) } }
        var out: [CGRect] = []
        for v in views {
            guard let sim = v.simulator else { out.append(.zero); continue }
            let id = ObjectIdentifier(sim)
            if placements[id] == nil {
                let p = freePlacement(for: v, avoiding: taken)
                placements[id] = p
                taken.append(frame(v, p))
            }
            out.append(frame(v, placements[id]!))
        }
        return out
    }

    /// A placement's frame now: its size from the picture's long side (kept between the smallest allowed and what
    /// the stage holds), moved in from the stage's edges.
    private func frame(_ v: SimulatorView, _ p: Placement) -> CGRect {
        let size = v.cell(longSide: clampedLongSide(v, p.longSide, within: bounds.size)).size
        return CGRect(origin: clampedOrigin(p.origin, size: size), size: size)
    }

    private func clampedOrigin(_ o: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(o.x, 0), max(bounds.width - size.width, 0)).rounded(),
                y: min(max(o.y, 0), max(bounds.height - size.height, 0)).rounded())
    }

    /// The long side kept to what is allowed: at least the device's minimum, and at most what fits in `space`.
    private func clampedLongSide(_ v: SimulatorView, _ longSide: CGFloat, within space: CGSize) -> CGFloat {
        let low = v.minimumLongSide
        func fits(_ l: CGFloat) -> Bool { let s = v.cell(longSide: l).size; return s.width <= space.width && s.height <= space.height }
        if longSide <= low || fits(longSide) { return max(longSide, low) }
        // Larger than the space: the largest that fits, found by halving (the cell grows with the long side).
        var lo = low, hi = longSide
        for _ in 0..<16 { let mid = (lo + hi) / 2; if fits(mid) { lo = mid } else { hi = mid } }
        return lo.rounded(.down)
    }

    /// A spot for a device that has none: the first free one, scanning rows from the top left, at the size the
    /// arranged devices have on average; else a step down and right from the last device.
    private func freePlacement(for v: SimulatorView, avoiding taken: [CGRect]) -> Placement {
        let sizes = placements.values.map(\.longSide)
        let longSide = sizes.isEmpty ? max(v.pictureLongSide, v.minimumLongSide) : sizes.reduce(0, +) / CGFloat(sizes.count)
        let size = v.cell(longSide: clampedLongSide(v, longSide, within: bounds.size)).size
        let step: CGFloat = 16
        var y: CGFloat = 0
        while y + size.height <= bounds.height {
            var x: CGFloat = 0
            while x + size.width <= bounds.width {
                let r = CGRect(x: x, y: y, width: size.width, height: size.height)
                if !taken.contains(where: { $0.insetBy(dx: 8, dy: 8).intersects(r) }) { return Placement(origin: r.origin, longSide: longSide) }
                x += step
            }
            y += step
        }
        let last = taken.last ?? .zero
        return Placement(origin: CGPoint(x: last.minX + 32, y: last.minY + 32), longSide: longSide)
    }

    /// From tiles to places: each device keeps its picture where it is, in a frame that fits it exactly.
    private func adoptTiles() {
        guard !isArranged else { return }
        for other in views {
            guard let s = other.simulator, other.frame.width > 0 else { continue }
            let longSide = other.pictureLongSide
            let cell = other.cell(longSide: longSide)
            let picture = other.pictureFrame.origin
            placements[ObjectIdentifier(s)] = Placement(origin: CGPoint(x: other.frame.minX + picture.x - cell.picture.x,
                                                                        y: other.frame.minY + picture.y - cell.picture.y),
                                                        longSide: longSide)
        }
    }

    func beginArranging(_ v: SimulatorView, at event: NSEvent, resizing: Bool) {
        guard arrangeable, let sim = v.simulator else { return }
        adoptTiles()
        let id = ObjectIdentifier(sim)
        guard var p = placements[id] else { return }
        // Start from where it is drawn, so a device a small window had pushed in does not jump.
        p.longSide = clampedLongSide(v, p.longSide, within: bounds.size)
        p.origin = frame(v, p).origin
        placements[id] = p
        stacking.removeAll { $0 == id }
        stacking.append(id)
        applyStacking()
        gesture = (v, convert(event.locationInWindow, from: nil), p, resizing)
        needsLayout = true
    }

    func continueArranging(_ v: SimulatorView, at event: NSEvent) {
        guard let g = gesture, g.view === v, let sim = v.simulator else { return }
        let at = convert(event.locationInWindow, from: nil)
        let dx = at.x - g.start.x, dy = at.y - g.start.y
        var p = g.from
        if g.resizing {
            // The picture keeps its shape: it follows whichever side the pointer pulls further, and stays on the stage.
            let from = v.cell(longSide: g.from.longSide)
            let pictureW = from.size.width - 2 * from.picture.x
            let pictureH = from.size.height - 2 * from.picture.y - 30   // the caption under it
            let byW = g.from.longSide * (pictureW + dx) / max(pictureW, 1)
            let byH = g.from.longSide * (pictureH + dy) / max(pictureH, 1)
            let room = CGSize(width: bounds.width - g.from.origin.x, height: bounds.height - g.from.origin.y)
            p.longSide = clampedLongSide(v, max(byW, byH), within: room)
        } else {
            let size = v.cell(longSide: p.longSide).size
            p.origin = snapped(clampedOrigin(CGPoint(x: g.from.origin.x + dx, y: g.from.origin.y + dy), size: size), size: size, moving: v)
        }
        placements[ObjectIdentifier(sim)] = p
        needsLayout = true
    }

    func endArranging(_ v: SimulatorView) {
        guard gesture?.view === v else { return }
        gesture = nil
        save()
        needsLayout = true
    }

    // MARK: Without a mouse (VoiceOver's actions on a device)

    /// Moves a device by a step, or makes it larger or smaller by a factor, as a drag would.
    func adjust(_ v: SimulatorView, by d: CGSize = .zero, scale: CGFloat = 1) {
        guard arrangeable, let sim = v.simulator else { return }
        adoptTiles()
        let id = ObjectIdentifier(sim)
        guard var p = placements[id] else { return }
        p.longSide = clampedLongSide(v, p.longSide, within: bounds.size)
        p.origin = frame(v, p).origin
        if scale != 1 {
            let room = CGSize(width: bounds.width - p.origin.x, height: bounds.height - p.origin.y)
            p.longSide = clampedLongSide(v, p.longSide * scale, within: room)
        }
        let size = v.cell(longSide: p.longSide).size
        p.origin = clampedOrigin(CGPoint(x: p.origin.x + d.width, y: p.origin.y + d.height), size: size)
        placements[id] = p
        stacking.removeAll { $0 == id }
        stacking.append(id)
        applyStacking()
        save()
        needsLayout = true
    }

    // MARK: Kept across launches

    /// The arrangement is saved under each device's app, kind and place among devices of the same app and kind, so
    /// opening the same set again (or Greenroom reopening it) puts them back. Positions are the stage's points,
    /// kept to the stage when laid out.
    private static let savedKey = "stageArrangement"

    private func keys() -> [ObjectIdentifier: String] {
        var seen: [String: Int] = [:], out: [ObjectIdentifier: String] = [:]
        for v in views {
            guard let sim = v.simulator else { continue }
            var device = "phone"
            if let i = sim.options.firstIndex(of: "--device"), i + 1 < sim.options.count { device = sim.options[i + 1] }
            let base = sim.apk.lastPathComponent + "|" + device
            let n = seen[base, default: 0]
            seen[base] = n + 1
            out[ObjectIdentifier(sim)] = base + "|" + String(n)
        }
        return out
    }

    private func save() {
        let defaults = UserDefaults.standard
        guard isArranged else { defaults.removeObject(forKey: Self.savedKey); return }
        var saved = defaults.dictionary(forKey: Self.savedKey) as? [String: [Double]] ?? [:]
        for (id, key) in keys() {
            if let p = placements[id] { saved[key] = [p.origin.x, p.origin.y, p.longSide] }
        }
        defaults.set(saved, forKey: Self.savedKey)
    }

    /// The check's relaunch: places forgotten in memory, then read back from what was saved.
    func reloadSavedForCheck() {
        placements = [:]
        stacking = []
        restoreSaved()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// On a stage not arranged yet, the saved places of the devices shown, if any of them has one.
    private func restoreSaved() {
        guard arrangeable, !isArranged, gesture == nil,
              let saved = UserDefaults.standard.dictionary(forKey: Self.savedKey) as? [String: [Double]], !saved.isEmpty else { return }
        for (id, key) in keys() {
            if let s = saved[key], s.count == 3 { placements[id] = Placement(origin: CGPoint(x: s[0], y: s[1]), longSide: s[2]) }
        }
        if isArranged { animateNext = true }
    }

    /// Lines a moving device's edges up with the stage's and the other devices' when they come within a few points.
    private func snapped(_ o: CGPoint, size: CGSize, moving: SimulatorView) -> CGPoint {
        let others = views.filter { $0 !== moving }.map(\.frame)
        func snap(_ v: CGFloat, _ candidates: [CGFloat]) -> CGFloat {
            guard let near = candidates.min(by: { abs($0 - v) < abs($1 - v) }), abs(near - v) < 10 else { return v }
            return near
        }
        let xs: [CGFloat] = [0, bounds.width - size.width] + others.flatMap { o -> [CGFloat] in [o.minX, o.maxX, o.minX - size.width, o.maxX - size.width] }
        let ys: [CGFloat] = [0, bounds.height - size.height] + others.flatMap { o -> [CGFloat] in [o.minY, o.maxY, o.minY - size.height, o.maxY - size.height] }
        return CGPoint(x: snap(o.x, xs), y: snap(o.y, ys))
    }

    /// Draws (and hit-tests) the devices arranged last in front, and the memory label over everything.
    private func applyStacking() {
        final class Ranks { var of: [ObjectIdentifier: Int] = [:] }
        let ranks = Ranks()
        for (i, v) in views.enumerated() { ranks.of[ObjectIdentifier(v)] = i + 1 }
        for (i, id) in stacking.enumerated() {
            if let v = views.first(where: { $0.simulator.map(ObjectIdentifier.init) == id }) { ranks.of[ObjectIdentifier(v)] = views.count + 1 + i }
        }
        ranks.of[ObjectIdentifier(placeholder)] = 0
        ranks.of[ObjectIdentifier(memoryLabel)] = Int.max
        withExtendedLifetime(ranks) {
            sortSubviews({ a, b, context in
                let r = Unmanaged<Ranks>.fromOpaque(context!).takeUnretainedValue()
                let x = r.of[ObjectIdentifier(a)] ?? 1, y = r.of[ObjectIdentifier(b)] ?? 1
                return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            }, context: Unmanaged.passUnretained(ranks).toOpaque())
        }
    }
}
