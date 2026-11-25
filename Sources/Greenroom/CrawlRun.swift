import Foundation
import AppKit

/// One screen the walk found, as `crawl.json` has it.
struct MapScreen {
    let id: String
    /// The activity's simple name ("MainActivity").
    let activity: String
    let title: String
    let depth: Int
    let parent: String?
    /// Where a replay begins: a deep link, or nil for the launcher activity.
    let start: String?
    /// Control commands from the start (`tap-text Trips`, `tap 109 1350`, `drag ...`).
    let steps: [String]
    /// Capture per combination name, in the run's combination order.
    let captures: [(combo: String, file: URL)]
    let texts: [String]
    let settled: Bool
    let flaky: String?
    /// Controls found on it (label, command, whether skipped and why).
    let controls: [(label: String, cmd: String, skipped: String?)]

    var label: String { title.isEmpty ? activity : title }
}

/// Where one control of a screen led: another screen, back to itself, or out of the screen graph.
struct MapEdge {
    enum Target: Equatable { case screen(String), exit, crash, skipped, failed, unfollowed }
    let from: String
    let action: String
    let cmd: String
    let to: Target
    let note: String?
}

struct MapFinding {
    let kind: String
    let detail: String
    let steps: [String]
}

/// A finished walk: what `report.html` shows, read from the run folder's `crawl.json`.
struct ScreenMapData {
    let folder: URL
    let apkName: String
    let screens: [MapScreen]
    let edges: [MapEdge]
    let findings: [MapFinding]
    let combos: [String]
    let incomplete: [String]
    let seconds: Double
    /// The APK that was walked, as Greenroom passed it (crawl.json only keeps its file name).
    let apk: URL?

    func screen(_ id: String) -> MapScreen? { screens.first { $0.id == id } }
    var crashes: [MapFinding] { findings.filter { $0.kind == "crash" } }

