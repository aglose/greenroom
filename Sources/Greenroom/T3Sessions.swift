import AppKit

// T3 Code's threads on the Sessions rows (Settings > T3 Code, "Show my T3 Code threads", off by default).
// Read through the person's own `t3` program, the interface T3 Code documents for this (docs/user/outside-agents.md,
// "host CLI"): `t3 thread list --project <repository> --json` for each repository added to Sessions, then
// `t3 thread show <id> --json` for the recent ones, which name their worktree and branch. `t3` asks the T3 Code server
// running on this Mac; with none running it fails and the rows stay as they are. Nothing is written: T3 Code's
// database is never opened. Every field is optional here: a shape that does not parse gives no thread, not a fault.
//
// A thread becomes a `ClaudeSession` (source `.t3`), so the rows treat it exactly like a Claude Code session: its
// title names the row, its status gives the dot, its pull requests the suggestions and the archiving.

/// Reads T3 Code's threads. Pure of UI; blocks (runs `t3`): never on the main thread.
enum T3Reader {
    /// For a check: the PATH `t3` is looked up on, instead of the login shell's and the usual install folders.
    static var pathOverride: String?
    static var timeout: TimeInterval = 20
    /// Threads not updated for this long are not asked for their details (nor shown).
    static let window: TimeInterval = 30 * 86_400
    /// At most this many `thread show` calls in one read; the rest wait for the next read (details are cached).
    static let showLimit = 24

    struct Detail: Equatable {
        var worktree: String?
        var branch: String?
        var archived = false
        var settled = false
        var pending = 0
        var summary: String?
        var model: String?
        var provider: String?
        var link: URL?
    }

    /// What one read gives, and why there is nothing when there is nothing.
    struct Result { var sessions: [ClaudeSession] = []; var note: String? }

