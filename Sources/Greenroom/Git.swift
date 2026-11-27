import CoreServices
import Foundation

/// Git through `/usr/bin/git`, always off the main thread: a worktree's list, its branch, head, whether it has
/// changes and how far ahead of its upstream it is, and a merge base. Nothing here writes to a repository.
enum Git {
    struct Worktree: Equatable {
        var path: URL
        var head: String
        var branch: String?
        var isBare = false
        var isPrunable = false
    }

    struct State: Equatable {
        var branch: String?
        var head: String
        var dirty: Bool
        var ahead: Int
        /// The newest of the head commit's date and the modified times of the changed files.
        var sourcesDate: Date?
    }

    private static let git = URL(fileURLWithPath: "/usr/bin/git")

    /// Whether `/usr/bin/git` is a real git: without the Command Line Tools it is a stub that offers to install them.
    /// Found out once, with `xcode-select -p`; nothing runs git again when it is not.
    static let available: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // Waits without waitUntilExit, which runs the run loop: on the main thread that let layout and table callbacks
        // run inside this initializer, and anything there that asked for `available` again re-entered it.
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else { return false }
        done.wait()
        return p.terminationStatus == 0
    }()

    /// Switches off what a repository's own configuration could use to run a program: its fsmonitor hook and its hooks.
    private static let safe = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]

    /// Runs git in `dir` and gives its standard output, or nil when it failed or took longer than `timeout`.
    static func run(_ args: [String], in dir: URL, timeout: TimeInterval = 20) async -> String? {
        guard available else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = git
                p.arguments = safe + args
                p.currentDirectoryURL = dir
                var env = ProcessInfo.processInfo.environment
                env["GIT_OPTIONAL_LOCKS"] = "0"      // reading status must not take the index lock a commit needs
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["LC_ALL"] = "C"
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: nil); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }

    /// The main checkout of the repository `folder` is in (the folder itself, or one of its worktrees), or nil when
    /// it is not in a repository with a working tree.
    static func mainCheckout(of folder: URL) async -> URL? {
        guard let out = await run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: folder) else { return nil }
        let common = URL(fileURLWithPath: out.trimmingCharacters(in: .whitespacesAndNewlines))
        if common.lastPathComponent == ".git" { return common.deletingLastPathComponent() }
        // A git submodule's common dir is `<super>/.git/modules/<name>` (not bare): its own toplevel is its checkout.
        guard await run(["rev-parse", "--is-bare-repository"], in: folder)?.trimmingCharacters(in: .whitespacesAndNewlines) == "false" else { return nil }
        return await toplevel(of: folder)
    }

    /// `git rev-parse --show-toplevel`: the root of the worktree `folder` is in, symlinks resolved, or nil when it
    /// is in no working tree.
    static func toplevel(of folder: URL) async -> URL? {
        guard let out = await run(["rev-parse", "--path-format=absolute", "--show-toplevel"], in: folder) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    }

    static func commonDir(of root: URL) -> URL { root.appendingPathComponent(".git", isDirectory: true) }

    static func parseWorktrees(_ porcelain: String) -> [Worktree] {
        var out: [Worktree] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var w = Worktree(path: URL(fileURLWithPath: "/"), head: "")
            var seen = false
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { w.path = URL(fileURLWithPath: String(line.dropFirst(9)), isDirectory: true); seen = true }
                else if line.hasPrefix("HEAD ") { w.head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst(7))
                    w.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
                }
                else if line == "bare" { w.isBare = true }
                else if line.hasPrefix("prunable") { w.isPrunable = true }
            }
            if seen { out.append(w) }
        }
        return out
    }

    /// `git worktree list --porcelain`: the main checkout first, then the linked worktrees. Bare entries and
    /// worktrees whose folder is gone are left out.
    static func worktrees(of repo: URL) async -> [Worktree] {
        guard let out = await run(["worktree", "list", "--porcelain"], in: repo) else { return [] }
        return parseWorktrees(out)
            .filter { !$0.isBare && !$0.isPrunable && FileManager.default.fileExists(atPath: $0.path.path) }
            .map { var w = $0; w.path = w.path.resolvingSymlinksInPath(); return w }
    }

    /// A worktree's branch, head, changes, commits ahead of its upstream, and the date of its newest source change.
    static func state(of worktree: URL) async -> State? {
        async let headOut = run(["rev-parse", "HEAD"], in: worktree)
        async let branchOut = run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: worktree)
        async let aheadOut = run(["rev-list", "--count", "@{upstream}..HEAD"], in: worktree)   // fails with no upstream: 0
        async let dateOut = run(["log", "-1", "--format=%ct"], in: worktree)
        async let statusOut = run(["status", "--porcelain=v1", "-z"], in: worktree, timeout: 8)
        let head = (await headOut?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        let branch = await branchOut?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Freshly initialized repositories have an unborn HEAD (branch exists, no commits yet).
        guard !head.isEmpty || (branch?.isEmpty == false) else { return nil }
        let ahead = Int((await aheadOut)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        var newest = (await dateOut).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.map { Date(timeIntervalSince1970: $0) }
        let status = await statusOut ?? ""
        let entries = status.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        // "XY path" records; a rename or copy is followed by its source path as a record of its own.
        var changed: [String] = []
        var skip = false
        for e in entries {
            if skip { skip = false; continue }
            guard e.count > 3 else { continue }
            changed.append(String(e.dropFirst(3)))
            if e.hasPrefix("R") || e.hasPrefix("C") { skip = true }
        }
        for rel in changed.prefix(500) {
            let f = worktree.appendingPathComponent(rel)
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > (newest ?? .distantPast) { newest = d }
        }
        return State(branch: branch?.isEmpty == false ? branch : nil, head: head, dirty: !changed.isEmpty, ahead: ahead, sourcesDate: newest)
    }

    /// The commit two refs last had in common (what a pull request from `a` against `b` would show), or nil.
    static func mergeBase(_ a: String, _ b: String, in dir: URL) async -> String? {
        guard !a.hasPrefix("-"), !b.hasPrefix("-"), let out = await run(["merge-base", "--", a, b], in: dir) else { return nil }
        let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }
}

/// Reports, through FSEvents, when worktrees come or go, or when a worktree's `HEAD` or a branch moves: the
/// repository's `.git` folder is watched and only those paths count. No polling.
final class WorktreeWatcher {
    let repo: URL
    /// On the main thread.
    var onChange: (() -> Void)?

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "greenroom-worktreewatch", qos: .utility)
    private var pending: DispatchWorkItem?

    init(repo: URL) { self.repo = repo }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.changed(Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let git = Git.commonDir(of: repo).resolvingSymlinksInPath().path
        guard let s = FSEventStreamCreate(nil, callback, &context, [git] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else { FSEventStreamInvalidate(s); FSEventStreamRelease(s); return false }
        stream = s
        return true
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        queue.sync { pending?.cancel(); pending = nil }
    }

    /// Whether a path under `.git` says a worktree appeared, went, switched branch or got a commit.
    static func matters(_ path: String) -> Bool {
        if path.contains("/objects/") { return false }
        if path.hasSuffix("/HEAD") || path.hasSuffix("/HEAD.lock") { return true }
        if path.contains("/refs/heads/") { return true }
        if path.contains("/worktrees/") { return true }
        return false
    }

    /// On the event queue.
    private func changed(_ paths: [String]) {
        guard paths.contains(where: Self.matters) else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in DispatchQueue.main.async { self?.onChange?() } }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
}
