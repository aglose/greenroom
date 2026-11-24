import AppKit

/// Every device control, grouped in cards on glass: Display, Environment, Hardware, App, and Fold on a folding
/// device. Each control is one engine command, sent to the chosen device or, with "All devices", to every one.
/// What a control shows is what was last set here, or what the engine reports when the device is picked.
final class DevicePane: NSView {
    /// The devices a command goes to, and the one whose settings are shown.
    var targets: () -> [Simulator] = { [] }
    private(set) weak var simulator: Simulator?
    /// "All devices" is on: commands go to every running simulator.
    private(set) var toAll = false
    var onToAllChange: ((Bool) -> Void)?
    /// Called whenever a device override changes so the stage can update its active override pills.
    var onOverridesChange: (() -> Void)?

    struct ActiveOverride {
        let id: String
        let symbol: String
        let label: String
        let color: NSColor
        let key: String
        let resetValue: String
        let resetCommand: String
    }

    func activeOverrides(for sim: Simulator?) -> [ActiveOverride] {
        guard let sim, let map = state[ObjectIdentifier(sim)] else { return [] }
        var out: [ActiveOverride] = []
        if let net = map["network"], net != "online" {
            let label = net == "3g" ? "Slow 3G" : net.capitalized
            out.append(ActiveOverride(id: "network", symbol: "wifi.exclamationmark", label: label, color: Design.warning, key: "network", resetValue: "online", resetCommand: "network online"))
        }
        if let fs = map["fontscale"], let v = Double(fs), abs(v - 1.0) > 0.04 {
            out.append(ActiveOverride(id: "fontscale", symbol: "textformat.size", label: String(format: "%.2g×", v), color: NSColor(srgbRed: 0.376, green: 0.647, blue: 0.980, alpha: 1), key: "fontscale", resetValue: "1.0", resetCommand: "fontscale 1.0"))
        }
        if let loc = map["locale"], !loc.isEmpty, !loc.hasPrefix("en") {
            let rtl = loc.hasPrefix("ar") || loc.hasPrefix("he")
            out.append(ActiveOverride(id: "locale", symbol: "globe", label: rtl ? "\(loc) RTL" : loc, color: NSColor(srgbRed: 0.376, green: 0.647, blue: 0.980, alpha: 1), key: "locale", resetValue: "en-US", resetCommand: "locale en-US"))
        }
        if map["bounds"] == "on" {
            out.append(ActiveOverride(id: "bounds", symbol: "square.dashed", label: "Layout bounds", color: Design.accent, key: "bounds", resetValue: "off", resetCommand: "debug layout off"))
        }
        if map["anim"] == "off" {
            out.append(ActiveOverride(id: "anim", symbol: "tortoise", label: "No anims", color: Design.mute, key: "anim", resetValue: "on", resetCommand: "animscale 1"))
        }
        if let th = map["thermal"], th != "none" {
            out.append(ActiveOverride(id: "thermal", symbol: "thermometer.high", label: "Thermal: \(th)", color: Design.record, key: "thermal", resetValue: "none", resetCommand: "thermal none"))
        }
        if let loc = map["location"], loc != "none" {
            out.append(ActiveOverride(id: "location", symbol: "location.fill", label: "GPS mock", color: Design.accent, key: "location", resetValue: "none", resetCommand: "location none"))
        }
        return out
    }

    func clearOverride(_ o: ActiveOverride, on sim: Simulator) {
        state[ObjectIdentifier(sim), default: [:]][o.key] = o.resetValue
        sim.send(o.resetCommand)
        refresh()
        onOverridesChange?()
    }

