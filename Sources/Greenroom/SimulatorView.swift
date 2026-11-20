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
    var showsCaption = false { didSet { caption.isHidden = !showsCaption; needsLayout = true } }
    var isChosen = false { didSet { updateOutline() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.clear.cgColor
        display.cornerRadius = 14
        display.masksToBounds = true
        layer?.addSublayer(display)

        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        caption.isHidden = true
        addSubview(caption)
        display.borderColor = NSColor.controlAccentColor.cgColor
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

    private func updateCaption() {
        guard let sim = simulator else { caption.stringValue = ""; return }
        let size = sim.deviceSize
        caption.stringValue = size.width > 0 ? "\(sim.name) · \(Int(size.width))×\(Int(size.height))" : sim.name
    }

    private func updateOutline() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        display.borderWidth = isChosen && showsCaption ? 2 : 0
        CATransaction.commit()
    }

    private func emit(_ input: SimulatorInput) {
        if let route { route(input, self) } else { simulator?.perform(input) }
    }

    /// Where the picture is drawn: the device's shape fitted into the view with a margin.
    private var pictureRect: CGRect {
        let size = simulator?.deviceSize ?? .zero
        var area = bounds.insetBy(dx: showsCaption ? 12 : 20, dy: showsCaption ? 12 : 20)
        if showsCaption { area.size.height -= 22 }
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return area }
        let scale = min(area.width / size.width, area.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A flipped, layer-backed view's sublayers use its flipped coordinates.
        let r = pictureRect
        display.frame = r
        CATransaction.commit()
        caption.frame = CGRect(x: 8, y: r.maxY + 6, width: bounds.width - 16, height: 16)
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?(self)
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
