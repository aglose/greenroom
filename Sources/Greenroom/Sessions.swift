import Foundation

// The model of docs/SESSIONS-PLAN.md ("The model"). Later workstreams fill in what is stubbed here: `Recipe` (W2),
// `Auto` (W3); `ClaudeSession` is in ClaudeSessions.swift (W1).

/// A repository the person added.
struct Workspace: Codable, Equatable {
    /// The main checkout.
    var root: URL
    /// The Gradle application module (":app"); found when nil.
    var module: String?
    var variant: String = "debug"
    /// What a change is compared with by default.
    var baseRef: String = "origin/main"
    /// "local", "ci", "remote": see Builds (W2).
    var recipes: [String: Recipe] = [:]
    /// What happens by itself: see Evidence (W3).
    var auto: Auto = .onBuild
    /// The `ci` and `remote` recipes' settings (RecipeSettings.swift).
    var ci = CISettings()
    var remote = RemoteSettings()
    /// Evidence walks use a copy of each session's signed-in data (off by default: a walk is fresh).
    var walkWithData = false
    /// Evidence walks stop two taps deep after two minutes instead of covering the whole app (off by default: a map
    /// that is the app's history has to be all of it).
    var quickWalk = false
    /// While an agent drives a session's simulator, its screen is recorded under the build's evidence (AgentRecording.swift).
    var recordAgent = true
    /// The worktrees (paths) the person put in the sidebar, the newest first. Only these show, with any that has a
    /// simulator running; the rest are a menu away, and the active ones are suggested.
    var shown: [String] = []
    /// Worktrees the person removed or dismissed: not suggested again (the + menu still has them).
    var hidden: [String] = []
    /// Worktrees put away because their pull request merged: not suggested again, listed apart in the + menu.
    var archived: [String] = []
    /// "Share screen maps through git" (off by default): each walk's map is kept as refs under refs/greenroom/maps in
    /// this repository and pushed to origin, and teammates' maps are fetched from it (History, `Workspace.shareExplanation`).
    var shareMaps = false
    /// "Also share maps walked on signed-in data" (off): without it such a map is written locally but never pushed.
    var shareSignedInMaps = false
    /// "Keep main built" (on): the repository's base branch is fetched and its newest commit built by itself, a
    /// row at the top that runs it (MainBuild.swift).
    var keepMain = true
    /// "Count Walks That Are Not Signed In" (off): the map of the base branch, which pull request diffs start from and
    /// are compared with, is one walked signed in, since only that reaches every screen. With this on a walk that
    /// was not signed in counts too (an app with no sign-in, or one whose owner wants only that part walked).
    var unsignedBaseline = false
    /// Path to a user-owned local executable script that retrieves or links a PR APK (e.g. from Artifactory).
    /// Greenroom never connects to Artifactory directly; only this local script runs, with the user's own tools.
    var prFetchScript = ""
    /// Skip scanning local `build/outputs/apk` folders and watching worktree `.apk` outputs for this repository.
    var skipLocalAPKScan = false
    /// Never run the built-in `local` Gradle build recipe (including MainBuilds local fallback) for this repository.
    var disableLocalBuilds = false

    static let unsignedExplanation = "The map of the base branch is walked signed in, so it has every screen, and walks that are not signed in are left out of pull request diffs. Turn this on for an app with no sign-in, or to compare only what is reachable without one."
    static let shareExplanation = "Stores each walk's map in this repository under refs/greenroom/maps and pushes it to origin, so teammates see a pull request's map without walking it. Captures of the app's screens are uploaded to your git remote."
    static let shareSignedInExplanation = "Maps walked on your signed-in data can show your account; they are pushed only with this on."

    init(root: URL) { self.root = root }

