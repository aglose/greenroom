import AppKit
import UniformTypeIdentifiers

// The Build button, progress, log and Cancel of a session's row (docs/SESSIONS-PLAN.md, "2. Builds"). The queue is
// Builds.swift; SessionsController calls into this file in a few places (the row, the palette, the install).

extension Session {
    /// When this session's newest build was made: a Gradle output in the worktree or a build the store holds.
    var builtAt: Date? { [outputs?.date, build?.date].compactMap { $0 }.max() }
}

/// A button that runs a closure (the row's cells are rebuilt often; nothing needs to keep a target alive).
final class ClosureButton: NSButton {
    var handler: (() -> Void)?
    @objc private func fire() { handler?() }
    convenience init(symbol: String, tip: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tip
        target = self
        action = #selector(fire)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    convenience init(title: String, tip: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.handler = handler
        self.title = title
        isBordered = false
        toolTip = tip
        target = self
        action = #selector(fire)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }
}

final class ClosureMenuItem: NSMenuItem {
    var handler: (() -> Void)?
    @objc private func fire() { handler?() }
    convenience init(_ title: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
    }
}

extension SessionsController {
    // MARK: Install

    /// Wires the queue to the rows; called once from `install`.
    func installBuilds() {
        LoginEnvironment.warmUp()
        var lastRefresh = Date.distantPast
        buildQueue.onChange = { [weak self] in
            BuildLogPopover.current?.refresh()
            guard let self else { return }
            // A click waiting on a build that failed or was cancelled does not open on some later build.
            self.openWhenBuilt = self.openWhenBuilt.filter { self.buildQueue.jobs[$0]?.isActive ?? false }
            self.mainBuilds.jobsChanged()
            self.onChange?()
        }
        buildQueue.onLine = { [weak self] job, line in
            BuildLogPopover.current?.append(line, of: job)
            // The row shows the log's last line: redrawn at most twice a second.
            guard let self, Date().timeIntervalSince(lastRefresh) > 0.5 else { return }
            lastRefresh = Date()
            self.onChange?()
        }
    }

    // MARK: Actions

    /// The session "this session" means in the palette: the selected simulator's, else the one used last.
    var currentSession: Session? {
        if let sim = workbench?.selected, let s = session(forSimulator: sim) { return s }
        return used.first.flatMap { p in sessions.first { $0.worktree.path == p } } ?? sessions.first
    }

    func workspace(of session: Session) -> Workspace? { workspaces.first { $0.root.path == session.workspace.path } }

    /// Builds `session` with the recipe named (the workspace's default when nil).
    func build(_ session: Session, recipe: String? = nil) {
        guard let ws = workspace(of: session) else { return }
        let name = recipe ?? ws.defaultRecipeName
        // The remote recipe uploads source code: it runs only for a repository whose person said yes (RecipesUI.swift).
        if let why = ws.refusal(forRecipe: name) {
            if name == "remote" { askRemoteConsent(for: ws) { [weak self] in self?.build(session, recipe: name) } }
            else { workbench?.toast.show(why, problem: true) }
            return
        }
        if recipe != nil { ws.defaultRecipeName = name }
        buildQueue.start(session, workspace: ws, recipeName: name, store: store) { [weak self] why in
            self?.workbench?.toast.show(why, problem: true)
        }
    }

    func cancelBuild(_ session: Session) { buildQueue.cancel(session.worktree.path) }

