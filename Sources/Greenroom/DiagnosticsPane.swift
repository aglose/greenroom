import AppKit

/// What the engine can tell about the running app, in cards on glass: performance (live numbers and the last
/// minute as sparklines), an accessibility audit that outlines its findings on the device picture, background
/// work, the clipboard and the device skin. Sampling runs once a second, only while the pane is shown, a device is
/// followed and the window is not minimised; every command is an asynchronous control-channel call.
final class DiagnosticsPane: NSView {
    // MARK: Hooks (Workbench)
    /// Every running simulator, for the per-device fps chips.
    var devices: () -> [Simulator] = { [] }
    /// Boxes to draw on a simulator's picture, in device pixels (empty clears them).
    var onMarks: ((Simulator, [CGRect]) -> Void)?
    /// One box outlined on the picture (a finding being flashed), or none.
    var onOutline: ((Simulator, CGRect?) -> Void)?
    /// The text a device's caption appends (its live fps), or nil.
    var onChip: ((Simulator, String?) -> Void)?
    var onSay: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?
    private(set) weak var simulator: Simulator?
    /// "Show on devices": each device's caption shows its fps.
    private(set) var showOnDevices = false

    // MARK: Samples
    struct Metrics {
        var fps: Double?, p50: Double?, p95: Double?, pace: String?, screen: String?
        var heap: Double?, footprint: Double?, cpuMs: Double?, cpuPercent: Double?
    }
    private struct History {
        var fps: [Double] = [], p95: [Double] = [], footprint: [Double] = [], cpu: [Double] = []
        var last = Metrics()
        var lastCpuMs: Double?, lastAt: TimeInterval?
        var busy = false
        static func add(_ a: inout [Double], _ v: Double?) { if let v { a.append(v); if a.count > 60 { a.removeFirst(a.count - 60) } } }
    }
    private var histories: [ObjectIdentifier: History] = [:]
    private var timer: Timer?
    private var tick = 0

    // MARK: Views
    private let glass = GlassView(radius: 18)
    private let stack = NSStackView()
    private let answer = NSTextField(wrappingLabelWithString: "")
    private var answerTimer: Timer?
    private let chipButton = GlassButton(symbol: nil, title: "Show on devices", label: "Show each device's frame rate under it", style: .well, target: nil, action: nil)
    private var tiles: [String: NSTextField] = [:]
    private var charts: [String: (spark: Sparkline, value: NSTextField)] = [:]
    private let paceLabel = NSTextField(labelWithString: "")
    // Audit
    private let auditButton = GlassButton(symbol: "checklist", title: "Audit this screen", label: "Check this screen for unlabeled controls and small touch targets", style: .accent, target: nil, action: nil)
    private let auditSummary = NSTextField(wrappingLabelWithString: "Not run yet.")
    private let findingsStack = NSStackView()
    private(set) var findings: [Finding] = []
    private var auditSimulator: Simulator?
    private var auditSignature = ""
    private var flashTimers: [Timer] = []
    // Background work
    private let backgroundStack = NSStackView()
    // Clipboard
    private let clipboardText = NSTextField(wrappingLabelWithString: "")
    private let clipboardField = NSTextField()
    // Skin
    private var skinCard: NSView!
    private let skinPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var skinHandler: DiagMenuHandler?

