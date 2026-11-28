import AppKit

/// What the stage shows for a session the person chose that has no simulator: its name and why nothing runs.
/// Without it the stage kept the last simulator, which is another session's, beside this session's panel.
final class SessionStage: NSView {
    private let title = NSTextField(labelWithString: "")
    private let line = NSTextField(wrappingLabelWithString: "")
    /// What it says (for a check).
    var texts: [String] { [title.stringValue, line.stringValue] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        // Its own stage, so running devices do not show through.
        let floor = StageBackground()
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = Design.ink
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        line.font = .systemFont(ofSize: 13)
        line.textColor = Design.mute
        line.alignment = .center
        let stack = NSStackView(views: [title, line])
        stack.orientation = .vertical
        stack.spacing = 8
        for v in [floor, stack] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            floor.topAnchor.constraint(equalTo: topAnchor), floor.bottomAnchor.constraint(equalTo: bottomAnchor),
            floor.leadingAnchor.constraint(equalTo: leadingAnchor), floor.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title: String, line: String) {
        if self.title.stringValue != title { self.title.stringValue = title }
        if self.line.stringValue != line { self.line.stringValue = line }
    }
}
