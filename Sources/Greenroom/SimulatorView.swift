import AppKit
import AVFoundation

/// Shows one simulator's screen, fitted into the view, and sends the mouse, scroll wheel and keyboard to it.
/// Positions go to the engine in device pixels, whatever size the picture is drawn at.
final class SimulatorView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    private let message = NSTextField(labelWithString: "")
    private(set) var simulator: Simulator?
    private var touching = false

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
        sim.onSize = { [weak self] _ in self?.needsLayout = true }
        sim.requestKeyframe()
        sim.send("redraw")
        needsLayout = true
        window?.makeFirstResponder(self)
    }

    func setMessage(_ text: String) { message.stringValue = text }

    /// Where the picture is drawn: the device's shape fitted into the view with a margin.
    private var pictureRect: CGRect {
        let size = simulator?.deviceSize ?? .zero
        let area = bounds.insetBy(dx: 20, dy: 20)
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return area }
        let scale = min(area.width / size.width, area.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer tree is not flipped; the view is.
        let r = pictureRect
        display.frame = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
        CATransaction.commit()
    }

    private func devicePoint(_ event: NSEvent) -> CGPoint? {
        guard let size = simulator?.deviceSize, size.width > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let r = pictureRect
        guard r.width > 0 else { return nil }
        let x = (p.x - r.minX) / r.width * size.width, y = (p.y - r.minY) / r.height * size.height
        return CGPoint(x: min(max(x, 0), size.width - 1), y: min(max(y, 0), size.height - 1))
    }

    private func touch(_ kind: String, _ event: NSEvent) {
        guard let p = devicePoint(event) else { return }
        simulator?.send(String(format: "touch %@ %.1f %.1f", kind, p.x, p.y))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard pictureRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        touching = true
        touch("down", event)
    }

    override func mouseDragged(with event: NSEvent) { if touching { touch("move", event) } }

    override func mouseUp(with event: NSEvent) {
        if touching { touch("up", event); touching = false }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let p = devicePoint(event) else { return }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 24 : event.scrollingDeltaY
        if dy != 0 { simulator?.send(String(format: "wheel %.1f %.1f %.3f", p.x, p.y, dy)) }
    }

    private static let keys: [UInt16: String] = [
        51: "DEL", 117: "FORWARD_DEL", 36: "ENTER", 76: "ENTER", 48: "TAB", 53: "ESCAPE",
        123: "DPAD_LEFT", 124: "DPAD_RIGHT", 125: "DPAD_DOWN", 126: "DPAD_UP",
        115: "MOVE_HOME", 119: "MOVE_END", 116: "PAGE_UP", 121: "PAGE_DOWN",
    ]

    override func keyDown(with event: NSEvent) {
        guard let sim = simulator else { return }
        let flags = event.modifierFlags
        if flags.contains(.command) { super.keyDown(with: event); return }
        if let name = Self.keys[event.keyCode] {
            if name == "ESCAPE" { sim.send("back"); return }
            var command = "key \(name) 1"
            if flags.contains(.shift) { command += " shift" }
            if flags.contains(.option) { command += " ctrl" }   // by word, as the engine's own window maps it
            if flags.contains(.control) { command += " ctrl" }
            sim.send(command)
        } else if flags.contains(.control), let c = event.charactersIgnoringModifiers?.uppercased(), c.count == 1,
                  c.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
            sim.send("key \(c) 1 ctrl")
        } else if let text = event.characters, !text.isEmpty {
            sim.type(text)
        }
    }

    /// ⌘V: the Mac clipboard's text, typed into the app.
    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { simulator?.type(text) }
    }
}
