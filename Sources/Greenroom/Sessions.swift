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

    init(root: URL) { self.root = root }

    // A file written before a field existed still reads: every key but the root has a default.
    private enum Keys: String, CodingKey { case root, module, variant, baseRef, recipes, auto, ci, remote, walkWithData }

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
    var slot: String { SessionStore.slot(for: worktree) }   // cached by path
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

extension Build {
    private enum Keys: String, CodingKey { case key, apk, source, sha, ref, dirty, date }

    /// Tolerant like `Workspace`: a later workstream's new field does not make an older build.json unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(key: try c.decode(String.self, forKey: .key), apk: try c.decode(URL.self, forKey: .apk),
                  source: (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .file,
                  sha: try? c.decodeIfPresent(String.self, forKey: .sha), ref: try? c.decodeIfPresent(String.self, forKey: .ref),
                  dirty: (try? c.decodeIfPresent(Bool.self, forKey: .dirty)) ?? false,
                  date: (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date(timeIntervalSince1970: 0))
    }
}
