import Foundation

// Base resolution (docs/SESSIONS-PLAN.md, "2. Builds"): whatever a change is compared against, a branch, another
// session, a commit, a pull request or a file, becomes a `Build`, so everything downstream compares two builds and
// does not care where either came from.

/// What a change is compared with.
enum BaseRef: Equatable {
    /// The workspace's base branch: the merge base of the worktree with `Workspace.baseRef` (what a pull request
    /// from it would show).
    case baseBranch
    /// Another session, by its worktree's path: its newest build, else its commit.
    case session(String)
    /// A branch, tag or commit of the repository.
    case ref(String)
    /// A pull request's head, by number.
    case pullRequest(Int)
    /// An APK file.
    case apk(URL)
}

/// What a resolution that built nothing could do about it. Greenroom starts no build in a scratch worktree by
/// itself: the UI shows this and the person decides.
struct BuildOffer: Equatable {
    enum Option: Equatable {
        /// Check the commit out in a worktree and build it with the local recipe.
        case localInWorktree
        /// The remote recipe (needs the person's yes for the repository).
        case remote
    }
    var sha: String
    var ref: String?
    /// Why CI could not give it (empty when it was not asked).
    var ciReason: String
    var options: [Option] = [.localInWorktree, .remote]
    /// The commit is a pull request's head: anyone's code. Building it runs its build scripts on this Mac.
    var fromPullRequest = false

    var message: String {
        let short = String(sha.prefix(7))
        var s = "There is no build of \(short)"
        if let ref, !ref.isEmpty { s += " (\(ref))" }
        s += ": none is stored, "
        s += ciReason.isEmpty ? "CI was not asked" : "CI gave none (\(ciReason))"
        s += ", and no worktree is at that commit with a fresh APK. It can be built: check it out in a worktree and build it with the local recipe, or use the remote recipe. Greenroom does not start a build in a scratch worktree by itself."
        if fromPullRequest { s += " Careful: this is a pull request's code, and building it with the local recipe runs that code's build scripts on this Mac." }
        return s
    }
}

enum BaseResolution: Equatable {
    case build(Build)
    case offer(BuildOffer)
    case failed(String)
}

extension SessionStore {
    /// The newest stored build made from exactly this commit (a prefix of 7 or more is enough). A build made from a
    /// worktree with uncommitted changes is not that commit's.
    func build(forSha sha: String) -> Build? {
        guard sha.count >= 7, let names = try? FileManager.default.contentsOfDirectory(atPath: builds.path) else { return nil }
        var best: Build?
        for name in names {
            guard let b = build(name), !b.dirty, let s = b.sha, !s.isEmpty, s.hasPrefix(sha) || sha.hasPrefix(s) else { continue }
            if best == nil || b.date > best!.date { best = b }
        }
        return best
    }
}

/// The GitHub CLI, found on the person's own PATH (the login shell's: an app started from Finder has a bare one).
enum GH {
    struct Result { var status: Int32; var out: String; var err: String }

