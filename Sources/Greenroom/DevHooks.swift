import AppKit
import UniformTypeIdentifiers

/// Developer launch hooks: relaunch the chosen simulator with adb, a debugger or a traffic recording, run it against
/// a recorded HAR, and reload it when a build folder gets a new APK. Everything here is a relaunch of the same APK
/// with the same options and data (never `--fresh`), in the same place on the stage.
final class DevHooks {
    static let shared = DevHooks()

    private(set) weak var workbench: Workbench?
    private let card = DevCard()
    /// The adb port each simulator announced (`adb device on localhost:PORT` in its log).
    private var adbPorts: [ObjectIdentifier: Int] = [:]
    private var wantAdbCard = Set<ObjectIdentifier>()
    private var logWatchers: [ObjectIdentifier: LogWatcher] = [:]
    private var watcher: BuildWatcher?
    private(set) var watchLabel: String?
    /// Told when a recorded HAR was read back after its simulator ended (scripted checks).
    var onHarReport: ((String) -> Void)?
    /// Told after each reload a build watch made, with the simulators it started.
    var onReload: ((String, [Simulator]) -> Void)?

    // MARK: Install

    func install(workbench: Workbench, in stack: NSView, over grid: NSView) {
        self.workbench = workbench
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: grid.centerXAnchor),
            card.bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: -16),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: grid.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(lessThanOrEqualTo: grid.trailingAnchor, constant: -16),
        ])
    }

    // MARK: Options

    /// Launch options that carry one of the hooks, with how many words each takes.
    private static let managed: [String: Int] = ["--adb": 1, "--debug": 1, "--network": 2]

    static func without(_ flags: Set<String>, from options: [String]) -> [String] {
        var out: [String] = []
        var rest = ArraySlice(options)
        while let o = rest.popFirst() {
            if flags.contains(o) { rest.removeFirst(min(managed[o] ?? 1, rest.count)) } else { out.append(o) }
        }
        return out
    }

    static func value(_ flag: String, in options: [String], at offset: Int = 1) -> String? {
        guard let i = options.firstIndex(of: flag), i + offset < options.count else { return nil }
        return options[i + offset]
    }

    static func har(of sim: Simulator) -> (mode: String, file: URL)? {
        guard let i = sim.options.firstIndex(of: "--network"), i + 2 < sim.options.count,
              ["record", "replay"].contains(sim.options[i + 1]) else { return nil }
        return (sim.options[i + 1], URL(fileURLWithPath: sim.options[i + 2]))
    }

    static func debugPort(of sim: Simulator) -> Int? { value("--debug", in: sim.options).flatMap { Int($0) } }
    static func hasADB(_ sim: Simulator) -> Bool { sim.options.contains("--adb") }
    func adbPort(of sim: Simulator) -> Int? { adbPorts[ObjectIdentifier(sim)] }

    // MARK: Relaunching

    private var jobs: [(@escaping () -> Void) -> Void] = []
    private var busy = false

    /// Starts `apk` (default: the simulator's own) with `options` in place of `old`, once `old` has quit and let go of
    /// its data: so the new one finds the same data, and takes the old one's place on the stage and its selection.
    /// Relaunches run one at a time, so several simulators never swap data slots.
    func relaunch(_ old: Simulator, apk: URL? = nil, options: [String], then: ((Simulator?) -> Void)? = nil) {
        enqueue { [weak self] done in
            guard let self, let wb = self.workbench else { done(); then?(nil); return }
            let wasChosen = wb.selected === old
            let chosen = wb.selected
            old.quit()
            DispatchQueue.global(qos: .userInitiated).async {
                old.waitUntilExit()
                DispatchQueue.main.async {
                    defer { done() }
                    guard let new = wb.open(apk ?? old.apk, remember: false, options: options) else { then?(nil); return }
                    Engine.shared.replace(old, with: new)
                    wb.matrixReplaced(old, with: new)
                    wb.select(wasChosen ? new : (chosen.map { c in Engine.shared.simulators.contains(where: { $0 === c }) ? c : new } ?? new))
                    self.adopt(new)
                    then?(new)
                }
            }
        }
    }

    private func enqueue(_ job: @escaping (@escaping () -> Void) -> Void) {
        jobs.append(job)
        if !busy { next() }
    }

    private func next() {
        guard !jobs.isEmpty else { busy = false; return }
        busy = true
        let job = jobs.removeFirst()
        job { [weak self] in self?.next() }
    }

    /// What a new simulator needs from here: its ended state read for a recording, and its adb port.
    private func adopt(_ sim: Simulator) {
        let id = ObjectIdentifier(sim)
        let previous = sim.onState
        sim.onState = { [weak self, weak sim] state in
            previous?(state)
            if case .ended = state, let sim { self?.ended(sim) }
        }
        if Self.hasADB(sim) {
            let w = LogWatcher(file: sim.log, pattern: #"adb device on localhost:(\d+)"#)
            logWatchers[id] = w
            w.onMatch = { [weak self] digits in
                guard let self else { return }
                self.logWatchers[id] = nil
                guard let port = Int(digits) else { return }
                self.adbPorts[id] = port
                if self.wantAdbCard.remove(id) != nil { self.showADB(port) }
            }
            w.start()
        }
    }

    private func ended(_ sim: Simulator) {
        let id = ObjectIdentifier(sim)
        adbPorts[id] = nil
        logWatchers[id]?.stop(); logWatchers[id] = nil
        wantAdbCard.remove(id)
        if let (mode, file) = Self.har(of: sim), mode == "record" { reportHAR(file) }
    }

    // MARK: adb

    func connectADB(_ sim: Simulator) {
        if Self.hasADB(sim) {
            if let port = adbPort(of: sim) { showADB(port) } else { wantAdbCard.insert(ObjectIdentifier(sim)); say("adb is starting…") }
            return
        }
        say("Restarting \(sim.name) with adb…")
        relaunch(sim, options: sim.options + ["--adb", "auto"]) { [weak self] new in
            guard let self, let new else { return }
            if let port = self.adbPort(of: new) { self.showADB(port) } else { self.wantAdbCard.insert(ObjectIdentifier(new)) }
        }
    }

    func stopADB(_ sim: Simulator) {
        card.hide()
        relaunch(sim, options: Self.without(["--adb"], from: sim.options)) { [weak self] _ in self?.say("adb is off") }
    }

    private func showADB(_ port: Int) {
        let command = "adb connect localhost:\(port)"
        card.show(symbol: "cable.connector", title: "adb is on", detail: command + "\nthen: adb -s localhost:\(port) shell", copy: command)
    }

    // MARK: Debugger

    func attachDebugger(_ sim: Simulator) {
        if let port = Self.debugPort(of: sim) { showDebugger(port); return }
        guard let port = Self.freePort() else { say("No free port for the debugger", problem: true); return }
        say("Restarting \(sim.name) with a debugger…")
        relaunch(sim, options: sim.options + ["--debug", String(port)]) { [weak self] new in if new != nil { self?.showDebugger(port) } }
    }

    func detachDebugger(_ sim: Simulator) {
        card.hide()
        relaunch(sim, options: Self.without(["--debug"], from: sim.options)) { [weak self] _ in self?.say("Debugger detached") }
    }

    private func showDebugger(_ port: Int) {
        card.show(symbol: "ladybug", title: "Debugger on localhost:\(port)",
                  detail: "Android Studio or IntelliJ: Run > Edit Configurations > + > Remote JVM Debug,\nHost localhost, Port \(port), then Debug. The app does not wait for it.",
                  copy: "localhost:\(port)")
    }

    // MARK: Traffic

    func record(_ sim: Simulator, to file: URL) {
        say("Restarting \(sim.name) to record its traffic…")
        relaunch(sim, options: Self.without(["--network"], from: sim.options) + ["--network", "record", file.path]) { [weak self, weak sim] new in
            guard let self, new != nil else { return }
            self.showRecording(file, sim: new ?? sim)
        }
    }

    func replay(_ sim: Simulator, from file: URL) {
        // The engine's sandbox cannot read ~/Documents or ~/Desktop: it gets a copy in its own state folder.
        let dir = Engine.shared.engineState.appendingPathComponent("hars/\(UUID().uuidString.prefix(8))", isDirectory: true)
        let copy = dir.appendingPathComponent(file.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.copyItem(at: file, to: copy)
        } catch { say("Cannot read \(file.lastPathComponent): \(error.localizedDescription)", problem: true); return }
        say("Restarting \(sim.name) against \(file.lastPathComponent)…")
        relaunch(sim, options: Self.without(["--network"], from: sim.options) + ["--network", "replay", copy.path]) { [weak self] new in
            guard let self, new != nil else { return }
            self.card.show(symbol: "play.circle", title: "Running against \(file.lastPathComponent)",
                           detail: "Every request is answered from the file; nothing leaves this Mac.\nA request the file lacks gets a 599.", copy: nil)
        }
    }

    func stopHAR(_ sim: Simulator) {
        card.hide()
        let recording = Self.har(of: sim)?.mode == "record"
        relaunch(sim, options: Self.without(["--network"], from: sim.options)) { [weak self] _ in
            self?.say(recording ? "Stopped recording" : "Stopped replaying")
        }
    }

    func saveHARNow(_ sim: Simulator) {
        sim.send("network save") { [weak self] answer in
            let problem = answer.hasPrefix("error")
            self?.say(problem ? answer.replacingOccurrences(of: "error: ", with: "") : "Saved \(Self.har(of: sim)?.file.lastPathComponent ?? "the HAR")", problem: problem)
        }
    }

    private func showRecording(_ file: URL, sim: Simulator?) {
        card.show(symbol: "record.circle", title: "Recording traffic to \(file.lastPathComponent)",
                  detail: "The file is written when this simulator closes or restarts.",
                  copy: nil, action: sim.map { s in ("Save now", { [weak self, weak s] in if let s { self?.saveHARNow(s) } }) })
    }

    private func reportHAR(_ file: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var text = "", problem = false
            if let data = try? Data(contentsOf: file, options: .mappedIfSafe),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let entries = (json["log"] as? [String: Any])?["entries"] as? [Any] {
                text = "Saved \(file.lastPathComponent): \(entries.count) request\(entries.count == 1 ? "" : "s")"
            } else {
                text = "\(file.lastPathComponent) was not written"; problem = true
            }
            DispatchQueue.main.async {
                self?.say(text, problem: problem)
                self?.onHarReport?(text)
            }
        }
    }

    // MARK: Build folder

    func watch(folder: URL, name: String?) {
        stopWatch(quietly: true)
        let w = BuildWatcher(folder: folder, name: name)
        w.onBuild = { [weak self] apk in self?.built(apk) }
        guard w.start() else { say("Cannot watch \(folder.lastPathComponent)", problem: true); return }
        watcher = w
        watchLabel = (name ?? "any .apk") + " in " + folder.lastPathComponent
        say("Watching \(watchLabel!)")
        card.show(symbol: "eye", title: "Watching \(folder.lastPathComponent)",
                  detail: (name ?? "Any APK") + " rebuilt there reloads the simulator that runs it, with its options and data.",
                  copy: nil, action: ("Stop watching", { [weak self] in self?.stopWatch() }))
    }

    func stopWatch(quietly: Bool = false) {
        guard watcher != nil else { return }
        watcher?.stop(); watcher = nil; watchLabel = nil
        if !quietly { card.hide(); say("Stopped watching the build folder") }
    }

    /// A new APK settled in the watched folder: the simulators running a file of that name restart on it.
    private func built(_ apk: URL) {
        let name = apk.lastPathComponent
        let sims = Engine.shared.simulators.filter { $0.apk.lastPathComponent == name }
        guard !sims.isEmpty else { say("\(name) was rebuilt; no simulator runs it"); return }
        var started: [Simulator] = []
        for (i, sim) in sims.enumerated() {
            relaunch(sim, apk: apk, options: sim.options) { [weak self] new in
                if let new { started.append(new) }
                guard i == sims.count - 1 else { return }
                if started.isEmpty { self?.say("Could not reload \(name)", problem: true); return }
                self?.say("Reloaded \(name)" + (started.count > 1 ? " on \(started.count) devices" : ""))
                self?.onReload?(name, started)
            }
        }
    }

    // MARK: Menu and palette

    private struct Entry {
        var title: String
        var symbol: String
        var on = false
        var enabled = true
        var separatorBefore = false
        var run: () -> Void
    }

    private func entries(for sim: Simulator?) -> [Entry] {
        var out: [Entry] = []
        if let sim {
            if Self.hasADB(sim) {
                let port = adbPort(of: sim)
                out.append(Entry(title: port.map { "adb connect localhost:\($0)" } ?? "adb is starting…", symbol: "cable.connector", on: true, enabled: port != nil) { [weak self] in self?.connectADB(sim) })
                out.append(Entry(title: "Turn adb off", symbol: "cable.connector.slash") { [weak self] in self?.stopADB(sim) })
            } else {
                out.append(Entry(title: "Connect adb", symbol: "cable.connector") { [weak self] in self?.connectADB(sim) })
            }
            if let port = Self.debugPort(of: sim) {
                out.append(Entry(title: "Debugger on localhost:\(port)", symbol: "ladybug", on: true) { [weak self] in self?.attachDebugger(sim) })
                out.append(Entry(title: "Detach the debugger", symbol: "ladybug.slash") { [weak self] in self?.detachDebugger(sim) })
            } else {
                out.append(Entry(title: "Attach a debugger", symbol: "ladybug") { [weak self] in self?.attachDebugger(sim) })
            }
            let har = Self.har(of: sim)
            if let har, har.mode == "record" {
                out.append(Entry(title: "Recording to \(har.file.lastPathComponent): save now", symbol: "record.circle", on: true, separatorBefore: true) { [weak self] in self?.saveHARNow(sim) })
                out.append(Entry(title: "Stop recording", symbol: "stop.circle") { [weak self] in self?.stopHAR(sim) })
            } else if let har {
                out.append(Entry(title: "Running against \(har.file.lastPathComponent)", symbol: "play.circle", on: true, separatorBefore: true) { })
                out.append(Entry(title: "Stop running against the HAR", symbol: "stop.circle") { [weak self] in self?.stopHAR(sim) })
            }
            out.append(Entry(title: "Record traffic to a HAR…", symbol: "record.circle", separatorBefore: har == nil) { [weak self] in self?.chooseRecordFile(sim) })
            out.append(Entry(title: "Run against a HAR…", symbol: "play.circle") { [weak self] in self?.chooseReplayFile(sim) })
        }
        if let label = watchLabel {
            out.append(Entry(title: "Watching \(label): stop", symbol: "eye", on: true, separatorBefore: true) { [weak self] in self?.stopWatch() })
        } else {
            out.append(Entry(title: "Watch a build folder…", symbol: "eye", separatorBefore: sim != nil) { [weak self] in self?.chooseBuildFolder(for: sim) })
        }
        return out
    }

    func submenuItem(for sim: Simulator?) -> NSMenuItem {
        let item = NSMenuItem(title: "Developer", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "hammer", accessibilityDescription: nil)
        let menu = NSMenu()
        for e in entries(for: sim) {
            if e.separatorBefore, !menu.items.isEmpty { menu.addItem(.separator()) }
            let m = ActionItem(title: e.title, handler: e.run)
            m.state = e.on ? .on : .off
            m.isEnabled = e.enabled
            m.image = NSImage(systemSymbolName: e.symbol, accessibilityDescription: nil)
            menu.addItem(m)
        }
        item.submenu = menu
        return item
    }

    func paletteItems(for sim: Simulator?) -> [PaletteItem] {
        entries(for: sim).enumerated().map { i, e in
            PaletteItem(id: "dev.\(i).\(e.title)", title: e.title, group: "Developer", symbol: e.symbol,
                        keywords: "developer adb debugger debug har traffic record replay build watch reload gradle", run: e.run)
        }
    }

    // MARK: Panels

    func chooseRecordFile(_ sim: Simulator) {
        guard let window = workbench?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json]
        panel.nameFieldStringValue = sim.name + ".har"
        panel.message = "Where to save \(sim.name)'s traffic. The file stays on this Mac."
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.record(sim, to: url)
        }
    }

    func chooseReplayFile(_ sim: Simulator) {
        guard let window = workbench?.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .json, .json]
        panel.message = "Choose a recorded HAR to answer \(sim.name)'s requests from"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.replay(sim, from: url)
        }
    }

    func chooseBuildFolder(for sim: Simulator?) {
        guard let window = workbench?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = sim.map { "Choose the folder your build writes \($0.apk.lastPathComponent) to" } ?? "Choose a build folder to watch"
        panel.prompt = "Watch"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.watch(folder: url, name: sim?.apk.lastPathComponent)
        }
    }

    // MARK: Helpers

    private func say(_ text: String, problem: Bool = false) { workbench?.toast.show(text, problem: problem) }

    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return got == 0 ? Int(UInt16(bigEndian: addr.sin_port)) : nil
    }

    /// Whether something accepts a connection on 127.0.0.1:port.
    static func listens(on port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { handler() }
}

