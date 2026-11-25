import Foundation

// Map history in git (docs/MAP-HISTORY-PLAN.md, "The store, and git"): a snapshot is stored as a commit under
// `refs/greenroom/`, outside every branch, tag and pull request, and shared by pushing and fetching those refs.
// Nothing here touches the working tree, the index, `HEAD` or a ref outside `refs/greenroom/`: git is used through
// its plumbing (`hash-object -w`, `mktree`, `commit-tree`, `update-ref`, `cat-file`) and nothing is checked out.

/// What a failed write says, in words.
struct MapGitFailure: Error, CustomStringConvertible {
    var description: String
    init(_ text: String) { description = text }
}

struct MapGit {
    /// The repository: a checkout (or one of its worktrees) or a bare repository.
    let repo: URL

    init(repo: URL) { self.repo = repo }

    /// What a write made: the git commit holding the snapshot, and the captures whose files the store could not give
    /// (the snapshot is written without them; `blobData` then has nothing for them).
    struct Written: Equatable {
        var commit: String
        var missing: [String]
    }

    // MARK: Names

    static let namespace = "refs/greenroom/maps"

    func ref(profile: String, commit: String) -> String { "\(Self.namespace)/\(profile)/\(commit)" }
    func ref(profile: String, tree: String) -> String { "\(Self.namespace)/\(profile)/tree/\(tree)" }

    /// A file or folder name for any string: letters, digits and `. _ - @` stay, everything else (and a leading dot,
    /// which git would hide or refuse) becomes `%XX` of its UTF-8 bytes. `%` is encoded too, so `decode` reverses it
    /// exactly and two strings never share a name.
    static func encode(_ name: String) -> String {
        var out = ""
        for (i, b) in name.utf8.enumerated() {
            let c = Character(UnicodeScalar(b))
            let plain = b < 128 && (c.isLetter || c.isNumber || c == "_" || c == "-" || c == "@" || (c == "." && i > 0))
            out += plain ? String(c) : String(format: "%%%02X", b)
        }
        return out.isEmpty ? "%00" : out
    }

