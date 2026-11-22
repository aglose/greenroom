import AppKit
import CoreServices

// The Claude Code link of docs/SESSIONS-PLAN.md ("5. The Claude Code link", "Show my Claude Code sessions").
// Reads, and only reads, three of Claude Code's own files, on this Mac, off the main thread, when the switch in
// Settings is on. They are not an interface Claude Code promises: every field is optional here, a file that does not
// parse is skipped without a word, and when nothing parses the rows stay plain worktree rows with one line saying so.

/// A pull request a Claude Code session opened, with its state when the desktop app recorded one.
struct ClaudePR: Equatable {
    enum State: String { case open = "OPEN", merged = "MERGED", closed = "CLOSED" }
    var url: URL
    var state: State?
    /// The branch it is from, when known: a main checkout's sessions open pull requests from many branches.
    var branch: String?
    var number: Int? { Int(url.lastPathComponent) }
}

/// What is known of one Claude Code session.
struct ClaudeSession: Equatable {
    enum Status: String { case working, idle, waiting }

    /// The session's working folder (symlinks resolved): a worktree, or a main checkout.
    var folder: URL
    /// The repository's main checkout when the files name it (the desktop app's `originCwd`).
    var repository: URL?
    var title: String?
    var status: Status = .idle
    var branch: String?
    var pullRequests: [URL] = []
    /// The same pull requests with their state and branch (the desktop app's files have them; a transcript's do not).
    var prs: [ClaudePR] = []
    var lastActivity: Date?
    /// Whether the process of a `~/.claude/sessions/<pid>.json` file is still there.
    var running = false
    var archived = false
    /// Who keeps it: a Claude Code session, or a T3 Code thread (T3Sessions.swift) shown the same way.
    enum Source: String { case claude, t3 }
    var source: Source = .claude
    /// The T3 Code thread's id (nil for Claude Code's sessions).
    var id: String?

    var pullRequest: URL? { pullRequests.first }
    /// What a row shows: the same session without the time of its last activity, which moves with every write.
    var shown: ClaudeSession { var c = self; c.lastActivity = nil; return c }
}

/// Where the three sources are. Injectable, so a check can point the reader at fixtures.
struct ClaudeRoots {
    /// `~/.claude/sessions`
    var sessions: URL
    /// `~/Library/Application Support/Claude/claude-code-sessions`
    var desktop: URL
    /// `~/.claude/projects`
    var projects: URL

    static var real: ClaudeRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ClaudeRoots(sessions: home.appendingPathComponent(".claude/sessions", isDirectory: true),
                           desktop: home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true),
                           projects: home.appendingPathComponent(".claude/projects", isDirectory: true))
    }

    var all: [URL] { [sessions, desktop, projects] }
}

/// A repository that has Claude sessions but was not added to Sessions.
struct ClaudeOffer: Equatable {
    var repository: URL
    var count: Int
}

// MARK: Reader

/// Reads the three sources into `ClaudeSession` values. Pure of UI; safe on any queue.
enum ClaudeReader {
    struct Result {
        var sessions: [ClaudeSession] = []
        /// Files looked at, and how many of them gave a session: when the first is above zero and the second is not,
        /// Claude Code's files have changed shape.
        var seen = 0
        var parsed = 0
    }

    /// Every file the reader opened, for a check to assert that nothing was opened with the switch off.
    private static let lock = NSLock()
    private static var openedFiles: [String] = []
    static var opened: [String] { lock.lock(); defer { lock.unlock() }; return openedFiles }
    static func resetOpened() { lock.lock(); openedFiles = []; lock.unlock() }
    private static func note(_ url: URL) { lock.lock(); openedFiles.append(url.path); lock.unlock() }

    /// A record before the sources are joined.
    struct Record {
        var ids: Set<String> = []
        var folder: String?
        var repository: String?
        var title: String?
        var pidName: String?
        var busy = false
        var waiting = false
        var alive = false
        var pid: Int32?
        var procStart: Date?
        var branch: String?
        var prs: [URL] = []
        var prInfo: [URL: (state: ClaudePR.State?, branch: String?)] = [:]
        var date: Date?
        var archived = false
        var fromDesktop = false
    }