    private let glass = GlassView(radius: 18)
    private let stack = NSStackView()
    private var state: [ObjectIdentifier: [String: String]] = [:]
    private var refreshers: [() -> Void] = []
    private var foldCard: NSView!
    private let toAllButtons = (GlassButton(symbol: nil, title: "Selected", label: "Controls change the selected device", target: nil, action: nil),
                                GlassButton(symbol: nil, title: "All devices", label: "Controls change every device", target: nil, action: nil))
    private let tilt = TiltPad()
    /// The engine's answer to the last control used, at the foot of the pane: what happened, or why nothing did.
    private let answer = NSTextField(wrappingLabelWithString: "")
    private var answerTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let title = NSTextField(labelWithString: "Device")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Design.ink
        toAllButtons.0.target = self; toAllButtons.0.action = #selector(pickSelected)
        toAllButtons.1.target = self; toAllButtons.1.action = #selector(pickAll)
        let applies = NSTextField(labelWithString: "Applies to")
        applies.font = .systemFont(ofSize: 12)
        applies.textColor = Design.mute
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [title, spacer, applies, Self.well([toAllButtons.0, toAllButtons.1])])
        head.spacing = 8

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
        buildCards()

        let doc = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        doc.translatesAutoresizingMaskIntoConstraints = false
        answer.font = .systemFont(ofSize: 12)
        answer.textColor = Design.mute
        answer.maximumNumberOfLines = 2
        answer.alphaValue = 0
        for v in [head, scroll, answer] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
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
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: State

    private func value(_ key: String, _ fallback: String) -> String {
        guard let s = simulator else { return fallback }
        return state[ObjectIdentifier(s)]?[key] ?? fallback
    }

    private func remember(_ key: String, _ v: String) {
        for s in targets() + [simulator].compactMap({ $0 }) { state[ObjectIdentifier(s), default: [:]][key] = v }
        onOverridesChange?()
    }

    /// Shows this simulator's settings; asks the engine for the ones it reports (language, text size).
    func follow(_ sim: Simulator?) {
        simulator = sim
        if let sim, state[ObjectIdentifier(sim)] == nil {
            var initial: [String: String] = ["appearance": sim.options.contains("dark") ? "dark" : "light"]
            if let i = sim.options.firstIndex(of: "--device"), i + 1 < sim.options.count { initial["device"] = sim.options[i + 1] }
            state[ObjectIdentifier(sim)] = initial
            sim.send("locale") { [weak self, weak sim] a in
                guard let self, let sim, !a.hasPrefix("error") else { return }
                self.state[ObjectIdentifier(sim), default: [:]]["locale"] = a.split(separator: ",").first.map(String.init) ?? a
                self.refresh()
            }
            sim.send("fontscale") { [weak self, weak sim] a in
                guard let self, let sim, Double(a) != nil else { return }
                self.state[ObjectIdentifier(sim), default: [:]]["fontscale"] = a
                self.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        toAllButtons.0.isOn = !toAll
        toAllButtons.1.isOn = toAll
        refreshers.forEach { $0() }
        let kind = value("device", "phone")
        let size = simulator?.deviceSize ?? .zero
        let folding = kind.contains("fold") || (size.width > 0 && abs(size.width / size.height - 1) < 0.2 && max(size.width, size.height) > 1000)
        foldCard?.isHidden = !folding
    }

    @objc private func pickSelected() { toAll = false; onToAllChange?(false); refresh() }
    @objc private func pickAll() { toAll = true; onToAllChange?(true); refresh() }

    /// Sends a command to the devices the controls change.
    private func send(_ command: String) {
        let to = targets()
        for (i, s) in to.enumerated() {
            s.send(command) { [weak self] reply in
                guard let self, i == 0 else { return }
                self.show(answer: reply, for: command, count: to.count)
            }
        }
    }

    private func show(answer reply: String, for command: String, count: Int) {
        let failed = reply.hasPrefix("error") || reply.hasPrefix("no ") || reply.contains(" has no ") || reply.contains("does not")
        let text = reply.replacingOccurrences(of: "error: ", with: "")
        answer.stringValue = (count > 1 ? "\(count) devices · " : "") + (text.isEmpty ? "Done" : text)
        answer.textColor = failed ? Design.warning : Design.mute
        answer.alphaValue = 1
        answerTimer?.invalidate()
        answerTimer = Timer.scheduledTimer(withTimeInterval: failed ? 6 : 3, repeats: false) { [weak self] _ in
            Design.animate(Design.arrive, { self?.answer.animator().alphaValue = 0 })
        }
    }

    // MARK: Cards

    private func buildCards() {
        addCard(card("Display", [
            row("Device", menu(key: "device", fallback: "phone", options: [("phone", "Phone"), ("foldable", "Foldable"), ("pixel-10-pro-fold", "Pixel 10 Pro Fold"),
                                                                         ("watch", "Watch"), ("tablet", "Tablet"), ("desktop", "Desktop"), ("tv", "TV")]) { "device \($0)" }),
            row("Language", menu(key: "locale", fallback: "en-US", options: [("en-US", "English (US)"), ("en-GB", "English (UK)"), ("fr-FR", "Français"),
                                                                           ("de-DE", "Deutsch"), ("es-ES", "Español"), ("ja-JP", "日本語"), ("ar-EG", "العربية (RTL)"),
                                                                           ("he-IL", "עברית (RTL)"), ("hi-IN", "हिन्दी")]) { "locale \($0)" }),
            row("Appearance", segments(key: "appearance", fallback: "light", options: [("light", "Light"), ("dark", "Dark")]) { "appearance \($0)" }),
            slider("Text size", key: "fontscale", fallback: 1, range: 0.85...2, format: "%.2f×") { String(format: "fontscale %.2f", $0) },
            chips([
                ("Status bar", "bars", "on", { $0 ? "bars status on" : "bars status off" }),
                ("Navigation bar", "nav", "on", { $0 ? "bars nav gesture" : "bars nav off" }),
                ("Software keyboard", "keyboard", "off", { $0 ? "keyboard soft on" : "keyboard soft off" }),
                ("Layout bounds", "bounds", "off", { $0 ? "debug layout on" : "debug layout off" }),
                ("Animations", "anim", "on", { $0 ? "animscale 1" : "animscale 0" }),
            ]),
        ]))
        addCard(card("Environment", [
            row("Network", segments(key: "network", fallback: "online", options: [("online", "Online"), ("3g", "3G"), ("lossy", "Lossy"), ("offline", "Offline")]) { "network \($0)" }),
            row("Location", menu(key: "location", fallback: "none", options: [("none", "None"), ("37.7749 -122.4194", "San Francisco"), ("51.5072 -0.1276", "London"),
                                                                            ("35.6762 139.6503", "Tokyo"), ("run", "City run (moving)"), ("bike", "Bicycle ride (moving)"),
                                                                            ("drive", "Freeway drive (moving)")]) { "location \($0)" }),
            row("Time zone", menu(key: "timezone", fallback: "", options: [("", "This Mac's"), ("UTC", "UTC"), ("America/Los_Angeles", "Los Angeles"),
                                                                         ("America/New_York", "New York"), ("Europe/London", "London"), ("Europe/Berlin", "Berlin"),
                                                                         ("Asia/Kolkata", "Kolkata"), ("Asia/Tokyo", "Tokyo"), ("Australia/Sydney", "Sydney")]) {
                $0.isEmpty ? "timezone \(TimeZone.current.identifier)" : "timezone \($0)" }),
            row("Clock", menu(key: "clock", fallback: "real", options: [("real", "Real time"), ("0941", "09:41 today"), ("midnight", "One minute to midnight"),
                                                                       ("newyear", "New Year's Eve, 23:59")]) { Self.clockCommand($0) }),
            row("Thermal", menu(key: "thermal", fallback: "none", options: [("none", "Normal"), ("light", "Light"), ("moderate", "Moderate"),
                                                                           ("severe", "Severe"), ("critical", "Critical")]) { "thermal \($0)" }),
            chips([("Bluetooth", "bluetooth", "on", { $0 ? "bluetooth on" : "bluetooth off" })]),
        ]))

        tilt.onTilt = { [weak self] pitch, roll in self?.send(String(format: "sensor tilt %.0f %.0f", pitch, roll)) }
        let tiltValue = NSTextField(labelWithString: "Upright")
        tiltValue.font = .systemFont(ofSize: 12)
        tiltValue.textColor = Design.mute
        tilt.onLabel = { tiltValue.stringValue = $0 }
        let tiltTitle = NSTextField(labelWithString: "Tilt")
        tiltTitle.textColor = Design.ink
        let tiltHead = NSStackView(views: [tiltTitle, NSView(), tiltValue])
        let hardwareButtons = grid([
            ("Shake", { [weak self] in self?.send("sensor shake") }),
            ("Lay flat", { [weak self] in self?.tilt.set(pitch: 0, roll: 0, flat: true); self?.send("sensor tilt 0 0") }),
            ("Fingerprint ✓", { [weak self] in self?.send("biometrics match") }),
            ("Fingerprint ✕", { [weak self] in self?.send("biometrics nomatch") }),
        ], columns: 2)
        let side = NSStackView(views: [tiltHead, hardwareButtons])
        side.orientation = .vertical
        side.alignment = .width
        side.spacing = 8
        let tiltRow = NSStackView(views: [tilt, side])
        tiltRow.spacing = 14
        tiltRow.alignment = .centerY
        tilt.widthAnchor.constraint(equalToConstant: 104).isActive = true
        tilt.heightAnchor.constraint(equalToConstant: 104).isActive = true
        addCard(card("Hardware", [
            tiltRow,
            row("Camera", segments(key: "camera", fallback: "pattern", options: [("pattern", "Test pattern"), ("off", "Covered")]) { "camera \($0)" }),
            row("Light", segments(key: "light", fallback: "0", options: [("0", "Dark"), ("300", "Indoor"), ("20000", "Sunlight")]) { "sensor light \($0)" }),
            row("Proximity", segments(key: "proximity", fallback: "far", options: [("far", "Far"), ("near", "Near")]) { "sensor proximity \($0)" }),
        ]))

        let link = NSTextField()
        link.placeholderString = "Open a link: https://… or myapp://…"
        link.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        link.bezelStyle = .roundedBezel
        link.target = self
        link.action = #selector(openLink(_:))
        addCard(card("App", [
            link,
            grid([
                ("Restart", { [weak self] in self?.send("restart") }),
                ("Recreate", { [weak self] in self?.send("recreate") }),
                ("Kill process", { [weak self] in self?.send("process-death") }),
                ("Low memory", { [weak self] in self?.send("memory low") }),
                ("Send push", { [weak self] in self?.send("push title=Greenroom body=A test message from Greenroom") }),
                ("Open notification", { [weak self] in self?.send("notifications last") }),
            ], columns: 3),
            grid([
                ("Allow request", { [weak self] in self?.send("permission allow") }),
                ("Deny request", { [weak self] in self?.send("permission deny") }),
                ("Reset permissions", { [weak self] in self?.send("permission reset") }),
            ], columns: 3),
        ]))
        foldCard = card("Fold", [
            row("Posture", segments(key: "fold", fallback: "open", options: [("closed", "Closed"), ("half", "Half open"), ("open", "Open flat")]) { "fold \($0)" }),
        ])
        addCard(foldCard)
    }

    /// A card across the pane's whole width.
    private func addCard(_ c: NSView) {
        stack.addArrangedSubview(c)
        c.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private static func clockCommand(_ v: String) -> String {
        let cal = Calendar.current
        let now = Date()
        func iso(_ d: Date) -> String {
            let f = ISO8601DateFormatter()
            f.timeZone = TimeZone.current
            return f.string(from: d)
        }
        switch v {
        case "0941": return "clock " + iso(cal.date(bySettingHour: 9, minute: 41, second: 0, of: now) ?? now)
        case "midnight": return "clock " + iso(cal.date(bySettingHour: 23, minute: 59, second: 0, of: now) ?? now)
        case "newyear":
            let y = cal.component(.year, from: now)
            return "clock " + iso(cal.date(from: DateComponents(year: y, month: 12, day: 31, hour: 23, minute: 59)) ?? now)
        default: return "clock real"
        }
    }

    @objc private func openLink(_ sender: NSTextField) {
        let url = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !url.contains(" ") else { return }
        send("open \(url)")
    }

    // MARK: Building blocks

    private func card(_ title: String, _ rows: [NSView]) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = Design.well.cgColor
        box.layer?.cornerRadius = 12
        box.layer?.cornerCurve = .continuous
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Design.ink
        label.alignment = .left
        let column = NSStackView(views: [label] + rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        column.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(column)
        NSLayoutConstraint.activate([column.topAnchor.constraint(equalTo: box.topAnchor), column.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                                     column.leadingAnchor.constraint(equalTo: box.leadingAnchor), column.trailingAnchor.constraint(equalTo: box.trailingAnchor)])
        // Every row spans the card, so its control sits at the right edge and its name at the left.
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

    static func well(_ views: [NSView]) -> NSView {
        let well = NSView()
        well.wantsLayer = true
        well.layer?.backgroundColor = Design.well.cgColor
        well.layer?.cornerRadius = 9
        well.layer?.cornerCurve = .continuous
        let r = NSStackView(views: views)
        r.spacing = 2
        r.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        r.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(r)
        NSLayoutConstraint.activate([r.topAnchor.constraint(equalTo: well.topAnchor), r.bottomAnchor.constraint(equalTo: well.bottomAnchor),
                                     r.leadingAnchor.constraint(equalTo: well.leadingAnchor), r.trailingAnchor.constraint(equalTo: well.trailingAnchor)])
        return well
    }

    private func segments(key: String, fallback: String, options: [(String, String)], command: @escaping (String) -> String) -> NSView {
        let buttons = options.map { v, name -> GlassButton in
            let b = GlassButton(symbol: nil, title: name, label: name, target: nil, action: nil)
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.onPress = { [weak self] in
                self?.remember(key, v)
                self?.send(command(v))
                self?.refresh()
            }
            return b
        }
        refreshers.append { [weak self] in
            guard let self else { return }
            let current = self.value(key, fallback)
            for (b, (v, _)) in zip(buttons, options) { b.isOn = v == current }
        }
        return Self.well(buttons)
    }

    private func menu(key: String, fallback: String, options: [(String, String)], command: @escaping (String) -> String) -> NSView {
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.controlSize = .regular
        pop.bezelStyle = .push
        pop.widthAnchor.constraint(equalToConstant: 196).isActive = true
        for (v, name) in options {
            pop.addItem(withTitle: name)
            pop.lastItem?.representedObject = v
        }
        let handler = MenuHandler { [weak self] v in
            self?.remember(key, v)
            self?.send(command(v))
            self?.refresh()
        }
        pop.target = handler
        pop.action = #selector(MenuHandler.picked(_:))
        objc_setAssociatedObject(pop, &MenuHandler.key, handler, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append { [weak self] in
            guard let self else { return }
            let current = self.value(key, fallback)
            // A value set elsewhere (the engine's own name for it) still finds its entry by prefix.
            if let i = options.firstIndex(where: { $0.0 == current || (!$0.0.isEmpty && current.hasPrefix($0.0)) }) { pop.selectItem(at: i) }
        }
        return pop
    }

    private func slider(_ name: String, key: String, fallback: Double, range: ClosedRange<Double>, format: String, command: @escaping (Double) -> String) -> NSView {
        let s = NSSlider(value: fallback, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        s.isContinuous = false
        let shown = NSTextField(labelWithString: String(format: format, fallback))
        shown.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        shown.textColor = Design.mute
        shown.alignment = .right
        shown.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let handler = SliderHandler { [weak self] v in
            let snapped = (v * 20).rounded() / 20
            shown.stringValue = String(format: format, snapped)
            self?.remember(key, String(snapped))
            self?.send(command(snapped))
        }
        s.target = handler
        s.action = #selector(SliderHandler.moved(_:))
        objc_setAssociatedObject(s, &SliderHandler.key, handler, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append { [weak self] in
            guard let self else { return }
            let v = Double(self.value(key, String(fallback))) ?? fallback
            s.doubleValue = v
            shown.stringValue = String(format: format, v)
        }
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13)
        label.textColor = Design.ink
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let r = NSStackView(views: [label, s, shown])
        r.spacing = 10
        return r
    }

    private func chips(_ items: [(String, String, String, (Bool) -> String)]) -> NSView {
        let buttons = items.map { name, key, fallback, command -> GlassButton in
            let b = GlassButton(symbol: nil, title: name, label: name, style: .well, target: nil, action: nil)
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.layer?.cornerRadius = 13
            b.onPress = { [weak self] in
                guard let self else { return }
                let on = self.value(key, fallback) != "on"
                self.remember(key, on ? "on" : "off")
                self.send(command(on))
                self.refresh()
            }
            refreshers.append { [weak self] in b.isOn = self?.value(key, fallback) == "on" }
            return b
        }
        let flow = FlowView(views: buttons)
        return flow
    }

    private func grid(_ items: [(String, () -> Void)], columns: Int) -> NSView {
        let buttons = items.map { name, action -> GlassButton in
            let b = GlassButton(symbol: nil, title: name, label: name, style: .well, target: nil, action: nil)
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.onPress = action
            return b
        }
        let g = NSGridView(views: stride(from: 0, to: buttons.count, by: columns).map { Array(buttons[$0..<min($0 + columns, buttons.count)]) })
        g.rowSpacing = 6
        g.columnSpacing = 6
        for i in 0..<g.numberOfColumns { g.column(at: i).xPlacement = .fill }
        return g
    }
}

/// A pad for tilting the device: the knob's distance from the centre is how far, its direction which way.
final class TiltPad: NSView {
    var onTilt: ((Double, Double) -> Void)?
    var onLabel: ((String) -> Void)?
    private var knob = CGPoint.zero   // -1...1 on each axis
    private var lastSent = Date.distantPast

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func set(pitch: Double, roll: Double, flat: Bool = false) {
        knob = CGPoint(x: roll / 90, y: -pitch / 90)
        onLabel?(flat ? "Flat on a table" : label(pitch, roll))
        needsDisplay = true
    }

    private func label(_ pitch: Double, _ roll: Double) -> String {
        abs(pitch) < 2 && abs(roll) < 2 ? "Upright" : String(format: "%.0f°, %.0f°", pitch, roll)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let pad = NSBezierPath(ovalIn: r)
        NSColor(white: 0, alpha: 0.3).setFill()
        pad.fill()
        Design.stroke.setStroke()
        pad.stroke()
        let c = CGPoint(x: r.midX, y: r.midY)
        let line = NSBezierPath()
        line.move(to: CGPoint(x: c.x, y: r.minY + 10)); line.line(to: CGPoint(x: c.x, y: r.maxY - 10))
        line.move(to: CGPoint(x: r.minX + 10, y: c.y)); line.line(to: CGPoint(x: r.maxX - 10, y: c.y))
        line.stroke()
        let reach = r.width / 2 - 12
        let p = CGPoint(x: c.x + knob.x * reach, y: c.y + knob.y * reach)
        Design.accent.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)).fill()
        Design.accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)).fill()
    }

    override func mouseDown(with event: NSEvent) { move(event, final: false) }
    override func mouseDragged(with event: NSEvent) { move(event, final: false) }
    override func mouseUp(with event: NSEvent) { move(event, final: true) }

    private func move(_ event: NSEvent, final: Bool) {
        let p = convert(event.locationInWindow, from: nil)
        let reach = bounds.width / 2 - 12
        var v = CGPoint(x: (p.x - bounds.midX) / reach, y: (p.y - bounds.midY) / reach)
        let len = (v.x * v.x + v.y * v.y).squareRoot()
        if len > 1 { v = CGPoint(x: v.x / len, y: v.y / len) }
        knob = v
        needsDisplay = true
        // Up on the pad tips the top of the device away (pitch down); right rolls it right.
        let pitch = Double(-v.y * 90), roll = Double(v.x * 90)
        onLabel?(label(pitch, roll))
        if final || Date().timeIntervalSince(lastSent) > 0.08 {
            lastSent = Date()
            onTilt?(pitch, roll)
        }
    }
}

/// Buttons laid out in rows that wrap at the view's width.
private final class FlowView: NSView {
    private let items: [NSView]
    init(views: [NSView]) {
        items = views
        super.init(frame: .zero)
        for v in views { v.translatesAutoresizingMaskIntoConstraints = true; addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }

    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in items {
            let s = v.fittingSize
            if x > 0, x + s.width > width { x = 0; y += rowH + 6; rowH = 0 }
            if apply { v.frame = NSRect(x: x, y: y, width: s.width, height: s.height) }
            x += s.width + 6
            rowH = max(rowH, s.height)
        }
        return y + rowH
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: place(width: max(bounds.width, 300), apply: false)) }
    override func layout() {
        super.layout()
        _ = place(width: bounds.width, apply: true)
        invalidateIntrinsicContentSize()
    }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

private final class MenuHandler: NSObject {
    static var key = 0
    let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    @objc func picked(_ sender: NSPopUpButton) { if let v = sender.selectedItem?.representedObject as? String { handler(v) } }
}

private final class SliderHandler: NSObject {
    static var key = 0
    let handler: (Double) -> Void
    init(_ handler: @escaping (Double) -> Void) { self.handler = handler }
    @objc func moved(_ sender: NSSlider) { handler(sender.doubleValue) }
}
