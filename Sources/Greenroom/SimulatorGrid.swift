import AppKit

/// One or several simulator views, tiled so each picture is as large as the space allows.
final class SimulatorGrid: NSView {
    private(set) var views: [SimulatorView] = []
    private let placeholder = SimulatorView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(placeholder)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    /// The next layout moves the devices to their places rather than jumping (set when devices come or go).
    private var animateNext = false
    private var lastSideBySide = false
    private var arriving: [SimulatorView] = []

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
                addSubview(v)
                v.show(sim)
                next.append(v)
            }
        }
        for v in views where !next.contains(where: { $0 === v }) {
            // A device leaving fades and sinks a little; the others close the gap as it goes.
            v.show(nil)
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
        for v in views {
            v.showsCaption = sideBySide && views.count > 1
            v.isChosen = v.simulator === chosen
        }
        placeholder.isHidden = !views.isEmpty
        if views.isEmpty { placeholder.show(nil, placeholder: hint) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        placeholder.frame = bounds
        guard !views.isEmpty else { return }
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
        let animate = animateNext && window != nil && !Design.reduceMotion
        animateNext = false
        let fresh = arriving
        arriving = []
        guard animate else { for (v, frame) in zip(views, best) { v.frame = frame }; return }
        for v in fresh {
            // A new device rises into its place from just below, fading in.
            if let i = views.firstIndex(where: { $0 === v }) { v.frame = best[i].offsetBy(dx: 0, dy: 24) }
            v.alphaValue = 0
        }
        Design.animate(Design.move, {
            for (v, frame) in zip(views, best) {
                v.animateLayout = true
                v.animator().frame = frame
                if fresh.contains(where: { $0 === v }) { v.animator().alphaValue = 1 }
            }
        }, done: { [weak self] in self?.views.forEach { $0.animateLayout = false } })
    }
}
