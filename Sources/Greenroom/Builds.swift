import Foundation

/// One build of one session: queued, running, or finished (kept until the next one starts, for its log and reason).
final class BuildJob {
    enum State: Equatable {
        case queued
        case running
        case built(Build)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    /// The worktree's path: a session's identity.
    let session: String
    let workspace: URL
    let title: String
    let recipeName: String
    let source: Build.Source
    private(set) var state: State = .queued
    private(set) var lines: [String] = []
    let started = Date()
    var run: RecipeRun?
    fileprivate var cancelRequested = false
    /// The recipe is done and its APK is being filed: a cancel now is honoured before the hand-off.
    fileprivate var handingOff = false
    fileprivate var recipe: Recipe
    fileprivate var module: String
    fileprivate var variant: String
    fileprivate var out: URL
    fileprivate var logFile: URL
    /// The workspace's recipe settings, as the recipe's environment (RecipeSettings.swift).
    fileprivate var extra: [String: String]
    /// A sandbox the remote recipe made from a template (it says so in a line of its log).
    fileprivate(set) var createdSandbox: String?

    init(session: Session, workspace: Workspace, recipeName: String, recipe: Recipe, store: SessionStore) {
        self.session = session.worktree.path
        self.workspace = workspace.root
        self.title = session.title
        self.recipeName = recipeName
        self.source = Recipe.source(ofRecipeNamed: recipeName)
        self.recipe = recipe
        self.module = workspace.module ?? ""
        self.variant = workspace.variant
        self.extra = workspace.recipeEnvironment
        let work = store.root.appendingPathComponent("sessions/work/\(session.slot)", isDirectory: true)
        self.out = work.appendingPathComponent("app.apk")
        self.logFile = work.appendingPathComponent("build.log")
    }

    var isActive: Bool { state == .queued || state == .running }
    var lastLine: String? { lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    var failure: String? { if case .failed(let why) = state { return why }; return nil }

    fileprivate func set(_ s: State) { state = s }
    fileprivate func append(_ l: String) {
        lines.append(l)
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
    }
}

/// The build queue: one build at a time per workspace (Gradle's daemon and caches are shared by its worktrees),
/// builds of different workspaces may overlap. A finished recipe becomes a `Build` in the store, handed to the
/// session, whose simulator then reloads through `SessionsController.adopt`. A failure keeps the last good build.
final class Builds {
    private weak var sessions: SessionsController?
    /// The newest job of each session (by worktree path): active, or finished with its log.
    private(set) var jobs: [String: BuildJob] = [:]
    private var queued: [BuildJob] = []
    private var running: [String: BuildJob] = [:]   // by workspace path

    /// Told on the main thread when a job's state changed (not for each line: see `onLine`).
    var onChange: (() -> Void)?
    /// Told on the main thread for each log line of a job.
    var onLine: ((BuildJob, String) -> Void)?
    /// Told when a build is filed and the session handed it, on the main thread.
    var onBuilt: ((BuildJob, Build) -> Void)?

    init(sessions: SessionsController) { self.sessions = sessions }

    func job(for session: Session) -> BuildJob? { jobs[session.worktree.path] }
    func isBuilding(_ worktree: String) -> Bool { jobs[worktree]?.isActive ?? false }

    // MARK: Start and cancel

    /// Queues a build of `session` with the recipe named (the workspace's default when nil). Gives the job, or nil
    /// when there is nothing to run (and says why through `error`).
    @discardableResult
    func start(_ session: Session, workspace: Workspace, recipeName: String? = nil, store: SessionStore, error: (String) -> Void = { _ in }) -> BuildJob? {
        if let j = jobs[session.worktree.path], j.isActive { error("\(session.title) is already building"); return nil }
        let name = recipeName ?? workspace.defaultRecipeName
        guard let recipe = workspace.recipe(named: name) else { error("There is no recipe called \(name)"); return nil }
        if let why = workspace.refusal(forRecipe: name) { error(why); return nil }   // the remote recipe needs the person's yes
        let job = BuildJob(session: session, workspace: workspace, recipeName: name, recipe: recipe, store: store)
        jobs[job.session] = job
        queued.append(job)
        job.append("queued: \(name) for \(session.title)")
        onChange?()
        pump(store: store, session: session)
        return job
    }

    /// Ends a job: a queued one is dropped, a running one has its whole process group ended.
    /// At once, for the app quitting: every running recipe's group gets SIGKILL, synchronously.
    func terminateAll() {
        for job in jobs.values where job.isActive { job.cancelRequested = true; job.run?.killNow() }
        Bases.killAll()
    }