/// Waits for a line of a simulator's log to match, by file events: no polling. One match, then it stops.
final class LogWatcher {
    private let file: URL
    private let regex: NSRegularExpression
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private let queue = DispatchQueue(label: "greenroom-logwatch", qos: .utility)
    var onMatch: ((String) -> Void)?

    init(file: URL, pattern: String) {
        self.file = file
        regex = try! NSRegularExpression(pattern: pattern)
    }

    func start() {
        let fd = open(file.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
        s.setEventHandler { [weak self] in self?.scan() }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
        queue.async { [weak self] in self?.scan() }
    }

    func stop() { source?.cancel(); source = nil }

    private func scan() {
        guard let h = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        let text = String(decoding: data, as: UTF8.self)
        if let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
           let r = Range(m.range(at: 1), in: text) {
            let found = String(text[r])
            source?.cancel(); source = nil
            DispatchQueue.main.async { [weak self] in self?.onMatch?(found) }
        }
    }
}

/// A small glass card over the stage: what a hook switched on, what to type or click next, and a Copy button.
final class DevCard: NSView {
    private let glass = GlassView(radius: 14)
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let copy: GlassButton
    private let action: GlassButton
    private let close: GlassButton
    private var copyText = ""
    private var actionHandler: (() -> Void)?
    private var reset: Timer?

