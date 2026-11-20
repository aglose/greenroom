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
        let size = deviceSize
        func px(_ f: CGPoint) -> (CGFloat, CGFloat) {
            (min(max(f.x * size.width, 0), max(size.width - 1, 0)), min(max(f.y * size.height, 0), max(size.height - 1, 0)))
        }
        switch input {
        case .touch(let kind, let f):
            guard size.width > 0 else { return }
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

    override init(frame: NSRect) {
        super.init(frame: frame)
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
        for l in [ringLayer, rimLayer, bezelLayer, display, hingeLayer, cameraLayer] { layer?.addSublayer(l) }

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
        guard let sim else { return }
        let renderer = display.sampleBufferRenderer
        sim.onSample = { [weak self, weak sim] sample in
            if renderer.status == .failed {
                renderer.flush()
                sim?.requestKeyframe()
            }
            renderer.enqueue(sample)
            DispatchQueue.main.async { if self?.message.stringValue.isEmpty == false { self?.message.stringValue = "" } }
        }
        sim.onSize = { [weak self] _ in self?.needsLayout = true; self?.updateCaption() }
        updateCaption()
        sim.requestKeyframe()
        sim.send("redraw")
        needsLayout = true
        window?.makeFirstResponder(self)
    }

    func setMessage(_ text: String) { message.stringValue = text }

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
        let s = simulator?.deviceSize ?? .zero
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
        var rest = "   \(sim.name)"
        if size.width > 0 { rest += "   \(Int(size.width))×\(Int(size.height))" }
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
        let size = simulator?.deviceSize ?? .zero
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
        CATransaction.setDisableActions(true)
        // A flipped, layer-backed view's sublayers use its flipped coordinates.
        let r = pictureRect
        display.frame = r
        let hasDevice = simulator != nil && (simulator?.deviceSize.width ?? 0) > 0
        let b = bezel(forShortSide: min(r.width, r.height))
        let screenR = screenRadius(r)
        display.cornerRadius = screenR
        let bezelRect = r.insetBy(dx: -b, dy: -b)
        bezelLayer.frame = bezelRect
        bezelLayer.cornerRadius = body == .watch ? bezelRect.width / 2 : screenR + b
        let rimRect = bezelRect.insetBy(dx: -3, dy: -3)
        rimLayer.frame = rimRect
        rimLayer.cornerRadius = body == .watch ? rimRect.width / 2 : screenR + b + 3
        rimLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: rimRect.size), cornerWidth: rimLayer.cornerRadius, cornerHeight: rimLayer.cornerRadius, transform: nil)
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
        for l in [rimLayer, bezelLayer, cameraLayer, hingeLayer] as [CALayer] { l.isHidden = !hasDevice }
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
        updateOutline()
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
        tracking = nil
        if inspecting {
            let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(t)
            tracking = t
        } else {
            outlined = nil
        }
    }

    private func point(_ event: NSEvent) {
        guard let f = fraction(event), let size = simulator?.deviceSize, pictureRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPoint?(Int(f.x * size.width), Int(f.y * size.height))
    }

    override func mouseMoved(with event: NSEvent) { if inspecting { point(event) } }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?(self)
        if inspecting { point(event); return }
        guard pictureRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        touching = true
        touch("down", event)
    }

    override func mouseDragged(with event: NSEvent) { if touching { touch("move", event) } }

    override func mouseUp(with event: NSEvent) {
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