    static func decode(_ name: String) -> String {
        if name == "%00" { return "" }
        var bytes: [UInt8] = []
        let u = Array(name.utf8)
        var i = 0
        while i < u.count {
            if u[i] == 37, i + 2 < u.count, let v = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(v); i += 3
            } else { bytes.append(u[i]); i += 1 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A screen's folder in the tree: its lineage, or its id while it has none.
    private static func folder(_ s: MapSnapshot.Screen) -> String { encode(s.lineage.isEmpty ? s.id : s.lineage) }

    /// A profile id or commit that is safe to put in a ref name and a command line.
    private static func safe(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && !s.hasPrefix("-") && !s.contains("..") && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    // MARK: Running git

    struct Result {
        var status: Int32
        var out: Data
        var err: String
        var timedOut = false
        var ok: Bool { status == 0 && !timedOut }
        var text: String { String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The same precautions as `Git.run` (no fsmonitor, no hooks, no prompts), synchronously, with input and a timeout.
    @discardableResult
    static func exec(_ args: [String], in dir: URL, input: Data? = nil, env extra: [String: String] = [:], timeout: TimeInterval = 60) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "gc.auto=0"] + args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        for k in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY"] { env[k] = nil }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input == nil ? FileHandle.nullDevice : inp
        guard (try? p.run()) != nil else { return Result(status: -1, out: Data(), err: "git could not be started") }
        var timedOut = false
        let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let group = DispatchGroup()
        var errData = Data()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if let input {
            group.enter()
            DispatchQueue.global().async {
                try? inp.fileHandleForWriting.write(contentsOf: input)
                try? inp.fileHandleForWriting.close()
                group.leave()
            }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        killer.cancel()
        return Result(status: p.terminationStatus, out: data, err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), timedOut: timedOut)
    }

    private func git(_ args: [String], input: Data? = nil, env: [String: String] = [:], timeout: TimeInterval = 60) -> Result {
        Self.exec(args, in: repo, input: input, env: env, timeout: timeout)
    }

    // MARK: Write

    /// A fixed author, committer and date: the same snapshot is the same commit, on every Mac and in CI.
    private static let identity = [
        "GIT_AUTHOR_NAME": "Greenroom", "GIT_AUTHOR_EMAIL": "greenroom@localhost", "GIT_AUTHOR_DATE": "2000-01-01T00:00:00+0000",
        "GIT_COMMITTER_NAME": "Greenroom", "GIT_COMMITTER_EMAIL": "greenroom@localhost", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00+0000",
    ]

    /// Stores `snapshot` as a commit whose tree is `map.json` and `screens/<folder>/<combination>.png`, and points
    /// `refs/greenroom/maps/<profile>/<commit>` at it, and (when no snapshot has it yet) the tree's ref
    /// `.../tree/<tree hash>`. `blob` gives the file of a capture by its hash. Returns the commit.
    @discardableResult
    func write(_ snapshot: MapSnapshot, blob: (String) -> URL?) throws -> Written {
        let profile = snapshot.profile.id
        guard Self.safe(snapshot.commit) else { throw MapGitFailure("the snapshot's commit is not a name git can keep: \(snapshot.commit)") }
        guard Self.safe(snapshot.tree) else { throw MapGitFailure("the snapshot's tree is not a name git can keep: \(snapshot.tree)") }

        func hash(_ r: Result, _ what: String) throws -> String {
            guard r.ok, !r.text.isEmpty else { throw MapGitFailure("git \(what) failed: \(r.err)") }
            return r.text
        }
        let map = try hash(git(["hash-object", "-w", "--no-filters", "--stdin"], input: snapshot.data()), "hash-object (map.json)")

        // Every capture file once, in one call.
        var wanted: [String] = [], files: [String: URL] = [:], missing: [String] = []
        for s in snapshot.screens {
            for hashName in s.captures.values.sorted() where files[hashName] == nil && !missing.contains(hashName) {
                if let url = blob(hashName) { files[hashName] = url; wanted.append(hashName) } else { missing.append(hashName) }
            }
        }
        var gitBlob: [String: String] = [:]
        if !wanted.isEmpty {
            let input = Data(wanted.map { files[$0]!.path }.joined(separator: "\n").utf8 + [10])
            let r = git(["hash-object", "-w", "--no-filters", "--stdin-paths"], input: input, timeout: 300)
            let ids = r.text.split(separator: "\n").map(String.init)
            guard r.ok, ids.count == wanted.count else { throw MapGitFailure("git hash-object failed on the captures: \(r.err)") }
            gitBlob = Dictionary(uniqueKeysWithValues: zip(wanted, ids))
        }

        func mktree(_ lines: [String]) throws -> String {
            try hash(git(["mktree"], input: Data((lines.joined(separator: "\n") + "\n").utf8)), "mktree")
        }
        var folders: [String: [String]] = [:]
        for s in snapshot.screens {
            for (combo, h) in s.captures {
                guard let id = gitBlob[h] else { continue }
                folders[Self.folder(s), default: []].append("100644 blob \(id)\t\(Self.encode(combo)).png")
            }
        }
        var root = ["100644 blob \(map)\tmap.json"]
        if !folders.isEmpty {
            // One call for every screen's folder: `mktree --batch` reads trees separated by a blank line.
            let names = folders.keys.sorted()
            let r = git(["mktree", "--batch"], input: Data(names.map { folders[$0]!.joined(separator: "\n") + "\n" }.joined(separator: "\n").utf8), timeout: 300)
            let ids = r.text.split(separator: "\n").map(String.init)
            guard r.ok, ids.count == names.count else { throw MapGitFailure("git mktree failed: \(r.err)") }
            root.append("040000 tree \(try mktree(zip(ids, names).map { "040000 tree \($0)\t\($1)" }))\tscreens")
        }
        let tree = try mktree(root)
        let message = "Map of \(snapshot.commit.prefix(7)) (profile \(profile))"
        let commit = try hash(git(["commit-tree", tree, "-m", message], env: Self.identity), "commit-tree")

        guard git(["update-ref", ref(profile: profile, commit: snapshot.commit), commit]).ok else { throw MapGitFailure("git update-ref failed") }
        // A tree that has a snapshot keeps the first one: both describe the same app. (The all-zero old value makes
        // update-ref refuse to replace.)
        _ = git(["update-ref", ref(profile: profile, tree: snapshot.tree), commit, String(repeating: "0", count: 40)])
        return Written(commit: commit, missing: missing)
    }

    // MARK: Read

    /// The ref holding the snapshot for `commit`: its own, else the one for its tree.
    private func find(profile: String, commit: String) -> String? {
        guard Self.safe(profile), !commit.isEmpty, !commit.hasPrefix("-") else { return nil }
        let own = ref(profile: profile, commit: commit)
        if Self.safe(commit), git(["rev-parse", "--verify", "-q", own + "^{commit}"]).ok { return own }
        let t = git(["rev-parse", "--verify", "-q", "--end-of-options", commit + "^{tree}"])
        guard t.ok, !t.text.isEmpty else { return nil }
        let byTree = ref(profile: profile, tree: t.text)
        return git(["rev-parse", "--verify", "-q", byTree + "^{commit}"]).ok ? byTree : nil
    }

    /// The snapshot for `commit`, or for a commit with the same tree. Nothing is checked out.
    func read(profile: String, commit: String) -> MapSnapshot? {
        guard let r = find(profile: profile, commit: commit) else { return nil }
        let f = git(["cat-file", "blob", r + ":map.json"])
        return f.ok ? MapSnapshot.read(f.out) : nil
    }

    /// One capture's PNG, read from the snapshot for `commit` (found as `read` does).
    func blobData(profile: String, commit: String, lineage: String, combo: String) -> Data? {
        guard let r = find(profile: profile, commit: commit) else { return nil }
        let f = git(["cat-file", "blob", "\(r):screens/\(Self.encode(lineage))/\(Self.encode(combo)).png"])
        return f.ok ? f.out : nil
    }

    /// The commits that have a snapshot of their own for `profile`, sorted.
    func list(profile: String) -> [String] {
        guard Self.safe(profile) else { return [] }
        let prefix = "\(Self.namespace)/\(profile)/"
        let r = git(["for-each-ref", "--format=%(refname)", prefix])
        return r.text.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix(prefix) && !$0.hasPrefix(prefix + "tree/") }
            .map { String($0.dropFirst(prefix.count)) }.sorted()
    }

    // MARK: Share

    private static func words(_ what: String, _ r: Result, timeout: TimeInterval) -> String? {
        if r.ok { return nil }
        if r.timedOut { return "\(what) took longer than \(Int(timeout)) seconds and was stopped" }
        let lines = r.err.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return "\(what) failed" + (lines.isEmpty ? "" : ": " + lines.suffix(4).joined(separator: " "))
    }

    private static func remoteOK(_ name: String) -> Bool { !name.isEmpty && !name.hasPrefix("-") && !name.contains(" ") }

    /// Pushes this profile's refs (inside `refs/greenroom/maps/*`, never forced) to `remote`. Nil when it worked,
    /// else what went wrong.
    func push(remote: String, profile: String, timeout: TimeInterval = 120) -> String? {
        guard Self.remoteOK(remote), Self.safe(profile) else { return "not a remote or profile name" }
        let spec = "\(Self.namespace)/\(profile)/*:\(Self.namespace)/\(profile)/*"
        return Self.words("pushing to \(remote)", git(["push", "--no-verify", remote, spec], timeout: timeout), timeout: timeout)
    }

    /// Fetches every `refs/greenroom/maps/*` of `remote`, never forced, touching no other ref. Nil when it worked.
    func fetch(remote: String, timeout: TimeInterval = 120) -> String? {
        guard Self.remoteOK(remote) else { return "not a remote name" }
        let spec = "\(Self.namespace)/*:\(Self.namespace)/*"
        let args = ["fetch", "--no-tags", "--no-recurse-submodules", "--no-write-fetch-head", "--refmap=", remote, spec]
        return Self.words("fetching from \(remote)", git(args, timeout: timeout), timeout: timeout)
    }

    // MARK: Prune

    /// Deletes this profile's refs for every commit not in `commits`, and the tree refs no kept commit shares.
    /// Returns how many refs it deleted. The objects stay until git's own garbage collection.
    @discardableResult
    func prune(keeping commits: [String], profile: String) -> Int {
        guard Self.safe(profile) else { return 0 }
        var keptTrees = Set<String>()
        for c in commits {
            if let s = read(profile: profile, commit: c) { keptTrees.insert(s.tree) }
            let t = git(["rev-parse", "--verify", "-q", "--end-of-options", c + "^{tree}"])
            if t.ok { keptTrees.insert(t.text) }
        }
        let prefix = "\(Self.namespace)/\(profile)/"
        let all = git(["for-each-ref", "--format=%(refname)", prefix]).text.split(separator: "\n").map(String.init)
        var doomed: [String] = []
        for r in all {
            let rest = String(r.dropFirst(prefix.count))
            if rest.hasPrefix("tree/") { if !keptTrees.contains(String(rest.dropFirst(5))) { doomed.append(r) } }
            else if !commits.contains(rest) { doomed.append(r) }
        }
        guard !doomed.isEmpty else { return 0 }
        let input = Data((doomed.map { "delete \($0)" }.joined(separator: "\n") + "\n").utf8)
        return git(["update-ref", "--stdin"], input: input).ok ? doomed.count : 0
    }
}
