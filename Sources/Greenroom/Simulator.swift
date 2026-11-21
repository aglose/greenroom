import AVFoundation
import Foundation

/// One running APK: the engine process (headless), its control channel and its screen stream.
/// The picture is shown by whoever sets `onSample`; input goes back through `control`.
final class Simulator {
    enum State: Equatable {
        case starting
        case running
        case ended(Int32)
    }

    let apk: URL
    let log: URL
    private(set) var state: State = .starting { didSet { if state != oldValue { onState?(state) } } }
    private(set) var control: ControlChannel?
    private(set) var deviceSize = CGSize.zero
    private(set) var framesShown = 0

    /// Each decodable frame, on the frame reader's thread.
    var onSample: ((CMSampleBuffer) -> Void)?
    /// Called on the main thread.
    var onState: ((State) -> Void)?
    var onSize: ((CGSize) -> Void)?

    private let process = Process()
    private var frames: FrameChannel?
    private let decoder = VideoDecoder()
    private var logHandle: FileHandle?
    private var pendingOutput = Data()
    private var port: Int?
    /// The control channel's token, when the engine can be told to want one (Engine.supportsControlToken).
    private var token: String?
    private var tokenFile: URL?

    /// What an agent was last told is on this screen, and the references it holds.
    let tree = ScreenTree()
    /// Touches, frames, requests and log lines, for the timeline and the network pane.
    let activity = Activity()
    private var netFeed: NetFeed?
    /// Whether other programs on this Mac are kept off this simulator's control channel.
    var isPrivate: Bool { token != nil }
    /// How much of the log an agent has already been given.
    var logOffset: UInt64 = 0
    /// The launch options this simulator was started with (shown to agents).
    private(set) var options: [String] = []

    var name: String { apk.deletingPathExtension().lastPathComponent }
    var isAlive: Bool { if case .ended = state { return false }; return true }

    init(apk: URL, log: URL) {
        self.apk = apk
        self.log = log
    }

    /// Starts the engine headless with a control port of its choosing, and connects once it names the port.
    func start(launcher: URL, stateDir: URL, options: [String], controlToken: Bool = false) throws {
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        logHandle = try FileHandle(forWritingTo: log)

        let pipe = Pipe()
        process.executableURL = launcher
        var control = ["--headless", "--control", "auto"]
        if controlToken {
            // A token only this app and the engine know: no other program on this Mac can drive the simulator.
            var bytes = [UInt8](repeating: 0, count: 24)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let made = bytes.map { String(format: "%02x", $0) }.joined()
            let dir = stateDir.appendingPathComponent("tokens", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = dir.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: file.path, contents: Data(made.utf8), attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            token = made
            tokenFile = file
            control += ["--control-token-file", file.path]
        }
        process.arguments = control + options + [apk.path]
        self.options = options
        var env = ProcessInfo.processInfo.environment
        env["APKSIM_HOME"] = stateDir.path
        env["APKSIM_LOGCAT"] = "1"   // the app's android.util.Log lines go to the simulator's log file
        process.environment = env
        process.currentDirectoryURL = stateDir
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.logHandle?.write(data)
            self.activity.logged(data)
            self.scan(data)
        }
        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                try? self.logHandle?.close()
                if let file = self.tokenFile { try? FileManager.default.removeItem(at: file) }
                self.frames?.close()
                self.control?.close()
                self.netFeed?.close()
                self.state = .ended(proc.terminationStatus)
                Reports.shared.engineEnded(status: proc.terminationStatus)
            }
        }
        try process.run()
    }

    /// The engine prints `[apksim] control port N` on stderr once the channel is open.
    private func scan(_ data: Data) {
        guard port == nil else { return }
        pendingOutput.append(data)
        guard let text = String(data: pendingOutput, encoding: .utf8),
              let range = text.range(of: #"control port (\d+)"#, options: .regularExpression) else {
            if pendingOutput.count > 1 << 20 { pendingOutput.removeAll() }
            return
        }
        let digits = text[range].split(separator: " ").last.flatMap { Int($0) }
        pendingOutput.removeAll()
        guard let digits else { return }
        port = digits
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.connect(port: digits) }
    }

    private func connect(port: Int) {
        guard let control = ControlChannel(port: port, token: token),
              let frames = FrameChannel(port: port, kbps: 24_000, token: token) else {
            DispatchQueue.main.async { [weak self] in self?.process.terminate() }
            return
        }
        frames.onFrame = { [weak self] frame in
            guard let self else { return }
            let size = CGSize(width: frame.width, height: frame.height)
            if size != self.deviceSize {
                self.deviceSize = size
                DispatchQueue.main.async { self.onSize?(size); Engine.shared.onChange?() }
            }
            if let sample = self.decoder.sampleBuffer(for: frame) {
                self.framesShown += 1
                self.activity.frameShown()
                self.onSample?(sample)
            } else {
                frames.requestKeyframe()
            }
        }
        self.frames = frames
        // The app's requests, when the engine was started with its network inspector (a third connection; none otherwise).
        if options.contains("--network-inspect"), let feed = NetFeed(port: port, token: token) {
            netFeed = feed
            feed.start(into: activity)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.control = control
            self.state = .running
            frames.start()
            control.send("redraw")   // a frame for the new subscriber, even if the screen is still
        }
    }

    func requestKeyframe() { frames?.requestKeyframe() }

    func send(_ command: String, reply: ((String) -> Void)? = nil) {
        guard let control else { reply?("error: the simulator is still starting"); return }
        control.send(command, reply: reply)
    }

    /// Sends a command and waits for its answer. Never on the main thread (answers are delivered there).
    func sendSync(_ command: String, timeout: TimeInterval = 30) -> String {
        precondition(!Thread.isMainThread)
        let done = DispatchSemaphore(value: 0)
        var answer = "error: no answer within \(Int(timeout)) s"
        DispatchQueue.main.async { self.send(command) { answer = $0; done.signal() } }
        _ = done.wait(timeout: .now() + timeout)
        return answer
    }

    /// Text as typed, spaces and all.
    func type(_ text: String) {
        send("type64 " + Data(text.utf8).base64EncodedString())
    }

    func quit() {
        guard process.isRunning else { return }
        if control != nil { send("quit") } else { process.terminate() }
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
    }

    func waitUntilExit() { process.waitUntilExit() }
}