    /// `screensKey`/`edgesKey` name another build's lists of a comparison run (`base_screens`, `base_edges`).
    static func read(_ folder: URL, screensKey: String = "screens", edgesKey: String = "edges") -> ScreenMapData? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("crawl.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json[screensKey] as? [[String: Any]] else { return nil }
        let combos = (json["combos"] as? [String]) ?? []
        let screens: [MapScreen] = list.compactMap { s in
            guard let id = s["id"] as? String else { return nil }
            let path = (s["path"] as? [String: Any]) ?? [:]
            let caps = (s["captures"] as? [String: String]) ?? [:]
            let order = combos + caps.keys.filter { !combos.contains($0) }.sorted()
            let captures = order.compactMap { c -> (String, URL)? in
                guard let rel = caps[c] else { return nil }
                let u = folder.appendingPathComponent(rel)
                return u.isInside(folder) && FileManager.default.fileExists(atPath: u.path) ? (c, u) : nil
            }
            let controls = ((s["actions"] as? [[String: Any]]) ?? []).map {
                (label: ($0["label"] as? String) ?? "", cmd: ($0["cmd"] as? String) ?? "", skipped: $0["skipped"] as? String)
            }
            let activity = ((s["activity"] as? String) ?? id).split(separator: ".").last.map(String.init) ?? id
            return MapScreen(id: id, activity: activity, title: (s["title"] as? String) ?? "", depth: (s["depth"] as? Int) ?? 0,
                             parent: s["parent"] as? String, start: path["start"] as? String, steps: (path["steps"] as? [String]) ?? [],
                             captures: captures, texts: (s["texts"] as? [String]) ?? [], settled: (s["settled"] as? Bool) ?? true,
                             flaky: s["flaky"] as? String, controls: controls)
        }
        let edges: [MapEdge] = ((json[edgesKey] as? [[String: Any]]) ?? []).compactMap { e in
            guard let from = e["from"] as? String else { return nil }
            let to: MapEdge.Target
            switch e["to"] as? String {
            case nil: to = .unfollowed
            case "EXIT": to = .exit
            case "CRASH": to = .crash
            case "SKIPPED": to = .skipped
            case "FAILED": to = .failed
            case let id?: to = .screen(id)
            }
            return MapEdge(from: from, action: (e["action"] as? String) ?? "", cmd: (e["cmd"] as? String) ?? "", to: to, note: e["note"] as? String)
        }
        let findings: [MapFinding] = ((json["findings"] as? [[String: Any]]) ?? []).map { f in
            MapFinding(kind: (f["kind"] as? String) ?? "", detail: (f["detail"] as? String) ?? "",
                       steps: ((f["path"] as? [String: Any])?["steps"] as? [String]) ?? [])
        }
        let meta = (try? Data(contentsOf: folder.appendingPathComponent("greenroom.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let apk = (meta?["apk"] as? String).map { URL(fileURLWithPath: $0) }
        let seconds = ((json["seconds"] as? [String: Any])?["total"] as? Double) ?? 0
        return ScreenMapData(folder: folder, apkName: (json["apk"] as? String) ?? apk?.lastPathComponent ?? "", screens: screens,
                             edges: edges, findings: findings, combos: combos, incomplete: (json["incomplete"] as? [String]) ?? [],
                             seconds: seconds, apk: apk)
    }
}

/// A repository's `.greenroom/map.json`, as walks inside the app read it: only `dataIgnore`, the patterns of what the
/// app writes at every action and no screen reads (`crawl.py --data-ignore`: a file of the data slot, `FILE#TABLE` or
/// `FILE#KEY`), so a replay after such a write does not take a new launch.
enum RepoMapSettings {
    static func dataIgnore(in root: URL?) -> [String] {
        guard let root, let data = try? Data(contentsOf: root.appendingPathComponent(".greenroom/map.json")),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return ((d["dataIgnore"] as? [String]) ?? []).filter { !$0.isEmpty && !$0.hasPrefix("-") }
    }

    /// What a finished walk relaunched for most (crawl.json's `relaunches` and `relaunch_files`), in a line, when it
    /// is worth saying: most of the walk's launches were for one or two things the app wrote. Nil otherwise.
    static func relaunchNote(_ walk: URL) -> String? {
        guard let data = try? Data(contentsOf: walk.appendingPathComponent("crawl.json")),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let n = d["relaunches"] as? Int, n >= 50, let files = d["relaunch_files"] as? [String: Int] else { return nil }
        let top = files.filter { !$0.key.hasPrefix("<") }.sorted { $0.value > $1.value }.prefix(2)
        guard let first = top.first, first.value * 2 >= n else { return nil }
        let names = top.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
        return "\(n) replays took a new launch, most because the app wrote \(names). If no screen shows that, list it under \"dataIgnore\" in the repository's .greenroom/map.json and later walks skip those launches."
    }
}

/// `scripts/crawl.py` of the bundled engine, run in the background. Its stdout says each level as it starts
/// ("[new] depth 1: 3 screen(s) to explore, 4 known"), which is what the map shows while the walk goes on.
final class CrawlRun {
    /// Where a walk with no time budget still stops, in seconds (4 hours): its map then says it was cut short.
    static let ceiling = 14_400
    /// Simulators a walk runs at once: the performance cores less two for the person and the app, a simulator to about
    /// 3 GB of memory, 6 at most and 2 at least. A walk on kept (signed-in) data still runs one: the crawler has one slot.
    static let parallel: Int = {
        func sys(_ name: String) -> Int {
            var v = 0, n = MemoryLayout<Int>.size
            return sysctlbyname(name, &v, &n, nil, 0) == 0 ? v : 0
        }
        let perf = sys("hw.perflevel0.physicalcpu"), cores = perf > 0 ? perf : ProcessInfo.processInfo.activeProcessorCount
        let gb = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return max(2, min(6, cores - 2, gb / 3))
    }()
    struct Settings {
        /// Taps deep; 0 walks the whole app, which is what a history of the app needs.
        var depth = 0
        /// The time budget; 0 is none (the crawler still stops at `ceiling`, so a walk that never ends does not hold the queue).
        var seconds = 0
        /// Combinations to capture: "light", "light,dark", or none.
        var appearances: [String] = ["light"]
        var offline = false
        var start: String?
        /// Simulators the walk runs at once (with `keepData`, each on its own clone of the slot: apksim 0.60).
        var jobs = CrawlRun.parallel
        /// `--events`: a line of JSON for each screen as it is explored (set when the crawler offers it: `Support.events`).
        var events = false
        /// `--base`: walk this build too and compare (Evidence's changes runs; not with `keepData`).
        var base: URL?
        /// `--base-option`: engine options for the base build's launches only (a check's way to make a changed build).
        var baseOption = ""
        /// `--keep-data`: use the data slot named in `engineOptions` as it is (a clone: see Evidence).
        var keepData = false
        /// Options for the engine's launches, after `--` (`--data-slots NAME`).
        var engineOptions: [String] = []
        /// Run at background quality of service (Evidence's walks; the Screen Map sheet's own runs are not).
        var background = false
        /// `--seed RUN_DIR`: start from an earlier walk's folder and carry what is not re-explored (package I1).
        var seed: URL?
        /// `--only-file PATH`: with `seed`, the screen ids to explore again, one per line.
        var onlyFile: URL?
        /// `--standby`: launches go to apksim's warm JVM when one is up (set when the crawler offers it). The engine
        /// keeps launches cold where a warm JVM cannot serve them (`--record-deps`, `--base`).
        var standby = false
        /// `--data-ignore PATTERN`, each: what the app writes at every action and no screen reads (the repository's
        /// `.greenroom/map.json` `dataIgnore`, RepoMapSettings), so replays after it are not new launches.
        var dataIgnore: [String] = []
        /// `--diff-seed --diff-controls HOW`: with `seed`, compare the walk with it (nil: not passed).
        var diffControls: String?
        /// `--record-deps`: each walked screen records the classes, source files and resources it depends on.
        var recordDeps = false
        /// `--max-actions N`: controls tried per screen (0: reach and capture only; "Verify carried screens").
        var maxActions: Int?
        /// Another `crawl.py` than the engine's (a check's stand-in).
        var script: URL?
    }

    /// What the engine's crawler can do beyond the released one: read once per crawler from its `--help`.
    struct Support: Equatable {
        /// `--seed` and `--only-file`.
        var seed = false
        var recordDeps = false
        var maxActions = false
        var events = false
        /// `--diff-seed` and `--diff-controls` (apksim 0.62.0): a seeded walk compared with its seed.
        var diffSeed = false
        /// `--standby` (apksim 0.64.0): launches handed to a warm JVM when one is up.
        var standby = false
        /// `--data-ignore PATTERN` (apksim 0.64.0).
        var dataIgnore = false
        static let none = Support()
    }

    private static let supportLock = NSLock()
    private static var supportCache: [String: Support] = [:]

    /// Runs `crawl.py --help` once per crawler (and Python) and looks for the options. Blocks for as long as that
    /// takes (a fraction of a second): call it off the main thread. Unreadable help is the released engine.
    /// What `support` found earlier for this crawler, without running anything; nil when it has not been asked yet.
    static func knownSupport(python: URL, script: URL? = nil) -> Support? {
        let crawler = script ?? Engine.shared.root.appendingPathComponent("scripts/crawl.py")
        supportLock.lock(); defer { supportLock.unlock() }
        return supportCache[python.path + "\u{0}" + crawler.path]
    }

    static func support(python: URL, script: URL? = nil) -> Support {
        let crawler = script ?? Engine.shared.root.appendingPathComponent("scripts/crawl.py")
        let key = python.path + "\u{0}" + crawler.path
        supportLock.lock()
        if let s = supportCache[key] { supportLock.unlock(); return s }
        supportLock.unlock()
        let p = Process()
        p.executableURL = python
        p.arguments = [crawler.path, "--help"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var s = Support.none
        if (try? p.run()) != nil {
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: killer)
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            killer.cancel()
            func has(_ flag: String) -> Bool { text.range(of: flag + "(?![\\w-])", options: .regularExpression) != nil }
            s = Support(seed: has("--seed") && has("--only-file"), recordDeps: has("--record-deps"), maxActions: has("--max-actions"), events: has("--events"), diffSeed: has("--diff-seed") && has("--diff-controls"),
                        standby: has("--standby"), dataIgnore: has("--data-ignore"))
        }
        supportLock.lock(); supportCache[key] = s; supportLock.unlock()
        return s
    }
    enum Event {
        /// Depth `depth` has `exploring` screens; `known` found so far.
        case level(depth: Int, exploring: Int, known: Int)
        case capturing(screens: Int, transitions: Int)
        /// `--events`: a screen the walk has finished with. `explored` false: found and never opened (a budget ran out).
        case screen(id: String, title: String, depth: Int, explored: Bool)
        case line(String)
    }
    enum Outcome { case finished(ScreenMapData), failed(String), cancelled }

    let out: URL
    var onEvent: ((Event) -> Void)?
    var onFinish: ((Outcome) -> Void)?
    private(set) var isRunning = false
    let startedAt = Date()
    private let process = Process()
    /// The crawler's command line, for checks.
    var arguments: [String] { process.arguments ?? [] }
    private let queue = DispatchQueue(label: "greenroom-crawl-run")
    private var cancelled = false
    private var outBuffer = Data(), errBuffer = Data()
    private let python: URL
    /// The crawler's working folder: the engine's state, or for a stand-in crawler the output's parent.
    private let workingFolder: URL

    init(python: URL, apk: URL, out: URL, settings: Settings) {
        self.python = python
        workingFolder = settings.script == nil ? Engine.shared.engineState : out.deletingLastPathComponent()
        self.out = out
        var a = [(settings.script ?? Engine.shared.root.appendingPathComponent("scripts/crawl.py")).path, apk.path, "--out", out.path,
                 "--max-seconds", String(settings.seconds > 0 ? settings.seconds : Self.ceiling), "-j", String(max(1, settings.jobs))]
        if settings.depth > 0 { a += ["--max-depth", String(settings.depth)] }
        if settings.appearances.isEmpty { a.append("--no-captures") }
        else { a += ["--matrix", "appearance=" + settings.appearances.joined(separator: ",")] }
        if let s = settings.start, !s.isEmpty { a += ["--start", s] }
        if let base = settings.base { a += ["--base", base.path] }
        if !settings.baseOption.isEmpty { a += ["--base-option", settings.baseOption] }
        if settings.keepData { a.append("--keep-data") }
        if let seed = settings.seed {
            a += ["--seed", seed.path]
            if let only = settings.onlyFile { a += ["--only-file", only.path] }
            if let how = settings.diffControls { a += ["--diff-seed", "--diff-controls", how] }
        }
        if settings.recordDeps { a.append("--record-deps") }
        if settings.events { a.append("--events") }
        if settings.standby { a.append("--standby") }
        for d in settings.dataIgnore { a += ["--data-ignore", d] }
        if let n = settings.maxActions { a += ["--max-actions", String(n)] }
        let tail = settings.engineOptions + (settings.offline ? ["--network-profile", "offline"] : [])
        if !tail.isEmpty { a += ["--"] + tail }
        process.arguments = a
        // Utility, not background: background work is kept to the efficiency cores, where a whole-app walk takes several times as long.
        if settings.background { process.qualityOfService = .utility }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let meta: [String: Any] = ["apk": apk.path, "depth": settings.depth, "seconds": settings.seconds,
                                   "appearances": settings.appearances, "offline": settings.offline, "start": settings.start ?? "",
                                   "keptData": settings.keepData, "jobs": settings.jobs]
        try? JSONSerialization.data(withJSONObject: meta).write(to: out.appendingPathComponent("greenroom.json"))
        CrawlRun.registry[ObjectIdentifier(self)] = self
    }

    private static var registry: [ObjectIdentifier: CrawlRun] = [:]
    private static let quitObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        for run in registry.values { run.cancel(wait: true) }
    }

    func start() {
        _ = CrawlRun.quitObserver
        let outPipe = Pipe(), errPipe = Pipe()
        process.executableURL = python
        var env = ProcessInfo.processInfo.environment
        env["APKSIM_HOME"] = Engine.shared.engineState.path
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env
        process.currentDirectoryURL = workingFolder
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        for (pipe, isErr) in [(outPipe, false), (errPipe, true)] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; return }
                self?.queue.async { self?.take(d, error: isErr) }
            }
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
                let stderr = String(decoding: self.errBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let code = proc.terminationStatus, was = self.cancelled
                DispatchQueue.main.async { self.finish(code: code, stderr: stderr, cancelled: was) }
            }
        }
        isRunning = true
        do { try process.run() } catch {
            DispatchQueue.main.async { self.finish(code: -1, stderr: error.localizedDescription, cancelled: false) }
        }
    }

    private func take(_ data: Data, error: Bool) {
        if error { errBuffer.append(data); return }
        outBuffer.append(data)
        while let nl = outBuffer.firstIndex(of: 10) {
            let line = String(decoding: outBuffer[outBuffer.startIndex..<nl], as: UTF8.self)
            outBuffer.removeSubrange(outBuffer.startIndex...nl)
            let event = CrawlRun.parse(line)
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
    }

    static func parse(_ line: String) -> Event {
        func ints(_ s: String) -> [Int] { s.split { !$0.isNumber }.compactMap { Int($0) } }
        if line.hasPrefix("{\"event\""), let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] {
            if o["event"] as? String == "screen", (o["build"] as? String ?? "new") == "new", let id = o["id"] as? String {
                return .screen(id: id, title: o["title"] as? String ?? "", depth: o["depth"] as? Int ?? 0, explored: o["explored"] as? Bool ?? true)
            }
            return .line(line)
        }
        if line.hasPrefix("[new] depth "), line.contains("to explore") {
            let n = ints(line)
            if n.count >= 3 { return .level(depth: n[0], exploring: n[1], known: n[2]) }
        }
        if line.hasPrefix("[new] "), line.contains(" screens, "), line.contains(" transitions") {
            let n = ints(line)
            if n.count >= 2 { return .capturing(screens: n[0], transitions: n[1]) }
        }
        return .line(line)
    }

    private func finish(code: Int32, stderr: String, cancelled: Bool) {
        guard isRunning else { return }
        isRunning = false
        CrawlRun.registry[ObjectIdentifier(self)] = nil
        if cancelled { onFinish?(.cancelled); return }
        // 0: walked, 1: walked and found a crash. Anything else (2: bad arguments, an instance that never started).
        if code == 0 || code == 1, let map = ScreenMapData.read(out) { onFinish?(.finished(map)); return }
        let last = stderr.split(separator: "\n").last.map { String($0).replacingOccurrences(of: "crawl: ", with: "") }
        onFinish?(.failed(last ?? "The walk ended with status \(code) and no map."))
    }

    /// Stops the walk and the simulators it started (only processes that descend from it). The crawler is told first,
    /// so it can end its own simulators; the tree is read before that (children of a dead crawler belong to no one),
    /// and what is left after 4 s is killed. Off the calling thread (reading the tree runs `pgrep`) unless `wait`.
    func cancel(wait: Bool = false) {
        guard isRunning, process.isRunning else { return }
        cancelled = true
        let pid = process.processIdentifier
        let stop = { [process] in
            let tree = SnapshotRun.descendants(of: pid)
            kill(pid, SIGTERM)
            for p in tree.reversed() { kill(p, SIGTERM) }
            let deadline = Date().addingTimeInterval(4)
            while process.isRunning, Date() < deadline { usleep(50_000) }
            for p in tree where kill(p, 0) == 0 { kill(p, SIGKILL) }
            if process.isRunning { kill(pid, SIGKILL) }
        }
        if wait { stop() } else { DispatchQueue.global(qos: .utility).async(execute: stop) }
    }
}
