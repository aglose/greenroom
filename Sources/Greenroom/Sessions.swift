import Foundation

// The model of docs/SESSIONS-PLAN.md ("The model"). Later workstreams fill in what is stubbed here: `Recipe` (W2),
// `Auto` (W3) and `ClaudeSession` (W1).

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

    init(root: URL) { self.root = root }
}

/// An executable that builds an APK. Run by W2; stored here so a workspace's settings round-trip.
struct Recipe: Codable, Equatable {
    var executable: String
    var arguments: [String] = []
}

enum Auto: String, Codable {
    case off, onBuild, onTurnEnd
}

/// What W1 reads of a Claude Code session. Every field is optional to the reader.
struct ClaudeSession: Equatable {
    var title: String?
    var status: String?
    var pullRequest: URL?
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
    var title: String { claude?.title ?? branch ?? "(detached \(String(head.prefix(7))))" }
    var shortHead: String { String(head.prefix(7)) }
    /// The engine's data slot for this worktree: its own app data, kept across rebuilds and restarts.
    var slot: String { SessionStore.slot(for: worktree) }
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
}
