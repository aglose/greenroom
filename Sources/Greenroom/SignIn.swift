import AppKit

/// An app's kept sign-in: the person signs in once, by hand, on a device they can see ("Sign In Once…"), and every
/// walk of that app then starts from a copy of that device's data.
///
/// - The data is a data slot of its own (`gsi…`), never one of the person's devices or sessions; a walk clones it and
///   removes its clone, as it does a session's data, so the kept sign-in is never changed by a walk.
/// - One sign-in per repository (every worktree of it), or per APK file name for an app opened with no repository.
/// - What the person did while signing in is recorded as a script (SignInRecorder), so Greenroom can sign in again
///   by itself when the kept sign-in stops working, and so a script exists for CI. What they typed is not in the
///   script: it is kept as variables in the Keychain.
/// - `sign-ins.json` in the state folder holds the slot's name, the date and the script's name: no credential.
final class SignIns {
    struct Record: Codable, Equatable {
        var slot: String
        var date: Date
        /// The recorded script's file name in Greenroom's scripts folder, when one was recorded.
        var script: String?
    }

    static let shared = SignIns()
    private var records: [String: Record] = [:]
    private let file: URL
    var onChange: (() -> Void)?

    static var dataRoot: URL { Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true) }
    static func key(workspace: URL) -> String { "repo:" + workspace.standardizedFileURL.path }
    static func key(apk: URL) -> String { "apk:" + apk.lastPathComponent }
    /// The kept slot's name for a key: lower-case letters and digits, as the engine takes.
    static func slot(for key: String) -> String { "gsi" + String(MapJSON.sha256(key).prefix(10)) }

    init(file: URL = Engine.shared.state.appendingPathComponent("sign-ins.json")) {
        self.file = file
        // Read as it is written (ISO 8601 dates): with the default decoder every kept sign-in was lost at the next launch.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: file), let r = try? decoder.decode([String: Record].self, from: d) { records = r }
    }

    /// The kept sign-in of a key, when its data is still there.
    func record(_ key: String?) -> Record? {
        guard let key, let r = records[key], SignIns.hasData(r.slot) else { return nil }
        return r
    }

    func set(_ r: Record, key: String) {
        records[key] = r
        save()
    }

    /// Forgets the sign-in and deletes its data. The recorded script and its variables stay: they are the person's.
    func forget(_ key: String) {
        if let r = records[key] { SlotClone.remove(r.slot, in: SignIns.dataRoot) }
        records[key] = nil
        save()
    }

    private func save() {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        if let d = try? e.encode(records) {
            try? d.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        onChange?()
    }

    /// Whether any app has data in the slot (`<package>/<slot>-0`).
    static func hasData(_ slot: String, in root: URL = SignIns.dataRoot) -> Bool {
        let fm = FileManager.default
        for pkg in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if fm.fileExists(atPath: pkg.appendingPathComponent(slot + "-0").path) { return true }
        }
        return false
    }

    /// The kept slot takes another slot's data (a script signed in again on a throwaway slot): what it had goes.
    @discardableResult
    static func adopt(_ other: String, as slot: String, in root: URL = SignIns.dataRoot) -> Bool {
        let fm = FileManager.default
        var moved = false
        for pkg in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard fm.fileExists(atPath: pkg.appendingPathComponent(other + "-0").path) else { continue }
            for suffix in ["", ".device"] {
                let from = pkg.appendingPathComponent(other + "-0" + suffix), to = pkg.appendingPathComponent(slot + "-0" + suffix)
                try? fm.removeItem(at: to)
                if fm.fileExists(atPath: from.path), (try? fm.moveItem(at: from, to: to)) != nil, suffix.isEmpty { moved = true }
            }
        }
        return moved
    }
}

/// Whether a walk met a sign-in: the app's first screen asks for one (the rest of the app is behind it), or screens
/// inside the app do (those parts are not mapped). Read from the screens' texts; a guess, said as one.
enum SignInWall: Equatable {
    case none
    /// The walk's first screen is a sign-in.
    case atStart
    /// This many screens ask for a sign-in or say they are locked.
    case inside(Int)

