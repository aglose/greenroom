import Foundation
import CryptoKit

/// One run of an androidTest APK against an app with the bundled engine: `apksim --instrument TEST.apk APP.apk`
/// prints `am instrument -r`'s raw output, which is read as it arrives (off the main thread) and turned into a tree of
/// classes and tests. Everything here is private to this Mac: the engine runs the APKs locally.
final class TestRun {
    enum Status { case running, passed, failed, ignored, assumption }
    enum State: Equatable { case idle, running, finished(exit: Int32, stopped: Bool) }

    final class Test {
        let id: String        // Class#method
        let cls: String
        let method: String
        fileprivate(set) var status: Status = .running
        fileprivate(set) var ms: Int?
        fileprivate(set) var stack = ""
        fileprivate var startedAt = Date()
        init(cls: String, method: String) { self.cls = cls; self.method = method; id = cls + "#" + method }
    }

    final class ClassNode {
        let name: String
        fileprivate(set) var tests: [Test] = []
        init(name: String) { self.name = name }
        var shortName: String { name.split(separator: ".").last.map(String.init) ?? name }
        var status: Status {
            if tests.contains(where: { $0.status == .failed }) { return .failed }
            if tests.contains(where: { $0.status == .running }) { return .running }
            if tests.allSatisfy({ $0.status == .ignored || $0.status == .assumption }) { return .ignored }
            return .passed
        }
    }

    struct Config {
        var testAPK: URL
        var appAPK: URL
        var classFilter = ""
        /// Exact tests (Class#method) instead of the filter: a rerun of the failures.
        var selectors: [String] = []
    }

    let config: Config
    let directory: URL
    private(set) var state: State = .idle
    private(set) var classes: [ClassNode] = []
    private(set) var expected = 0
    private(set) var passed = 0, failed = 0, ignored = 0
    private(set) var startedAt = Date()
    private(set) var endedAt: Date?
    /// Why a run that produced no tests ended, from the engine's own log.
    private(set) var problem: String?
    /// Called on the main thread, at most about ten times a second, when anything changed.
    var onChange: (() -> Void)?

    var elapsed: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    var allTests: [Test] { classes.flatMap { $0.tests } }
    var done: Int { passed + failed + ignored }
    var failedSelectors: [String] { allTests.filter { $0.status == .failed }.map { $0.id } }
    var isRunning: Bool { state == .running }

    private var byID: [String: Test] = [:]
    private var process: Process?
    private var stopping = false
    private let lock = NSLock()
    private var pending: [Pending] = []
    private var flushScheduled = false
    private var lastFlush = Date.distantPast

    // Every live run, so the app can end them when it quits.
    private static let registry = NSHashTable<TestRun>.weakObjects()

    private enum Pending {
        case started(cls: String, method: String, total: Int?, at: Date)
        case result(code: Int, cls: String, method: String, stack: String, at: Date)
        case ended(exit: Int32)
    }

    init(config: Config) {
        self.config = config
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        directory = Engine.shared.engineState.appendingPathComponent("tests/\(stamp)", isDirectory: true)
    }

    // MARK: Starting and stopping

    func start() throws {
        try Engine.shared.prepare()
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var args = ["--instrument", config.testAPK.path]
        if !config.selectors.isEmpty {
            args += ["-e", "class", config.selectors.map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,") }.joined(separator: ",")]
        } else {
            let f = config.classFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            if !f.isEmpty { args += ["-e", "class", f] }
        }
        args += ["--bundles", directory.path, "--record", "failed", "--record-dir", directory.path, config.appAPK.path]

        let p = Process()
        p.executableURL = Engine.shared.launcher
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["APKSIM_HOME"] = Engine.shared.engineState.path
        p.environment = env
        p.currentDirectoryURL = Engine.shared.engineState
        let pipe = Pipe()
        p.standardOutput = pipe
        let logURL = directory.appendingPathComponent("engine.log")
        fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        p.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        startedAt = Date()
        try p.run()
        process = p
        state = .running
        TestRun.registry.add(self)

        let reader = pipe.fileHandleForReading
        let thread = Thread { [weak self] in
            var parser = InstrumentParser()
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    for e in parser.feed(line: line) { self?.enqueue(e) }
                }
            }
            if !buffer.isEmpty {
                for e in parser.feed(line: String(decoding: buffer, as: UTF8.self)) { self?.enqueue(e) }
            }
            p.waitUntilExit()
            self?.enqueue(.ended(exit: p.terminationStatus))
        }
        thread.name = "greenroom-tests-reader"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Ends the engine process and everything it started; the run then finishes as stopped.
    func stop() {
        guard let p = process, p.isRunning else { return }
        stopping = true
        let pids = TestRun.tree(of: p.processIdentifier)
        for pid in pids { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if p.isRunning { for pid in TestRun.tree(of: p.processIdentifier) { kill(pid, SIGKILL) } }
        }
    }