    /// What the reader keeps between reads: the parsed record of each file, by path, valid while the file's modified
    /// time and size are the same. Only the process check is redone each time.
    final class Cache {
        struct Entry { var mtime: Date?; var size: Int?; var record: Record? }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        fileprivate func get(_ path: String, _ mtime: Date?, _ size: Int?) -> Entry? {
            lock.lock(); defer { lock.unlock() }
            guard let e = entries[path], e.mtime == mtime, e.size == size else { return nil }
            return e
        }
        fileprivate func set(_ path: String, _ e: Entry) { lock.lock(); entries[path] = e; lock.unlock() }
        fileprivate func keep(_ paths: Set<String>) { lock.lock(); entries = entries.filter { paths.contains($0.key) }; lock.unlock() }
    }

    /// Transcripts not touched for this long are not opened at all.
    static let window: TimeInterval = 30 * 86_400

    private static func cached(_ file: URL, _ cache: Cache?, seen: inout Set<String>, make: (URL) -> Record?) -> Record? {
        let v = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        seen.insert(file.path)
        if let hit = cache?.get(file.path, v?.contentModificationDate, v?.fileSize) { return hit.record }
        let r = make(file)
        cache?.set(file.path, Cache.Entry(mtime: v?.contentModificationDate, size: v?.fileSize, record: r))
        return r
    }