    // A file written before a field existed still reads: every key but the root has a default.
    private enum Keys: String, CodingKey { case root, module, variant, baseRef, recipes, auto, ci, remote, walkWithData, quickWalk, recordAgent, shown, hidden, archived, shareMaps, shareSignedInMaps, keepMain, unsignedBaseline, prFetchScript, skipLocalAPKScan, disableLocalBuilds }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(root: try c.decode(URL.self, forKey: .root))
        module = try? c.decodeIfPresent(String.self, forKey: .module)
        variant = (try? c.decodeIfPresent(String.self, forKey: .variant)) ?? variant
        baseRef = (try? c.decodeIfPresent(String.self, forKey: .baseRef)) ?? baseRef
        recipes = (try? c.decodeIfPresent([String: Recipe].self, forKey: .recipes)) ?? recipes
        auto = (try? c.decodeIfPresent(Auto.self, forKey: .auto)) ?? auto
        ci = (try? c.decodeIfPresent(CISettings.self, forKey: .ci)) ?? ci
        remote = (try? c.decodeIfPresent(RemoteSettings.self, forKey: .remote)) ?? remote
        walkWithData = (try? c.decodeIfPresent(Bool.self, forKey: .walkWithData)) ?? walkWithData
        quickWalk = (try? c.decodeIfPresent(Bool.self, forKey: .quickWalk)) ?? quickWalk
        recordAgent = (try? c.decodeIfPresent(Bool.self, forKey: .recordAgent)) ?? recordAgent
        shown = (try? c.decodeIfPresent([String].self, forKey: .shown)) ?? shown
        hidden = (try? c.decodeIfPresent([String].self, forKey: .hidden)) ?? hidden
        archived = (try? c.decodeIfPresent([String].self, forKey: .archived)) ?? archived
        shareMaps = (try? c.decodeIfPresent(Bool.self, forKey: .shareMaps)) ?? shareMaps
        shareSignedInMaps = (try? c.decodeIfPresent(Bool.self, forKey: .shareSignedInMaps)) ?? shareSignedInMaps
        keepMain = (try? c.decodeIfPresent(Bool.self, forKey: .keepMain)) ?? keepMain
        unsignedBaseline = (try? c.decodeIfPresent(Bool.self, forKey: .unsignedBaseline)) ?? unsignedBaseline
        prFetchScript = (try? c.decodeIfPresent(String.self, forKey: .prFetchScript)) ?? prFetchScript
        skipLocalAPKScan = (try? c.decodeIfPresent(Bool.self, forKey: .skipLocalAPKScan)) ?? skipLocalAPKScan
        disableLocalBuilds = (try? c.decodeIfPresent(Bool.self, forKey: .disableLocalBuilds)) ?? disableLocalBuilds
    }
}

/// An executable that builds an APK. Run by W2; stored here so a workspace's settings round-trip.
struct Recipe: Codable, Equatable {
    var executable: String
    var arguments: [String] = []
}

enum Auto: String, Codable {
    case off, onBuild, onTurnEnd
}

/// One row: a worktree of a workspace.
struct Session {
    let worktree: URL
    /// The workspace's main checkout this worktree belongs to.
    let workspace: URL
    var branch: String?
    var head: String
    var dirty: Bool
    var ahead: Int
    var claude: ClaudeSession?
    /// All Claude Code / T3 Code sessions attached to this worktree, highest priority first.
    var agentSessions: [ClaudeSession] = []
    /// The GitHub pull request for this worktree's branch (from `gh pr list`), if any.
    var githubPR: GH.BranchPull? = nil
    /// The newest build of this worktree, once one has been recorded in the store.
    var build: Build?
    var simulator: Simulator?
    /// The newest APK under the worktree's Gradle outputs (what counts as its build until W2 makes them), and
    /// the newest source change (the head commit's date or a changed file's), to tell whether it is stale.
    var outputs: Outputs?
    var sourcesDate: Date?

    struct Outputs: Equatable {
        var apk: URL
        var date: Date
    }

