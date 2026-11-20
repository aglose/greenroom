import AppKit

/// The last minute of one simulator on four tracks (touches, frames drawn, requests, log lines), live, with a
/// playhead that can be dragged back to a moment; the network pane follows it to the request made then.
final class TimelineDock: NSView {
    private let glass = GlassView(radius: 18)
    private let tracks = TimelineTracks()
    private let state = NSTextField(labelWithString: "Live")
    private var liveButton: GlassButton!
    private(set) var saveButton: GlassButton!
    private var timer: Timer?
    /// Called with the moment under the playhead when the person drags it.
    var onScrub: ((Date) -> Void)? { get { tracks.onScrub } set { tracks.onScrub = newValue } }
    var onSave: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        let title = NSTextField(labelWithString: "Timeline")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Design.ink
        state.font = .systemFont(ofSize: 12, weight: .semibold)
        let hint = NSTextField(labelWithString: "Drag to look back")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = Design.mute
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        liveButton = GlassButton(symbol: nil, title: "Back to live", label: "Follow the present again", style: .accent, target: self, action: #selector(backToLive(_:)))
        saveButton = GlassButton(symbol: "square.and.arrow.down", title: "Save recording", label: "Save what the flight recorder holds", style: .well, target: self, action: #selector(save(_:)))
        let close = GlassButton(symbol: "chevron.down", label: "Hide the timeline", target: self, action: #selector(closeDock(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [title, state, hint, spacer, liveButton, saveButton, close])
        head.spacing = 10
        head.setCustomSpacing(6, after: title)
        for v in [glass, head, tracks] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            head.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            tracks.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 8),
            tracks.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            tracks.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            tracks.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        tracks.onPause = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func follow(_ sim: Simulator?) {
        tracks.activity = sim?.activity
        tracks.goLive()
        refresh()
    }

    /// Redraws a few times a second while shown and following the present.
    func setShown(_ on: Bool) {
        timer?.invalidate()
        timer = on ? Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.tracks.isLive else { return }
            self.tracks.needsDisplay = true
        } : nil
        if on { tracks.needsDisplay = true }
    }

    /// Moves the playhead to a moment (a request picked in the network pane).
    func show(_ time: Date) {
        tracks.pause(at: time)
        refresh()
    }

    var isLive: Bool { tracks.isLive }

    private func refresh() {
        if tracks.isLive {
            state.stringValue = "● Live"
            state.textColor = Design.accent
        } else {
            let back = max(0, Date().timeIntervalSince(tracks.playhead))
            state.stringValue = String(format: "Paused, %.1f s ago", back)
            state.textColor = NSColor(srgbRed: 1, green: 0.70, blue: 0.68, alpha: 1)
        }
        liveButton.isHidden = tracks.isLive
        tracks.needsDisplay = true
    }

    @objc private func backToLive(_ sender: Any?) { tracks.goLive(); refresh() }
    @objc private func save(_ sender: Any?) { onSave?() }
    @objc private func closeDock(_ sender: Any?) { onClose?() }
}

/// The tracks themselves: a window of time ending now (live) or where the person stopped it.
final class TimelineTracks: NSView {
    var activity: Activity?
    var onScrub: ((Date) -> Void)?
    var onPause: (() -> Void)?
    private(set) var isLive = true
    private var end = Date()
    private(set) var playhead = Date()
    private let span: TimeInterval = 60
    private let labelWidth: CGFloat = 70
    private static let names = ["Touches", "Frames", "Network", "Log"]

    override var isFlipped: Bool { true }

    func goLive() { isLive = true; needsDisplay = true }

    func pause(at time: Date) {
        if isLive || time > end || time < end.addingTimeInterval(-span) {
            // Keep the moment in view: the window ends a little after it, but never in the future.
            end = min(Date(), max(time.addingTimeInterval(span * 0.25), isLive ? Date() : end))
        }
        isLive = false
        playhead = time
        needsDisplay = true
        onPause?()
    }

    private var trackArea: NSRect { NSRect(x: labelWidth, y: 0, width: bounds.width - labelWidth, height: bounds.height - 18) }

    private func x(_ t: Date, now: Date) -> CGFloat {
        let a = trackArea
        return a.minX + CGFloat(1 - now.timeIntervalSince(t) / span) * a.width
    }

