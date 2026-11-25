import AppKit
import AVKit
import UniformTypeIdentifiers

// The Changes sheet (docs/SESSIONS-PLAN.md, "4. Changes"): a full-stage sheet like Screenshot Tests and the Screen Map.
// A session's build against a base: what is new, changed and gone, as numbers, as pictures, on the map, as a recorded
// tour of both builds, and live. The model is Changes.swift.

/// One tile of the Screens tab: a screen that differs, its picture and what changed.
final class ChangeTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("change-tile")
    private let picture = SnapshotPicture()
    private let nameLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let dot = NSView()
    private(set) var screenID = ""

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
        status.font = .systemFont(ofSize: 11, weight: .medium)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        for l in [nameLabel, status] { l.lineBreakMode = .byTruncatingTail }
        for s in [picture, nameLabel, status, dot] as [NSView] { s.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(s) }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: v.topAnchor, constant: 6), picture.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            picture.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6), picture.heightAnchor.constraint(equalToConstant: 168),
            nameLabel.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 6), nameLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), dot.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            status.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3), status.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            status.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
        ])
        view = v
    }

    func configure(_ c: ChangeScreen) {
        screenID = c.id
        nameLabel.stringValue = c.title
        status.stringValue = c.status.word + ": " + c.detail
        status.textColor = c.status.color
        dot.layer?.backgroundColor = c.status.color.cgColor
        picture.show(nil, empty: "")
        if let url = c.status == .gone ? c.base : c.head {
            let id = c.id
            SnapshotImages.load(url, maxPixel: 420) { [weak self] image in if self?.screenID == id { self?.picture.show(image, empty: "") } }
        } else { picture.show(nil, empty: "No capture") }
        refreshSelection()
    }

    override var isSelected: Bool { didSet { refreshSelection() } }
    private func refreshSelection() {
        view.layer?.borderColor = (isSelected ? Design.accent : NSColor.clear).cgColor
        view.layer?.backgroundColor = (isSelected ? Design.wellOn : Design.well).cgColor
    }
}

/// The heading of a group of tiles on the Screens tab: "Added · 2".
final class ChangeGroupHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("change-group")
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Design.mute
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        for v in [dot, label] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), dot.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6), label.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ status: ChangeStatus, count: Int) {
        label.stringValue = ChangesSheet.groupWord(status).uppercased() + "  \u{00B7}  \(count)"
        dot.layer?.backgroundColor = status.color.cgColor
    }
}

private final class ChangesFlipped: NSView { override var isFlipped: Bool { true } }

