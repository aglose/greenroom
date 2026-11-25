import Foundation

/// `Greenroom --map-share-check DIR`: map sharing through git (the workspace's "Share screen maps through git"),
/// headless, no engine, no network. A bare repository stands for `origin`; clones of it are people's workspaces, each
/// with its own store. With sharing on, a walk filed in one (through `History.filed`, as Evidence files it) is pushed as
/// refs to origin, and another's baseline lookup fetches, finds and imports it, captures included; a map walked on
/// signed-in data is written but not pushed; with sharing off nothing is written to any repository and nothing is
/// fetched; a remote that does not exist is reported in words and the walk is filed all the same.
enum MapShareCheck {
    static func run(dir: URL) -> Never {
        var ok = true
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; print("[greenroom] map-share: \(good ? "ok  " : "FAIL") \(what)") }
        func finish() -> Never { print("[greenroom] map-share check: \(ok ? "PASS" : "FAIL")"); exit(ok ? 0 : 1) }
        func sync<T>(_ body: @escaping () async -> T) -> T {
            var out: T?
            let wait = DispatchSemaphore(value: 0)
            Task.detached { out = await body(); wait.signal() }
            wait.wait()
            return out!
        }
        let fm = FileManager.default
        let base = dir.resolvingSymlinksInPath().appendingPathComponent("map-share-check", isDirectory: true)
        try? fm.removeItem(at: base)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)

        @discardableResult
        func git(_ args: [String], in repo: URL) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "user.name=Check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + args
            p.currentDirectoryURL = repo
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        func refs(_ repo: URL) -> [String] { (git(["for-each-ref", "--format=%(refname)", "refs/greenroom"], in: repo) ?? "").split(separator: "\n").map(String.init) }

        // A first repository with two commits on main, pushed to a bare origin; then four clones.
        let seed = base.appendingPathComponent("seed", isDirectory: true), origin = base.appendingPathComponent("origin.git", isDirectory: true)
        try? fm.createDirectory(at: seed, withIntermediateDirectories: true)
        guard git(["init", "-q", "-b", "main"], in: seed) != nil else { expect(false, "a repository was made (is /usr/bin/git there?)"); finish() }
        try? "one\n".write(to: seed.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        git(["add", "-A"], in: seed); git(["commit", "-q", "-m", "one"], in: seed)
        try? "two\n".write(to: seed.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        git(["commit", "-q", "-am", "two"], in: seed)
        let c2 = git(["rev-parse", "HEAD"], in: seed) ?? "", c1 = git(["rev-parse", "HEAD~1"], in: seed) ?? ""
        git(["clone", "-q", "--bare", seed.path, origin.path], in: base)
        func clone(_ name: String) -> URL {
            let u = base.appendingPathComponent(name, isDirectory: true)
            git(["clone", "-q", origin.path, u.path], in: base)
            return u
        }
        let a = clone("alice"), b = clone("bob"), c = clone("carol"), d = clone("dave")
        git(["remote", "set-url", "origin", base.appendingPathComponent("no-such-remote.git").path], in: d)
        expect(!c1.isEmpty && !c2.isEmpty && [a, b, c, d].allSatisfy { git(["rev-parse", "HEAD"], in: $0) == c2 }, "a bare origin and four clones of it, each at main's two commits")

        func workspace(_ root: URL, share: Bool) -> Workspace { var w = Workspace(root: root); w.baseRef = "origin/main"; w.shareMaps = share; return w }
        let wsA = workspace(a, share: true), wsB = workspace(b, share: true), wsC = workspace(c, share: false), wsD = workspace(d, share: true)
        let models = MapImpactCheck.models()
        let walk = base.appendingPathComponent("walk", isDirectory: true)
        MapImpactCheck.writeWalk(walk, models: models)
        let profile = MapProfile()
        func build(_ sha: String) -> Build { Build(key: String(sha.prefix(12)), apk: base.appendingPathComponent("x.apk"), source: .local, sha: sha, ref: nil, dirty: false, date: Date()) }
        func state(_ name: String) -> URL { base.appendingPathComponent("state-" + name, isDirectory: true) }

        // 1. Alice files a walk of c1: written and pushed.
        let filedA = sync { await History.filed(walk: walk, build: build(c1), profile: profile, candidates: [wsA], stateRoot: state("alice"), engine: "e1") }
        let own = "\(MapGit.namespace)/\(profile.id)/\(c1)"
        expect(filedA?.shareProblem == nil && filedA?.shared == "pushed to origin", "a walk filed with sharing on is written and pushed (\(filedA?.shared ?? filedA?.shareProblem ?? "nothing"))")
        expect(refs(a).contains(own) && refs(origin).contains(own) && refs(origin).contains { $0.contains("/tree/") }, "origin has its refs: by commit and by tree (\(refs(origin).count))")
        expect(git(["rev-parse", "HEAD"], in: a) == c2 && (git(["status", "--porcelain"], in: a) ?? "x").isEmpty && (git(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/tags"], in: origin) ?? "") == "refs/heads/main",
               "no branch, tag, checkout or working tree is touched")

        // 2. Bob's baseline for c2: fetched, found as c2's nearest ancestor, imported with its captures.
        let storeB = History.store(stateRoot: state("bob"), workspace: b)
        expect(storeB.snapshot(profile: profile.id, commit: c1) == nil, "bob's store starts without it")
        let found = sync { await History.baseline(of: build(c2), profile: profile, candidates: [wsB], stateRoot: state("bob")) }
        let imported = storeB.snapshot(profile: profile.id, commit: c1)
        expect(found?.snapshot.commit == c1 && found?.behind == 1 && found?.problem == nil, "bob's baseline lookup for c2 fetches and finds alice's map of c1, one commit behind")
        let captures = imported?.screens.flatMap { $0.captures.values } ?? []
        expect(imported == filedA?.snapshot && !captures.isEmpty && captures.allSatisfy { h in storeB.blobURL(h).flatMap { try? Data(contentsOf: $0) }.map { MapJSON.sha256($0) == h } ?? false },
               "it is imported into bob's store as alice saved it, with all \(captures.count) captures, each the bytes its hash names")

        // 3. A map walked on signed-in data: written in alice's repository, not pushed.
        let signedIn = MapProfile(signIn: "session-data")
        let before = refs(origin)
        let filedS = sync { await History.filed(walk: walk, build: build(c2), profile: signedIn, candidates: [wsA], stateRoot: state("alice"), engine: "e1") }
        let ownS = "\(MapGit.namespace)/\(signedIn.id)/\(c2)"
        expect(filedS?.shared?.contains("not pushed") == true && refs(a).contains(ownS) && refs(origin) == before, "a map walked on signed-in data is written here and not pushed (\(filedS?.shared ?? "nothing"))")
        var wsA2 = wsA; wsA2.shareSignedInMaps = true
        let filedS2 = sync { await History.filed(walk: walk, build: build(c2), profile: MapProfile(signIn: "session-data", offline: true), candidates: [wsA2], stateRoot: state("alice"), engine: "e1") }
        expect(filedS2?.shared == "pushed to origin", "with \"Also share maps walked on signed-in data\" on, it is pushed")

        // 4. Sharing off: nothing written to carol's repository or origin, nothing fetched.
        let originBefore = refs(origin)
        let filedC = sync { await History.filed(walk: walk, build: build(c2), profile: profile, candidates: [wsC], stateRoot: state("carol"), engine: "e1") }
        let foundC = sync { await History.baseline(of: build(c2), profile: profile, candidates: [wsC], stateRoot: state("carol")) }
        expect(filedC != nil && filedC?.shared == nil && filedC?.shareProblem == nil && refs(c).isEmpty && refs(origin) == originBefore && foundC?.snapshot.commit == c2,
               "with sharing off the walk is filed in the store only: no ref in carol's repository or origin, nothing fetched (carol has \(refs(c).count) refs)")

        // 5. A remote that does not exist: said in words, and the walk is filed all the same.
        let filedD = sync { await History.filed(walk: walk, build: build(c1), profile: profile, candidates: [wsD], stateRoot: state("dave"), engine: "e1") }
        expect(filedD != nil && History.store(stateRoot: state("dave"), workspace: d).snapshot(profile: profile.id, commit: c1) != nil && (filedD?.shareProblem?.contains("failed") ?? false),
               "a remote that does not exist is reported and does not stop the filing: \(filedD?.shareProblem ?? "no problem reported")")
        let fetchD = sync { await History.fetchIfDue(wsD, stateRoot: state("dave-2")) }
        expect(fetchD?.hasPrefix("fetching from origin failed") == true, "and a fetch from it says so: \(fetchD ?? "nothing")")
        let again = sync { await History.fetchIfDue(wsD, stateRoot: state("dave-2")) }
        expect(again == nil, "a second fetch within ten minutes is not made")

        // 6. The setting round-trips and is off by default.
        let decoded = MapJSON.decode(Workspace.self, from: MapJSON.encode(wsA2))
        let old = MapJSON.decode(Workspace.self, from: Data(#"{"root": "file:///tmp/x/"}"#.utf8))
        expect(decoded?.shareMaps == true && decoded?.shareSignedInMaps == true && old?.shareMaps == false && old?.shareSignedInMaps == false,
               "the two settings are saved with the workspace, and a workspace saved before them has both off")
        finish()
    }
}
