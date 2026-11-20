import AppKit
import UniformTypeIdentifiers

// MARK: Pieces

/// A picture fitted into a rounded box on a well, with a line of text when there is none.
final class SnapshotPicture: NSView {
    private let note = NSTextField(labelWithString: "")
    private(set) var image: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspect
        note.font = .systemFont(ofSize: 12)
        note.textColor = Design.mute
        note.alignment = .center
        note.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)
        NSLayoutConstraint.activate([note.centerXAnchor.constraint(equalTo: centerXAnchor), note.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ image: CGImage?, empty: String) {
        self.image = image
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
        note.stringValue = image == nil ? empty : ""
    }
}

/// Golden under actual, with a line you drag: left of it the golden, right of it the actual.
final class SnapshotWipe: NSView {
    private let base = CALayer(), top = CALayer(), mask = CALayer(), handle = CALayer(), knob = CALayer()
    private let note = NSTextField(labelWithString: "")
    var position: CGFloat = 0.5 { didSet { position = min(1, max(0, position)); layoutSplit(); onChange?(position) } }
    var onChange: ((CGFloat) -> Void)?
    private var imageSize = CGSize.zero

    /// Where the picture lies in the view (aspect fit), which the line moves across.
    private var fit: CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0 else { return bounds }
        let k = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * k, h = imageSize.height * k
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        for l in [base, top] { l.contentsGravity = .resizeAspect; layer?.addSublayer(l) }
        top.mask = mask
        mask.backgroundColor = NSColor.black.cgColor
        handle.backgroundColor = Design.accent.cgColor
        knob.backgroundColor = Design.accent.cgColor
        knob.cornerRadius = 9
        layer?.addSublayer(handle)
        layer?.addSublayer(knob)
        note.font = .systemFont(ofSize: 12)
        note.textColor = Design.mute
        note.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)
        NSLayoutConstraint.activate([note.centerXAnchor.constraint(equalTo: centerXAnchor), note.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// `golden` is the left side, `actual` the right.
    func show(golden: CGImage?, actual: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.contents = actual
        top.contents = golden
        if let i = actual ?? golden { imageSize = CGSize(width: i.width, height: i.height) }
        CATransaction.commit()
        note.stringValue = golden == nil && actual == nil ? "Nothing to compare" : (golden == nil ? "No golden yet" : "")
        layoutSplit()
    }

    override func layout() { super.layout(); layoutSplit() }

    private func layoutSplit() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in [base, top] { l.frame = bounds }
        let f = fit
        let x = f.minX + f.width * position
        mask.frame = CGRect(x: 0, y: 0, width: x, height: bounds.height)
        handle.frame = CGRect(x: x - 1, y: f.minY, width: 2, height: f.height)
        knob.frame = CGRect(x: x - 9, y: bounds.midY - 9, width: 18, height: 18)
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { drag(event) }
    override func mouseDragged(with event: NSEvent) { drag(event) }
    private func drag(_ e: NSEvent) { let f = fit; if f.width > 0 { position = (convert(e.locationInWindow, from: nil).x - f.minX) / f.width } }
}

/// One tile of the grid: the actual picture, the screen and combination, and how it compares.
final class SnapshotTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("snapshot-tile")
    private let picture = SnapshotPicture()
    private let nameLabel = NSTextField(labelWithString: "")
    private let combo = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let dot = NSView()
    private(set) var resultID = ""

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.cornerCurve = .continuous
        v.layer?.backgroundColor = Design.well.cgColor
        v.layer?.borderWidth = 2
        v.layer?.borderColor = NSColor.clear.cgColor
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.textColor = Design.ink
        combo.font = .systemFont(ofSize: 10)
        combo.textColor = Design.mute
        status.font = .systemFont(ofSize: 11, weight: .medium)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        for l in [nameLabel, combo, status] { l.lineBreakMode = .byTruncatingTail }
        for s in [picture, nameLabel, combo, status, dot] as [NSView] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: v.topAnchor, constant: 6), picture.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            picture.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6), picture.heightAnchor.constraint(equalToConstant: 168),
            nameLabel.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 6), nameLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            combo.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1), combo.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            combo.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), dot.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            status.topAnchor.constraint(equalTo: combo.bottomAnchor, constant: 3), status.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            status.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
        ])
        view = v
    }

    static func color(_ kind: SnapshotResult.Kind) -> NSColor {
        switch kind {
        case .same, .recorded: return Design.accent
        case .different: return Design.difference
        case .new, .updated: return Design.warning
        case .error: return Design.record
        }
    }

    func configure(_ r: SnapshotResult) {
        resultID = r.id
        nameLabel.stringValue = r.screen
        combo.stringValue = r.combo
        status.stringValue = r.statusText
        status.textColor = Self.color(r.kind)
        dot.layer?.backgroundColor = Self.color(r.kind).cgColor
        picture.show(nil, empty: r.kind == .error ? "no picture" : "")
        if let url = r.actual {
            let id = r.id
            SnapshotImages.load(url, maxPixel: 420) { [weak self] image in
                if self?.resultID == id { self?.picture.show(image, empty: "") }
            }
        }
        refreshSelection()
    }

    override var isSelected: Bool { didSet { refreshSelection() } }
    private func refreshSelection() {
        view.layer?.borderColor = (isSelected ? Design.accent : NSColor.clear).cgColor
        view.layer?.backgroundColor = (isSelected ? Design.wellOn : Design.well).cgColor
    }
}

