import AppKit
import UniformTypeIdentifiers

/// The screen map: a full-stage sheet that walks the app (the engine's crawler) and shows every screen it reached as
/// a graph, with the route to each. A screen's card opens to its capture, the controls on it and where each leads;
/// "Go there" replays the route on the selected device.
final class ScreenMap: NSView {
    private(set) var isOpen = false
    var onSay: ((String, Bool) -> Void)?
    var onToggle: (() -> Void)?
    /// The selected simulator's APK, the default for a walk.
    var defaultAPK: () -> URL? = { nil }
    /// Replays a screen's route on the selected device.
    var onGo: ((MapScreen, ScreenMapData) -> Void)?
    /// The selected simulator's session worktree, whose `.greenroom/scripts` are offered for signing in too.
    var worktree: () -> URL? = { nil }

    /// The script that signs in before a walk (MapSignIn), while it runs; the slot it left, while the walk runs.
    private var signIn: MapSignIn?
    private var signedInSlot: String?
    private var signInStatus = ""
    private var scripts: [Scripts.Script] = []

    private(set) var run: CrawlRun?
    private(set) var data: ScreenMapData?
    private var apkURL: URL? { didSet { UserDefaults.standard.set(apkURL?.path, forKey: "mapAPK") } }
    private var lastFolder: URL? { didSet { UserDefaults.standard.set(lastFolder?.path, forKey: "mapRun") } }
    private var pythonURL: URL? = SnapshotRun.python()
    private var ticker: Timer?
    private var reached = (depth: 0, known: 0)