    private static let start = try! NSRegularExpression(pattern: "\\b(sign in|log in|login|sign up|create (an )?account|password|forgot password)\\b", options: .caseInsensitive)
    private static let gate = try! NSRegularExpression(pattern: "\\b(sign in to|log in to|please (sign|log) in|is locked|session (has )?expired)\\b", options: .caseInsensitive)
    private static func matches(_ re: NSRegularExpression, _ texts: [String]) -> Bool {
        texts.contains { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }

    static func find(_ screens: [(depth: Int, title: String, texts: [String])]) -> SignInWall {
        let first = screens.filter { $0.depth == 0 }
        // A sign-in at the start: every first screen asks, and little was found past it.
        if !first.isEmpty, first.allSatisfy({ matches(start, $0.texts + [$0.title]) }), screens.count <= 6 { return .atStart }
        let gated = screens.filter { matches(gate, $0.texts + [$0.title]) }.count
        return gated > 0 ? .inside(gated) : .none
    }

    static func find(_ map: ScreenMapData) -> SignInWall { find(map.screens.map { (depth: $0.depth, title: $0.title, texts: $0.texts) }) }

    /// What to tell the person, given whether a sign-in is kept for the app.
    func note(kept: Bool) -> String? {
        switch self {
        case .none: return nil
        case .atStart:
            return kept ? "The kept sign-in no longer works: the app opens on its sign-in screen. \"Sign In Again…\" renews it."
                        : "The app opens on a sign-in, so only that was mapped. \"Sign In Once…\" signs you in on a device you can see; every walk then starts signed in."
        case .inside(let n):
            return kept ? "\(n) screen\(n == 1 ? " still asks" : "s still ask") for a sign-in or say they are locked, though the walk started signed in."
                        : "\(n) screen\(n == 1 ? " asks" : "s ask") for a sign-in or say they are locked, so what is behind \(n == 1 ? "it" : "them") was not mapped. \"Sign In Once…\" signs you in on a device you can see; every walk then starts signed in."
        }
    }
}

/// Records what a person does on a simulator while signing in, as the steps of a script: taps by the text of what was
/// tapped (by position when it has none), what was typed as variables kept in the Keychain, keys and swipes.
final class SignInRecorder {
    enum Step: Equatable {
        case tap(label: String?, x: Int, y: Int)
        /// Typed text, by the name of the variable that holds it.
        case type(variable: String)
        case command(String)
        case swipe(Int, Int, Int, Int)
    }

    private(set) var steps: [Step] = []
    /// The variables the typed text went into, in order.
    private(set) var variables: [Variables.Variable] = []
    private let prefix: String
    private var typing = ""
    /// The field the last tap landed in: a password field makes what is typed next a secret; so does not knowing.
    private var lastField: ScreenNode?
    private var tappedField = false
    private var down: (x: Int, y: Int, node: ScreenNode?, far: Bool)?
    private var last: (x: Int, y: Int)?

    /// `prefix`: the start of the variables' names ("SIGNIN_HOMESAFE").
    init(prefix: String) { self.prefix = prefix }

    /// A name for an app's variables and script: letters, digits and _.
    static func tag(_ name: String) -> String {
        let up = name.uppercased().map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "_" }
        let s = String(up).split(separator: "_").joined(separator: "_")
        return s.isEmpty ? "APP" : String(s.prefix(24))
    }

    /// One thing the person did, in device pixels. `nodes`: the screen's nodes, asked for at a touch's start (the
    /// answer may come after the touch has ended).
    func touch(_ kind: String, x: Int, y: Int) {
        switch kind {
        case "down":
            flushTyping()
            down = (x, y, nil, false)
            last = (x, y)
        case "move":
            guard var d = down else { return }
            if abs(x - d.x) > 24 || abs(y - d.y) > 24 { d.far = true; down = d }
            last = (x, y)
        default:
            guard let d = down else { return }
            down = nil
            if d.far, let l = last { steps.append(.swipe(d.x, d.y, l.x, l.y)); return }
            pendingTap = steps.count
            steps.append(.tap(label: nil, x: d.x, y: d.y))
            if let n = d.node { name(tapAt: steps.count - 1, node: n) }
        }
    }

    /// The index of a tap whose node is not known yet.
    private var pendingTap: Int?