    /// The app is quitting: nothing may stay behind. Synchronous and bounded.
    static func terminateAll() {
        for run in registry.allObjects {
            guard let p = run.process, p.isRunning else { continue }
            run.stopping = true
            let pids = tree(of: p.processIdentifier)
            for pid in pids { kill(pid, SIGKILL) }
            let deadline = Date().addingTimeInterval(1)
            while p.isRunning, Date() < deadline { usleep(20_000) }
        }
    }

    /// A process and all its descendants (the engine's launcher execs the JVM, but a sandbox or shell may sit between).
    private static func tree(of root: pid_t) -> [pid_t] {
        var out = [root], i = 0
        while i < out.count {
            let q = Process()
            q.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            q.arguments = ["-P", String(out[i])]
            let pipe = Pipe()
            q.standardOutput = pipe
            q.standardError = FileHandle.nullDevice
            if (try? q.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                q.waitUntilExit()
                out += String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
            }
            i += 1
        }
        return out
    }

    // MARK: From the reader thread to the main thread, batched

    private func enqueue(_ e: InstrumentParser.Event) {
        let at = Date()
        let item: Pending
        switch e {
        case .status(let code, let f):
            guard let cls = f["class"], let test = f["test"] else { return }
            if code == 1 { item = .started(cls: cls, method: test, total: f["numtests"].flatMap { Int($0) }, at: at) }
            else if [0, -1, -2, -3, -4].contains(code) { item = .result(code: code, cls: cls, method: test, stack: f["stack"] ?? "", at: at) }
            else { return }
        case .finished: return
        }
        push(item)
    }

    private func enqueue(_ p: Pending) { push(p) }

    private func push(_ item: Pending) {
        lock.lock()
        pending.append(item)
        let schedule: Bool
        if case .ended = item { schedule = true } else { schedule = !flushScheduled }
        if schedule { flushScheduled = true }
        let wait = max(0, 0.1 - Date().timeIntervalSince(lastFlush))
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        lock.lock()
        let items = pending
        pending = []
        flushScheduled = false
        lastFlush = Date()
        lock.unlock()
        guard !items.isEmpty else { return }
        for item in items { apply(item) }
        onChange?()
    }

    private func test(_ cls: String, _ method: String, at: Date) -> Test {
        let id = cls + "#" + method
        if let t = byID[id] { return t }
        let t = Test(cls: cls, method: method)
        t.startedAt = at
        byID[id] = t
        if let c = classes.first(where: { $0.name == cls }) { c.tests.append(t) }
        else { let c = ClassNode(name: cls); c.tests.append(t); classes.append(c) }
        return t
    }

