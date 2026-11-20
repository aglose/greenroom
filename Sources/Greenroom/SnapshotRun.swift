import Foundation
import AppKit
import ImageIO

/// One screenshot (screen × combination) of a run of the engine's `snapshot.py`, as `results.json` reports it.
struct SnapshotResult {
    enum Kind { case same, different, new, error, recorded, updated }
    var screen: String
    var combo: String
    var kind: Kind
    var detail: String
    var pixels: Int?
    var total: Int?
    /// The file as the golden folder names it, `screen/combo.png`.
    var rel: String
    var actual: URL?
    var golden: URL?
    var diff: URL?
    /// Accepted as the golden in this window.
    var accepted = false

    var id: String { screen + "/" + combo }
    var percent: Double? {
        guard let p = pixels, let t = total, t > 0 else { return nil }
        return Double(p) / Double(t) * 100
    }
    /// A short line for the tile.
    var statusText: String {
        switch kind {
        case .same: return accepted ? "Accepted" : "Same"
        case .different:
            if detail.hasPrefix("size changed") { return "Size changed" }
            if let p = percent { return p < 0.01 ? "<0.01% differ" : String(format: "%.2f%% differ", p) }
            return "Different"
        case .new: return "New, no golden"
        case .error: return "Error"
        case .recorded: return "Recorded"
        case .updated: return "Golden rewritten"
        }
    }
}

/// `scripts/snapshot.py` of the bundled engine, run as a background process whose output is read as it comes.
final class SnapshotRun {
    enum Mode { case compare, record }
    enum Outcome {
        case finished(exit: Int32, results: [SnapshotResult])
        case failed(String)
        case cancelled
    }

    let mode: Mode
    let out: URL
    /// Called on the main thread: captures done, captures in all (0 until known), the latest line.
    var onProgress: ((Int, Int, String) -> Void)?
    var onFinish: ((Outcome) -> Void)?
    private(set) var isRunning = false
    private let process = Process()
    private let queue = DispatchQueue(label: "greenroom-snapshot-run")
    private var cancelled = false
    private var outBuffer = Data()
    private var errBuffer = Data()
    private var done = 0, total = 0
    private let arguments: [String]
    private let python: URL

    init(python: URL, spec: URL, apk: URL?, goldens: URL?, out: URL, mode: Mode) {
        self.python = python
        self.out = out
        self.mode = mode
        var a = [Engine.shared.root.appendingPathComponent("scripts/snapshot.py").path, spec.path, "--out", out.path]
        if let apk { a += ["--apk", apk.path] }
        if let goldens { a += ["--goldens", goldens.path] }
        if mode == .record { a.append("--update") }
        arguments = a
        SnapshotRun.registry[ObjectIdentifier(self)] = self
    }

