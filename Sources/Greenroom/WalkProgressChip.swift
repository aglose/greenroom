import AppKit

/// How far a running walk has got, said outside the screen map: a short line and, once the crawler reports which
/// screens it has finished, the share of the screens found so far that are opened (nil: not known yet).
struct WalkProgress: Equatable {
    var text: String
    var fraction: Double?
    /// The full line the sheet shows, for the tooltip.
    var detail: String
    /// The same share as a count, for the job list: the screens opened, of those found so far.
    var counted: JobProgress? = nil
}

/// The running walk in the top bar: a spinner, how far it has got and a thin bar under it. It stays while the walk
/// runs, whether or not the screen map is open, so a walk is never mistaken for over and started again. A click opens
/// the map.
final class WalkProgressChip: NSView {
    var onOpen: (() -> Void)?
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let track = CALayer()
    private let fill = CALayer()
    private(set) var progress: WalkProgress?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Design.well.cgColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = Design.ink
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let icon = NSImageView(image: NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = Design.accent
        let row = NSStackView(views: [spinner, icon, label])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        track.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        fill.backgroundColor = Design.accent.cgColor
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: GlassButtonCell.iconOnly.height),
            widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Nil: no walk is running, and the chip goes.
    func show(_ p: WalkProgress?) {
        guard p != progress else { return }
        let was = progress
        progress = p
        guard let p else {
            spinner.stopAnimation(nil)
            isHidden = true
            return
        }
        if was == nil { spinner.startAnimation(nil); isHidden = false }
        label.stringValue = p.text
        toolTip = p.detail + "\nClick to open the screen map."
        setAccessibilityLabel("Walking the app: " + p.detail)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(progress?.fraction == nil)
        let h: CGFloat = 2
        track.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        let f = min(1, max(0, progress?.fraction ?? 0))
        track.isHidden = progress?.fraction == nil
        fill.isHidden = track.isHidden
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * f, height: h)
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { layer?.backgroundColor = Design.wellOn.cgColor }
    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = Design.well.cgColor
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
