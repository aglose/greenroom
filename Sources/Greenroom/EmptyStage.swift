import AppKit

/// The APK screen (File > Run an APK…, docs/AGENT-FIRST-SPEC.md): running an APK by hand. Where to drop one, the
/// promise that it stays on this Mac, a file picker, the apps opened lately and the sample app. It takes the stage
/// when asked for, over running devices too, and gives it back (Back, Escape, or an app opening). With nothing
/// running the stage is WaitingStage: this is the only screen that offers a drop target.
final class EmptyStage: NSView {
    var onChoose: (() -> Void)?
    var onOpen: ((URL) -> Void)?
    /// Back, or Escape: give the stage back.
    var onBack: (() -> Void)?
    private let recents = NSStackView()
    private let card = NSView()
    private let recentTitle = NSTextField(labelWithString: "RECENT APPS")
    private let sampleButton = GlassButton(symbol: nil, title: "Try Sample App →", label: "Run the sample app that comes with Greenroom", style: .plain, target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        // Its own stage, so running devices do not show through when it is opened over them.
        let floor = StageBackground()
        floor.translatesAutoresizingMaskIntoConstraints = false
        addSubview(floor)
        NSLayoutConstraint.activate([
            floor.topAnchor.constraint(equalTo: topAnchor), floor.bottomAnchor.constraint(equalTo: bottomAnchor),
            floor.leadingAnchor.constraint(equalTo: leadingAnchor), floor.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        card.wantsLayer = true
        card.layer?.cornerRadius = 22
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor(white: 1, alpha: 0.03).cgColor
        let dash = CAShapeLayer()
        dash.strokeColor = Design.accent.withAlphaComponent(0.35).cgColor
        dash.fillColor = nil
        dash.lineWidth = 2
        dash.lineDashPattern = [8, 6]
        card.layer?.addSublayer(dash)
        cardDash = dash

        let iconWell = NSView()
        iconWell.wantsLayer = true
        iconWell.layer?.cornerRadius = 12
        iconWell.layer?.cornerCurve = .continuous
        iconWell.layer?.backgroundColor = Design.accent.withAlphaComponent(0.14).cgColor
        iconWell.layer?.borderWidth = 1
        iconWell.layer?.borderColor = Design.accent.withAlphaComponent(0.28).cgColor
        iconWell.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.down.app", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .medium)) ?? NSImage())
        icon.contentTintColor = Design.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconWell.addSubview(icon)
        NSLayoutConstraint.activate([
            iconWell.widthAnchor.constraint(equalToConstant: 44),
            iconWell.heightAnchor.constraint(equalToConstant: 44),
            icon.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
        ])

        let title = NSTextField(labelWithString: "Run an APK")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = Design.ink
        let promise = NSTextField(wrappingLabelWithString: "Drop an APK here, or choose one. It runs natively in under a second\nand stays private on this Mac.")
        promise.font = .systemFont(ofSize: 13.5)
        promise.textColor = Design.mute
        promise.alignment = .center
        let choose = GlassButton(symbol: nil, title: "Choose an APK…", label: "Choose an APK to run", style: .accent, target: nil, action: nil)
        choose.onPress = { [weak self] in self?.onChoose?() }
        choose.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let column = NSStackView(views: [iconWell, title, promise, choose])
        column.orientation = .vertical
        column.spacing = 12
        column.setCustomSpacing(14, after: iconWell)
        column.setCustomSpacing(18, after: promise)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        recentTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        recentTitle.textColor = Design.mute
        sampleButton.font = .systemFont(ofSize: 12, weight: .medium)
        sampleButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        sampleButton.onPress = { [weak self] in
            let apk = Self.sampleAPK
            if FileManager.default.fileExists(atPath: apk.path) { self?.onOpen?(apk) }
        }
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let recentHeader = NSStackView(views: [recentTitle, headerSpacer, sampleButton])
        recentHeader.orientation = .horizontal
        recentHeader.alignment = .centerY

        recents.orientation = .vertical
        recents.alignment = .leading
        recents.spacing = 10
        let lower = NSStackView(views: [recentHeader, recents])
        lower.orientation = .vertical
        lower.alignment = .leading
        lower.spacing = 10
        recentsBlock = lower

        let back = GlassButton(symbol: "chevron.left", title: "Back", label: "Leave the APK screen", style: .plain, target: nil, action: nil)
        back.onPress = { [weak self] in self?.onBack?() }
        back.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let all = NSStackView(views: [back, card, lower])
        all.orientation = .vertical
        all.spacing = 24
        all.setCustomSpacing(10, after: back)
        all.alignment = .leading
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.centerXAnchor.constraint(equalTo: centerXAnchor),
            all.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            card.widthAnchor.constraint(equalToConstant: 560),
            lower.widthAnchor.constraint(equalTo: card.widthAnchor),
            recentHeader.widthAnchor.constraint(equalTo: lower.widthAnchor),
            recents.widthAnchor.constraint(equalTo: lower.widthAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 36),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -36),
            column.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -48),
        ])
        reload()
    }

    private static var sampleAPK: URL {
        Engine.shared.root.deletingLastPathComponent().appendingPathComponent("engine-testapp.apk")
    }

    private var cardDash: CAShapeLayer?
    private var recentsBlock: NSView?

    required init?(coder: NSCoder) { fatalError("not used") }

    // Escape gives the stage back, and clicks on the screen never reach a device under it.
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onBack?() }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func layout() {
        super.layout()
        cardDash?.frame = card.bounds
        cardDash?.path = CGPath.rounded(card.bounds.insetBy(dx: 1, dy: 1), radius: 21)
    }

    /// Up to four recent APKs opened, as rich cards in a 2x2 grid.
    func reload() {
        recents.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // One card per app name: copies of one build opened from different folders are one app here (newest first).
        var seen = Set<String>()
        let list = Array(Recents.all.filter { seen.insert($0.lastPathComponent).inserted }.prefix(4))
        let hasSample = FileManager.default.fileExists(atPath: Self.sampleAPK.path)
        sampleButton.isHidden = !hasSample
        recentTitle.isHidden = list.isEmpty
        recents.isHidden = list.isEmpty
        recentsBlock?.isHidden = list.isEmpty && !hasSample

        var i = 0
        while i < list.count {
            let left = RecentAppCard(url: list[i]) { [weak self] url in self?.onOpen?(url) }
            let right: NSView = (i + 1 < list.count)
                ? RecentAppCard(url: list[i + 1]) { [weak self] url in self?.onOpen?(url) }
                : NSView()
            let row = NSStackView(views: [left, right])
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            recents.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recents.widthAnchor).isActive = true
            i += 2
        }
    }
}

