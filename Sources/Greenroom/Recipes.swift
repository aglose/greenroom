import Foundation

// Recipes (docs/SESSIONS-PLAN.md, "2. Builds"): an executable run with the person's own tools, told what to build
// through its environment, which leaves an APK where it is told to. `Recipe` itself (executable + arguments) is
// declared with the model in Sessions.swift so a workspace's settings round-trip.

extension Recipe {
    /// The recipes that ship in `Resources/recipes/`: the runner, the queue and the UI take any name listed.
    static let builtInNames = ["local", "ci", "remote"]

    /// Where the bundled recipes are: the app's Resources, else (a `swift run` build) the source tree's.
    static var bundledFolder: URL {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("recipes", isDirectory: true),
           FileManager.default.fileExists(atPath: r.path) { return r }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/recipes", isDirectory: true)
    }

    /// A built-in recipe by name, or nil when there is none of that name.
    static func builtIn(_ name: String) -> Recipe? {
        guard builtInNames.contains(name) else { return nil }
        return Recipe(executable: bundledFolder.appendingPathComponent(name + ".sh").path)
    }

    /// What a Build records as its source: "ci" and "remote" are theirs, anything else (local, a custom
    /// executable) was built from the worktree as it is.
    static func source(ofRecipeNamed name: String) -> Build.Source {
        switch name {
        case "ci": return .ci
        case "remote": return .remote
        default: return .local
        }
    }
}

extension Workspace {
    /// A recipe by name: the workspace's own (a custom one) first, then the built-in of that name.
    func recipe(named name: String) -> Recipe? { recipes[name] ?? Recipe.builtIn(name) }

    /// Every recipe name offered, built-ins first; "ci" only for a repository with a GitHub remote.
    var recipeNames: [String] {
        Recipe.builtInNames.filter { $0 != "ci" || recipes["ci"] != nil || GitHubRemote.has(root) }
            + recipes.keys.filter { !Recipe.builtInNames.contains($0) }.sorted()
    }

    /// The name of the recipe the Build button runs: the last one chosen for this workspace, else "local".
    var defaultRecipeName: String {
        get {
            let n = UserDefaults.standard.string(forKey: "buildRecipe." + root.path) ?? "local"
            return recipe(named: n) != nil ? n : "local"
        }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "buildRecipe." + root.path) }
    }
}

/// What a recipe is told about what to build: the plan's environment contract.
struct RecipeJob {
    var worktree: URL
    var repo: URL
    var ref: String
    var sha: String
    var dirty: Bool
    var module: String
    var variant: String
    /// Where the recipe writes the APK.
    var out: URL
    /// The workspace's recipe settings (`Workspace.recipeEnvironment`), beside the contract's variables.
    var extra: [String: String] = [:]

    var environment: [String: String] {
        extra.merging([
            "GREENROOM_WORKTREE": worktree.path, "GREENROOM_REPO": repo.path, "GREENROOM_REF": ref, "GREENROOM_SHA": sha,
            "GREENROOM_DIRTY": dirty ? "1" : "0", "GREENROOM_MODULE": module, "GREENROOM_VARIANT": variant, "GREENROOM_OUT": out.path,
        ]) { _, contract in contract }
    }
}

enum RecipeOutcome: Equatable {
    case built
    case failed(String)
    case cancelled
}

/// A child process in a group of its own (so the whole tree can be ended), its stdout and stderr on one pipe.
enum ProcessGroup {
    struct Child { var pid: pid_t; var fd: Int32 }