// MARK: The review

/// Screenshot tests: a spec's screens in every combination of the engine's `snapshot.py`, compared with their
/// goldens. A glass sheet over the stage, closed with Escape.
final class SnapshotReview: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    /// A toast, for the window to show.
    var onSay: ((String, Bool) -> Void)?
    /// The APK of the simulator selected in the window, used while none was chosen here.
    var defaultAPK: () -> URL? = { nil }
    var onToggle: (() -> Void)?
    private(set) var isOpen = false

    // Setup, remembered between launches.
    private(set) var specURL: URL? { didSet { UserDefaults.standard.set(specURL?.path, forKey: "snapshotSpec") } }
    private(set) var apkURL: URL? { didSet { UserDefaults.standard.set(apkURL?.path, forKey: "snapshotAPK") } }
    private var goldensOverride: URL? { didSet { UserDefaults.standard.set(goldensOverride?.path, forKey: "snapshotGoldens") } }
    private(set) var results: [SnapshotResult] = []
    private var runFolder: URL? { didSet { UserDefaults.standard.set(runFolder?.path, forKey: "snapshotRun") } }
    private(set) var run: SnapshotRun?
    private var filter = 0   // all, different, new, errors
    private var shown: [SnapshotResult] = []
    private(set) var selectedID: String?
    private var differences: [String: CGImage] = [:]
    private var pythonURL: URL? = SnapshotRun.python()

    // Views.
    private let dim = NSView()
    private let panel = GlassView(radius: 18)
    private let specLabel = NSTextField(labelWithString: "")
    private let apkLabel = NSTextField(labelWithString: "")
    private let goldensLabel = NSTextField(labelWithString: "")
    private let runButton = GlassButton(symbol: "play.fill", title: "Run", label: "Run the screenshot tests", style: .accent, target: nil, action: nil)
    private let recordButton = GlassButton(symbol: "record.circle", title: "Record goldens", label: "Capture every screen and keep it as the golden", style: .well, target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let filterControl = NSSegmentedControl(labels: ["All", "Different", "New", "Errors"], trackingMode: .selectOne, target: nil, action: nil)
    private let acceptDifferent = GlassButton(symbol: "checkmark.circle", title: "Accept all different", label: "Keep every different capture as its golden", style: .well, target: nil, action: nil)
    private let acceptNew = GlassButton(symbol: "plus.circle", title: "Accept all new", label: "Keep every new capture as its golden", style: .well, target: nil, action: nil)
    private let collection = NSCollectionView()
    private let emptyNote = NSTextField(wrappingLabelWithString: "")
    // Detail.
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailStatus = NSTextField(wrappingLabelWithString: "")
    private let modeControl = NSSegmentedControl(labels: ["Side by side", "Wipe"], trackingMode: .selectOne, target: nil, action: nil)
    private let acceptButton = GlassButton(symbol: "checkmark", title: "Accept as golden", label: "Copy this capture over its golden", style: .accent, target: nil, action: nil)
    private let goldenPane = SnapshotPicture(), actualPane = SnapshotPicture(), diffPane = SnapshotPicture()
    private let wipe = SnapshotWipe()
    private let wipeSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var sideBySide = NSStackView()
    private var wipeBox = NSStackView()
    private var detailBody = NSView()
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        appearance = NSAppearance(named: .darkAqua)
        let d = UserDefaults.standard
        specURL = d.string(forKey: "snapshotSpec").map { URL(fileURLWithPath: $0) }
        apkURL = d.string(forKey: "snapshotAPK").map { URL(fileURLWithPath: $0) }
        goldensOverride = d.string(forKey: "snapshotGoldens").map { URL(fileURLWithPath: $0) }
        runFolder = d.string(forKey: "snapshotRun").map { URL(fileURLWithPath: $0) }
        build()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Layout

    private func label(_ t: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = Design.mute) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

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

        // Header.
        let title = label("Screenshot tests", size: 15, weight: .semibold, color: Design.ink)
        let close = GlassButton(symbol: "xmark", label: "Close (Esc)", target: self, action: #selector(closePressed))
        let hspacer = NSView(); hspacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, hspacer, close])

        // Setup: the spec, the APK, the goldens.
        func setupRow(_ name: String, _ value: NSTextField, _ choose: Selector, _ tip: String) -> NSStackView {
            let n = label(name)
            n.widthAnchor.constraint(equalToConstant: 58).isActive = true
            value.font = .systemFont(ofSize: 12, weight: .medium)
            value.textColor = Design.ink
            value.lineBreakMode = .byTruncatingMiddle
            value.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let b = GlassButton(symbol: nil, title: "Choose…", label: tip, style: .well, target: self, action: choose)
            return NSStackView(views: [n, value, b])
        }
        let specRow = setupRow("Spec", specLabel, #selector(chooseSpec), "Choose the spec.json that lists the screens")
        let apkRow = setupRow("APK", apkLabel, #selector(chooseAPK), "Choose the APK to test")
        let goldRow = setupRow("Goldens", goldensLabel, #selector(chooseGoldens), "Choose the folder of golden images")
        for r in [specRow, apkRow, goldRow] { r.spacing = 8 }
        let setup = NSStackView(views: [specRow, apkRow, goldRow])
        setup.orientation = .vertical
        setup.alignment = .leading
        setup.spacing = 4
        for r in [specRow, apkRow, goldRow] { r.trailingAnchor.constraint(equalTo: setup.trailingAnchor).isActive = true }

        runButton.target = self; runButton.action = #selector(runPressed)
        recordButton.target = self; recordButton.action = #selector(recordPressed)
        let buttons = NSStackView(views: [runButton, recordButton])
        buttons.orientation = .vertical
        buttons.alignment = .trailing
        buttons.spacing = 6
        let top = NSStackView(views: [setup, buttons])
        top.spacing = 18
        top.alignment = .centerY

        // Progress and filter.
        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.minValue = 0; progress.maxValue = 1
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 200).isActive = true
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = Design.mute
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        filterControl.selectedSegment = 0
        filterControl.target = self; filterControl.action = #selector(filterChanged)
        filterControl.controlSize = .small
        acceptDifferent.target = self; acceptDifferent.action = #selector(acceptAllDifferent)
        acceptNew.target = self; acceptNew.action = #selector(acceptAllNew)
        acceptDifferent.isHidden = true; acceptNew.isHidden = true
        let spacer2 = NSView(); spacer2.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [progress, statusLabel, spacer2, filterControl, acceptNew, acceptDifferent])
        bar.spacing = 10

        // Grid.
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 140, height: 252)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 4, left: 4, bottom: 8, right: 4)
        collection.collectionViewLayout = layout
        collection.register(SnapshotTileItem.self, forItemWithIdentifier: SnapshotTileItem.identifier)
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        emptyNote.font = .systemFont(ofSize: 13)
        emptyNote.textColor = Design.mute
        emptyNote.alignment = .center
        emptyNote.translatesAutoresizingMaskIntoConstraints = false
        let gridBox = NSView()
        for v in [scroll, emptyNote] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; gridBox.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: gridBox.topAnchor), scroll.bottomAnchor.constraint(equalTo: gridBox.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: gridBox.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: gridBox.trailingAnchor),
            emptyNote.centerXAnchor.constraint(equalTo: gridBox.centerXAnchor), emptyNote.centerYAnchor.constraint(equalTo: gridBox.centerYAnchor),
            emptyNote.widthAnchor.constraint(lessThanOrEqualTo: gridBox.widthAnchor, constant: -40),
            gridBox.widthAnchor.constraint(equalToConstant: 470),
        ])

        // Detail.
        detailTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        detailTitle.textColor = Design.ink
        detailTitle.lineBreakMode = .byTruncatingTail
        detailTitle.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        detailStatus.font = .systemFont(ofSize: 12)
        detailStatus.textColor = Design.mute
        detailStatus.maximumNumberOfLines = 2
        modeControl.selectedSegment = 0
        modeControl.target = self; modeControl.action = #selector(modeChanged)
        modeControl.controlSize = .small
        acceptButton.target = self; acceptButton.action = #selector(acceptSelected)
        acceptButton.isHidden = true
        let dspacer = NSView(); dspacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let dhead = NSStackView(views: [detailTitle, dspacer, modeControl, acceptButton])
        dhead.spacing = 10

        func column(_ name: String, _ pane: SnapshotPicture) -> NSStackView {
            let c = NSStackView(views: [label(name, size: 11, weight: .medium), pane])
            c.orientation = .vertical
            c.alignment = .centerX
            c.spacing = 4
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.widthAnchor.constraint(equalTo: c.widthAnchor).isActive = true
            return c
        }
        sideBySide = NSStackView(views: [column("Golden", goldenPane), column("Actual", actualPane), column("Difference", diffPane)])
        sideBySide.distribution = .fillEqually
        sideBySide.spacing = 10
        wipe.onChange = { [weak self] p in self?.wipeSlider.doubleValue = Double(p) }
        wipeSlider.target = self; wipeSlider.action = #selector(wipeSliderMoved)
        let wl = label("Golden", size: 11, weight: .medium), wr = label("Actual", size: 11, weight: .medium)
        let wipeBar = NSStackView(views: [wl, wipeSlider, wr])
        wipeBar.spacing = 8
        wipeBox = NSStackView(views: [wipe, wipeBar])
        wipeBox.orientation = .vertical
        wipeBox.spacing = 8
        wipeBox.isHidden = true
        wipe.translatesAutoresizingMaskIntoConstraints = false
        wipeBar.translatesAutoresizingMaskIntoConstraints = false
        wipeBar.leadingAnchor.constraint(equalTo: wipeBox.leadingAnchor).isActive = true
        wipeBar.trailingAnchor.constraint(equalTo: wipeBox.trailingAnchor).isActive = true
        wipe.widthAnchor.constraint(equalTo: wipeBox.widthAnchor).isActive = true
        detailBody.translatesAutoresizingMaskIntoConstraints = false
        for v in [sideBySide, wipeBox] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detailBody.addSubview(v)
            NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: detailBody.topAnchor), v.bottomAnchor.constraint(equalTo: detailBody.bottomAnchor),
                                         v.leadingAnchor.constraint(equalTo: detailBody.leadingAnchor), v.trailingAnchor.constraint(equalTo: detailBody.trailingAnchor)])
        }
        let detail = NSStackView(views: [dhead, detailStatus, detailBody])
        detail.orientation = .vertical
        detail.spacing = 6
        detail.alignment = .leading
        for v in [dhead, detailStatus, detailBody] as [NSView] { v.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
        let detailWell = NSView()
        detailWell.wantsLayer = true
        detailWell.layer?.backgroundColor = Design.well.cgColor
        detailWell.layer?.cornerRadius = 12
        detailWell.layer?.cornerCurve = .continuous
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailWell.addSubview(detail)
        NSLayoutConstraint.activate([detail.topAnchor.constraint(equalTo: detailWell.topAnchor, constant: 12), detail.bottomAnchor.constraint(equalTo: detailWell.bottomAnchor, constant: -12),
                                     detail.leadingAnchor.constraint(equalTo: detailWell.leadingAnchor, constant: 12), detail.trailingAnchor.constraint(equalTo: detailWell.trailingAnchor, constant: -12)])

        let body = NSStackView(views: [gridBox, detailWell])
        body.spacing = 14
        body.distribution = .fill

        let rule = NSView(); rule.wantsLayer = true; rule.layer?.backgroundColor = Design.stroke.cgColor
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let column = NSStackView(views: [header, top, rule, bar, body])
        column.orientation = .vertical
        column.spacing = 10
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)
        for v in [header, top, rule, bar, body] as [NSView] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([column.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14), column.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
                                     column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18), column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18)])
    }

    // MARK: Opening and closing

    func open(loadLast: Bool = true) {
        guard !isOpen else { return }
        isOpen = true
        if pythonURL == nil { pythonURL = SnapshotRun.python() }
        if loadLast, results.isEmpty, let folder = runFolder, let last = SnapshotRun.read(folder) { results = last; applyFilter() }
        refreshSetup()
        isHidden = false
        alphaValue = 0
        panel.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: 8))
        window?.makeFirstResponder(self)
        Design.animate(Design.arrive, {
            self.animator().alphaValue = 1
            self.panel.layer?.setAffineTransform(.identity)
        })
        onToggle?()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        if let run, run.isRunning {
            run.cancel()
            onSay?("Screenshot test run stopped", false)
        }
        Design.animate(Design.snap, { self.animator().alphaValue = 0 }, done: { if !self.isOpen { self.isHidden = true } })
        onToggle?()
    }

    @objc private func closePressed() { close() }
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { close() } else { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) { if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { close() } }

    // MARK: Setup

    /// The APK a run uses: the one chosen here, else the selected simulator's, else the spec's own.
    var effectiveAPK: URL? { apkURL ?? defaultAPK() }

    private func specJSON() -> [String: Any]? {
        guard let specURL, let data = try? Data(contentsOf: specURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Where goldens are kept: the chosen folder, else the spec's `goldens` beside it.
    var goldensDir: URL? {
        if let goldensOverride { return goldensOverride }
        guard let specURL, let g = specJSON()?["goldens"] as? String else { return nil }
        return URL(fileURLWithPath: g, relativeTo: specURL.deletingLastPathComponent()).standardizedFileURL
    }

    private var goldensExist: Bool {
        guard let dir = goldensDir, let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
        return e.contains { ($0 as? URL)?.pathExtension == "png" }
    }

    func setSpec(_ url: URL?) {
        specURL = url
        goldensOverride = nil
        refreshSetup()
    }
    func setAPK(_ url: URL?) { apkURL = url; refreshSetup() }

    private func tilde(_ p: String) -> String { p.hasPrefix(NSHomeDirectory()) ? "~" + p.dropFirst(NSHomeDirectory().count) : p }

    private func refreshSetup() {
        if let specURL {
            let screens = (specJSON()?["screens"] as? [Any])?.count
            specLabel.stringValue = specURL.lastPathComponent + (screens.map { "  ·  \($0) screens" } ?? "  ·  cannot read this file") + "  ·  " + tilde(specURL.deletingLastPathComponent().path)
        } else { specLabel.stringValue = "None: pick the spec.json that lists the screens" }
        if let apk = effectiveAPK { apkLabel.stringValue = apk.lastPathComponent + (apkURL == nil ? "  ·  the selected simulator's" : "") }
        else { apkLabel.stringValue = specURL == nil ? "The selected simulator's, or choose one" : "The spec's own, or choose one" }
        goldensLabel.stringValue = goldensDir.map { tilde($0.path) + (goldensExist ? "" : "  ·  no goldens yet") } ?? "Beside the spec"
        let running = run?.isRunning == true
        let ready = specURL != nil && pythonURL != nil
        runButton.isEnabled = running || (ready && goldensExist)
        recordButton.isEnabled = ready && !running
        runButton.title = running ? "Stop" : "Run"
        runButton.style = running ? .record : .accent
        if pythonURL == nil, !running {
            setStatus("Screenshot tests need Python 3, and this Mac has none. Install the command line tools (xcode-select --install in Terminal) or Python from python.org, then reopen this.", problem: true)
        } else if !running, results.isEmpty {
            setStatus(specURL == nil ? "Choose a spec to begin." : (goldensExist ? "Ready. Run compares every screen with its golden." : "No goldens yet: Record goldens captures every screen and keeps it as the reference."), problem: false)
        }
        refreshBulk()
        updateEmpty()
    }

    private func setStatus(_ text: String, problem: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = problem ? Design.warning : Design.mute
    }

    private func panelOpen(_ title: String, directory: Bool, types: [UTType] = [], pick: @escaping (URL) -> Void) {
        let p = NSOpenPanel()
        p.message = title
        p.canChooseDirectories = directory
        p.canChooseFiles = !directory
        p.allowedContentTypes = types
        p.allowsMultipleSelection = false
        guard let w = window else { return }
        p.beginSheetModal(for: w) { r in if r == .OK, let u = p.url { pick(u) } }
    }

    @objc private func chooseSpec() { panelOpen("Choose the spec.json that lists the screens", directory: false, types: [.json]) { [weak self] in self?.setSpec($0); self?.results = []; self?.applyFilter() } }
    @objc private func chooseAPK() { panelOpen("Choose the APK to test", directory: false, types: [UTType(filenameExtension: "apk") ?? .data]) { [weak self] in self?.setAPK($0) } }
    @objc private func chooseGoldens() { panelOpen("Choose the folder of golden images", directory: true) { [weak self] in self?.goldensOverride = $0; self?.refreshSetup() } }

    // MARK: Running

    @objc private func runPressed() {
        if let run, run.isRunning { run.cancel(); return }
        start(.compare)
    }

    @objc private func recordPressed() {
        guard goldensExist, let w = window else { start(.record); return }
        let alert = NSAlert()
        alert.messageText = "Record goldens again?"
        alert.informativeText = "Every screen is captured and written over its golden in \(goldensDir?.lastPathComponent ?? "the golden folder"). Goldens that differ now will be replaced."
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: w) { [weak self] r in if r == .alertFirstButtonReturn { self?.start(.record) } }
    }

    /// Starts a run. `completion` hears the outcome on the main thread (scripted checks).
    func start(_ mode: SnapshotRun.Mode, completion: ((SnapshotRun.Outcome) -> Void)? = nil) {
        guard run?.isRunning != true, let spec = specURL, let python = pythonURL else { return }
        let base = Engine.shared.state.appendingPathComponent("snapshots", isDirectory: true)
        SnapshotRun.prune(base)
        let out = base.appendingPathComponent("run-\(Int(Date().timeIntervalSince1970 * 1000))", isDirectory: true)
        let r = SnapshotRun(python: python, spec: spec, apk: effectiveAPK, goldens: goldensOverride, out: out, mode: mode)
        run = r
        generation += 1
        let gen = generation
        progress.isHidden = false
        progress.doubleValue = 0
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        setStatus(mode == .record ? "Starting the simulators to record goldens…" : "Starting the simulators…", problem: false)
        r.onProgress = { [weak self] done, total, _ in
            guard let self, self.generation == gen else { return }
            if total > 0 {
                self.progress.isIndeterminate = false
                self.progress.doubleValue = Double(done) / Double(total)
                self.setStatus("\(done) of \(total) captures" + (mode == .record ? " recorded" : ""), problem: false)
            }
        }
        r.onFinish = { [weak self] outcome in
            guard let self, self.generation == gen else { return }
            self.progress.stopAnimation(nil)
            self.progress.isHidden = true
            switch outcome {
            case .finished(_, let list):
                self.results = list
                self.runFolder = out
                self.differences = [:]
                self.selectedID = nil
                self.applyFilter()
                self.setStatus(Self.summary(list), problem: list.contains { $0.kind == .error })
            case .failed(let why):
                self.setStatus("The run failed: " + why, problem: true)
                self.onSay?("Screenshot tests failed: " + why, true)
            case .cancelled:
                self.setStatus("Stopped.", problem: false)
            }
            self.refreshSetup()
            completion?(outcome)
        }
        refreshSetup()
        r.start()
    }

    static func counts(_ list: [SnapshotResult]) -> [SnapshotResult.Kind: Int] {
        Dictionary(list.map { ($0.kind, 1) }, uniquingKeysWith: +)
    }

    static func summary(_ list: [SnapshotResult]) -> String {
        let c = counts(list)
        var parts: [String] = []
        for (kind, name) in [(SnapshotResult.Kind.same, "same"), (.different, "different"), (.new, "new"), (.error, "errors"), (.recorded, "recorded"), (.updated, "rewritten")] {
            if let n = c[kind], n > 0 { parts.append("\(n) \(name)") }
        }
        return "\(list.count) captures: " + parts.joined(separator: ", ")
    }

    // MARK: Grid

    @objc private func filterChanged() { filter = filterControl.selectedSegment; applyFilter() }

    private func applyFilter() {
        switch filter {
        case 1: shown = results.filter { $0.kind == .different }
        case 2: shown = results.filter { $0.kind == .new || $0.kind == .recorded }
        case 3: shown = results.filter { $0.kind == .error }
        default: shown = results
        }
        // Different and wrong first when showing everything, as the script's report does.
        if filter == 0 {
            let rank: [SnapshotResult.Kind: Int] = [.error: 0, .different: 1, .new: 2, .updated: 3, .recorded: 4, .same: 5]
            shown = shown.enumerated().sorted { (rank[$0.element.kind] ?? 9, $0.offset) < (rank[$1.element.kind] ?? 9, $1.offset) }.map(\.element)
        }
        collection.reloadData()
        if let id = selectedID, let i = shown.firstIndex(where: { $0.id == id }) {
            collection.selectItems(at: [IndexPath(item: i, section: 0)], scrollPosition: [])
            showDetail(shown[i])
        } else if let first = shown.first {
            select(first.id, in: 0)
        } else {
            selectedID = nil
            showDetail(nil)
        }
        refreshBulk()
        updateEmpty()
        let c = Self.counts(results)
        filterControl.setLabel("All \(results.count)", forSegment: 0)
        filterControl.setLabel("Different \(c[.different] ?? 0)", forSegment: 1)
        filterControl.setLabel("New \((c[.new] ?? 0) + (c[.recorded] ?? 0))", forSegment: 2)
        filterControl.setLabel("Errors \(c[.error] ?? 0)", forSegment: 3)
    }

    private func updateEmpty() {
        if results.isEmpty { emptyNote.stringValue = "No results yet.\nRun the tests, or record goldens the first time."; emptyNote.isHidden = false }
        else if shown.isEmpty { emptyNote.stringValue = "Nothing in this filter."; emptyNote.isHidden = false }
        else { emptyNote.isHidden = true }
    }

    private func refreshBulk() {
        let d = results.filter { $0.kind == .different }.count, n = results.filter { $0.kind == .new }.count
        acceptDifferent.isHidden = d == 0
        acceptNew.isHidden = n == 0
        acceptDifferent.title = "Accept all different (\(d))"
        acceptNew.title = "Accept all new (\(n))"
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { shown.count }
    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: SnapshotTileItem.identifier, for: indexPath) as! SnapshotTileItem
        item.configure(shown[indexPath.item])
        return item
    }
    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let i = indexPaths.first?.item, shown.indices.contains(i) else { return }
        selectedID = shown[i].id
        showDetail(shown[i])
    }

    /// Selects a tile by id (scripted checks, and after a run).
    func select(_ id: String, in index: Int? = nil) {
        guard let i = index ?? shown.firstIndex(where: { $0.id == id }), shown.indices.contains(i) else { return }
        collection.selectItems(at: [IndexPath(item: i, section: 0)], scrollPosition: .centeredVertically)
        selectedID = id
        showDetail(shown[i])
    }

    // MARK: Detail

    private var selected: SnapshotResult? { results.first { $0.id == selectedID } }

    private func showDetail(_ r: SnapshotResult?) {
        guard let r else {
            detailTitle.stringValue = results.isEmpty ? "" : "Pick a tile"
            detailStatus.stringValue = ""
            acceptButton.isHidden = true
            for p in [goldenPane, actualPane, diffPane] { p.show(nil, empty: "") }
            wipe.show(golden: nil, actual: nil)
            return
        }
        detailTitle.stringValue = r.screen + "  ·  " + r.combo
        detailStatus.stringValue = r.statusText + (r.detail.isEmpty || r.kind == .same ? "" : "  ·  " + r.detail)
        detailStatus.textColor = SnapshotTileItem.color(r.kind)
        acceptButton.isHidden = !(r.kind == .different || r.kind == .new)
        acceptButton.title = r.kind == .new ? "Keep as golden" : "Accept as golden"
        let id = r.id
        let noGolden = r.kind == .new || r.kind == .recorded
        goldenPane.show(nil, empty: noGolden ? "No golden yet" : "")
        actualPane.show(nil, empty: "")
        diffPane.show(nil, empty: "")
        wipe.show(golden: nil, actual: nil)
        var golden: CGImage?, actual: CGImage?
        func refreshWipe() { if selectedID == id { wipe.show(golden: golden, actual: actual) } }
        if let u = r.golden {
            SnapshotImages.load(u, maxPixel: 1700) { [weak self] img in
                guard self?.selectedID == id else { return }
                golden = img; self?.goldenPane.show(img, empty: "No golden yet"); refreshWipe()
            }
        }
        if let u = r.actual {
            SnapshotImages.load(u, maxPixel: 1700) { [weak self] img in
                guard self?.selectedID == id else { return }
                actual = img; self?.actualPane.show(img, empty: ""); refreshWipe()
            }
        } else { actualPane.show(nil, empty: "No capture") }
        switch r.kind {
        case .different:
            if let img = differences[id] { diffPane.show(img, empty: "") }
            else if let u = r.diff {
                SnapshotImages.load(u, maxPixel: 1700) { [weak self] img in if self?.selectedID == id { self?.diffPane.show(img, empty: "") } }
            } else if let g = r.golden, let a = r.actual {
                diffPane.show(nil, empty: "Working out the difference…")
                SnapshotImages.difference(golden: g, actual: a) { [weak self] img in
                    guard let self else { return }
                    if let img { self.differences[id] = img }
                    if self.selectedID == id { self.diffPane.show(img, empty: "Sizes differ: no map") }
                }
            } else { diffPane.show(nil, empty: "No difference map") }
        case .same, .recorded: diffPane.show(nil, empty: "No difference")
        default: diffPane.show(nil, empty: "Nothing to compare")
        }
    }

    @objc private func modeChanged() { setMode(wipe: modeControl.selectedSegment == 1) }

    func setMode(wipe on: Bool) {
        modeControl.selectedSegment = on ? 1 : 0
        sideBySide.isHidden = on
        wipeBox.isHidden = !on
    }

    @objc private func wipeSliderMoved() { wipe.position = CGFloat(wipeSlider.doubleValue) }
    func setWipe(_ p: CGFloat) { wipe.position = p }

    // MARK: Accepting

    @objc private func acceptSelected() { if let s = selected { accept([s.id]) } }
    @objc private func acceptAllDifferent() { confirmAccept(.different) }
    @objc private func acceptAllNew() { confirmAccept(.new) }

    private func confirmAccept(_ kind: SnapshotResult.Kind) {
        let ids = results.filter { $0.kind == kind }.map(\.id)
        guard !ids.isEmpty, let w = window else { return }
        let alert = NSAlert()
        alert.messageText = kind == .new ? "Keep \(ids.count) new capture\(ids.count == 1 ? "" : "s") as goldens?" : "Accept \(ids.count) different capture\(ids.count == 1 ? "" : "s") as goldens?"
        alert.informativeText = "Each capture is copied over its golden in \(goldensDir.map { tilde($0.path) } ?? "the golden folder"). The old golden images are replaced and cannot be restored from here."
        alert.addButton(withTitle: kind == .new ? "Keep all" : "Accept all")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: w) { [weak self] r in if r == .alertFirstButtonReturn { self?.accept(ids) } }
    }

    /// Copies each capture over its golden. Returns how many were written.
    @discardableResult
    func accept(_ ids: [String]) -> Int {
        guard let dir = goldensDir else { return 0 }
        let fm = FileManager.default
        var done = Set<String>()
        for id in ids {
            guard let i = results.firstIndex(where: { $0.id == id }), let actual = results[i].actual else { continue }
            let target = dir.appendingPathComponent(results[i].rel)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")
                try? fm.removeItem(at: tmp)
                try fm.copyItem(at: actual, to: tmp)
                if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: target) }
            } catch {
                onSay?("Could not write \(target.lastPathComponent): \(error.localizedDescription)", true)
                continue
            }
            results[i].kind = .same
            results[i].accepted = true
            results[i].pixels = 0
            results[i].golden = actual
            results[i].diff = nil
            differences[id] = nil
            done.insert(id)
        }
        if let runFolder, !done.isEmpty { SnapshotRun.markAccepted(done, in: runFolder) }
        if !done.isEmpty {
            onSay?(done.count == 1 ? "Golden updated" : "\(done.count) goldens updated", false)
            setStatus(Self.summary(results), problem: false)
            applyFilter()
            refreshSetup()
        }
        return done.count
    }

    /// "Run screenshot tests…": a run at once when there is a spec with goldens, else the file panel for the spec.
    func runIfReady() {
        guard run?.isRunning != true else { return }
        if specURL == nil { DispatchQueue.main.async { self.chooseSpec() } }
        else if goldensExist, pythonURL != nil { start(.compare) }
    }

    // MARK: Scripted checks

    /// Selects the first tile of this kind. False when there is none.
    func selectFirst(_ kind: SnapshotResult.Kind) -> Bool {
        guard let r = results.first(where: { $0.kind == kind }) else { return false }
        if !shown.contains(where: { $0.id == r.id }) { filterControl.selectedSegment = 0; filter = 0; applyFilter() }
        select(r.id)
        return true
    }

    func acceptSelectedForCheck() -> Int { selected.map { accept([$0.id]) } ?? 0 }
}
