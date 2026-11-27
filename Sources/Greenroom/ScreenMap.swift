import AppKit
import UniformTypeIdentifiers

/// The screen map: a full-stage sheet that walks the app (the engine's crawler) and shows every screen it reached as
/// a graph, with the route to each. A finished walk becomes a snapshot (MapSnapshot) of the build's commit, filed in the
/// history when the build has one, and the map (MapHost: the navigator and the detail column) shows it, against the
/// baseline of that commit when the history has one. A strip of the stored snapshots (MapTimeline) re-compares any two.
/// "Go there" replays a screen's route on the selected device.
/// Where a walk of the selected build is kept and what it is compared with: the history store of its repository, the
/// build's commit and tree, and the baseline of that commit for a profile (nil: none). Nil context: the build has no
/// clean commit, so the walk is shown and not filed.
struct MapContext {
    var store: MapStore
    var commit: String
    var tree: String
    var engine: String
    var baseline: (MapProfile) async -> (snapshot: MapSnapshot, behind: Int)?
    /// The base branch's short name ("main") when the commit is on it: its map is what pull request diffs start from
    /// and are compared with. Nil for a commit of another branch.
    var baseBranch: String? = nil
    /// Whether a walk that was not signed in counts as a map of this repository (`Workspace.unsignedBaseline`).
    var unsignedCounts = true
}

final class ScreenMap: NSView {
    private(set) var isOpen = false
    var onSay: ((String, Bool) -> Void)?
    var onToggle: (() -> Void)?
    /// How far the running walk has got, each second while it runs; nil when it ends. Shown outside the sheet too.
    var onProgress: ((WalkProgress?) -> Void)?
    /// The selected simulator's APK, the default for a walk.
    var defaultAPK: () -> URL? = { nil }
    /// Replays a screen's route on the selected device.
    var onGo: ((MapScreen, ScreenMapData) -> Void)?
    /// The selected simulator's session worktree, whose `.greenroom/scripts` are offered for signing in too.
    var worktree: () -> URL? = { nil }
    /// The key of the app's kept sign-in (SignIns): the selected session's repository; nil keys it by the APK's name.
    var signInKey: () -> String? = { nil }
    /// "Sign In Once…": opens the app on a visible device (apk, key, the app's name; true when a sign-in was kept).
    var signInOnce: ((URL, String, String, @escaping (Bool) -> Void) -> Void)?
    private func keptKey(_ apk: URL) -> String { signInKey() ?? SignIns.key(apk: apk) }
    private var kept: SignIns.Record? { effectiveAPK.flatMap { SignIns.shared.record(keptKey($0)) } }
    /// The menu's choice is the kept sign-in.
    var usesKeptSignIn: Bool { signInPopup.selectedItem?.representedObject as? String == "kept" }
    /// The history a walked APK belongs to (see MapContext); nil: not in one.
    var context: (URL) async -> MapContext? = { _ in nil }

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
    /// Screens the running walk has finished with (the crawler's `--events`), and the devices it runs on.
    private var explored = 0
    private var devices = 1
    /// Between Walk and the crawler's start (its options are being asked).
    private var starting = false
    private var startedAt = Date()
    private var shownCombos: [String] = []
    private var lastSignedIn = false
    /// Whether closing the sheet during this walk has said that it goes on.
    private var toldBackground = false
    private(set) var progress: WalkProgress?

    private let dim = NSView()
    private let panel = GlassView(radius: 18)
    private let apkButton = GlassButton(symbol: "app.dashed", title: "Choose APK…", label: "Choose the APK to walk", style: .well, target: nil, action: nil)
    private let configButton = GlassButton(symbol: "slider.horizontal.3", title: "Whole app · No limit · Light ▾", label: "Configure walk depth, time, captures, sign-in and deep link", style: .well, target: nil, action: nil)
    private let configPopover = GlassView(radius: 14)
    private let depthPopup = NSPopUpButton()
    private let timePopup = NSPopUpButton()
    private let capturePopup = NSPopUpButton()
    private let offline = NSButton(checkboxWithTitle: "Walk offline (block network)", target: nil, action: nil)
    private let startField = NSTextField()
    private let signInPopup = NSPopUpButton()
    private let exportButton = GlassButton(symbol: "square.and.arrow.up", title: "Export…", label: "Export the map as a folder with an index.html anyone can open in a browser", style: .well, target: nil, action: nil)
    private let walkButton = GlassButton(symbol: "point.3.connected.trianglepath.dotted", title: "Walk the app", label: "Walk every screen the app has", style: .accent, target: nil, action: nil)
    /// While a walk runs: stops it and keeps nothing. With a paused walk: starts over instead of resuming.
    private let stopButton = GlassButton(symbol: nil, title: "Stop", label: "Stop the walk and keep nothing", style: .well, target: nil, action: nil)

    /// A walk that was paused: its folder (the engine writes what it found when it is stopped, with the screens still
    /// to open), the APK it was of, and the settings it ran with, which a walk that goes on from it must have too.
    struct Paused: Codable, Equatable {
        var folder: String
        var apk: String
        var found: Int
        var toOpen: Int
        var depth: Int
        var seconds: Int
        var appearances: [String]
        var start: String?
        var offline: Bool
    }
    private(set) var paused: Paused? {
        didSet {
            if let paused, let d = try? JSONEncoder().encode(paused) { UserDefaults.standard.set(d, forKey: "mapPaused") }
            else { UserDefaults.standard.removeObject(forKey: "mapPaused") }
        }
    }
    /// The paused walk, when it is of the APK shown and its folder is still there.
    private var pausedHere: Paused? {
        guard let p = paused, p.apk == effectiveAPK?.path, FileManager.default.fileExists(atPath: p.folder + "/crawl.json") else { return nil }
        return p
    }
    private var pausing = false
    /// What the map shows is a paused walk's part, not a finished walk.
    private var showsPaused = false
    /// What the finished walk relaunched for most, when that was most of its launches (RepoMapSettings.relaunchNote).
    private(set) var relaunchNote: String?
    private var walkOut: URL?
    /// The paused walk the running one goes on from.
    private var resumedFrom: URL?
    nonisolated static let resumedMarker = "greenroom-resumed"
    var pausedText: String? { pausedHere.map { Self.pausedWords($0) } }
    static func pausedWords(_ p: Paused) -> String {
        "Paused: \(p.found) screen\(p.found == 1 ? "" : "s") found" + (p.toOpen > 0 ? ", \(p.toOpen) still to open" : "") + ". Resume goes on from here; nothing found so far is walked again."
    }
    private let summary = NSTextField(labelWithString: "")
    private let crashChip = GlassButton(symbol: "exclamationmark.triangle.fill", title: "", label: "Show where it crashed", style: .record, target: nil, action: nil)
    private let comboControl = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    let host = MapHost()
    /// Before the first walk: what a walk does and what decides it (MapOnboarding).
    let onboarding = MapOnboarding()
    /// `[head] compared with [base]`.
    private let compareLabel = NSTextField(labelWithString: "")
    private let timeline = MapTimeline()
    private var timelineRow: NSView!

    /// What the map shows now: the walk as a snapshot, the store its pictures are in, the stored snapshots of its profile
    /// (oldest first) and the pair the strip compares.
    private(set) var snapshot: MapSnapshot?
    private var mapStore: MapStore?
    private var stored: [MapSnapshot] = []
    private var shownCompare: (head: String, base: String?)?
    private var loadedAPK: URL?
    private var generation = 0

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

