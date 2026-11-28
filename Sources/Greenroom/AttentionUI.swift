import AppKit

// The sidebar by attention, drawn (docs/AGENT-FIRST-SPEC.md, "Sessions, by what they need"): a session's card with
// its harness's mark, the task's title, repository and branch, six marks for the loop and one line saying why it is
// where it is; the group headers; and the counts in the top bar. The model is Attention.swift.

/// Six small marks, one a step of the loop.
final class LoopPips: NSView {
    var steps: [LoopStep] = [] { didSet { needsDisplay = true; toolTip = steps.map { "\($0.name): \($0.state == .none ? "not yet" : $0.state.rawValue)\($0.detail.isEmpty ? "" : " · " + $0.detail)" }.joined(separator: "\n") } }
    private static let size: CGFloat = 6, gap: CGFloat = 3

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(LoopStep.names.count) * Self.size + CGFloat(LoopStep.names.count - 1) * Self.gap, height: Self.size)
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = (bounds.height - Self.size) / 2
        for (i, step) in steps.enumerated() {
            let r = NSRect(x: CGFloat(i) * (Self.size + Self.gap), y: y, width: Self.size, height: Self.size)
            step.color.setFill()
            if step.state == .going {
                // Under way: a ring, so it reads apart from done at a glance (and without colour).
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                step.color.setStroke()
                ring.stroke()
            } else {
                NSBezierPath(ovalIn: r).fill()
            }
        }
    }

    override func accessibilityLabel() -> String? { toolTip }
    override func isAccessibilityElement() -> Bool { true }
}

extension SessionsController {
    /// The two letters a card shows for the harness at work in a session ("CC", "CX", "CU", "T3"), and its name.
    static func mark(for agent: AgentSession?) -> (letters: String, name: String)? {
        guard let agent else { return nil }
        var name = agent.sourceName
        // A T3 Code thread runs a harness of its own: the card names that one.
        if agent.source == .t3, let p = agent.provider?.lowercased() {
            if p.contains("claude") { name = "Claude Code" } else if p.contains("codex") { name = "Codex" } else if p.contains("cursor") { name = "Cursor" }
        }
        return (mark(name: name), agent.source == .t3 && name != "T3 Code" ? "\(name) in T3 Code" : name)
    }

    static func mark(name: String) -> String {
        switch name {
        case "Claude Code": return "CC"
        case "Codex": return "CX"
        case "Cursor": return "CU"
        case "T3 Code": return "T3"
        case "Antigravity": return "AG"
        case "Copilot": return "CO"
        case "Gemini CLI": return "GE"
        default:
            let letters = name.filter { $0.isLetter || $0.isNumber }
            return letters.isEmpty ? "AG" : String(letters.prefix(2)).uppercased()
        }
    }

    /// "just now", "4 min", "2 h", "3 d": how long, in as few letters as a card has room for.
    static func short(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86_400 { return "\(s / 3600) h" }
        return "\(s / 86_400) d"
    }

    /// What a card's last line says: why the session is in its group, and for how long.
    func attentionLine(for s: Session, _ state: AttentionState) -> String {
        let now = WorkStore.now()
        let age = since(s).map { Self.short(now.timeIntervalSince($0)) }
        switch state.group {
        case .ready, .needs:
            guard let age, age != "just now" else { return state.line }
            return state.line + " · " + age + " ago"
        case .working:
            // The step of the loop it is in, when one is under way.
            let going = loop(for: s).first { $0.state == .going && $0.name != "Review" }
            let what = going.map { $0.detail.isEmpty ? state.line : "\($0.name): \($0.detail)" } ?? state.line
            guard let age, age != "just now" else { return what }
            return what + " · " + age
        case .quiet:
            guard let built = s.builtAt else { return "Not built" }
            return Self.age(built) + (s.isStale ? " · stale" : "")
        }
    }

    private func attentionWhere(_ s: Session) -> String {
        let branch = s.branch ?? (s.shortHead.isEmpty ? s.worktree.lastPathComponent : "(detached \(s.shortHead))")
        // A session titled by its branch does not say the branch twice: its commit instead.
        var bits = [s.workspace.lastPathComponent, branch == s.title && !s.shortHead.isEmpty ? s.shortHead : branch]
        if let n = s.prNumber { bits.append("#\(n)" + (s.githubPR.map { " " + $0.statusBadge } ?? "")) }
        return bits.joined(separator: " · ")
    }

    /// Everything an attention card shows, as one string: the sidebar rebuilds a card only when this changed.
    func attentionKey(for s: Session, _ state: AttentionState) -> String {
        let job = buildQueue.job(for: s)
        let jobKey = job.map { "\($0.id)|\($0.state == .queued)|\($0.isActive)|\($0.failure ?? "")" } ?? "-"
        let sim = s.simulator.map { $0.state == .running ? "run" : "on" } ?? "off"
        let selected = s.simulator != nil && s.simulator === workbench?.selected
        let mark = Self.mark(for: s.displayAgent)
        let steps: String = loop(for: s).map { $0.state.rawValue + $0.detail }.joined(separator: ",")
        let shortcut: String = shortcutIndex(for: s).map(String.init) ?? ""
        var parts: [String] = [s.title, mark?.letters ?? "", mark?.name ?? "", attentionWhere(s), attentionLine(for: s, state)]
        parts += ["\(state.group.rawValue)", steps, sim, jobKey, evidence.badgeKey(for: s)]
        parts += [selected ? "sel" : "", shortcut, s.prURL?.absoluteString ?? ""]
        return parts.joined(separator: "\u{1f}")
    }