    /// The nodes of the screen as it was when the touch began.
    func nodes(_ list: [ScreenNode], x: Int, y: Int) {
        let p = CGPoint(x: x, y: y)
        let hit = list.filter { $0.frame.contains(p) && (!$0.label.isEmpty || $0.field || $0.password) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let hit else { return }
        if var d = down, d.x == x, d.y == y { d.node = hit; down = d; return }
        if let i = pendingTap, i < steps.count, case .tap(nil, x, y) = steps[i] { name(tapAt: i, node: hit) }
    }

    private func name(tapAt i: Int, node: ScreenNode) {
        pendingTap = nil
        // A password field's text is what was typed into it, so it is never a label: its hint or description is.
        let label = (node.password ? (!node.hint.isEmpty ? node.hint : node.desc) : node.label).trimmingCharacters(in: .whitespacesAndNewlines)
        // A label a script can find again: one line, not long.
        let usable = !label.isEmpty && label.count <= 40 && !label.contains("\n")
        if case .tap(_, let x, let y) = steps[i] { steps[i] = .tap(label: usable ? label : nil, x: x, y: y) }
        lastField = node.field ? node : nil
        tappedField = node.field
    }

    func text(_ t: String) { typing += t }

    func command(_ c: String) {
        // Backspace while typing takes the last character back; anything else ends the typing.
        if c.hasPrefix("key DEL"), !typing.isEmpty { typing.removeLast(); return }
        flushTyping()
        steps.append(.command(c))
    }

    private func flushTyping() {
        guard !typing.isEmpty else { return }
        // A secret unless it went into a field that is known not to be a password's.
        let secret = !(tappedField && lastField?.password == false)
        let name = "\(prefix)_\(variables.count + 1)"
        variables.append(Variables.Variable(name: name, value: typing, secret: secret))
        steps.append(.type(variable: name))
        typing = ""
    }

    /// Ends the recording: what is still being typed becomes its step.
    func finish() { flushTyping() }

    var isEmpty: Bool { steps.isEmpty && typing.isEmpty }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The script: bash, with `gr` as every Greenroom script has it. No typed value is in it.
    func script(app: String, date: Date = Date()) -> String {
        let day = ISO8601DateFormatter().string(from: date).prefix(10)
        var out = ["#!/bin/bash",
                   "# Signs in to \(app). Recorded by Greenroom's \"Sign In Once\" on \(day): the taps and keys you made, in order.",
                   "# What you typed is not here: it is in your Keychain as the variables below (Settings > Variables).",
                   "# Edit it freely: gr tap-text, gr type, gr key, gr wait TEXT SECONDS, gr tap X Y (see New Script… for all of gr).",
                   "set -euo pipefail", ""]
        for v in variables { out.append(": \"${\(v.name):?add \(v.name) in Greenroom > Settings > Variables}\"") }
        if !variables.isEmpty { out.append("") }
        for s in steps {
            switch s {
            case .tap(let label?, _, _):
                out.append("gr wait \(Self.quote(label)) 30")
                out.append("gr tap-text \(Self.quote(label))")
            case .tap(nil, let x, let y):
                out.append("sleep 1")
                out.append("gr tap \(x) \(y)")
            case .type(let v): out.append("gr type \"$\(v)\"")
            case .command(let c): out.append("gr \(c)")
            case .swipe(let a, let b, let c, let d): out.append("gr swipe \(a) \(b) \(c) \(d)")
            }
        }
        out += ["", "# Give the app a moment to finish signing in and write what it keeps.", "sleep 4", "echo \"signed in to \(app.replacingOccurrences(of: "\"", with: ""))\"", ""]
        return out.joined(separator: "\n")
    }
}

/// "Sign In Once…": the app on a device the person can see, on the kept slot, with a small panel beside it. They sign
/// in as they would on a phone and press "Use This Sign-In"; the device quits (so the app has written its data) and
/// the slot is the app's kept sign-in. What they did is recorded as a script.
final class SignInOnce: NSObject {
    private static var current: SignInOnce?
    static var isRunning: Bool { current != nil }

    private let workbench: Workbench
    private let apk: URL
    private let key: String
    private let app: String
    private let slot: String
    private let done: (Bool) -> Void
    private var sim: Simulator?
    private var recorder: SignInRecorder
    private var panel: NSPanel?
    private var observer: NSObjectProtocol?
    private var using = false
    private let note = NSTextField(wrappingLabelWithString: "")

    /// `app`: the app's name for the panel and the script. `done(true)`: a sign-in was kept.
    @discardableResult
    static func begin(workbench: Workbench, apk: URL, key: String, app: String, done: @escaping (Bool) -> Void) -> Bool {
        guard current == nil else { workbench.toast.show("A sign-in is already open: finish or cancel it first.", problem: true); return false }
        let s = SignInOnce(workbench: workbench, apk: apk, key: key, app: app, done: done)
        current = s
        s.start()
        return true
    }

    private init(workbench: Workbench, apk: URL, key: String, app: String, done: @escaping (Bool) -> Void) {
        self.workbench = workbench
        self.apk = apk
        self.key = key
        self.app = app
        // Signed in on a slot of its own first: the kept one is replaced only when the person says this one is good.
        slot = SlotClone.freshName(prefix: "gsn")
        self.done = done
        recorder = SignInRecorder(prefix: "SIGNIN_" + SignInRecorder.tag(app))
    }

