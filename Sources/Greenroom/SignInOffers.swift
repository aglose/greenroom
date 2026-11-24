import AppKit

/// Quick sign-in: once a script has signed in from a screen, that screen offers the script as a button on the device,
/// so the next sign-in is one click rather than Device > Run Script.
///
/// - A screen is known by its activity (the class, so the app too) and its fingerprint: the short texts on it that
///   are not typed (labels, buttons, the fields' hints) and whether it has a password field. One activity holds many
///   screens in a Compose app, so the texts tell them apart.
/// - An offer is saved when a manual run of a script ends well (exit 0) and it started on a screen that looks like a
///   sign-in (a password field, or "sign in", "log in"... on it) that it then left. "Stop Offering" on the button
///   forgets it.
/// - `sign-in-offers.json` in the state folder holds the activity, the texts and the script's name: never what was typed.
final class SignInOffers {
    struct Print: Codable, Equatable {
        /// The activity's class name, as the engine answers `activity`.
        var activity: String
        /// Short texts on the screen that are not typed: what a label, a button or a field's hint says.
        var anchors: [String]
        var password: Bool

        /// The fingerprint of a screen from its nodes.
        init(activity: String, nodes: [ScreenNode]) {
            self.activity = activity.trimmingCharacters(in: .whitespacesAndNewlines)
            var seen = Set<String>(), out: [String] = []
            for n in nodes {
                // What is typed into a field changes; its hint, when it has one, does not.
                let raw = n.field ? n.hint : n.label
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (2...40).contains(t.count), !t.contains("\n"), t.contains(where: \.isLetter), seen.insert(t).inserted else { continue }
                out.append(t)
                if out.count == 40 { break }
            }
            anchors = out
            password = nodes.contains { $0.password }
        }

        init(activity: String, anchors: [String], password: Bool) {
            self.activity = activity
            self.anchors = anchors
            self.password = password
        }

        private static let signIn = try! NSRegularExpression(pattern: "\\b(sign in|sign-in|log in|login|password|connect|continue with)\\b", options: .caseInsensitive)

        /// Whether the screen looks like a sign-in: a password field, or a text that says so.
        var looksLikeSignIn: Bool {
            password || anchors.contains { Self.signIn.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }

        /// Whether `screen` is this screen again: the same activity, a password field if this had one, and most of
        /// this one's texts.
        func matches(_ screen: Print) -> Bool {
            guard !activity.isEmpty, activity == screen.activity, !anchors.isEmpty else { return false }
            if password && !screen.password { return false }
            let there = Set(screen.anchors)
            let shared = anchors.filter { there.contains($0) }.count
            return Double(shared) / Double(anchors.count) >= 0.6
        }
    }

    struct Offer: Codable, Equatable {
        var screen: Print
        /// The script's file name.
        var script: String
        /// From a session's `.greenroom/scripts` rather than Greenroom's own folder.
        var fromWorktree: Bool
        var date: Date
    }

    static let shared = SignInOffers()
    private(set) var offers: [Offer] = []
    private let file: URL?

    /// `file` nil: in memory only (the checks).
    init(file: URL? = Engine.shared.state.appendingPathComponent("sign-in-offers.json")) {
        self.file = file
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let file, let data = try? Data(contentsOf: file), let o = try? d.decode([Offer].self, from: data) { offers = o }
    }

    /// The offers for a screen, newest first.
    func offers(for screen: Print) -> [Offer] { offers.filter { $0.screen.matches(screen) }.reversed() }

    func hasOffers(activity: String) -> Bool { offers.contains { $0.screen.activity == activity } }

    /// Saves an offer of `script` on `screen`, unless that screen already offers it. Answers whether it was added.
    @discardableResult
    func add(_ script: Scripts.Script, on screen: Print) -> Bool {
        guard !offers.contains(where: { $0.script == script.name && $0.fromWorktree == script.fromWorktree && $0.screen.matches(screen) }) else { return false }
        offers.append(Offer(screen: screen, script: script.name, fromWorktree: script.fromWorktree, date: Date()))
        save()
        return true
    }