    static func read(_ roots: ClaudeRoots, cache: Cache? = nil) -> Result {
        var seenPaths = Set<String>()
        defer { cache?.keep(seenPaths) }
        var result = Result()
        var records: [Record] = []

        // 1. Live terminal sessions.
        for file in files(in: roots.sessions, ext: "json", depth: 1) {
            result.seen += 1
            guard var r = cached(file, cache, seen: &seenPaths, make: { json($0).flatMap { Record(pid: $0) } }) else { continue }
            if let pid = r.pid { r.alive = isAlive(pid, startedBefore: r.procStart) }
            result.parsed += 1
            records.append(r)
        }
        // 2. The desktop app's sessions.
        for file in files(in: roots.desktop, ext: "json", depth: 6) where file.lastPathComponent.hasPrefix("local_") {
            result.seen += 1
            guard let r = cached(file, cache, seen: &seenPaths, make: { f in
                json(f).flatMap { Record(desktop: $0) }.map { var r = $0; r.ids.insert(f.deletingPathExtension().lastPathComponent); return r }
            }) else { continue }
            result.parsed += 1
            records.append(r)
        }
        // 3. Transcripts: the first line and the end only.
        let folders = (try? FileManager.default.contentsOfDirectory(at: roots.projects, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            for file in files(in: folder, ext: "jsonl", depth: 1) {
                result.seen += 1
                // Old transcripts are not opened: their modified time says they are out of the window.
                if let m = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(m) > window { continue }
                guard let r = cached(file, cache, seen: &seenPaths, make: { f in
                    Record(transcript: f).map { var r = $0; r.ids.insert(f.deletingPathExtension().lastPathComponent); return r }
                }) else { continue }
                result.parsed += 1
                records.append(r)
            }
        }
        result.sessions = join(records)
        return result
    }

    /// Records that share an id (the CLI's session id, the desktop app's) are one session.
    private static func join(_ records: [Record]) -> [ClaudeSession] {
        var groups: [Record] = []
        for r in records {
            if let i = groups.firstIndex(where: { !$0.ids.isDisjoint(with: r.ids) }) {
                groups[i] = merge(groups[i], r)
                // A record may have bridged two earlier groups.
                var j = i + 1
                while j < groups.count {
                    if !groups[i].ids.isDisjoint(with: groups[j].ids) { groups[i] = merge(groups[i], groups[j]); groups.remove(at: j) } else { j += 1 }
                }
            } else {
                groups.append(r)
            }
        }
        var resolved: [String: URL] = [:]   // many sessions share a folder: each is resolved once
        func res(_ p: String) -> URL { if let u = resolved[p] { return u }; let u = resolve(p); resolved[p] = u; return u }
        return groups.compactMap { g in
            guard let folder = g.folder else { return nil }
            var status = ClaudeSession.Status.idle
            if g.alive && g.busy { status = .working }
            if g.waiting && !g.archived { status = .waiting }
            let prs = g.prs.map { ClaudePR(url: $0, state: g.prInfo[$0]?.state, branch: g.prInfo[$0]?.branch) }
            return ClaudeSession(folder: res(folder), repository: g.repository.map(res), title: g.title ?? g.pidName, status: status,
                                 branch: g.branch, pullRequests: g.prs, prs: prs, lastActivity: g.date, running: g.alive, archived: g.archived)
        }
    }

    /// The first record's fields win where it has them (the desktop app's title over a transcript's, say); the
    /// order the sources are read in is the order of trust.
    private static func merge(_ a: Record, _ b: Record) -> Record {
        var r = a
        r.ids.formUnion(b.ids)
        // The desktop app's own title is what the person sees there.
        if b.fromDesktop, let t = b.title { r.title = t } else { r.title = a.title ?? b.title }
        r.pidName = a.pidName ?? b.pidName
        r.folder = a.folder ?? b.folder
        r.repository = a.repository ?? b.repository
        r.busy = a.busy || b.busy
        r.waiting = a.waiting || b.waiting
        r.alive = a.alive || b.alive
        r.branch = a.branch ?? b.branch
        for u in b.prs where !r.prs.contains(u) { r.prs.append(u) }
        for (u, info) in b.prInfo where r.prInfo[u]?.state == nil { r.prInfo[u] = info }
        r.date = [a.date, b.date].compactMap { $0 }.max()
        r.archived = a.archived || b.archived
        r.fromDesktop = a.fromDesktop || b.fromDesktop
        return r
    }

    // MARK: Files

    private static func files(in dir: URL, ext: String, depth: Int) -> [URL] {
        guard depth > 0, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [URL] = []
        for item in items {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                out += files(in: item, ext: ext, depth: depth - 1)
            } else if item.pathExtension == ext {
                out.append(item)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// A whole small file as a JSON object, or nil (unreadable, empty, truncated, not an object, or very large).
    fileprivate static func json(_ file: URL) -> [String: Any]? {
        note(file)
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 1_000_000), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The first line, and the lines of the last `tail` bytes. Never the whole file.
    fileprivate static func edges(of file: URL, tail: Int = 32_768) -> (first: Data?, last: [Data], modified: Date?) {
        note(file)
        guard let h = try? FileHandle(forReadingFrom: file) else { return (nil, [], nil) }
        defer { try? h.close() }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
        guard let head = try? h.read(upToCount: 65_536), !head.isEmpty else { return (nil, [], modified) }
        let first = head.split(separator: 10, maxSplits: 1, omittingEmptySubsequences: true).first.map { Data($0) }
        let size = (try? h.seekToEnd()) ?? 0
        var last: [Data] = []
        if size <= UInt64(head.count) {
            // The whole file is in `head`: every line after the first counts.
            last = Array(head.split(separator: 10, omittingEmptySubsequences: true).dropFirst().map { Data($0) })
        } else {
            let from = size > UInt64(tail) ? size - UInt64(tail) : 0
            try? h.seek(toOffset: from)
            if let t = try? h.readToEnd() {
                var lines = t.split(separator: 10, omittingEmptySubsequences: true).map { Data($0) }
                if from > 0, !lines.isEmpty { lines.removeFirst() }   // cut in the middle
                last = lines
            }
        }
        return (first, last, modified)
    }

    /// Whether a process with this id exists and is the one the file was written by: a process that began more than a
    /// minute after the file says it started is a later process that reused the id.
    static func isAlive(_ pid: Int32, startedBefore start: Date? = nil) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        if let start, let actual = startTime(of: pid), actual.timeIntervalSince(start) > 60 { return false }
        return true
    }

    static func startTime(of pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1e6)
    }

    fileprivate static func resolve(_ path: String) -> URL { URL(fileURLWithPath: path).resolvingSymlinksInPath() }

    fileprivate static func string(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// A 32-bit integer from a JSON number or a numeric string; nil for a boolean, a fraction, or anything that does
    /// not fit (never a trap).
    fileprivate static func int32(_ v: Any?) -> Int32? {
        if let n = v as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            guard d.isFinite, d == d.rounded() else { return nil }
            return Int32(exactly: d)
        }
        return (v as? String).flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    fileprivate static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            guard d.isFinite, abs(d) < 1e14 else { return nil }
            return Date(timeIntervalSince1970: d > 1e11 ? d / 1000 : d)
        }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    fileprivate static func url(_ v: Any?) -> URL? {
        if let s = string(v), let u = URL(string: s), u.scheme != nil { return u }
        if let d = v as? [String: Any] { return url(d["url"] ?? d["prUrl"] ?? d["html_url"]) }
        return nil
    }

}

extension ClaudeReader.Record {
    /// `~/.claude/sessions/<pid>.json`: pid, sessionId, cwd, name, status, updatedAt, hostSessionId.
    init?(pid obj: [String: Any]) {
        self.init()
        folder = ClaudeReader.string(obj["cwd"])
        guard folder != nil else { return nil }
        for k in ["sessionId", "hostSessionId"] { if let s = ClaudeReader.string(obj[k]) { ids.insert(s) } }
        pidName = ClaudeReader.string(obj["name"])
        busy = (obj["status"] as? String) == "busy"
        pid = ClaudeReader.int32(obj["pid"])
        procStart = ClaudeReader.date(obj["procStart"] ?? obj["startedAt"])
        date = ClaudeReader.date(obj["updatedAt"])
    }

