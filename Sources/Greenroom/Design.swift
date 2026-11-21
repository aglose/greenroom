import AppKit

/// Every colour, radius and motion curve the window uses, in one place. Views take their values from here.
enum Design {
    // Colours of the dark stage and the glass that floats over it.
    static let stage = NSColor(srgbRed: 0.071, green: 0.075, blue: 0.086, alpha: 1)
    static let stageDot = NSColor(white: 1, alpha: 0.055)
    static let ink = NSColor(srgbRed: 0.949, green: 0.953, blue: 0.961, alpha: 1)
    static let mute = NSColor(srgbRed: 0.643, green: 0.659, blue: 0.690, alpha: 1)
    static let well = NSColor(white: 1, alpha: 0.07)
    static let wellOn = NSColor(white: 1, alpha: 0.17)
    static let stroke = NSColor(white: 1, alpha: 0.09)
    static let accent = NSColor(srgbRed: 0.239, green: 0.839, blue: 0.549, alpha: 1)       // live, selected, on
    static let onAccent = NSColor(srgbRed: 0.024, green: 0.157, blue: 0.102, alpha: 1)
    static let record = NSColor(srgbRed: 1.0, green: 0.322, blue: 0.278, alpha: 1)
    static let difference = NSColor(srgbRed: 1.0, green: 0.435, blue: 0.812, alpha: 1)
    static let agent = NSColor(srgbRed: 0.357, green: 0.294, blue: 0.839, alpha: 1)
    static let warning = NSColor(srgbRed: 1.0, green: 0.753, blue: 0.302, alpha: 1)

    // Shapes.
    static let barHeight: CGFloat = 48
    static let margin: CGFloat = 12
    static let glassRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10

    // Motion: three curves cover everything (docs/UI-PLAN.md). Each is a duration and a timing; springs where
    // something moves, a quick ease where something changes state.
    static var snap: TimeInterval { 0.15 * slow }
    static var move: TimeInterval { 0.34 * slow }
    static var arrive: TimeInterval { 0.24 * slow }
    /// `GREENROOM_SLOW_MOTION=N` runs every animation N times slower, to look at one (or capture it) mid-flight.
    static let slow: Double = Double(ProcessInfo.processInfo.environment["GREENROOM_SLOW_MOTION"] ?? "") ?? 1
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func moveTiming() -> CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1) }

    /// Runs `changes` animated on the `move` curve, or at once when the person asked for reduced motion.
    static func animate(_ duration: TimeInterval = 0.34, _ changes: () -> Void, done: (() -> Void)? = nil) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            changes(); done?(); return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = moveTiming()
            ctx.allowsImplicitAnimation = true
            changes()
        }, completionHandler: done)
    }
}

/// A rounded pane of frosted glass that floats over the stage.
final class GlassView: NSVisualEffectView {
    init(radius: CGFloat = Design.glassRadius) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Design.stroke.cgColor
        appearance = NSAppearance(named: .darkAqua)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The canvas the devices stand on: dark, with a faint dot grid that shows the space is a surface.
final class StageBackground: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Design.stage.cgColor
        let dot = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            Design.stageDot.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
            return true
        }
        let pattern = CALayer()
        pattern.backgroundColor = NSColor(patternImage: dot).cgColor
        pattern.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(pattern)
        dots = pattern
    }

    private var dots: CALayer?

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = Design.stage.cgColor
        dots?.frame = bounds
        CATransaction.commit()
    }
}

/// Lays out a GlassButton's content itself: AppKit's own layout put a leading image against the button's edge and
/// spread the rest of the width between image and title, so every icon-and-title button looked lopsided. Here the
/// icon and title are one group with fixed insets and gap, centred in whatever width the button is given.
final class GlassButtonCell: NSButtonCell {
    static let inset: CGFloat = 12, gap: CGFloat = 6, iconOnly = NSSize(width: 32, height: 30)

    private var iconSize: NSSize { imagePosition == .noImage ? .zero : (image?.size ?? .zero) }
    private var titleSize: NSSize { title.isEmpty ? .zero : attributedTitle.size() }
    private var groupWidth: CGFloat {
        let i = iconSize.width, t = titleSize.width
        return i + t + (i > 0 && t > 0 ? Self.gap : 0)
    }

