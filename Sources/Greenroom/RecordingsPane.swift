import AppKit
import UniformTypeIdentifiers

/// Saved recordings: open, reveal, delete, replay on a build, and find the first build that replays differently.
/// Floats over the stage on glass, in the right slot beside the Device and Network panes.
final class RecordingsPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let glass = GlassView(radius: 18)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let count = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let selectedName = NSTextField(labelWithString: "")
    private let selectedMeta = NSTextField(labelWithString: "")
    private var actionButtons: [String: GlassButton] = [:]

    private let headline = NSTextField(labelWithString: "Nothing replayed yet")
    private let stopButton = GlassButton(symbol: "stop.fill", title: "Stop", label: "Stop the replay and end the search", style: .record, target: nil, action: nil)
    private var tabButtons: [GlassButton] = []
    private let resultText = NSTextView()
    private let logText = NSTextView()
    private let resultScroll = NSScrollView()
    private let logScroll = NSScrollView()
    private let frames = NSStackView()
    private var frameImages: [NSImageView] = []
    private var frameHeight: NSLayoutConstraint!
    private var tab = 0   // Result, Log

    // The builds to search, in the order they are tried: oldest first.
    private let buildsCard = NSView()
    private let buildsTable = NSTableView()
    private let buildsTitle = NSTextField(wrappingLabelWithString: "")
    private var builds: [URL] = []
    private var buildsFor: Recording?
    private var buildButtons: [String: GlassButton] = [:]

    private let store = RecordingStore()
    private(set) var recordings: [Recording] = []
    private var folder: URL?
    /// Said to the person in the workbench's toast.
    var onSay: ((String, Bool) -> Void)?
    var onOpenTrace: ((URL) -> Void)?

    // What is running or was last run.
    private struct Step {
        enum State { case pending, running, done(ReplayOutcome) }
        var name: String
        var state: State
        var folder: URL?
    }
    private var steps: [Step] = []
    private var conclusion = ""
    private var conclusionColor = Design.mute
    private let log = LockedText()
    private(set) var busy = false
    private var stopRequested = false
    private var redrawQueued = false

    private var selectedRecording: Recording? {
        table.selectedRow >= 0 && table.selectedRow < recordings.count ? recordings[table.selectedRow] : nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        let title = NSTextField(labelWithString: "Recordings")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Design.ink
        count.font = .systemFont(ofSize: 12)
        count.textColor = Design.mute
        let folderButton = GlassButton(symbol: "folder", label: "Show the recordings folder in Finder", target: self, action: #selector(showFolder(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [title, count, spacer, folderButton])
        top.spacing = 6

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recording"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 50
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Recordings")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = Design.mute
        empty.alignment = .center
        empty.stringValue = "No recordings yet. Press Record, use the app, then save the recording (⇧⌘S): it shows up here, ready to replay."

        // The chosen recording and what can be done to it.
        let card = Self.card()
        selectedName.font = .systemFont(ofSize: 13, weight: .semibold)
        selectedName.textColor = Design.ink
        selectedName.lineBreakMode = .byTruncatingMiddle
        selectedMeta.font = .systemFont(ofSize: 11)
        selectedMeta.textColor = Design.mute
        selectedMeta.lineBreakMode = .byTruncatingMiddle
        func button(_ id: String, _ symbol: String, _ title: String, _ label: String, _ action: Selector) -> GlassButton {
            let b = GlassButton(symbol: symbol, title: title, label: label, style: .well, target: self, action: action)
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.heightAnchor.constraint(equalToConstant: 28).isActive = true
            actionButtons[id] = b
            return b
        }
        let row1 = NSStackView(views: [
            button("replay", "play.fill", "Replay on build…", "Replay this recording on a build you choose", #selector(replayPicked(_:))),
            button("recorded", "arrow.counterclockwise", "On the recorded build", "Replay on the build it was recorded from", #selector(replayRecorded(_:))),
]) 
        let row1b = NSStackView(views: [
            button("bisect", "arrow.triangle.branch", "Find the first build that differs…", "Replay on several builds and find the first that differs", #selector(bisectPicked(_:))),
        ])
        let row2 = NSStackView(views: [
            button("trace", "waveform.path.ecg", "Trace viewer", "Open in the trace viewer", #selector(openTrace(_:))),
            button("reveal", "magnifyingglass", "Reveal in Finder", "Reveal in Finder", #selector(reveal(_:))),
            button("delete", "trash", "Delete…", "Move to the Trash", #selector(deletePicked(_:))),
        ])
        for r in [row1, row1b, row2] { r.spacing = 6; r.distribution = .fillProportionally }
        let rows = NSStackView(views: [selectedName, selectedMeta, row1, row1b, row2])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        rows.setCustomSpacing(10, after: selectedMeta)
        rows.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(rows)

        // The result of the last replay or search, and the engine's output.
        let result = Self.card()
        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        headline.textColor = Design.mute
        headline.lineBreakMode = .byTruncatingTail
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stopButton.onPress = { [weak self] in self?.stop() }
        stopButton.isHidden = true
        tabButtons = ["Result", "Log"].enumerated().map { i, name in
            let b = GlassButton(symbol: nil, title: name, label: name, target: self, action: #selector(tabPicked(_:)))
            b.tag = i
            return b
        }
        let tabs = NSStackView(views: tabButtons)
        tabs.spacing = 2
        let resultHead = NSStackView(views: [headline, NSView(), stopButton, tabs])
        resultHead.spacing = 8
        for (t, s) in [(resultText, resultScroll), (logText, logScroll)] {
            t.isEditable = false
            t.isRichText = true
            t.drawsBackground = false
            t.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
            t.textColor = Design.ink
            t.textContainerInset = NSSize(width: 4, height: 6)
            t.autoresizingMask = [.width]
            t.isVerticallyResizable = true
            t.textContainer?.widthTracksTextView = true
            s.documentView = t
            s.drawsBackground = false
            s.hasVerticalScroller = true
            s.autohidesScrollers = true
            s.translatesAutoresizingMaskIntoConstraints = false
            result.addSubview(s)
        }
        logScroll.isHidden = true
        frames.orientation = .horizontal
        frames.distribution = .fillEqually
        frames.spacing = 8
        for name in ["Recorded", "Replayed", "Difference"] {
            let img = NSImageView()
            img.imageScaling = .scaleProportionallyUpOrDown
            img.wantsLayer = true
            img.layer?.cornerRadius = 6
            img.layer?.masksToBounds = true
            img.layer?.borderWidth = 1
            img.layer?.borderColor = Design.stroke.cgColor
            img.setAccessibilityLabel(name)
            let cap = NSTextField(labelWithString: name)
            cap.font = .systemFont(ofSize: 10.5, weight: .medium)
            cap.textColor = name == "Difference" ? Design.difference : Design.mute
            cap.alignment = .center
            let col = NSStackView(views: [img, cap])
            col.orientation = .vertical
            col.spacing = 3
            frameImages.append(img)
            frames.addArrangedSubview(col)
        }
        frames.isHidden = true
        for v in [resultHead, frames] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; result.addSubview(v) }
        frameHeight = frames.heightAnchor.constraint(equalToConstant: 0)

        configureBuildsCard()
        buildsCard.isHidden = true

        for v in [top, scroll, empty, card, result, buildsCard] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.30),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
            card.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rows.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            result.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 8),
            result.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            result.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            result.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            resultHead.topAnchor.constraint(equalTo: result.topAnchor, constant: 10),
            resultHead.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: 14),
            resultHead.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -8),
            frames.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: 12),
            frames.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -12),
            frames.bottomAnchor.constraint(equalTo: result.bottomAnchor, constant: -10),
            frameHeight,
            buildsCard.topAnchor.constraint(equalTo: result.topAnchor), buildsCard.bottomAnchor.constraint(equalTo: result.bottomAnchor),
            buildsCard.leadingAnchor.constraint(equalTo: result.leadingAnchor), buildsCard.trailingAnchor.constraint(equalTo: result.trailingAnchor),
        ])
        for s in [resultScroll, logScroll] {
            NSLayoutConstraint.activate([
                s.topAnchor.constraint(equalTo: resultHead.bottomAnchor, constant: 6),
                s.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: 8),
                s.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -6),
                s.bottomAnchor.constraint(equalTo: frames.topAnchor, constant: -6),
            ])
        }
        refreshButtons()
        renderResult()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func card() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 0, alpha: 0.3).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Design.stroke.cgColor
        return card
    }

    // MARK: The list

    /// Shown or hidden by the workbench. The folder is read when it is shown and when a recording is saved, never
    /// while hidden.
    func setShown(_ on: Bool, folder: URL) {
        self.folder = folder
        if on { refresh() }
    }

    func refresh(select file: URL? = nil, done: (() -> Void)? = nil) {
        guard let folder else { return }
        store.load(from: folder) { [weak self] list in
            guard let self else { return }
            let keep = file ?? self.selectedRecording?.url
            self.recordings = list
            self.count.stringValue = list.isEmpty ? "" : "\(list.count)"
            self.empty.isHidden = !list.isEmpty
            self.table.reloadData()
            if let keep, let i = list.firstIndex(where: { $0.url == keep }) { self.table.selectRowIndexes([i], byExtendingSelection: false) }
            else if !list.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false) }
            self.refreshButtons()
            done?()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === buildsTable ? builds.count : recordings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === buildsTable {
            guard row < builds.count else { return nil }
            let u = builds[row]
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Self.shortDate.string(from: $0) } ?? ""
            return Self.cell("buildCell", title: "\(row + 1).  \(u.lastPathComponent)", subtitle: date + (row == 0 ? "  ·  oldest: assumed good" : ""), in: tableView, compact: true)
        }
        guard row < recordings.count else { return nil }
        let r = recordings[row]
        return Self.cell("recordingCell", title: r.name, subtitle: r.meta + (r.package.map { "  ·  " + $0 } ?? ""), in: tableView, compact: false)
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static func cell(_ id: String, title: String, subtitle: String, in table: NSTableView, compact: Bool) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        let cell = table.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = identifier
            let t = NSTextField(labelWithString: "")
            t.font = .systemFont(ofSize: 13, weight: .medium)
            t.textColor = Design.ink
            t.lineBreakMode = .byTruncatingMiddle
            let s = NSTextField(labelWithString: "")
            s.font = .systemFont(ofSize: 11)
            s.textColor = Design.mute
            s.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: [t, s])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(stack)
            c.textField = t
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -10),
                stack.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = title
        ((cell.textField?.superview as? NSStackView)?.views.last as? NSTextField)?.stringValue = subtitle
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === buildsTable { refreshBuildButtons(); return }
        refreshButtons()
    }

    private func refreshButtons() {
        let r = selectedRecording
        selectedName.stringValue = r?.name ?? "No recording chosen"
        selectedMeta.stringValue = r.map { rec in
            (rec.apkName.map { "Recorded on \($0)" } ?? "Recorded build unknown") + (rec.apkPath == nil ? "" : "  ·  build file found")
        } ?? ""
        for (id, b) in actionButtons {
            switch id {
            case "recorded": b.isEnabled = r?.apkPath != nil && !busy
            case "trace", "reveal": b.isEnabled = r != nil
            default: b.isEnabled = r != nil && !busy
            }
        }
        for (i, b) in tabButtons.enumerated() { b.isOn = i == tab }
        stopButton.isHidden = !busy
    }

    // MARK: Actions on a recording

    @objc private func showFolder(_ sender: Any?) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(folder)
    }

    @objc private func openTrace(_ sender: Any?) { if let r = selectedRecording { onOpenTrace?(r.url) } }

    @objc private func reveal(_ sender: Any?) { if let r = selectedRecording { NSWorkspace.shared.activateFileViewerSelecting([r.url]) } }

    @objc private func deletePicked(_ sender: Any?) {
        guard let r = selectedRecording, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(r.name)” to the Trash?"
        alert.informativeText = "The recording leaves this list. You can put it back from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.trash(r)
        }
    }

    /// Moves the recording to the Trash (no confirmation: the caller asked).
    func trash(_ r: Recording) {
        do {
            try FileManager.default.trashItem(at: r.url, resultingItemURL: nil)
            onSay?("Moved \(r.name) to the Trash", false)
            refresh()
        } catch {
            onSay?("Could not move it to the Trash: \(error.localizedDescription)", true)
        }
    }

    @objc private func replayPicked(_ sender: Any?) { promptReplay() }

    /// Asks for a build (the chosen recording's, or the newest's) and replays on it.
    func promptReplay() {
        guard let r = selectedRecording ?? recordings.first else { onSay?("There is no recording to replay yet", true); return }
        let panel = NSOpenPanel()
        panel.message = "Choose the build to replay “\(r.name)” on"
        panel.prompt = "Replay"
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        if let recorded = r.apkPath { panel.directoryURL = recorded.deletingLastPathComponent(); panel.nameFieldStringValue = recorded.lastPathComponent }
        let go: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let apk = panel.url else { return }
            self?.replay(r, apk: apk)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: go) } else { go(panel.runModal()) }
    }

    @objc private func replayRecorded(_ sender: Any?) {
        guard let r = selectedRecording, let apk = r.apkPath else { return }
        replay(r, apk: apk)
    }

    @objc private func tabPicked(_ sender: GlassButton) {
        tab = sender.tag
        resultScroll.isHidden = tab != 0
        logScroll.isHidden = tab != 1
        refreshButtons()
    }

    // MARK: Replay

    /// Replays `recording` on `apk` (nil: the build the engine finds for it). Results show in the pane.
    func replay(_ recording: Recording, apk: URL?, completion: ((ReplayOutcome) -> Void)? = nil) {
        guard !busy else { onSay?("A replay is already running: stop it first", true); return }
        beginSession()
        let name = apk?.lastPathComponent ?? recording.apkName ?? "the recorded build"
        steps = [Step(name: name, state: .running)]
        setHeadline("Replaying on \(name)…", Design.ink)
        runOne(recording, apk: apk, label: name) { [weak self] outcome, out in
            guard let self else { return }
            self.steps[0].state = .done(outcome)
            self.steps[0].folder = out
            self.finishSession(headline: self.headlineFor(outcome, on: name), color: Self.color(outcome))
            if case .diverged(let d) = outcome { self.showFrames(d) }
            completion?(outcome)
        }
    }

    private func runOne(_ rec: Recording, apk: URL?, label: String, done: @escaping (ReplayOutcome, URL) -> Void) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let out = Engine.shared.engineState.appendingPathComponent("replays", isDirectory: true)
            .appendingPathComponent("\(rec.name)-\(stamp.string(from: Date()))", isDirectory: true)
        appendLog("\n=== replay \(rec.name) on \(label)\n")
        let job = ReplayJob(bundle: rec.url, apk: apk, out: out)
        ReplayRunner.shared.submit(job, token: ReplayRunner.shared.token, output: { [weak self] text in
            self?.log.append(text)
            self?.queueRedraw()
        }, completion: { [weak self] run in
            let outcome = ReplayRunner.interpret(run, out: out)
            self?.appendLog("=== \(outcome.word): \(outcome.detail) (\(String(format: "%.1f", run.seconds)) s)\n")
            done(outcome, out)
        })
    }

    private func appendLog(_ s: String) { log.append(s); queueRedraw() }

    // MARK: Bisect

    @objc private func bisectPicked(_ sender: Any?) { promptBisect() }

    /// Asks for builds (a folder of APKs, or several APKs) and shows them in the order they will be tried.
    func promptBisect() {
        guard !busy else { onSay?("A replay is already running: stop it first", true); return }
        guard let r = selectedRecording ?? recordings.first else { onSay?("There is no recording to search with yet", true); return }
        let panel = NSOpenPanel()
        panel.message = "Choose a folder of builds, or several APKs, to search for the first that replays “\(r.name)” differently"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let recorded = r.apkPath { panel.directoryURL = recorded.deletingLastPathComponent() }
        let go: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            let found = BuildOrder.apks(in: panel.urls)
            guard found.count >= 2 else { self?.onSay?("Choose at least two APKs, or a folder with two", true); return }
            self?.editBuilds(for: r, builds: found)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: go) } else { go(panel.runModal()) }
    }

    private func configureBuildsCard() {
        let card = buildsCard
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.095, blue: 0.11, alpha: 0.97).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Design.stroke.cgColor
        buildsTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        buildsTitle.textColor = Design.ink
        buildsTitle.maximumNumberOfLines = 3
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("build"))
        c.resizingMask = .autoresizingMask
        buildsTable.addTableColumn(c)
        buildsTable.headerView = nil
        buildsTable.backgroundColor = .clear
        buildsTable.style = .plain
        buildsTable.rowHeight = 38
        buildsTable.dataSource = self
        buildsTable.delegate = self
        buildsTable.setAccessibilityLabel("Builds, oldest first")
        let s = NSScrollView()
        s.documentView = buildsTable
        s.drawsBackground = false
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        func b(_ id: String, _ symbol: String?, _ title: String, _ label: String, _ style: GlassButton.Style = .well, _ action: @escaping () -> Void) -> GlassButton {
            let g = GlassButton(symbol: symbol, title: title, label: label, style: style, target: nil, action: nil)
            g.font = .systemFont(ofSize: 12, weight: .medium)
            g.heightAnchor.constraint(equalToConstant: 28).isActive = true
            g.onPress = action
            buildButtons[id] = g
            return g
        }
        let order = NSStackView(views: [
            b("up", "arrow.up", "", "Move the build earlier") { [weak self] in self?.moveBuild(-1) },
            b("down", "arrow.down", "", "Move the build later") { [weak self] in self?.moveBuild(1) },
            b("remove", "minus", "", "Leave the build out") { [weak self] in self?.removeBuild() },
            b("add", "plus", "Add…", "Add more APKs") { [weak self] in self?.addBuilds() },
            b("name", nil, "Sort by name", "Order by file name") { [weak self] in self?.sortBuilds(byName: true) },
            b("date", nil, "Sort by date", "Order by modification time") { [weak self] in self?.sortBuilds(byName: false) },
        ])
        order.spacing = 4
        let go = NSStackView(views: [
            b("cancel", nil, "Cancel", "Close without searching") { [weak self] in self?.buildsCard.isHidden = true },
            NSView(),
            b("start", "arrow.triangle.branch", "Find the first that differs", "Replay on these builds and find the first that differs", .accent) { [weak self] in self?.startBisectFromCard() },
        ])
        go.spacing = 6
        for v in [buildsTitle, s, order, go] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(v) }
        NSLayoutConstraint.activate([
            buildsTitle.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            buildsTitle.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            buildsTitle.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            s.topAnchor.constraint(equalTo: buildsTitle.bottomAnchor, constant: 8),
            s.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            s.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            s.bottomAnchor.constraint(equalTo: order.topAnchor, constant: -8),
            order.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            order.bottomAnchor.constraint(equalTo: go.topAnchor, constant: -8),
            go.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            go.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            go.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }

    func editBuilds(for recording: Recording, builds list: [URL]) {
        builds = list
        buildsFor = recording
        buildsTitle.stringValue = "Builds to search for “\(recording.name)”, oldest first. The first is replayed to confirm it matches; the search then narrows down."
        buildsTable.reloadData()
        if !builds.isEmpty { buildsTable.selectRowIndexes([0], byExtendingSelection: false) }
        refreshBuildButtons()
        buildsCard.isHidden = false
        buildsCard.alphaValue = 0
        Design.animate(Design.arrive, { self.buildsCard.animator().alphaValue = 1 })
    }

    private func refreshBuildButtons() {
        let i = buildsTable.selectedRow
        buildButtons["up"]?.isEnabled = i > 0
        buildButtons["down"]?.isEnabled = i >= 0 && i < builds.count - 1
        buildButtons["remove"]?.isEnabled = i >= 0 && builds.count > 2
        buildButtons["start"]?.isEnabled = builds.count >= 2
    }

    private func moveBuild(_ delta: Int) {
        let i = buildsTable.selectedRow, j = i + delta
        guard i >= 0, builds.indices.contains(j) else { return }
        builds.swapAt(i, j)
        buildsTable.reloadData()
        buildsTable.selectRowIndexes([j], byExtendingSelection: false)
    }

    private func removeBuild() {
        let i = buildsTable.selectedRow
        guard i >= 0, builds.count > 2 else { return }
        builds.remove(at: i)
        buildsTable.reloadData()
        buildsTable.selectRowIndexes([min(i, builds.count - 1)], byExtendingSelection: false)
    }

    private func sortBuilds(byName: Bool) {
        builds = byName ? builds.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } : BuildOrder.sorted(builds)
        buildsTable.reloadData()
        refreshBuildButtons()
    }

    private func addBuilds() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let have = Set(builds.map(\.path))
        builds = BuildOrder.sorted(builds + BuildOrder.apks(in: panel.urls).filter { !have.contains($0.path) })
        buildsTable.reloadData()
        refreshBuildButtons()
    }

    private func startBisectFromCard() {
        guard let r = buildsFor, builds.count >= 2 else { return }
        buildsCard.isHidden = true
        bisect(r, builds: builds)
    }

    /// Replays `recording` on `builds` (oldest first), one at a time, narrowing down to the first that differs.
    func bisect(_ recording: Recording, builds list: [URL], completion: ((Bisect.Conclusion?) -> Void)? = nil) {
        guard !busy else { onSay?("A replay is already running: stop it first", true); return }
        beginSession()
        steps = []
        var state = Bisect(count: list.count)
        var replays = 0
        appendLog("# searching \(list.count) builds for the first that replays \(recording.name) differently\n")
        func conclude(_ c: Bisect.Conclusion?) {
            let (text, color) = Self.words(for: c, builds: list, stopped: stopRequested, replays: replays)
            finishSession(headline: text, color: color)
            if let c, case .firstDifferent(let i, _, _) = c, let step = steps.first(where: { $0.name == list[i].lastPathComponent }),
               case .done(.diverged(let d)) = step.state { showFrames(d) }
            completion?(c)
        }
        func step() {
            if stopRequested { conclude(nil); return }
            guard let i = state.next else { conclude(state.conclusion); return }
            let name = list[i].lastPathComponent
            steps.append(Step(name: name, state: .running))
            let n = steps.count - 1
            setHeadline("Replaying \(name)  (\(replays + 1), about \(replays + max(1, state.stepsLeftEstimate)) in all)…", Design.ink)
            runOne(recording, apk: list[i], label: name) { [weak self] outcome, out in
                guard let self else { return }
                replays += 1
                self.steps[n].state = .done(outcome)
                self.steps[n].folder = out
                switch outcome {
                case .same: state.record(i, .good)
                case .diverged, .crashed: state.record(i, .bad)
                case .cannot: state.record(i, .skip)
                case .failed:
                    // Stopped or timed out: a build that hangs is skipped, a stop ends the search.
                    if self.stopRequested { conclude(nil); return }
                    state.record(i, .skip)
                }
                self.queueRedraw()
                step()
            }
        }
        step()
    }

    /// The search's answer as words and colour.
    private static func words(for c: Bisect.Conclusion?, builds: [URL], stopped: Bool, replays: Int) -> (String, NSColor) {
        func n(_ i: Int) -> String { builds[i].lastPathComponent }
        guard let c else { return ("Stopped after \(replays) replay\(replays == 1 ? "" : "s"); no answer", Design.warning) }
        switch c {
        case .firstDifferent(let i, let good, _):
            return ("First different: \(n(i))  (previous \(n(good)) same)", Design.difference)
        case .candidates(let good, let bad, let skipped):
            return ("The change is in \(skipped.map(n).joined(separator: ", ")) or \(n(bad)): \(skipped.count == 1 ? "it" : "they") could not be replayed (after \(n(good)), same)", Design.warning)
        case .oldestDiffers: return ("\(n(0)), the oldest build, already differs: nothing to compare against", Design.warning)
        case .oldestUnreplayable: return ("\(n(0)), the oldest build, cannot be replayed: the search needs a good start", Design.warning)
        case .newestUnreplayable: return ("\(n(builds.count - 1)), the newest build, cannot be replayed", Design.warning)
        case .noneDiffers: return ("No build differs: \(n(builds.count - 1)) replays the same as \(n(0))", Design.accent)
        }
    }

    // MARK: Session state and drawing

    private func beginSession() {
        busy = true
        stopRequested = false
        conclusion = ""
        steps = []
        log.reset()
        frames.isHidden = true
        frameHeight.constant = 0
        refreshButtons()
        renderResult()
    }

    private func finishSession(headline text: String, color: NSColor) {
        busy = false
        setHeadline(text, color)
        conclusion = text
        conclusionColor = color
        refreshButtons()
        renderResult()
        renderLog()
    }

    func stop() {
        guard busy else { return }
        stopRequested = true
        setHeadline("Stopping…", Design.warning)
        ReplayRunner.shared.cancelAll()
    }

    private func setHeadline(_ text: String, _ color: NSColor) {
        headline.stringValue = text
        headline.textColor = color
        queueRedraw()
    }

    private func headlineFor(_ o: ReplayOutcome, on name: String) -> String {
        switch o {
        case .same: return "Same: \(name) replays as recorded"
        case .diverged(let d): return "Diverged at \(d.label) (+\(d.offsetMs) ms)"
        case .crashed: return "Crashed on \(name)"
        case .cannot: return "Cannot replay on \(name)"
        case .failed(let why): return "Failed: \(why)"
        }
    }

    private static func color(_ o: ReplayOutcome) -> NSColor {
        switch o {
        case .same: return Design.accent
        case .diverged: return Design.difference
        case .crashed: return Design.record
        case .cannot, .failed: return Design.warning
        }
    }

    /// Redraws the text at most four times a second while output streams in.
    private func queueRedraw() {
        DispatchQueue.main.async { [self] in
            guard !redrawQueued else { return }
            redrawQueued = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                redrawQueued = false
                renderResult()
                renderLog()
            }
        }
    }

    private func renderResult() {
        let out = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)
        func add(_ s: String, _ c: NSColor, _ f: NSFont? = nil) { out.append(NSAttributedString(string: s, attributes: [.foregroundColor: c, .font: f ?? mono])) }
        if steps.isEmpty && !busy {
            add("Replay a recording on a build to see whether the app still does what it did, or search a folder of builds for the first one that does not.\n", Design.mute)
        }
        for (i, s) in steps.enumerated() {
            add(String(format: "%2d  ", i + 1), Design.mute)
            add(s.name + "\n", Design.ink, bold)
            switch s.state {
            case .pending: add("    waiting\n", Design.mute)
            case .running: add("    replaying…\n", Design.mute)
            case .done(let o):
                add("    " + Self.symbol(o) + " " + o.word, Self.color(o), bold)
                add(o.detail.isEmpty || o.word == o.detail ? "\n" : "\n    " + o.detail + "\n", Design.mute)
            }
        }
        if !conclusion.isEmpty { add("\n" + conclusion + "\n", conclusionColor, bold) }
        resultText.textStorage?.setAttributedString(out)
    }

    private static func symbol(_ o: ReplayOutcome) -> String {
        switch o { case .same: return "✓"; case .diverged: return "≠"; case .crashed: return "✕"; case .cannot: return "–"; case .failed: return "!" }
    }

    private func renderLog() {
        let atEnd = logScroll.contentView.bounds.maxY >= logText.frame.maxY - 30
        logText.string = log.text.isEmpty ? "The engine's output shows here while a replay runs." : log.text
        if atEnd { logText.scrollToEndOfDocument(nil) }
    }

    /// The recorded frame, the replayed one and the difference map at the point that diverged, from the engine's report.
    private func showFrames(_ d: ReplayOutcome.Divergence) {
        DispatchQueue.global(qos: .userInitiated).async {
            let points = d.folder.appendingPathComponent("points", isDirectory: true)
            func image(_ kind: String, _ ext: String) -> NSImage? {
                for n in [String(format: "%02d", d.point), String(d.point)] {
                    let u = points.appendingPathComponent("\(n)-\(kind).\(ext)")
                    if let i = NSImage(contentsOf: u) { return i }
                }
                return nil
            }
            let found = [image("recorded", "jpg"), image("replayed", "jpg"), image("diff", "png")]
            DispatchQueue.main.async { [self] in
                guard found.contains(where: { $0 != nil }) else { return }
                for (v, i) in zip(frameImages, found) { v.image = i }
                frames.isHidden = false
                frameHeight.constant = 160
                layoutSubtreeIfNeeded()
            }
        }
    }

    // MARK: Scripted checks

    /// The result text as shown (for scripted checks).
    var resultSummary: String { headline.stringValue }
    var framesShown: Bool { !frames.isHidden && frameImages.contains { $0.image != nil } }
    /// Chooses the recording as a click on its row would.
    func debugSelect(_ file: URL) { if let i = recordings.firstIndex(where: { $0.url == file }) { table.selectRowIndexes([i], byExtendingSelection: false) } }
}
