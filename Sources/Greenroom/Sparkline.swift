import AppKit

/// A small line chart of the last samples: one CAShapeLayer for the line, one for the fill under it. Setting
/// `values` rebuilds two paths (60 points), nothing else, so it is cheap to update every second.
final class Sparkline: NSView {
    var values: [Double] = [] { didSet { rebuild() } }
    /// The scale: the chart's top is this, or the largest value when it is higher. 0 means the largest value alone.
    var floorTop: Double = 0 { didSet { rebuild() } }
    var tint: NSColor = Design.accent { didSet { line.strokeColor = tint.cgColor; fill.fillColor = tint.withAlphaComponent(0.16).cgColor } }
    /// How many samples the chart's width stands for.
    var capacity = 60

    private let line = CAShapeLayer()
    private let fill = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor
        layer?.masksToBounds = true
        line.fillColor = nil
        line.lineWidth = 1.5
        line.lineJoin = .round
        line.strokeColor = tint.cgColor
        fill.fillColor = tint.withAlphaComponent(0.16).cgColor
        layer?.addSublayer(fill)
        layer?.addSublayer(line)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }
    override func layout() { super.layout(); rebuild() }

    private func rebuild() {
        let w = bounds.width, h = bounds.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        line.frame = bounds; fill.frame = bounds
        guard values.count > 1, w > 0, h > 0 else { line.path = nil; fill.path = nil; return }
        let top = max(floorTop, values.max() ?? 0, 0.0001)
        let step = w / CGFloat(max(capacity - 1, 1))
        let x0 = w - step * CGFloat(values.count - 1)   // the newest sample sits at the right edge
        let path = CGMutablePath()
        for (i, v) in values.enumerated() {
            let p = CGPoint(x: x0 + step * CGFloat(i), y: 3 + (h - 6) * CGFloat(v / top))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        line.path = path
        let area = CGMutablePath()
        area.addPath(path)
        area.addLine(to: CGPoint(x: w, y: 0)); area.addLine(to: CGPoint(x: x0, y: 0)); area.closeSubpath()
        fill.path = area
    }
}