    override var cellSize: NSSize {
        if title.isEmpty { return Self.iconOnly }
        return NSSize(width: ceil(groupWidth + 2 * Self.inset), height: Self.iconOnly.height)
    }

    private func groupOrigin(in bounds: NSRect) -> CGFloat { bounds.minX + floor((bounds.width - groupWidth) / 2) }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        let s = iconSize
        guard s.width > 0 else { return .zero }
        return NSRect(x: groupOrigin(in: rect), y: rect.minY + floor((rect.height - s.height) / 2), width: s.width, height: s.height)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let s = titleSize
        guard s.width > 0 else { return .zero }
        let i = iconSize.width
        let x = groupOrigin(in: rect) + (i > 0 ? i + Self.gap : 0)
        return NSRect(x: x, y: rect.minY + floor((rect.height - s.height) / 2), width: ceil(s.width), height: ceil(s.height))
    }

    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in view: NSView) {
        super.drawImage(image, withFrame: imageRect(forBounds: view.bounds), in: view)
    }

    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in view: NSView) -> NSRect {
        let r = titleRect(forBounds: view.bounds)
        title.draw(in: r)
        return r
    }
}

/// A button on glass: a symbol, a title, or both, in a soft well; tinted while on.
final class GlassButton: NSButton {
    override class var cellClass: AnyClass? { get { GlassButtonCell.self } set {} }
    enum Style { case plain, well, accent, record }
    var style: Style = .plain { didSet { refresh() } }
    var isOn = false { didSet { refresh() } }
    /// What a press does, for buttons made in code without a target.
    var onPress: (() -> Void)? { didSet { target = self; action = #selector(pressed) } }
    @objc private func pressed() { onPress?() }
    private var hovering = false { didSet { refresh() } }

    convenience init(symbol: String?, title: String = "", label: String, style: Style = .plain, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) }
        imagePosition = symbol == nil ? .noImage : (title.isEmpty ? .imageOnly : .imageLeading)
        toolTip = label
        setAccessibilityLabel(label)
        self.target = target
        self.action = action
        self.style = style
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        font = .systemFont(ofSize: 13, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        if title.isEmpty { widthAnchor.constraint(equalToConstant: 32).isActive = true }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        refresh()
    }

    override var intrinsicContentSize: NSSize { cell?.cellSize ?? super.intrinsicContentSize }
    // AppKit gives a button its symbol's alignment insets (doc.on.doc has some), so constraints then sized an inner
    // rectangle: "Copy route" came out 33 pt tall and 1.5 pt higher than "Go there" beside it. The well is the button.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    // A new title or symbol keeps the button's colours and re-measures it (the Walk/Stop and count buttons).
    override var title: String { didSet { if title != oldValue { refresh(); invalidateIntrinsicContentSize() } } }
    override var image: NSImage? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    override var isHighlighted: Bool { didSet { refresh() } }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func refresh() {
        let fill: NSColor, ink: NSColor
        switch (style, isOn) {
        case (.accent, _), (_, true) where style != .record: fill = isOn || style == .accent ? Design.accent : Design.well; ink = Design.onAccent
        case (.record, true): fill = Design.record.withAlphaComponent(0.22); ink = NSColor(srgbRed: 1, green: 0.70, blue: 0.68, alpha: 1)
        case (.well, _), (.record, false): fill = hovering ? Design.wellOn : Design.well; ink = Design.ink
        default: fill = hovering ? Design.well : .clear; ink = isEnabled ? Design.ink : Design.mute
        }
        CATransaction.begin(); CATransaction.setAnimationDuration(Design.snap)
        // Pressed, a button darkens at once (no waiting for the click to finish to show it was hit).
        layer?.backgroundColor = (isHighlighted ? fill.blended(withFraction: 0.35, of: .black) ?? fill : fill).cgColor
        if isHighlighted, fill.alphaComponent < 0.05 { layer?.backgroundColor = Design.wellOn.cgColor }
        CATransaction.commit()
        contentTintColor = ink
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: ink, .font: font ?? .systemFont(ofSize: 13)])
    }

    override var isEnabled: Bool { didSet { refresh(); alphaValue = isEnabled ? 1 : 0.45 } }
}