    /// A desktop app file: title, cwd, originCwd, folderPlace, isArchived, prs, lastActivityAt,
    /// interruptedAwaitingPerson, cliSessionId.
    init?(desktop obj: [String: Any]) {
        self.init()
        let place = obj["folderPlace"] as? [String: Any]
        let origin = place?["origin"] as? [String: Any]
        folder = ClaudeReader.string(obj["cwd"]) ?? ClaudeReader.string(place?["cwd"]) ?? ClaudeReader.string(obj["originCwd"])
        guard folder != nil else { return nil }
        repository = ClaudeReader.string(obj["originCwd"]) ?? ClaudeReader.string(origin?["cwd"])
        for k in ["cliSessionId", "sessionId"] { if let s = ClaudeReader.string(obj[k]) { ids.insert(s) } }
        title = ClaudeReader.string(obj["title"])
        archived = (obj["isArchived"] as? Bool) ?? false
        waiting = (obj["interruptedAwaitingPerson"] as? Bool) ?? false
        date = ClaudeReader.date(obj["lastActivityAt"])
        if let list = obj["prs"] as? [Any] {
            for item in list {
                guard let u = ClaudeReader.url(item) else { continue }
                if !prs.contains(u) { prs.append(u) }
                let d = item as? [String: Any]
                prInfo[u] = (ClaudeReader.string(d?["state"]).flatMap { ClaudePR.State(rawValue: $0.uppercased()) }, ClaudeReader.string(d?["branch"]))
            }
        }
        fromDesktop = true
    }

    /// A transcript: cwd and gitBranch on its lines, a "custom-title" line, a "pr-link" line.
    init?(transcript file: URL) {
        self.init()
        let e = ClaudeReader.edges(of: file)
        var lines: [[String: Any]] = []
        for d in ([e.first].compactMap { $0 }) + e.last {
            if let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { lines.append(o) }
        }
        guard !lines.isEmpty else { return nil }
        // The first line that has a folder, the last that has a branch.
        folder = lines.compactMap { ClaudeReader.string($0["cwd"]) }.first
        guard folder != nil else { return nil }
        branch = lines.compactMap { ClaudeReader.string($0["gitBranch"]) }.last
        for o in lines {
            switch o["type"] as? String {
            case "custom-title": if let t = ClaudeReader.string(o["customTitle"]) { title = t }
            case "pr-link": if let u = ClaudeReader.url(o["prUrl"] ?? o["url"] ?? o["pr"]), !prs.contains(u) { prs.append(u) }
            default: break
            }
        }
        date = e.modified
    }
}

// MARK: Model

/// The reader, its switch and its refresh. One instance (`shared`) for the app; roots are replaceable.
final class ClaudeSessions {
    static let shared = ClaudeSessions()
    static let defaultsKey = "claudeSessionsShow"

    var roots = ClaudeRoots.real