    override init(frame: NSRect) {
        copy = GlassButton(symbol: "doc.on.doc", title: "Copy", label: "Copy", style: .well, target: nil, action: nil)
        action = GlassButton(symbol: nil, title: "Do", label: "Action", style: .well, target: nil, action: nil)
        close = GlassButton(symbol: "xmark", label: "Dismiss", style: .plain, target: nil, action: nil)
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        appearance = NSAppearance(named: .darkAqua)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Design.ink
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = Design.mute
        detail.isSelectable = true
        detail.maximumNumberOfLines = 4
        icon.contentTintColor = Design.accent
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        copy.onPress = { [weak self] in self?.copied() }
        action.onPress = { [weak self] in self?.actionHandler?() }
        close.onPress = { [weak self] in self?.hide() }
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let buttons = NSStackView(views: [copy, action, close])
        buttons.spacing = 6
        let row = NSStackView(views: [icon, text, buttons])
        row.spacing = 12
        row.alignment = .centerY
        for v in [glass, row] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        icon.setContentHuggingPriority(.required, for: .horizontal)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor), glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(symbol: String, title: String, detail: String, copy text: String?, action: (String, () -> Void)? = nil) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.title.stringValue = title
        self.detail.stringValue = detail
        copyText = text ?? ""
        copy.isHidden = text == nil
        copy.title = "Copy"
        self.action.isHidden = action == nil
        if let action { self.action.title = action.0; actionHandler = action.1 }
        let wasHidden = isHidden
        isHidden = false
        if wasHidden { alphaValue = 0 }
        Design.animate(Design.arrive, { self.animator().alphaValue = 1 })
    }

    func hide() {
        guard !isHidden else { return }
        Design.animate(Design.arrive, { self.animator().alphaValue = 0 }, done: { if self.alphaValue == 0 { self.isHidden = true } })
    }

    private func copied() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        copy.title = "Copied"
        reset?.invalidate()
        reset = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.copy.title = "Copy" }
    }
}