    /// Runs `gh ARGS` in `dir`. Off the main thread. A status of 127 means `gh` was not found.
    static func run(_ args: [String], in dir: URL, timeout: TimeInterval = 60) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let env = LoginEnvironment.resolve().env
                guard let exe = find("gh", in: env["PATH"] ?? "") else {
                    cont.resume(returning: Result(status: 127, out: "", err: "the GitHub CLI (gh) is not installed: install it (brew install gh) and sign in with gh auth login"))
                    return
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.currentDirectoryURL = dir
                var e = env
                e["GH_PROMPT_DISABLED"] = "1"
                e["NO_COLOR"] = "1"
                p.environment = e
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: Result(status: 126, out: "", err: "could not start gh")); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: Result(status: p.terminationStatus, out: String(decoding: data, as: UTF8.self), err: String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    static func find(_ name: String, in path: String) -> String? {
        for dir in path.split(separator: ":") {
            let f = String(dir) + "/" + name
            if FileManager.default.isExecutableFile(atPath: f) { return f }
        }
        return nil
    }

    /// The last non-empty line of a failure, for a one-line message.
    static func why(_ r: Result) -> String {
        let text = r.err.isEmpty ? r.out : r.err
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? "exit status \(r.status)"
    }

    struct Pull: Equatable { var number: Int; var sha: String; var ref: String; var title: String }

    /// A pull request matched to a local branch via `gh pr list`.
    struct BranchPull: Equatable {
        var number: Int
        var title: String
        var branch: String
        var state: String
        var isDraft: Bool
        var url: URL?
        var baseBranch: String? = nil
        var reviewDecision: String? = nil
        var additions: Int? = nil
        var deletions: Int? = nil
        var changedFiles: Int? = nil

        var isOpen: Bool { state.uppercased() == "OPEN" }
        var isMerged: Bool { state.uppercased() == "MERGED" }
        var isClosed: Bool { state.uppercased() == "CLOSED" }

        /// Compact status word combining draft, state, and review decision.
        var statusBadge: String {
            if isDraft { return "Draft" }
            if isMerged { return "Merged" }
            if isClosed { return "Closed" }
            switch reviewDecision?.uppercased() {
            case "APPROVED": return "Approved"
            case "CHANGES_REQUESTED": return "Changes"
            default: return "Open"
            }
        }
    }

    /// `gh pr view N -R SLUG --json headRefOid,headRefName,title` in the repository `dir` is in (`slug` nil: gh's own guess).
    static func pull(number: Int, slug: String?, in dir: URL) async -> (Pull?, String) {
        let r = await run(["pr", "view", String(number)] + (slug.map { ["-R", $0] } ?? []) + ["--json", "headRefOid,headRefName,title"], in: dir)
        guard r.status == 0 else { return (nil, r.status == 127 ? r.err : "gh could not read pull request \(number): \(why(r))") }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any],
              let sha = obj["headRefOid"] as? String, !sha.isEmpty else { return (nil, "gh gave no commit for pull request \(number)") }
        return (Pull(number: number, sha: sha, ref: obj["headRefName"] as? String ?? "", title: obj["title"] as? String ?? ""), "")
    }

    /// `gh pr list --state all --limit 50 --json ...`, keyed by `headRefName` (open PRs win over closed/merged, then highest number).
    static func pullsByBranch(in dir: URL, slug: String? = nil) async -> [String: BranchPull] {
        let fields = "number,title,headRefName,baseRefName,state,isDraft,url,reviewDecision,additions,deletions,changedFiles"
        let r = await run(["pr", "list", "--state", "all", "--limit", "50"] + (slug.map { ["-R", $0] } ?? []) + ["--json", fields], in: dir, timeout: 20)
        guard r.status == 0, let arr = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [[String: Any]] else { return [:] }
        var out: [String: BranchPull] = [:]
        for obj in arr {
            guard let number = obj["number"] as? Int, let branch = obj["headRefName"] as? String, !branch.isEmpty else { continue }
            let review = (obj["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let base = (obj["baseRefName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let pr = BranchPull(number: number, title: obj["title"] as? String ?? "", branch: branch,
                                state: obj["state"] as? String ?? "OPEN", isDraft: obj["isDraft"] as? Bool ?? false,
                                url: (obj["url"] as? String).flatMap(URL.init(string:)),
                                baseBranch: base, reviewDecision: review,
                                additions: obj["additions"] as? Int, deletions: obj["deletions"] as? Int,
                                changedFiles: obj["changedFiles"] as? Int)
            if let have = out[branch] {
                if pr.isOpen != have.isOpen { if pr.isOpen { out[branch] = pr } }
                else if pr.number > have.number { out[branch] = pr }
            } else {
                out[branch] = pr
            }
        }
        return out
    }
}

/// A pull request typed or pasted by the person: a number, `#42`, or its address.
enum PullRequestRef {
    /// The number, and the `owner/repo` when an address named one.
    static func parse(_ text: String) -> (number: Int, slug: String?)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let digits = t.hasPrefix("#") ? String(t.dropFirst()) : t
        if let n = Int(digits), n > 0 { return (n, nil) }
        // An address: its host, and the path alone (a #fragment or ?query is not part of it).
        guard let c = URLComponents(string: t), let host = c.host?.lowercased(), host == "github.com" || host.hasSuffix(".github.com") else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let n = Int(parts[3]), n > 0 else { return nil }
        return (n, parts[0] + "/" + parts[1])
    }
}

enum Bases {
    /// Running `ci` fetches, ended with the app (a running `gh` is not left behind).
    private static let lock = NSLock()
    private static var active: [RecipeRun] = []
    static func killAll() { lock.lock(); let runs = active; lock.unlock(); for r in runs { r.killNow() } }
    private static func track(_ run: RecipeRun, _ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on { active.append(run) } else { active.removeAll { $0 === run } }
    }

