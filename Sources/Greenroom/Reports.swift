import AppKit
import Darwin
import MachO

/// Opt-in crash reports and usage statistics (PRIVACY.md). Both are off until the customer turns them on: asked once,
/// in a sheet after the first launch; dismissing it leaves them off; Settings > Privacy changes them and shows the
/// exact reports waiting to be sent.
///
/// What a report can hold is fixed by its types, so nothing from an APK can reach one:
/// - every report: Greenroom's version and build, the engine's version, macOS's version, the day (no time, no
///   identifier of the Mac or the customer);
/// - usage: counts of `Feature` cases, an enum of Greenroom's own features (never a string from outside);
/// - a crash of Greenroom itself: the signal and the return addresses inside Greenroom's own executable, as offsets
///   from its start (symbolicated with that build's symbols; frames in system libraries are dropped);
/// - an unexpected engine exit: its exit status only (no log, no stack: those name the tested app's code). An app's own
///   crash (status 10) is the customer's, not ours, and is never reported.
///
/// Reports wait in `STATE/reports/outbox` (JSON, one per file, at most 50). They are sent to the URL in Info.plist's
/// `GreenroomReportsURL` (or `GREENROOM_REPORTS_URL`, for checks) once a day; with no URL, nothing is sent and they
/// only wait, readable in Settings.
final class Reports {
    static let shared = Reports()

    enum Feature: String, CaseIterable {
        case apkOpened, simulatorLaunched, sideBySide, mirror, compare, screenshot, recording, palette
        case paneDevice, paneNetwork, paneTests, paneDiagnostics, paneRecordings, timeline, inspector, log
        case snapshots, screenMap, agentTool
    }

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var counts: [Feature: Int] = [:]
    var crashes: Bool { get { defaults.bool(forKey: "reports.crashes") } set { defaults.set(newValue, forKey: "reports.crashes") } }
    var usage: Bool { get { defaults.bool(forKey: "reports.usage") } set { defaults.set(newValue, forKey: "reports.usage") } }
    var asked: Bool { get { defaults.bool(forKey: "reports.asked") } set { defaults.set(newValue, forKey: "reports.asked") } }

    var folder: URL { Engine.shared.state.appendingPathComponent("reports", isDirectory: true) }
    var outbox: URL { folder.appendingPathComponent("outbox", isDirectory: true) }
    private var pendingCrash: URL { folder.appendingPathComponent("crash.pending") }
    private var usageFile: URL { folder.appendingPathComponent("usage.json") }

    var endpoint: URL? {
        let env = ProcessInfo.processInfo.environment["GREENROOM_REPORTS_URL"] ?? ""
        let plist = Bundle.main.object(forInfoDictionaryKey: "GreenroomReportsURL") as? String ?? ""
        let s = env.isEmpty ? plist : env
        guard let url = URL(string: s), url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" else { return nil }
        return url
    }

    // MARK: start

