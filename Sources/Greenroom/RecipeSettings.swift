import Foundation

// What the `ci` and `remote` recipes (Resources/recipes/ci.sh, remote.sh) are told besides the plan's GREENROOM_*
// contract: per-workspace settings, read tolerantly like the rest of the store (an unknown or mistyped field is
// the default, never a workspace that fails to load), and the facts about a workspace the menus need.

/// The `ci` recipe's settings (docs/SESSIONS-PLAN.md, "2. Builds").
struct CISettings: Codable, Equatable {
    /// The artifact's name. Empty: the only artifact that holds an APK matching `apk`.
    var artifact = ""
    /// A glob for the APK's file name inside the artifact. Empty: `*.apk`.
    var apk = ""
    /// A workflow with `workflow_dispatch`, started when a commit has no run. Empty: none is started.
    var workflow = ""

    init() {}
    private enum Keys: String, CodingKey { case artifact, apk, workflow }
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else { return }
        artifact = (try? c.decodeIfPresent(String.self, forKey: .artifact)) ?? ""
        apk = (try? c.decodeIfPresent(String.self, forKey: .apk)) ?? ""
        workflow = (try? c.decodeIfPresent(String.self, forKey: .workflow)) ?? ""
    }
}

/// The `remote` recipe's settings, and the person's answer to "upload this repository's source code?".
struct RemoteSettings: Codable, Equatable {
    /// An existing boat.dev sandbox to resume for each build (and stop after it).
    var sandbox = ""
    /// A snapshot to create a sandbox from when there is no sandbox id.
    var template = ""
    /// nil: never asked. true: allowed for this repository. false: the person said no. Only true lets the recipe run.
    var consent: Bool?

    init() {}
    private enum Keys: String, CodingKey { case sandbox, template, consent }
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else { return }
        sandbox = (try? c.decodeIfPresent(String.self, forKey: .sandbox)) ?? ""
        template = (try? c.decodeIfPresent(String.self, forKey: .template)) ?? ""
        consent = try? c.decodeIfPresent(Bool.self, forKey: .consent)
    }
}

extension Workspace {
    /// The settings the recipes read from the environment, beside the GREENROOM_* contract.
    var recipeEnvironment: [String: String] {
        var env: [String: String] = [:]
        if !ci.artifact.isEmpty { env["GREENROOM_CI_ARTIFACT"] = ci.artifact }
        if !ci.apk.isEmpty { env["GREENROOM_CI_APK"] = ci.apk }
        if !ci.workflow.isEmpty { env["GREENROOM_CI_WORKFLOW"] = ci.workflow }
        if !remote.sandbox.isEmpty { env["GREENROOM_REMOTE_SANDBOX"] = remote.sandbox }
        if !remote.template.isEmpty { env["GREENROOM_REMOTE_TEMPLATE"] = remote.template }
        if remote.consent == true { env["GREENROOM_REMOTE_CONSENT"] = "1" }
        return env
    }

    /// Why a recipe may not run for this workspace yet, or nil.
    func refusal(forRecipe name: String) -> String? {
        if name == "local" && disableLocalBuilds {
            return "Local Gradle builds are disabled for \(root.lastPathComponent). Use your PR APK script, link a local APK, or re-enable local builds in Settings > Build Recipes."
        }
        if name == "remote" && recipes["remote"] == nil && remote.consent != true {
            return "The remote recipe has not been allowed for \(root.lastPathComponent): it uploads this repository's source code to your own boat.dev account. Choose Build with > remote to read what it sends and say yes."
        }
        return nil
    }
}

/// Starter template and helpers for user-owned PR APK retrieval scripts.
/// Greenroom never connects to Artifactory or external artifact stores directly: the user provides their own
/// local executable script that runs with their own credentials and returns an APK (via GREENROOM_OUT or GREENROOM_APK=).
enum PRFetchScript {
    static var folder: URL { Engine.shared.state.appendingPathComponent("recipes", isDirectory: true) }

