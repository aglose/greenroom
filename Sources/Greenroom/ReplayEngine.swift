import Foundation

// Replaying a saved recording on a build, and searching a list of builds for the first one that replays differently.
// The engine does the replay (`apksim replay`); this file runs it as a process, reads what it says, and decides
// which build to try next.

/// What one replay of a recording on one build came to.
enum ReplayOutcome: Equatable {
    case same(String)
    case diverged(Divergence)
    case crashed(String)
    /// The engine would not replay it on this build (another signer, a missing activity, a bundle with no checkpoint).
    case cannot(String)
    /// Stopped, timed out, or an exit status the engine does not define.
    case failed(String)

    struct Divergence: Equatable {
        var point: Int
        var points: Int
        var label: String
        var offsetMs: Int
        var pixels: Int
        var threshold: Int
        var folder: URL

        var summary: String {
            "diverged at point \(point) of \(points) (\(label), +\(offsetMs) ms): \(pixels) pixels differ (threshold \(threshold))"
        }
    }

    var isSame: Bool { if case .same = self { return true }; return false }
    /// A build that differs: the screen diverged, or the app crashed.
    var isDifferent: Bool {
        switch self { case .diverged, .crashed: return true; default: return false }
    }

    var word: String {
        switch self {
        case .same: return "same"
        case .diverged: return "diverged"
        case .crashed: return "crashed"
        case .cannot: return "cannot replay"
        case .failed: return "failed"
        }
    }

    var detail: String {
        switch self {
        case .same(let s), .crashed(let s), .cannot(let s), .failed(let s): return s
        case .diverged(let d): return d.summary
        }
    }
}

/// One replay to run: the bundle, optionally another build, and where the engine puts its report.
struct ReplayJob {
    var bundle: URL
    var apk: URL?
    var out: URL
    var timeout: TimeInterval = 900
}

struct ReplayRun {
    var exit: Int32?
    var log: String
    var seconds: Double
    var cancelled: Bool
    var timedOut: Bool
}

/// Runs replays one at a time on a background queue. Every process it starts is killed (with what it started) when
/// stopped and when the app quits.
final class ReplayRunner {
    static let shared = ReplayRunner()
    private let queue = DispatchQueue(label: "greenroom.replay", qos: .utility)
    private let lock = NSLock()
    private var current: Process?
    private var generation = 0

    /// The newest generation: jobs submitted before a `cancelAll` finish at once as cancelled.
    var token: Int { lock.lock(); defer { lock.unlock() }; return generation }