    /// Opens a file chooser to link a local `.apk` on disk directly to `session` (and its PR, if any).
    func chooseLocalAPK(for session: Session) {
        guard let window = workbench?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        if let pr = session.prNumber {
            panel.message = "Choose a local APK to link to PR #\(pr) (\(session.title))"
        } else {
            panel.message = "Choose a local APK to link to \(session.title)"
        }
        panel.prompt = "Link APK"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if await self.linkLocalAPK(url, to: session, open: true) != nil {
                    let target = session.prNumber.map { "PR #\($0)" } ?? session.title
                    self.workbench?.toast.show("Linked \(url.lastPathComponent) to \(target)")
                } else {
                    self.workbench?.toast.show("Could not link \(url.lastPathComponent)", problem: true)
                }
            }
        }
    }

    /// "Custom...": any executable becomes the workspace's "custom" recipe and builds at once.
    func chooseCustomRecipe(for session: Session) {
        guard let window = workbench?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose the executable that builds an APK. It is told what to build through GREENROOM_* variables and writes the APK to GREENROOM_OUT."
        panel.prompt = "Use"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK, let url = panel.url else { return }
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                self.workbench?.toast.show("\(url.lastPathComponent) is not executable (chmod +x)", problem: true)
                return
            }
            guard let i = self.workspaces.firstIndex(where: { $0.root.path == session.workspace.path }) else { return }
            self.workspaces[i].recipes["custom"] = Recipe(executable: url.path)
            self.store.saveWorkspaces(self.workspaces)
            self.build(session, recipe: "custom")
        }
    }

    func showBuildLog(_ session: Session, from view: NSView?) {
        guard let job = buildQueue.job(for: session), let content = workbench?.window.contentView else {
            workbench?.toast.show("\(session.title) has not been built here yet")
            return
        }
        // Anchored to a fixed rectangle where the button was: the rows are redrawn while a build runs.
        var rect = NSRect(x: 0, y: content.bounds.height - 60, width: 1, height: 1)
        if let view { rect = content.convert(view.bounds, from: view) }
        BuildLogPopover.show(job: job, anchor: rect, in: content, onCancel: { [weak self] in self?.cancelBuild(session) })
    }

    // MARK: Row

    /// What the row shows of a build: a line under the title while one runs or has failed, and the buttons.
    func buildAccessories(for s: Session) -> (detail: String?, color: NSColor?, views: [NSView]) {
        let job = buildQueue.job(for: s)
        var views: [NSView] = []
        var detail: String?
        var color: NSColor?
        if let job, job.isActive {
            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .small
            spin.isIndeterminate = true
            spin.startAnimation(nil)
            spin.setContentHuggingPriority(.required, for: .horizontal)
            views.append(spin)
            views.append(ClosureButton(symbol: "xmark.circle", tip: "Cancel build (a Gradle daemon may finish its current task)") { [weak self] in self?.cancelBuild(s) })
            detail = job.state == .queued ? "build queued: another build of this repository is running" : "building: " + (job.lastLine ?? job.recipeName)
        } else {
            if let job, let why = job.failure {
                detail = "build failed: " + (why.split(separator: "\n").last.map(String.init) ?? why)
                color = .systemRed
            }
            views.append(ClosureButton(symbol: "hammer", tip: "Build with \(workspace(of: s)?.defaultRecipeName ?? "local")") { [weak self] in self?.build(s) })
        }
        if job != nil {
            let log = ClosureButton(symbol: "text.alignleft", tip: "Show the build log") {}
            log.handler = { [weak self, weak log] in self?.showBuildLog(s, from: log) }
            views.append(log)
        }
        return (detail, color, views)
    }

    /// The items the row's context menu gets: Build, Build with, Cancel, the log.
    func buildMenuItems(for s: Session) -> [NSMenuItem] {
        guard let ws = workspace(of: s) else { return [] }
        var items: [NSMenuItem] = []
        if let pr = s.githubPR, let url = pr.url {
            items.append(ClosureMenuItem("Open PR #\(pr.number)\(pr.isDraft ? " (Draft)" : "") on GitHub") { NSWorkspace.shared.open(url) })
            items.append(.separator())
        }
        let active = buildQueue.job(for: s)?.isActive ?? false
        if active {
            items.append(ClosureMenuItem("Cancel Build") { [weak self] in self?.cancelBuild(s) })
        } else {
            if let pr = s.prNumber, ws.hasPRFetchScript {
                items.append(ClosureMenuItem("Fetch PR #\(pr) APK (pr-script)") { [weak self] in self?.build(s, recipe: "pr-script") })
            }
            if !(ws.disableLocalBuilds && ws.defaultRecipeName == "local") {
                items.append(ClosureMenuItem("Build (\(ws.defaultRecipeName))") { [weak self] in self?.build(s) })
            }
            let linkTitle = s.prNumber.map { "Link Local APK to PR #\($0)…" } ?? "Link Local APK…"
            items.append(ClosureMenuItem(linkTitle) { [weak self] in self?.chooseLocalAPK(for: s) })
            let sub = NSMenu()
            for name in ws.recipeNames { sub.addItem(ClosureMenuItem(name) { [weak self] in self?.build(s, recipe: name) }) }
            if !ws.recipeNames.isEmpty { sub.addItem(.separator()) }
            sub.addItem(ClosureMenuItem("Custom…") { [weak self] in self?.chooseCustomRecipe(for: s) })
            sub.addItem(.separator())
            for item in recipeMenuItems(for: s, in: ws) { sub.addItem(item) }
            let with = NSMenuItem(title: "Build with", action: nil, keyEquivalent: "")
            with.submenu = sub
            items.append(with)
        }
        items.append(ClosureMenuItem("Changes…") { [weak self] in self?.workbench?.showChanges(of: s) })
        items.append(ClosureMenuItem("Add Pull Request…") { [weak self] in self?.pulls.askAndAdd() })
        if buildQueue.job(for: s) != nil {
            items.append(ClosureMenuItem("Show Build Log") { [weak self] in self?.showBuildLog(s, from: nil) })
        }
        return items
    }

    func buildPaletteItems() -> [PaletteItem] {
        [
            PaletteItem(id: "session.build", title: "Build this session", group: "Sessions", symbol: "hammer", keywords: "recipe gradle assemble compile pr-script") { [weak self] in
                guard let self else { return }
                if let s = self.currentSession { self.build(s) } else { self.workbench?.toast.show("No session to build: add a repository first", problem: true) }
            },
            PaletteItem(id: "session.build.cancel", title: "Cancel build", group: "Sessions", symbol: "xmark.circle", keywords: "stop recipe gradle") { [weak self] in
                guard let self else { return }
                if let s = self.currentSession, self.buildQueue.isBuilding(s.worktree.path) { self.cancelBuild(s) }
                else { self.workbench?.toast.show("Nothing is building") }
            },
            PaletteItem(id: "session.link.apk", title: "Link local APK to this session / PR…", group: "Sessions", symbol: "link", keywords: "apk pr artifactory local file attach") { [weak self] in
                guard let self else { return }
                if let s = self.currentSession { self.chooseLocalAPK(for: s) }
                else { self.workbench?.toast.show("No session selected: add a repository first", problem: true) }
            },
            PaletteItem(id: "session.stop.local.scan", title: "Stop local APK search for this repository", group: "Sessions", symbol: "stop.circle", keywords: "scan skip disable gradle artifactory") { [weak self] in
                guard let self else { return }
                if let s = self.currentSession { self.stopLocalSearch(for: s.workspace) }
                else if let first = self.workspaces.first { self.stopLocalSearch(for: first.root) }
                else { self.workbench?.toast.show("No repository added yet", problem: true) }
            },
        ]
    }
}

