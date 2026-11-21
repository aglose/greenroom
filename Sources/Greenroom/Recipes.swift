import Foundation

// Recipes (docs/SESSIONS-PLAN.md, "2. Builds"): an executable run with the person's own tools, told what to build
// through its environment, which leaves an APK where it is told to. `Recipe` itself (executable + arguments) is
// declared with the model in Sessions.swift so a workspace's settings round-trip.

extension Recipe {
    /// The recipes that ship in `Resources/recipes/`. W2b adds "ci" and W2c "remote" here (and their scripts to the
    /// folder); nothing else changes for them: the runner, the queue and the UI take any name listed.
    static let builtInNames = ["local"]

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

    /// Every recipe name offered, built-ins first.
    var recipeNames: [String] { Recipe.builtInNames + recipes.keys.filter { !Recipe.builtInNames.contains($0) }.sorted() }

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

    var environment: [String: String] {
        [
            "GREENROOM_WORKTREE": worktree.path, "GREENROOM_REPO": repo.path, "GREENROOM_REF": ref, "GREENROOM_SHA": sha,
            "GREENROOM_DIRTY": dirty ? "1" : "0", "GREENROOM_MODULE": module, "GREENROOM_VARIANT": variant, "GREENROOM_OUT": out.path,
        ]
    }
}

enum RecipeOutcome: Equatable {
    case built
    case failed(String)
    case cancelled
}

/// The person's own environment, for the recipes: an app started from Finder has a bare one (no Homebrew, no
/// JAVA_HOME). Asked once of the login shell, off the main thread, and kept.
enum LoginEnvironment {
    private static let lock = NSLock()
    private static var cached: [String: String]?
    /// For a check: what the recipes get instead of asking the shell.
    static var override: [String: String]?
    private static let keys = ["PATH", "JAVA_HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT"]

    /// The environment a recipe starts with: this process's, with PATH, JAVA_HOME and ANDROID_HOME taken from the
    /// login shell where it knows them. Blocks for up to a few seconds the first time: call it off the main thread.
    static func resolve() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let login = override ?? shell()
        if let p = login["PATH"], !p.isEmpty {
            // The shell's entries first, then any this process had that the shell did not.
            var seen = Set<String>(), parts: [String] = []
            for e in (p + ":" + (env["PATH"] ?? "")).split(separator: ":").map(String.init) where seen.insert(e).inserted { parts.append(e) }
            env["PATH"] = parts.joined(separator: ":")
        }
        for k in keys where k != "PATH" {
            if env[k]?.isEmpty ?? true, let v = login[k], !v.isEmpty { env[k] = v }
        }
        return env
    }

    private static func shell() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let sh = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        // Markers, as an interactive shell may print a banner or a warning of its own.
        let script = keys.map { "printf '@@%s=%s\\n' \($0) \"${\($0):-}\"" }.joined(separator: "; ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sh)
        p.arguments = ["-l", "-i", "-c", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var out: [String: String] = [:]
        if (try? p.run()) != nil {
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") where line.hasPrefix("@@") {
                let kv = line.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
            }
        }
        cached = out
        return out
    }

    /// Starts the lookup in the background so the first build does not wait for it.
    static func warmUp() { DispatchQueue.global(qos: .utility).async { _ = resolve() } }
}

/// One run of a recipe: its own process group, stdout and stderr as lines, cancellable as a whole.
final class RecipeRun {
    let recipe: Recipe
    let job: RecipeJob
    /// Called on the main thread for each line of the log, in order.
    var onLine: ((String) -> Void)?
    /// Every line so far (capped), for the reason and the log's file.
    private(set) var lines: [String] = []
    private(set) var pid: pid_t = 0
    private let lock = NSLock()
    private var cancelled = false
    private static let keep = 20000

    init(recipe: Recipe, job: RecipeJob) {
        self.recipe = recipe
        self.job = job
    }