    /// Writes an executable starter script for `repoName` and returns its URL.
    static func createTemplate(for repoName: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safe = repoName.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "-" }
        let base = String(safe).isEmpty ? "repo" : String(safe)
        var url = folder.appendingPathComponent("\(base)-pr-apk.sh")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-pr-apk-\(n).sh")
            n += 1
        }
        guard fm.createFile(atPath: url.path, contents: Data(template.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    static let template = #"""
        #!/bin/bash
        # Greenroom PR APK Script: fetch or locate an APK for a pull request using your own tools and credentials.
        # Greenroom never connects to Artifactory or your build storage directly — only this script does.
        #
        # Environment variables provided by Greenroom:
        #   GREENROOM_PR_NUMBER   Pull request number (when a PR exists for this branch / review row)
        #   GREENROOM_PR_TITLE    Pull request title (when known)
        #   GREENROOM_PR_URL      Pull request URL (when known)
        #   GREENROOM_PR_STATE    Pull request state: OPEN, DRAFT, MERGED, CLOSED (when known)
        #   GREENROOM_REF         Branch name
        #   GREENROOM_SHA         Commit SHA
        #   GREENROOM_REPO_SLUG   GitHub owner/repo (when a GitHub remote exists)
        #   GREENROOM_WORKTREE    Path to the local git worktree
        #   GREENROOM_REPO        Path to the repository's main checkout
        #   GREENROOM_MODULE      Selected Gradle module (empty if auto-detected)
        #   GREENROOM_VARIANT     Selected build variant (default: debug)
        #   GREENROOM_OUT         Destination path if you copy/download the APK directly
        #   Plus any variables from Greenroom > Settings > Variables (secrets are masked in logs).
        #
        # Two ways to hand the APK back to Greenroom:
        #   1. Download or copy the APK directly to "$GREENROOM_OUT", OR
        #   2. Point Greenroom at a local APK you downloaded/kept on disk by printing:
        #        GREENROOM_APK=/path/to/your/app-pr.apk
        #      (optionally also print GREENROOM_PR=123 to tag/link it to a specific PR number).
        #
        # To give the job a progress bar in Greenroom's job list, print how far you are as you go (these lines are
        # kept out of the log):
        #   echo "greenroom: progress 1048576/52428800 bytes"   # also: 3/12 steps, 7/? files, 40%, and - to clear
        #
        # You can also link a local APK to a PR from outside Greenroom at any time:
        #   /Applications/Greenroom.app/Contents/MacOS/Greenroom --link-apk /path/to/app.apk --pr 123
        set -euo pipefail

        pr="${GREENROOM_PR_NUMBER:-}"
        sha="${GREENROOM_SHA:-}"
        branch="${GREENROOM_REF:-}"

        # Example 1 (JFrog CLI / Artifactory):
        # : "${pr:?no open pull request found for branch '${branch:-detached}'}"
        # tmp="$(mktemp -d)"
        # trap 'rm -rf "$tmp"' EXIT
        # jf rt dl "my-android-repo/pr-${pr}/*-debug.apk" "$tmp/" --flat=true --sort-by=created --sort-order=desc --limit=1
        # apk="$(find "$tmp" -name '*.apk' -type f | head -n 1)"
        # [ -n "$apk" ] || { echo "error: no APK found in Artifactory for PR #${pr}" >&2; exit 1; }
        # cp "$apk" "$GREENROOM_OUT"

        # Example 2 (link an already-downloaded local APK to this PR without copying):
        # echo "GREENROOM_PR=${pr}"
        # echo "GREENROOM_APK=$HOME/Downloads/app-pr-${pr}.apk"

        echo "error: edit $0 with your command to fetch or locate the PR APK (PR=${pr:-none}, sha=${sha:0:7})" >&2
        exit 1
        """#
}

/// Whether a repository has a GitHub remote (the `ci` recipe is offered only then), and what CI would be behind by.
enum GitHubRemote {
    /// `owner/repo` of a remote URL on GitHub (https, ssh or scp-like), or nil for any other host.
    static func slug(of url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = "", path = ""
        if let r = s.range(of: "://") {
            let rest = String(s[r.upperBound...])
            let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            host = String(parts.first ?? "")
            path = parts.count > 1 ? String(parts[1]) : ""
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        } else if let colon = s.firstIndex(of: ":"), !s.hasPrefix("/") {
            host = String(s[..<colon])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            path = String(s[s.index(after: colon)...])
        } else {
            return nil
        }
        guard host.lowercased() == "github.com" || host.lowercased().hasSuffix(".github.com") else { return nil }
        s = path
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        let comps = s.split(separator: "/").map(String.init)
        guard comps.count >= 2 else { return nil }
        return comps[0] + "/" + comps[1]
    }

    private static let lock = NSLock()
    private static var cache: [String: (slugs: [String], at: Date)] = [:]

    /// The GitHub `owner/repo`s of a repository's remotes. A few milliseconds of `git config` the first time, kept
    /// for a minute (a menu asks, so this is synchronous and never talks to the network).
    static func slugs(of root: URL) -> [String] {
        lock.lock()
        if let c = cache[root.path], Date().timeIntervalSince(c.at) < 60 { lock.unlock(); return c.slugs }
        lock.unlock()
        var found: [String] = []
        if Git.available {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "core.fsmonitor=false", "config", "--get-regexp", "^remote\\..*\\.(push)?url$"]
            p.currentDirectoryURL = root
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    guard let sp = line.firstIndex(of: " ") else { continue }
                    if let s = slug(of: String(line[line.index(after: sp)...])), !found.contains(s) { found.append(s) }
                }
            }
        }
        lock.lock(); cache[root.path] = (found, Date()); lock.unlock()
        return found
    }

    static func has(_ root: URL) -> Bool { !slugs(of: root).isEmpty }

    /// `owner/repo` the recipes are told (GREENROOM_REPO_SLUG): the GitHub remote the worktree's upstream uses, else
    /// `origin`, else the first GitHub remote there is. gh is then told with -R, never left to guess.
    static func repoSlug(for worktree: URL) async -> String? {
        async let upstreamOut = Git.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], in: worktree)
        async let remotesOut = Git.run(["config", "--get-regexp", "^remote\\..*\\.(push)?url$"], in: worktree)
        let upstream = (await upstreamOut)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var byRemote: [(name: String, slug: String)] = []
        for line in (await remotesOut ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix("remote."), let slug = slug(of: parts[1]) else { continue }
            var name = String(parts[0].dropFirst(7))
            for suffix in [".pushurl", ".url"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)); break }
            byRemote.append((name, slug))
        }
        // The longest remote name that starts the upstream's name ("origin/main", or "my/fork/main" for a remote "my/fork").
        if let up = byRemote.filter({ upstream.hasPrefix($0.name + "/") }).max(by: { $0.name.count < $1.name.count }) { return up.slug }
        return byRemote.first { $0.name == "origin" }?.slug ?? byRemote.first?.slug
    }
    static func forget(_ root: URL) { lock.lock(); cache[root.path] = nil; lock.unlock() }
}

/// "CI has a1b2c3d, 2 commits behind": what the `ci` recipe would build when it is older than the worktree.
enum CIBehind {
    /// The row's words, or nil when CI would build what the worktree is. `ciSha` is the commit the worktree's
    /// upstream is at (the newest one GitHub can have). "CI has" only when a CI run of it is known (`known`: the
    /// store holds a CI build of it); otherwise it is only what is pushed.
    static func describe(ciSha: String, ahead: Int, dirty: Bool, known: Bool = true) -> String? {
        let short = String(ciSha.prefix(7))
        let head = known ? "CI has \(short)" : "pushed: \(short)"
        if ahead > 0 { return head + ", \(ahead) commit\(ahead == 1 ? "" : "s") behind" }
        if dirty { return head + ", without your edits" }
        return nil
    }

    private static let lock = NSLock()
    /// worktree path + head + ahead -> the upstream's commit and when it was read ("" for none).
    private static var shas: [String: (sha: String, at: Date)] = [:]
    private static var asking = Set<String>()
    static var maxAge: TimeInterval = 20

    private static func learned(_ key: String, _ sha: String) {
        lock.lock(); defer { lock.unlock() }
        shas[key] = (sha, Date())
        asking.remove(key)
    }

    /// The words for a session's row, from what is known now. The upstream's commit moves when a fetch lands, so it
    /// is asked of git again in the background once it is `maxAge` old (the old answer stands meanwhile) and `then`
    /// runs on the main thread when it is known.
    static func note(for s: Session, store: SessionStore? = nil, then: @escaping () -> Void) -> String? {
        guard s.ahead > 0 || s.dirty else { return nil }
        let key = s.worktree.path + "@" + s.head + "+" + String(s.ahead)
        lock.lock()
        let known = shas[key]
        let busy = asking.contains(key)
        let stale = known.map { Date().timeIntervalSince($0.at) > maxAge } ?? true
        if stale && !busy { asking.insert(key) }
        lock.unlock()
        if stale && !busy {
            let wt = s.worktree
            Task {
                let out = await Git.run(["rev-parse", "--verify", "--quiet", "@{upstream}"], in: wt)
                let sha = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let changed = sha != known?.sha
                learned(key, sha)
                if changed { await MainActor.run { then() } }
            }
        }
        guard let k = known, !k.sha.isEmpty else { return nil }
        let isKnown = (store ?? SessionStore.shared).build(forSha: k.sha)?.source == .ci
        return describe(ciSha: k.sha, ahead: s.ahead, dirty: s.dirty, known: isKnown)
    }
}