    static func spawn(_ exe: String, _ args: [String], env: [String: String], cwd: String?) -> (Child?, String) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return (nil, "could not make a pipe") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // The app ignores SIGTERM (it quits through its own handler) and ignored signals survive exec: a recipe would
        // never hear a cancel, and a shell cannot trap what it inherited as ignored. Default dispositions, nothing blocked.
        var noSignals = sigset_t(), allSignals = sigset_t()
        sigemptyset(&noSignals); sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attr, 0)   // a group of its own, led by the child
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, exe, &actions, &attr, argv, envp)
        close(fds[1])
        guard rc == 0 else { close(fds[0]); return (nil, String(cString: strerror(rc))) }
        return (Child(pid: child, fd: fds[0]), "")
    }

    struct Drained { var status: Int32; var timedOut: Bool }

    /// Reads the child's output until it has exited and its pipe is drained, calling `onData`. The pipe being closed
    /// (a recipe that closes stdout and goes on) does not end the wait; the child's exit does. After the exit a
    /// grace of a second for a pipe a grandchild still holds. At `deadline` the whole group gets SIGTERM, so a recipe's trap can clean up (a remote sandbox to stop), and SIGKILL `grace` seconds later (at once with 0).
    /// `reaped` runs the moment the child is reaped, so a later kill of its pid can be skipped.
    static func drain(_ c: Child, deadline: Date, grace: TimeInterval = 0, onData: (Data) -> Void, reaped: () -> Void) -> Drained {
        var status: Int32 = 0
        var exited = false, eof = false, timedOut = false
        var exitedAt: Date?
        var killedAt: Date?
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            if !eof {
                var pfd = pollfd(fd: c.fd, events: Int16(POLLIN), revents: 0)
                let n = poll(&pfd, 1, 100)
                if n > 0 {
                    let got = read(c.fd, &buf, buf.count)
                    if got > 0 { onData(Data(buf[0..<got])); continue }
                    if got == 0 { eof = true }
                }
            } else if !exited {
                usleep(100_000)
            }
            if !exited, waitpid(c.pid, &status, WNOHANG) == c.pid { exited = true; exitedAt = Date(); reaped() }
            if exited && (eof || Date().timeIntervalSince(exitedAt!) > 1) { break }
            if !timedOut, Date() > deadline {
                timedOut = true
                if grace > 0 { killpg(c.pid, SIGTERM) } else { killpg(c.pid, SIGKILL); killedAt = Date() }
            }
            if timedOut, killedAt == nil, Date() > deadline.addingTimeInterval(grace) { killpg(c.pid, SIGKILL); killedAt = Date() }
            if let k = killedAt, Date() > k.addingTimeInterval(5), !exited { break }   // unkillable: give up waiting
        }
        close(c.fd)
        if exited { killpg(c.pid, SIGKILL) }   // whatever is left of the group
        return Drained(status: status, timedOut: timedOut)
    }
}

/// The person's own environment, for the recipes: an app started from Finder has a bare one (no Homebrew, no
/// JAVA_HOME). Asked once of the login shell, off the main thread, with a deadline, and kept.
enum LoginEnvironment {
    private static let queue = DispatchQueue(label: "greenroom-login-env")
    private static var cached: (env: [String: String], note: String?)?
    /// For a check: what the recipes get instead of asking the shell.
    static var override: [String: String]?
    /// For a check: a stand-in login shell, and how long it may take.
    static var shellOverride: String?
    static var deadline: TimeInterval = 8
    private static let keys = ["PATH", "JAVA_HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT"]

    /// The environment a recipe starts with: this process's, with PATH, JAVA_HOME and ANDROID_HOME taken from the
    /// login shell where it knows them, and a line for the build log when that did not work (never values). Blocks
    /// for at most the deadline the first time: call it off the main thread.
    static func resolve() -> (env: [String: String], note: String?) {
        var env = ProcessInfo.processInfo.environment
        var note: String?
        var login: [String: String]
        if let o = override { login = o } else { (login, note) = shell() }
        if let p = login["PATH"], !p.isEmpty {
            // The shell's entries first, then any this process had that the shell did not.
            var seen = Set<String>(), parts: [String] = []
            for e in (p + ":" + (env["PATH"] ?? "")).split(separator: ":").map(String.init) where seen.insert(e).inserted { parts.append(e) }
            env["PATH"] = parts.joined(separator: ":")
        }
        for k in keys where k != "PATH" {
            if env[k]?.isEmpty ?? true, let v = login[k], !v.isEmpty { env[k] = v }
        }
        return (env, note)
    }

    static func reset() { queue.sync { cached = nil } }

    /// The person's login shell, from the account database (an app started from Finder may have no SHELL).
    private static func loginShell() -> String {
        if let o = shellOverride { return o }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }

    private static func shell() -> ([String: String], String?) {
        queue.sync {
            if let c = cached { return (c.env, c.note) }
            let (env, note) = ask()
            cached = (env, note)
            return (env, note)
        }
    }