    func remove(_ offer: Offer) {
        offers.removeAll { $0 == offer }
        save()
    }

    private func save() {
        guard let file else { return }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        if let d = try? e.encode(offers) {
            try? d.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// The screen a simulator shows now. Blocks: never on the main thread. Nil when the simulator does not answer.
    static func capture(_ sim: Simulator) -> Print? {
        precondition(!Thread.isMainThread)
        let activity = sim.sendSync("activity", timeout: 5)
        guard !activity.hasPrefix("error") else { return nil }
        let raw = sim.sendSync("nodes", timeout: 10)
        guard !raw.hasPrefix("error") else { return nil }
        return Print(activity: activity, nodes: ScreenNode.parse(raw))
    }
}

/// Watches the devices on the stage and puts a "Sign in with…" button on one whose screen has an offer. Looks again
/// when a device draws something new (so a still screen costs nothing), and at least every few seconds.
final class QuickSignIn {
    private weak var workbench: Workbench?
    private var timer: Timer?
    private var busy = false
    private let queue = DispatchQueue(label: "greenroom-quick-sign-in")
    /// Per simulator: frames drawn when last looked at, and when.
    private var looked: [ObjectIdentifier: (frames: Int, at: Date)] = [:]
    /// Simulators a quick sign-in is running on: no button there meanwhile.
    private var running = Set<ObjectIdentifier>()
    /// Simulators a manual run of a script is running on (ScriptWindow): no button there either.
    static var scriptRunning = Set<ObjectIdentifier>()

    init(workbench: Workbench) {
        self.workbench = workbench
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Looks again now (an offer was added or removed).
    func refresh() {
        looked.removeAll()
        tick()
    }

    private func tick() {
        guard let wb = workbench, !busy else { return }
        let sims = Engine.shared.simulators.filter { $0.isAlive && $0.controlPort != nil && $0.framesShown > 0 && wb.stage.view(for: $0) != nil }
        // Views of devices that went: nothing to keep.
        let ids = Set(sims.map(ObjectIdentifier.init))
        looked = looked.filter { ids.contains($0.key) }
        let store = SignInOffers.shared
        guard !store.offers.isEmpty, !SignInOnce.isRunning else {
            for s in sims { wb.stage.view(for: s)?.quickSignIn = nil }
            return
        }
        let now = Date()
        let due = sims.filter { s in
            let id = ObjectIdentifier(s)
            if running.contains(id) || Self.scriptRunning.contains(id) { wb.stage.view(for: s)?.quickSignIn = nil; return false }
            guard let l = looked[id] else { return true }
            return l.frames != s.framesShown || now.timeIntervalSince(l.at) > 4
        }
        guard !due.isEmpty else { return }
        for s in due { looked[ObjectIdentifier(s)] = (s.framesShown, now) }
        busy = true
        queue.async { [weak self] in
            var found: [(Simulator, SignInOffers.Offer?)] = []
            for s in due {
                // The activity first: most screens of most apps have no offer, and asking for it is cheap.
                let activity = s.sendSync("activity", timeout: 5).trimmingCharacters(in: .whitespacesAndNewlines)
                var offer: SignInOffers.Offer?
                if !activity.hasPrefix("error"), DispatchQueue.main.sync(execute: { store.hasOffers(activity: activity) }) {
                    let raw = s.sendSync("nodes", timeout: 10)
                    if !raw.hasPrefix("error") {
                        let screen = SignInOffers.Print(activity: activity, nodes: ScreenNode.parse(raw))
                        offer = DispatchQueue.main.sync { store.offers(for: screen).first }
                    }
                }
                found.append((s, offer))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                for (s, offer) in found { self.show(offer, on: s) }
            }
        }
    }

    private func show(_ offer: SignInOffers.Offer?, on sim: Simulator) {
        guard let wb = workbench, let view = wb.stage.view(for: sim) else { return }
        let id = ObjectIdentifier(sim)
        guard let offer, sim.isAlive, !running.contains(id), !Self.scriptRunning.contains(id),
              let script = Scripts.available(for: wb.worktree(of: sim)).first(where: { $0.name == offer.script && $0.fromWorktree == offer.fromWorktree }) else {
            view.quickSignIn = nil
            return
        }
        if view.quickSignIn?.offer == offer { return }
        view.quickSignIn = QuickSignInButton.Model(offer: offer, title: Self.title(script),
                                                   run: { [weak self, weak sim] in if let sim { self?.run(script, on: sim) } },
                                                   forget: { [weak self] in self?.forget(offer) })
    }

    /// "Sign in with PercySafe" from sign-in-percysafe.sh; the file name for any other.
    static func title(_ script: Scripts.Script) -> String {
        let base = script.url.deletingPathExtension().lastPathComponent
        for p in ["sign-in-", "signin-", "login-", "log-in-"] where base.lowercased().hasPrefix(p) && base.count > p.count {
            let rest = base.dropFirst(p.count).replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return "Sign in to " + rest.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return "Sign in · \(script.name)"
    }

    private func forget(_ offer: SignInOffers.Offer) {
        SignInOffers.shared.remove(offer)
        workbench?.toast.show("This screen no longer offers \(offer.script). Run it from Device > Run Script.")
        refresh()
    }

    /// Runs the script with no window: the button says it is signing in, a toast says how it went. A failure's
    /// output opens in a window.
    private func run(_ script: Scripts.Script, on sim: Simulator) {
        guard let wb = workbench, let view = wb.stage.view(for: sim) else { return }
        guard let r = ScriptRun(script: script, sim: sim, worktree: wb.worktree(of: sim)) else {
            wb.toast.show("\(sim.name) is not ready for a script yet", problem: true)
            return
        }
        let id = ObjectIdentifier(sim)
        running.insert(id)
        view.quickSignIn?.busy = true
        view.refreshQuickSignIn()
        let simName = sim.name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let o = r.runSync(timeout: 600)
            DispatchQueue.main.async {
                guard let self else { return }
                self.running.remove(id)
                self.looked[id] = nil
                wb.stage.view(for: sim)?.quickSignIn = nil
                if o.code == 0 && o.failure == nil {
                    wb.toast.show("Signed in with \(script.name)")
                } else {
                    let why = o.failure ?? (o.timedOut ? "it ran for 10 minutes" : "exit \(o.code ?? -1)")
                    wb.toast.show("\(script.name) did not sign in (\(why))", action: "Show Output") {
                        ScriptWindow.showFinished(script: script, simName: simName, outcome: o, relativeTo: wb.window)
                    }
                }
                self.tick()
            }
        }
    }
}

/// The button a device shows over its screen's bottom when the screen has a quick sign-in: the script's name, and
/// a small × that stops the offer.
final class QuickSignInButton: NSView {
    struct Model {
        let offer: SignInOffers.Offer
        let title: String
        let run: () -> Void
        let forget: () -> Void
        var busy = false
    }

    private let glass = GlassView(radius: 18)
    private let main = GlassButton(symbol: "key.fill", title: "", label: "Sign in", style: .accent, target: nil, action: nil)
    private let close = GlassButton(symbol: "xmark", label: "Stop offering this sign-in here", target: nil, action: nil)
    private var model: Model?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [glass, main, close] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop offering")?.withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            main.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            main.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.leadingAnchor.constraint(equalTo: main.trailingAnchor, constant: 2),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 38),
        ])
        main.onPress = { [weak self] in
            guard let m = self?.model, !m.busy else { return }
            m.run()
        }
        close.onPress = { [weak self] in self?.model?.forget() }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ m: Model) {
        model = m
        main.title = m.busy ? "Signing in…" : m.title
        main.toolTip = m.busy ? "Running \(m.offer.script)" : "Run \(m.offer.script) on this device: it signed in from this screen before"
        main.setAccessibilityLabel(m.busy ? "Signing in" : m.title)
        close.isHidden = m.busy
        close.toolTip = "Stop offering \(m.offer.script) on this screen"
    }
}