    /// Runs a remote/artifact fetch recipe (`"pr-script"` or `"ci"`) for one commit, with no session and no queue.
    /// The APK is filed in the store as a CI build of that commit (and PR, when known). `onLine` gets the log on main.
    static func fetchCI(sha: String, ref: String?, workspace: Workspace, store: SessionStore, slug: String? = nil,
                        recipeName: String = "ci", prNumber: Int? = nil, prTitle: String? = nil, prURL: String? = nil,
                        onLine: ((String) -> Void)? = nil) async -> (Build?, String) {
        guard let recipe = workspace.recipe(named: recipeName) else { return (nil, "there is no \(recipeName) recipe") }
        let scratch = store.root.appendingPathComponent("sessions/work/\(recipeName)-\(String(sha.prefix(7)))-\(UUID().uuidString.prefix(6))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Looking for what CI already built must never start a workflow: only an explicit Build on a row does.
        var extra = workspace.recipeEnvironment
        extra["GREENROOM_CI_DISPATCH"] = "0"
        let known = await GitHubRemote.repoSlug(for: workspace.root)
        if let s = slug ?? known { extra["GREENROOM_REPO_SLUG"] = s }
        let job = RecipeJob(worktree: workspace.root, repo: workspace.root, ref: ref ?? "", sha: sha, dirty: false, module: workspace.module ?? "",
                            variant: workspace.variant, out: scratch.appendingPathComponent("app.apk"),
                            prNumber: prNumber, prTitle: prTitle, prURL: prURL, extra: extra)
        let run = RecipeRun(recipe: recipe, job: job)
        // In the job queue while it runs: seen from any session, and cancelled there.
        let what = prNumber.map { "pull request #\($0)" } ?? "\(workspace.root.lastPathComponent) at \(sha.prefix(7))"
        let ticket = await MainActor.run { () -> QueueJob in
            let t = QueueJob(kind: .fetch, title: "Fetch the build of \(what)", owner: nil, lane: nil, detail: "looking for a build (\(recipeName))")
            t.onCancel = { run.cancel() }
            JobQueue.shared.adopt(t)
            return t
        }
        run.onLine = { line in
            onLine?(line)
            JobQueue.shared.update(ticket, detail: line)
        }
        track(run, true)
        let outcome: RecipeOutcome = await withCheckedContinuation { c in run.start { c.resume(returning: $0) } }
        track(run, false)
        await MainActor.run {
            switch outcome {
            case .cancelled: JobQueue.shared.finish(ticket, .cancelled)
            // Finding no build is an answer, not a failure of the app: the row that asked says what to do next.
            case .failed(let why): JobQueue.shared.finish(ticket, .done, detail: "no build: " + (why.split(separator: "\n").last.map(String.init) ?? why))
            case .built: JobQueue.shared.finish(ticket, .done, detail: "fetched")
            }
        }
        switch outcome {
        case .cancelled: return (nil, "cancelled")
        case .failed(let why): return (nil, why)
        case .built:
            let out = job.out
            let resolvedPR = run.resolvedPRNumber ?? prNumber
            let build = await Task.detached { store.record(apk: out, source: .ci, sha: sha, ref: ref, dirty: false, date: Date(), prNumber: resolvedPR) }.value
            return build.map { ($0, "") } ?? (nil, "The APK could not be stored")
        }
    }

    /// A commit's build: the stored one, else the user's PR APK script (if configured), else the `ci` recipe,
    /// else an existing worktree already at that commit with a fresh APK, else an offer to build it.
    static func resolve(sha: String, ref: String?, in workspace: Workspace, sessions: [Session], store: SessionStore,
                        pullRequest: Bool = false, slug: String? = nil, prNumber: Int? = nil, prTitle: String? = nil,
                        onLine: ((String) -> Void)? = nil) async -> BaseResolution {
        if let b = store.build(forSha: sha) { return .build(b) }
        if let prNumber, let b = store.build(forPR: prNumber), b.sha == nil || b.sha == sha { return .build(b) }
        var ciReason = ""
        let prURL = (prNumber != nil && slug != nil) ? "https://github.com/\(slug!)/pull/\(prNumber!)" : nil
        if workspace.hasPRFetchScript {
            let (build, why) = await fetchCI(sha: sha, ref: ref, workspace: workspace, store: store, slug: slug,
                                             recipeName: "pr-script", prNumber: prNumber, prTitle: prTitle, prURL: prURL, onLine: onLine)
            if let build { return .build(build) }
            ciReason = why.split(separator: "\n").last.map(String.init) ?? why
        }
        if workspace.recipes["ci"] != nil || GitHubRemote.has(workspace.root) {
            let (build, why) = await fetchCI(sha: sha, ref: ref, workspace: workspace, store: store, slug: slug,
                                             recipeName: "ci", prNumber: prNumber, prTitle: prTitle, prURL: prURL, onLine: onLine)
            if let build { return .build(build) }
            let ghWhy = why.split(separator: "\n").last.map(String.init) ?? why
            ciReason = ciReason.isEmpty ? ghWhy : "\(ciReason); CI: \(ghWhy)"
        } else if ciReason.isEmpty {
            ciReason = "this repository has no GitHub remote"
        }
        let at = sessions.first { $0.workspace.path == workspace.root.path && $0.head == sha && !$0.dirty && $0.outputs != nil && !$0.isStale }
        if let at, let outputs = at.outputs {
            let apk = outputs.apk, head = at.head, branch = at.branch
            let build = await Task.detached { store.record(apk: apk, source: .local, sha: head, ref: branch, dirty: false, date: outputs.date, prNumber: prNumber ?? at.prNumber) }.value
            if let build { return .build(build) }
        }
        var offer = BuildOffer(sha: sha, ref: ref, ciReason: ciReason, fromPullRequest: pullRequest)
        if workspace.disableLocalBuilds { offer.options.removeAll { $0 == .localInWorktree } }
        return .offer(offer)
    }

    /// `resolve(base:in:)` of the plan. `worktree` is the one the base branch's merge base is taken from (the
    /// workspace's main checkout by default); `sessions` are the worktrees an existing build may be found in.
    static func resolve(base: BaseRef, in workspace: Workspace, sessions: [Session] = [], store: SessionStore, worktree: URL? = nil,
                        onLine: ((String) -> Void)? = nil) async -> BaseResolution {
        let dir = worktree ?? workspace.root
        switch base {
        case .apk(let url):
            guard FileManager.default.isReadableFile(atPath: url.path) else { return .failed("\(url.lastPathComponent) cannot be read") }
            let build = await Task.detached { store.record(apk: url, source: .file, sha: nil, ref: nil, dirty: false) }.value
            return build.map { .build($0) } ?? .failed("\(url.lastPathComponent) could not be stored as a build")
        case .session(let path):
            guard let s = sessions.first(where: { $0.worktree.path == path }) else { return .failed("That session is no longer there") }
            if let newest = store.history(of: path).compactMap({ store.build($0) }).first { return .build(newest) }
            if let b = s.build { return .build(b) }
            return await resolve(sha: s.head, ref: s.branch, in: workspace, sessions: sessions, store: store, onLine: onLine)
        case .baseBranch:
            guard let sha = await Git.mergeBase("HEAD", workspace.baseRef, in: dir) else {
                return .failed("Could not find where this worktree left \(workspace.baseRef). Fetch it (git fetch) or choose another base.")
            }
            return await resolve(sha: sha, ref: workspace.baseRef, in: workspace, sessions: sessions, store: store, onLine: onLine)
        case .ref(let name):
            guard !name.hasPrefix("-") else { return .failed("\(name) is not a branch or commit") }
            for candidate in [name, "origin/" + name] {
                if let out = await Git.run(["rev-parse", "--verify", "--quiet", candidate + "^{commit}"], in: dir) {
                    let sha = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sha.isEmpty { return await resolve(sha: sha, ref: name, in: workspace, sessions: sessions, store: store, onLine: onLine) }
                }
            }
            return .failed("No branch or commit called \(name) in \(workspace.root.lastPathComponent). Fetch it (git fetch) or check the name.")
        case .pullRequest(let n):
            let slug = await GitHubRemote.repoSlug(for: workspace.root)
            let (pr, why) = await GH.pull(number: n, slug: slug, in: workspace.root)
            guard let pr else { return .failed(why) }
            return await resolve(sha: pr.sha, ref: pr.ref.isEmpty ? nil : pr.ref, in: workspace, sessions: sessions, store: store, pullRequest: true, slug: slug, prNumber: pr.number, prTitle: pr.title, onLine: onLine)
        }
    }
}