    var isMain: Bool { worktree.standardizedFileURL.path == workspace.standardizedFileURL.path }
    var title: String {
        if let b = branch, b == "main" || b == "master" { return b }
        if let t = claude?.title { return t }
        if let pr = githubPR { return "#\(pr.number) \(pr.title.isEmpty ? (branch ?? (shortHead.isEmpty ? worktree.lastPathComponent : shortHead)) : pr.title)" }
        if let b = branch { return b }
        return shortHead.isEmpty ? worktree.lastPathComponent : "(detached \(shortHead))"
    }
    /// Short, unmistakable label for a simulator running this session's build.
    var simLabel: String {
        if let pr = githubPR {
            let draft = pr.isDraft ? " Draft" : ""
            let tail = branch ?? (shortHead.isEmpty ? worktree.lastPathComponent : shortHead)
            return "#\(pr.number)\(draft) · \(tail)"
        }
        let base = branch ?? title
        return shortHead.isEmpty ? base : "\(base) · \(shortHead)"
    }
    var shortHead: String { String(head.prefix(7)) }
    /// The engine's data slot for this worktree: its own app data, kept across rebuilds and restarts.
    var slot: String { SessionStore.slot(for: worktree) }   // cached by path
    /// The pull requests of this worktree's Claude sessions from its own branch (a main checkout's sessions open
    /// them from many).
    var pullRequests: [ClaudePR] {
        (claude?.prs ?? []).filter { pr in pr.branch == nil || branch == nil || pr.branch == branch }
    }
    var hasOpenPR: Bool { (githubPR?.isOpen ?? false) || pullRequests.contains { $0.state == .open } }
    /// The primary pull request number associated with this session's branch, if any.
    var prNumber: Int? {
        if let n = githubPR?.number { return n }
        if let n = pullRequests.first(where: { $0.state == .open })?.number ?? pullRequests.first?.number { return n }
        if let pr = claude?.pullRequest, let n = Int(pr.lastPathComponent) { return n }
        return nil
    }
    var prTitle: String? { githubPR?.title }
    var prURL: URL? { githubPR?.url ?? pullRequests.first(where: { $0.state == .open })?.url ?? pullRequests.first?.url ?? claude?.pullRequest }
    var prState: String? {
        if let pr = githubPR { return pr.isDraft ? "DRAFT" : pr.state.uppercased() }
        return pullRequests.first(where: { $0.state == .open })?.state?.rawValue ?? pullRequests.first?.state?.rawValue
    }
    /// Every pull request known is closed and one of them merged: the work is in.
    var prMerged: Bool {
        if let pr = githubPR { return pr.isMerged }
        let prs = pullRequests
        return !prs.isEmpty && prs.allSatisfy { $0.state == .merged || $0.state == .closed } && prs.contains { $0.state == .merged }
    }
    /// A Claude session at work in it now (running, or waiting for the person).
    var claudeActive: Bool { guard let c = claude, !c.archived else { return false }; return c.running || c.status == .waiting }
    /// All active (running or waiting, non-archived, non-settled) T3 Code / Claude Code sessions in this worktree.
    var activeAgentSessions: [ClaudeSession] {
        let list = agentSessions.isEmpty ? [claude].compactMap { $0 } : agentSessions
        return list.filter { !$0.archived && !$0.settled && ($0.running || $0.status == .waiting) }
    }
    /// The primary T3 Code / Claude Code session worth displaying in the sidebar card for this worktree.
    /// Main checkouts only show active or recent unsettled sessions (avoiding stale archived threads);
    /// feature worktrees also show their most recent finished session so the owner thread stays visible.
    var displayAgent: ClaudeSession? {
        if let active = activeAgentSessions.first { return active }
        let list = agentSessions.isEmpty ? [claude].compactMap { $0 } : agentSessions
        if isMain {
            let cutoff = Date().addingTimeInterval(-3 * 86_400)
            return list.first { !$0.archived && !$0.settled && ($0.title != nil || $0.summary != nil) && ($0.lastActivity ?? .distantPast) > cutoff }
        }
        return list.first { !$0.archived && ($0.title != nil || $0.summary != nil || $0.running || $0.status == .waiting) }
    }
    /// Pull request summary to show on the row when `githubPR` is absent (main checkouts ignore stale merged/closed PRs).
    var fallbackPR: ClaudePR? {
        if let open = pullRequests.first(where: { $0.state == .open }) { return open }
        if isMain { return nil }
        return pullRequests.first
    }
    var isStale: Bool {
        guard let outputs, let sourcesDate else { return false }
        return outputs.date < sourcesDate
    }
}

/// An APK and where it came from.
struct Build: Codable, Equatable {
    enum Source: String, Codable { case local, ci, remote, file }

    /// First 16 hex of the file's SHA-256.
    let key: String
    /// `builds/<key>/app.apk`, an APFS clone: no extra disk.
    let apk: URL
    let source: Source
    let sha: String?
    let ref: String?
    let dirty: Bool
    let date: Date
    /// Pull request number this build was fetched or linked for, when known.
    let prNumber: Int?

    init(key: String, apk: URL, source: Source, sha: String?, ref: String?, dirty: Bool, date: Date, prNumber: Int? = nil) {
        self.key = key
        self.apk = apk
        self.source = source
        self.sha = sha
        self.ref = ref
        self.dirty = dirty
        self.date = date
        self.prNumber = prNumber
    }
}

extension Build {
    private enum Keys: String, CodingKey { case key, apk, source, sha, ref, dirty, date, prNumber }

    /// Tolerant like `Workspace`: a later workstream's new field does not make an older build.json unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(key: try c.decode(String.self, forKey: .key), apk: try c.decode(URL.self, forKey: .apk),
                  source: (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .file,
                  sha: try? c.decodeIfPresent(String.self, forKey: .sha), ref: try? c.decodeIfPresent(String.self, forKey: .ref),
                  dirty: (try? c.decodeIfPresent(Bool.self, forKey: .dirty)) ?? false,
                  date: (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date(timeIntervalSince1970: 0),
                  prNumber: try? c.decodeIfPresent(Int.self, forKey: .prNumber))
    }
}