    /// `$SHELL -l -i -c /usr/bin/env`: the same in zsh, bash and fish. The shell has its own process group and a
    /// deadline, after which the group gets SIGKILL: a startup file that waits or starts a daemon holding the pipe
    /// cannot hold a build.
    private static func ask() -> ([String: String], String?) {
        let sh = loginShell()
        let (child, why) = ProcessGroup.spawn(sh, ["-l", "-i", "-c", "/usr/bin/env"], env: ProcessInfo.processInfo.environment, cwd: nil)
        guard let child else { return ([:], "note: could not start the login shell (\(why)); the recipe has the app's own environment") }
        var data = Data()
        let r = ProcessGroup.drain(child, deadline: Date().addingTimeInterval(deadline), onData: { data.append($0) }, reaped: {})
        var out: [String: String] = [:]
        for line in (String(data: data, encoding: .utf8) ?? "").split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[line.startIndex..<eq])
            if keys.contains(k) { out[k] = String(line[line.index(after: eq)...]) }
        }
        if r.timedOut { return (out, "note: the login shell did not finish in \(Int(deadline)) s and was stopped; PATH may lack your tools") }
        if (out["PATH"] ?? "").isEmpty { return (out, "note: the login shell gave no PATH; the recipe has the app's own environment") }
        return (out, nil)
    }

    /// Starts the lookup in the background so the first build does not wait for it.
    static func warmUp() { DispatchQueue.global(qos: .utility).async { _ = resolve() } }
}

/// Splits output into lines: \n, \r\n and a lone \r (a progress bar) all end one; a line longer than `cap` bytes is
/// cut and marked.
struct LineSplitter {
    private var pending = Data()
    private var skipLF = false
    let cap: Int
    init(cap: Int = 64 * 1024) { self.cap = cap }

    mutating func feed(_ data: Data) -> [String] {
        var out: [String] = []
        for b in data {
            if b == 0x0a { if skipLF { skipLF = false; continue }; out.append(take()); continue }
            skipLF = false
            if b == 0x0d { out.append(take()); skipLF = true; continue }
            pending.append(b)
            if pending.count >= cap { out.append(take() + " […line cut]") }
        }
        return out
    }

    mutating func finish() -> String? { pending.isEmpty ? nil : take() }

    private mutating func take() -> String {
        defer { pending = Data() }
        return String(decoding: pending, as: UTF8.self)
    }
}

/// One run of a recipe: its own process group, stdout and stderr as lines, cancellable as a whole.
final class RecipeRun {
    let recipe: Recipe
    let job: RecipeJob
    /// Called on the main thread for each line of the log, in order.
    var onLine: ((String) -> Void)?
    /// The whole run may not take longer than this (a setting, "buildTimeoutMinutes", 30 by default).
    var timeout: TimeInterval = {
        let m = UserDefaults.standard.object(forKey: "buildTimeoutMinutes") as? Double ?? 30
        return max(1, m) * 60
    }()
    private(set) var pid: pid_t = 0
    private let lock = NSLock()
    private var _lines: [String] = []
    private(set) var dropped = 0
    private var cancelled = false
    private var reaped = false
    /// Secret variables' values, taken out of every line (under `lock`).
    private var secrets: [String] = []
    private static let keep = 20000

    init(recipe: Recipe, job: RecipeJob) {
        self.recipe = recipe
        self.job = job
    }

