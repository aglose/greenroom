import AppKit

/// The job queue in the top bar: how many jobs run and wait, whichever session is on the stage. A click opens the
/// list (`JobsPopover`). It is there while the queue has anything to show, a finished job included.
final class JobsChip: NSView {
    weak var workbench: Workbench?
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dot = CALayer()
    private var observer: NSObjectProtocol?
    /// Jobs that failed after this have not been looked at: the chip says so until the list is opened.
    private var seen = Date()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Design.well.cgColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        icon.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = Design.mute
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = Design.ink
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let row = NSStackView(views: [spinner, icon, label])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        dot.backgroundColor = Design.record.cgColor
        dot.cornerRadius = 3
        dot.isHidden = true
        layer?.addSublayer(dot)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: GlassButtonCell.iconOnly.height),
            widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
        observer = NotificationCenter.default.addObserver(forName: JobQueue.changed, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// "Build fix-login", "2 running · 1 waiting", "Jobs": what the chip says for a queue.
    static func words(running: [QueueJob], waiting: [QueueJob]) -> String {
        if running.count == 1, waiting.isEmpty { return running[0].title }
        let counts = counts(running: running.count, waiting: waiting)
        return counts.isEmpty ? "Jobs" : counts
    }

    /// "2 running · 1 waiting · 1 paused".
    static func counts(running: Int, waiting: [QueueJob]) -> String {
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        let paused = waiting.filter(\.isPaused).count
        if waiting.count > paused { parts.append("\(waiting.count - paused) waiting") }
        if paused > 0 { parts.append("\(paused) paused") }
        return parts.joined(separator: " · ")
    }

    func refresh() {
        let q = JobQueue.shared
        let running = q.running, waiting = q.waiting
        isHidden = q.jobs.isEmpty
        if running.isEmpty { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        icon.isHidden = !running.isEmpty
        label.stringValue = Self.words(running: running, waiting: waiting)
        let failed = q.recent.filter { $0.failure != nil && ($0.ended ?? .distantPast) > seen }.count
        dot.isHidden = failed == 0
        var tip = (running + waiting).prefix(8).map { "\($0.title): \($0.statusLine)" }
        if failed > 0 { tip.append("\(failed) job\(failed == 1 ? "" : "s") failed") }
        toolTip = (tip.isEmpty ? "Nothing is running." : tip.joined(separator: "\n")) + "\nClick for the job queue."
        setAccessibilityLabel("Job queue: " + label.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: bounds.width - 9, y: bounds.height - 9, width: 6, height: 6)
        CATransaction.commit()
    }

    func open() {
        seen = Date()
        refresh()
        JobsPopover.toggle(from: self, workbench: workbench)
    }

    override func mouseDown(with event: NSEvent) { layer?.backgroundColor = Design.wellOn.cgColor }
    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = Design.well.cgColor
        if bounds.contains(convert(event.locationInWindow, from: nil)) { open() }
    }
    override func accessibilityPerformPress() -> Bool { open(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// How far a job has got: a thin track and its filled share, in the colours of the top bar's walk chip.
private final class JobBar: NSView {
    private let fill = CALayer()
    var fraction: Double = 0 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer?.cornerRadius = 1.5
        layer?.masksToBounds = true
        fill.backgroundColor = Design.accent.cgColor
        layer?.addSublayer(fill)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 3).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * min(1, max(0, fraction)), height: bounds.height)
        CATransaction.commit()
    }
}

/// One job in the list: what it is, how it goes, and the buttons that act on it.
private final class JobRow: NSView {
    let job: QueueJob
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let bar = JobBar()
    var onReveal: (() -> Void)?

