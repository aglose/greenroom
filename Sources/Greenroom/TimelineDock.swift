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

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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

    // The tracks are shape layers the GPU composites, one per colour, their paths replaced at each redraw: nothing is
    // painted on the CPU, and no picture of the whole area is kept (a drawn view held ~130 MB of backing stores).
    private var built = false
    private var shapes: [String: CAShapeLayer] = [:]
    private var labels: [CATextLayer] = []
    private var axis: [CATextLayer] = []
    private static let failed = NSColor(srgbRed: 1, green: 0.48, blue: 0.44, alpha: 1)
    private static let request = NSColor(srgbRed: 0.5, green: 0.72, blue: 1, alpha: 1)

    private func shape(_ key: String, _ color: NSColor) -> CAShapeLayer {
        if let l = shapes[key] { return l }
        let l = CAShapeLayer()
        l.fillColor = color.cgColor
        l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(l)
        shapes[key] = l
        return l
    }

    private func text(_ s: String) -> CATextLayer {
        let t = CATextLayer()
        t.string = s
        t.font = NSFont.systemFont(ofSize: 12)
        t.fontSize = 12
        t.foregroundColor = Design.mute.cgColor
        t.contentsScale = window?.backingScaleFactor ?? 2
        t.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        layer?.addSublayer(t)
        return t
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let host = layer else { return }
        if !built {
            built = true
            // Order is drawing order: wells, then marks, then the playhead on top.
            _ = shape("well", Design.well)
            for (i, _) in [0.25, 0.45, 0.65, 0.85].enumerated() { _ = shape("frames\(i)", Design.accent.withAlphaComponent([0.25, 0.45, 0.65, 0.85][i])) }
            _ = shape("touch", Design.ink)
            _ = shape("req", Self.request)
            _ = shape("reqFailed", Self.failed)
            _ = shape("reqMocked", Design.difference)
            _ = shape("logE", Self.failed)
            _ = shape("logW", Design.warning)
            _ = shape("logI", Design.mute.withAlphaComponent(0.6))
            _ = shape("playhead", Design.accent)
            labels = Self.names.map { text($0) }
            axis = (0...4).map { _ in text("") }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let now = isLive ? Date() : end
        if isLive { end = now; playhead = now }
        let a = trackArea
        let rowH = (a.height - 18) / 4
        func row(_ i: Int) -> CGRect {
            // A flipped, layer-backed view's sublayers use its flipped coordinates: rows count from the top.
            CGRect(x: a.minX, y: a.minY + CGFloat(i) * (rowH + 6), width: a.width, height: rowH)
        }
        let wells = CGMutablePath()
        for i in 0..<4 {
            let r = row(i)
            wells.addRounded(r, radius: 6)
            labels[i].frame = CGRect(x: 0, y: r.midY - 8, width: labelWidth - 6, height: 16)
        }
        shapes["well"]?.path = wells
        let from = now.addingTimeInterval(-span)
        func px(_ t: Date) -> CGFloat { a.minX + CGFloat(1 - now.timeIntervalSince(t) / span) * a.width }
        let activity = self.activity
        // Touches.
        let touches = CGMutablePath(), tr = row(0)
        for t in activity?.touches ?? [] where t >= from && t <= now {
            touches.addRounded(CGRect(x: px(t) - 2, y: tr.minY + tr.height * 0.25, width: 4, height: tr.height * 0.5), radius: 2)
        }
        shapes["touch"]?.path = touches
        // Frames: how many in each sliver of time, as one of four strengths of green.
        let fr = row(1)
        let buckets = max(1, Int(fr.width / 3))
        var counts = [Int](repeating: 0, count: buckets)
        for t in activity?.frames ?? [] where t >= from && t <= now {
            let i = Int(CGFloat(1 - now.timeIntervalSince(t) / span) * CGFloat(buckets))
            if i >= 0, i < buckets { counts[i] += 1 }
        }
        let perBucket = max(1, span / Double(buckets) * 120)
        let levels = (0..<4).map { _ in CGMutablePath() }
        for (i, c) in counts.enumerated() where c > 0 {
            let level = min(3, Int(Double(c) / perBucket * 4))
            levels[level].addRect(CGRect(x: fr.minX + CGFloat(i) * 3, y: fr.minY + 4, width: 2, height: fr.height - 8))
        }
        for i in 0..<4 { shapes["frames\(i)"]?.path = levels[i] }
        // Requests.
        let nr = row(2)
        let ok = CGMutablePath(), bad = CGMutablePath(), mocked = CGMutablePath()
        for e in activity?.requests ?? [] where e.end >= from && e.start <= now {
            let x0 = px(e.start), x1 = max(x0 + 3, px(e.end))
            let r = CGRect(x: x0, y: nr.minY + nr.height * 0.25, width: x1 - x0, height: nr.height * 0.5)
            (e.failed ? bad : e.mocked ? mocked : ok).addRounded(r, radius: 3)
        }
        shapes["req"]?.path = ok
        shapes["reqFailed"]?.path = bad
        shapes["reqMocked"]?.path = mocked
        // Log lines.
        let lr = row(3)
        let le = CGMutablePath(), lw = CGMutablePath(), li = CGMutablePath()
        for m in activity?.logs ?? [] where m.time >= from && m.time <= now {
            let x = px(m.time)
            switch m.level {
            case "E", "F": le.addRect(CGRect(x: x - 1, y: lr.midY - lr.height * 0.35, width: 2, height: lr.height * 0.7))
            case "W": lw.addRect(CGRect(x: x - 1, y: lr.midY - lr.height * 0.25, width: 2, height: lr.height * 0.5))
            default: li.addRect(CGRect(x: x - 1, y: lr.midY - lr.height * 0.175, width: 2, height: lr.height * 0.35))
            }
        }
        shapes["logE"]?.path = le
        shapes["logW"]?.path = lw
        shapes["logI"]?.path = li
        // The playhead: a line and a knob, red while paused.
        let x = px(playhead)
        let head = CGMutablePath()
        head.addRect(CGRect(x: x - 1, y: a.minY - 2, width: 2, height: a.height - 14))
        head.addEllipse(in: CGRect(x: x - 5, y: a.minY - 6, width: 10, height: 10))
        shapes["playhead"]?.path = head
        shapes["playhead"]?.fillColor = (isLive ? Design.accent : Design.record).cgColor
        // The axis.
        for (k, s) in stride(from: 0, through: Int(span), by: 15).enumerated() where k < axis.count {
            let t = now.addingTimeInterval(-Double(Int(span) - s))
            let label = s == Int(span) ? (isLive ? "now" : "") : "−\(Int(span) - s) s"
            axis[k].string = label
            let w: CGFloat = 50
            axis[k].frame = CGRect(x: min(max(px(t) - w / 2, a.minX), a.maxX - w), y: host.bounds.height - 16, width: w, height: 16)
            axis[k].alignmentMode = k == 0 ? .left : (k == axis.count - 1 ? .right : .center)
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
