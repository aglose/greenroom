import AppKit
import AVFoundation

/// What a person did in a simulator's view, with positions as fractions of the device's screen so the same
/// gesture can be sent to devices of other sizes.
enum SimulatorInput {
    case touch(String, CGPoint)          // down | move | up, position
    case wheel(CGPoint, CGFloat)
    case command(String)                 // back, key NAME ...
    case text(String)
}

extension Simulator {
    func perform(_ input: SimulatorInput) {
        onPerform?(input)
        let size = deviceSize
        func px(_ f: CGPoint) -> (CGFloat, CGFloat) {
            (min(max(f.x * size.width, 0), max(size.width - 1, 0)), min(max(f.y * size.height, 0), max(size.height - 1, 0)))
        }
        switch input {
        case .touch(let kind, let f):
            guard size.width > 0 else { return }
            if kind == "down" { activity.touched() }
            let (x, y) = px(f)
            send(String(format: "touch %@ %.1f %.1f", kind, x, y))
        case .wheel(let f, let dy):
            guard size.width > 0 else { return }
            let (x, y) = px(f)
            send(String(format: "wheel %.1f %.1f %.3f", x, y, dy))
        case .command(let c): send(c)
        case .text(let t): type(t)
        }
    }
}

/// Shows one simulator's screen, fitted into the view, and sends the mouse, scroll wheel and keyboard to it.
/// Positions go to the engine in device pixels, whatever size the picture is drawn at.
final class SimulatorView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    private let message = NSTextField(labelWithString: "")
    private(set) var simulator: Simulator?
    private var touching = false
    private let caption = NSTextField(labelWithString: "")
    /// Where input goes. Unset, it goes to this view's own simulator.
    var route: ((SimulatorInput, SimulatorView) -> Void)?
    /// Called when the view is clicked, before the click is sent.
    var onSelect: ((SimulatorView) -> Void)?
    /// A caption under the picture and an outline when chosen: for views shown side by side.
    var showsCaption = false { didSet { needsLayout = true } }
    var isChosen = false { didSet { updateOutline() } }
    /// Areas to point out on the picture, in device pixels: boxes (differences in content) and filled areas
    /// (differing pixels). Set by a comparison.
    var boxes: [CGRect] = [] { didSet { needsLayout = true } }
    var areas: [CGRect] = [] { didSet { needsLayout = true } }
    /// The inspector's node, outlined in the accent colour.
    var outlined: CGRect? { didSet { needsLayout = true } }
    /// While inspecting, the pointer picks nodes and touches are not sent to the app.
    var inspecting = false { didSet { updateTracking() } }
    var onPoint: ((Int, Int) -> Void)?
    /// Extra text at the end of the caption (the Diagnostics pane's live fps); empty for none.
    var captionExtra = "" { didSet { if captionExtra != oldValue { updateCaption() } } }
    /// On a side-by-side canvas: the body and caption move the device, the grip at its bottom right resizes it, and
    /// the button at its top left closes it. The grid does the moving and sizing; the view reports the gesture.
    var arrangeable = false { didSet { if arrangeable != oldValue { updateTracking(); updateChips() } } }
    weak var arranger: SimulatorGrid?
    private let closeChip = CornerButton()
    private let gripChip = ChipImage()
    private var gripRect = CGRect.zero
    /// The device as it takes clicks while arranged: its body, chips and caption, not the padding around them, so a
    /// device overlapping another does not take the clicks meant for the one underneath.
    private var bodyRect = CGRect.zero
    /// A press on the body or grip: it becomes a move or a resize only once the pointer has travelled a few points,
    /// so a click (to choose the device) leaves the stage as it is.
    private var pressed: (event: NSEvent, at: CGPoint, resizing: Bool)?
    /// Whether the pointer is over this device and no device in front of it (set by the grid, which knows the order).
    var hovering = false { didSet { if hovering != oldValue { updateChips() } } }
    private enum Arranging { case move, resize }
    private var arranging: Arranging?
    private let outlineLayer = CAShapeLayer()
    private var tracking: NSTrackingArea?
    private let boxLayer = CAShapeLayer()
    private let areaLayer = CAShapeLayer()
    // The device's body: a metal rim, a black bezel, a camera, and a ring while chosen.
    private let rimLayer = CAGradientLayer()
    private let bezelLayer = CALayer()
    private let cameraLayer = CALayer()
    private let ringLayer = CALayer()
    private let hingeLayer = CAGradientLayer()
    /// The screen while the app starts: the device's shape, softly breathing, until the first picture fades in.
    private let placeholderLayer = CALayer()
    private var waitingForFirstFrame = false
    /// The next layout moves the body to its new place and shape rather than jumping (set by the grid, and by a
    /// rotation or device change).
    var animateLayout = false
    private var morphOnce = false
    private var lastSize = CGSize.zero

    private var recorderObserver: NSObjectProtocol?
    deinit { if let o = recorderObserver { NotificationCenter.default.removeObserver(o) } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        recorderObserver = NotificationCenter.default.addObserver(forName: Recorder.didChange, object: nil, queue: .main) { [weak self] _ in self?.updateCaption() }
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
        display.masksToBounds = true
        display.cornerCurve = .continuous
        ringLayer.borderColor = Design.accent.cgColor
        ringLayer.borderWidth = 3
        ringLayer.cornerCurve = .continuous
        ringLayer.shadowColor = Design.accent.cgColor
        ringLayer.shadowOpacity = 0.45
        ringLayer.shadowRadius = 22
        ringLayer.shadowOffset = .zero
        ringLayer.opacity = 0
        rimLayer.colors = [NSColor(white: 0.62, alpha: 1), NSColor(white: 0.24, alpha: 1), NSColor(white: 0.49, alpha: 1), NSColor(white: 0.19, alpha: 1)].map(\.cgColor)
        rimLayer.locations = [0, 0.38, 0.7, 1]
        rimLayer.startPoint = CGPoint(x: 0, y: 0)
        rimLayer.endPoint = CGPoint(x: 1, y: 1)
        rimLayer.cornerCurve = .continuous
        rimLayer.shadowColor = NSColor.black.cgColor
        rimLayer.shadowOpacity = 0.85
        rimLayer.shadowRadius = 34
        rimLayer.shadowOffset = CGSize(width: 0, height: -26)
        bezelLayer.backgroundColor = NSColor(srgbRed: 0.02, green: 0.02, blue: 0.024, alpha: 1).cgColor
        bezelLayer.cornerCurve = .continuous
        cameraLayer.backgroundColor = NSColor(srgbRed: 0.02, green: 0.02, blue: 0.024, alpha: 1).cgColor
        cameraLayer.borderColor = NSColor(white: 0.12, alpha: 1).cgColor
        cameraLayer.borderWidth = 1
        hingeLayer.colors = [NSColor(white: 0, alpha: 0.45).cgColor, NSColor(white: 1, alpha: 0.07).cgColor]
        hingeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        hingeLayer.endPoint = CGPoint(x: 1, y: 0.5)
        placeholderLayer.backgroundColor = NSColor(srgbRed: 0.10, green: 0.105, blue: 0.12, alpha: 1).cgColor
        placeholderLayer.cornerCurve = .continuous
        placeholderLayer.isHidden = true
        for l in [ringLayer, rimLayer, bezelLayer, placeholderLayer, display, hingeLayer, cameraLayer] { layer?.addSublayer(l) }

        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.textColor = Design.mute
        message.alignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        caption.font = .systemFont(ofSize: 12, weight: .regular)
        caption.textColor = Design.mute
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        addSubview(caption)
        for chip in [closeChip, gripChip] as [NSView] {
            chip.wantsLayer = true
            chip.layer?.backgroundColor = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 0.96).cgColor
            chip.layer?.cornerRadius = Self.chip / 2
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
            chip.alphaValue = 0
            chip.isHidden = true
            addSubview(chip)
        }
        let small = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        closeChip.isBordered = false
        closeChip.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(small)
        closeChip.contentTintColor = Design.ink
        closeChip.target = self
        closeChip.action = #selector(closeClicked)
        closeChip.setAccessibilityLabel("Close this simulator")
        gripChip.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Resize")?.withSymbolConfiguration(small)
        gripChip.contentTintColor = Design.ink
        gripChip.imageScaling = .scaleNone
        areaLayer.fillColor = NSColor.systemPink.withAlphaComponent(0.28).cgColor
        boxLayer.fillColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        boxLayer.strokeColor = NSColor.systemOrange.cgColor
        boxLayer.lineWidth = 2
        outlineLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        outlineLayer.strokeColor = NSColor.controlAccentColor.cgColor
        outlineLayer.lineWidth = 2
        layer?.addSublayer(outlineLayer)
        layer?.addSublayer(areaLayer)
        layer?.addSublayer(boxLayer)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func show(_ sim: Simulator?, placeholder: String = "") {
        simulator?.onSample = nil
        simulator?.onSize = nil
        simulator = sim
        display.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        message.stringValue = sim == nil ? placeholder : (sim!.state == .starting ? "Starting \(sim!.name)…" : "")
        lastSize = .zero
        guard let sim else { placeholderLayer.isHidden = true; return }
        waitingForFirstFrame = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        display.opacity = 0
        placeholderLayer.isHidden = false
        placeholderLayer.opacity = 1
        CATransaction.commit()
        if !Design.reduceMotion {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.55
            breathe.duration = 1.1
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            placeholderLayer.add(breathe, forKey: "breathe")
        }
        let renderer = display.sampleBufferRenderer
        sim.onSample = { [weak self, weak sim] sample in
            if renderer.status == .failed {
                renderer.flush()
                sim?.requestKeyframe()
            }
            renderer.enqueue(sample)
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.message.stringValue.isEmpty { self.message.stringValue = "" }
                if self.waitingForFirstFrame { self.firstFrameArrived() }
            }
        }
        sim.onSize = { [weak self] size in
            guard let self else { return }
            // A rotation or a device change: the body turns into its new shape instead of jumping.
            if self.lastSize.width > 0, size != self.lastSize { self.morphOnce = true }
            self.needsLayout = true
            self.updateCaption()
        }
        updateCaption()
        sim.requestKeyframe()
        sim.send("redraw")
        needsLayout = true
        window?.makeFirstResponder(self)
    }

    func setMessage(_ text: String) { message.stringValue = text }

    /// The first picture cross-fades over the breathing placeholder.
    private func firstFrameArrived() {
        waitingForFirstFrame = false
        let d = Design.reduceMotion ? 0.12 : 0.22 * Design.slow
        CATransaction.begin()
        CATransaction.setAnimationDuration(d)
        CATransaction.setCompletionBlock { [weak self] in
            self?.placeholderLayer.removeAnimation(forKey: "breathe")
            self?.placeholderLayer.isHidden = true
        }
        display.opacity = 1
        placeholderLayer.opacity = 0
        CATransaction.commit()
    }

    /// The device's size, or before its first picture, the size its kind of device usually has, so the body can
    /// stand on the stage while the app starts.
    private var effectiveSize: CGSize {
        if let s = simulator?.deviceSize, s.width > 0 { return s }
        guard let sim = simulator else { return .zero }
        var kind = "phone"
        if let i = sim.options.firstIndex(of: "--device"), i + 1 < sim.options.count { kind = sim.options[i + 1] }
        switch kind {
        case "watch", "watch-large": return CGSize(width: 454, height: 454)
        case "watch-small": return CGSize(width: 384, height: 384)
        case "foldable": return CGSize(width: 1682, height: 1402)
        case "pixel-10-pro-fold": return CGSize(width: 2076, height: 2152)
        case "tablet": return CGSize(width: 2560, height: 1600)
        case "desktop": return CGSize(width: 2560, height: 1440)
        case "tv": return CGSize(width: 3840, height: 2160)
        default: return CGSize(width: 822, height: 1782)
        }
    }

    /// A ring that fades at a device position: where an agent touched, so the person can follow it.
    func flashTouch(deviceX: Int, deviceY: Int) {
        guard let size = simulator?.deviceSize, size.width > 0, let host = layer else { return }
        let r = pictureRect
        let p = CGPoint(x: r.minX + CGFloat(deviceX) / size.width * r.width, y: r.minY + CGFloat(deviceY) / size.height * r.height)
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -16, y: -16, width: 32, height: 32), transform: nil)
        ring.position = p
        ring.fillColor = NSColor.systemPink.withAlphaComponent(0.35).cgColor
        ring.strokeColor = NSColor.systemPink.cgColor
        ring.lineWidth = 2
        host.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.6
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "touch")
        CATransaction.commit()
    }

    /// What kind of body the device is drawn in, from its screen's shape.
    private enum Body { case phone, fold, watch, flat }

    private var body: Body {
        let s = effectiveSize
        guard s.width > 0, s.height > 0 else { return .phone }
        let a = s.width / s.height
        if abs(s.width - s.height) < 2, max(s.width, s.height) < 700 { return .watch }
        if a > 0.8, a < 1.25 { return .fold }
        if a > 1.25 && max(s.width, s.height) > 2000 { return .flat }   // tablet, desktop, TV
        return .phone
    }

    private var kindName: String {
        if let i = simulator?.options.firstIndex(of: "--device"), let d = simulator?.options.dropFirst(i + 1).first {
            return Workbench.title(d)
        }
        switch body {
        case .phone: return "Phone"
        case .fold: return "Foldable"
        case .watch: return "Watch"
        case .flat: return "Tablet"
        }
    }

    private func updateCaption() {
        guard let sim = simulator else { caption.attributedStringValue = NSAttributedString(); return }
        let size = sim.deviceSize
        let text = NSMutableAttributedString(string: kindName, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Design.ink])
        if Recorder.isRecording(sim) { text.insert(NSAttributedString(string: "●  ", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Design.record]), at: 0) }
        var rest = "   \(sim.cellLabel ?? sim.name)"
        if size.width > 0 { rest += "   \(Int(size.width))×\(Int(size.height))" }
        if !captionExtra.isEmpty { rest += "   ·   \(captionExtra)" }
        text.append(NSAttributedString(string: rest, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Design.mute]))
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.lineBreakMode = .byTruncatingMiddle
        text.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: text.length))
        caption.attributedStringValue = text
    }

    private func updateOutline() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Design.arrive)
        ringLayer.opacity = isChosen && showsCaption && simulator != nil ? 1 : 0
        CATransaction.commit()
    }

    private func emit(_ input: SimulatorInput) {
        if let route { route(input, self) } else { simulator?.perform(input) }
    }

    /// Where the picture is drawn: the device's shape fitted into the view with a margin.
    private var pictureRect: CGRect {
        let size = effectiveSize
        var area = bounds.insetBy(dx: 28, dy: 24)
        area.size.height -= 30   // the caption
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return area }
        // First fit, then take the body's bezel and rim off the space and fit again.
        let first = min(area.width / size.width, area.height / size.height)
        let edge = 2 * (bezel(forShortSide: min(size.width, size.height) * first) + 3)
        let scale = max(0.01, min((area.width - edge) / size.width, (area.height - edge) / size.height))
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded(), width: w.rounded(), height: h.rounded())
    }

    private func bezel(forShortSide side: CGFloat) -> CGFloat {
        switch body {
        case .watch: return max(8, side * 0.055)
        case .flat: return max(6, side * 0.018)
        default: return min(12, max(6, side * 0.028))
        }
    }

    private func screenRadius(_ r: CGRect) -> CGFloat {
        let short = min(r.width, r.height)
        switch body {
        case .watch: return short / 2
        case .phone: return short * 0.125
        case .fold: return short * 0.04
        case .flat: return short * 0.03
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        let size0 = simulator?.deviceSize ?? .zero
        if (animateLayout || morphOnce) && !Design.reduceMotion {
            CATransaction.setAnimationDuration(Design.move)
            CATransaction.setAnimationTimingFunction(Design.moveTiming())
        } else {
            CATransaction.setDisableActions(true)
        }
        morphOnce = false
        if size0.width > 0 { lastSize = size0 }
        // A flipped, layer-backed view's sublayers use its flipped coordinates.
        let r = pictureRect
        display.frame = r
        let hasDevice = simulator != nil
        let b = bezel(forShortSide: min(r.width, r.height))
        let screenR = screenRadius(r)
        display.cornerRadius = screenR
        placeholderLayer.frame = r
        placeholderLayer.cornerRadius = screenR
        let bezelRect = r.insetBy(dx: -b, dy: -b)
        bezelLayer.frame = bezelRect
        bezelLayer.cornerRadius = body == .watch ? bezelRect.width / 2 : screenR + b
        let rimRect = bezelRect.insetBy(dx: -3, dy: -3)
        rimLayer.frame = rimRect
        rimLayer.cornerRadius = body == .watch ? rimRect.width / 2 : screenR + b + 3
        rimLayer.shadowPath = CGPath.rounded(CGRect(origin: .zero, size: rimRect.size), radius: rimLayer.cornerRadius)
        let ringRect = rimRect.insetBy(dx: -3, dy: -3)
        ringLayer.frame = ringRect
        ringLayer.cornerRadius = rimLayer.cornerRadius + 3
        let cam = max(8, min(14, r.width * 0.044))
        switch body {
        case .phone: cameraLayer.frame = CGRect(x: r.midX - cam / 2, y: r.minY + cam * 0.9, width: cam, height: cam)
        case .fold: cameraLayer.frame = CGRect(x: r.maxX - cam * 2.6, y: r.minY + cam * 1.1, width: cam, height: cam)
        default: cameraLayer.frame = .zero
        }
        cameraLayer.cornerRadius = cam / 2
        hingeLayer.frame = body == .fold ? CGRect(x: r.midX - 1, y: r.minY, width: 2, height: r.height) : .zero
        for l in [rimLayer, bezelLayer, cameraLayer, hingeLayer, display] as [CALayer] { l.isHidden = !hasDevice }
        // The marks, from device pixels to where the picture is drawn.
        let size = simulator?.deviceSize ?? .zero
        func path(_ rects: [CGRect]) -> CGPath {
            let p = CGMutablePath()
            guard size.width > 0, size.height > 0 else { return p }
            let sx = r.width / size.width, sy = r.height / size.height
            for q in rects { p.addRect(CGRect(x: r.minX + q.minX * sx, y: r.minY + q.minY * sy, width: q.width * sx, height: q.height * sy)) }
            return p
        }
        areaLayer.frame = bounds
        boxLayer.frame = bounds
        outlineLayer.frame = bounds
        outlineLayer.path = path(outlined.map { [$0] } ?? [])
        areaLayer.path = path(areas)
        boxLayer.path = path(boxes)
        CATransaction.commit()
        caption.frame = CGRect(x: 8, y: rimRect.maxY + 12, width: bounds.width - 16, height: 18)
        caption.isHidden = !hasDevice
        // The chips sit just outside the body's corners; neither takes a click on the screen itself.
        closeChip.frame = CGRect(x: rimRect.minX + 3 - Self.chip / 2, y: rimRect.minY + 3 - Self.chip / 2, width: Self.chip, height: Self.chip)
        gripChip.frame = CGRect(x: rimRect.maxX - 3 - Self.chip / 2, y: rimRect.maxY - 3 - Self.chip / 2, width: Self.chip, height: Self.chip)
        gripRect = gripChip.frame.insetBy(dx: -6, dy: -6)
        closeChip.blocked = r
        bodyRect = rimRect.union(closeChip.frame).union(gripRect).union(caption.frame)
        updateOutline()
    }

    private static let chip: CGFloat = 22

    /// The close and resize chips: shown while the pointer is over an arrangeable device, or it is being arranged.
    private func updateChips() {
        let on = arrangeable && simulator != nil && (hovering || arranging != nil)
        closeChip.toolTip = simulator.map { "Close \($0.name)" }
        gripChip.toolTip = "Drag to resize"
        for chip in [closeChip, gripChip] as [NSView] {
            if on { chip.isHidden = false }
            Design.animate(Design.snap, { chip.animator().alphaValue = on ? 1 : 0 }, done: { if !(self.arrangeable && (self.hovering || self.arranging != nil)) { chip.isHidden = true } })
        }
    }

    @objc private func closeClicked() {
        if let sim = simulator { arranger?.close(sim) }
    }

    @objc private func tidyClicked() { arranger?.tidy() }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { simulator != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        guard let sim = simulator else { return nil }
        return "\(kindName), \(sim.name)"
    }

    /// What a drag does, for VoiceOver and Full Keyboard Access: move a step, larger or smaller, close, Tidy Up.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard arrangeable, let arranger, simulator != nil else { return nil }
        let step: CGFloat = 40
        func action(_ name: String, _ f: @escaping () -> Void) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) { f(); return true }
        }
        var actions = [
            action("Move left") { [weak self] in self.map { arranger.adjust($0, by: CGSize(width: -step, height: 0)) } },
            action("Move right") { [weak self] in self.map { arranger.adjust($0, by: CGSize(width: step, height: 0)) } },
            action("Move up") { [weak self] in self.map { arranger.adjust($0, by: CGSize(width: 0, height: -step)) } },
            action("Move down") { [weak self] in self.map { arranger.adjust($0, by: CGSize(width: 0, height: step)) } },
            action("Make larger") { [weak self] in self.map { arranger.adjust($0, scale: 1.15) } },
            action("Make smaller") { [weak self] in self.map { arranger.adjust($0, scale: 1 / 1.15) } },
            action("Close") { [weak self] in self?.closeClicked() },
        ]
        if arranger.isArranged { actions.append(action("Tidy Up") { arranger.tidy() }) }
        return actions
    }

    // MARK: Arranging on the canvas

    /// The view's size that holds a picture with this long side exactly, and where the picture's top left then is:
    /// the inverse of `pictureRect`, so the canvas can size a device by its picture.
    func cell(longSide: CGFloat) -> (size: CGSize, picture: CGPoint) {
        let s = effectiveSize
        let long = max(s.width, s.height)
        guard long > 0 else { return (CGSize(width: longSide * 0.46 + 80, height: longSide + 102), CGPoint(x: 40, y: 36)) }
        let pw = s.width * longSide / long, ph = s.height * longSide / long
        let edge = 2 * (bezel(forShortSide: min(pw, ph)) + 3)
        return (CGSize(width: (pw + edge + 56).rounded(.up), height: (ph + edge + 48 + 30).rounded(.up)), CGPoint(x: 28 + edge / 2, y: 24 + edge / 2))
    }

    /// The picture's long side as drawn now, and its place in this view.
    var pictureLongSide: CGFloat { let r = pictureRect; return max(r.width, r.height) }
    var pictureFrame: CGRect { pictureRect }

    /// The smallest a picture may be made on the canvas: big enough to read the app and hit its controls, a
    /// short side of at least 110 points and a long side of at least 240.
    var minimumLongSide: CGFloat {
        let s = effectiveSize
        guard s.width > 0, s.height > 0 else { return 240 }
        return max(240, 110 * max(s.width, s.height) / min(s.width, s.height))
    }

    private func cursor(at p: CGPoint) -> NSCursor {
        guard arrangeable, !inspecting, simulator != nil else { return .arrow }
        if arranging == .move { return .closedHand }
        if arranging == .resize || onGrip(p) {
            if #available(macOS 15, *) { return .frameResize(position: .bottomRight, directions: .all) }
            return .crosshair
        }
        if closeChip.frame.contains(p) || pictureRect.contains(p) { return .arrow }
        return .openHand
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(self, true)
        arranger?.refreshHover()
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(self, false)
        arranger?.refreshHover()
        if arranging == nil { NSCursor.arrow.set() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard arrangeable, let sim = simulator, !pictureRect.contains(convert(event.locationInWindow, from: nil)) else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Close \(sim.name)", action: #selector(closeClicked), keyEquivalent: "").target = self
        if arranger?.isArranged == true {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Tidy Up", action: #selector(tidyClicked), keyEquivalent: "").target = self
        }
        return menu
    }

    /// The event's position as a fraction of the picture, clamped to it.
    private func fraction(_ event: NSEvent) -> CGPoint? {
        guard let size = simulator?.deviceSize, size.width > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let r = pictureRect
        guard r.width > 0, r.height > 0 else { return nil }
        return CGPoint(x: min(max((p.x - r.minX) / r.width, 0), 1), y: min(max((p.y - r.minY) / r.height, 0), 1))
    }

    private func touch(_ kind: String, _ event: NSEvent) {
        if let f = fraction(event) { emit(.touch(kind, f)) }
    }

    private func updateTracking() {
        if let tracking { removeTrackingArea(tracking) }
        // Entering and leaving always (the matrix wall runs the cell under the pointer at full rate); moves and the
        // cursor while inspecting or arranging.
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        if inspecting || arrangeable { options.formUnion([.mouseMoved, .cursorUpdate]) }
        let t = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(t)
        tracking = t
        if !inspecting { outlined = nil }
        if !arrangeable { hovering = false }
    }

    /// The pointer came onto the view (true) or left it (false).
    var onHover: ((SimulatorView, Bool) -> Void)?

    private func point(_ event: NSEvent) {
        guard let f = fraction(event), let size = simulator?.deviceSize, pictureRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPoint?(Int(f.x * size.width), Int(f.y * size.height))
    }

    override func mouseMoved(with event: NSEvent) {
        if inspecting { point(event); return }
        if arrangeable {
            if !hovering { arranger?.refreshHover() }
            cursor(at: convert(event.locationInWindow, from: nil)).set()
        }
    }

    /// The resize grip's area, less the screen: a touch on the screen's corner stays a touch.
    private func onGrip(_ p: CGPoint) -> Bool { gripRect.contains(p) && !pictureRect.contains(p) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard arrangeable, arranger?.isArranged == true, let superview else { return super.hitTest(point) }
        return bodyRect.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?(self)
        if inspecting { point(event); return }
        let p = convert(event.locationInWindow, from: nil)
        if arrangeable { arranger?.raise(self) }
        if arrangeable, onGrip(p) || !pictureRect.contains(p) {
            pressed = (event, p, onGrip(p))
            if pressed!.resizing { cursor(at: p).set() }
            return
        }
        guard pictureRect.contains(p) else { return }
        touching = true
        touch("down", event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let press = pressed, arranging == nil {
            let p = convert(event.locationInWindow, from: nil)
            guard hypot(p.x - press.at.x, p.y - press.at.y) >= 3 else { return }
            arranging = press.resizing ? .resize : .move
            cursor(at: p).set()
            arranger?.beginArranging(self, at: press.event, resizing: press.resizing)
        }
        if arranging != nil { arranger?.continueArranging(self, at: event); return }
        if touching { touch("move", event) }
    }

    override func mouseUp(with event: NSEvent) {
        if pressed != nil, arranging == nil { pressed = nil; return }   // a click on the body: chosen, nothing moved
        pressed = nil
        if arranging != nil {
            arranging = nil
            arranger?.endArranging(self)
            cursor(at: convert(event.locationInWindow, from: nil)).set()
            updateChips()
            return
        }
        if touching { touch("up", event); touching = false }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let f = fraction(event) else { return }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 24 : event.scrollingDeltaY
        if dy != 0 { emit(.wheel(f, dy)) }
    }

    private static let keys: [UInt16: String] = [
        51: "DEL", 117: "FORWARD_DEL", 36: "ENTER", 76: "ENTER", 48: "TAB", 53: "ESCAPE",
        123: "DPAD_LEFT", 124: "DPAD_RIGHT", 125: "DPAD_DOWN", 126: "DPAD_UP",
        115: "MOVE_HOME", 119: "MOVE_END", 116: "PAGE_UP", 121: "PAGE_DOWN",
    ]

    override func keyDown(with event: NSEvent) {
        guard simulator != nil else { return }
        let flags = event.modifierFlags
        if flags.contains(.command) { super.keyDown(with: event); return }
        if let name = Self.keys[event.keyCode] {
            if name == "ESCAPE" { emit(.command("back")); return }
            var command = "key \(name) 1"
            if flags.contains(.shift) { command += " shift" }
            if flags.contains(.option) || flags.contains(.control) { command += " ctrl" }   // Option: by word, as the engine's own window maps it
            emit(.command(command))
        } else if flags.contains(.control), let c = event.charactersIgnoringModifiers?.uppercased(), c.count == 1,
                  c.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
            emit(.command("key \(c) 1 ctrl"))
        } else if let text = event.characters, !text.isEmpty {
            emit(.text(text))
        }
    }

    /// ⌘V: the Mac clipboard's text, typed into the app.
    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { emit(.text(text)) }
    }
}

/// The close button: never takes a click on the device's screen (`blocked`), which it slightly overlaps.
final class CornerButton: NSButton {
    var blocked = CGRect.zero
    override func hitTest(_ point: NSPoint) -> NSView? { blocked.contains(point) ? nil : super.hitTest(point) }
}

/// An image that lets clicks through to the view under it (the resize grip: the device's view handles the drag).
final class ChipImage: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