    /// Runs `job` after the ones before it. `output` hears text as the engine prints it (any thread), and
    /// `completion` is called on the main queue.
    func submit(_ job: ReplayJob, token: Int, output: ((String) -> Void)? = nil, completion: @escaping (ReplayRun) -> Void) {
        queue.async { [self] in
            let started = Date()
            func finish(_ run: ReplayRun) { DispatchQueue.main.async { completion(run) } }
            guard self.token == token else { finish(ReplayRun(exit: nil, log: "", seconds: 0, cancelled: true, timedOut: false)); return }
            let fm = FileManager.default
            try? fm.createDirectory(at: job.out, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let p = Process()
            p.executableURL = Engine.shared.launcher
            var args = ["replay", "--headless", "--out", job.out.path]
            if let apk = job.apk { args += ["--apk", apk.path] }
            args.append(job.bundle.path)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["APKSIM_HOME"] = Engine.shared.engineState.path
            p.environment = env
            p.currentDirectoryURL = Engine.shared.engineState
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let done = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in done.signal() }
            let buffer = LockedText()
            let logFile = job.out.appendingPathComponent("output.log")
            fm.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let sink = try? FileHandle(forWritingTo: logFile)
            pipe.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty else { h.readabilityHandler = nil; return }
                let text = String(decoding: data, as: UTF8.self)
                buffer.append(text)
                try? sink?.write(contentsOf: data)
                output?(text)
            }
            self.lock.lock()
            let still = self.generation == token
            if still { self.current = p }
            self.lock.unlock()
            guard still else { finish(ReplayRun(exit: nil, log: "", seconds: 0, cancelled: true, timedOut: false)); return }
            do { try p.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                self.lock.lock(); self.current = nil; self.lock.unlock()
                finish(ReplayRun(exit: nil, log: "could not start the engine: \(error.localizedDescription)", seconds: 0, cancelled: false, timedOut: false))
                return
            }
            var timedOut = false
            if done.wait(timeout: .now() + job.timeout) == .timedOut {
                timedOut = true
                Self.kill(p, wait: 4)
                _ = done.wait(timeout: .now() + 6)
            }
            // What the engine printed last, once the pipe is drained.
            pipe.fileHandleForReading.readabilityHandler = nil
            if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                buffer.append(String(decoding: rest, as: UTF8.self))
                try? sink?.write(contentsOf: rest)
                output?(String(decoding: rest, as: UTF8.self))
            }
            try? sink?.close()
            self.lock.lock()
            self.current = nil
            let cancelled = self.generation != token
            self.lock.unlock()
            finish(ReplayRun(exit: p.isRunning ? nil : p.terminationStatus, log: buffer.text,
                             seconds: Date().timeIntervalSince(started), cancelled: cancelled, timedOut: timedOut))
        }
    }

    /// Ends the running replay and every queued one. With `wait`, returns once the process is gone (the app is quitting).
    func cancelAll(wait: Bool = false) {
        lock.lock()
        generation += 1
        let p = current
        lock.unlock()
        guard let p, p.isRunning else { return }
        Self.kill(p, wait: wait ? 1.5 : 0)
    }

    /// SIGTERM to the process and what it started (the launcher's client, a JVM), SIGKILL to what is left after `wait`.
    private static func kill(_ p: Process, wait: TimeInterval) {
        let pids = [p.processIdentifier] + descendants(of: p.processIdentifier)
        for pid in pids { Darwin.kill(pid, SIGTERM) }
        let hard = {
            for pid in pids where Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
        }
        if wait > 0 {
            let end = Date().addingTimeInterval(wait)
            while Date() < end, pids.contains(where: { Darwin.kill($0, 0) == 0 }) { usleep(50_000) }
            hard()
        } else {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: hard)
        }
    }

    private static func descendants(of pid: Int32) -> [Int32] {
        let q = Process()
        q.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        q.arguments = ["-P", String(pid)]
        let out = Pipe()
        q.standardOutput = out
        q.standardError = FileHandle.nullDevice
        guard (try? q.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        q.waitUntilExit()
        let kids = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
        return kids + kids.flatMap { descendants(of: $0) }
    }

    /// The outcome of a finished run, from the exit status the engine documents (0 same, 3 diverged, 10 crashed,
    /// 2 cannot be replayed) and its report.
    static func interpret(_ run: ReplayRun, out: URL) -> ReplayOutcome {
        if run.cancelled { return .failed("stopped") }
        if run.timedOut { return .failed("timed out after \(Int(run.seconds)) s") }
        let lines = run.log.split(separator: "\n").map(String.init)
        let engineLines = lines.filter { $0.hasPrefix("[apksim] replay") || $0.hasPrefix("[apksim] exit") }
        let report = (try? Data(contentsOf: out.appendingPathComponent("report.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        switch run.exit {
        case 0?:
            let n = (report?["points"] as? [Any])?.count ?? 0
            return .same(n > 0 ? "matched at all \(n) points" : "matched")
        case 3?:
            let points = report?["points"] as? [[String: Any]] ?? []
            let first = (report?["firstDivergence"] as? Int) ?? points.first { $0["diverged"] as? Bool == true }.flatMap { $0["n"] as? Int } ?? 0
            let p = points.first { ($0["n"] as? Int) == first } ?? [:]
            return .diverged(.init(point: first, points: points.count, label: p["label"] as? String ?? "?",
                                   offsetMs: p["offsetMs"] as? Int ?? 0, pixels: p["pixels"] as? Int ?? 0,
                                   threshold: report?["threshold"] as? Int ?? 0, folder: out))
        case 10?:
            let said = engineLines.last { $0.contains("crashed") } ?? lines.last { $0.contains("FATAL EXCEPTION") }
            return .crashed(said.map(clean) ?? "the app crashed")
        case 2?:
            let said = lines.last { $0.contains("replay") && !$0.hasPrefix("[apksim] exit") } ?? lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return .cannot(said.map(clean) ?? "the engine cannot replay this recording on that build")
        case let code?:
            return .failed("the engine exited with status \(code)" + (lines.last.map { ": " + clean($0) } ?? ""))
        case nil:
            return .failed(run.log.isEmpty ? "the engine did not run" : clean(lines.last ?? run.log))
        }
    }

    private static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: "[apksim] replay: ", with: "").replacingOccurrences(of: "[apksim] ", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Text appended from the pipe's thread and read from another.
final class LockedText {
    private let lock = NSLock()
    private var value = ""
    func append(_ s: String) { lock.lock(); value += s; lock.unlock() }
    func reset() { lock.lock(); value = ""; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

/// Binary search over builds listed oldest first for the first one that replays differently. Pure: it says which
/// build to replay next from what has been seen, as `git bisect` does; a build the engine cannot replay is skipped
/// and the search goes around it.
struct Bisect {
    enum Verdict { case good, bad, skip }
    enum Conclusion: Equatable {
        /// `index` is the first different build; `lastGood` the newest build before it that replayed the same.
        /// `skippedBetween` lists builds between the two that could not be replayed (the change is in one of them or `index`).
        case firstDifferent(index: Int, lastGood: Int, skippedBetween: [Int])
        case oldestDiffers
        case oldestUnreplayable
        case newestUnreplayable
        case noneDiffers
        /// Only builds that could not be replayed lie between a good build and a different one.
        case candidates(lastGood: Int, firstBad: Int, skipped: [Int])
    }

    let count: Int
    private(set) var verdicts: [Int: Verdict] = [:]

    init(count: Int) { self.count = count }

    mutating func record(_ index: Int, _ verdict: Verdict) { verdicts[index] = verdict }

    /// The build to replay next, or nil when the search is over (`conclusion`).
    var next: Int? {
        if count == 0 { return nil }
        if verdicts[0] == nil { return 0 }
        guard verdicts[0] == .good else { return nil }
        if count > 1, verdicts[count - 1] == nil { return count - 1 }
        guard conclusion == nil else { return nil }
        let (lo, hi) = bounds
        let open = ((lo + 1)..<hi).filter { verdicts[$0] == nil }
        let mid = Double(lo + hi) / 2
        return open.min { abs(Double($0) - mid) < abs(Double($1) - mid) || (abs(Double($0) - mid) == abs(Double($1) - mid) && $0 < $1) }
    }

    /// The newest good build below the oldest bad one, and that bad one.
    private var bounds: (Int, Int) {
        let hi = verdicts.filter { $0.value == .bad }.keys.min() ?? count - 1
        let lo = verdicts.filter { $0.value == .good && $0.key < hi }.keys.max() ?? 0
        return (lo, hi)
    }

    var conclusion: Conclusion? {
        guard count > 0, let first = verdicts[0] else { return nil }
        switch first {
        case .bad: return .oldestDiffers
        case .skip: return .oldestUnreplayable
        case .good: break
        }
        if count == 1 { return .noneDiffers }
        guard let last = verdicts[count - 1] else { return nil }
        if last == .skip { return .newestUnreplayable }
        if last == .good { return .noneDiffers }
        let (lo, hi) = bounds
        if ((lo + 1)..<hi).contains(where: { verdicts[$0] == nil }) { return nil }
        let skipped = ((lo + 1)..<hi).filter { verdicts[$0] == .skip }
        return skipped.isEmpty || hi - lo == 1
            ? .firstDifferent(index: hi, lastGood: lo, skippedBetween: [])
            : (skipped.count == hi - lo - 1 ? .candidates(lastGood: lo, firstBad: hi, skipped: skipped)
                                            : .firstDifferent(index: hi, lastGood: lo, skippedBetween: skipped))
    }

    /// Replays still to do at most, for a progress line: the two ends and log2 of what lies between.
    var stepsLeftEstimate: Int {
        let (lo, hi) = bounds
        let untested = (verdicts[0] == nil ? 1 : 0) + (verdicts[count - 1] == nil && count > 1 ? 1 : 0)
        let gap = max(0, hi - lo - 1)
        return untested + (gap == 0 ? 0 : Int(ceil(log2(Double(gap + 1)))))
    }
}