final class ChangesSheet: NSView, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    enum Tab: Int, CaseIterable { case summary, screens, map, video, live
        var title: String { ["Summary", "Screens", "Map", "Video", "Live"][rawValue] }
    }

    // MARK: Wiring

    var onSay: ((String, Bool) -> Void)?
    var onToggle: (() -> Void)?
    /// Opens a screen of the head on the session's live simulator (Workbench.goThere).
    var onGo: ((MapScreen, ScreenMapData) -> Void)?
    /// Opens both builds side by side with mirrored input (Workbench.compare(with:)).
    var onLive: ((Session, Build) -> Void)?
    weak var controller: SessionsController?
    /// Tours of a comparison are recorded by themselves once it ends (a check turns this off to run its own).
    var tourAutomatically = true

    private(set) var isOpen = false
    private(set) var session: Session?
    private(set) var run: ChangesRun?
    private(set) var changeSet: ChangeSet?
    private(set) var tab: Tab = .summary
    private(set) var tour: ChangeTour.Result?
    private(set) var tourStatus = ""
    private var tourRunner: ChangeTour?
    private var baseRef: BaseRef = .baseBranch
    private var baseName: String?
    private var baseOption = ""
    private var startLink: String?
    private var customChoice: String?
    private var lastBases: [String: (BaseRef, String?)] = [:]
    private var ticker: Timer?
    /// The differing screens in the order of the tiles: added, then changed, then removed.
    private var shown: [ChangeScreen] = []
    /// The groups of `shown`, each a status and its screens (empty groups left out).
    private var groups: [(status: ChangeStatus, screens: [ChangeScreen])] = []
    static func groupWord(_ s: ChangeStatus) -> String {
        switch s { case .new: return "Added"; case .changed: return "Changed"; case .gone: return "Removed"; default: return s.word.capitalized }
    }
    private func indexPath(of id: String) -> IndexPath? {
        for (g, group) in groups.enumerated() { if let i = group.screens.firstIndex(where: { $0.id == id }) { return IndexPath(item: i, section: g) } }
        return nil
    }
    private func screen(at p: IndexPath) -> ChangeScreen? {
        groups.indices.contains(p.section) && groups[p.section].screens.indices.contains(p.item) ? groups[p.section].screens[p.item] : nil
    }
    /// What changed on the selected screen, in lines: how it is reached, why it was walked again, texts and controls.
    private let detailNotes = NSTextField(wrappingLabelWithString: "")
    var detailNotesText: String { detailNotes.stringValue }
    var groupTitles: [String] { groups.map { Self.groupWord($0.status) + " \($0.screens.count)" } }
    private var selectedScreen: String?
    private var shownImages: (base: Bool, head: Bool, diff: Bool) = (false, false, false)

    // MARK: Views

    private let dim = NSView()
    private let panel = GlassView(radius: 18)
    private let headLabel = NSTextField(labelWithString: "")
    private let againstLabel = NSTextField(labelWithString: "against")
    private let basePopup = NSPopUpButton()
    private let compareButton = GlassButton(symbol: "play.fill", title: "Compare", label: "Walk both builds and compare them", style: .accent, target: nil, action: nil)
    private let copyButton = GlassButton(symbol: "doc.on.doc", title: "Copy summary", label: "Copy the summary as Markdown, for a pull request", style: .well, target: nil, action: nil)
    private let exportButton = GlassButton(symbol: "square.and.arrow.up", title: "Export…", label: "Export the map as a folder with an index.html anyone can open in a browser", style: .well, target: nil, action: nil)
    private let reportButton = GlassButton(symbol: "safari", title: "Open report", label: "Open the crawler's report of this pair", style: .well, target: nil, action: nil)
    private var tabButtons: [GlassButton] = []
    private let diffPills = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let body = NSView()

    // The state card over the tabs (nothing yet, walking, an offer, a failure).
    private let stateCard = NSStackView()
    private let stateSpinner = NSProgressIndicator()
    private let stateTitle = NSTextField(labelWithString: "")
    private let stateText = NSTextField(wrappingLabelWithString: "")
    private let stateButtons = NSStackView()

    private let summaryView = NSView()
    private let summaryStack = NSStackView()
    private let screensView = NSView()
    private let mapView = NSView()
    private let videoView = NSView()
    private let liveView = NSView()

    // Screens tab.
    private let collection = NSCollectionView()
    private let screensEmpty = NSTextField(wrappingLabelWithString: "")
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailStatus = NSTextField(wrappingLabelWithString: "")
    private var modeButtons: [GlassButton] = []
    private var compareMode = 0   // 0: side by side, 1: wipe, 2: diff solo
    private let goButton = GlassButton(symbol: "arrow.forward.circle.fill", title: "Go there", label: "Open this screen on the session's simulator", style: .accent, target: nil, action: nil)
    private let basePane = SnapshotPicture(), headPane = SnapshotPicture(), diffPane = SnapshotPicture(), diffSoloPane = SnapshotPicture()
    private let wipe = SnapshotWipe()
    private let wipeSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var sideBySide = NSStackView()
    private var wipeBox = NSStackView()

    // Map tab: the navigator and the detail column (MapHost), fed from the comparison's snapshots.
    let mapHost = MapHost()
    private var mapGeneration = 0

    // Video tab.
    private let baseVideo = AVPlayerView(), headVideo = AVPlayerView()
    private let videoNote = NSTextField(wrappingLabelWithString: "")
    private let videoButtons = NSStackView()
    private let chapterRow = NSStackView()
    private let playButton = GlassButton(symbol: "play.fill", title: "Play", label: "Play both clips together", style: .well, target: nil, action: nil)
    private let videoColumns = NSStackView()
    private var playing = false
    private var chapterTimeObserver: Any?
    private var chapterButtons: [GlassButton] = []

    // Live tab.
    private let liveText = NSTextField(wrappingLabelWithString: "")
    private let liveButton = GlassButton(symbol: "rectangle.split.2x1", title: "Open both side by side", label: "Run the base beside the session's simulator with mirrored input", style: .accent, target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        appearance = NSAppearance(named: .darkAqua)
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

    private func wellView(_ radius: CGFloat = 12) -> NSView {
        let w = NSView()
        w.wantsLayer = true
        w.layer?.backgroundColor = Design.well.cgColor
        w.layer?.cornerRadius = radius
        w.layer?.cornerCurve = .continuous
        return w
    }

    private func pin(_ v: NSView, in host: NSView, inset: CGFloat = 0) {
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
        NSLayoutConstraint.activate([v.topAnchor.constraint(equalTo: host.topAnchor, constant: inset), v.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -inset),
                                     v.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: inset), v.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -inset)])
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

        // Header: the head build, "against", the base picker, and what can be done with the result.
        let title = label("Changes", size: 15, weight: .semibold, color: Design.ink)
        headLabel.font = .systemFont(ofSize: 12, weight: .medium)
        headLabel.textColor = Design.ink
        headLabel.lineBreakMode = .byTruncatingMiddle
        headLabel.setContentCompressionResistancePriority(.init(2), for: .horizontal)
        againstLabel.font = .systemFont(ofSize: 12)
        againstLabel.textColor = Design.mute
        againstLabel.setContentHuggingPriority(.required, for: .horizontal)
        basePopup.controlSize = .small
        basePopup.font = .systemFont(ofSize: 12)
        basePopup.setContentCompressionResistancePriority(.init(3), for: .horizontal)
        compareButton.target = self; compareButton.action = #selector(comparePressed)
        copyButton.target = self; copyButton.action = #selector(copySummary)
        reportButton.target = self; reportButton.action = #selector(openReport)
        exportButton.target = self; exportButton.action = #selector(exportPressed)
        let close = GlassButton(symbol: "xmark", label: "Close (Esc)", target: self, action: #selector(closePressed))
        let hs = NSView(); hs.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, headLabel, againstLabel, basePopup, hs, compareButton, copyButton, exportButton, reportButton, close])
        header.spacing = 10

        tabButtons = Tab.allCases.map { t in
            let b = GlassButton(symbol: nil, title: t.title, label: "Show \(t.title)", style: .plain, target: self, action: #selector(tabPicked(_:)))
            b.tag = t.rawValue
            b.font = .systemFont(ofSize: 12, weight: .semibold)
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            b.layer?.cornerRadius = 9
            b.isEnabled = false
            return b
        }
        tabButtons[0].isOn = true
        let tabRow = NSStackView(views: tabButtons)
        tabRow.spacing = 4
        tabRow.alignment = .centerY

        diffPills.spacing = 6
        diffPills.alignment = .centerY
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = Design.mute
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let ss = NSView(); ss.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [tabRow, diffPills, ss, statusLabel])
        bar.alignment = .centerY
        bar.spacing = 12

        buildSummary()
        buildScreens()
        buildMap()
        buildVideo()
        buildLive()
        for v in [summaryView, screensView, mapView, videoView, liveView] { pin(v, in: body); v.isHidden = true }

        // The state card, over the tabs.
        stateSpinner.style = .spinning
        stateSpinner.controlSize = .regular
        stateSpinner.isDisplayedWhenStopped = false
        stateTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        stateTitle.textColor = Design.ink
        stateText.font = .systemFont(ofSize: 13)
        stateText.textColor = Design.mute
        stateText.alignment = .center
        stateText.maximumNumberOfLines = 0
        stateButtons.spacing = 8
        stateCard.orientation = .vertical
        stateCard.alignment = .centerX
        stateCard.spacing = 10
        for v in [stateSpinner, stateTitle, stateText, stateButtons] as [NSView] { stateCard.addArrangedSubview(v) }
        stateCard.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(stateCard)
        NSLayoutConstraint.activate([stateCard.centerXAnchor.constraint(equalTo: body.centerXAnchor), stateCard.centerYAnchor.constraint(equalTo: body.centerYAnchor),
                                     stateCard.widthAnchor.constraint(lessThanOrEqualToConstant: 520), stateText.widthAnchor.constraint(lessThanOrEqualToConstant: 500)])

        let rule = NSView(); rule.wantsLayer = true; rule.layer?.backgroundColor = Design.stroke.cgColor
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let column = NSStackView(views: [header, rule, bar, body])
        column.orientation = .vertical
        column.spacing = 10
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)
        body.translatesAutoresizingMaskIntoConstraints = false
        for v in [header, rule, bar, body] as [NSView] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        body.setContentHuggingPriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([column.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14), column.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
                                     column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18), column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18)])
    }

    private func buildSummary() {
        summaryStack.orientation = .vertical
        summaryStack.alignment = .leading
        summaryStack.spacing = 14
        let flip = ChangesFlipped()
        summaryStack.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(summaryStack)
        flip.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.documentView = flip
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        NSLayoutConstraint.activate([
            summaryStack.topAnchor.constraint(equalTo: flip.topAnchor, constant: 4), summaryStack.leadingAnchor.constraint(equalTo: flip.leadingAnchor, constant: 4),
            summaryStack.trailingAnchor.constraint(equalTo: flip.trailingAnchor, constant: -4), summaryStack.bottomAnchor.constraint(equalTo: flip.bottomAnchor, constant: -4),
            flip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        pin(scroll, in: summaryView)
    }

    private func buildScreens() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 140, height: 232)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 4, left: 4, bottom: 8, right: 4)
        layout.headerReferenceSize = NSSize(width: 100, height: 26)
        collection.collectionViewLayout = layout
        collection.register(ChangeTileItem.self, forItemWithIdentifier: ChangeTileItem.identifier)
        collection.register(ChangeGroupHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: ChangeGroupHeader.identifier)
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
        screensEmpty.font = .systemFont(ofSize: 13)
        screensEmpty.textColor = Design.mute
        screensEmpty.alignment = .center
        let gridBox = NSView()
        for v in [scroll, screensEmpty] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; gridBox.addSubview(v) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: gridBox.topAnchor), scroll.bottomAnchor.constraint(equalTo: gridBox.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: gridBox.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: gridBox.trailingAnchor),
            screensEmpty.centerXAnchor.constraint(equalTo: gridBox.centerXAnchor), screensEmpty.centerYAnchor.constraint(equalTo: gridBox.centerYAnchor),
            screensEmpty.widthAnchor.constraint(lessThanOrEqualTo: gridBox.widthAnchor, constant: -40),
            gridBox.widthAnchor.constraint(equalToConstant: 330),
        ])

        detailTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        detailTitle.textColor = Design.ink
        detailTitle.lineBreakMode = .byTruncatingTail
        detailTitle.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        detailStatus.font = .systemFont(ofSize: 12)
        detailStatus.textColor = Design.mute
        detailStatus.maximumNumberOfLines = 2
        detailNotes.font = .systemFont(ofSize: 11.5)
        detailNotes.textColor = Design.mute
        detailNotes.maximumNumberOfLines = 9
        detailNotes.isSelectable = true
        detailNotes.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        modeButtons = ["Side by side", "Wipe", "Diff"].enumerated().map { idx, text in
            let b = GlassButton(symbol: nil, title: text, label: "Comparison view: \(text)", style: .well, target: self, action: #selector(modePicked(_:)))
            b.tag = idx
            b.font = .systemFont(ofSize: 11.5, weight: .medium)
            b.heightAnchor.constraint(equalToConstant: 25).isActive = true
            b.layer?.cornerRadius = 8
            return b
        }
        modeButtons[0].isOn = true
        let modeRow = NSStackView(views: modeButtons)
        modeRow.spacing = 4
        goButton.target = self; goButton.action = #selector(goPressed)
        let dspacer = NSView(); dspacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let dhead = NSStackView(views: [detailTitle, dspacer, modeRow, goButton])
        dhead.alignment = .centerY
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
        sideBySide = NSStackView(views: [column("Base", basePane), column("Head", headPane), column("Difference", diffPane)])
        sideBySide.distribution = .fillEqually
        sideBySide.spacing = 10
        wipe.onChange = { [weak self] p in self?.wipeSlider.doubleValue = Double(p) }
        wipeSlider.target = self; wipeSlider.action = #selector(wipeMoved)
        let wipeBar = NSStackView(views: [label("Base", size: 11, weight: .medium), wipeSlider, label("Head", size: 11, weight: .medium)])
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
        diffSoloPane.isHidden = true
        let detailBody = NSView()
        detailBody.translatesAutoresizingMaskIntoConstraints = false
        for v in [sideBySide, wipeBox, diffSoloPane] as [NSView] { pin(v, in: detailBody) }
        let detail = NSStackView(views: [dhead, detailStatus, detailNotes, detailBody])
        detail.orientation = .vertical
        detail.spacing = 6
        detail.alignment = .leading
        for v in [dhead, detailStatus, detailNotes, detailBody] as [NSView] { v.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
        let well = wellView()
        pin(detail, in: well, inset: 12)

        let row = NSStackView(views: [gridBox, well])
        row.spacing = 14
        row.distribution = .fill
        pin(row, in: screensView)
    }

    private func buildMap() {
        let mapWell = NSView()
        mapWell.wantsLayer = true
        mapWell.layer?.backgroundColor = NSColor(white: 0, alpha: 0.22).cgColor
        mapWell.layer?.cornerRadius = 12
        mapWell.layer?.cornerCurve = .continuous
        mapWell.layer?.masksToBounds = true
        let grid = StageBackground(frame: .zero)
        pin(grid, in: mapWell)
        pin(mapHost, in: mapWell)
        mapHost.onGo = { [weak self] lineage in
            guard let self, let id = self.mapHost.source?.head.screens.first(where: { $0.lineage == lineage })?.id else { return }
            self.go(id)
        }
        mapHost.onCopyRoute = { [weak self] text in self?.onSay?("Route copied: \(text.split(separator: "\n").count) control commands", false) }
        pin(mapWell, in: mapView)
    }

    private func dotLabel(_ text: String, _ color: NSColor) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])
        let s = NSStackView(views: [dot, label(text, size: 11)])
        s.spacing = 5
        return s
    }

    private func buildVideo() {
        for v in [baseVideo, headVideo] {
            v.controlsStyle = .none
            v.videoGravity = .resizeAspect
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
            v.layer?.cornerRadius = 8
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
        }
        func column(_ name: String, _ v: AVPlayerView) -> NSStackView {
            let c = NSStackView(views: [label(name, size: 11, weight: .medium), v])
            c.orientation = .vertical
            c.alignment = .centerX
            c.spacing = 4
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: c.widthAnchor).isActive = true
            return c
        }
        videoColumns.setViews([column("Base", baseVideo), column("Head", headVideo)], in: .leading)
        videoColumns.distribution = .fillEqually
        videoColumns.spacing = 12
        playButton.target = self; playButton.action = #selector(playPressed)
        chapterRow.spacing = 6
        let chapterScroll = NSStackView(views: [playButton, chapterRow])
        chapterScroll.spacing = 10
        chapterScroll.alignment = .centerY
        videoNote.font = .systemFont(ofSize: 13)
        videoNote.textColor = Design.mute
        videoNote.alignment = .center
        videoNote.maximumNumberOfLines = 0
        videoButtons.spacing = 8
        let noteBox = NSStackView(views: [videoNote, videoButtons])
        noteBox.orientation = .vertical
        noteBox.alignment = .centerX
        noteBox.spacing = 10
        let column = NSStackView(views: [videoColumns, chapterScroll, noteBox])
        column.orientation = .vertical
        column.spacing = 10
        column.alignment = .leading
        videoColumns.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        noteBox.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        videoColumns.setContentHuggingPriority(.init(1), for: .vertical)
        let well = wellView()
        pin(column, in: well, inset: 12)
        pin(well, in: videoView)
    }

    private func buildLive() {
        liveText.font = .systemFont(ofSize: 13)
        liveText.textColor = Design.mute
        liveText.alignment = .center
        liveText.maximumNumberOfLines = 0
        liveButton.target = self; liveButton.action = #selector(livePressed)
        let stack = NSStackView(views: [label("Both builds, live", size: 16, weight: .semibold, color: Design.ink), liveText, liveButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        liveView.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: liveView.centerXAnchor), stack.centerYAnchor.constraint(equalTo: liveView.centerYAnchor),
                                     liveText.widthAnchor.constraint(lessThanOrEqualToConstant: 480)])
    }

    // MARK: Opening and closing

    /// Opens on `session`. `compare`: starts a comparison with the repository's base branch at once.
    func open(session: Session, compare: Bool) {
        let changed = self.session?.worktree.path != session.worktree.path
        // A rebuild since the comparison: what the sheet holds is of the old build.
        let current = controller?.builds[session.worktree.path] ?? session.build
        let stale = !changed && run?.head != nil && current != nil && current?.key != run?.head?.key
        let compareNow = compare || stale
        self.session = session
        if changed || stale || run == nil {
            run?.cancel()
            tourRunner?.cancel()
            resetResult()
            if let c = controller { run = ChangesRun(session: session, controller: c); run?.onState = { [weak self] s in self?.stateChanged(s) } }
            let last = lastBases[session.worktree.path]
            baseRef = last?.0 ?? .baseBranch
            baseName = last?.1
            customChoice = nil
        }
        refreshHeader()
        rebuildBaseMenu()
        if !isOpen {
            isOpen = true
            isHidden = false
            alphaValue = 0
            panel.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: 8))
            window?.makeFirstResponder(self)
            Design.animate(Design.arrive, {
                self.animator().alphaValue = 1
                self.panel.layer?.setAffineTransform(.identity)
            }, done: { if self.tab == .map { self.mapHost.settle() } })
            onToggle?()
        }
        if compareNow, !(run?.isActive ?? false), changeSet == nil { self.compare(base: baseRef, name: baseName) }
        else if run.map({ if case .idle = $0.state { return true } else { return false } }) ?? true { stateChanged(.idle) }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        pausePlayers()
        Design.animate(Design.snap, { self.animator().alphaValue = 0 }, done: { if !self.isOpen { self.isHidden = true } })
        onToggle?()
    }

    @objc private func closePressed() { close() }
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { close() } else { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) { if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { close() } }

    // MARK: The base

    private func rebuildBaseMenu() {
        let menu = NSMenu()
        func add(_ title: String, tag: Int, object: Any? = nil) {
            let item = NSMenuItem(title: title, action: #selector(basePicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.representedObject = object
            menu.addItem(item)
        }
        if let custom = customChoice { add(custom, tag: 100); menu.addItem(.separator()) }
        let ws = session.flatMap { controller?.workspace(of: $0) }
        add((ws?.baseRef ?? "origin/main") + " (the base branch)", tag: 1)
        let others = (controller?.sessions ?? []).filter { $0.worktree.path != session?.worktree.path && $0.workspace.path == session?.workspace.path }
        if !others.isEmpty {
            menu.addItem(.separator())
            for s in others { add("Session: " + s.title, tag: 2, object: s.worktree.path) }
        }
        menu.addItem(.separator())
        add("Pull request…", tag: 3)
        add("Branch or commit…", tag: 4)
        add("APK file…", tag: 5)
        basePopup.menu = menu
        if customChoice != nil { basePopup.selectItem(at: 0) }
        else if case .session(let path) = baseRef, let i = menu.items.firstIndex(where: { ($0.representedObject as? String) == path }) { basePopup.selectItem(at: i) }
        else { basePopup.selectItem(at: 0) }
    }

    @objc private func basePicked(_ sender: NSMenuItem) {
        switch sender.tag {
        case 100: break   // the custom choice already shown
        case 1: customChoice = nil; setBase(.baseBranch, name: nil)
        case 2:
            guard let path = sender.representedObject as? String else { return }
            customChoice = nil
            setBase(.session(path), name: String(sender.title.dropFirst("Session: ".count)))
        case 3: askText("Compare with a pull request", "Its number or address. Greenroom fetches the build GitHub Actions made of its head with your gh sign-in.", "42 or https://github.com/owner/repo/pull/42") { [weak self] text in
            guard let pr = PullRequestRef.parse(text) else { self?.onSay?("That is not a pull request number or address", true); return }
            self?.customChoice = "Pull request #\(pr.number)"
            self?.setBase(.pullRequest(pr.number), name: "#\(pr.number)")
        }
        case 4: askText("Compare with a branch or commit", "A branch, tag or commit of this repository.", "main, a1b2c3d, release/1.2") { [weak self] text in
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            self?.customChoice = t
            self?.setBase(.ref(t), name: t)
        }
        case 5: chooseAPK()
        default: break
        }
        rebuildBaseMenu()
    }

    private func setBase(_ ref: BaseRef, name: String?) {
        baseRef = ref
        baseName = name
        baseOption = ""
        startLink = nil
        if let p = session?.worktree.path { lastBases[p] = (ref, name) }
        compare(base: ref, name: name)
    }

    private func askText(_ title: String, _ info: String, _ placeholder: String, _ done: @escaping (String) -> Void) {
        guard let w = window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "Compare")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { done(field.stringValue) } }
    }

    private func chooseAPK() {
        guard let w = window else { return }
        let p = NSOpenPanel()
        p.message = "Choose the APK to compare with"
        p.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        p.beginSheetModal(for: w) { [weak self] r in
            guard r == .OK, let u = p.url, let self else { return }
            self.customChoice = u.lastPathComponent
            self.rebuildBaseMenu()
            self.setBase(.apk(u), name: u.lastPathComponent)
        }
    }

    // MARK: Comparing

    /// Starts a comparison of the session's build with `base` (resolved through Bases; nothing is built). `baseOption`
    /// and `start` are the engine options of the base's launches and a deep link to start from (checks use both).
    func compare(base: BaseRef, name: String? = nil, baseOption: String = "", start: String? = nil) {
        guard let run else { return }
        baseRef = base
        baseName = name
        if case .baseBranch = base { customChoice = nil } else if let name { customChoice = name }
        rebuildBaseMenu()
        self.baseOption = baseOption
        startLink = start
        resetResult()
        run.start(base: base, baseOption: baseOption, start: start)
    }

    @objc private func comparePressed() {
        if run?.isActive == true { run?.cancel(); return }
        compare(base: baseRef, name: baseName, baseOption: baseOption, start: startLink)
    }

    private func resetResult() {
        changeSet = nil
        tour = nil
        tourStatus = ""
        tourRunner?.cancel()
        tourRunner = nil
        selectedScreen = nil
        shown = []
        collection.reloadData()
        mapGeneration += 1
        mapHost.clear()
        unloadVideo()
    }

    private func stateChanged(_ state: ChangesRun.State) {
        ticker?.invalidate()
        ticker = nil
        compareButton.title = run?.isActive == true ? "Stop" : (changeSet == nil ? "Compare" : "Compare again")
        compareButton.style = run?.isActive == true ? .record : .accent
        refreshHeader()
        stateSpinner.stopAnimation(nil)
        stateButtons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func card(_ title: String, _ text: String, spinning: Bool = false) {
            stateCard.isHidden = false
            stateTitle.stringValue = title
            stateText.stringValue = text
            if spinning { stateSpinner.startAnimation(nil) }
            stateSpinner.isHidden = !spinning
            showTab(nil)
        }
        switch state {
        case .idle:
            card("Compare this build", "Choose what to compare it with, then press Compare. Greenroom walks both builds and shows the screens that differ.")
            statusLabel.stringValue = ""
        case .resolving:
            card("Finding the base build…", "Looking for a build of what you chose: one already stored, then what CI made of that commit.", spinning: true)
        case .offer(let o):
            card("There is no build of the base yet", o.message)
            let b = GlassButton(symbol: "arrow.triangle.branch", title: "Check out in a worktree", label: "Adds a worktree at that commit to Sessions; build it from its row, then compare again", style: .accent, target: self, action: #selector(offerCheckout))
            offer = o
            stateButtons.addArrangedSubview(b)
        case .walking(_, _, let since):
            compareButton.title = "Stop"
            compareButton.style = .record
            tickWalking(since)
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickWalking(since) }
        case .needsMain(let title, let text, let waiting):
            card(title, text, spinning: waiting)
            statusLabel.stringValue = ""
            if waiting { compareButton.title = "Stop"; compareButton.style = .record }
        case .done(let set):
            changeSet = set
            stateCard.isHidden = true
            populate(set)
            showTab(tab)
            if tourAutomatically { startTour() }
        case .failed(let why):
            card("Could not compare", why)
            let b = GlassButton(symbol: "arrow.clockwise", title: "Try again", label: "Try the same comparison again", style: .well, target: self, action: #selector(comparePressed))
            stateButtons.addArrangedSubview(b)
            statusLabel.stringValue = ""
        case .cancelled:
            card("Stopped", "The comparison was stopped. Nothing was kept.")
            statusLabel.stringValue = ""
        }
        for b in tabButtons { b.isEnabled = changeSet != nil }
        if run?.isActive != true { compareButton.title = changeSet == nil ? "Compare" : "Compare again"; compareButton.style = .accent }
    }
    private var offer: BuildOffer?

    private func tickWalking(_ since: Date) {
        guard case .walking(let depth, let known, _)? = run?.state else { return }
        let s = Int(Date().timeIntervalSince(since))
        let t = String(format: "%d:%02d", s / 60, s % 60)
        var line = "Walking both builds, the head first and then the base"
        if known > 0 { line = depth == -1 ? "Capturing \(known) screens" : "Walking \(depth == 0 ? "the first screen" : "\(depth) tap\(depth == 1 ? "" : "s") deep"), \(known) screen\(known == 1 ? "" : "s") found" }
        stateCard.isHidden = false
        stateSpinner.isHidden = false
        stateSpinner.startAnimation(nil)
        stateTitle.stringValue = "Comparing…"
        stateText.stringValue = line + "  ·  " + t + "\nIt runs its own hidden devices, so yours are left alone."
        statusLabel.stringValue = ""
        showTab(nil)
    }

    @objc private func offerCheckout() {
        guard let o = offer, let s = session, let ws = controller?.workspace(of: s), let store = controller?.store else { return }
        let dir = store.root.appendingPathComponent("worktrees/\(ws.root.lastPathComponent)-\(o.sha.prefix(7))", isDirectory: true)
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
            var ok = FileManager.default.fileExists(atPath: dir.path)
            if !ok { ok = await Git.run(["worktree", "add", "--detach", dir.path, o.sha], in: ws.root, timeout: 60) != nil }
            if ok {
                self.controller?.refresh()
                self.onSay?("Checked out \(o.sha.prefix(7)) as a session. Build it from its row, then compare again.", false)
            } else {
                self.onSay?("Could not check out \(o.sha.prefix(7))", true)
            }
        }
    }

    // MARK: Header and status

    private func refreshHeader() {
        guard let s = session else { return }
        if let h = run?.head { headLabel.stringValue = ChangeSet.describe(h, name: s.branch ?? s.title) }
        else { headLabel.stringValue = "\(s.branch ?? s.title) \(s.shortHead)" + (controller?.hasBuild(s) == false ? " (no build)" : "") }
        let running = run?.isActive == true
        copyButton.isHidden = changeSet == nil
        exportButton.isHidden = changeSet == nil
        exportButton.isEnabled = mapHost.canExport && run?.isActive != true
        reportButton.isHidden = changeSet?.reportURL == nil
        compareButton.isEnabled = true
        basePopup.isEnabled = !running
        diffPills.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let set = changeSet, run?.base != nil || set.baseline != nil {
            let c = set.summary
            // A comparison with the base branch's stored map has no base build: it says which map.
            let against = run?.base.map { ChangeSet.describe($0, name: baseName) } ?? set.baseline ?? ""
            statusLabel.stringValue = "\(against)  ·  \(c.new) new, \(c.changed) changed, \(c.gone) gone, \(c.same) the same" + (set.unreached > 0 ? ", \(set.unreached) not reached" : "")
                + (set.unplaced.isEmpty ? "" : "  ·  \(set.unplaced.count) change\(set.unplaced.count == 1 ? "" : "s") not traced to screens")
            if tabButtons.indices.contains(Tab.screens.rawValue) {
                let n = set.differing.count
                tabButtons[Tab.screens.rawValue].title = n > 0 ? "Screens (\(n))" : "Screens"
            }
            func pill(_ text: String, _ color: NSColor) -> NSView {
                let l = label(text, size: 11, weight: .semibold, color: color)
                let box = NSView()
                box.wantsLayer = true
                box.layer?.cornerRadius = 9
                box.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
                l.translatesAutoresizingMaskIntoConstraints = false
                box.addSubview(l)
                NSLayoutConstraint.activate([
                    l.topAnchor.constraint(equalTo: box.topAnchor, constant: 2), l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
                    l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), l.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
                ])
                return box
            }
            if c.new > 0 { diffPills.addArrangedSubview(pill("+\(c.new) new", ChangeStatus.new.color)) }
            if c.changed > 0 { diffPills.addArrangedSubview(pill("~\(c.changed) changed", ChangeStatus.changed.color)) }
            if c.gone > 0 { diffPills.addArrangedSubview(pill("−\(c.gone) gone", ChangeStatus.gone.color)) }
        } else if tabButtons.indices.contains(Tab.screens.rawValue) {
            tabButtons[Tab.screens.rawValue].title = "Screens"
        }
    }

    /// The base as the header says it, for the summary Markdown.
    var baseDescription: String { run?.base.map { ChangeSet.describe($0, name: baseName) } ?? changeSet?.baseline ?? "the base" }
    var headDescription: String { run?.head.map { ChangeSet.describe($0, name: session?.branch ?? session?.title) } ?? "this build" }

    /// The Markdown "Copy summary" puts on the clipboard.
    var markdown: String? { changeSet?.markdown(head: headDescription, base: baseDescription) }

    @objc func copySummary() {
        guard let text = markdown else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onSay?("Summary copied: paste it into a pull request", false)
    }

    // MARK: Export

    private var exportTitle: String { "Changes of " + (session?.branch ?? session?.title ?? "this build") }
    private var exportNames: (base: String, head: String) { (baseName ?? "base", session?.branch ?? session?.title ?? "this build") }

    @objc private func exportPressed() {
        guard !(run?.isActive ?? false) else { return }
        mapHost.exportWithPanel(title: exportTitle, names: exportNames, suggested: "map-export") { [weak self] r in self?.exported(r) }
    }

    /// For checks: exports to `folder` with no panel.
    func exportNow(to folder: URL, done: @escaping (Result<URL, Error>) -> Void) {
        mapHost.export(to: folder, title: exportTitle, names: exportNames) { [weak self] r in self?.exported(r, reveal: false); done(r) }
    }

    private(set) var exportStatus = ""

    private func exported(_ r: Result<URL, Error>, reveal: Bool = true) {
        switch r {
        case .success(let index):
            exportStatus = "Exported to \(index.deletingLastPathComponent().path)"
            onSay?("Map exported", false)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([index]) }
        case .failure(let e):
            exportStatus = "The export failed: \(e.localizedDescription)"
            onSay?("The export failed", true)
        }
    }

    @objc private func openReport() {
        guard let url = changeSet?.reportURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Tabs

    @objc private func tabPicked(_ sender: GlassButton) { selectTab(Tab(rawValue: sender.tag) ?? .summary) }

    func selectTab(_ t: Tab) {
        tab = t
        for b in tabButtons { b.isOn = b.tag == t.rawValue }
        if changeSet != nil { showTab(t) }
        if t != .video { pausePlayers() }
    }

    private func showTab(_ t: Tab?) {
        let views = [summaryView, screensView, mapView, videoView, liveView]
        for (i, v) in views.enumerated() { v.isHidden = t?.rawValue != i }
        if t == .map { DispatchQueue.main.async { self.mapHost.settle() } }
    }

    // MARK: Filling the tabs

    private func populate(_ set: ChangeSet) {
        fillSummary(set)
        let differing = set.differing
        groups = [ChangeStatus.new, .changed, .gone].compactMap { st in
            let list = differing.filter { $0.status == st }
            return list.isEmpty ? nil : (st, list)
        }
        shown = groups.flatMap(\.screens)
        collection.reloadData()
        screensEmpty.stringValue = shown.isEmpty ? "No screen differs from the base." : ""
        selectedScreen = nil
        showDetail(nil)
        if let first = shown.first { selectScreen(first.id) }
        showMap(set)
        fillLive()
        refreshVideo()
        refreshHeader()
    }

    private func fillSummary(_ set: ChangeSet) {
        summaryStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let s = set.summary
        func tile(_ n: Int, _ caption: String, _ color: NSColor) -> NSView {
            let num = NSTextField(labelWithString: "\(n)")
            num.font = .systemFont(ofSize: 34, weight: .semibold)
            num.textColor = n == 0 ? Design.mute : color
            let cap = label(caption, size: 12, weight: .medium, color: n == 0 ? Design.mute : color)
            let st = NSStackView(views: [num, cap])
            st.orientation = .vertical
            st.alignment = .leading
            st.spacing = 0
            st.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            let w = wellView()
            st.translatesAutoresizingMaskIntoConstraints = false
            w.addSubview(st)
            NSLayoutConstraint.activate([st.topAnchor.constraint(equalTo: w.topAnchor), st.bottomAnchor.constraint(equalTo: w.bottomAnchor),
                                         st.leadingAnchor.constraint(equalTo: w.leadingAnchor), st.trailingAnchor.constraint(equalTo: w.trailingAnchor),
                                         w.widthAnchor.constraint(greaterThanOrEqualToConstant: 130)])
            return w
        }
        let tiles = NSStackView(views: [tile(s.new, "new", ChangeStatus.new.color), tile(s.changed, "changed", ChangeStatus.changed.color),
                                        tile(s.gone, "gone", ChangeStatus.gone.color), tile(s.same, "the same", Design.mute)]
                                       + (set.unreached > 0 ? [tile(set.unreached, "not reached", Design.mute)] : []))
        tiles.spacing = 10
        summaryStack.addArrangedSubview(tiles)
        if set.isUnchanged {
            let ok = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 22, weight: .medium)) ?? NSImage())
            ok.contentTintColor = Design.accent
            let words = NSStackView(views: [label("No differences", size: 15, weight: .semibold, color: Design.ink),
                                            label(set.identical ? "Head and base are the same build, so nothing was walked." : (set.unreached > 0
                                                  ? "None of the \(s.same) screens both walks reached differs. \(set.unreached) more were reached by one walk only, because the other did not finish."
                                                  : "Every one of the \(s.same) screens the walk reached looks and is built the same as in the base."), size: 12)])
            words.orientation = .vertical
            words.alignment = .leading
            words.spacing = 2
            let row = NSStackView(views: [ok, words])
            row.spacing = 10
            row.alignment = .centerY
            summaryStack.addArrangedSubview(row)
        } else {
            summaryStack.addArrangedSubview(section("WHAT DIFFERS", set.differing.map { c in
                let sign = c.status == .new ? "+" : (c.status == .gone ? "−" : "~")
                return (sign, c.status.color, c.title + "  ·  " + c.detail)
            }))
        }
        if !set.unplaced.isEmpty {
            // Changes the walk could not trace to screens: said, not walked for.
            summaryStack.addArrangedSubview(section("NOT TRACED TO SCREENS", set.unplaced.map { ("?", Design.warning, $0.prefix(1).uppercased() + $0.dropFirst()) }
                + [("", Design.mute, "Screens these reach were not walked again, so a difference there is not shown. \u{201C}Walk Everything Again\u{201D} in the session's menu walks the whole app.")]))
        }
        if !set.crashes.isEmpty {
            summaryStack.addArrangedSubview(section("CRASHES", set.crashes.map { c in
                ("!", Design.record, "\(c.side == .base ? "Base" : "Head"): " + (c.detail.split(separator: "\n").first.map(String.init) ?? c.detail))
            }))
        }
        let skipped = set.screens.filter { $0.status == .unreached }
        if !set.unfinished.isEmpty || !skipped.isEmpty {
            summaryStack.addArrangedSubview(section("NOT FINISHED", set.unfinished.map { ("·", Design.warning, $0) } + skipped.map { ("?", Design.mute, $0.title + "  ·  not reached: " + $0.detail) }))
        }
        let limits = label(Evidence.limits, size: 11)
        limits.lineBreakMode = .byWordWrapping
        limits.maximumNumberOfLines = 0
        limits.preferredMaxLayoutWidth = 620
        summaryStack.addArrangedSubview(limits)
        tourLine.font = .systemFont(ofSize: 12)
        tourLine.textColor = Design.mute
        tourLine.stringValue = tourStatus
        summaryStack.addArrangedSubview(tourLine)
    }
    private let tourLine = NSTextField(labelWithString: "")

    private func section(_ heading: String, _ rows: [(String, NSColor, String)]) -> NSView {
        var views: [NSView] = [label(heading, size: 10, weight: .semibold)]
        for (mark, color, text) in rows.prefix(40) {
            let m = label(mark, size: 13, weight: .semibold, color: color)
            m.alignment = .center
            m.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let t = label(text, size: 12.5, color: Design.ink)
            t.lineBreakMode = .byTruncatingTail
            let r = NSStackView(views: [m, t])
            r.spacing = 8
            views.append(r)
        }
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        return s
    }

    private func fillLive() {
        let base = run?.base.map { ChangeSet.describe($0, name: baseName) } ?? "the base"
        liveText.stringValue = "Opens \(base) beside the session's simulator. A tap, a scroll or a key goes to both, and what differs between the two screens is marked. For what only hands find."
    }

    // MARK: Screens tab

    func numberOfSections(in collectionView: NSCollectionView) -> Int { groups.count }
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { groups.indices.contains(section) ? groups[section].screens.count : 0 }
    func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let v = cv.makeSupplementaryView(ofKind: kind, withIdentifier: ChangeGroupHeader.identifier, for: indexPath)
        if let h = v as? ChangeGroupHeader, groups.indices.contains(indexPath.section) { h.configure(groups[indexPath.section].status, count: groups[indexPath.section].screens.count) }
        return v
    }
    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: ChangeTileItem.identifier, for: indexPath) as! ChangeTileItem
        if let c = screen(at: indexPath) { item.configure(c) }
        return item
    }
    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let p = indexPaths.first, let c = screen(at: p) else { return }
        selectedScreen = c.id
        showDetail(c)
    }

    /// Selects a tile by id (checks, and the first one when the tab fills).
    func selectScreen(_ id: String) {
        guard let p = indexPath(of: id), let c = screen(at: p) else { return }
        collection.selectItems(at: [p], scrollPosition: .centeredVertically)
        selectedScreen = id
        showDetail(c)
    }

    var tileCount: Int { shown.count }
    var tileTitles: [String] { shown.map(\.title) }
    /// Which of the three pictures the detail has loaded (checks).
    var detailImages: (base: Bool, head: Bool, diff: Bool) { (basePane.image != nil, headPane.image != nil, diffPane.image != nil) }

    private func showDetail(_ c: ChangeScreen?) {
        guard let c else {
            detailTitle.stringValue = shown.isEmpty ? "" : "Pick a tile"
            detailStatus.stringValue = ""
            detailNotes.attributedStringValue = NSAttributedString()
            detailNotes.isHidden = true
            goButton.isHidden = true
            for p in [basePane, headPane, diffPane, diffSoloPane] { p.show(nil, empty: "") }
            wipe.show(golden: nil, actual: nil)
            return
        }
        detailTitle.stringValue = c.title
        detailStatus.stringValue = c.status.word.capitalized + "  ·  " + c.detail + (c.activity.isEmpty ? "" : "  ·  " + c.activity)
        detailStatus.textColor = c.status.color
        let notes = changeSet.map { Self.notes(of: c, in: $0) } ?? NSAttributedString()
        detailNotes.attributedStringValue = notes
        detailNotes.isHidden = notes.length == 0
        goButton.isHidden = c.status == .gone
        let id = c.id
        basePane.show(nil, empty: c.status == .new ? "Not in the base" : "")
        headPane.show(nil, empty: c.status == .gone ? "Not in the head" : "")
        let diffEmpty = c.status == .changed ? "No difference map" : "Nothing to compare"
        diffPane.show(nil, empty: diffEmpty)
        diffSoloPane.show(nil, empty: diffEmpty)
        wipe.show(golden: nil, actual: nil)
        var base: CGImage?, head: CGImage?
        func refreshWipe() { if selectedScreen == id { wipe.show(golden: base, actual: head) } }
        if let u = c.base {
            SnapshotImages.load(u, maxPixel: 1700) { [weak self] img in
                guard self?.selectedScreen == id else { return }
                base = img; self?.basePane.show(img, empty: ""); refreshWipe()
            }
        }
        if let u = c.head {
            SnapshotImages.load(u, maxPixel: 1700) { [weak self] img in
                guard self?.selectedScreen == id else { return }
                head = img; self?.headPane.show(img, empty: ""); refreshWipe()
            }
        }
        if let u = c.diff {
            SnapshotImages.load(u, maxPixel: 1700) { [weak self] img in
                if self?.selectedScreen == id {
                    self?.diffPane.show(img, empty: "")
                    self?.diffSoloPane.show(img, empty: "")
                }
            }
        }
    }

    /// What a differing screen's detail says under its status: the way there, why the walk looked at it again, and the
    /// texts and controls that were added or removed. Empty when the comparison knows none of it.
    static func notes(of c: ChangeScreen, in set: ChangeSet) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Design.mute]
        func line(_ head: String, _ body: String, _ color: NSColor = Design.ink) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: plain)) }
            out.append(NSAttributedString(string: head, attributes: plain))
            out.append(NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: color]))
        }
        func quoted(_ list: [String], limit: Int = 4) -> String {
            let shown = list.prefix(limit).map { "\u{201C}" + ChangeSet.plain($0).prefix(48) + "\u{201D}" }.joined(separator: ", ")
            return list.count > limit ? shown + " and \(list.count - limit) more" : shown
        }
        // The way there: the titles of the screens on its route, from the start.
        let map = c.status == .gone ? set.baseMap : set.headMap
        if let map, let id = c.status == .gone ? c.baseID : c.headID {
            var trail: [String] = []
            var at = map.screen(id)?.parent, seen = Set<String>()
            while let p = at, seen.insert(p).inserted, let s = map.screen(p) { trail.insert(s.label, at: 0); at = s.parent }
            if !trail.isEmpty { line("Reached from  ", (trail + [c.title]).joined(separator: "  \u{203A}  ")) }
        }
        // The walk's reasons are by the base's id: a screen whose structure changed has another id in the head.
        if let why = [c.baseID, c.headID].compactMap({ $0 }).compactMap({ set.walkedBecause[$0] }).first, !why.isEmpty {
            line("Walked again because  ", why.prefix(3).joined(separator: ", ") + (why.count > 3 ? " and \(why.count - 3) more" : ""))
        }
        if let ch = set.change(of: c) {
            if !ch.textAdded.isEmpty { line("+ text  ", quoted(ch.textAdded), Design.accent) }
            if !ch.textRemoved.isEmpty { line("\u{2212} text  ", quoted(ch.textRemoved), Design.record) }
        }
        for l in set.controlLines(of: c).prefix(4) {
            let color = l.hasPrefix("+") ? Design.accent : (l.hasPrefix("-") ? Design.record : Design.warning)
            line("control  ", l, color)
        }
        return out
    }

    @objc private func modePicked(_ sender: GlassButton) { setCompareMode(sender.tag) }
    func setCompareMode(_ mode: Int) {
        compareMode = max(0, min(2, mode))
        for b in modeButtons { b.isOn = b.tag == compareMode }
        sideBySide.isHidden = compareMode != 0
        wipeBox.isHidden = compareMode != 1
        diffSoloPane.isHidden = compareMode != 2
    }
    func setMode(wipe on: Bool) { setCompareMode(on ? 1 : 0) }
    @objc private func wipeMoved() { wipe.position = CGFloat(wipeSlider.doubleValue) }

    @objc private func goPressed() { if let id = selectedScreen { go(id) } }

    /// Opens a screen of the head on the session's simulator: the route as the map's "Go there" replays it.
    func go(_ id: String) {
        guard let set = changeSet, let c = set.screen(id), let hid = c.headID, let screen = set.headMap.screen(hid), let session else { return }
        guard let sim = controller?.simulator(for: session), sim.state == .running else {
            onSay?("Open the session first (click its row): the route is replayed on its simulator", true)
            return
        }
        // The walk's APK is the stored copy of the build; the session's simulator may run the same file from Gradle's outputs.
        let m = set.headMap
        let adjusted = ScreenMapData(folder: m.folder, apkName: m.apkName, screens: m.screens, edges: m.edges, findings: m.findings, combos: m.combos,
                                     incomplete: m.incomplete, seconds: m.seconds, apk: sim.apk)
        close()
        onGo?(screen, adjusted)
    }

    // MARK: Map tab

    /// The comparison on the map: its two snapshots (from the history, or made from the walk's folder when the comparison
    /// came from a `--base` walk), the head's lineages paired with the base's, changes first.
    private func showMap(_ set: ChangeSet) {
        mapGeneration += 1
        let mine = mapGeneration
        mapHost.clear()
        Task { @MainActor [weak self] in
            let src = await Task.detached { set.mapSource ?? History.pairSource(folder: set.folder) }.value
            guard let self, self.mapGeneration == mine, let src else { return }
            self.mapHost.show(src)
            self.refreshHeader()
            if self.tab == .map { self.mapHost.settle() }
        }
    }

    /// For checks: the colour label of a screen's card on the map.
    var mapMarks: [String: MapMark] { changeSet?.marks ?? [:] }

    /// For checks: the card of the head's screen with this id (the Map tab's key into the comparison): its frame on the map.
    func mapFrame(of id: String) -> CGRect? { mapHost.source?.lineage(ofHeadScreen: id).flatMap { mapHost.navigator.surface.frame(of: $0) } }
    /// For checks: selects it, and the detail column fills.
    func mapSelect(_ id: String) { mapHost.source?.lineage(ofHeadScreen: id).map { mapHost.select($0, reveal: false) } }
    var mapDetailLineage: String? { mapHost.detail.isHidden ? nil : mapHost.detail.lineage }
    var mapIsReady: Bool { mapHost.source != nil && !mapHost.navigator.busy }

    // MARK: Live tab

    @objc private func livePressed() {
        guard let s = session, let b = run?.base else { return }
        close()
        onLive?(s, b)
    }

    // MARK: Video tab: the change tour

    private func startTour() {
        guard let set = changeSet, let head = run?.head, let base = run?.base, tourRunner == nil else { return }
        if let cached = ChangeTour.Result.read(set.folder) {
            tour = cached
            tourStatus = cached.skipped.map { "Change tour skipped: " + $0 } ?? "Change tour: \(cached.stops.count) screen\(cached.stops.count == 1 ? "" : "s") recorded."
            refreshVideo()
            return
        }
        if set.isUnchanged { tourStatus = "No change tour: nothing differs."; refreshVideo(); return }
        let runner = ChangeTour()
        tourRunner = runner
        tourStatus = "Recording the change tour…"
        refreshVideo()
        let options = baseOption.isEmpty ? [] : baseOption.split(separator: " ").map(String.init)
        runner.start(set: set, head: head, base: base, baseOptions: options, progress: { [weak self] line in
            self?.tourStatus = line
            self?.refreshVideo()
        }, completion: { [weak self] outcome in
            guard let self, self.tourRunner === runner else { return }
            self.tourRunner = nil
            switch outcome {
            case .done(let r):
                self.tour = r
                self.tourStatus = r.skipped.map { "Change tour skipped: " + $0 } ?? "Change tour: \(r.stops.count) screen\(r.stops.count == 1 ? "" : "s") recorded."
            case .cancelled: self.tourStatus = "The change tour was stopped."
            case .failed(let why): self.tourStatus = "The change tour failed: " + why
            }
            self.refreshVideo()
        })
    }

    /// Records the tour again now, whatever is kept (the check's, and "Try again").
    func recordTour(force: Bool = false) {
        tourRunner?.cancel()
        tourRunner = nil
        if force, let set = changeSet {
            tour = nil
            for n in ["tour.json", "tour-head.mp4", "tour-base.mp4", "tour-head.chapters.json", "tour-base.chapters.json"] { try? FileManager.default.removeItem(at: set.folder.appendingPathComponent(n)) }
        }
        startTour()
    }
    /// Stops the tour that is recording (what its Stop button does).
    func cancelTour() { tourRunner?.cancel() }
    var tourIsRunning: Bool { tourRunner != nil }
    /// The engine processes of the tour recording now (checks).
    var tourProcessIDs: [Int32] { tourRunner?.processIDs ?? [] }

    @objc private func recordTourPressed() { tourRunner = nil; startTour() }
    @objc private func stopTourPressed() { cancelTour() }

    private func unloadVideo() {
        pausePlayers()
        baseVideo.player = nil
        headVideo.player = nil
        chapterRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chapterButtons = []
    }

    private func refreshVideo() {
        tourLine.stringValue = tourStatus
        videoButtons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let set = changeSet else { return }
        let running = tourRunner != nil
        if let t = tour, t.skipped == nil, let hf = t.head {
            videoNote.stringValue = ""
            videoNote.isHidden = true
            if (headVideo.player?.currentItem?.asset as? AVURLAsset)?.url != hf {
                pausePlayers()
                headVideo.player = AVPlayer(url: hf)
                baseVideo.player = t.base.map { AVPlayer(url: $0) }
                for p in [headVideo.player, baseVideo.player] { p?.automaticallyWaitsToMinimizeStalling = false }
                NotificationCenter.default.addObserver(self, selector: #selector(clipEnded(_:)), name: .AVPlayerItemDidPlayToEndTime, object: headVideo.player?.currentItem)
            }
            chapterRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
            chapterButtons = []
            for (i, c) in t.chapters(of: hf).enumerated() {
                let b = GlassButton(symbol: nil, title: "\(i + 1)  \(c.title)", label: "Play from \(c.title)", style: .well, target: self, action: #selector(chapterPressed(_:)))
                b.tag = i
                chapterRow.addArrangedSubview(b)
                chapterButtons.append(b)
            }
            videoColumns.isHidden = false
            playButton.isHidden = false
            return
        }
        videoColumns.isHidden = true
        playButton.isHidden = true
        chapterRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        videoNote.isHidden = false
        if running {
            videoNote.stringValue = tourStatus + "\nBoth builds are driven to each new or changed screen on hidden devices, and the screens are recorded."
            videoButtons.addArrangedSubview(GlassButton(symbol: "stop.fill", title: "Stop", label: "Stop recording the tour", style: .record, target: self, action: #selector(stopTourPressed)))
        } else if let t = tour, let why = t.skipped {
            videoNote.stringValue = "No change tour: " + why
            if !set.isUnchanged { videoButtons.addArrangedSubview(GlassButton(symbol: "arrow.clockwise", title: "Try again", label: "Record the change tour again", style: .well, target: self, action: #selector(recordTourPressed))) }
        } else if set.isUnchanged {
            videoNote.stringValue = "Nothing differs, so there is nothing to record."
        } else {
            videoNote.stringValue = tourStatus.isEmpty ? "Both builds recorded at each new or changed screen, side by side." : tourStatus
            videoButtons.addArrangedSubview(GlassButton(symbol: "record.circle", title: "Record the change tour", label: "Take both builds to each screen that differs and record them", style: .accent, target: self, action: #selector(recordTourPressed)))
        }
    }

    @objc private func clipEnded(_ n: Notification) { playing = false; playButton.title = "Play" }

    private func pausePlayers() {
        playing = false
        playButton.title = "Play"
        baseVideo.player?.pause()
        headVideo.player?.pause()
    }

    @objc private func playPressed() {
        if playing { pausePlayers(); return }
        if let item = headVideo.player?.currentItem, item.currentTime() >= item.duration - CMTime(seconds: 0.1, preferredTimescale: 600) { seek(to: 0) }
        playTogether()
    }

    private func playTogether() {
        playing = true
        playButton.title = "Pause"
        // One start time on the host clock for both, so the two clips begin together.
        // setRate(_:time:atHostTime:) raises before the items are ready to play: until then, plain play().
        let ready = [baseVideo.player, headVideo.player].allSatisfy { $0 == nil || $0?.currentItem?.status == .readyToPlay }
        guard ready else { for p in [baseVideo.player, headVideo.player] { p?.play() }; return }
        let at = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 0.15, preferredTimescale: 1000))
        for p in [baseVideo.player, headVideo.player] { p?.setRate(1, time: .invalid, atHostTime: at) }
    }

    private func seek(to index: Int?) {
        guard let t = tour else { return }
        let hc = t.chapters(of: t.head), bc = t.chapters(of: t.base)
        func time(_ list: [Recorder.Chapter]) -> CMTime {
            guard let i = index, list.indices.contains(i) else { return .zero }
            return CMTime(seconds: max(0, list[i].t - 0.4), preferredTimescale: 600)
        }
        headVideo.player?.seek(to: time(hc), toleranceBefore: .zero, toleranceAfter: .zero)
        baseVideo.player?.seek(to: time(bc), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func chapterPressed(_ sender: NSButton) {
        seek(to: sender.tag)
        for b in chapterButtons { b.isOn = b === sender }
        playTogether()
    }

    // For checks.
    /// AppKit's own drawing of the glass (what a screenshot taken while the screen is locked has) is white: flat, it is dark.
    func flatForCapture(_ on: Bool) {
        if flatBacking.superview == nil {
            flatBacking.wantsLayer = true
            flatBacking.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
            pin(flatBacking, in: panel)
            panel.addSubview(flatBacking, positioned: .below, relativeTo: panel.subviews.first)
        }
        flatBacking.isHidden = !on
    }
    private let flatBacking = NSView()
    var summaryText: String { statusLabel.stringValue }
    var stateTitleText: String { stateCard.isHidden ? "" : stateTitle.stringValue }
    var stateDetailText: String { stateCard.isHidden ? "" : stateText.stringValue }
    var offerButtonTitles: [String] { stateButtons.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    var videoNoteText: String { videoNote.isHidden ? "" : videoNote.stringValue }
    var hasPlayers: Bool { headVideo.player != nil && baseVideo.player != nil }
    var summaryLines: [String] { allText(in: summaryStack) }

    private func allText(in view: NSView) -> [String] {
        var out: [String] = []
        for v in view.subviews {
            if let t = v as? NSTextField, !t.stringValue.isEmpty { out.append(t.stringValue) }
            out += allText(in: v)
        }
        return out
    }
}

extension SessionsController {
    /// The palette's entry: the current session's build against its base.
    func changesPaletteItems() -> [PaletteItem] {
        [PaletteItem(id: "session.changes", title: "Changes: what this session changed…", group: "Sessions", symbol: "plusminus.circle", shortcut: "⌘D",
                     keywords: "diff compare base branch pull request screens new changed gone tour") { [weak self] in
            guard let self, let s = self.currentSession else { self?.workbench?.toast.show("Add a repository first: Changes compares a session's build with a base", problem: true); return }
            self.workbench?.showChanges(of: s)
        }]
    }
}