        // Header: sleek single bar with APK pill, Walk Config popover pill, Export, Walk, Close.
        let title = label("Screen Map", size: 15, weight: .semibold, color: Design.ink)
        apkButton.target = self; apkButton.action = #selector(chooseAPK)
        apkButton.font = .systemFont(ofSize: 12, weight: .medium)
        apkButton.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        configButton.target = self; configButton.action = #selector(toggleConfigPopover)
        configButton.font = .systemFont(ofSize: 12, weight: .medium)
        let close = GlassButton(symbol: "xmark", label: "Close (Esc)", target: self, action: #selector(closePressed))
        walkButton.target = self; walkButton.action = #selector(walkPressed)
        stopButton.target = self; stopButton.action = #selector(stopPressed)
        stopButton.isHidden = true
        if let d = UserDefaults.standard.data(forKey: "mapPaused") { paused = try? JSONDecoder().decode(Paused.self, from: d) }
        let hs = NSView(); hs.setContentHuggingPriority(.init(1), for: .horizontal)
        exportButton.target = self; exportButton.action = #selector(exportPressed)
        exportButton.isEnabled = false
        let header = NSStackView(views: [title, apkButton, configButton, hs, exportButton, stopButton, walkButton, close])
        header.alignment = .centerY
        header.spacing = 10

        popup(depthPopup, ["1 tap deep", "2 taps deep", "3 taps deep", "4 taps deep", "6 taps deep", "Whole app"], key: "mapWalkDepth", default: 5)
        popup(timePopup, ["1 minute", "3 minutes", "5 minutes", "10 minutes", "30 minutes", "No time limit"], key: "mapWalkTime", default: 5)
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
        signInPopup.controlSize = .small
        signInPopup.font = .systemFont(ofSize: 12)
        signInPopup.target = self; signInPopup.action = #selector(signInChanged)
        signInPopup.toolTip = "Run one of your scripts (Device > Run Script) on a hidden device first, then walk signed in on its data. Your own devices' data is not touched."
        signInPopup.setAccessibilityLabel("Sign in before walking")

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

        // The map and its detail column.
        let mapWell = NSView()
        mapWell.wantsLayer = true
        mapWell.layer?.backgroundColor = NSColor(white: 0, alpha: 0.22).cgColor
        mapWell.layer?.cornerRadius = 12
        mapWell.layer?.cornerCurve = .continuous
        mapWell.layer?.masksToBounds = true
        let grid = StageBackground(frame: .zero)
        onboarding.onChoose = { [weak self] in self?.chooseAPK() }
        onboarding.onSignIn = { [weak self] in self?.beginSignInOnce() }
        onboarding.onWalk = { [weak self] in self?.walk() }
        for v in [grid, host, onboarding] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; mapWell.addSubview(v) }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: mapWell.topAnchor), grid.bottomAnchor.constraint(equalTo: mapWell.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: mapWell.leadingAnchor), grid.trailingAnchor.constraint(equalTo: mapWell.trailingAnchor),
            host.topAnchor.constraint(equalTo: mapWell.topAnchor), host.bottomAnchor.constraint(equalTo: mapWell.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: mapWell.leadingAnchor), host.trailingAnchor.constraint(equalTo: mapWell.trailingAnchor),
            onboarding.centerXAnchor.constraint(equalTo: mapWell.centerXAnchor), onboarding.centerYAnchor.constraint(equalTo: mapWell.centerYAnchor),
        ])
        host.isHidden = true
        host.onGo = { [weak self] lineage in self?.go(lineage) }
        host.onCopyRoute = { [weak self] text in self?.onSay?("Route copied: \(text.split(separator: "\n").count) control commands", false) }
        host.onPickCommit = { [weak self] commit in self?.pickBase(commit) }

        compareLabel.font = .systemFont(ofSize: 12, weight: .medium)
        compareLabel.textColor = Design.ink
        compareLabel.lineBreakMode = .byTruncatingTail
        compareLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        compareLabel.isHidden = true
        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.onChange = { [weak self] base, head in self?.compare(base: base, head: head) }
        timeline.isHidden = true
        timelineRow = timeline

        let body = mapWell
        let rule = NSView(); rule.wantsLayer = true; rule.layer?.backgroundColor = Design.stroke.cgColor
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let column = NSStackView(views: [header, rule, status, compareLabel, timeline, body])
        column.orientation = .vertical
        column.spacing = 10
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)
        for v in [header, rule, status, compareLabel, timeline, body] as [NSView] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        body.setContentHuggingPriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([column.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14), column.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
                                     column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18), column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18)])

        buildConfigPopover()
    }

    private func buildConfigPopover() {
        func fieldRow(_ name: String, _ control: NSView) -> NSStackView {
            let l = label(name, size: 11.5, weight: .medium, color: Design.mute)
            l.widthAnchor.constraint(equalToConstant: 74).isActive = true
            control.setContentHuggingPriority(.init(1), for: .horizontal)
            let r = NSStackView(views: [l, control])
            r.alignment = .centerY
            r.spacing = 8
            return r
        }
        let popTitle = label("Walk Configuration", size: 12.5, weight: .semibold, color: Design.ink)
        let popClose = GlassButton(symbol: "xmark", label: "Close configuration", target: self, action: #selector(closeConfigPopover))
        popClose.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let popSpacer = NSView(); popSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let popHeader = NSStackView(views: [popTitle, popSpacer, popClose])
        popHeader.alignment = .centerY

        let safetyBox = NSView()
        safetyBox.wantsLayer = true
        safetyBox.layer?.cornerRadius = 8
        safetyBox.layer?.cornerCurve = .continuous
        safetyBox.layer?.backgroundColor = Design.accent.withAlphaComponent(0.11).cgColor
        safetyBox.layer?.borderWidth = 1
        safetyBox.layer?.borderColor = Design.accent.withAlphaComponent(0.28).cgColor
        let shield = NSImageView(image: NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) ?? NSImage())
        shield.contentTintColor = Design.accent
        let safety = label("Never taps delete, buy, send, sign out and the like.", size: 11, color: Design.accent)
        safety.lineBreakMode = .byWordWrapping
        safety.maximumNumberOfLines = 2
        let safetyRow = NSStackView(views: [shield, safety])
        safetyRow.alignment = .centerY
        safetyRow.spacing = 7
        safetyRow.edgeInsets = NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)
        safetyRow.translatesAutoresizingMaskIntoConstraints = false
        safetyBox.addSubview(safetyRow)
        NSLayoutConstraint.activate([
            safetyRow.topAnchor.constraint(equalTo: safetyBox.topAnchor), safetyRow.bottomAnchor.constraint(equalTo: safetyBox.bottomAnchor),
            safetyRow.leadingAnchor.constraint(equalTo: safetyBox.leadingAnchor), safetyRow.trailingAnchor.constraint(equalTo: safetyBox.trailingAnchor),
        ])

        let rows: [NSView] = [
            popHeader,
            fieldRow("Depth", depthPopup),
            fieldRow("Time limit", timePopup),
            fieldRow("Captures", capturePopup),
            fieldRow("Sign-in", signInPopup),
            fieldRow("Deep link", startField),
            offline,
            safetyBox,
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in rows { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }

        let popTint = NSView()
        popTint.wantsLayer = true
        popTint.layer?.backgroundColor = NSColor(srgbRed: 0.105, green: 0.11, blue: 0.125, alpha: 0.90).cgColor
        popTint.layer?.cornerRadius = 14
        popTint.layer?.cornerCurve = .continuous
        popTint.translatesAutoresizingMaskIntoConstraints = false
        configPopover.addSubview(popTint)
        configPopover.addSubview(stack)
        configPopover.translatesAutoresizingMaskIntoConstraints = false
        configPopover.isHidden = true
        configPopover.layer?.shadowColor = NSColor.black.cgColor
        configPopover.layer?.shadowOpacity = 0.55
        configPopover.layer?.shadowRadius = 24
        configPopover.layer?.shadowOffset = CGSize(width: 0, height: -8)
        panel.addSubview(configPopover)
        NSLayoutConstraint.activate([
            popTint.topAnchor.constraint(equalTo: configPopover.topAnchor), popTint.bottomAnchor.constraint(equalTo: configPopover.bottomAnchor),
            popTint.leadingAnchor.constraint(equalTo: configPopover.leadingAnchor), popTint.trailingAnchor.constraint(equalTo: configPopover.trailingAnchor),
            stack.topAnchor.constraint(equalTo: configPopover.topAnchor), stack.bottomAnchor.constraint(equalTo: configPopover.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: configPopover.leadingAnchor), stack.trailingAnchor.constraint(equalTo: configPopover.trailingAnchor),
            configPopover.widthAnchor.constraint(equalToConstant: 350),
            configPopover.topAnchor.constraint(equalTo: configButton.bottomAnchor, constant: 8),
            configPopover.leadingAnchor.constraint(equalTo: configButton.leadingAnchor),
        ])
    }

    @objc private func toggleConfigPopover() {
        configPopover.isHidden.toggle()
        configButton.isOn = !configPopover.isHidden
    }

    @objc private func closeConfigPopover() {
        configPopover.isHidden = true
        configButton.isOn = false
    }

    private func refreshConfigSummary() {
        let depthStr = ["1 tap", "2 taps", "3 taps", "4 taps", "6 taps", "Whole app"][max(0, min(5, depthPopup.indexOfSelectedItem))]
        let timeStr = ["1m", "3m", "5m", "10m", "30m", "No limit"][max(0, min(5, timePopup.indexOfSelectedItem))]
        let capStr = ["Light", "Light & Dark", "No captures"][max(0, min(2, capturePopup.indexOfSelectedItem))]
        var parts = [depthStr, timeStr, capStr]
        if let s = signInScript { parts.append(s.name) }
        else if usesKeptSignIn { parts.append("Signed in") }
        if offline.state == .on { parts.append("Offline") }
        configButton.title = parts.joined(separator: " · ") + " ▾"
    }

    // MARK: Opening and closing

    func open() {
        guard !isOpen else { return }
        isOpen = true
        if pythonURL == nil { pythonURL = SnapshotRun.python() }
        reloadScripts()
        if !isWalking {
            if data == nil, let p = pausedHere, let part = ScreenMapData.read(URL(fileURLWithPath: p.folder)) {
                showsPaused = true
                present(part, animated: false, live: false)
                setSummary(Self.pausedWords(p))
            } else if let apk = effectiveAPK, data == nil || loadedAPK?.path != apk.path {
                loadStored(for: apk, fallbackToLastFolder: data == nil)
            } else if data == nil, let f = lastFolder, let last = ScreenMapData.read(f) {
                present(last, animated: false, live: false)
            }
        }
        refresh()
        isHidden = false
        alphaValue = 0
        panel.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: 8))
        window?.makeFirstResponder(host.navigator.surface)
        Design.animate(Design.arrive, {
            self.animator().alphaValue = 1
            self.panel.layer?.setAffineTransform(.identity)
        }, done: { if self.data != nil { self.host.settle() } })
        onToggle?()
    }

    /// Shows a finished run from another folder (Sessions' evidence) without starting a walk; false when the folder
    /// has no map or a walk is running here.
    @discardableResult
    func show(folder: URL) -> Bool {
        guard !isWalking, let d = ScreenMapData.read(folder) else { return false }
        present(d, animated: false, live: false)
        return true
    }

    /// A walk goes on when the sheet closes; the map is there when it opens again.
    func close() {
        guard isOpen else { return }
        isOpen = false
        closeConfigPopover()
        if isWalking, !toldBackground {
            toldBackground = true
            onSay?("The walk goes on in the background. The top bar shows how far it has got.", false)
        }
        Design.animate(Design.snap, { self.animator().alphaValue = 0 }, done: { if !self.isOpen { self.isHidden = true } })
        onToggle?()
    }

    @objc private func closePressed() { close() }
    override func cancelOperation(_ sender: Any?) {
        if !configPopover.isHidden { closeConfigPopover(); return }
        close()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) } else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !configPopover.isHidden {
            let pInPanel = panel.convert(event.locationInWindow, from: nil)
            if !configPopover.frame.contains(pInPanel) && !configButton.frame.contains(pInPanel) { closeConfigPopover() }
        }
        if !panel.frame.contains(p) { close() }
    }

    // MARK: Settings

    var effectiveAPK: URL? { apkURL ?? defaultAPK() }
    func setAPK(_ url: URL?) {
        apkURL = url
        refresh()
        if isOpen, !isWalking, let apk = effectiveAPK, loadedAPK?.path != apk.path {
            loadStored(for: apk, fallbackToLastFolder: false)
        }
    }

    var settings: CrawlRun.Settings {
        var s = CrawlRun.Settings()
        s.depth = [1, 2, 3, 4, 6, 0][max(0, depthPopup.indexOfSelectedItem)]   // 0: the whole app
        s.seconds = [60, 180, 300, 600, 1800, 0][max(0, timePopup.indexOfSelectedItem)]   // 0: no limit
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
    /// For checks: how many screens the running walk has found, and what the two buttons say.
    var knownScreens: Int { reached.known }
    var walkTitle: String { walkButton.title }
    var stopTitle: String { stopButton.isHidden ? "" : stopButton.title }
    /// Whether Export… is enabled, for checks.
    var canExportNow: Bool { exportButton.isEnabled }
    /// The `[head] compared with [base]` line and the strip, for checks.
    var compareText: String { compareLabel.stringValue }
    var timelineControl: MapTimeline { timeline }

    @objc private func settingChanged() {
        let d = UserDefaults.standard
        d.set(depthPopup.indexOfSelectedItem, forKey: "mapWalkDepth")
        d.set(timePopup.indexOfSelectedItem, forKey: "mapWalkTime")
        d.set(capturePopup.indexOfSelectedItem, forKey: "mapCaptures")
        d.set(offline.state == .on, forKey: "mapOffline")
        refresh()
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
        // The kept sign-in ("Sign In Once"), when the app has one: the choice unless a script was chosen.
        var keptAt: Int?
        if let k = kept {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
            signInPopup.addItem(withTitle: "Signed in (kept \(f.string(from: k.date)))")
            signInPopup.lastItem?.representedObject = "kept"
            keptAt = signInPopup.numberOfItems - 1
        }
        signInPopup.addItem(withTitle: kept == nil ? "Sign In Once…" : "Sign In Again…")
        signInPopup.lastItem?.representedObject = "once"
        signInPopup.lastItem?.toolTip = "Opens the app on a device you can see. Sign in as you would on a phone and press Use This Sign-In: walks then start signed in, on a copy of that device's data."
        signInPopup.addItem(withTitle: "New Sign-in Script…")
        signInPopup.lastItem?.representedObject = "new"
        let i = scripts.firstIndex { $0.name == wanted }.map { $0 + 1 } ?? (wanted == nil ? keptAt : nil) ?? 0
        signInPopup.selectItem(at: i)
        refreshConfigSummary()
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
        refreshConfigSummary()
    }

    /// For checks: the kept sign-in, when the app has one. False when it has none.
    @discardableResult
    func chooseKeptSignIn() -> Bool {
        reloadScripts()
        let i = signInPopup.indexOfItem(withRepresentedObject: "kept")
        if i >= 0 { signInPopup.selectItem(at: i) }
        refreshConfigSummary()
        return i >= 0
    }

    @objc private func signInChanged() {
        if signInPopup.selectedItem?.representedObject as? String == "new" {
            do { NSWorkspace.shared.open(try Scripts.newScript()) } catch { onSay?("Could not write a new script", true) }
            reloadScripts()
            return
        }
        if signInPopup.selectedItem?.representedObject as? String == "once" {
            reloadScripts()
            beginSignInOnce()
            return
        }
        UserDefaults.standard.set(signInScript?.name, forKey: "mapSignIn")
        refresh()
    }

    /// "Sign In Once…": the app on a device the person can see; when they keep the sign-in, walks start signed in.
    private func beginSignInOnce() {
        guard !isWalking, let apk = effectiveAPK, let begin = signInOnce else { return }
        let name = (apk.deletingPathExtension().lastPathComponent)
        begin(apk, keptKey(apk), signInKey().map { URL(fileURLWithPath: String($0.dropFirst(5))).lastPathComponent } ?? name) { [weak self] kept in
            guard let self else { return }
            if kept { UserDefaults.standard.removeObject(forKey: "mapSignIn") }
            self.reloadScripts()
            self.open()
            if kept { self.setSummary("Sign-in kept. Walk the app to map it signed in.") }
            self.refresh()
        }
    }

    var isWalking: Bool { signIn != nil || starting || run?.isRunning == true }

    /// This walk in the job queue (Jobs.swift): seen and acted on there from any session, while the sheet is closed too.
    private var ticket: QueueJob?

    /// Puts the walk that is starting in the job queue, or takes up the paused one it goes on from.
    private func enterQueue(apk: URL, resuming: Bool) {
        if resuming, let t = ticket, t.state == .paused { JobQueue.shared.resumed(t); return }
        if let t = ticket { JobQueue.shared.finish(t, .cancelled) }
        let t = QueueJob(kind: .map, title: "Map \(apk.deletingPathExtension().lastPathComponent)", owner: worktree()?.path, lane: nil, detail: "starting the walk")
        t.pauseTip = "Stop here and keep what was found: resuming goes on from it"
        t.onCancel = { [weak self, weak t] in
            guard let self, let t, self.ticket === t else { return }
            if self.isWalking { self.stop() } else { self.ticket = nil; JobQueue.shared.finish(t, .cancelled) }
        }
        t.onPause = { [weak self, weak t] in
            guard let self, let t, self.ticket === t, self.run?.isRunning == true else { return "The walk can be paused once it is walking." }
            self.pause()
            return nil
        }
        t.onResume = { [weak self, weak t] in
            guard let self, let t, self.ticket === t else { return }
            if !self.walk(resume: true) { self.ticket = nil; JobQueue.shared.finish(t, .cancelled) }
        }
        ticket = t
        JobQueue.shared.adopt(t)
    }

    @objc private func chooseAPK() {
        let p = NSOpenPanel()
        p.message = "Choose the APK to walk"
        p.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in if r == .OK, let u = p.url { self?.setAPK(u) } }
    }

    private func refresh() {
        if let apk = effectiveAPK {
            apkButton.title = apk.lastPathComponent + (apkURL == nil ? " · active" : "")
        } else {
            apkButton.title = "Choose APK…"
        }
        refreshConfigSummary()
        let running = isWalking
        let resumable = !running && pausedHere != nil
        walkButton.title = running ? (signIn != nil || starting ? "Stop walk" : "Pause walk") : (resumable ? "Resume walk" : (data == nil ? "Walk the app" : "Walk again"))
        walkButton.style = running ? .record : .accent
        walkButton.toolTip = running ? "Stop here and keep what was found: Resume goes on from it, now or after Greenroom was quit" : (resumable ? "Go on from where the walk was paused" : nil)
        stopButton.isHidden = !(resumable || (running && signIn == nil && !starting))
        stopButton.title = resumable ? "Start over" : "Stop"
        stopButton.toolTip = resumable ? "Forget the paused walk and walk the app from the beginning" : "Stop the walk and keep nothing"
        walkButton.isEnabled = running || (effectiveAPK != nil && pythonURL != nil)
        exportButton.isEnabled = !running && host.canExport
        for c in [depthPopup, timePopup, capturePopup, signInPopup, offline, startField] as [NSControl] { c.isEnabled = !running }
        if pythonURL == nil, !running {
            setSummary("The map needs Python 3, and this Mac has none. Install the command line tools (xcode-select --install in Terminal), then reopen this.", problem: true)
        }
        onboarding.isHidden = data != nil || running
        if !onboarding.isHidden { onboarding.show(onboardingState) }
        walkButton.isHidden = !onboarding.isHidden   // the card has its own Walk: one place to start
    }

    private var onboardingState: MapOnboarding.State {
        var s = MapOnboarding.State()
        s.app = effectiveAPK?.lastPathComponent
        s.appIsDevice = apkURL == nil
        if let script = signInScript { s.signIn = .script(script.name) }
        else if usesKeptSignIn, let k = kept {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
            s.signIn = .kept(f.string(from: k.date))
        }
        var reach = [depthPopup, timePopup, capturePopup].compactMap { $0.titleOfSelectedItem }
        if offline.state == .on { reach.append("offline") }
        s.reach = reach.joined(separator: ", ")
        s.noPython = pythonURL == nil
        return s
    }

    private func setSummary(_ text: String, problem: Bool = false) {
        summary.stringValue = text
        summary.textColor = problem ? Design.warning : Design.mute
    }

    // MARK: Walking

    @objc private func walkPressed() {
        closeConfigPopover()
        // A walk that is running is paused: what it found is kept, and Resume goes on from it.
        if isWalking { if signIn != nil || starting { stop() } else { pause() }; return }
        walk(resume: pausedHere != nil)
    }

    @objc private func stopPressed() {
        closeConfigPopover()
        if !isWalking {
            // "Start over": the paused walk is forgotten.
            paused = nil
            walk()
            return
        }
        guard Date().timeIntervalSince(run?.startedAt ?? startedAt) > 15, let w = window else { stop(); return }
        // A long walk is not thrown away by one press: what it found goes with it.
        let a = NSAlert()
        a.messageText = "Stop the walk and keep nothing?"
        a.informativeText = (reached.known > 0 ? "It has found \(reached.known) screen\(reached.known == 1 ? "" : "s") so far. " : "")
            + "Stopping keeps none of it, and the next walk starts from the beginning. Pause keeps what was found so the walk can go on later."
        a.addButton(withTitle: "Keep Walking")
        a.addButton(withTitle: "Pause Instead")
        a.addButton(withTitle: "Stop Walk")
        a.buttons[2].hasDestructiveAction = true
        a.beginSheetModal(for: w) { [weak self] r in
            if r == .alertSecondButtonReturn { self?.pause() } else if r == .alertThirdButtonReturn { self?.stop() }
        }
    }

    /// Stops the walk and keeps what it found: the engine writes its map so far and the screens still to open, and
    /// "Resume walk" goes on from there (`walk(resume:)`). Before anything is found there is nothing to keep.
    func pause() {
        guard let run, run.isRunning else { stop(); return }
        pausing = true
        setSummary("Pausing: the walk is writing down what it found…")
        run.cancel()
    }

    /// Stops the walk (or the sign-in before it), with nothing kept.
    func stop() {
        if let signIn { signIn.cancel(); return }
        if let run, run.isRunning { run.cancel(); return }
        if starting { starting = false; generation += 1; finished(.cancelled); return }
    }

    /// Starts a walk with the settings shown. False when there is nothing to walk or no Python.
    @discardableResult
    func walk(resume: Bool = false) -> Bool {
        guard !isWalking else { return true }
        guard let apk = effectiveAPK, let python = pythonURL ?? SnapshotRun.python() else { refresh(); return false }
        let from = resume ? pausedHere : nil
        enterQueue(apk: apk, resuming: from != nil)
        UserDefaults.standard.set(startField.stringValue, forKey: "mapStart")
        let base = Engine.shared.state.appendingPathComponent("maps", isDirectory: true)
        SnapshotRun.prune(base, keep: 5)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let out = base.appendingPathComponent("run-" + stamp)
        var walkSettings = settings
        showsPaused = false
        resumedFrom = nil
        walkOut = out
        if let from {
            // Going on from a paused walk: the same settings it ran with (the engine refuses another set of captures),
            // its folder as the seed, and the screens it had still to open as the ones to walk.
            let folder = URL(fileURLWithPath: from.folder)
            let json = (try? Data(contentsOf: folder.appendingPathComponent("crawl.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let ids = (json?["unexplored"] as? [String]) ?? []
            let only = folder.appendingPathComponent("resume-only.txt")
            try? Data((ids.joined(separator: "\n") + (ids.isEmpty ? "" : "\n")).utf8).write(to: only)
            walkSettings.depth = from.depth; walkSettings.seconds = from.seconds; walkSettings.appearances = from.appearances
            walkSettings.start = from.start; walkSettings.offline = from.offline
            walkSettings.seed = folder
            walkSettings.onlyFile = only
            resumedFrom = folder
        } else { paused = nil }
        lastSignedIn = signInScript != nil
        toldBackground = false
        data = nil
        reached = (from?.found ?? 0, 0)
        explored = from.map { max(0, $0.found - $0.toOpen) } ?? 0
        generation += 1
        snapshot = nil
        host.clear()
        host.isHidden = false
        onboarding.isHidden = true
        compareLabel.isHidden = true
        timeline.isHidden = true
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
                    ws.engineOptions = ["--data-slots", slot]
                    self.signedInSlot = slot
                    self.startCrawl(python: python, apk: apk, out: out, settings: ws)
                case .failed(let why): self.finished(.failed("signing in did not work. " + why))
                case .cancelled: self.finished(.cancelled)
                }
            }
        } else if usesKeptSignIn, let k = kept, case .cloned(let slot) = SlotClone.make(slot: k.slot, in: SignIns.dataRoot) {
            // The kept sign-in: the walk runs on a copy of its data, which goes when the walk ends.
            var ws = walkSettings
            ws.keepData = true
            ws.engineOptions = ["--data-slots", slot]
            signedInSlot = slot
            lastSignedIn = true
            startCrawl(python: python, apk: apk, out: out, settings: ws)
        } else {
            startCrawl(python: python, apk: apk, out: out, settings: walkSettings)
        }
        tick()
        refresh()
        return true
    }

    /// While a walk runs: what it will be once it ends ("It becomes the map of main at 753faed: pull request diffs
    /// start from it"). Nil until the build's place in the history is known, and for a build with none.
    private(set) var feedsNote: String?

    /// The repository of the walked build (its `.greenroom/map.json`): the context's, else the session's worktree.
    private var repoRoot: URL?

    private func startCrawl(python: URL, apk: URL, out: URL, settings: CrawlRun.Settings) {
        var settings = settings
        feedsNote = nil
        repoRoot = worktree()
        let whole = settings.depth == 0 && settings.seconds == 0 && (settings.start ?? "").isEmpty
        Task { @MainActor [weak self] in
            guard let self, let ctx = await self.context(apk) else { return }
            let sha = String(ctx.commit.prefix(7))
            if let name = ctx.baseBranch, !settings.keepData, !ctx.unsignedCounts {
                self.feedsNote = "This walk is not signed in, so it is not the map of \(name) that pull request diffs use: that one is walked signed in, to have every screen. Pick a sign-in above for it to count."
            } else if let name = ctx.baseBranch {
                self.feedsNote = whole ? "This walk becomes the map of \(name) at \(sha): pull request diffs start from it and are compared with it."
                    : "This walk is saved as a map of \(name) at \(sha), but pull request diffs use the map of the whole app with no limit."
            } else { self.feedsNote = "This walk is saved as the map of \(sha)." }
            self.tick()
        }
        devices = max(1, settings.jobs)
        let gen = generation
        starting = true
        startedAt = Date()
        // What this crawler offers is asked off the main thread (its --help, once); the walk starts when that is known.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let support = CrawlRun.support(python: python)
            let events = support.events
            DispatchQueue.main.async {
                guard let self, gen == self.generation, self.starting, self.run == nil else { return }
                self.starting = false
                settings.events = events
                settings.standby = support.standby
                settings.freezeNetwork = support.freezeNetwork
                settings.deterministic = support.deterministic
                if support.dataIgnore { settings.dataIgnore = RepoMapSettings.dataIgnore(in: self.repoRoot) }
                // What each screen depends on is recorded, so this walk can be the map a later walk starts from and a
                // pull request is compared with (without it, the next walk of the app is a full one again).
                settings.recordDeps = support.recordDeps
                let r = CrawlRun(python: python, apk: apk, out: out, settings: settings)
                self.run = r
                r.onEvent = { [weak self] e in self?.event(e) }
                r.onFinish = { [weak self] o in self?.finished(o) }
                r.start()
                self.tick()
                self.refresh()
            }
        }
        tick()
        refresh()
    }

    private func tick() {
        if signIn != nil {
            setSummary(signInStatus)
            report(WalkProgress(text: "Signing in to walk…", fraction: nil, detail: signInStatus))
            return
        }
        guard starting || run?.isRunning == true else { return }
        let s = Int(Date().timeIntervalSince(run?.startedAt ?? startedAt))
        let t = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        let signedIn = signedInSlot != nil ? ", signed in" : ""
        let on = devices == 1 ? "1 hidden device" : "\(devices) hidden devices"
        let whole = settings.depth == 0
        let screens = "\(reached.known) screen\(reached.known == 1 ? "" : "s")"
        let feeds = feedsNote.map { "\n" + $0 } ?? ""
        // The share of the screens found so far that are opened: it can go back as more are found, and is honest about that.
        let fraction = explored > 0 && reached.known > 0 ? min(1, Double(explored) / Double(reached.known)) : nil
        let detail: String, short: String
        if reached.known == 0 {
            detail = signedInSlot != nil ? "Starting the signed-in device…  \(t)" : "Starting \(on)…  \(t)"
            short = "Starting the walk…  \(t)"
        } else if reached.depth < 0 {
            detail = "Capturing \(screens)…  \(t)"
            short = "Capturing \(screens)  ·  \(t)"
        } else if whole {
            // The whole app: how much is found and how much of that is still to open (a count; how long it takes is not known before the end).
            let toOpen = explored > 0 && explored < reached.known ? reached.known - explored : 0
            detail = "Mapping the whole app\(signedIn): \(screens) found" + (toOpen > 0 ? ", \(toOpen) to open" : "") + "  ·  \(on)  ·  \(t)" + feeds
            short = "Mapping: \(screens)" + (toOpen > 0 ? ", \(toOpen) to open" : "") + "  ·  \(t)"
        } else {
            let deep = reached.depth == 0 ? "the first screen" : "\(reached.depth) tap\(reached.depth == 1 ? "" : "s") deep"
            detail = "Walking\(signedIn): \(deep), \(screens) found  ·  \(t)"
            short = "Walking: \(screens)  ·  \(t)"
        }
        setSummary(detail)
        report(WalkProgress(text: short, fraction: fraction, detail: detail))
    }

    private func report(_ p: WalkProgress?) {
        guard p != progress else { return }
        progress = p
        if let p, let t = ticket { JobQueue.shared.update(t, detail: p.text, fraction: .some(p.fraction)) }
        onProgress?(p)
    }

    private func event(_ e: CrawlRun.Event) {
        switch e {
        case .level(let depth, let exploring, let known):
            reached = (depth, known)
            host.walkReached(depth: depth, exploring: exploring)
        case .capturing(let screens, _):
            if settings.appearances.isEmpty { return }
            reached = (-1, screens)
        case .screen(_, let title, let depth, let wasExplored):
            guard wasExplored else { return }
            explored += 1
            host.walkExplored(depth: depth, title: title)
        case .line: return
        }
        tick()
    }

    private func finished(_ outcome: CrawlRun.Outcome) {
        ticker?.invalidate()
        ticker = nil
        report(nil)
        spinner.stopAnimation(nil)
        if let slot = signedInSlot {
            signedInSlot = nil
            DispatchQueue.global(qos: .utility).async { MapSignIn.discard(slot) }
        }
        let wasPausing = pausing
        pausing = false
        switch outcome {
        case .cancelled where wasPausing:
            // Paused: the engine wrote what it found. That is shown, and kept for "Resume walk".
            let s = settings
            if let out = walkOut, let part = ScreenMapData.read(out), !part.screens.isEmpty, let apk = effectiveAPK {
                let json = (try? Data(contentsOf: out.appendingPathComponent("crawl.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let was = resumedFrom.flatMap { _ in paused }
                if resumedFrom != nil { try? Data().write(to: out.appendingPathComponent(Self.resumedMarker)) }
                let p = Paused(folder: out.path, apk: apk.path, found: part.screens.count, toOpen: ((json?["unexplored"] as? [String]) ?? []).count,
                               depth: was?.depth ?? s.depth, seconds: was?.seconds ?? s.seconds, appearances: was?.appearances ?? s.appearances,
                               start: was?.start ?? s.start, offline: was?.offline ?? s.offline)
                paused = p
                showsPaused = true
                present(part, animated: isOpen, live: false)
                setSummary(Self.pausedWords(p))
                onSay?("Walk paused: \(p.found) screens found", false)
                if let t = ticket { JobQueue.shared.suspended(t, detail: "\(p.found) screen\(p.found == 1 ? "" : "s") found, \(p.toOpen) to open") }
            } else {
                host.clear()
                setSummary("Paused before the walk had found anything to keep: the next walk starts from the beginning.")
            }
        case .finished(let map):
            if let t = ticket { JobQueue.shared.finish(t, .done, detail: "\(map.screens.count) screen\(map.screens.count == 1 ? "" : "s")" + (map.crashes.isEmpty ? "" : ", \(map.crashes.count) crash\(map.crashes.count == 1 ? "" : "es")")) }
            relaunchNote = RepoMapSettings.relaunchNote(map.folder)
            if resumedFrom != nil { try? Data().write(to: map.folder.appendingPathComponent(Self.resumedMarker)) }
            paused = nil
            lastFolder = map.folder
            present(map, animated: isOpen)
            let crashes = map.crashes.count
            onSay?("Screen map: \(map.screens.count) screens" + (crashes > 0 ? ", \(crashes) crash\(crashes == 1 ? "" : "es")" : ""), crashes > 0)
        case .failed(let why):
            if let t = ticket { JobQueue.shared.finish(t, .failed(why)) }
            host.clear()
            setSummary("The walk failed: " + why, problem: true)
            onSay?("The walk failed", true)
        case .cancelled:
            host.clear()
            setSummary("Walk stopped.")
        }
        // Whatever did not end paused, done or failed above was stopped.
        if let t = ticket, t.state != .paused {
            if t.isActive { JobQueue.shared.finish(t, .cancelled) }
            ticket = nil
        }
        run = nil
        resumedFrom = nil
        refresh()
    }

    /// Shows a finished walk: the summary line and its chips at once, then the map once the walk is a snapshot (and,
    /// when the build has a commit, compared with its baseline).
    private func present(_ map: ScreenMapData, animated: Bool, live: Bool = true) {
        loadedAPK = map.apk ?? effectiveAPK
        applyPresentation(map, live: live)
        generation += 1
        let mine = generation
        let apk = live ? (map.apk ?? effectiveAPK) : nil
        let settings = self.settings, signedIn = lastSignedIn
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ctx = apk != nil ? await self.context(apk!) : nil
            let profile = Evidence.profile(depth: settings.depth, seconds: settings.seconds, appearances: settings.appearances, start: settings.start, signedIn: signedIn, offline: settings.offline)
            let engine = Engine.shared.version
            let made = await Task.detached { await ScreenMap.makeSource(map, context: ctx, profile: profile, engine: engine) }.value
            guard self.generation == mine, let made else {
                if self.generation == mine { self.setSummary("The map could not be read back after the walk.", problem: true) }
                return
            }
            self.show(made, animated: animated)
        }
    }

    private func applyPresentation(_ map: ScreenMapData, live: Bool) {
        data = map
        let transitions = map.edges.filter { if case .screen = $0.to { return true } else { return false } }.count
        var parts = ["\(map.screens.count) screens", "\(transitions) transitions"]
        let unexplored = map.incomplete.first { $0.hasPrefix("--max-depth") }.map { _ in "deepest level not opened" }
        let outOfTime = map.incomplete.contains { $0.hasPrefix("--max-seconds") } ? "stopped at the time limit" : nil
        parts += [unexplored, outOfTime].compactMap { $0 }
        parts.append(String(format: "%.0f s", map.seconds))
        // A sign-in the walk met: said after the counts, with what to do about it.
        let wall = live ? SignInWall.find(map).note(kept: lastSignedIn) : nil
        setSummary(map.apkName + "  ·  " + parts.joined(separator: "  ·  ") + (wall.map { "\n" + $0.replacingOccurrences(of: "\"Sign In Once…\"", with: "\"Sign In Once…\" in the sign-in menu").replacingOccurrences(of: "\"Sign In Again…\"", with: "\"Sign In Again…\" in the sign-in menu") } ?? "")
                   + ((live ? relaunchNote : nil).map { "\n" + $0 } ?? ""), problem: wall != nil)
        let crashes = map.crashes.count
        crashChip.isHidden = crashes == 0
        crashChip.title = crashes == 1 ? "1 crash" : "\(crashes) crashes"
        let combos = map.combos.filter { c in map.screens.contains { $0.captures.contains { $0.combo == c } } }
        shownCombos = combos
        comboControl.segmentCount = combos.count
        for (i, c) in combos.enumerated() { comboControl.setLabel(c.contains("dark") ? "Dark" : (c.contains("light") ? "Light" : c), forSegment: i) }
        comboControl.selectedSegment = 0
        comboControl.isHidden = combos.count < 2
        onboarding.isHidden = true
        host.isHidden = false
    }

    /// Loads an existing stored snapshot for `apk`'s commit from the repository's `MapStore` so reopening the sheet on
    /// an already-walked build (such as `main`) shows its map instead of the onboarding card.
    private func loadStored(for apk: URL, fallbackToLastFolder: Bool) {
        generation += 1
        let mine = generation
        let s = self.settings
        let signedIn = signInScript != nil || usesKeptSignIn
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let ctx = await self.context(apk) {
                var preferred: [MapProfile] = [
                    Evidence.profile(depth: s.depth, seconds: s.seconds, appearances: s.appearances, start: s.start, signedIn: signedIn, offline: s.offline),
                    Evidence.profile(depth: 0, seconds: 0, appearances: ["light"], start: nil, signedIn: true, offline: false),
                ]
                if ctx.unsignedCounts {
                    preferred.append(Evidence.profile(depth: 0, seconds: 0, appearances: ["light"], start: nil, signedIn: false, offline: false))
                }
                let loaded = await Task.detached { await ScreenMap.loadStoredMade(context: ctx, preferred: preferred, apk: apk) }.value
                guard self.generation == mine, !self.isWalking else { return }
                if let (map, made) = loaded {
                    self.showsPaused = false
                    self.loadedAPK = apk
                    self.applyPresentation(map, live: false)
                    self.show(made, animated: false)
                    return
                }
            }
            guard self.generation == mine, !self.isWalking else { return }
            if fallbackToLastFolder, self.data == nil, let f = self.lastFolder, let last = ScreenMapData.read(f) {
                self.present(last, animated: false, live: false)
            }
        }
    }

    nonisolated static func loadStoredMade(context ctx: MapContext, preferred: [MapProfile], apk: URL) async -> (ScreenMapData, Made)? {
        func find(_ profileID: String) -> MapSnapshot? {
            ctx.store.snapshot(profile: profileID, commit: ctx.commit) ?? ctx.store.snapshot(profile: profileID, tree: ctx.tree)
        }
        var snap: MapSnapshot?
        var seen = Set<String>()
        for p in preferred where seen.insert(p.id).inserted {
            if let hit = find(p.id) { snap = hit; break }
        }
        if snap == nil {
            let others = ctx.store.profiles().filter { !seen.contains($0) }.compactMap(find)
            snap = others.sorted {
                let aSigned = $0.profile.signIn != nil, bSigned = $1.profile.signIn != nil
                if aSigned != bSigned { return aSigned }
                return ($0.walked, $0.commit) > ($1.walked, $1.commit)
            }.first
        }
        guard let snap else { return nil }
        let found = await ctx.baseline(snap.profile)
        let base = found.flatMap { $0.snapshot.commit == snap.commit ? nil : $0 }
        let stored = loadStored(ctx.store, profile: snap.profile.id)
        let src = MapSource.make(head: snap, base: base?.snapshot, history: stored.isEmpty ? [snap] : stored, blobURL: { ctx.store.blobURL($0) })
        let made = Made(source: src, store: ctx.store, stored: stored, filed: true, baselineBehind: base?.behind, baselineCommit: base?.snapshot.commit,
                        baseBranch: ctx.baseBranch, hasDeps: snap.startDeps != nil, counts: snap.profile.signIn != nil || ctx.unsignedCounts)
        return (ScreenMapData.from(snapshot: snap, store: ctx.store, apk: apk), made)
    }

    /// What a finished walk becomes: its snapshot (filed in the context's store when the build has a commit, else kept
    /// apart and unsaved), its baseline when there is one, and the stored snapshots of the profile.
    struct Made {
        var source: MapSource
        var store: MapStore
        var stored: [MapSnapshot]
        var filed: Bool
        var baselineBehind: Int?
        var baselineCommit: String?
        /// The base branch's name when this walk is its map; whether it recorded what its screens depend on.
        var baseBranch: String? = nil
        var hasDeps = false
        /// False for a walk that was not signed in where only signed-in walks count as a map of the base branch.
        var counts = true
    }

    nonisolated static func makeSource(_ map: ScreenMapData, context ctx: MapContext?, profile: MapProfile, engine: String) async -> Made? {
        let folder = map.folder
        let walked = Date()
        if let ctx {
            // A walk that went on from a paused one is one walk of this commit: what it took over was walked here too.
            let resumed = FileManager.default.fileExists(atPath: folder.appendingPathComponent(ScreenMap.resumedMarker).path)
            guard let imported = ctx.store.importWalk(folder, commit: ctx.commit, tree: ctx.tree, profile: profile, engine: engine, walked: walked, continuation: resumed) else { return nil }
            let found = await ctx.baseline(profile)
            // A baseline that is this commit's own snapshot says nothing: the map opens plain.
            let base = found.flatMap { $0.snapshot.commit == ctx.commit ? nil : $0 }
            let (paired, _) = MapPairing.pair(head: imported, base: base?.snapshot)
            var filed = true
            // A commit's map is kept once, except that a walk that recorded what its screens depend on takes the place
            // of one that did not (only such a map can be what later walks start from), as a full walk does of one
            // that carried screens.
            let was = ctx.store.snapshot(profile: profile.id, commit: ctx.commit)
            let better = was.map { ($0.startDeps == nil && paired.startDeps != nil) || $0.screens.contains { $0.carriedFrom != nil } } ?? true
            if better { filed = ctx.store.save(paired) }
            let kept = better ? paired : (was ?? paired)
            let stored = loadStored(ctx.store, profile: profile.id)
            let src = MapSource.make(head: paired, base: base?.snapshot, history: stored.isEmpty ? [paired] : stored, blobURL: { ctx.store.blobURL($0) })
            return Made(source: src, store: ctx.store, stored: stored, filed: filed, baselineBehind: base?.behind, baselineCommit: base?.snapshot.commit,
                        baseBranch: ctx.baseBranch, hasDeps: kept.startDeps != nil, counts: profile.signIn != nil || ctx.unsignedCounts)
        }
        // No commit: an import into a store of its own, never filed.
        let root = Engine.shared.state.appendingPathComponent("maps-unsaved", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let store = MapStore(root: root, repo: "walk")
        let commit = "walk" + String(Int(walked.timeIntervalSince1970))
        guard let imported = store.importWalk(folder, commit: commit, tree: "", profile: profile, engine: engine, walked: walked) else { return nil }
        let src = MapSource.make(head: imported, base: nil, history: [], blobURL: { store.blobURL($0) })
        return Made(source: src, store: store, stored: [], filed: false, baselineBehind: nil, baselineCommit: nil)
    }

    /// The stored snapshots of a profile, oldest first, the newest fifty.
    nonisolated static func loadStored(_ store: MapStore, profile: String) -> [MapSnapshot] {
        let all = store.commits(profile: profile).compactMap { store.snapshot(profile: profile, commit: $0) }.sorted { ($0.walked, $0.commit) < ($1.walked, $1.commit) }
        return Array(all.suffix(50))
    }

    private func show(_ made: Made, animated: Bool) {
        snapshot = made.source.head
        mapStore = made.store
        stored = made.stored
        host.setCombo(shownCombos.first ?? "light")
        comboControl.selectedSegment = 0
        host.show(made.source)
        shownCompare = (made.source.head.commit, made.source.base?.commit)
        compareLabel.isHidden = false
        compareLabel.stringValue = headerText(made)
        // The strip, over the stored snapshots when there are two or more.
        if made.stored.count >= 2, made.filed {
            let entries = ScreenMap.timelineEntries(made.stored)
            timeline.show(entries, base: made.baselineCommit ?? made.source.base?.commit, head: made.source.head.commit)
            timeline.isHidden = false
        } else { timeline.isHidden = true }
        if isOpen { DispatchQueue.main.async { self.host.settle() } }
        host.select(made.source.head.screens.first?.lineage, reveal: false)
        refresh()
    }

    // MARK: Export

    /// The two names the export's page shows: the walk (or its commit), and the baseline's commit.
    private var exportNames: (base: String, head: String) {
        guard let s = host.source else { return ("", "") }
        return (s.base.map { String($0.commit.prefix(7)) } ?? "", s.head.commit.hasPrefix("walk") ? "this walk" : String(s.head.commit.prefix(7)))
    }

    @objc private func exportPressed() {
        guard !isWalking else { return }
        let title = (data?.apkName.isEmpty == false ? data!.apkName : effectiveAPK?.lastPathComponent) ?? "App"
        host.exportWithPanel(title: "Screen map of " + title, names: exportNames, suggested: "map-export") { [weak self] r in self?.exported(r) }
    }

    /// For checks: exports to `folder` with no panel.
    func exportNow(to folder: URL, done: @escaping (Result<URL, Error>) -> Void) {
        let title = (data?.apkName.isEmpty == false ? data!.apkName : effectiveAPK?.lastPathComponent) ?? "App"
        host.export(to: folder, title: "Screen map of " + title, names: exportNames) { [weak self] r in self?.exported(r, reveal: false); done(r) }
    }

    private func exported(_ r: Result<URL, Error>, reveal: Bool = true) {
        switch r {
        case .success(let index):
            setSummary("Exported to \(index.deletingLastPathComponent().path)")
            onSay?("Map exported", false)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([index]) }
        case .failure(let e):
            setSummary("The export failed: \(e.localizedDescription)", problem: true)
            onSay?("The export failed", true)
        }
    }

    /// `[head] compared with [base]`, and how far behind the baseline is.
    private func headerText(_ m: Made) -> String {
        if showsPaused { return "a paused walk  ·  not saved yet: it is saved once it has finished" }
        let head = m.filed ? "\(String(m.source.head.commit.prefix(7)))" : "this walk"
        // What the saved walk is for: the base branch's map is what pull request diffs start from.
        let whole = m.source.head.profile.depth == 0 && m.source.head.profile.seconds == 0 && m.source.head.profile.starts.isEmpty
        var feeds = ""
        if m.filed, let name = m.baseBranch {
            if !m.counts { feeds = "saved, but not signed in, so it is not the map of \(name) that pull request diffs use (that one is walked signed in, to have every screen)" }
            else if !m.hasDeps { feeds = "saved as the map of \(name), but with no record of what its screens depend on, so a pull request's walk cannot start from it" }
            else if whole { feeds = "saved as the map of \(name): pull request diffs start from it and are compared with it" + (m.source.head.cutShort ? " (the walk was cut short, so screens may be missing)" : "") }
            else { feeds = "saved as a map of \(name) with these limits; pull request diffs use the map of the whole app with no limit" }
        }
        guard let base = m.source.base else {
            if !feeds.isEmpty { return "\(head)  ·  \(feeds)" }
            return m.filed ? "\(head)  ·  saved to the history  ·  the first map of this app: later walks are compared with it"
                           : "\(head)  ·  not saved to the history: the build has no commit, or was made with uncommitted changes"
        }
        let behind = m.baselineBehind.map { $0 > 0 ? "  ·  the baseline is \($0) commit\($0 == 1 ? "" : "s") behind" : "" } ?? ""
        let c = m.source.diff?.counts
        let changes = c.map { $0.differing == 0 ? "  ·  nothing changed" : "  ·  \($0.added) new, \($0.modified) changed, \($0.removed) gone" } ?? ""
        return "\(head) compared with \(String(base.commit.prefix(7)))" + behind + changes + (feeds.isEmpty ? "" : "  ·  " + feeds)
    }

    nonisolated static func timelineEntries(_ list: [MapSnapshot]) -> [MapTimelineEntry] {
        let fmt = ISO8601DateFormatter()
        return list.enumerated().map { i, s in
            let c = i == 0 ? MapDiff.Counts() : MapPairing.diff(head: s, base: list[i - 1]).counts
            return MapTimelineEntry(commit: s.commit, label: String(s.commit.prefix(7)), date: fmt.date(from: s.walked), tag: nil, added: c.added, removed: c.removed, modified: c.modified)
        }
    }

    /// The strip moved: the pair's two snapshots are compared again and the map redrawn in place.
    private func compare(base: String, head: String) {
        guard let store = mapStore, let list = Optional(stored), let h = list.first(where: { $0.commit == head }), let b = list.first(where: { $0.commit == base }) else { return }
        generation += 1
        let mine = generation
        Task { @MainActor [weak self] in
            let src = await Task.detached { MapSource.make(head: h, base: b, history: list, blobURL: { store.blobURL($0) }) }.value
            guard let self, self.generation == mine else { return }
            self.host.show(src, keepingPlace: true)
            self.snapshot = src.head
            self.shownCompare = (head, base)
            let m = Made(source: src, store: store, stored: list, filed: true, baselineBehind: nil, baselineCommit: base)
            self.compareLabel.stringValue = self.headerText(m)
        }
    }

    /// A filmstrip frame was pressed: that commit becomes the base.
    private func pickBase(_ commit: String) {
        guard let head = timeline.head, !timeline.isHidden, let b = timeline.entries.firstIndex(where: { $0.commit.hasPrefix(commit) || commit.hasPrefix($0.commit) }) else { return }
        _ = head
        timeline.set(base: b)
    }

    @objc private func showCrash() {
        guard let map = data, let crash = map.crashes.first, let src = host.source else { return }
        // The screen the crashing control was on: the longest route the crash's own route begins with.
        let at = map.screens.filter { crash.steps.starts(with: $0.steps) }.max { $0.steps.count < $1.steps.count }
        if let at, let lineage = src.lineage(ofHeadScreen: at.id) { host.select(lineage) }
        onSay?(crash.detail.split(separator: "\n").first.map(String.init) ?? "Crash", true)
    }

    @objc private func comboChanged() {
        let i = comboControl.selectedSegment
        if shownCombos.indices.contains(i) { host.setCombo(shownCombos[i]) }
    }

    // MARK: Zoom

    @objc private func zoomIn() { host.zoom(by: 1.25) }
    @objc private func zoomOut() { host.zoom(by: 0.8) }
    @objc private func zoomToFit() { host.fit() }

    /// A control command as a person would say it.
    static func describe(_ cmd: String) -> String {
        if cmd.hasPrefix("tap-text ") { return "Tap “\(cmd.dropFirst(9))”" }
        if cmd.hasPrefix("tap ") { return "Tap at " + cmd.dropFirst(4).replacingOccurrences(of: " ", with: ", ") }
        if cmd.hasPrefix("drag ") { return "Scroll down" }
        if cmd.hasPrefix("type") { return "Type text" }
        return cmd
    }

    /// "Go there" for the screen with this lineage: only the walk's own screens have a route to replay.
    private func go(_ lineage: String) {
        guard let map = data, let src = host.source, let id = src.head.screens.first(where: { $0.lineage == lineage })?.id, let s = map.screen(id) else {
            onSay?("That screen is not in this walk, so there is no route to replay", true)
            return
        }
        onGo?(s, map)
    }
}