    private func start() {
        guard let sim = workbench.open(apk, remember: false, options: ["--data-slots", slot]) else {
            workbench.toast.show("The app could not be started to sign in.", problem: true)
            end(kept: false)
            return
        }
        self.sim = sim
        sim.onPerform = { [weak self, weak sim] input in
            guard let self, let sim else { return }
            let size = sim.deviceSize
            func px(_ f: CGPoint) -> (Int, Int) { (Int(min(max(f.x * size.width, 0), max(size.width - 1, 0))), Int(min(max(f.y * size.height, 0), max(size.height - 1, 0)))) }
            switch input {
            case .touch(let kind, let f):
                let (x, y) = px(f)
                self.recorder.touch(kind, x: x, y: y)
                if kind == "down" { sim.send("nodes") { [weak self] raw in self?.recorder.nodes(ScreenNode.parse(raw), x: x, y: y) } }
            case .text(let t): self.recorder.text(t)
            case .command(let c): self.recorder.command(c)
            case .wheel: break
            }
        }
        observer = NotificationCenter.default.addObserver(forName: Simulator.stateChanged, object: nil, queue: .main) { [weak self] _ in self?.stateChanged() }
        showPanel()
    }

    private func showPanel() {
        guard let window = workbench.window as NSWindow? else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150), styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "Sign in to \(app)"
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        note.stringValue = "Sign in on this device the way you would on a phone. When the app shows you are in, press Use This Sign-In.\n\nEvery walk of \(app) will then start signed in, on a copy of this device's data. What you do here is recorded as a script, so Greenroom can sign in again by itself; what you type is kept in your Keychain, not in the script."
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        let use = NSButton(title: "Use This Sign-In", target: self, action: #selector(usePressed))
        use.keyEquivalent = "\r"
        use.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, use])
        let stack = NSStackView(views: [note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 340), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        p.contentView = content
        p.setContentSize(content.fittingSize)
        let f = window.frame
        p.setFrameTopLeftPoint(NSPoint(x: f.maxX - p.frame.width - 24, y: f.maxY - 72))
        window.addChildWindow(p, ordered: .above)
        panel = p
    }

    private func stateChanged() {
        guard let sim else { return }
        if case .ended = sim.state {
            // "Use This Sign-In" quit it: its data is written. Closed any other way: nothing is kept.
            if using { keep() } else { end(kept: false) }
        }
    }

    @objc private func usePressed() {
        guard let sim, !using else { return }
        using = true
        recorder.finish()
        note.stringValue = "Keeping the sign-in…"
        if sim.isAlive { sim.quit() } else { keep() }
    }

    @objc private func cancelPressed() {
        guard !using else { return }
        if let sim, sim.isAlive { sim.quit() } else { end(kept: false) }
    }

    /// The device has quit with the person's go-ahead: its slot becomes the kept one, the script and variables are written.
    /// The device's process has ended, but the engine's JVM may still be writing the slot: it is moved once that has let go.
    private func keep() {
        let slot = self.slot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            SlotClone.waitUntilFree(slot, in: SignIns.dataRoot)
            DispatchQueue.main.async { self?.adoptKept() }
        }
    }

    private func adoptKept() {
        let kept = SignIns.slot(for: key)
        SlotClone.remove(kept, in: SignIns.dataRoot)
        guard SignIns.adopt(slot, as: kept) else {
            workbench.toast.show("The app kept no data on that device, so there is no sign-in to keep.", problem: true)
            end(kept: false)
            return
        }
        var scriptName: String?
        if !recorder.isEmpty {
            do {
                for v in recorder.variables { try Variables.shared.set(v) }
                Scripts.prepareFolder()
                let url = Scripts.folder.appendingPathComponent("sign-in-" + SignInRecorder.tag(app).lowercased().replacingOccurrences(of: "_", with: "-") + ".sh")
                try Data(recorder.script(app: app).utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                scriptName = url.lastPathComponent
            } catch {
                workbench.toast.show("The sign-in is kept, but its script could not be saved: \(error.localizedDescription)", problem: true)
            }
        }
        SignIns.shared.set(SignIns.Record(slot: kept, date: Date(), script: scriptName), key: key)
        workbench.toast.show("Sign-in kept: walks of \(app) now start signed in" + (scriptName.map { ". Recorded as \($0)" } ?? ""), problem: false)
        end(kept: true)
    }

    private func end(kept: Bool) {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        sim?.onPerform = nil
        if let p = panel { p.parent?.removeChildWindow(p); p.orderOut(nil) }
        panel = nil
        if !kept { SlotClone.remove(slot, in: SignIns.dataRoot) }
        SignInOnce.current = nil
        done(kept)
    }
}