    func cancel(_ worktree: String) {
        guard let job = jobs[worktree], job.isActive else { return }
        if job.state == .queued {
            queued.removeAll { $0 === job }
            job.set(.cancelled)
            onChange?()
        } else {
            job.cancelRequested = true
            if !job.handingOff { job.run?.cancel() }   // the run's completion does the rest
        }
    }

    // MARK: Running

    /// Starts the next queued job of every workspace with none running.
    private func pump(store: SessionStore, session: Session? = nil) {
        for job in queued where running[job.workspace.path] == nil {
            queued.removeAll { $0 === job }
            running[job.workspace.path] = job
            launch(job, store: store, session: session)
        }
    }

    private func launch(_ job: BuildJob, store: SessionStore, session: Session?) {
        job.set(.running)
        onChange?()
        let hint = session
        Task { @MainActor in
            // What the tree is now, not what the row showed a while ago.
            let wt = URL(fileURLWithPath: job.session, isDirectory: true)
            let state = await Git.state(of: wt)
            let sha = state?.head ?? hint?.head ?? ""
            let ref = state?.branch ?? hint?.branch ?? ""
            let dirty = state?.dirty ?? hint?.dirty ?? false
            var extra = job.extra
            if let slug = await GitHubRemote.repoSlug(for: wt) { extra["GREENROOM_REPO_SLUG"] = slug }
            let rj = RecipeJob(worktree: wt, repo: job.workspace, ref: ref, sha: sha, dirty: dirty, module: job.module, variant: job.variant, out: job.out, extra: extra)
            let run = RecipeRun(recipe: job.recipe, job: rj)
            job.run = run
            if job.cancelRequested {
                self.finish(job, outcome: .cancelled, store: store, sha: sha, ref: ref, dirty: dirty)
                return
            }
            run.onLine = { [weak self, weak job] line in
                guard let self, let job else { return }
                job.append(line)
                if line.hasPrefix("greenroom: sandbox-created ") { job.createdSandbox = String(line.dropFirst(27)).trimmingCharacters(in: .whitespaces) }
                self.onLine?(job, line)
            }
            run.start { [weak self] outcome in
                self?.finish(job, outcome: outcome, store: store, sha: sha, ref: ref, dirty: dirty)
            }
        }
    }

    private func finish(_ job: BuildJob, outcome: RecipeOutcome, store: SessionStore, sha: String, ref: String, dirty: Bool) {
        let work = job.logFile.deletingLastPathComponent()
        let log = job.run?.logText ?? (job.lines.joined(separator: "\n") + "\n")
        // The remote recipe made a sandbox from a template: keep its id in the workspace's settings, so the next build resumes it.
        if let made = job.createdSandbox { sessions?.noteCreatedSandbox(made, workspaceRoot: job.workspace.path) }
        let release = { [self] in
            running[job.workspace.path] = nil
            onChange?()
            pump(store: store)
        }
        switch outcome {
        case .cancelled:
            let note = "cancelled. A Gradle daemon the recipe started may finish its current task."
            job.append(note)
            onLine?(job, note)
            job.set(.cancelled)
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try? log.write(to: job.logFile, atomically: true, encoding: .utf8)
            release()
        case .failed(let why):
            job.set(.failed(why))
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try? log.write(to: job.logFile, atomically: true, encoding: .utf8)
            release()
        case .built:
            let out = job.out, source = job.source
            job.handingOff = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                // Hashing and cloning a big APK is off the main thread.
                // CI built the pushed commit, whatever the worktree has changed since.
                let build = store.record(apk: out, source: source, sha: sha.isEmpty ? nil : sha, ref: ref.isEmpty ? nil : ref, dirty: source == .ci ? false : dirty, date: Date())
                if let build {
                    store.note(build: build.key, of: job.session)
                    try? log.write(to: store.folder(of: build.key).appendingPathComponent("build.log"), atomically: true, encoding: .utf8)
                }
                try? FileManager.default.removeItem(at: out)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if build != nil, job.cancelRequested {
                        // Cancel came while the APK was being filed: honoured before the session is handed it.
                        let note = "cancelled before the build was adopted: it is kept in the store, the session keeps running its previous build"
                        job.append(note)
                        self.onLine?(job, note)
                        job.set(.cancelled)
                    } else if let build {
                        job.set(.built(build))
                        self.sessions?.adopt(build, forWorktree: job.session)
                        self.onBuilt?(job, build)
                    } else {
                        job.set(.failed("The APK could not be stored"))
                    }
                    release()
                }
            }
        }
    }
}