    /// Starts it; `completion` runs once on the main thread. The environment is resolved off the main thread first.
    func start(completion: @escaping (RecipeOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let outcome = run()
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Ends the recipe and everything it started in its group (SIGTERM, then SIGKILL after two seconds).
    func cancel() {
        lock.lock(); cancelled = true; let p = pid; lock.unlock()
        guard p > 0 else { return }
        killpg(p, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { killpg(p, SIGKILL) }
    }

    private func run() -> RecipeOutcome {
        try? FileManager.default.createDirectory(at: job.out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: job.out)
        var env = LoginEnvironment.resolve()
        for (k, v) in job.environment { env[k] = v }

        let exe = recipe.executable
        guard FileManager.default.isExecutableFile(atPath: exe) else { return .failed("The recipe \(exe) is not an executable file") }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return .failed("Could not make a pipe") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        posix_spawn_file_actions_addchdir_np(&actions, job.worktree.path)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)   // a group of its own, led by the recipe

        let argv = ([exe] + recipe.arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }

        var child: pid_t = 0
        lock.lock()
        let early = cancelled
        lock.unlock()
        if early { close(fds[0]); close(fds[1]); return .cancelled }
        let rc = posix_spawn(&child, exe, &actions, &attr, argv, envp)
        close(fds[1])
        guard rc == 0 else { close(fds[0]); return .failed("Could not start \(exe): \(String(cString: strerror(rc)))") }
        lock.lock(); pid = child; let wasCancelled = cancelled; lock.unlock()
        if wasCancelled { killpg(child, SIGTERM) }

        // Read until the recipe has exited and its pipe is drained (a child that outlives it and keeps the pipe
        // open does not hold the build: after the exit, a short grace, then the group is ended).
        var pending = Data()
        var status: Int32 = 0
        var exited = false
        var exitedAt: Date?
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            var pfd = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
            let n = poll(&pfd, 1, 100)
            if n > 0 {
                let got = read(fds[0], &buf, buf.count)
                if got > 0 { pending.append(contentsOf: buf[0..<got]); flush(&pending, final: false); continue }
                if got == 0 { break }
            }
            if !exited, waitpid(child, &status, WNOHANG) == child { exited = true; exitedAt = Date() }
            if exited, let t = exitedAt, Date().timeIntervalSince(t) > 1 { break }
        }
        close(fds[0])
        flush(&pending, final: true)
        if !exited { waitpid(child, &status, 0) }
        killpg(child, SIGKILL)   // whatever is left of the group

        lock.lock(); let was = cancelled; lock.unlock()
        if was { return .cancelled }
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        let size = (try? FileManager.default.attributesOfItem(atPath: job.out.path)[.size] as? Int) ?? 0
        if code == 0 && size > 0 { return .built }
        let why = Self.reason(lines: lines)
        if code == 0 { return .failed("The recipe finished but left no APK at GREENROOM_OUT" + (why.isEmpty ? "" : ": " + why)) }
        return .failed(why.isEmpty ? "The recipe exited with status \(code)" : why)
    }

    private func flush(_ data: inout Data, final: Bool) {
        var emitted: [String] = []
        while let i = data.firstIndex(of: 0x0a) {
            emitted.append(String(decoding: data[data.startIndex..<i], as: UTF8.self))
            data = data[data.index(after: i)...]
        }
        if final, !data.isEmpty { emitted.append(String(decoding: data, as: UTF8.self)); data = Data() }
        guard !emitted.isEmpty else { return }
        let clean = emitted.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        lock.lock()
        lines.append(contentsOf: clean)
        if lines.count > Self.keep { lines.removeFirst(lines.count - Self.keep) }
        lock.unlock()
        DispatchQueue.main.async { [onLine] in for l in clean { onLine?(l) } }
    }

    /// The last error lines of a log: the lines that look like errors (the last three), else its last three.
    static func reason(lines: [String]) -> String {
        let words = ["error", "failed", "exception", "what went wrong", "not found", "no such", "denied", "unable"]
        let real = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let errors = real.filter { l in let low = l.lowercased(); return words.contains { low.contains($0) } }
        return (errors.isEmpty ? real.suffix(3) : errors.suffix(3)).joined(separator: "\n")
    }
}