/// Clickable recent-app card with a deterministic monogram badge, app name, parent folder, and modified date.
private final class RecentAppCard: NSView {
    private let url: URL
    private let onOpen: (URL) -> Void
    private var hovering = false { didSet { refresh() } }
    private var pressed = false { didSet { refresh() } }

    private static let palette: [(NSColor, NSColor)] = [
        (NSColor(srgbRed: 0.16, green: 0.68, blue: 0.46, alpha: 1), NSColor(srgbRed: 0.10, green: 0.44, blue: 0.34, alpha: 1)),
        (NSColor(srgbRed: 0.25, green: 0.48, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.16, green: 0.31, blue: 0.62, alpha: 1)),
        (NSColor(srgbRed: 0.56, green: 0.36, blue: 0.82, alpha: 1), NSColor(srgbRed: 0.37, green: 0.22, blue: 0.58, alpha: 1)),
        (NSColor(srgbRed: 0.82, green: 0.46, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.58, green: 0.28, blue: 0.14, alpha: 1)),
        (NSColor(srgbRed: 0.20, green: 0.62, blue: 0.68, alpha: 1), NSColor(srgbRed: 0.12, green: 0.40, blue: 0.46, alpha: 1)),
        (NSColor(srgbRed: 0.78, green: 0.32, blue: 0.52, alpha: 1), NSColor(srgbRed: 0.52, green: 0.18, blue: 0.34, alpha: 1)),
    ]

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    init(url: URL, onOpen: @escaping (URL) -> Void) {
        self.url = url
        self.onOpen = onOpen
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Design.well.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Design.stroke.cgColor
        toolTip = url.path

        let appName = url.deletingPathExtension().lastPathComponent
        let badge = Self.makeMonogram(for: appName)

        let title = NSTextField(labelWithString: appName)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Design.ink
        title.lineBreakMode = .byTruncatingTail

        let parentName = url.deletingLastPathComponent().lastPathComponent
        var subParts: [String] = []
        if !parentName.isEmpty { subParts.append(parentName) }
        if let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) {
            subParts.append(Self.dateFormatter.localizedString(for: mod, relativeTo: Date()))
        }
        let subtitle = NSTextField(labelWithString: subParts.joined(separator: " · "))
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = Design.mute
        subtitle.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [title, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [badge, textStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 54),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func makeMonogram(for name: String) -> NSView {
        let letters = initials(for: name)
        let hash = name.unicodeScalars.reduce(5381) { (($0 << 5) &+ $0) &+ Int($1.value) }
        let pair = palette[abs(hash) % palette.count]

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.cornerCurve = .continuous
        box.layer?.masksToBounds = true
        box.translatesAutoresizingMaskIntoConstraints = false

        let grad = CAGradientLayer()
        grad.colors = [pair.0.cgColor, pair.1.cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0)
        grad.endPoint = CGPoint(x: 1, y: 1)
        grad.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        box.layer?.addSublayer(grad)

        let label = NSTextField(labelWithString: letters)
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 32),
            box.heightAnchor.constraint(equalToConstant: 32),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    private static func initials(for name: String) -> String {
        let parts = name.split { !$0.isLetter && !$0.isNumber }.filter { !$0.isEmpty }
        if parts.count >= 2, let a = parts[0].first, let b = parts[1].first {
            return String([a, b]).uppercased()
        }
        let cleaned = name.filter { $0.isLetter || $0.isNumber }
        return String(cleaned.prefix(2)).uppercased().isEmpty ? "AP" : String(cleaned.prefix(2)).uppercased()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        let pt = convert(event.locationInWindow, from: nil)
        if wasPressed, bounds.contains(pt) { onOpen(url) }
    }

    private func refresh() {
        let fill: NSColor = pressed ? (Design.wellOn.blended(withFraction: 0.25, of: .black) ?? Design.wellOn) : (hovering ? Design.wellOn : Design.well)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Design.snap)
        layer?.backgroundColor = fill.cgColor
        CATransaction.commit()
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