    private func apply(_ item: Pending) {
        switch item {
        case .started(let cls, let method, let total, let at):
            if let total { expected = max(expected, total) }
            let t = test(cls, method, at: at)
            t.startedAt = at
            t.status = .running
        case .result(let code, let cls, let method, let stack, let at):
            let t = test(cls, method, at: at)
            if t.status != .running { return }
            t.ms = Int(at.timeIntervalSince(t.startedAt) * 1000)
            t.stack = stack.trimmingCharacters(in: .whitespacesAndNewlines)
            switch code {
            case 0: t.status = .passed; passed += 1
            case -3: t.status = .ignored; ignored += 1
            case -4: t.status = .assumption; ignored += 1
            default: t.status = .failed; failed += 1
            }
        case .ended(let status):
            // A test with no result when the process ended did not finish: it is the one that was running.
            for t in allTests where t.status == .running {
                t.status = .failed
                failed += 1
                t.ms = Int(Date().timeIntervalSince(t.startedAt) * 1000)
                t.stack = stopping ? "Stopped before this test finished." : "The process ended (exit \(status)) before this test finished."
            }
            endedAt = Date()
            state = .finished(exit: status, stopped: stopping)
            if allTests.isEmpty || status != 0 && failed == 0 { problem = engineLogTail() }
            TestRun.registry.remove(self)
        }
    }

    private func engineLogTail() -> String? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("engine.log"), encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").suffix(6).joined(separator: "\n")
        return lines.isEmpty ? nil : lines
    }

    // MARK: Failure bundles and movies

    /// DIR/<class>/<method>-<first 8 hex of SHA-256("class#method")>, the engine's bundle folder for a test.
    func bundleFolder(for t: Test) -> URL? {
        let hash = SHA256.hash(data: Data(t.id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        let exact = directory.appendingPathComponent(t.cls, isDirectory: true).appendingPathComponent("\(t.method)-\(hash)", isDirectory: true)
        if fm.fileExists(atPath: exact.path) { return exact }
        return scan(t) { name in name == "\(t.method)-\(hash)" }
    }

    func movieFile(for t: Test) -> URL? {
        let hash = SHA256.hash(data: Data(t.id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        for ext in ["mp4", "avi"] {
            let f = directory.appendingPathComponent(t.cls, isDirectory: true).appendingPathComponent("\(t.method)-\(hash).\(ext)")
            if fm.fileExists(atPath: f.path) { return f }
        }
        return scan(t) { name in name == "\(t.method)-\(hash).mp4" || name == "\(t.method)-\(hash).avi" }
    }

    /// The class folder's name may be sanitised by the engine: look in every class folder for the test's own name.
    private func scan(_ t: Test, _ match: (String) -> Bool) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for d in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
            if let n = names.first(where: match) { return d.appendingPathComponent(n) }
        }
        return nil
    }
}

/// `am instrument -r`'s raw output, a line at a time. A status block is `INSTRUMENTATION_STATUS: key=value` lines
/// closed by `INSTRUMENTATION_STATUS_CODE: n`; a value (a stack trace) goes on over the lines that follow it, until
/// the next line that starts with `INSTRUMENTATION_`.
struct InstrumentParser {
    enum Event {
        case status(code: Int, fields: [String: String])
        case finished(code: Int?)
    }

    private var fields: [String: String] = [:]
    private var lastKey: String?

    mutating func feed(line raw: String) -> [Event] {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.hasPrefix("INSTRUMENTATION_STATUS_CODE:") {
            let code = Int(line.dropFirst("INSTRUMENTATION_STATUS_CODE:".count).trimmingCharacters(in: .whitespaces)) ?? 99
            let out = Event.status(code: code, fields: fields.mapValues { $0.trimmingCharacters(in: .newlines) })
            fields = [:]; lastKey = nil
            return [out]
        }
        if line.hasPrefix("INSTRUMENTATION_STATUS:") {
            let kv = line.dropFirst("INSTRUMENTATION_STATUS:".count).drop(while: { $0 == " " })
            guard let eq = kv.firstIndex(of: "=") else { lastKey = nil; return [] }
            let key = String(kv[kv.startIndex..<eq])
            fields[key] = String(kv[kv.index(after: eq)...])
            lastKey = key
            return []
        }
        if line.hasPrefix("INSTRUMENTATION_CODE:") {
            lastKey = nil
            return [.finished(code: Int(line.dropFirst("INSTRUMENTATION_CODE:".count).trimmingCharacters(in: .whitespaces)))]
        }
        if line.hasPrefix("INSTRUMENTATION_") { lastKey = nil; return [] }   // RESULT, ABORTED
        if let k = lastKey { fields[k, default: ""] += "\n" + line }
        return []
    }
}
