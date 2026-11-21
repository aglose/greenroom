import Foundation

/// The bundled apksim release: where it is, where its state goes, and how an APK is launched with it.
/// Greenroom never reads an APK itself; it hands the path to the engine, which runs it locally.
final class Engine {
    static let shared = Engine()
    /// Launched by scripts/mcp-check.py: its GREENROOM_STATE, GREENROOM_ADD_REPOSITORY and GREENROOM_CHECK_FEEDS count.
    static let agentCheck = CommandLine.arguments.contains("--agent-check")

    /// The engine's folder: `Contents/Resources/engine` in the app, or `GREENROOM_ENGINE` for a development run.
    let root: URL
    /// Everything the engine writes (caches, app data, logs). Private to the user.
    let state: URL

    private(set) var running: [Instance] = []
    /// The simulators shown in the workbench, oldest first. Ended ones stay until closed.
    private(set) var simulators: [Simulator] = []
    var onChange: (() -> Void)?

    final class Instance {
        let apk: URL
        let process: Process
        let log: URL
        init(apk: URL, process: Process, log: URL) { self.apk = apk; self.process = process; self.log = log }
    }

    enum Failure: LocalizedError {
        case engineMissing(URL)
        case notAnApk(URL)
        var errorDescription: String? {
            switch self {
            case .engineMissing(let u): return "The simulator engine is missing from this copy of Greenroom (\(u.path))."
            case .notAnApk(let u): return "\(u.lastPathComponent) is not an APK."
            }
        }
    }

    private init() {
        if let dev = ProcessInfo.processInfo.environment["GREENROOM_ENGINE"], !dev.isEmpty {
            root = URL(fileURLWithPath: dev)
        } else {
            root = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("engine")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // GREENROOM_STATE: another state folder, for checks that must not touch (or meet) the person's own. Only
        // with --agent-check on the command line (scripts/mcp-check.py passes it): never from the environment alone.
        if Engine.agentCheck, let other = ProcessInfo.processInfo.environment["GREENROOM_STATE"], other.hasPrefix("/") {
            state = URL(fileURLWithPath: other, isDirectory: true)
        } else if let (flag, i) = ["--evidence-check", "--changes-check"].compactMap({ f in CommandLine.arguments.firstIndex(of: f).map { (f, $0) } }).first,
                  i + 2 < CommandLine.arguments.count {
            // `--evidence-check DIR APK` (and `--changes-check`) keep their whole state (store, engine, app data) in
            // DIR/evidence-check/engine-state (DIR/changes-check/engine-state).
            state = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true).resolvingSymlinksInPath()
                .appendingPathComponent(flag.dropFirst(2).replacingOccurrences(of: "-check", with: "") + "-check/engine-state", isDirectory: true)
        } else {
            state = support.appendingPathComponent("Greenroom", isDirectory: true)
        }
    }

    var launcher: URL { root.appendingPathComponent("apksim") }

    var version: String {
        let v = try? String(contentsOf: root.appendingPathComponent("work/release"), encoding: .utf8)
        return v?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }

    /// Creates the state folder readable by the user alone, and puts the bundled training app where the engine
    /// looks for it, so the engine's first run downloads nothing.
    func prepare() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: launcher.path) else { throw Failure.engineMissing(launcher) }
        for dir in [state, engineState, logs] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        if simulators.isEmpty {   // tokens of simulators from an earlier run of the app: nothing answers to them now
            try? fm.removeItem(at: engineState.appendingPathComponent("tokens", isDirectory: true))
        }
        let bundled = root.deletingLastPathComponent().appendingPathComponent("engine-testapp.apk")
        let wanted = engineState.appendingPathComponent("testapp-\(version).apk")
        if fm.fileExists(atPath: bundled.path), !fm.fileExists(atPath: wanted.path) {
            try fm.copyItem(at: bundled, to: wanted)
        }
    }

    /// Whether this engine has `--control-token-file` (apksim after 0.53.0): its control channel then answers
    /// only this app. Older engines answer any program on this Mac.
    private(set) lazy var supportsControlToken: Bool = {
        (try? String(contentsOf: launcher, encoding: .utf8))?.contains("--control-token-file") ?? false
    }()

    var engineState: URL { state.appendingPathComponent("engine", isDirectory: true) }
    var logs: URL { state.appendingPathComponent("logs", isDirectory: true) }

    /// Starts the APK in a simulator of its own. `options` are apksim launch options placed before the APK.
    @discardableResult
    func launch(apk: URL, options: [String] = [], onExit: ((Int32) -> Void)? = nil) throws -> Instance {
        guard apk.pathExtension.lowercased() == "apk" else { throw Failure.notAnApk(apk) }
        try prepare()
        let log = logs.appendingPathComponent("instance-\(Int(Date().timeIntervalSince1970 * 1000)).log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: log)

        let p = Process()
        p.executableURL = launcher
        p.arguments = options + [apk.path]
        var env = ProcessInfo.processInfo.environment
        env["APKSIM_HOME"] = engineState.path
        p.environment = env
        p.currentDirectoryURL = engineState
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice

        let instance = Instance(apk: apk, process: p, log: log)
        p.terminationHandler = { [weak self] proc in
            try? out.close()
            DispatchQueue.main.async {
                self?.running.removeAll { $0 === instance }
                self?.onChange?()
                onExit?(proc.terminationStatus)
            }
        }
        try p.run()
        running.append(instance)
        onChange?()
        return instance
    }

    /// Starts the APK headless for the workbench: its screen is streamed to the app and drawn there.
    func open(apk: URL, options: [String] = []) throws -> Simulator {
        guard apk.pathExtension.lowercased() == "apk" else { throw Failure.notAnApk(apk) }
        try prepare()
        let log = logs.appendingPathComponent("simulator-\(Int(Date().timeIntervalSince1970 * 1000)).log")
        let sim = Simulator(apk: apk, log: log)
        // The network inspector reads the app's own connections as they pass (no proxy, nothing changed), so the
        // network pane and timeline have the requests from the first one on.
        let inspect = options.contains("--network-inspect") ? options : options + ["--network-inspect"]
        try sim.start(launcher: launcher, stateDir: engineState, options: inspect, controlToken: supportsControlToken)
        simulators.append(sim)
        onChange?()
        return sim
    }

    /// Puts `new` where `old` stood in the list and drops `old` (a relaunch keeps its place on the stage).
    func replace(_ old: Simulator, with new: Simulator) {
        if let at = simulators.firstIndex(where: { $0 === old }) {
            simulators.removeAll { $0 === new }
            simulators.insert(new, at: min(at, simulators.count))
            simulators.removeAll { $0 === old }
        }
        onChange?()
    }

    /// Simulators taken off the stage whose process has not exited yet: until it has, it still holds its data slot.
    private(set) var closing: [Simulator] = []

    func close(_ sim: Simulator) {
        ScreenRecording.shared.finishSync(sim)   // a recording of it ends here, as a finished file
        sim.quit()
        simulators.removeAll { $0 === sim }
        closing.append(sim)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            sim.waitUntilExit()
            DispatchQueue.main.async { self?.closing.removeAll { $0 === sim } }
        }
        onChange?()
    }

    var screenshots: URL { engineState.appendingPathComponent("screenshots", isDirectory: true) }

    /// Asks every simulator to quit (SIGTERM: the engine's client passes it on) and stops the engine's standbys.
    func stopAll() {
        for i in running where i.process.isRunning { i.process.terminate() }
        for s in simulators { s.quit() }
        let p = Process()
        p.executableURL = launcher
        p.arguments = ["--stop-standbys"]
        var env = ProcessInfo.processInfo.environment
        env["APKSIM_HOME"] = engineState.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        // Bounded: this runs as the app quits, and quitting must not hang on the engine.
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning, Date() < deadline { usleep(50_000) }
    }
}