/// The log of a build in a popover: it follows the build while it runs, with its reason and a Cancel.
final class BuildLogPopover: NSViewController, NSPopoverDelegate {
    static weak var current: BuildLogPopover?
    private static var popover: NSPopover?
    private static let keepLines = 3000
    private var shown: [String] = []
    private var unflushed: [String] = []
    private var flushScheduled = false

    private let job: BuildJob
    private let text = NSTextView()
    private let header = NSTextField(labelWithString: "")
    private let onCancel: () -> Void

    init(job: BuildJob, onCancel: @escaping () -> Void) {
        self.job = job
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    static func show(job: BuildJob, anchor: NSRect, in view: NSView, onCancel: @escaping () -> Void) {
        popover?.close()
        let c = BuildLogPopover(job: job, onCancel: onCancel)
        let p = NSPopover()
        p.appearance = NSAppearance(named: .darkAqua)
        p.behavior = .transient
        p.delegate = c
        p.contentViewController = c
        p.show(relativeTo: anchor, of: view, preferredEdge: .maxX)
        popover = p
        current = c
    }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 340))
        v.wantsLayer = true
        v.appearance = NSAppearance(named: .darkAqua)
        v.layer?.backgroundColor = Design.stage.cgColor
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = Design.ink
        header.lineBreakMode = .byTruncatingTail
        header.maximumNumberOfLines = 2
        header.preferredMaxLayoutWidth = 420
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = Design.ink
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 10, height: 8)
        shown = Array(job.lines.suffix(Self.keepLines))
        text.string = shown.joined(separator: "\n")
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Design.stroke.cgColor
        let cancel = GlassButton(symbol: "xmark.circle", title: "Cancel", label: "Cancel build (a Gradle daemon may finish its current task)", style: .record, target: nil, action: nil)
        cancel.heightAnchor.constraint(equalToConstant: 24).isActive = true
        cancel.font = .systemFont(ofSize: 11, weight: .medium)
        cancel.onPress = { [weak self] in self?.onCancel() }
        let copy = GlassButton(symbol: "doc.on.doc", title: "Copy", label: "Copy the log", style: .well, target: nil, action: nil)
        copy.heightAnchor.constraint(equalToConstant: 24).isActive = true
        copy.font = .systemFont(ofSize: 11, weight: .medium)
        copy.onPress = { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self?.job.lines.joined(separator: "\n") ?? "", forType: .string)
        }
        for sub in [header, divider, scroll, cancel, copy] as [NSView] { sub.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(sub) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 12), header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(lessThanOrEqualTo: copy.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: header.centerYAnchor), cancel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            copy.centerYAnchor.constraint(equalTo: header.centerYAnchor), copy.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -6),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10), divider.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: v.trailingAnchor), divider.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        view = v
        refresh()
    }

    /// Lines are collected and drawn four times a second at most; the view keeps the last `keepLines`.
    func append(_ line: String, of other: BuildJob) {
        guard other === job, isViewLoaded else { return }
        unflushed.append(line)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard isViewLoaded, !unflushed.isEmpty else { return }
        let atEnd = (text.enclosingScrollView?.verticalScroller?.floatValue ?? 1) > 0.98
        let added = unflushed
        shown.append(contentsOf: added)
        unflushed = []
        let cut = shown.count > Self.keepLines
        if cut { shown.removeFirst(shown.count - Self.keepLines) }
        if cut {
            text.string = shown.joined(separator: "\n")
        } else {
            text.textStorage?.append(NSAttributedString(string: (text.string.isEmpty ? "" : "\n") + added.joined(separator: "\n"),
                                                        attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Design.ink]))
        }
        if atEnd { text.scrollToEndOfDocument(nil) }
        refresh()
    }

    func popoverDidClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
        Self.popover = nil
    }

    func refresh() {
        switch job.state {
        case .queued: header.stringValue = "\(job.recipeName): queued behind another build of this repository"
        case .running: header.stringValue = "\(job.recipeName): building \(job.title)…"
        case .built(let b): header.stringValue = "\(job.recipeName): built \(b.key)"
        case .cancelled: header.stringValue = "\(job.recipeName): cancelled"
        case .failed(let why): header.stringValue = "\(job.recipeName): failed. " + why
        }
    }
}