    struct Finding { let rect: CGRect; let text: String }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let title = NSTextField(labelWithString: "Diagnostics")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Design.ink
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        chipButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        chipButton.font = .systemFont(ofSize: 12, weight: .medium)
        chipButton.layer?.cornerRadius = 13
        chipButton.onPress = { [weak self] in self?.setShowOnDevices(!(self?.showOnDevices ?? false)) }
        let close = GlassButton(symbol: "xmark", label: "Close Diagnostics", style: .plain, target: self, action: #selector(closePressed))
        close.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let head = NSStackView(views: [title, spacer, chipButton, close])
        head.spacing = 8

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        buildCards()

        let doc = DiagFlipped()
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        doc.translatesAutoresizingMaskIntoConstraints = false
        let scrollFade = ScrollFadeOverlay(scrollView: scroll)
        answer.font = .systemFont(ofSize: 12)
        answer.textColor = Design.mute
        answer.maximumNumberOfLines = 2
        answer.alphaValue = 0
        for v in [head, scroll, scrollFade, answer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            head.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: answer.topAnchor, constant: -6),
            scrollFade.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            scrollFade.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            scrollFade.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            scrollFade.heightAnchor.constraint(equalToConstant: 26),
            answer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            answer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            answer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            answer.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Following

    /// Shows this simulator's numbers and starts sampling; nil stops, and takes every mark and chip off the stage.
    func follow(_ sim: Simulator?) {
        if sim !== simulator, let old = auditSimulator { clearAudit(on: old, message: "Not run yet.") }
        simulator = sim
        guard let sim else {
            stopSampling()
            for s in devices() { onChip?(s, nil) }
            return
        }
        if histories[ObjectIdentifier(sim)] == nil { histories[ObjectIdentifier(sim)] = History() }
        render(histories[ObjectIdentifier(sim)]!)
        startSampling()
        refreshBackground(); refreshClipboard(); refreshSkins()
    }

    private func startSampling() {
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopSampling() { timer?.invalidate(); timer = nil }

    var isSampling: Bool { timer != nil }

    func setShowOnDevices(_ on: Bool) {
        showOnDevices = on
        chipButton.isOn = on
        if on { sample() } else { for s in devices() { onChip?(s, nil) } }
    }

    // MARK: Sampling

    private func sample() {
        guard let window, !window.isMiniaturized, window.isVisible, let sim = simulator else { return }
        tick += 1
        var targets = [sim]
        if showOnDevices { targets += devices().filter { $0 !== sim && $0.state == .running } }
        for s in targets where s.state == .running { sample(s, full: s === sim) }
        if hasMarks, tick % 2 == 0 { recheckAudit() }
    }

    private var hasMarks: Bool { !findings.isEmpty && auditSimulator != nil }

    private func sample(_ sim: Simulator, full: Bool) {
        let id = ObjectIdentifier(sim)
        var h = histories[id] ?? History()
        guard !h.busy else { return }
        h.busy = true
        histories[id] = h
        let group = DispatchGroup()
        var framesReply = "", statsReply = ""
        group.enter(); sim.send("frames") { framesReply = $0; group.leave() }
        if full { group.enter(); sim.send("stats") { statsReply = $0; group.leave() } }
        group.notify(queue: .main) { [weak self, weak sim] in
            guard let self, let sim else { return }
            var h = self.histories[id] ?? History()
            h.busy = false
            var m = Self.parseFrames(framesReply)
            if full {
                let s = Self.parseStats(statsReply)
                m.heap = s["heapUsedMb"]; m.footprint = s["footprintMb"]; m.cpuMs = s["cpuMs"]
                let now = ProcessInfo.processInfo.systemUptime
                if let c = m.cpuMs, let prev = h.lastCpuMs, let at = h.lastAt, now > at { m.cpuPercent = max(0, (c - prev) / ((now - at) * 1000) * 100) }
                h.lastCpuMs = m.cpuMs; h.lastAt = now
                History.add(&h.fps, m.fps ?? 0); History.add(&h.p95, m.p95); History.add(&h.footprint, m.footprint); History.add(&h.cpu, m.cpuPercent)
            } else {
                History.add(&h.fps, m.fps ?? 0)
            }
            h.last = m
            self.histories[id] = h
            if self.showOnDevices { self.onChip?(sim, Self.chip(m)) }
            if full, sim === self.simulator { self.render(h) }
        }
    }

    /// `frames=343 avg=120.2 fps, interval p50=8.3ms p95=10.9ms p99=12.3ms max=14.5ms; on 120 Hz pace: 79% | screen: headless | ...`
    /// or `no frames | screen: ...` when nothing was drawn since the last call.
    static func parseFrames(_ reply: String) -> Metrics {
        var m = Metrics()
        let parts = reply.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = parts.first else { return m }
        func num(_ pattern: String, in text: String) -> Double? {
            guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
            return Double(text[r].split(separator: "=").last ?? "")
        }
        if first.hasPrefix("no frames") { m.fps = 0 } else {
            m.fps = num(#"avg=[\d.]+"#, in: first)
            m.p50 = num(#"p50=[\d.]+"#, in: first)
            m.p95 = num(#"p95=[\d.]+"#, in: first)
            if let r = first.range(of: #"pace: \d+%"#, options: .regularExpression) { m.pace = String(first[r].dropFirst(6)) }
        }
        if let s = parts.first(where: { $0.hasPrefix("screen:") }) {
            let text = s.dropFirst(7).trimmingCharacters(in: .whitespaces)
            if text != "headless" { m.screen = text }
        }
        return m
    }

    static func parseStats(_ reply: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for token in reply.split(separator: " ") {
            let kv = token.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let v = Double(kv[1]) { out[String(kv[0])] = v }
        }
        return out
    }

    private static func chip(_ m: Metrics) -> String? {
        guard let f = m.fps else { return nil }
        return f > 0 ? String(format: "%.0f fps", f) : "idle"
    }

    private func render(_ h: History) {
        let m = h.last
        func set(_ key: String, _ text: String) { if tiles[key]?.stringValue != text { tiles[key]?.stringValue = text } }
        set("fps", m.fps.map { $0 > 0 ? String(format: "%.0f", $0) : "idle" } ?? "–")
        set("p50", m.p50.map { String(format: "%.1f ms", $0) } ?? "–")
        set("p95", m.p95.map { String(format: "%.1f ms", $0) } ?? "–")
        set("heap", m.heap.map { String(format: "%.0f MB", $0) } ?? "–")
        set("footprint", m.footprint.map { String(format: "%.0f MB", $0) } ?? "–")
        set("cpu", m.cpuMs.map { String(format: "%.1f s", $0 / 1000) } ?? "–")
        let pace = [m.pace.map { "On pace \($0)" }, m.screen.map { "Screen: \($0)" }].compactMap { $0 }.joined(separator: "   ")
        if paceLabel.stringValue != pace { paceLabel.stringValue = pace }
        chart("fps", h.fps, m.fps.map { $0 > 0 ? String(format: "%.0f fps", $0) : "idle" })
        chart("p95", h.p95, m.p95.map { String(format: "%.1f ms", $0) })
        chart("footprint", h.footprint, m.footprint.map { String(format: "%.0f MB", $0) })
        chart("cpu", h.cpu, m.cpuPercent.map { String(format: "%.0f%%", $0) })
    }

    private func chart(_ key: String, _ values: [Double], _ text: String?) {
        guard let c = charts[key] else { return }
        c.spark.values = values
        let t = text ?? "–"
        if c.value.stringValue != t { c.value.stringValue = t }
    }

    // MARK: Accessibility audit

    /// Runs the engine's audit and shows the findings, outlined on the picture.
    func audit() {
        guard let sim = simulator, sim.state == .running else { onSay?("No device is running", true); return }
        auditButton.isEnabled = false
        auditSummary.stringValue = "Checking…"
        auditSummary.textColor = Design.mute
        sim.send("a11y") { [weak self, weak sim] reply in
            guard let self, let sim else { return }
            self.auditButton.isEnabled = true
            if reply.hasPrefix("error") {
                self.auditSummary.stringValue = reply.replacingOccurrences(of: "error: ", with: "")
                self.auditSummary.textColor = Design.warning
                return
            }
            let (summary, found) = Self.parseAudit(reply)
            if let old = self.auditSimulator, old !== sim { self.onMarks?(old, []) }
            self.auditSimulator = sim
            self.findings = found
            self.auditSignature = Self.signature(found)
            self.auditSummary.stringValue = summary
            self.auditSummary.textColor = found.isEmpty ? Design.accent : Design.warning
            self.showFindings()
            self.onMarks?(sim, found.map(\.rect))
        }
    }

    /// `3 issue(s) in 82 nodes: [686,208,790,304] control with no label (View) ; [..] touch target 126x27 dp, under 48 dp: View`
    /// or `no issues in 65 nodes`.
    static func parseAudit(_ reply: String) -> (String, [Finding]) {
        let line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = line.range(of: ": "), line.contains("issue") else { return (line.isEmpty ? "No answer" : line.prefix(1).uppercased() + line.dropFirst() + ".", []) }
        var head = String(line[..<colon.lowerBound])
        head = head.replacingOccurrences(of: "1 issue(s)", with: "1 issue")
        head = head.replacingOccurrences(of: "issue(s)", with: "issues")
        var found: [Finding] = []
        for item in line[colon.upperBound...].components(separatedBy: " ; ") {
            guard let r = item.range(of: #"^\s*\[(-?\d+),(-?\d+),(-?\d+),(-?\d+)\]\s*"#, options: .regularExpression) else { continue }
            let nums = item[r].split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            guard nums.count == 4 else { continue }
            found.append(Finding(rect: CGRect(x: nums[0], y: nums[1], width: max(nums[2] - nums[0], 1), height: max(nums[3] - nums[1], 1)),
                                 text: String(item[r.upperBound...]).trimmingCharacters(in: .whitespaces)))
        }
        return (head.prefix(1).uppercased() + head.dropFirst() + ".", found)
    }

    private static func signature(_ f: [Finding]) -> String { f.map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)),\(Int($0.rect.width)),\(Int($0.rect.height)) \($0.text)" }.joined(separator: "|") }

    /// While marks are up, the audit is asked again every other second: another list of findings means the screen
    /// changed under them, and they come off.
    private func recheckAudit() {
        guard let sim = auditSimulator, sim.state == .running else { return }
        let was = auditSignature
        sim.send("a11y") { [weak self, weak sim] reply in
            guard let self, let sim, self.auditSimulator === sim, !self.findings.isEmpty, !reply.hasPrefix("error") else { return }
            if Self.signature(Self.parseAudit(reply).1) != was { self.clearAudit(on: sim, message: "The screen changed. Audit again.") }
        }
    }

    private func clearAudit(on sim: Simulator, message: String) {
        flashTimers.forEach { $0.invalidate() }; flashTimers = []
        findings = []
        auditSimulator = nil
        auditSignature = ""
        auditSummary.stringValue = message
        auditSummary.textColor = Design.mute
        showFindings()
        onMarks?(sim, [])
        onOutline?(sim, nil)
    }

    private func showFindings() {
        for v in findingsStack.arrangedSubviews { findingsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, f) in findings.prefix(30).enumerated() {
            let b = GlassButton(symbol: nil, title: "", label: "Show this finding on the screen", style: .plain, target: nil, action: nil)
            b.heightAnchor.constraint(equalToConstant: 38).isActive = true
            let kind: String
            if f.text.contains("no label") { kind = "No label" } else if f.text.contains("touch target") { kind = "Small touch target" } else { kind = "Finding" }
            let detail = f.text.replacingOccurrences(of: "touch target ", with: "")
            b.attributedTitle = NSAttributedString(string: "")
            let titleLabel = NSTextField(labelWithString: kind)
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            titleLabel.textColor = Design.ink
            let detailLabel = NSTextField(labelWithString: "\(detail)   at \(Int(f.rect.minX)),\(Int(f.rect.minY))")
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = Design.mute
            detailLabel.lineBreakMode = .byTruncatingTail
            let col = NSStackView(views: [titleLabel, detailLabel])
            col.orientation = .vertical; col.alignment = .leading; col.spacing = 1
            col.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(col)
            NSLayoutConstraint.activate([col.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 8), col.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -8),
                                         col.centerYAnchor.constraint(equalTo: b.centerYAnchor)])
            b.onPress = { [weak self] in self?.flash(i) }
            findingsStack.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: findingsStack.widthAnchor).isActive = true
        }
        if findings.count > 30 {
            let more = NSTextField(labelWithString: "and \(findings.count - 30) more, all outlined on the screen")
            more.font = .systemFont(ofSize: 11); more.textColor = Design.mute
            findingsStack.addArrangedSubview(more)
        }
    }

    /// Blinks one finding's box on the picture.
    func flash(_ index: Int) {
        guard findings.indices.contains(index), let sim = auditSimulator else { return }
        flashTimers.forEach { $0.invalidate() }; flashTimers = []
        let rect = findings[index].rect
        let steps: [(Double, Bool)] = [(0, true), (0.16, false), (0.32, true), (0.48, false), (0.64, true), (1.8, false)]
        for (at, on) in steps {
            let t = Timer(timeInterval: at, repeats: false) { [weak self, weak sim] _ in if let sim { self?.onOutline?(sim, on ? rect : nil) } }
            RunLoop.main.add(t, forMode: .common)
            flashTimers.append(t)
        }
    }

    // MARK: Background work

    private func refreshBackground() {
        guard let sim = simulator, sim.state == .running else { return }
        for kind in ["jobs", "services", "alarms"] {
            sim.send(kind) { [weak self, weak sim] reply in
                guard let self, sim === self.simulator else { return }
                self.backgroundItems[kind] = Self.items(reply)
                self.rebuildBackground()
            }
        }
    }

    private var backgroundItems: [String: [String]] = [:]

    /// One list entry per line; the engine says `none` for an empty list.
    static func items(_ reply: String) -> [String] {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == "none" || t.hasPrefix("error") { return [] }
        return t.components(separatedBy: "; ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func jobID(_ line: String) -> Int? {
        for pattern in [#"(?i)job\W{0,3}(\d+)"#, #"^\W{0,2}(\d+)"#, #"#(\d+)"#] {
            if let r = line.range(of: pattern, options: .regularExpression), let n = Int(line[r].filter(\.isNumber)) { return n }
        }
        return nil
    }

    private func rebuildBackground() {
        for v in backgroundStack.arrangedSubviews { backgroundStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for (kind, name) in [("jobs", "Jobs"), ("services", "Services"), ("alarms", "Alarms")] {
            let list = backgroundItems[kind] ?? []
            let head = NSTextField(labelWithString: "\(name)   \(list.count)")
            head.font = .systemFont(ofSize: 12, weight: .semibold)
            head.textColor = list.isEmpty ? Design.mute : Design.ink
            backgroundStack.addArrangedSubview(head)
            if list.isEmpty { continue }
            for line in list.prefix(12) {
                let label = NSTextField(wrappingLabelWithString: line)
                label.font = .systemFont(ofSize: 11)
                label.textColor = Design.mute
                label.maximumNumberOfLines = 2
                label.lineBreakMode = .byTruncatingTail
                label.setContentHuggingPriority(.init(1), for: .horizontal)
                var views: [NSView] = [label]
                if kind == "jobs", let id = Self.jobID(line) {
                    let run = GlassButton(symbol: "play.fill", title: "Run", label: "Run job \(id) now", style: .well, target: nil, action: nil)
                    run.heightAnchor.constraint(equalToConstant: 24).isActive = true
                    run.font = .systemFont(ofSize: 11, weight: .medium)
                    run.onPress = { [weak self] in self?.send("jobs run \(id)"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refreshBackground() } }
                    views.append(run)
                }
                let r = NSStackView(views: views)
                r.spacing = 8
                backgroundStack.addArrangedSubview(r)
                r.widthAnchor.constraint(equalTo: backgroundStack.widthAnchor).isActive = true
            }
        }
    }

    // MARK: Clipboard and skin

    private func refreshClipboard() {
        guard let sim = simulator, sim.state == .running else { return }
        sim.send("clipboard") { [weak self, weak sim] reply in
            guard let self, sim === self.simulator else { return }
            self.clipboardText.stringValue = reply == "(empty)" ? "Empty" : reply
            self.clipboardText.textColor = reply == "(empty)" ? Design.mute : Design.ink
        }
    }

    private func setClipboard() {
        let text = clipboardField.stringValue
        guard !text.isEmpty else { return }
        simulator?.send("clipboard set " + text.replacingOccurrences(of: "\n", with: " ")) { [weak self] reply in
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.show(answer: trimmed.lowercased() == "ok" ? "Clipboard updated" : reply)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refreshClipboard() }
    }

    private func refreshSkins() {
        guard let sim = simulator, sim.state == .running else { return }
        sim.send("skin") { [weak self, weak sim] reply in
            guard let self, sim === self.simulator else { return }
            let (current, stored) = Self.parseSkins(reply)
            self.skinCard.isHidden = stored.isEmpty
            self.skinPopup.removeAllItems()
            self.skinPopup.addItem(withTitle: "None"); self.skinPopup.lastItem?.representedObject = "off"
            for s in stored { self.skinPopup.addItem(withTitle: s); self.skinPopup.lastItem?.representedObject = s }
            let i = stored.firstIndex { current.hasPrefix($0) }.map { $0 + 1 } ?? 0
            self.skinPopup.selectItem(at: i)
        }
    }

    /// `off; stored: pixel-10-pro-fold`: the skin on now (or `off`) and the stored ones.
    static func parseSkins(_ reply: String) -> (String, [String]) {
        let line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.hasPrefix("error") else { return ("off", []) }
        let current = line.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? "off"
        var stored: [String] = []
        if let r = line.range(of: "stored:") {
            stored = line[r.upperBound...].components(separatedBy: CharacterSet(charactersIn: ",;")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "none" }
        }
        return (current, stored)
    }

    // MARK: Commands

    private func send(_ command: String) {
        simulator?.send(command) { [weak self] reply in self?.show(answer: reply) }
    }

    private func show(answer reply: String) {
        let failed = reply.hasPrefix("error") || reply.hasPrefix("no ")
        let text = reply.replacingOccurrences(of: "error: ", with: "")
        answer.stringValue = text.isEmpty ? "Done" : text
        answer.textColor = failed ? Design.warning : Design.mute
        answer.alphaValue = 1
        answerTimer?.invalidate()
        answerTimer = Timer.scheduledTimer(withTimeInterval: failed ? 6 : 3, repeats: false) { [weak self] _ in
            Design.animate(Design.arrive, { self?.answer.animator().alphaValue = 0 })
        }
    }

    // MARK: Cards

    private func buildCards() {
        // Performance: six numbers, four charts.
        func tile(_ key: String, _ name: String) -> NSView {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11)
            label.textColor = Design.mute
            let value = NSTextField(labelWithString: "–")
            value.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
            value.textColor = Design.ink
            tiles[key] = value
            let c = NSStackView(views: [label, value])
            c.orientation = .vertical; c.alignment = .leading; c.spacing = 1
            return c
        }
        let row1 = NSStackView(views: [tile("fps", "Frames a second"), tile("p50", "Frame time p50"), tile("p95", "Frame time p95")])
        let row2 = NSStackView(views: [tile("heap", "Heap in use"), tile("footprint", "Footprint"), tile("cpu", "CPU time")])
        for r in [row1, row2] { r.distribution = .fillEqually; r.spacing = 8 }
        paceLabel.font = .systemFont(ofSize: 11)
        paceLabel.textColor = Design.mute
        paceLabel.lineBreakMode = .byTruncatingTail
        func chartView(_ key: String, _ name: String, tint: NSColor, floor: Double = 0) -> NSView {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11); label.textColor = Design.mute
            let value = NSTextField(labelWithString: "–")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); value.textColor = Design.ink
            value.alignment = .right
            let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let top = NSStackView(views: [label, spacer, value])
            let spark = Sparkline()
            spark.tint = tint
            spark.floorTop = floor
            spark.heightAnchor.constraint(equalToConstant: 30).isActive = true
            charts[key] = (spark, value)
            let c = NSStackView(views: [top, spark])
            c.orientation = .vertical; c.alignment = .width; c.spacing = 3
            return c
        }
        let charts1 = NSStackView(views: [chartView("fps", "Frame rate", tint: Design.accent, floor: 60), chartView("p95", "Frame time p95", tint: Design.warning, floor: 16)])
        let charts2 = NSStackView(views: [chartView("footprint", "Footprint", tint: NSColor(srgbRed: 0.45, green: 0.62, blue: 1, alpha: 1)), chartView("cpu", "CPU, of one core", tint: Design.difference, floor: 100)])
        for r in [charts1, charts2] { r.distribution = .fillEqually; r.spacing = 10 }
        let note = NSTextField(labelWithString: "The last 60 seconds, sampled once a second while this pane is open.")
        note.font = .systemFont(ofSize: 11); note.textColor = Design.mute
        addCard(card("Performance", [row1, row2, paceLabel, charts1, charts2, note]))

        // Accessibility audit.
        auditButton.onPress = { [weak self] in self?.audit() }
        auditSummary.font = .systemFont(ofSize: 12)
        auditSummary.textColor = Design.mute
        auditSummary.maximumNumberOfLines = 2
        findingsStack.orientation = .vertical; findingsStack.alignment = .leading; findingsStack.spacing = 2
        let auditRow = NSStackView(views: [auditButton, auditSummary])
        auditRow.spacing = 10
        addCard(card("Accessibility", [auditRow, findingsStack]))

        // Background work.
        backgroundStack.orientation = .vertical; backgroundStack.alignment = .leading; backgroundStack.spacing = 4
        let refresh = GlassButton(symbol: "arrow.clockwise", title: "Refresh", label: "Ask the app for its jobs, services and alarms again", style: .well, target: nil, action: nil)
        refresh.heightAnchor.constraint(equalToConstant: 26).isActive = true
        refresh.font = .systemFont(ofSize: 12, weight: .medium)
        refresh.onPress = { [weak self] in self?.refreshBackground() }
        addCard(card("Background work", [backgroundStack, refresh]))
        backgroundItems = [:]
        rebuildBackground()

        // Clipboard.
        clipboardText.font = .systemFont(ofSize: 12)
        clipboardText.maximumNumberOfLines = 3
        clipboardText.lineBreakMode = .byTruncatingTail
        clipboardText.isSelectable = true
        clipboardText.stringValue = "Empty"
        clipboardField.placeholderString = "Text for the app's clipboard"
        clipboardField.font = .systemFont(ofSize: 12)
        clipboardField.bezelStyle = .roundedBezel
        clipboardField.target = self; clipboardField.action = #selector(clipboardEntered)
        let set = GlassButton(symbol: nil, title: "Set", label: "Put this text on the app's clipboard", style: .well, target: nil, action: nil)
        set.heightAnchor.constraint(equalToConstant: 26).isActive = true
        set.onPress = { [weak self] in self?.setClipboard() }
        let reload = GlassButton(symbol: "arrow.clockwise", label: "Read the app's clipboard again", style: .well, target: nil, action: nil)
        reload.heightAnchor.constraint(equalToConstant: 26).isActive = true
        reload.onPress = { [weak self] in self?.refreshClipboard() }
        let fieldRow = NSStackView(views: [clipboardField, set, reload])
        fieldRow.spacing = 6
        addCard(card("Clipboard", [clipboardText, fieldRow]))

        // Skin: only when the engine has any stored.
        skinPopup.controlSize = .regular
        skinPopup.bezelStyle = .push
        skinPopup.widthAnchor.constraint(equalToConstant: 196).isActive = true
        let handler = DiagMenuHandler { [weak self] v in self?.send("skin \(v)") }
        skinPopup.target = handler
        skinPopup.action = #selector(DiagMenuHandler.picked(_:))
        skinHandler = handler
        skinCard = card("Skin", [row("Frame around the screen", skinPopup)])
        skinCard.isHidden = true
        addCard(skinCard)
    }

    @objc private func clipboardEntered() { setClipboard() }
    @objc private func closePressed() { onClose?() }

    private func addCard(_ c: NSView) {
        stack.addArrangedSubview(c)
        c.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func card(_ title: String, _ rows: [NSView]) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = Design.well.cgColor
        box.layer?.cornerRadius = 12
        box.layer?.cornerCurve = .continuous
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Design.ink
        let column = NSStackView(views: [label] + rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        column.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(column)
        NSLayoutConstraint.activate([column.topAnchor.constraint(equalTo: box.topAnchor), column.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                                     column.leadingAnchor.constraint(equalTo: box.leadingAnchor), column.trailingAnchor.constraint(equalTo: box.trailingAnchor)])
        for r in rows { r.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24).isActive = true }
        return box
    }

    private func row(_ name: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Design.ink
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let r = NSStackView(views: [label, spacer, control])
        r.spacing = 8
        return r
    }

    // MARK: Scripted checks

    /// The latest numbers for the followed device (for checks).
    var latest: Metrics? { simulator.flatMap { histories[ObjectIdentifier($0)]?.last } }
    var sampleCount: Int { simulator.flatMap { histories[ObjectIdentifier($0)]?.fps.count } ?? 0 }
    var backgroundCounts: (jobs: Int, services: Int, alarms: Int) {
        (backgroundItems["jobs"]?.count ?? 0, backgroundItems["services"]?.count ?? 0, backgroundItems["alarms"]?.count ?? 0)
    }
    func refreshAll() { refreshBackground(); refreshClipboard(); refreshSkins() }
    func setClipboardForCheck(_ text: String) { clipboardField.stringValue = text; setClipboard() }
    var clipboardShown: String { clipboardText.stringValue }
}

private final class DiagFlipped: NSView { override var isFlipped: Bool { true } }

private final class DiagMenuHandler: NSObject {
    let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    @objc func picked(_ sender: NSPopUpButton) { if let v = sender.selectedItem?.representedObject as? String { handler(v) } }
}