    /// At launch: the crash handlers armed, a crash left by the last run turned into a report (if crash reports are
    /// on; else dropped), yesterday's usage sealed into a report (if on), and the outbox sent.
    func start() {
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        collectCrash()
        loadUsage()
        sealUsage(before: Self.today)
        armCrashHandlers(path: pendingCrash.path)
        send()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.saveUsage(); self?.sealUsage(before: Self.today); self?.send()
        }
    }

    func count(_ f: Feature) {
        guard usage else { return }
        lock.lock(); counts[f, default: 0] += 1; lock.unlock()
    }

    /// A simulator's engine ended. Only statuses that point at the engine are kept.
    func engineEnded(status: Int32) {
        guard crashes, ![0, 10, 130, 137, 143, 15, 9].contains(status) else { return }
        write(report(kind: "engine-exit", body: ["status": Int(status)]))
    }

    func saveUsage() {
        lock.lock(); let c = counts; lock.unlock()
        guard usage, !c.isEmpty else { return }
        let body: [String: Any] = ["day": Self.today, "counts": Dictionary(uniqueKeysWithValues: c.map { ($0.key.rawValue, $0.value) })]
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) { try? data.write(to: usageFile) }
    }

    private func loadUsage() {
        guard let data = try? Data(contentsOf: usageFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (json["day"] as? String) == Self.today, let c = json["counts"] as? [String: Int] else { return }
        for (k, v) in c { if let f = Feature(rawValue: k) { counts[f] = v } }
    }

    /// A day's counts become one usage report once the day is over.
    func sealUsage(before day: String) {
        guard let data = try? Data(contentsOf: usageFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = json["day"] as? String, d < day, let c = json["counts"] as? [String: Int] else { return }
        try? FileManager.default.removeItem(at: usageFile)
        guard usage else { return }
        write(report(kind: "usage", day: d, body: ["counts": c.filter { Feature(rawValue: $0.key) != nil }]))
    }

    // MARK: reports

    static var today: String { day(Date()) }
    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    func report(kind: String, day: String = Reports.today, body: [String: Any]) -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var r: [String: Any] = [
            "kind": kind, "day": day,
            "app": info["CFBundleShortVersionString"] as? String ?? "dev",
            "build": info["CFBundleVersion"] as? String ?? "0",
            "engine": Engine.shared.version,
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        ]
        for (k, v) in body { r[k] = v }
        return r
    }

    private func write(_ report: [String: Any]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
        guard files.count < 50,
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? data.write(to: outbox.appendingPathComponent("\(report["kind"] ?? "report")-\(UUID().uuidString.prefix(8)).json"))
    }

    /// The reports waiting, as they would be sent (Settings shows them).
    func waiting() -> [(URL, String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { f in (try? String(contentsOf: f, encoding: .utf8)).map { (f, $0) } }
    }

    func discardWaiting() { for (f, _) in waiting() { try? FileManager.default.removeItem(at: f) } }

    /// Sends what is waiting, if a kind's switch is on and there is somewhere to send it; a report whose switch was
    /// turned off meanwhile is dropped unsent.
    func send(done: (() -> Void)? = nil) {
        let all = waiting()
        let group = DispatchGroup()
        for (file, text) in all {
            let kind = (text.contains("\"kind\" : \"usage\"")) ? "usage" : "crash"
            guard kind == "usage" ? usage : crashes else { try? FileManager.default.removeItem(at: file); continue }
            guard let url = endpoint else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(text.utf8)
            request.timeoutInterval = 30
            group.enter()
            Self.session.dataTask(with: request) { _, response, _ in
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: file)
                }
                group.leave()
            }.resume()
        }
        group.notify(queue: .main) { done?() }
    }

    /// No cookies, no cache, no system proxy credentials: a report carries only its body.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never; c.httpShouldSetCookies = false; c.urlCache = nil
        c.httpAdditionalHeaders = ["User-Agent": "Greenroom"]
        return URLSession(configuration: c)
    }()

    // MARK: Greenroom's own crashes

    private func collectCrash() {
        guard let text = try? String(contentsOf: pendingCrash, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: pendingCrash)
        guard crashes else { return }
        var signal = 0, offsets: [String] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("signal ") { signal = Int(line.dropFirst(7)) ?? 0 }
            else if line.hasPrefix("+0x") { offsets.append(String(line.dropFirst())) }
        }
        write(report(kind: "crash", body: ["signal": signal, "frames": Array(offsets.prefix(64))]))
    }
}

// The handler runs in a signal context: only async-signal-safe calls (open, write, backtrace, _exit) on memory
// prepared at launch. It keeps the frames inside Greenroom's executable, as offsets from its start.
private var crashPath = [CChar](repeating: 0, count: 1024)
private var textStart: UInt = 0, textEnd: UInt = 0
private let frameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)

private func armCrashHandlers(path: String) {
    _ = path.withCString { strncpy(&crashPath, $0, crashPath.count - 1) }
    for (i, c) in "0123456789abcdef".utf8.enumerated() { hexDigits[i] = c }
    if let header = _dyld_get_image_header(0) {
        var size: UInt = 0
        if let text = getsegmentdata(UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self), "__TEXT", &size) {
            textStart = UInt(bitPattern: UnsafeRawPointer(header)); textEnd = UInt(bitPattern: text) + size
        }
    }
    for sig in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGABRT] {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = onCrash
        action.sa_flags = SA_RESETHAND
        sigaction(sig, &action, nil)
    }
}

private let hexDigits = UnsafeMutablePointer<UInt8>.allocate(capacity: 16)
private let numberBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 24)

private func onCrash(_ sig: Int32) {
    let fd = open(&crashPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    if fd >= 0 {
        func put(_ s: StaticString) { _ = write(fd, s.utf8Start, s.utf8CodeUnitCount) }
        func number(_ value: UInt, base: UInt) {
            var i = 24, x = value
            repeat { i -= 1; numberBuffer[i] = hexDigits[Int(x % base)]; x /= base } while x != 0
            _ = write(fd, numberBuffer + i, 24 - i)
        }
        put("signal "); number(UInt(sig), base: 10); put("\n")
        let n = backtrace(frameBuffer, 128)
        for k in 0..<Int(n) {
            let a = UInt(bitPattern: frameBuffer[k])
            if a >= textStart && a < textEnd { put("+0x"); number(a - textStart, base: 16); put("\n") }
        }
        close(fd)
    }
    raise(sig)   // the handler was reset: the default action ends the process, and macOS writes its own report
}