    init(job: QueueJob, buttons: [NSView], reveal: (() -> Void)?) {
        self.job = job
        self.onReveal = reveal
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor

        let icon = NSImageView(image: NSImage(systemSymbolName: job.kind.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        switch job.state {
        case .running: icon.contentTintColor = Design.accent
        case .failed: icon.contentTintColor = Design.record
        case .paused: icon.contentTintColor = Design.warning
        case .queued: icon.contentTintColor = job.held ? Design.warning : Design.mute
        default: icon.contentTintColor = Design.mute
        }

        title.stringValue = job.title
        title.font = .systemFont(ofSize: 12.5, weight: .medium)
        title.textColor = job.isActive ? Design.ink : Design.mute
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        time.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        time.textColor = Design.mute
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [icon, title, spacer, time] + buttons)
        top.spacing = 6
        top.alignment = .centerY

        status.font = .systemFont(ofSize: 10.5)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        let column = NSStackView(views: [top, status, bar])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 7), column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            top.widthAnchor.constraint(equalTo: column.widthAnchor),
            status.widthAnchor.constraint(equalTo: column.widthAnchor),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        if reveal != nil { title.toolTip = "Click to show it" }
        update()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// What moves while the row stays: its line, its clock and its bar.
    func update() {
        status.stringValue = job.statusLine
        status.toolTip = job.failure ?? job.statusLine
        status.textColor = job.failure != nil ? Design.record : .secondaryLabelColor
        switch job.state {
        case .queued: time.stringValue = ""
        default: time.stringValue = job.elapsed.map(Self.clock) ?? ""
        }
        let fraction = job.state == .running || job.state == .paused ? job.fraction : nil
        bar.isHidden = fraction == nil
        bar.fraction = fraction ?? 0
    }

    override func mouseUp(with event: NSEvent) {
        guard let onReveal, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onReveal()
    }
}

private final class JobsFlipped: NSView { override var isFlipped: Bool { true } }

/// The job queue's list: what runs, what waits in the order it will run, and what ended lately, for every session at
/// once. Each row cancels, pauses or resumes its job, or moves it to the front; the footer sets how many run at once.
final class JobsPopover: NSViewController, NSPopoverDelegate {
    private static var popover: NSPopover?
    private weak var workbench: Workbench?
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let summary = NSTextField(labelWithString: "")
    private let limit = NSPopUpButton()
    private let pauseAll = NSButton(title: "Pause All", target: nil, action: nil)
    private let clear = NSButton(title: "Clear Finished", target: nil, action: nil)
    private var rows: [JobRow] = []
    private var signature = ""
    private var observer: NSObjectProtocol?
    private var ticker: Timer?
    private var heightConstraint: NSLayoutConstraint?
    static let width: CGFloat = 430

    static var isShown: Bool { popover?.isShown == true }

    /// Opens the list under `view` (the chip, or the top bar when the chip is not there), or closes it when it is open.
    static func toggle(from view: NSView, workbench: Workbench?) {
        if let p = popover, p.isShown { p.close(); return }
        let c = JobsPopover()
        c.workbench = workbench
        let p = NSPopover()
        p.appearance = NSAppearance(named: .darkAqua)
        p.behavior = .transient
        p.delegate = c
        p.contentViewController = c
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        popover = p
    }

    static func close() { popover?.close() }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        v.wantsLayer = true
        v.appearance = NSAppearance(named: .darkAqua)
        v.layer?.backgroundColor = Design.stage.cgColor

        let heading = NSTextField(labelWithString: "Jobs")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = Design.ink
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = Design.mute
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let head = NSStackView(views: [heading, summary])
        head.spacing = 8
        head.alignment = .firstBaseline

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = JobsFlipped()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let limitLabel = NSTextField(labelWithString: "At once")
        limitLabel.font = .systemFont(ofSize: 11)
        limitLabel.textColor = Design.mute
        limit.controlSize = .small
        limit.font = .systemFont(ofSize: 11)
        limit.addItems(withTitles: ["No limit", "1 job", "2 jobs", "3 jobs", "4 jobs"])
        limit.target = self
        limit.action = #selector(limitChanged)
        limit.toolTip = "How many jobs run at the same time across every session. The rest wait in the order shown. One build per repository and one walk at a time, whatever this says."
        for b in [pauseAll, clear] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.target = self
        }
        pauseAll.action = #selector(pauseOrResumeAll)
        clear.action = #selector(clearFinished)
        clear.toolTip = "Take the jobs that are over out of the list"
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let foot = NSStackView(views: [limitLabel, limit, gap, pauseAll, clear])
        foot.spacing = 6