    /// The card's height: its three lines, and the buttons under them when it is the selected one.
    func attentionHeight(for s: Session) -> CGFloat {
        let selected = s.simulator != nil && s.simulator === workbench?.selected
        return 6 + 14 + 17 + 4 + 14 + 4 + 14 + (selected ? 7 + 25 : 0)
    }

    private static func line(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    func attentionCell(for s: Session, _ state: AttentionState) -> NSView {
        let selected = s.simulator != nil && s.simulator === workbench?.selected
        let steps = loop(for: s)

        // Line 1: the harness's mark, the task's title, a running build, the key that picks the row.
        var header: [NSView] = []
        if let mark = Self.mark(for: s.displayAgent) {
            let pill = Self.makePill(mark.letters, textColor: state.group.color, fill: state.group.color.withAlphaComponent(0.14),
                                     border: state.group.color.withAlphaComponent(0.28), font: .systemFont(ofSize: 9, weight: .bold))
            pill.toolTip = mark.name
            pill.setAccessibilityLabel(mark.name)
            header.append(pill)
        } else {
            let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "No agent") ?? NSImage())
            icon.contentTintColor = .tertiaryLabelColor
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .medium)
            icon.setContentHuggingPriority(.required, for: .horizontal)
            header.append(icon)
        }
        header.append(Self.line(s.title, size: 13, weight: selected ? .semibold : .medium, color: Design.ink))
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.append(headerSpacer)
        let build = buildAccessories(for: s)
        let activeBuild = buildQueue.job(for: s)?.isActive ?? false
        var overlayButtons: [NSView] = []
        for v in build.views {
            if activeBuild, v is NSProgressIndicator || (v as? ClosureButton)?.toolTip?.hasPrefix("Cancel") == true { header.append(v) } else { overlayButtons.append(v) }
        }
        if state.group == .ready {
            let done = ClosureButton(symbol: "checkmark.circle", tip: "Mark as reviewed: it leaves Ready until its agent does more") { [weak self] in self?.markReviewed(s) }
            done.contentTintColor = .secondaryLabelColor
            overlayButtons.append(done)
        }
        let remove = ClosureButton(symbol: "xmark", tip: "Remove from the sidebar (the repository's + menu brings it back)") { [weak self] in self?.remove(s) }
        remove.contentTintColor = .tertiaryLabelColor
        overlayButtons.append(remove)
        var shortcutBadge: NSTextField?
        if let n = shortcutIndex(for: s) {
            let badge = NSTextField(labelWithString: "⌘\(n)")
            badge.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            badge.textColor = .tertiaryLabelColor
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            header.append(badge)
            shortcutBadge = badge
        }
        let headerStack = NSStackView(views: header)
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 5
        headerStack.heightAnchor.constraint(equalToConstant: 17).isActive = true

        // Line 2: where it is, and what its walk found.
        let whereLabel = Self.line(attentionWhere(s), size: 10.5, weight: .regular, color: .secondaryLabelColor)
        let whereSpacer = NSView()
        whereSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        var whereViews: [NSView] = [whereLabel, whereSpacer]
        if let walk = evidence.badge(for: s) { whereViews.append(walk) }
        let whereRow = NSStackView(views: whereViews)
        whereRow.orientation = .horizontal
        whereRow.alignment = .centerY
        whereRow.spacing = 6
        whereRow.heightAnchor.constraint(equalToConstant: 14).isActive = true

        // Line 3: the loop, and why the session is in this group.
        let pips = LoopPips()
        pips.steps = steps
        pips.setContentHuggingPriority(.required, for: .horizontal)
        pips.setContentCompressionResistancePriority(.required, for: .horizontal)
        let tone: NSColor
        switch state.tone {
        case .ok: tone = Design.accent
        case .bad: tone = Design.record
        case .warn: tone = Design.warning
        case .go: tone = Attention.working.color
        case .plain: tone = .secondaryLabelColor
        }
        let why = Self.line(attentionLine(for: s, state), size: 10.5, weight: state.group == .quiet ? .regular : .medium, color: tone)
        let lineRow = NSStackView(views: [pips, why])
        lineRow.orientation = .horizontal
        lineRow.alignment = .centerY
        lineRow.spacing = 7
        lineRow.heightAnchor.constraint(equalToConstant: 14).isActive = true

        var rows: [NSView] = [headerStack, whereRow, lineRow]
        var actionRow: NSView?
        if selected {
            func button(_ symbol: String, _ title: String, _ label: String, _ run: @escaping () -> Void) -> GlassButton {
                let b = GlassButton(symbol: symbol, title: title, label: label, style: .well, target: nil, action: nil)
                b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
                b.font = .systemFont(ofSize: 11, weight: .medium)
                b.heightAnchor.constraint(equalToConstant: 25).isActive = true
                b.layer?.cornerRadius = 7
                b.onPress = run
                return b
            }
            var actions: [NSView] = [
                button("hammer", "Build", "Rebuild this session") { [weak self] in self?.build(s) },
                button("plusminus", "Changes", "Show changes for this session") { [weak self] in self?.workbench?.showChanges(of: s) },
            ]
            if let url = s.prURL { actions.append(button("arrow.up.right", "PR", "Open pull request on GitHub") { NSWorkspace.shared.open(url) }) }
            let row = NSStackView(views: actions)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = 6
            row.heightAnchor.constraint(equalToConstant: 25).isActive = true
            rows.append(row)
            actionRow = row
        }

        for case let b as ClosureButton in overlayButtons {
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }
        let overlay = NSStackView(views: overlayButtons)
        overlay.orientation = .horizontal
        overlay.alignment = .centerY
        overlay.spacing = 4
        overlay.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 7
        overlay.layer?.cornerCurve = .continuous
        overlay.layer?.backgroundColor = NSColor(srgbRed: 0.145, green: 0.153, blue: 0.172, alpha: 0.96).cgColor
        overlay.layer?.borderWidth = 0.75
        overlay.layer?.borderColor = Design.stroke.cgColor
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true

        let content = NSStackView(views: rows)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        if let actionRow { content.setCustomSpacing(7, after: lineRow); _ = actionRow }
        content.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8.5
        card.layer?.cornerCurve = .continuous
        if !selected {
            card.layer?.backgroundColor = NSColor(white: 1, alpha: 0.02).cgColor
            card.layer?.borderWidth = 1
            card.layer?.borderColor = NSColor(white: 1, alpha: 0.05).cgColor
        }
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        card.addSubview(overlay)
        var constraints = [
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -7),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            overlay.centerYAnchor.constraint(equalTo: headerStack.centerYAnchor),
            overlay.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -5),
        ]
        for r in rows { constraints.append(r.widthAnchor.constraint(equalTo: content.widthAnchor)) }
        NSLayoutConstraint.activate(constraints)

        var tip = ["\(state.group.title): \(attentionLine(for: s, state))"]
        if let mark = Self.mark(for: s.displayAgent) { tip.append(mark.name + (s.displayAgent?.title.map { ": " + $0 } ?? "")) }
        if let pr = s.githubPR { tip.append("PR #\(pr.number): \(pr.title) (\(pr.statusBadge))") }
        tip.append("Branch: \(s.branch ?? "detached") (\(s.shortHead)\(s.ahead > 0 ? ", \(s.ahead) ahead" : "")\(s.dirty ? ", edited" : ""))")
        tip.append("Worktree: \((s.worktree.path as NSString).abbreviatingWithTildeInPath)")
        tip.append(steps.map { "\($0.name) \($0.state == .none ? "–" : $0.state.rawValue)" }.joined(separator: "  "))

        let wrapper = HoverCardWrapper()
        wrapper.overlay = overlay
        wrapper.hideOnHover = shortcutBadge
        wrapper.toolTip = tip.joined(separator: "\n")
        wrapper.autoresizingMask = [.width, .height]
        wrapper.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -3),
            card.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 1),
            card.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -1),
        ])
        return wrapper
    }

    /// A group's header: its name, a dot of its colour and how many it holds.
    static func attentionHeader(_ group: Attention, count: Int, inset: CGFloat) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = group.color.cgColor
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let label = NSTextField(labelWithString: group.title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let n = NSTextField(labelWithString: "\(count)")
        n.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        n.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [dot, label, n])
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: 6)
        stack.setAccessibilityLabel("\(group.title), \(count)")
        return stack
    }
}

/// The counts in the top bar ("1 ready · 1 needs you · 2 working"), each in its group's colour. A click goes to the
/// next session that is ready or needs the person. Hidden while every session is quiet.
final class AttentionChip: NSView {
    var onPress: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private(set) var text: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Design.well.cgColor
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: GlassButtonCell.iconOnly.height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ counts: [Attention: Int]) {
        let next = Attention.summary(counts)
        guard next != text || isHidden != (next == nil) else { return }
        text = next
        isHidden = next == nil
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for g in [Attention.ready, .needs, .working] {
            guard let n = counts[g], n > 0 else { continue }
            if out.length > 0 { out.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])) }
            out.append(NSAttributedString(string: g.counted(n), attributes: [.font: font, .foregroundColor: g == .working ? Design.ink.withAlphaComponent(0.85) : g.color]))
        }
        label.attributedStringValue = out
        let waiting = (counts[.ready] ?? 0) + (counts[.needs] ?? 0)
        toolTip = waiting > 0 ? "Go to the next session that is ready or needs you (⌘')" : "Sessions at work"
        setAccessibilityLabel(next ?? "")
    }

    override func mouseDown(with event: NSEvent) { layer?.backgroundColor = Design.wellOn.cgColor }
    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = Design.well.cgColor
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}