    private init() {
        // A hidden check (`--<name>-check`) never reads the real folders: it points `roots` at its fixtures itself.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--") && $0.hasSuffix("-check") }) {
            enabledOverride = false
            let none = URL(fileURLWithPath: "/nonexistent-greenroom-check", isDirectory: true)
            roots = ClaudeRoots(sessions: none, desktop: none, projects: none)
        }
    }
    /// A check's own answer for the switch, so it never writes the person's preference.
    var enabledOverride: Bool?
    var enabled: Bool {
        get { enabledOverride ?? UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey); changedSwitch() }
    }

    /// Every session read at the last refresh (none with the switch off).
    private(set) var sessions: [ClaudeSession] = []
    /// One line for the sidebar when files were found and none could be read; nil otherwise.
    private(set) var note: String?
    private(set) var offers: [ClaudeOffer] = []
    /// Told on the main thread after each refresh.
    var onChange: (() -> Void)?

    private var stream: FSEventStreamRef?
    private var watching: [String] = []
    private let queue = DispatchQueue(label: "greenroom-claudesessions", qos: .utility)
    /// The debounce's one pending reload and when the burst of events it covers began. Under `lock`, since the
    /// event queue sets it and the main thread cancels it; nothing waits on the queue.
    private let lock = NSLock()
    private var pending: DispatchWorkItem?
    private var burstStart: Date?
    private var scans = 0
    private let cache = ClaudeReader.Cache()
    private var generation = 0
    private var mainCheckouts: [String: URL?] = [:]
    private var loadedOnce = false

    deinit { stopWatching() }

    /// Starts or stops according to the switch, then reads once. Cheap to call again.
    func changedSwitch() {
        if enabled { startWatching() } else { stopWatching() }
        reload()
    }

    /// Reads the three sources on a utility queue and publishes the answer on the main thread. With the switch off
    /// it opens nothing and publishes an empty answer. `quiet`: a reload the watcher asked for tells no one when no
    /// session changed in a way a row shows (a busy session writes every second or so).
    func reload(quiet: Bool = false) {
        generation += 1
        let mine = generation
        guard enabled else {
            sessions = []; note = nil; offers = []; loadedOnce = false
            onChange?()
            return
        }
        let roots = self.roots, cache = self.cache
        lock.lock(); scans += 1; lock.unlock()
        queue.async { [weak self] in
            let result = ClaudeReader.read(roots, cache: cache)
            self?.lock.lock(); self?.scans -= 1; self?.lock.unlock()
            DispatchQueue.main.async {
                guard let self, mine == self.generation, self.enabled else { return }
                let note = result.seen > 0 && result.parsed == 0
                if quiet, self.loadedOnce, note == (self.note != nil), result.sessions.map(\.shown) == self.sessions.map(\.shown) {
                    self.sessions = result.sessions   // the times, for ranking, without telling anyone
                    return
                }
                self.loadedOnce = true
                self.sessions = result.sessions
                self.note = result.seen > 0 && result.parsed == 0
                    ? "Claude Code's session files could not be read (a newer version?), so rows show branches."
                    : nil
                self.refreshOffers(mine)   // tells `onChange`, once, when the offers are known
            }
        }
    }

    /// Whether a read is under way (a check waits for none before it counts opened files).
    var isScanning: Bool { lock.lock(); defer { lock.unlock() }; return scans > 0 }

    /// Gives each row its Claude session (nil with the switch off), carrying the pull requests of every session of
    /// that worktree. Each path is resolved once and sessions are matched on strings: with hundreds of sessions and
    /// a dozen worktrees, resolving inside the match ran to hundreds of thousands of file system calls on the main
    /// thread at every write Claude Code made.
    func attach(_ rows: [Session]) -> [Session] {
        let pool = (enabled ? sessions : []) + T3Sessions.shared.sessions   // T3 Code's threads, when its switch is on
        guard !pool.isEmpty else { return rows.map { var r = $0; r.claude = nil; return r } }
        let paths = rows.map { $0.worktree.resolvingSymlinksInPath().path }
        var byOwner: [String: [ClaudeSession]] = [:]
        for s in pool {   // `folder` was resolved when read
            if let o = Self.owner(path: s.folder.path, among: paths) { byOwner[o, default: []].append(s) }
        }
        return zip(rows, paths).map { row, path in
            var r = row
            guard let mine = byOwner[path], var best = mine.max(by: { Self.rank($0) < Self.rank($1) }) else { r.claude = nil; return r }
            for s in mine { for pr in s.prs where !best.prs.contains(where: { $0.url == pr.url }) { best.prs.append(pr) } }
            r.claude = best
            return r
        }
    }

    /// `owner(of:among:)` on paths already resolved.
    static func owner(path f: String, among worktrees: [String]) -> String? {
        var best: String?
        for p in worktrees {
            guard f == p || f.hasPrefix(p.hasSuffix("/") ? p : p + "/") else { continue }
            if best == nil || p.count > best!.count { best = p }
        }
        return best
    }

    /// The worktree a folder belongs to: the folder itself or the deepest of `worktrees` above it (matched on whole
    /// path components, so `/a/app` is not above `/a/app-2`, and a worktree nested in the main checkout wins over it).
    static func owner(of folder: URL, among worktrees: [URL]) -> String? {
        owner(path: folder.resolvingSymlinksInPath().path, among: worktrees.map { $0.resolvingSymlinksInPath().path })
    }

    /// The best session of a worktree: not archived over archived, running over not, then the most recent. `among`
    /// is every worktree of the rows, so a session started in a subfolder finds its worktree.
    static func best(for worktree: URL, among all: [URL] = [], in list: [ClaudeSession]) -> ClaudeSession? {
        let path = worktree.resolvingSymlinksInPath().path
        let paths = (all + [worktree]).map { $0.resolvingSymlinksInPath().path }
        return list.filter { owner(path: $0.folder.path, among: paths) == path }.max { rank($0) < rank($1) }
    }

    fileprivate static func rank(_ s: ClaudeSession) -> (Int, Int, Date) { (s.archived ? 0 : 1, s.running ? 1 : 0, s.lastActivity ?? .distantPast) }

    // MARK: Offers

    /// The workspaces changed: the offers are worked out again from the sessions already read.
    func workspacesChanged() {
        guard enabled else { return }
        refreshOffers(generation)
    }

    /// Repositories with live-ish Claude sessions (not archived, active in the last 30 days or running) that are not
    /// among `workspaces`' main checkouts. The main checkout of a folder is asked of git once.
    private func refreshOffers(_ mine: Int) {
        let added = Set(workspaceRoots().map { $0.resolvingSymlinksInPath().path })
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let recent = sessions.filter { !$0.archived && ($0.running || ($0.lastActivity ?? .distantPast) > cutoff) }
        let known = mainCheckouts
        Task { @MainActor in
            var found: [String: (URL, Int)] = [:]
            var learned = known
            var done = Set<String>()
            var perFolder: [String: Int] = [:]
            for s in recent { perFolder[s.folder.path, default: 0] += 1 }
            for s in recent {
                let key = s.folder.path
                guard !done.contains(key) else { continue }
                var repo: URL?
                if let r = s.repository, FileManager.default.fileExists(atPath: r.path) { repo = r }
                else if let cached = learned[key] { repo = cached }
                else { repo = await Git.mainCheckout(of: s.folder)?.resolvingSymlinksInPath(); learned[key] = .some(repo) }
                guard let repo else { continue }
                _ = done.insert(key)
                if added.contains(repo.path) { continue }
                found[repo.path] = (repo, (found[repo.path]?.1 ?? 0) + (perFolder[key] ?? 0))
            }
            guard mine == self.generation else { return }
            self.mainCheckouts = learned
            self.offers = found.values.map { ClaudeOffer(repository: $0.0, count: $0.1) }.sorted { ($0.count, $1.repository.path) > ($1.count, $0.repository.path) }
            self.onChange?()
        }
    }

    // MARK: FSEvents

    func startWatching() {
        let existing = roots.all.filter { FileManager.default.fileExists(atPath: $0.path) }.map { $0.resolvingSymlinksInPath().path }
        guard !existing.isEmpty, existing != watching else { return }
        stopWatching()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ClaudeSessions>.fromOpaque(info).takeUnretainedValue().changed()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &context, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else { FSEventStreamInvalidate(s); FSEventStreamRelease(s); return }
        stream = s
        watching = existing
    }

    func stopWatching() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        watching = []
        lock.lock(); pending?.cancel(); pending = nil; burstStart = nil; lock.unlock()   // a read already running is dropped by `generation`
    }

    /// On the event queue: coalesced, one reload 1.5 s after the last change, but never more than 6 s after the
    /// first of a burst (a busy session writes all the time: its status dot must not wait for it to stop).
    private func changed() {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if pending != nil, let start = burstStart, now.timeIntervalSince(start) >= 6 { return }   // already due
        pending?.cancel()
        if pending == nil { burstStart = now }
        let item = DispatchWorkItem { [weak self] in
            self?.lock.lock(); self?.pending = nil; self?.burstStart = nil; self?.lock.unlock()
            DispatchQueue.main.async { self?.reload(quiet: true) }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    /// The main checkouts of the workspaces added; set by the sessions controller. Offers leave these out.
    var workspaceRoots: () -> [URL] = { [] }

    // MARK: Open in Claude

    /// Brings Claude up. SS1 (docs/SESSIONS-PLAN.md, spikes): if the desktop app has a `claude://` link that opens a
    /// given session, build it from `session` here; until the format is known this only activates the app.
    @discardableResult
    static func openInClaude(_ session: ClaudeSession?) -> Bool {
        let ws = NSWorkspace.shared
        guard let app = ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else { return false }
        ws.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}

// MARK: Row pieces

enum ClaudeUI {
    /// The status dot of a row: green working, grey idle, orange waiting for you; nothing for a session that is
    /// archived or not running (a finished one is not shown as live).
    static func dot(for c: ClaudeSession?) -> NSView? {
        guard let c else { return nil }
        let (symbol, tint, label): (String, NSColor, String)
        if c.archived { (symbol, tint, label) = ("circle.dotted", .tertiaryLabelColor, "Claude session archived") }
        else if c.status == .waiting { (symbol, tint, label) = ("exclamationmark.circle.fill", .systemOrange, "Claude is waiting for you") }
        else if c.running && c.status == .working { (symbol, tint, label) = ("circle.fill", .systemGreen, "Claude is working") }
        else if c.running { (symbol, tint, label) = ("circle.fill", .secondaryLabelColor, "Claude is idle") }
        else { (symbol, tint, label) = ("circle", .tertiaryLabelColor, "Claude session finished") }
        let v = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage())
        v.contentTintColor = tint
        v.toolTip = label
        v.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentCompressionResistancePriority(.required, for: .horizontal)
        return v
    }

    /// Set when the person closes the prompt below; it is not shown again.
    static let titlesPromptHiddenKey = "claudeTitlesPromptHidden"

    /// Whether the sidebar offers to show Claude Code's titles: the switch is off, the person has not closed the
    /// offer, and Claude Code is on this Mac. Only `~/.claude`'s existence is looked at, never a file in it, so the
    /// switch stays the one thing that lets Greenroom read them. Never in a check (it sets its own switch).
    static var offersTitles: Bool {
        let claude = ClaudeSessions.shared
        guard claude.enabledOverride == nil, !claude.enabled, !UserDefaults.standard.bool(forKey: titlesPromptHiddenKey) else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        return FileManager.default.fileExists(atPath: home.path)
    }

    /// "Show Claude Code's sessions": clicking the row turns the switch on; the cross closes the offer.
    static func titlesPromptCell(onHide: @escaping () -> Void) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: "Show Claude Code's sessions")
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: "Titles, pull requests and what to add")
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = ClosureButton(symbol: "xmark", tip: "Don't offer this again (it stays in Settings)", handler: onHide)
        close.contentTintColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, text, close])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 6)
        stack.toolTip = "Reads Claude Code's session files on this Mac, only to name rows. The same as \"Show my Claude Code sessions\" in Settings."
        return stack
    }

    /// "3 Claude sessions in a repository you have not added", and the folder under it.
    static func offerCell(_ offer: ClaudeOffer) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: "\(offer.count) Claude session\(offer.count == 1 ? "" : "s") in a repository you have not added")
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: "Add \(offer.repository.lastPathComponent) to Sessions")
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let stack = NSStackView(views: [icon, text])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        return stack
    }
}