    // Everything started here is stopped when the app quits.
    private static var registry: [ObjectIdentifier: SnapshotRun] = [:]
    private static let quitObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        for run in registry.values { run.cancel(wait: true) }
    }

    func start() {
        _ = SnapshotRun.quitObserver
        let outPipe = Pipe(), errPipe = Pipe()
        process.executableURL = python
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["APKSIM_HOME"] = Engine.shared.engineState.path
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env
        process.currentDirectoryURL = Engine.shared.engineState
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.take(d, error: false) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.take(d, error: true) }
        }
        process.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
            let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
            self?.queue.async {
                guard let self else { return }
                self.take(rest, error: false)
                self.take(restErr, error: true)
                let code = proc.terminationStatus
                let stderr = String(decoding: self.errBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let was = self.cancelled
                DispatchQueue.main.async { self.finish(code: code, stderr: stderr, cancelled: was) }
            }
        }
        do {
            try process.run()
            isRunning = true
        } catch {
            isRunning = true
            DispatchQueue.main.async { self.finish(code: -1, stderr: error.localizedDescription, cancelled: false) }
        }
    }

    private func take(_ data: Data, error: Bool) {
        if error { errBuffer.append(data); return }
        outBuffer.append(data)
        while let nl = outBuffer.firstIndex(of: 10) {
            let line = String(decoding: outBuffer[outBuffer.startIndex..<nl], as: UTF8.self)
            outBuffer.removeSubrange(outBuffer.startIndex...nl)
            consume(line)
        }
    }

    private func consume(_ line: String) {
        if let m = line.range(of: #"^(\d+) captures: "#, options: .regularExpression) {
            total = Int(line[m].dropLast(11).trimmingCharacters(in: .whitespaces)) ?? 0
        } else if line.range(of: #"^\s*(ok|new|UPDATED|MISMATCH|MISSING|ERROR)\s"#, options: .regularExpression) != nil {
            done += 1
        }
        let (d, t) = (done, total)
        DispatchQueue.main.async { [weak self] in self?.onProgress?(d, t, line) }
    }

    private func finish(code: Int32, stderr: String, cancelled: Bool) {
        guard isRunning else { return }
        isRunning = false
        SnapshotRun.registry[ObjectIdentifier(self)] = nil
        if cancelled { onFinish?(.cancelled); return }
        // 0: all matched, 1: something differs. Anything else, or no results file, is a failed run.
        let results = SnapshotRun.read(out)
        if (code == 0 || code == 1), let results { onFinish?(.finished(exit: code, results: results)); return }
        let message = stderr.split(separator: "\n").last.map(String.init) ?? "The run ended with status \(code) and no results."
        onFinish?(.failed(message))
    }

    /// Stops the script, and with it the simulators it started: only processes that descend from this run.
    func cancel(wait: Bool = false) {
        guard isRunning, process.isRunning else { return }
        cancelled = true
        let pid = process.processIdentifier
        let tree = SnapshotRun.descendants(of: pid)
        for p in tree.reversed() { kill(p, SIGTERM) }
        kill(pid, SIGTERM)
        let stop = { [process] in
            let deadline = Date().addingTimeInterval(4)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            for p in tree where kill(p, 0) == 0 { kill(p, SIGKILL) }
            if process.isRunning { kill(pid, SIGKILL) }
        }
        if wait { stop() } else { DispatchQueue.global(qos: .utility).async(execute: stop) }
    }

    private static func descendants(of pid: Int32) -> [Int32] {
        var all: [Int32] = [], frontier = [pid]
        while let next = frontier.popLast() {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-P", String(next)]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            for s in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if let c = Int32(s) { all.append(c); frontier.append(c) }
            }
        }
        return all
    }

    // MARK: Results

    /// Reads `results.json` of a run folder.
    static func read(_ out: URL) -> [SnapshotResult]? {
        guard let data = try? Data(contentsOf: out.appendingPathComponent("results.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["results"] as? [[String: Any]] else { return nil }
        return list.compactMap { r in
            guard let screen = r["screen"] as? String, let combo = r["combo"] as? String, let status = r["status"] as? String else { return nil }
            let rel = (r["actual"] as? String) ?? (r["golden"] as? String) ?? "\(screen)/\(combo).png"
            let kind: SnapshotResult.Kind
            switch status {
            case "match": kind = .same
            case "mismatch": kind = .different
            case "missing": kind = .new
            case "new": kind = .recorded
            case "updated": kind = .updated
            default: kind = .error
            }
            func file(_ dir: String, _ key: String) -> URL? {
                guard let p = r[key] as? String else { return nil }
                let u = out.appendingPathComponent(dir).appendingPathComponent(p)
                return FileManager.default.fileExists(atPath: u.path) ? u : nil
            }
            return SnapshotResult(screen: screen, combo: combo, kind: kind, detail: (r["detail"] as? String) ?? "",
                                  pixels: r["pixels"] as? Int, total: r["total"] as? Int, rel: rel,
                                  actual: file("actual", "actual"), golden: file("golden", "golden"), diff: file("diff", "diff"))
        }
    }

    /// Writes an accepted result back into the run's `results.json`, so reopening it shows what is true now.
    static func markAccepted(_ ids: Set<String>, in out: URL) {
        let file = out.appendingPathComponent("results.json")
        guard let data = try? Data(contentsOf: file), var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var list = json["results"] as? [[String: Any]] else { return }
        for i in list.indices {
            if let s = list[i]["screen"] as? String, let c = list[i]["combo"] as? String, ids.contains(s + "/" + c) {
                list[i]["status"] = "match"
                list[i]["detail"] = "accepted"
                list[i]["pixels"] = 0
                list[i]["golden"] = list[i]["actual"]
                list[i].removeValue(forKey: "diff")
            }
        }
        json["results"] = list
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) { try? out.write(to: file, options: .atomic) }
    }

    /// Keeps the newest few run folders; a report with its copies of the images is a few MB.
    static func prune(_ dir: URL, keep: Int = 6) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let runs = items.filter { $0.lastPathComponent.hasPrefix("run-") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for old in runs.dropFirst(keep) { try? fm.removeItem(at: old) }
    }

    // MARK: Python

    /// A Python 3 to run the engine's scripts. The system's `/usr/bin/python3` is only a stub (it opens an install
    /// dialog) until the command line tools are there, so it is used only when they are.
    static func python() -> URL? {
        let fm = FileManager.default
        var paths: [String] = []
        let tools = ["/Library/Developer/CommandLineTools/usr/bin/python3", "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
        if tools.contains(where: { fm.isExecutableFile(atPath: $0) }) { paths.append("/usr/bin/python3") }
        paths += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") where dir != "/usr/bin" {
            paths.append(dir + "/python3")
        }
        return paths.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// Thumbnails and full pictures for the review, decoded off the main thread and kept (downscaled) in a cache.
enum SnapshotImages {
    private final class Box { let image: CGImage; init(_ i: CGImage) { image = i } }
    private static let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.totalCostLimit = 160_000_000; return c }()
    private static let queue = DispatchQueue(label: "greenroom-snapshot-images", qos: .userInitiated, attributes: .concurrent)

    /// Calls `done` on the main thread with the picture, downscaled so its long side is at most `maxPixel`.
    static func load(_ url: URL, maxPixel: Int, done: @escaping (CGImage?) -> Void) {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)|\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { done(hit.image); return }
        queue.async {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            var image: CGImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil) { image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) }
            if let image { cache.setObject(Box(image), forKey: key, cost: image.width * image.height * 4) }
            DispatchQueue.main.async { done(image) }
        }
    }

    /// The difference map of two pictures of one size, for a result the script wrote none for.
    static func difference(golden: URL, actual: URL, done: @escaping (CGImage?) -> Void) {
        queue.async {
            func read(_ u: URL) -> CGImage? { CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } }
            var out: CGImage?
            if let g = read(golden), let a = read(actual), let p = ScreenComparison.pixels(a: g, b: a),
               let png = ScreenComparison.map(b: a, cells: p.cells, maxSize: 1600), let src = CGImageSourceCreateWithData(png as CFData, nil) {
                out = CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
            DispatchQueue.main.async { done(out) }
        }
    }
}
