import AppKit
import AVKit
import SwiftUI

// The session panel and the loop strip (docs/AGENT-FIRST-SPEC.md, A6), drawn from what ReviewController worked out.

private extension LoopStep {
    var tint: Color { Color(nsColor: color) }
}

private struct PanelButton: ButtonStyle {
    enum Kind { case primary, plain, danger }
    var kind: Kind = .plain
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = kind == .primary ? SettingsTheme.accent : Color.white.opacity(configuration.isPressed ? 0.16 : 0.09)
        let ink: Color = kind == .primary ? SettingsTheme.onAccent : (kind == .danger ? SettingsTheme.record : SettingsTheme.ink)
        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

private struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SettingsTheme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
    }
}

private func heading(_ text: String) -> some View {
    Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(SettingsTheme.mute)
}

struct SessionPanelView: View {
    @ObservedObject var model: SessionPanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let s = model.state {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        verdict(s)
                        if model.merge.number != nil || !model.merge.blocked.isEmpty { pull } else if model.merge.none { noPull }
                        spec(s)
                        tell(s)
                        if !s.calls.isEmpty { activity(s) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
            } else {
                Text("Choose a session to see what its agent set out to do, what it checked, and to answer it.")
                    .font(.system(size: 12)).foregroundStyle(SettingsTheme.mute)
                    .padding(16)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: Design.stage).opacity(0.92)))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let s = model.state {
                Text(s.mark)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(SettingsTheme.ink)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.agent.opacity(0.75)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsTheme.ink).lineLimit(1).truncationMode(.middle)
                    Text(s.repository).font(.system(size: 10.5)).foregroundStyle(SettingsTheme.mute).lineLimit(1)
                }
            } else {
                Text("Session").font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsTheme.ink)
            }
            Spacer(minLength: 4)
            Button("All agents") { model.onAllAgents?() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SettingsTheme.mute)
                .help("Every agent's calls, pausing, and recording")
            Button { model.onClose?() } label: { Image(systemName: "xmark").font(.system(size: 10.5, weight: .semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(SettingsTheme.mute)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.07)))
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: Where it stands, and the person's answer

    private func tone(_ s: SessionPanelState) -> Color {
        switch s.verdict {
        case .asked, .ready, .approved: return SettingsTheme.accent
        case .changes: return SettingsTheme.warning
        case .none: return Color(nsColor: s.group.color)
        }
    }

    private func verdict(_ s: SessionPanelState) -> some View {
        Card {
            HStack(spacing: 7) {
                Circle().fill(tone(s)).frame(width: 8, height: 8)
                Text(s.headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsTheme.ink)
            }
            if !s.summary.isEmpty {
                Text(s.summary).font(.system(size: 12)).foregroundStyle(SettingsTheme.ink.opacity(0.86)).fixedSize(horizontal: false, vertical: true)
            }
            LoopPipsRow(steps: s.steps)
            if !s.answerNote.isEmpty {
                Text(s.answerNote).font(.system(size: 11)).foregroundStyle(SettingsTheme.mute)
            }
            if s.canAnswer {
                HStack(spacing: 8) {
                    Button("Approve") { model.onApprove?() }
                        .buttonStyle(PanelButton(kind: s.verdict == .asked || s.verdict == .ready ? .primary : .plain))
                        .help("Tell the agent its work is approved, for the commit the session is at")
                    Button("Request Changes") { model.onRequestChanges?() }
                        .buttonStyle(PanelButton())
                        .help("Tell the agent what to change: your comments below go with it")
                }
                .padding(.top, 2)
            }
        }
    }

    private var pull: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                heading("Pull request")
                Spacer()
                if model.merge.number != nil {
                    Button("Open on GitHub") { model.onOpenPull?() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(SettingsTheme.accent)
                }
            }
            if let n = model.merge.number {
                Text("#\(n) \(model.merge.title)").font(.system(size: 12, weight: .medium)).foregroundStyle(SettingsTheme.ink).lineLimit(2)
            }
            if !model.merge.detail.isEmpty {
                Text(model.merge.detail).font(.system(size: 11)).foregroundStyle(SettingsTheme.mute).fixedSize(horizontal: false, vertical: true)
            }
            if !model.merge.blocked.isEmpty {
                Text(model.merge.blocked).font(.system(size: 11)).foregroundStyle(model.merge.merged ? SettingsTheme.accent : SettingsTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.merge.canMerge || model.merge.busy {
                Button(model.merge.busy ? "Merging…" : "Merge…") { model.onMerge?() }
                    .buttonStyle(PanelButton())
                    .disabled(model.merge.busy)
                    .help("Merge this pull request as your GitHub account. Only you can: no agent tool does.")
            }
        }
    }

    private var noPull: some View {
        Card {
            heading("Pull request")
            Text("This branch has no pull request yet, so there is nothing to merge.").font(.system(size: 11.5)).foregroundStyle(SettingsTheme.mute)
                .fixedSize(horizontal: false, vertical: true)
            Button("Ask the Agent for One") { model.onAskForPull?() }
                .buttonStyle(PanelButton())
                .help("Sends the agent a comment asking it to open a pull request for this branch")
        }
    }

    // MARK: The spec

    private func spec(_ s: SessionPanelState) -> some View {
        Card {
            heading("Spec")
            if let title = s.specTitle {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(SettingsTheme.ink).fixedSize(horizontal: false, vertical: true)
                if !s.specText.isEmpty {
                    Text(s.specText).font(.system(size: 12)).foregroundStyle(SettingsTheme.ink.opacity(0.86)).fixedSize(horizontal: false, vertical: true)
                }
                if let link = s.specLink {
                    Button(link) { model.onOpen?(link) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(SettingsTheme.accent).lineLimit(1).truncationMode(.middle)
                }
                ForEach(s.criteria) { c in criterion(c) }
                if s.criteria.isEmpty {
                    Text("The agent named no criteria.").font(.system(size: 11)).foregroundStyle(SettingsTheme.mute)
                }
            } else {
                Text("The agent has not said what this session is for. One that uses Greenroom's spec tool shows its task and criteria here, each ticked as it is checked.")
                    .font(.system(size: 11.5)).foregroundStyle(SettingsTheme.mute).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func criterion(_ c: SessionPanelState.Criterion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: c.state == .passed ? "checkmark.circle.fill" : (c.state == .failed ? "xmark.circle.fill" : "circle"))
                .font(.system(size: 13))
                .foregroundStyle(c.state == .passed ? SettingsTheme.accent : (c.state == .failed ? SettingsTheme.record : SettingsTheme.mute.opacity(0.6)))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.text).font(.system(size: 12)).foregroundStyle(SettingsTheme.ink).fixedSize(horizontal: false, vertical: true)
                Text(c.detail).font(.system(size: 10.5)).foregroundStyle(c.state == .failed ? SettingsTheme.record.opacity(0.9) : SettingsTheme.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if c.recording != nil {
                Button { model.onPlay?(c) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text(SessionPanelView.clock(c.second ?? 0)).font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(SettingsTheme.ink)
                .padding(.horizontal, 7).frame(height: 20)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .help("Play the recording from just before this check")
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func clock(_ seconds: Double) -> String {
        let n = Int(seconds)
        return "\(n / 60):" + String(format: "%02d", n % 60)
    }

    // MARK: Telling the agent

    private func tell(_ s: SessionPanelState) -> some View {
        Card {
            heading("Tell the agent")
            ForEach(s.comments) { c in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(c.text).font(.system(size: 12)).foregroundStyle(SettingsTheme.ink).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if c.pending {
                            Button { model.onRemove?(c.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                                .buttonStyle(.plain).foregroundStyle(SettingsTheme.mute)
                                .help("Take it back: the agent has not been given it")
                        }
                    }
                    if let pin = c.pin { pinLine(pin, picture: c.picture) }
                    Text(c.status).font(.system(size: 10.5)).foregroundStyle(c.pending ? SettingsTheme.warning : SettingsTheme.mute)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
            }
            TextEditor(text: $model.draft)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 54)
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SettingsTheme.wellFill))
                .overlay(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text("What should it change, or know?").font(.system(size: 12)).foregroundStyle(SettingsTheme.mute.opacity(0.7))
                            .padding(.horizontal, 10).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Comment for the agent")
            if let pin = model.pin {
                pinLine("Pinned to \(ScreenNode.quote(pin.label))" + (pin.screen.isEmpty ? "" : " on \(pin.screen)"), picture: pin.picture)
            }
            HStack(spacing: 8) {
                Button(model.pin != nil ? "Unpin" : (model.pinning ? "Cancel" : "Pin to Screen")) { model.onPin?() }
                    .buttonStyle(PanelButton())
                    .disabled(!s.hasSimulator && model.pin == nil && !model.pinning)
                    .help(s.hasSimulator ? "Click a node on the session's device: the agent gets its name, where it is and a picture"
                                         : "The session's simulator is not running")
                Spacer()
                Button("Send") { model.onSend?() }
                    .buttonStyle(PanelButton(kind: .primary))
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("The agent hears it with its next call, when its turn ends, or with the answer to its review")
            }
            if model.pinning {
                Text("Click what your comment is about on the device.").font(.system(size: 11)).foregroundStyle(SettingsTheme.warning)
            }
        }
    }

    private func pinLine(_ text: String, picture: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let picture, let image = NSImage(contentsOfFile: picture) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 96, maxHeight: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityLabel("A picture of it")
            }
            HStack(spacing: 4) {
                Image(systemName: "pin.fill").font(.system(size: 9))
                Text(text).font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color(nsColor: Design.difference))
        }
    }

    // MARK: What the agent did

    private func activity(_ s: SessionPanelState) -> some View {
        Card {
            heading("Last calls")
            ForEach(s.calls) { c in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(c.time).font(.system(size: 10).monospacedDigit()).foregroundStyle(SettingsTheme.mute)
                    Text(c.tool).font(.system(size: 11, weight: .semibold)).foregroundStyle(c.failed ? SettingsTheme.record : SettingsTheme.ink)
                    Text(c.summary).font(.system(size: 11)).foregroundStyle(SettingsTheme.mute).lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }
}

/// The six steps as a row of marks with their names under them.
private struct LoopPipsRow: View {
    let steps: [LoopStep]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                VStack(spacing: 3) {
                    Capsule().fill(step.tint).frame(height: 4)
                    Text(step.name).font(.system(size: 9, weight: .medium)).foregroundStyle(step.state == .none ? SettingsTheme.mute.opacity(0.6) : SettingsTheme.mute)
                }
                .help(step.detail.isEmpty ? step.name : "\(step.name): \(step.detail)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(steps.filter { $0.state != .none }.map { "\($0.name) \($0.state.rawValue)" }.joined(separator: ", "))
    }
}

/// The loop across the top of the stage: where the chosen session is between the spec and the review.
struct LoopStripView: View {
    @ObservedObject var model: LoopStripModel

    var body: some View {
        // What does not fit goes in this order: the details of steps that are done, who is driving, the other
        // details, the lines between the steps.
        ViewThatFits(in: .horizontal) {
            row(details: 2, driver: true, lines: true)
            row(details: 1, driver: true, lines: true)
            row(details: 1, driver: false, lines: true)
            row(details: 0, driver: false, lines: true)
            row(details: 0, driver: false, lines: false)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: Design.stage).opacity(0.9)))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SettingsTheme.stroke, lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loop for \(model.title)")
    }
}

extension LoopStripView {
    /// `details`: 2 every step's line, 1 only of steps under way, failed or waiting (what there is to act on), 0 none.
    fileprivate func row(details: Int, driver: Bool, lines: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(model.steps.enumerated()), id: \.offset) { i, step in
                if i > 0, lines { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 14, height: 1) }
                HStack(spacing: 5) {
                    Circle().fill(step.tint).frame(width: 7, height: 7)
                    Text(step.name).font(.system(size: 11.5, weight: step.state == .going ? .semibold : .medium))
                        .foregroundStyle(step.state == .none ? SettingsTheme.mute.opacity(0.7) : SettingsTheme.ink)
                        .lineLimit(1).fixedSize()
                    if details == 2 || (details == 1 && step.state != .done), !step.detail.isEmpty {
                        Text(step.detail).font(.system(size: 10.5)).foregroundStyle(step.state == .failed ? SettingsTheme.record : SettingsTheme.mute)
                            .lineLimit(1).fixedSize()
                    }
                }
                .padding(.horizontal, lines ? 6 : 4)
                .help(step.detail.isEmpty ? step.name : "\(step.name): \(step.detail)")
            }
            Spacer(minLength: 8)
            if driver, !model.driver.isEmpty {
                Text(model.driver).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(model.take == "Hand Back" ? SettingsTheme.warning : SettingsTheme.ink).lineLimit(1).fixedSize().padding(.trailing, 8)
            }
            if !model.take.isEmpty {
                Button(model.take) { model.onTake?() }
                    .buttonStyle(PanelButton())
                    .fixedSize()
                    .help(model.take == "Hand Back" ? "Let this session's agent act on the device again"
                                                    : "Take this session's device: its agent waits, the other sessions' agents go on")
                    .padding(.trailing, 6)
            }
            Button(model.action) { model.onOpen?() }
                .buttonStyle(PanelButton(kind: model.action == "Review" ? .primary : .plain))
                .fixedSize()
                .help("What this session set out to do, what was checked, and your answer")
        }
    }
}

/// A small window that plays a recording from a given second.
enum MomentPlayer {
    static func window(file: URL, second: Double, title: String) -> NSWindow {
        let player = AVPlayer(url: file)
        let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 360, height: 640))
        view.player = player
        view.controlsStyle = .inline
        let w = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = view
        w.appearance = NSAppearance(named: .darkAqua)
        w.center()
        player.seek(to: CMTime(seconds: second, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in player.play() }
        return w
    }
}