        let column = NSStackView(views: [head, scroll, foot])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(column)
        let h = scroll.heightAnchor.constraint(equalToConstant: 60)
        heightConstraint = h
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: v.topAnchor, constant: 12), column.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
            column.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 12), column.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12),
            v.widthAnchor.constraint(equalToConstant: Self.width),
            head.widthAnchor.constraint(equalTo: column.widthAnchor), scroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            foot.widthAnchor.constraint(equalTo: column.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            h,
        ])
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = NotificationCenter.default.addObserver(forName: JobQueue.changed, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.rows.forEach { $0.update() } }
        refresh()
    }

    func popoverDidClose(_ notification: Notification) {
        ticker?.invalidate()
        ticker = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if Self.popover?.contentViewController === self { Self.popover = nil }
    }

    // MARK: The list

    /// The list is rebuilt when a job came, went, changed state or moved; else only what its rows say changes.
    private func refresh() {
        let q = JobQueue.shared
        let shown = q.active + q.recent
        let sig = shown.map { "\($0.id)|\($0.state)|\($0.held)|\(q.canPause($0))|\(q.isFirst($0))" }.joined(separator: ",")
        if sig == signature { rows.forEach { $0.update() } } else { signature = sig; rebuild(q) }
        let running = q.running, waiting = q.waiting
        summary.stringValue = running.isEmpty && waiting.isEmpty ? "nothing is running" : JobsChip.counts(running: running.count, waiting: waiting)
        let n = q.limitOverride ?? q.limit
        limit.selectItem(at: min(n, limit.numberOfItems - 1))
        let anyToPause = q.jobs.contains { q.canPause($0) }
        let anyPaused = q.jobs.contains { $0.isPaused }
        pauseAll.title = !anyToPause && anyPaused ? "Resume All" : "Pause All"
        pauseAll.isEnabled = anyToPause || anyPaused
        pauseAll.toolTip = pauseAll.title == "Resume All" ? "Let every paused job go on" : "Hold every waiting job, and pause the running ones that can be"
        clear.isEnabled = !q.recent.isEmpty
    }

    private func header(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = Design.mute
        return l
    }

    private func rebuild(_ q: JobQueue) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        rows = []
        func add(_ title: String, _ jobs: [QueueJob]) {
            guard !jobs.isEmpty else { return }
            stack.addArrangedSubview(header(title))
            for job in jobs {
                let row = JobRow(job: job, buttons: buttons(for: job, in: q), reveal: reveal(job))
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                rows.append(row)
            }
        }
        add("Running", q.running)
        add("Waiting", q.waiting)
        add("Finished", q.recent)
        if rows.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "Nothing is running. Builds, walks of an app, comparisons and fetched builds show here while they run, whichever session started them.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = Design.mute
            empty.preferredMaxLayoutWidth = Self.width - 24
            stack.addArrangedSubview(empty)
        }
        stack.layoutSubtreeIfNeeded()
        heightConstraint?.constant = min(420, max(44, stack.fittingSize.height))
    }

    private func button(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSView {
        let b = ClosureButton(symbol: symbol, tip: tip, handler: action)
        b.contentTintColor = Design.mute
        b.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        b.setAccessibilityLabel(tip)
        return b
    }

    private func buttons(for job: QueueJob, in q: JobQueue) -> [NSView] {
        var out: [NSView] = []
        switch job.state {
        case .queued:
            if job.held { out.append(button("play.fill", "Resume: let it start when its turn comes") { q.resume(job) }) }
            else { out.append(button("pause.fill", "Hold it in the queue: it keeps its place and does not start") { q.pause(job) }) }
            if !q.isFirst(job) || job.held { out.append(button("arrow.up.to.line", "Run it before everything else that waits") { q.prioritize(job) }) }
            out.append(button("xmark", "Cancel") { q.cancel(job) })
        case .running:
            if q.canPause(job) {
                out.append(button("pause.fill", job.pauseTip) { [weak self] in
                    if let why = q.pause(job) { self?.workbench?.toast.show(why, problem: true) }
                })
            }
            out.append(button("xmark", "Cancel") { q.cancel(job) })
        case .paused:
            out.append(button("play.fill", "Resume") { q.resume(job) })
            out.append(button("xmark", "Cancel") { q.cancel(job) })
        case .done, .failed, .cancelled:
            out.append(button("xmark", "Take it out of the list") { q.forget(job) })
        }
        return out
    }

    /// What a click on a row shows: a build's log, the screen map of a walk made there. Nil when there is nothing to show.
    private func reveal(_ job: QueueJob) -> (() -> Void)? {
        guard let wb = workbench else { return nil }
        switch job.kind {
        case .map: return { JobsPopover.close(); wb.showMap() }
        case .build:
            guard let s = wb.sessions.sessions.first(where: { $0.worktree.path == job.owner }) else { return nil }
            return { JobsPopover.close(); wb.sessions.showBuildLog(s, from: nil) }
        default: return nil
        }
    }

    // MARK: The footer

    @objc private func limitChanged() { JobQueue.shared.limit = limit.indexOfSelectedItem }

    @objc private func pauseOrResumeAll() {
        if pauseAll.title == "Resume All" { JobQueue.shared.resumeAll() } else { JobQueue.shared.pauseAll() }
    }

    @objc private func clearFinished() { JobQueue.shared.clearRecent() }
}