    /// The `t3` program: the login shell's PATH, then where T3 Code puts it (`~/.t3/bin`, the desktop app's command;
    /// `~/.local/bin` and `~/bin`, its installers').
    static func find() -> (exe: String, env: [String: String])? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        var env = LoginEnvironment.resolve().env
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = pathOverride ?? ([env["PATH"] ?? ""] + ["\(home)/.t3/bin", "\(home)/.local/bin", "\(home)/bin"]).joined(separator: ":")
        if pathOverride != nil { env["PATH"] = path }
        guard let exe = GH.find("t3", in: path) else { return nil }
        return (exe, env)
    }

    struct Run { var status: Int32; var output: String; var error = ""; var timedOut = false }

    /// One `t3` call; its output goes to a file (a grandchild holding a pipe open cannot keep this waiting).
    static func run(_ exe: String, _ args: [String], in dir: URL, env: [String: String]) -> Run {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("greenroom-t3-\(UUID().uuidString.prefix(8)).out")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let errLog = log.appendingPathExtension("err")
        FileManager.default.createFile(atPath: errLog.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: log); try? FileManager.default.removeItem(at: errLog) }
        guard let out = try? FileHandle(forWritingTo: log), let err = try? FileHandle(forWritingTo: errLog) else { return Run(status: 126, output: "") }
        defer { try? out.close(); try? err.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.currentDirectoryURL = dir
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Run(status: 126, output: "") }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline {
                timedOut = true
                p.terminate()
                let grace = Date().addingTimeInterval(2)
                while p.isRunning, Date() < grace { usleep(50_000) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                break
            }
            usleep(30_000)
        }
        return Run(status: timedOut ? 124 : p.terminationStatus, output: (try? String(contentsOf: log, encoding: .utf8)) ?? "",
                   error: (try? String(contentsOf: errLog, encoding: .utf8)) ?? "", timedOut: timedOut)
    }

    /// Every recent thread of every repository in `roots`. `cache` keeps each thread's details by id and update time.
    static func read(roots: [URL], cache: inout [String: (updated: String, detail: Detail)]) -> Result {
        guard let (exe, env) = find() else { return Result(note: "T3 Code's t3 command was not found (opening T3 Code once installs it in ~/.t3/bin).") }
        var out: [ClaudeSession] = []
        var shows = 0
        var reached = false
        var seen = Set<String>()
        for root in roots {
            let r = run(exe, ["thread", "list", "--project", root.path, "--json"], in: root, env: env)
            // A repository that is not a T3 Code project has no threads, but T3 Code answered.
            if r.status != 0, r.error.contains("No T3 Code project matches") { reached = true; continue }
            guard r.status == 0, let items = parseList(r.output) else { continue }   // no server, or a shape not read
            reached = true
            // Prioritize active / unsettled threads when calling `thread show` so running work never misses its worktree.
            let prioritized = items.sorted { a, b in
                let activeStatuses: Set = ["running", "waiting", "preparing", "queued", "starting"]
                let sa = activeStatuses.contains(string(a["status"]) ?? "") ? 0 : (((a["settled"] as? Bool) == true) ? 2 : 1)
                let sb = activeStatuses.contains(string(b["status"]) ?? "") ? 0 : (((b["settled"] as? Bool) == true) ? 2 : 1)
                return sa < sb
            }
            for item in prioritized {
                guard let id = string(item["threadId"]), !seen.contains(id) else { continue }
                seen.insert(id)
                let updated = string(item["updatedAt"]) ?? ""
                if let d = date(updated), Date().timeIntervalSince(d) > window { continue }
                if item["parentThreadId"] as? String != nil { continue }   // a fork's or subagent's thread rides on its parent
                var detail = cache[id].flatMap { $0.updated == updated ? $0.detail : nil }
                if detail == nil, shows < showLimit {
                    shows += 1
                    let s = run(exe, ["thread", "show", id, "--json"], in: root, env: env)
                    if s.status == 0, let d = parseDetail(s.output) { detail = d; cache[id] = (updated, d) }
                }
                let effectiveDetail = detail ?? cache[id]?.detail
                // Skip un-fetched overflow threads rather than mis-attributing a worktree thread to the main checkout.
                if effectiveDetail == nil, shows >= showLimit { continue }
                if let session = session(item, detail: effectiveDetail, root: root) { out.append(session) }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return Result(sessions: out, note: reached || roots.isEmpty ? nil : "T3 Code did not answer: is it running?")
    }

    // MARK: Parsing (the shapes of apps/server/src/cli/thread.ts and packages/contracts/src/orchestratorMcp.ts)

    /// `thread list --json`: a bare array (an object holding `threads` or `items` is taken too).
    static func parseList(_ text: String) -> [[String: Any]]? {
        guard let obj = json(text) else { return nil }
        if let a = obj as? [[String: Any]] { return a }
        if let d = obj as? [String: Any] { return (d["threads"] ?? d["items"]) as? [[String: Any]] }
        return nil
    }

    /// `thread show --json`: the thread's object, at the top or under `thread`, plus optional `messages`.
    static func parseDetail(_ text: String) -> Detail? {
        guard let rootObj = json(text) as? [String: Any] else { return nil }
        let d = (rootObj["thread"] as? [String: Any]) ?? rootObj
        let worktree = string(d["worktreePath"]) ?? string(d["cwd"])
        let branch = string(d["branch"])
        let pending = (d["pendingRequestCount"] as? NSNumber)?.intValue ?? 0
        let settled = (d["settled"] as? Bool) ?? false
        let model = string(d["model"])
        let provider = string(d["providerInstanceId"]) ?? string(d["provider"])
        let link = string(d["link"]).flatMap(URL.init(string:))
        var summary: String?
        if let messages = rootObj["messages"] as? [[String: Any]] {
            // Latest user message tells what the thread is currently working on.
            for msg in messages.reversed() {
                guard string(msg["role"])?.lowercased() == "user",
                      let rawText = string(msg["text"]) else { continue }
                if let clean = cleanSnippet(rawText) { summary = clean; break }
            }
        }
        return Detail(worktree: worktree, branch: branch, archived: (d["archived"] as? Bool) ?? false,
                      settled: settled, pending: pending, summary: summary, model: model, provider: provider, link: link)
    }

    /// Condenses a prompt into a clean single-line snippet for the sidebar card.
    static func cleanSnippet(_ raw: String, limit: Int = 140) -> String? {
        // Strip leading XML-like wrapper tags or attachment lines.
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasPrefix("[Attached") }
        let joined = lines.joined(separator: " ")
        let collapsed = joined.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// One list item (and its details, when known) as a session of the rows. A thread whose worktree is not known
    /// belongs to the repository's main checkout, where T3 Code runs a thread without one.
    static func session(_ item: [String: Any], detail: Detail?, root: URL) -> ClaudeSession? {
        guard let id = string(item["threadId"]) else { return nil }
        let raw = string(item["status"]) ?? "idle"
        let live: Set = ["preparing", "queued", "starting", "running"]
        var status = ClaudeSession.Status.idle
        if live.contains(raw) { status = .working }
        if raw == "waiting" || (detail?.pending ?? 0) > 0 { status = .waiting }
        var prs: [ClaudePR] = []
        let list = (item["pullRequests"] as? [[String: Any]]) ?? []
        for p in list {
            guard let u = string(p["url"]).flatMap(URL.init(string:)) else { continue }
            let state = string(p["state"]).flatMap { ClaudePR.State(rawValue: $0.uppercased()) }
            prs.append(ClaudePR(url: u, state: state, branch: detail?.branch))
        }
        if let linked = item["linkedPullRequest"] as? [String: Any], let u = string(linked["url"]).flatMap(URL.init(string:)), !prs.contains(where: { $0.url == u }) {
            let state = string(linked["state"]).flatMap { ClaudePR.State(rawValue: $0.uppercased()) }
            prs.append(ClaudePR(url: u, state: state, branch: detail?.branch))
        }
        let folder = detail?.worktree.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } ?? root.resolvingSymlinksInPath()
        let settled = (item["settled"] as? Bool) ?? (detail?.settled ?? false)
        let model = detail?.model ?? string(item["model"])
        let provider = detail?.provider ?? string(item["providerInstanceId"])
        let link = detail?.link ?? string(item["link"]).flatMap(URL.init(string:))
        return ClaudeSession(folder: folder, repository: root.resolvingSymlinksInPath(), title: string(item["title"]), status: status,
                             branch: detail?.branch, pullRequests: prs.map(\.url), prs: prs, lastActivity: date(string(item["updatedAt"]) ?? ""),
                             running: status != .idle, archived: detail?.archived ?? false, source: .t3, id: id,
                             settled: settled, model: model, provider: provider, summary: detail?.summary, rawStatus: raw, link: link)
    }

    private static func json(_ text: String) -> Any? {
        // Only the JSON: a line of notice before it (an update hint) is skipped.
        guard let start = text.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...].utf8))
    }

    private static func string(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// The switch, the reads and their schedule. One instance (`shared`).
final class T3Sessions {
    static let shared = T3Sessions()
    static let defaultsKey = "t3SessionsShow"

    private init() {
        // A hidden check never asks the person's T3 Code.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--") && $0.hasSuffix("-check") }) { enabledOverride = false }
    }

    var enabledOverride: Bool?
    var enabled: Bool {
        get { enabledOverride ?? UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey); changedSwitch() }
    }

    /// The threads of the last read (none with the switch off).
    private(set) var sessions: [ClaudeSession] = []
    /// Why there are none, when that is worth a line in the sidebar.
    private(set) var note: String?
    /// Told on the main thread when a read changed what the rows show.
    var onChange: (() -> Void)?
    /// The repositories added to Sessions; set by the sessions controller.
    var workspaceRoots: () -> [URL] = { [] }

    /// How often T3 Code is asked while Greenroom is the active app (a read starts one short `t3` per repository).
    static let interval: TimeInterval = 20
    private let queue = DispatchQueue(label: "greenroom-t3sessions", qos: .utility)
    private var cache: [String: (updated: String, detail: T3Reader.Detail)] = [:]
    private var reading = false
    private var timer: Timer?
    private var observers: [Any] = []

    func changedSwitch() {
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard enabled else {
            let had = !sessions.isEmpty || note != nil
            sessions = []; note = nil
            if had { onChange?() }
            return
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.reload() })
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            guard NSApp?.isActive ?? true else { return }   // in the background nobody is looking
            self?.reload()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        reload()
    }

    /// `t3 app <folder>`: the folder's thread in T3 Code's desktop app. `done` gets nil, or why not (main thread).
    static func open(_ folder: URL, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var why: String?
            if let (exe, env) = T3Reader.find() {
                let r = T3Reader.run(exe, ["app", folder.path], in: folder, env: env)
                if r.status != 0 { why = "T3 Code did not open it: is its desktop app running?" }
            } else {
                why = "T3 Code's t3 command was not found (opening T3 Code once installs it in ~/.t3/bin)."
            }
            DispatchQueue.main.async { done(why) }
        }
    }

    /// One read off the main thread; skipped while one is still running.
    func reload() {
        guard enabled, !reading else { return }
        let roots = workspaceRoots()
        reading = true
        var cache = self.cache
        queue.async { [weak self] in
            let result = T3Reader.read(roots: roots, cache: &cache)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                self.cache = cache
                guard self.enabled else { return }
                let same = result.sessions.map(\.shown) == self.sessions.map(\.shown) && result.note == self.note
                self.sessions = result.sessions
                self.note = result.note
                if !same { self.onChange?() }
            }
        }
    }
}