    private func time(atX px: CGFloat) -> Date {
        let a = trackArea
        let f = min(max((px - a.minX) / a.width, 0), 1)
        return end.addingTimeInterval(-span * Double(1 - f))
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = isLive ? Date() : end
        if isLive { end = now; playhead = now }
        let a = trackArea
        let rowH = (a.height - 18) / 4
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Design.mute]
        func row(_ i: Int) -> NSRect { NSRect(x: a.minX, y: a.minY + CGFloat(i) * (rowH + 6), width: a.width, height: rowH) }
        for (i, name) in Self.names.enumerated() {
            let r = row(i)
            (name as NSString).draw(at: NSPoint(x: 0, y: r.midY - 8), withAttributes: label)
            Design.well.setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
        let from = now.addingTimeInterval(-span)
        guard let activity else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: a).addClip()

        // Touches: a tick for each.
        Design.ink.setFill()
        let touch = row(0)
        for t in activity.touches where t >= from && t <= now {
            NSBezierPath(roundedRect: NSRect(x: x(t, now: now) - 2, y: touch.minY + touch.height * 0.25, width: 4, height: touch.height * 0.5), xRadius: 2, yRadius: 2).fill()
        }
        // Frames: how many were drawn in each sliver of time, as the strength of the green.
        let frames = row(1)
        let buckets = max(1, Int(frames.width / 3))
        var counts = [Int](repeating: 0, count: buckets)
        for t in activity.frames where t >= from && t <= now {
            let i = Int(CGFloat(1 - now.timeIntervalSince(t) / span) * CGFloat(buckets))
            if i >= 0, i < buckets { counts[i] += 1 }
        }
        let perBucket = max(1, span / Double(buckets) * 120)
        for (i, c) in counts.enumerated() where c > 0 {
            Design.accent.withAlphaComponent(min(0.9, 0.2 + CGFloat(Double(c) / perBucket))).setFill()
            NSRect(x: frames.minX + CGFloat(i) * 3, y: frames.minY + 4, width: 2, height: frames.height - 8).fill()
        }
        // Requests: a bar from start to end, red when it failed.
        let net = row(2)
        for e in activity.requests where e.end >= from && e.start <= now {
            let x0 = x(e.start, now: now), x1 = max(x0 + 3, x(e.end, now: now))
            let color = e.failed ? NSColor(srgbRed: 1, green: 0.48, blue: 0.44, alpha: 1) : e.mocked ? Design.difference : NSColor(srgbRed: 0.5, green: 0.72, blue: 1, alpha: 1)
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x0, y: net.minY + net.height * 0.25, width: x1 - x0, height: net.height * 0.5), xRadius: 3, yRadius: 3).fill()
        }
        // Log lines: errors red and tall, warnings yellow, the rest grey.
        let log = row(3)
        for m in activity.logs where m.time >= from && m.time <= now {
            let (color, h): (NSColor, CGFloat) = m.level == "E" || m.level == "F" ? (NSColor(srgbRed: 1, green: 0.48, blue: 0.44, alpha: 1), 0.7)
                : m.level == "W" ? (Design.warning, 0.5) : (Design.mute.withAlphaComponent(0.6), 0.35)
            color.setFill()
            NSRect(x: x(m.time, now: now) - 1, y: log.midY - log.height * h / 2, width: 2, height: log.height * h).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // The playhead, and the axis.
        let px = x(playhead, now: now)
        let line = NSRect(x: px - 1, y: a.minY - 2, width: 2, height: a.height - 14)
        (isLive ? Design.accent : Design.record).setFill()
        line.fill()
        NSBezierPath(ovalIn: NSRect(x: px - 5, y: a.minY - 6, width: 10, height: 10)).fill()
        for s in stride(from: 0, through: Int(span), by: 15) {
            let t = now.addingTimeInterval(-Double(Int(span) - s))
            let text = s == Int(span) ? (isLive ? "now" : "") : "−\(Int(span) - s) s"
            let size = (text as NSString).size(withAttributes: label)
            let tx = min(max(x(t, now: now) - size.width / 2, a.minX), a.maxX - size.width)
            (text as NSString).draw(at: NSPoint(x: tx, y: bounds.height - 16), withAttributes: label)
        }
    }

    override func mouseDown(with event: NSEvent) { scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }

    private func scrub(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if isLive { end = Date() }
        isLive = false
        playhead = time(atX: p.x)
        needsDisplay = true
        onPause?()
        onScrub?(playhead)
    }
}
