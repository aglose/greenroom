import AppKit

/// What the screen map shows before its first walk: what a walk does, then the three things that decide it (the app,
/// signing in, how far) each with where it stands and what to do about it, then Walk. Said once here so the first walk
/// is started knowing it runs in the background and can take a while.
final class MapOnboarding: NSView {
    struct State: Equatable {
        /// The APK's file name, nil: none.
        var app: String?
        /// The selected device's APK rather than a chosen one.
        var appIsDevice = false
        enum SignIn: Equatable { case none, kept(String), script(String) }
        var signIn: SignIn = .none
        /// "Whole app, no time limit, light captures".
        var reach = ""
        /// Python 3 is missing.
        var noPython = false
    }

    var onChoose: (() -> Void)?
    var onSignIn: (() -> Void)?
    var onWalk: (() -> Void)?

    private let appRow = Row(number: 1)
    private let signInRow = Row(number: 2)
    private let reachRow = Row(number: 3)
    private let walkButton = GlassButton(symbol: "point.3.connected.trianglepath.dotted", title: "Walk the app", label: "Walk every screen the app has", style: .accent, target: nil, action: nil)
    private let problem = NSTextField(wrappingLabelWithString: "")
    private(set) var state = State()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Map every screen of your app")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = Design.ink
        let lead = NSTextField(wrappingLabelWithString: "Greenroom taps through the app by itself, a level at a time, and draws every screen it reaches with the way there. Each walk of a committed build is kept, and later walks are compared with it, so you can see which screens a change touched.")
        lead.font = .systemFont(ofSize: 13)
        lead.textColor = Design.mute

        appRow.button.title = "Choose…"
        appRow.button.onPress = { [weak self] in self?.onChoose?() }
        signInRow.button.onPress = { [weak self] in self?.onSignIn?() }
        reachRow.button.isHidden = true
        walkButton.onPress = { [weak self] in self?.onWalk?() }
        walkButton.font = .systemFont(ofSize: 14, weight: .semibold)
        walkButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let background = NSTextField(wrappingLabelWithString: "It runs in the background on hidden devices, several at once, so yours are left alone. Close this and keep working: the top bar shows how far the walk has got, and the map is here when it ends. The first walk of a large app can take a while. It never taps delete, buy, send, sign out and the like.")
        background.font = .systemFont(ofSize: 12)
        background.textColor = Design.mute
        problem.font = .systemFont(ofSize: 12, weight: .medium)
        problem.textColor = Design.warning
        problem.isHidden = true

        let steps = NSStackView(views: [appRow, signInRow, reachRow])
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 10
        let column = NSStackView(views: [title, lead, steps, problem, walkButton, background])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.setCustomSpacing(6, after: title)
        column.setCustomSpacing(20, after: lead)
        column.setCustomSpacing(18, after: steps)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        for v in [lead, steps, problem, background, appRow, signInRow, reachRow] as [NSView] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: 520),
        ])
        show(State())
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ s: State) {
        state = s
        if let app = s.app {
            appRow.set(done: true, title: app, note: s.appIsDevice ? "The app on the selected device. Choose another APK to walk that instead." : "The APK you chose.")
        } else {
            appRow.set(done: false, title: "Choose the app", note: "Open an app on a device, or choose an APK file to walk.")
        }
        switch s.signIn {
        case .kept(let date):
            signInRow.set(done: true, title: "Starts signed in", note: "On a copy of the sign-in you kept \(date). Your devices' data is not touched.")
            signInRow.button.title = "Sign In Again…"
        case .script(let name):
            signInRow.set(done: true, title: "Signs in with \(name) first", note: "The script runs on a hidden device, then the walk starts on its data.")
            signInRow.button.title = "Sign In Once…"
        case .none:
            signInRow.set(done: false, optional: true, title: "Sign in, if the app needs an account", note: "Without it the walk stops at the sign-in screen. Sign in once on a device you can see, and every walk starts signed in.")
            signInRow.button.title = "Sign In Once…"
        }
        signInRow.button.isEnabled = s.app != nil
        reachRow.set(done: true, title: s.reach, note: "Change how far it goes, captures and network in the row above.")
        problem.isHidden = !s.noPython
        problem.stringValue = "The map needs Python 3, and this Mac has none. Install the command line tools (xcode-select --install in Terminal), then reopen this."
        walkButton.isEnabled = s.app != nil && !s.noPython
    }

    /// For checks.
    var walkEnabled: Bool { walkButton.isEnabled }
    var signInTitle: String { signInRow.titleText }

    /// One step: a numbered badge (a tick once it is settled), what it is, a line on it, and its button.
    final class Row: NSView {
        let button = GlassButton(symbol: nil, title: "", label: "", style: .well, target: nil, action: nil)
        private let badge = NSTextField(labelWithString: "")
        private let badgeWell = NSView()
        private let title = NSTextField(labelWithString: "")
        private let note = NSTextField(wrappingLabelWithString: "")
        private let number: Int
        var titleText: String { title.stringValue }

        init(number: Int) {
            self.number = number
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor
            layer?.cornerRadius = 10
            layer?.cornerCurve = .continuous
            badgeWell.wantsLayer = true
            badgeWell.layer?.cornerRadius = 11
            badgeWell.translatesAutoresizingMaskIntoConstraints = false
            badge.font = .systemFont(ofSize: 11, weight: .bold)
            badge.alignment = .center
            badge.translatesAutoresizingMaskIntoConstraints = false
            badgeWell.addSubview(badge)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.textColor = Design.ink
            title.lineBreakMode = .byTruncatingMiddle
            title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            note.font = .systemFont(ofSize: 12)
            note.textColor = Design.mute
            note.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let text = NSStackView(views: [title, note])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            text.setContentHuggingPriority(.init(1), for: .horizontal)
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [badgeWell, text, button])
            row.distribution = .fill   // the text takes the width, so the button sits at the row's right edge
            row.alignment = .centerY
            row.spacing = 12
            row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 10)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
                row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
                badgeWell.widthAnchor.constraint(equalToConstant: 22), badgeWell.heightAnchor.constraint(equalToConstant: 22),
                badge.centerXAnchor.constraint(equalTo: badgeWell.centerXAnchor), badge.centerYAnchor.constraint(equalTo: badgeWell.centerYAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        func set(done: Bool, optional: Bool = false, title t: String, note n: String) {
            title.stringValue = t
            note.stringValue = n
            badge.stringValue = done ? "✓" : "\(number)"
            badge.textColor = done ? Design.onAccent : (optional ? Design.mute : Design.ink)
            badgeWell.layer?.backgroundColor = (done ? Design.accent : Design.wellOn).cgColor
        }
    }
}