    private let dim = NSView()
    private let panel = GlassView(radius: 18)
    private let appLabel = NSTextField(labelWithString: "")
    private let depthPopup = NSPopUpButton()
    private let timePopup = NSPopUpButton()
    private let capturePopup = NSPopUpButton()
    private let offline = NSButton(checkboxWithTitle: "Offline", target: nil, action: nil)
    private let startField = NSTextField()
    private let signInPopup = NSPopUpButton()
    private let walkButton = GlassButton(symbol: "point.3.connected.trianglepath.dotted", title: "Walk the app", label: "Walk every screen the app has", style: .accent, target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let crashChip = GlassButton(symbol: "exclamationmark.triangle.fill", title: "", label: "Show where it crashed", style: .record, target: nil, action: nil)
    private let comboControl = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    let canvas = MapCanvas(frame: .zero)
    private let scroll = NSScrollView()
    private let emptyNote = NSTextField(wrappingLabelWithString: "")

    // Detail.
    private let detail = NSStackView()
    private let picture = SnapshotPicture()
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailSub = NSTextField(labelWithString: "")
    private let routeStack = NSStackView()
    private let controlStack = NSStackView()
    private let goButton = GlassButton(symbol: "arrow.forward.circle.fill", title: "Go there", label: "Replay the route on the selected device", style: .accent, target: nil, action: nil)
    private let copyButton = GlassButton(symbol: "doc.on.doc", title: "Copy route", label: "Copy the route as control commands", style: .well, target: nil, action: nil)
    private var pictureHeight: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        appearance = NSAppearance(named: .darkAqua)
        apkURL = UserDefaults.standard.string(forKey: "mapAPK").map { URL(fileURLWithPath: $0) }
        lastFolder = UserDefaults.standard.string(forKey: "mapRun").map { URL(fileURLWithPath: $0) }
        build()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var acceptsFirstResponder: Bool { true }

    private func label(_ t: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = Design.mute) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func popup(_ p: NSPopUpButton, _ items: [String], key: String, default d: Int) {
        p.addItems(withTitles: items)
        p.controlSize = .small
        p.font = .systemFont(ofSize: 12)
        p.selectItem(at: min(UserDefaults.standard.object(forKey: key) as? Int ?? d, items.count - 1))
        p.target = self
        p.action = #selector(settingChanged)
    }

    // MARK: Layout

    private func build() {
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
        for v in [dim, panel] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: topAnchor), dim.bottomAnchor.constraint(equalTo: bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor), dim.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 58), panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28), panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])

        // Header: what is walked, the settings, Walk.
        let title = label("Screen map", size: 15, weight: .semibold, color: Design.ink)
        appLabel.font = .systemFont(ofSize: 12, weight: .medium)
        appLabel.textColor = Design.mute
        appLabel.lineBreakMode = .byTruncatingMiddle
        appLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let choose = GlassButton(symbol: nil, title: "Choose…", label: "Choose the APK to walk", style: .well, target: self, action: #selector(chooseAPK))
        let close = GlassButton(symbol: "xmark", label: "Close (Esc)", target: self, action: #selector(closePressed))
        walkButton.target = self; walkButton.action = #selector(walkPressed)
        let hs = NSView(); hs.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, appLabel, choose, hs, walkButton, close])
        header.spacing = 10

        popup(depthPopup, ["1 tap deep", "2 taps deep", "3 taps deep", "4 taps deep", "6 taps deep"], key: "mapDepth", default: 2)
        popup(timePopup, ["1 minute", "3 minutes", "5 minutes", "10 minutes"], key: "mapTime", default: 1)
        popup(capturePopup, ["Light captures", "Light and dark", "No captures"], key: "mapCaptures", default: 0)
        offline.controlSize = .small
        offline.font = .systemFont(ofSize: 12)
        offline.state = UserDefaults.standard.bool(forKey: "mapOffline") ? .on : .off
        offline.target = self; offline.action = #selector(settingChanged)
        offline.toolTip = "Walk with no network, so nothing the app does reaches a real server"
        startField.placeholderString = "Start at a deep link (optional)"
        startField.controlSize = .small
        startField.font = .systemFont(ofSize: 12)
        startField.stringValue = UserDefaults.standard.string(forKey: "mapStart") ?? ""
        startField.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let safety = label("Never taps delete, buy, send, sign out and the like", size: 11)
        safety.lineBreakMode = .byTruncatingTail
        safety.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        signInPopup.controlSize = .small
        signInPopup.font = .systemFont(ofSize: 12)
        signInPopup.target = self; signInPopup.action = #selector(signInChanged)
        signInPopup.toolTip = "Run one of your scripts (Device > Run Script) on a hidden device first, then walk signed in on its data. Your own devices' data is not touched."
        signInPopup.setAccessibilityLabel("Sign in before walking")
        let settings = NSStackView(views: [depthPopup, timePopup, capturePopup, signInPopup, offline, startField, safety])
        settings.spacing = 10

        // Status: what the walk is doing, or what the map holds.
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = Design.mute
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        crashChip.target = self; crashChip.action = #selector(showCrash)
        crashChip.isHidden = true
        comboControl.controlSize = .small
        comboControl.target = self; comboControl.action = #selector(comboChanged)
        comboControl.isHidden = true
        let ss = NSView(); ss.setContentHuggingPriority(.init(1), for: .horizontal)
        let zoomOut = GlassButton(symbol: "minus.magnifyingglass", label: "Zoom out", target: self, action: #selector(zoomOut))
        let zoomFit = GlassButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Fit the map", target: self, action: #selector(zoomToFit))
        let zoomIn = GlassButton(symbol: "plus.magnifyingglass", label: "Zoom in", target: self, action: #selector(zoomIn))
        let status = NSStackView(views: [spinner, summary, crashChip, ss, comboControl, zoomOut, zoomFit, zoomIn])
        status.spacing = 8

        // The map.
        scroll.documentView = canvas
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.3
        scroll.maxMagnification = 2
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = false
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        canvas.onSelect = { [weak self] id in self?.showDetail(id) }
        canvas.onOpen = { [weak self] id in self?.go(id) }
        let mapWell = NSView()
        mapWell.wantsLayer = true
        mapWell.layer?.backgroundColor = NSColor(white: 0, alpha: 0.22).cgColor
        mapWell.layer?.cornerRadius = 12
        mapWell.layer?.cornerCurve = .continuous
        mapWell.layer?.masksToBounds = true
        let grid = StageBackground(frame: .zero)
        emptyNote.font = .systemFont(ofSize: 13)
        emptyNote.textColor = Design.mute
        emptyNote.alignment = .center
        for v in [grid, scroll, emptyNote] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; mapWell.addSubview(v) }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: mapWell.topAnchor), grid.bottomAnchor.constraint(equalTo: mapWell.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: mapWell.leadingAnchor), grid.trailingAnchor.constraint(equalTo: mapWell.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: mapWell.topAnchor), scroll.bottomAnchor.constraint(equalTo: mapWell.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: mapWell.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: mapWell.trailingAnchor),
            emptyNote.centerXAnchor.constraint(equalTo: mapWell.centerXAnchor), emptyNote.centerYAnchor.constraint(equalTo: mapWell.centerYAnchor),
            emptyNote.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])

        // The selected screen.
        detailTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        detailTitle.textColor = Design.ink
        detailTitle.lineBreakMode = .byTruncatingTail
        detailTitle.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        detailSub.font = .systemFont(ofSize: 11.5)
        detailSub.textColor = Design.mute
        detailSub.lineBreakMode = .byTruncatingTail
        detailSub.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        picture.translatesAutoresizingMaskIntoConstraints = false
        pictureHeight = picture.heightAnchor.constraint(equalToConstant: 300)
        pictureHeight.isActive = true
        goButton.target = self; goButton.action = #selector(goPressed)
        copyButton.target = self; copyButton.action = #selector(copyRoute)
        let buttons = NSStackView(views: [goButton, copyButton])
        buttons.spacing = 8
        for s in [routeStack, controlStack] {
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 3
        }
        let controlsScroll = NSScrollView()
        let flip = MapFlippedView()
        controlStack.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(controlStack)
        flip.translatesAutoresizingMaskIntoConstraints = false
        controlsScroll.documentView = flip
        controlsScroll.drawsBackground = false
        controlsScroll.hasVerticalScroller = true
        controlsScroll.autohidesScrollers = true
        NSLayoutConstraint.activate([
            controlStack.topAnchor.constraint(equalTo: flip.topAnchor), controlStack.leadingAnchor.constraint(equalTo: flip.leadingAnchor),
            controlStack.trailingAnchor.constraint(equalTo: flip.trailingAnchor), controlStack.bottomAnchor.constraint(equalTo: flip.bottomAnchor),
            flip.widthAnchor.constraint(equalTo: controlsScroll.contentView.widthAnchor),
        ])
        let routeHead = label("ROUTE", size: 10, weight: .semibold)
        let controlsHead = label("CONTROLS", size: 10, weight: .semibold)
        for v in [picture, detailTitle, detailSub, buttons, routeHead, routeStack, controlsHead, controlsScroll] as [NSView] { detail.addArrangedSubview(v) }
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 6
        detail.setCustomSpacing(12, after: picture)
        detail.setCustomSpacing(12, after: detailSub)
        detail.setCustomSpacing(14, after: buttons)
        detail.setCustomSpacing(14, after: routeStack)
        for v in [picture, controlsScroll, routeStack] as [NSView] { v.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
        controlsScroll.setContentHuggingPriority(.init(1), for: .vertical)
        controlsScroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let detailWell = NSView()
        detailWell.wantsLayer = true
        detailWell.layer?.backgroundColor = Design.well.cgColor
        detailWell.layer?.cornerRadius = 12
        detailWell.layer?.cornerCurve = .continuous
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailWell.addSubview(detail)
        NSLayoutConstraint.activate([detail.topAnchor.constraint(equalTo: detailWell.topAnchor, constant: 14), detail.bottomAnchor.constraint(equalTo: detailWell.bottomAnchor, constant: -12),
                                     detail.leadingAnchor.constraint(equalTo: detailWell.leadingAnchor, constant: 14), detail.trailingAnchor.constraint(equalTo: detailWell.trailingAnchor, constant: -14),
                                     detailWell.widthAnchor.constraint(equalToConstant: 330)])
        detail.isHidden = true

        let body = NSStackView(views: [mapWell, detailWell])
        body.spacing = 14
        body.distribution = .fill
        body.alignment = .top
        mapWell.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        detailWell.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true

        let rule = NSView(); rule.wantsLayer = true; rule.layer?.backgroundColor = Design.stroke.cgColor
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let column = NSStackView(views: [header, settings, rule, status, body])
        column.orientation = .vertical
        column.spacing = 10
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)
        for v in [header, settings, rule, status, body] as [NSView] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        body.setContentHuggingPriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([column.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14), column.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
                                     column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18), column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18)])
    }

    // MARK: Opening and closing

    func open() {
        guard !isOpen else { return }
        isOpen = true
        if pythonURL == nil { pythonURL = SnapshotRun.python() }
        reloadScripts()
        if data == nil, !isWalking, let f = lastFolder, let last = ScreenMapData.read(f) { present(last, animated: false) }
        refresh()
        isHidden = false
        alphaValue = 0
        panel.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: 8))
        window?.makeFirstResponder(canvas)
        Design.animate(Design.arrive, {
            self.animator().alphaValue = 1
            self.panel.layer?.setAffineTransform(.identity)
        }, done: { if self.data != nil, self.scroll.magnification == 1 { self.fit(animated: false) } })
        onToggle?()
    }

    /// Shows a finished run from another folder (Sessions' evidence) without starting a walk; false when the folder
    /// has no map or a walk is running here.
    @discardableResult
    func show(folder: URL) -> Bool {
        guard !isWalking, let d = ScreenMapData.read(folder) else { return false }
        present(d, animated: false)
        return true
    }

    /// A walk goes on when the sheet closes; the map is there when it opens again.
    func close() {
        guard isOpen else { return }
        isOpen = false
        Design.animate(Design.snap, { self.animator().alphaValue = 0 }, done: { if !self.isOpen { self.isHidden = true } })
        onToggle?()
    }

    @objc private func closePressed() { close() }
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { close() } else { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) { if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { close() } }

    // MARK: Settings

    var effectiveAPK: URL? { apkURL ?? defaultAPK() }
    func setAPK(_ url: URL?) { apkURL = url; refresh() }

    var settings: CrawlRun.Settings {
        var s = CrawlRun.Settings()
        s.depth = [1, 2, 3, 4, 6][max(0, depthPopup.indexOfSelectedItem)]
        s.seconds = [60, 180, 300, 600][max(0, timePopup.indexOfSelectedItem)]
        s.appearances = [["light"], ["light", "dark"], []][max(0, capturePopup.indexOfSelectedItem)]
        s.offline = offline.state == .on
        let start = startField.stringValue.trimmingCharacters(in: .whitespaces)
        s.start = start.isEmpty ? nil : start
        return s
    }

    /// For checks: depth, time and captures by index into the menus.
    func configure(depth: Int, time: Int, captures: Int, start: String? = nil) {
        depthPopup.selectItem(at: depth); timePopup.selectItem(at: time); capturePopup.selectItem(at: captures)
        if let start { startField.stringValue = start }
        settingChanged()
    }

    /// The status line, for checks.
    var statusText: String { summary.stringValue }

    @objc private func settingChanged() {
        let d = UserDefaults.standard
        d.set(depthPopup.indexOfSelectedItem, forKey: "mapDepth")
        d.set(timePopup.indexOfSelectedItem, forKey: "mapTime")
        d.set(capturePopup.indexOfSelectedItem, forKey: "mapCaptures")
        d.set(offline.state == .on, forKey: "mapOffline")
    }

    // MARK: Signing in

    /// The scripts that can sign in: Greenroom's own, then the selected session's. The choice is kept by name.
    func reloadScripts() {
        guard !isWalking else { return }
        scripts = Scripts.available(for: worktree())
        let wanted = UserDefaults.standard.string(forKey: "mapSignIn")
        signInPopup.removeAllItems()
        signInPopup.addItem(withTitle: "No sign-in")
        for s in scripts { signInPopup.addItem(withTitle: "Sign in with " + s.name + (s.fromWorktree ? " (session)" : "")) }
        signInPopup.menu?.addItem(.separator())
        signInPopup.addItem(withTitle: "New Sign-in Script…")
        signInPopup.lastItem?.representedObject = "new"
        let i = scripts.firstIndex { $0.name == wanted }.map { $0 + 1 } ?? 0
        signInPopup.selectItem(at: i)
    }

    /// The script chosen in the menu, if any.
    var signInScript: Scripts.Script? {
        let i = signInPopup.indexOfSelectedItem - 1
        return scripts.indices.contains(i) ? scripts[i] : nil
    }

    /// For checks: the script to sign in with (nil: none), by its file.
    func chooseSignIn(_ url: URL?) {
        if let url, !scripts.contains(where: { $0.url == url }) { scripts.append(.init(url: url, fromWorktree: false)); signInPopup.insertItem(withTitle: "Sign in with " + url.lastPathComponent, at: scripts.count) }
        let i = url.flatMap { u in scripts.firstIndex { $0.url == u } }.map { $0 + 1 } ?? 0
        signInPopup.selectItem(at: i)
    }

    @objc private func signInChanged() {
        if signInPopup.selectedItem?.representedObject as? String == "new" {
            do { NSWorkspace.shared.open(try Scripts.newScript()) } catch { onSay?("Could not write a new script", true) }
            reloadScripts()
            return
        }
        UserDefaults.standard.set(signInScript?.name, forKey: "mapSignIn")
    }

    var isWalking: Bool { signIn != nil || run?.isRunning == true }

    @objc private func chooseAPK() {
        let p = NSOpenPanel()
        p.message = "Choose the APK to walk"
        p.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in if r == .OK, let u = p.url { self?.setAPK(u) } }
    }

    private func refresh() {
        if let apk = effectiveAPK { appLabel.stringValue = apk.lastPathComponent + (apkURL == nil ? "  ·  the selected device's" : "") }
        else { appLabel.stringValue = "No app: open one, or choose an APK" }
        let running = isWalking
        walkButton.title = running ? "Stop" : (data == nil ? "Walk the app" : "Walk again")
        walkButton.style = running ? .record : .accent
        walkButton.isEnabled = running || (effectiveAPK != nil && pythonURL != nil)
        for c in [depthPopup, timePopup, capturePopup, signInPopup, offline, startField] as [NSControl] { c.isEnabled = !running }
        if pythonURL == nil, !running {
            setSummary("The map needs Python 3, and this Mac has none. Install the command line tools (xcode-select --install in Terminal), then reopen this.", problem: true)
        }
        emptyNote.isHidden = data != nil || running
        emptyNote.stringValue = "Greenroom taps through the app by itself, a level at a time, and draws every screen it reaches with the way there. It runs its own hidden devices, so yours are left alone."
    }

    private func setSummary(_ text: String, problem: Bool = false) {
        summary.stringValue = text
        summary.textColor = problem ? Design.warning : Design.mute
    }

    // MARK: Walking

    @objc private func walkPressed() {
        if let signIn { signIn.cancel(); return }
        if let run, run.isRunning { run.cancel(); return }
        walk()
    }

    /// Starts a walk with the settings shown. False when there is nothing to walk or no Python.
    @discardableResult
    func walk() -> Bool {
        guard !isWalking else { return true }
        guard let apk = effectiveAPK, let python = pythonURL ?? SnapshotRun.python() else { refresh(); return false }
        UserDefaults.standard.set(startField.stringValue, forKey: "mapStart")
        let base = Engine.shared.state.appendingPathComponent("maps", isDirectory: true)
        SnapshotRun.prune(base, keep: 5)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let out = base.appendingPathComponent("run-" + stamp)
        let walkSettings = settings
        data = nil
        reached = (0, 0)
        canvas.clear()
        canvas.frame = NSRect(origin: .zero, size: scroll.contentSize)
        scroll.magnification = 1
        showDetail(nil)
        crashChip.isHidden = true
        comboControl.isHidden = true
        spinner.startAnimation(nil)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if let script = signInScript {
            // Sign in first, on a device of its own; the walk then takes that device's data as it is.
            SlotClone.sweep(in: Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true))
            let s = MapSignIn(apk: apk, script: script, worktree: worktree())
            signIn = s
            signInStatus = "Starting a device to run \(script.name)…"
            s.onStatus = { [weak self] text in self?.signInStatus = text; self?.tick() }
            s.start { [weak self] outcome in
                guard let self else { return }
                self.signIn = nil
                switch outcome {
                case .ready(let slot):
                    var ws = walkSettings
                    ws.keepData = true
                    ws.jobs = 1   // the crawler walks a kept slot with one device
                    ws.engineOptions = ["--data-slots", slot]
                    self.signedInSlot = slot
                    self.startCrawl(python: python, apk: apk, out: out, settings: ws)
                case .failed(let why): self.finished(.failed("signing in did not work. " + why))
                case .cancelled: self.finished(.cancelled)
                }
            }
        } else {
            startCrawl(python: python, apk: apk, out: out, settings: walkSettings)
        }
        tick()
        refresh()
        return true
    }

    private func startCrawl(python: URL, apk: URL, out: URL, settings: CrawlRun.Settings) {
        let r = CrawlRun(python: python, apk: apk, out: out, settings: settings)
        run = r
        r.onEvent = { [weak self] e in self?.event(e) }
        r.onFinish = { [weak self] o in self?.finished(o) }
        r.start()
        tick()
        refresh()
    }

    private func tick() {
        if signIn != nil { setSummary(signInStatus); return }
        guard let run, run.isRunning else { return }
        let s = Int(Date().timeIntervalSince(run.startedAt))
        let t = String(format: "%d:%02d", s / 60, s % 60)
        let signedIn = signedInSlot != nil ? ", signed in" : ""
        if reached.known == 0 { setSummary(signedInSlot != nil ? "Starting the signed-in device…  \(t)" : "Starting three hidden devices…  \(t)") }
        else if reached.depth < 0 { setSummary("Capturing \(reached.known) screens…  \(t)") }
        else { setSummary("Walking\(signedIn): \(reached.depth == 0 ? "the first screen" : "\(reached.depth) tap\(reached.depth == 1 ? "" : "s") deep"), \(reached.known) screen\(reached.known == 1 ? "" : "s") found  ·  \(t)") }
    }

    private func event(_ e: CrawlRun.Event) {
        switch e {
        case .level(let depth, let exploring, let known):
            reached = (depth, known)
            canvas.walkReached(depth: depth, exploring: exploring)
        case .capturing(let screens, _):
            if settings.appearances.isEmpty { return }
            reached = (-1, screens)
        case .line: return
        }
        tick()
    }

    private func finished(_ outcome: CrawlRun.Outcome) {
        ticker?.invalidate()
        ticker = nil
        spinner.stopAnimation(nil)
        if let slot = signedInSlot {
            signedInSlot = nil
            DispatchQueue.global(qos: .utility).async { MapSignIn.discard(slot) }
        }
        switch outcome {
        case .finished(let map):
            lastFolder = map.folder
            present(map, animated: isOpen)
            let crashes = map.crashes.count
            onSay?("Screen map: \(map.screens.count) screens" + (crashes > 0 ? ", \(crashes) crash\(crashes == 1 ? "" : "es")" : ""), crashes > 0)
        case .failed(let why):
            canvas.clear()
            setSummary("The walk failed: " + why, problem: true)
            onSay?("The walk failed", true)
        case .cancelled:
            canvas.clear()
            setSummary("Walk stopped.")
        }
        run = nil
        refresh()
    }

    private func present(_ map: ScreenMapData, animated: Bool) {
        data = map
        canvas.comboIndex = 0
        canvas.show(map, animated: animated)
        let transitions = map.edges.filter { if case .screen = $0.to { return true } else { return false } }.count
        var parts = ["\(map.screens.count) screens", "\(transitions) transitions"]
        let unexplored = map.incomplete.first { $0.hasPrefix("--max-depth") }.map { _ in "deepest level not opened" }
        let outOfTime = map.incomplete.contains { $0.hasPrefix("--max-seconds") } ? "stopped at the time limit" : nil
        parts += [unexplored, outOfTime].compactMap { $0 }
        parts.append(String(format: "%.0f s", map.seconds))
        setSummary(map.apkName + "  ·  " + parts.joined(separator: "  ·  "))
        let crashes = map.crashes.count
        crashChip.isHidden = crashes == 0
        crashChip.title = crashes == 1 ? "1 crash" : "\(crashes) crashes"
        let combos = map.combos.filter { c in map.screens.contains { $0.captures.contains { $0.combo == c } } }
        comboControl.segmentCount = combos.count
        for (i, c) in combos.enumerated() { comboControl.setLabel(c.contains("dark") ? "Dark" : (c.contains("light") ? "Light" : c), forSegment: i) }
        comboControl.selectedSegment = 0
        comboControl.isHidden = combos.count < 2
        emptyNote.isHidden = true
        if isOpen { DispatchQueue.main.async { self.fit(animated: animated) } }
        canvas.select(map.screens.first?.id, reveal: false)
    }

    @objc private func showCrash() {
        guard let map = data, let crash = map.crashes.first else { return }
        // The screen the crashing control was on: the longest route the crash's own route begins with.
        let at = map.screens.filter { crash.steps.starts(with: $0.steps) }.max { $0.steps.count < $1.steps.count }
        if let at { canvas.select(at.id) }
        onSay?(crash.detail.split(separator: "\n").first.map(String.init) ?? "Crash", true)
    }

    @objc private func comboChanged() {
        canvas.comboIndex = comboControl.selectedSegment
        showDetail(canvas.selected)
    }

    // MARK: Zoom

    @objc private func zoomIn() { zoom(by: 1.25) }
    @objc private func zoomOut() { zoom(by: 0.8) }
    @objc private func zoomToFit() { fit(animated: true) }

    private func zoom(by f: CGFloat) {
        let m = min(scroll.maxMagnification, max(scroll.minMagnification, scroll.magnification * f))
        let c = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        Design.animate(Design.move, { scroll.animator().setMagnification(m, centeredAt: c) })
    }

    /// The whole map in view, never larger than life.
    func fit(animated: Bool) {
        let size = canvas.bounds.size, view = scroll.bounds.size
        guard size.width > 0, size.height > 0, view.width > 0 else { return }
        let m = max(scroll.minMagnification, min(1, view.width / size.width, view.height / size.height))
        let c = NSPoint(x: size.width / 2, y: size.height / 2)
        if animated { Design.animate(Design.move, { scroll.animator().setMagnification(m, centeredAt: c) }) }
        else { scroll.setMagnification(m, centeredAt: c) }
    }

    // MARK: Detail

    private func showDetail(_ id: String?) {
        guard let map = data, let id, let s = map.screen(id) else { detail.isHidden = true; return }
        detail.isHidden = false
        detailTitle.stringValue = s.label
        let routes = map.edges.filter { $0.from == id }
        let reachable = Set(routes.compactMap { e -> String? in if case .screen(let t) = e.to, t != id { return t } else { return nil } })
        detailSub.stringValue = "\(s.activity)  ·  \(s.steps.count == 0 ? "start" : "\(s.steps.count) step\(s.steps.count == 1 ? "" : "s") in")  ·  leads to \(reachable.count) screen\(reachable.count == 1 ? "" : "s")" + (s.settled ? "" : "  ·  never settles")

        // The capture, at the run's aspect ratio.
        let combo = min(canvas.comboIndex, max(0, s.captures.count - 1))
        let width: CGFloat = 302
        if let file = s.captures.indices.contains(combo) ? s.captures[combo].file : nil {
            SnapshotImages.load(file, maxPixel: 900) { [weak self] img in
                guard let self, self.canvas.selected == id else { return }
                // At most about two fifths of the column, so the controls below keep room.
                let room = max(180, self.detail.bounds.height * 0.42)
                if let img { self.pictureHeight.constant = min(room, width * CGFloat(img.height) / CGFloat(max(1, img.width))) }
                self.picture.show(img, empty: "No capture")
            }
        } else {
            pictureHeight.constant = 90
            picture.show(nil, empty: "Walked without captures")
        }

        // The route: the start, then each step.
        routeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let startText = s.start.map { "Open \($0)" } ?? "Launch the app"
        for (i, step) in ([startText] + s.steps.map(ScreenMap.describe)).enumerated() {
            let n = label(i == 0 ? "●" : "\(i)", size: 10.5, weight: .semibold, color: i == 0 ? Design.accent : Design.mute)
            n.alignment = .right
            n.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let t = label(step, size: 12, color: Design.ink)
            t.lineBreakMode = .byTruncatingTail
            t.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let row = NSStackView(views: [n, t])
            row.spacing = 8
            routeStack.addArrangedSubview(row)
        }
        goButton.isEnabled = true

        // The controls on the screen, and where each leads.
        controlStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for e in routes {
            let (where_, color, target): (String, NSColor, String?) = {
                switch e.to {
                case .screen(let t) where t == id: return ("stays here", Design.mute, nil)
                case .screen(let t): return (map.screen(t)?.label ?? t, Design.ink, t)
                case .exit: return ("closes the app", Design.warning, nil)
                case .crash: return ("crashes", Design.record, nil)
                case .skipped: return ("not tapped: " + (e.note ?? "on the safety list"), Design.mute, nil)
                case .failed: return ("did not replay", Design.warning, nil)
                case .unfollowed: return ("not followed", Design.mute, nil)
                }
            }()
            let row = MapControlRow(control: e.action.isEmpty ? e.cmd : e.action, outcome: where_, color: color, enabled: target != nil)
            if let target { row.onPress = { [weak self] in self?.canvas.select(target) } }
            controlStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: controlStack.widthAnchor).isActive = true
        }
        if routes.isEmpty {
            controlStack.addArrangedSubview(label(s.depth >= settings.depth ? "Not opened: the walk stopped at this depth." : "No controls with a label.", size: 12))
        }
    }

    /// A control command as a person would say it.
    static func describe(_ cmd: String) -> String {
        if cmd.hasPrefix("tap-text ") { return "Tap “\(cmd.dropFirst(9))”" }
        if cmd.hasPrefix("tap ") { return "Tap at " + cmd.dropFirst(4).replacingOccurrences(of: " ", with: ", ") }
        if cmd.hasPrefix("drag ") { return "Scroll down" }
        if cmd.hasPrefix("type") { return "Type text" }
        return cmd
    }

    private func go(_ id: String) {
        guard let map = data, let s = map.screen(id) else { return }
        onGo?(s, map)
    }

    @objc private func goPressed() { if let id = canvas.selected { go(id) } }

    @objc private func copyRoute() {
        guard let map = data, let id = canvas.selected, let s = map.screen(id) else { return }
        let lines = [s.start.map { "restart \($0)" } ?? "restart"] + s.steps.flatMap { [$0, "settle 1500 100"] }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        onSay?("Route copied: \(lines.count) control commands", false)
    }
}

/// One control in the detail: its name, and where it leads (a press goes there on the map).
private final class MapControlRow: NSView {
    var onPress: (() -> Void)?
    private var hovering = false { didSet { layer?.backgroundColor = (hovering && enabled ? Design.wellOn : .clear).cgColor } }
    private let enabled: Bool

    init(control: String, outcome: String, color: NSColor, enabled: Bool) {
        self.enabled = enabled
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        let name = NSTextField(labelWithString: control)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = Design.ink
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(2), for: .horizontal)
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) ?? NSImage())
        arrow.contentTintColor = Design.mute
        let to = NSTextField(labelWithString: outcome)
        to.font = .systemFont(ofSize: 12)
        to.textColor = color
        to.lineBreakMode = .byTruncatingTail
        to.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        to.alignment = .right
        let row = NSStackView(views: [name, arrow, to])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor)])
        toolTip = enabled ? "Show it on the map" : outcome
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func mouseEntered(with event: NSEvent) { hovering = true; if enabled { NSCursor.pointingHand.set() } }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }
    override func mouseUp(with event: NSEvent) { if enabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() } }
    override func mouseDown(with event: NSEvent) {}
}

private final class MapFlippedView: NSView { override var isFlipped: Bool { true } }
