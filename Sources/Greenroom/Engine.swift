import Foundation

/// The bundled apksim release: where it is, where its state goes, and how an APK is launched with it.
/// Greenroom never reads an APK itself; it hands the path to the engine, which runs it locally.
final class Engine {
    static let shared = Engine()

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
        state = support.appendingPathComponent("Greenroom", isDirectory: true)
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
        let bundled = root.deletingLastPathComponent().appendingPathComponent("engine-testapp.apk")
        let wanted = engineState.appendingPathComponent("testapp-\(version).apk")
        if fm.fileExists(atPath: bundled.path), !fm.fileExists(atPath: wanted.path) {
            try fm.copyItem(at: bundled, to: wanted)
        }
    }

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
        try sim.start(launcher: launcher, stateDir: engineState, options: options)
        simulators.append(sim)
        onChange?()
        return sim
    }

    func close(_ sim: Simulator) {
        sim.quit()
        simulators.removeAll { $0 === sim }
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
        try? p.run()
        p.waitUntilExit()
    }
}
