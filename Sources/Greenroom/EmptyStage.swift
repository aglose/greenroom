import AppKit

/// What the stage shows with nothing running: where to drop an APK, the promise that it stays on this Mac, a way in
/// for someone with source and no APK (a project folder, or a GitHub repository cloned here), and the apps opened lately.
final class EmptyStage: NSView {
    var onChoose: (() -> Void)?
    var onOpen: ((URL) -> Void)?
    /// "Open a project folder…": build an Android project on this Mac and run it.
    var onFolder: (() -> Void)?
    /// "Clone from GitHub…": clone a repository, then build and run it.
    var onClone: (() -> Void)?
    private let recents = NSStackView()
    private let card = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        card.wantsLayer = true
        card.layer?.cornerRadius = 22
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor(white: 1, alpha: 0.03).cgColor
        let dash = CAShapeLayer()
        dash.strokeColor = NSColor(white: 1, alpha: 0.22).cgColor
        dash.fillColor = nil
        dash.lineWidth = 2
        dash.lineDashPattern = [8, 6]
        card.layer?.addSublayer(dash)
        cardDash = dash

        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.down.app", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 44, weight: .light)) ?? NSImage())
        icon.contentTintColor = Design.accent
        let title = NSTextField(labelWithString: "Drop an APK to run it")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = Design.ink
        let promise = NSTextField(wrappingLabelWithString: "It opens in under a second and stays on this Mac.\nNothing about your app is sent anywhere.")
        promise.font = .systemFont(ofSize: 14)
        promise.textColor = Design.mute
        promise.alignment = .center
        let choose = GlassButton(symbol: nil, title: "Choose an APK…", label: "Choose an APK to run", style: .accent, target: nil, action: nil)
        choose.onPress = { [weak self] in self?.onChoose?() }
        let sample = GlassButton(symbol: nil, title: "Open the sample app", label: "Run the sample app that comes with Greenroom", style: .well, target: nil, action: nil)
        sample.onPress = { [weak self] in
            let apk = Engine.shared.root.deletingLastPathComponent().appendingPathComponent("engine-testapp.apk")
            if FileManager.default.fileExists(atPath: apk.path) { self?.onOpen?(apk) }
        }
        for b in [choose, sample] { b.heightAnchor.constraint(equalToConstant: 34).isActive = true }
        let buttons = NSStackView(views: [choose, sample])
        buttons.spacing = 10

        // No APK: build one from source.
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        let noAPK = NSTextField(labelWithString: "No APK? Build one from source")
        noAPK.font = .systemFont(ofSize: 12, weight: .medium)
        noAPK.textColor = Design.mute
        let folder = GlassButton(symbol: "folder", title: "Open a project folder…", label: "Build and run an Android project folder on this Mac", style: .well, target: nil, action: nil)
        folder.onPress = { [weak self] in self?.onFolder?() }
        let clone = GlassButton(symbol: "arrow.down.circle", title: "Clone from GitHub…", label: "Clone a GitHub repository, then build and run it", style: .well, target: nil, action: nil)
        clone.onPress = { [weak self] in self?.onClone?() }
        for b in [folder, clone] { b.heightAnchor.constraint(equalToConstant: 30).isActive = true }
        let sources = NSStackView(views: [folder, clone])
        sources.spacing = 10

        let column = NSStackView(views: [icon, title, promise, buttons, rule, noAPK, sources])
        column.orientation = .vertical
        column.spacing = 12
        column.setCustomSpacing(18, after: promise)
        column.setCustomSpacing(26, after: buttons)
        column.setCustomSpacing(22, after: rule)
        column.setCustomSpacing(10, after: noAPK)
        rule.widthAnchor.constraint(equalToConstant: 360).isActive = true
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        let recentTitle = NSTextField(labelWithString: "Recent")
        recentTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        recentTitle.textColor = Design.mute
        recents.spacing = 10
        let lower = NSStackView(views: [recentTitle, recents])
        lower.orientation = .vertical
        lower.alignment = .leading
        lower.spacing = 8
        recentsBlock = lower

        let all = NSStackView(views: [card, lower])
        all.orientation = .vertical
        all.spacing = 28
        all.alignment = .leading
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.centerXAnchor.constraint(equalTo: centerXAnchor),
            all.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            card.widthAnchor.constraint(equalToConstant: 560),
            lower.widthAnchor.constraint(equalTo: card.widthAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 40),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -40),
            column.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -48),
        ])
        reload()
    }

    private var cardDash: CAShapeLayer?
    private var recentsBlock: NSView?

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        cardDash?.frame = card.bounds
        cardDash?.path = CGPath.rounded(card.bounds.insetBy(dx: 1, dy: 1), radius: 21)
    }

    /// The last three APKs opened, as buttons.
    func reload() {
        recents.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // One card per app name: copies of one build opened from different folders are one app here (newest first).
        var seen = Set<String>()
        let list = Array(Recents.all.filter { seen.insert($0.lastPathComponent).inserted }.prefix(3))
        recentsBlock?.isHidden = list.isEmpty
        for url in list {
            let b = GlassButton(symbol: "shippingbox", title: url.deletingPathExtension().lastPathComponent, label: url.path, style: .well, target: nil, action: nil)
            b.heightAnchor.constraint(equalToConstant: 38).isActive = true
            b.onPress = { [weak self] in self?.onOpen?(url) }
            recents.addArrangedSubview(b)
        }
    }
}

/// A short message floating at the foot of the stage: a screenshot saved, a recording that could not be.
final class Toast: NSView {
    private let glass = GlassView(radius: 14)
    private let label = NSTextField(labelWithString: "")
    private var hide: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        for v in [glass, label] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36),
            widthAnchor.constraint(lessThanOrEqualToConstant: 640),
        ])
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var action: (() -> Void)?

    /// A message with something to click: "Show in Finder".
    func show(_ text: String, action title: String, _ run: @escaping () -> Void) {
        show(text + "  ·  " + title)
        action = run
        hide?.invalidate()
        hide = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.action = nil
            Design.animate(Design.arrive, { self.animator().alphaValue = 0 })
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let run = action, alphaValue > 0.5 { action = nil; run() } else { super.mouseDown(with: event) }
    }

    func show(_ text: String, problem: Bool = false) {
        action = nil
        label.stringValue = text
        label.textColor = problem ? Design.warning : Design.ink
        hide?.invalidate()
        Design.animate(Design.arrive, { self.animator().alphaValue = 1 })
        hide = Timer.scheduledTimer(withTimeInterval: problem ? 6 : 3, repeats: false) { [weak self] _ in
            guard let self else { return }
            Design.animate(Design.arrive, { self.animator().alphaValue = 0 })
        }
    }

    var text: String { label.stringValue }
}