    /// Every line so far (the last `keep`).
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }

    /// The log as it is written to `build.log`: the lines, with a first line saying when the start was dropped.
    var logText: String {
        let l = lines
        return (dropped > 0 ? "[\(dropped) earlier lines dropped]\n" : "") + l.joined(separator: "\n") + "\n"
    }

    /// Starts it; `completion` runs once on the main thread. The environment is resolved off the main thread first.
    func start(completion: @escaping (RecipeOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let outcome = run()
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Ends the recipe and everything it started in its group (SIGTERM, then SIGKILL after ten seconds, time for a remote recipe to stop its sandbox, unless it has
    /// been reaped by then: its pid may be someone else's by then).
    func cancel() {
        lock.lock(); cancelled = true; let p = pid; lock.unlock()
        guard p > 0 else { return }
        killpg(p, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let gone = self.reaped; self.lock.unlock()
            if !gone { killpg(p, SIGKILL) }
        }
    }

    /// For the app quitting.
    /// SIGTERM first, so the recipe's own cleanup runs (a remote recipe stops its sandbox); the group gets up to
    /// `grace` seconds to end, then SIGKILL. Blocks for that long at most.
    func killNow(grace: TimeInterval = 10) {
        lock.lock(); cancelled = true; let p = pid; let gone = reaped; lock.unlock()
        guard p > 0 && !gone else { return }
        killpg(p, SIGTERM)
        let end = Date().addingTimeInterval(grace)
        while Date() < end, killpg(p, 0) == 0 { usleep(50_000) }
        if killpg(p, 0) == 0 { killpg(p, SIGKILL) }
    }

    private func add(_ raw: [String]) {
        guard !raw.isEmpty else { return }
        lock.lock()
        let new = secrets.isEmpty ? raw : raw.map { Variables.mask($0, secrets) }   // a secret never reaches the log
        _lines.append(contentsOf: new)
        if _lines.count > Self.keep { dropped += _lines.count - Self.keep; _lines.removeFirst(_lines.count - Self.keep) }
        lock.unlock()
        DispatchQueue.main.async { [onLine] in for l in new { onLine?(l) } }
    }

    private func run() -> RecipeOutcome {
        try? FileManager.default.createDirectory(at: job.out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: job.out)
        let (base, note) = LoginEnvironment.resolve()
        var env = base
        // The person's variables (Variables: the Keychain), then the recipe's own contract, which they cannot replace.
        let vars = Variables.shared.all()   // one read of the Keychain
        for v in vars { env[v.name] = v.value }
        lock.lock(); secrets = Variables.secrets(of: vars); lock.unlock()
        for (k, v) in job.environment { env[k] = v }
        if let note { add([note]) }

        let exe = recipe.executable
        guard FileManager.default.isExecutableFile(atPath: exe) else { return .failed("The recipe \(exe) is not an executable file") }
        lock.lock(); let early = cancelled; lock.unlock()
        if early { return .cancelled }
        let (spawned, why) = ProcessGroup.spawn(exe, recipe.arguments, env: env, cwd: job.worktree.path)
        guard let child = spawned else { return .failed("Could not start \(exe): \(why)") }
        lock.lock(); pid = child.pid; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { killpg(child.pid, SIGTERM) }

        var splitter = LineSplitter()
        let started = Date()
        let r = ProcessGroup.drain(child, deadline: started.addingTimeInterval(timeout), grace: 10,
                                   onData: { add(splitter.feed($0)) },
                                   reaped: { lock.lock(); reaped = true; lock.unlock() })
        if let last = splitter.finish() { add([last]) }

        lock.lock(); let was = cancelled; lock.unlock()
        if was { return .cancelled }
        if r.timedOut {
            let span = timeout >= 60 ? "\(Int(timeout / 60)) minutes" : "\(Int(timeout)) seconds"
            add(["note: stopped after \(span) (the build time limit, setting buildTimeoutMinutes)"])
            return .failed("The recipe ran longer than \(span) and was stopped")
        }
        let status = r.status
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        let size = (try? FileManager.default.attributesOfItem(atPath: job.out.path)[.size] as? Int) ?? 0
        if code == 0 && size > 0 { return .built }
        let why2 = Self.reason(lines: lines)
        if code == 0 { return .failed("The recipe finished but left no APK at GREENROOM_OUT" + (why2.isEmpty ? "" : ": " + why2)) }
        return .failed(why2.isEmpty ? "The recipe exited with status \(code)" : why2)
    }

    /// The last error lines of a log: the lines that look like errors (the last three), else its last three.
    static func reason(lines: [String]) -> String {
        let words = ["error", "failed", "exception", "what went wrong", "not found", "no such", "denied", "unable"]
        let real = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let errors = real.filter { l in let low = l.lowercased(); return words.contains { low.contains($0) } }
        return (errors.isEmpty ? real.suffix(3) : errors.suffix(3)).joined(separator: "\n")
    }
}
