import AppKit

// The agent's tools for a session (docs/SESSIONS-PLAN.md, "5. The Claude Code link", "What the agent gets"):
// `session`, `build`, `changes` and `screenshot`'s `screen`, and the recording of an agent's session. All of them work
// only for a connection tied to a session (the shim's folder is a worktree of an added repository), and say so
// plainly when it is not. They use what the app already has: the build queue (`Builds.start`, so the remote
// recipe's consent holds), `Bases.resolve` and `Evidence.changes`. Nothing here starts a build of a base: an
// unbuilt base is answered as text. Called off the main thread.

extension AgentTools {
    static let noSession = "this folder is not a worktree of a repository added to Greenroom: run the agent from a worktree of one"
    /// The same, with why this call did not add the folder's repository when there is a reason to give.
    static func noSession(_ connection: Connection) -> String {
        guard let why = connection.why else { return noSession }
        return "this folder is not a worktree of a repository added to Greenroom (\(why))"
    }

    // MARK: Plumbing

    func mainSync<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }

    /// Runs async work to the end, for a tool (which runs on its own queue and is never the main thread).
    func blocking<T>(_ body: @escaping () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var out: T?
        Task.detached { out = await body(); done.signal() }
        done.wait()
        return out!
    }

    /// The session this connection is tied to, as the app has it now, with its workspace and git state read again.
    func tied(_ connection: Connection) throws -> (session: Session, workspace: Workspace) {
        guard let wb = workbench, let old = connection.session else { throw Failure(message: Self.noSession(connection)) }
        var found: (Session, Workspace)?
        mainSync {
            let s = wb.sessions.session(atWorktree: old.worktree) ?? old
            if let ws = wb.sessions.workspaces.first(where: { $0.root.path == s.workspace.path }) { found = (s, ws) }
        }
        guard var (s, ws) = found else { throw Failure(message: Self.noSession) }
        let wt = s.worktree
        if let state = blocking({ await Git.state(of: wt) }) {
            s.head = state.head; s.branch = state.branch; s.dirty = state.dirty; s.ahead = state.ahead
            if let d = state.sourcesDate { s.sourcesDate = d }
        }
        if Engine.agentCheck { AgentCheckHooks.adjust(&ws) }
        return (s, ws)
    }

    private func label(_ s: Session) -> String { s.branch ?? "detached \(s.shortHead)" }

    func age(_ date: Date) -> String {
        let n = max(0, Int(Date().timeIntervalSince(date)))
        if n < 90 { return "\(n) s ago" }
        if n < 5400 { return "\(n / 60) min ago" }
        if n < 129_600 { return "\(n / 3600) h ago" }
        return "\(n / 86_400) days ago"
    }

    private func clamp(_ v: Any?, _ low: Int, _ high: Int, _ fallback: Int) -> TimeInterval {
        TimeInterval(min(max((v as? Int) ?? fallback, low), high))
    }

    /// The newest build of a session: a recipe's, or the newest APK its worktree's Gradle outputs hold.
    private func newestBuild(_ s: Session) -> (apk: URL, date: Date, source: String, key: String?)? {
        guard let wb = workbench else { return nil }
        let fm = FileManager.default
        return mainSync {
            var c: [(URL, Date, String, String?)] = []
            for b in [s.build, wb.sessions.builds[s.worktree.path]].compactMap({ $0 }) { c.append((b.apk, b.date, b.source.rawValue, b.key)) }
            if let o = s.outputs { c.append((o.apk, o.date, "Gradle output", nil)) }
            return c.filter { fm.fileExists(atPath: $0.0.path) }.max { $0.1 < $1.1 }.map { (apk: $0.0, date: $0.1, source: $0.2, key: $0.3) }
        }
    }

    /// The session's newest build as a stored `Build` (an APK only Gradle made is filed first).
    func headBuild(_ s: Session) -> Build? {
        guard let wb = workbench, let n = newestBuild(s) else { return nil }
        let store = mainSync { wb.sessions.store }
        if let key = n.key, let b = store.build(key) { return b }
        return store.record(apk: n.apk, source: .local, sha: s.head, ref: s.branch, dirty: s.dirty, date: n.date)
    }

    // MARK: session

    func sessionTool(_ connection: Connection) throws -> String {
        let (s, ws) = try tied(connection)
        guard let wb = workbench else { throw Failure(message: Self.noSession) }
        var lines = ["\(label(s)) \(s.shortHead) (\(s.dirty ? "uncommitted changes" : "clean")\(s.ahead > 0 ? ", \(s.ahead) ahead of its upstream" : ""))"]
        if let n = newestBuild(s) {
            let stale = (s.sourcesDate.map { $0 > n.date } ?? false) ? "stale: the sources are newer, call build" : "current"
            lines.append("build: \(age(n.date)), \(n.source), \(stale)\(n.key.map { " [\($0)]" } ?? "")")
        } else {
            lines.append("build: none yet, call build")
        }
        let name = mainSync { ws.defaultRecipeName }
        let others = ws.recipeNames.filter { $0 != name }
        lines.append("default recipe: \(name)" + (others.isEmpty ? "" : " (others: \(others.joined(separator: ", ")))"))
        lines.append("base: \(ws.baseRef)")
        lines.append("launch: skin \(ws.skin.isEmpty ? "none" : ws.skin), options \(ws.launchOptions.isEmpty ? "none" : ws.launchOptions) (launch_settings changes them)")
        let sim = mainSync { wb.sessions.simulator(for: s) }
        lines.append(sim.map { "simulator: \(id($0)) running" } ?? "simulator: none (launch starts it)")
        if let c = s.claude, let title = c.title { lines.append("claude session: \(ScreenNode.quote(title)) (\(c.status.rawValue))") }
        let taking = mainSync { recording.recording(for: s.worktree.path) }
        if let r = taking, r.live { lines.append("recording: your session is being recorded for the person (\(r.file.lastPathComponent))") }
        return lines.joined(separator: "\n")
    }

    // MARK: launch_settings

    func launchSettingsTool(_ args: [String: Any], _ connection: Connection) throws -> String {
        let (_, ws) = try tied(connection)
        guard let wb = workbench else { throw Failure(message: Self.noSession) }
        let skinArg = (args["skin"] as? String)?.trimmingCharacters(in: .whitespaces)
        let optionsArg = (args["options"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let skins: [LaunchSettings.Skin] = {
            let done = DispatchSemaphore(value: 0)
            var listed: [LaunchSettings.Skin] = []
            DispatchQueue.main.async { LaunchSettings.loadSkins { listed = $0; done.signal() } }
            return done.wait(timeout: .now() + 20) == .success ? listed : mainSync { LaunchSettings.cachedSkins }
        }()
        var lines: [String] = []
        if skinArg != nil || optionsArg != nil {
            var skin = skinArg ?? ws.skin
            if skin == "off" || skin == "none" { skin = "" }
            if !skin.isEmpty, !skins.contains(where: { $0.name == skin }) {
                throw Failure(message: "there is no stored skin called \(skin): the skins are \(skins.map(\.name).joined(separator: ", "))")
            }
            let options = optionsArg ?? ws.launchOptions
            let dropped = LaunchSettings.sanitized(LaunchSettings.tokens(options)).dropped
            mainSync { wb.sessions.setLaunch(skin: skin, options: options, for: ws.root) }
            lines.append("saved for \(ws.root.lastPathComponent): a running simulator takes the skin now, the options when it next launches")
            if !dropped.isEmpty { lines.append("left out (Greenroom sets these itself): \(dropped.joined(separator: ", "))") }
        }
        let now = mainSync { wb.sessions.workspaces.first { $0.root.path == ws.root.path } } ?? ws
        lines.append("skin: \(now.skin.isEmpty ? "none" : now.skin)")
        lines.append("options: \(now.launchOptions.isEmpty ? "none" : now.launchOptions)")
        let effective = mainSync { LaunchSettings.options(for: now) }
        if !effective.isEmpty { lines.append("added to each launch: \(effective.joined(separator: " "))") }
        lines.append("stored skins: " + (skins.isEmpty ? "none" : skins.map { s in [s.name, s.device.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", ")))
        return lines.joined(separator: "\n")
    }

    // MARK: build

    func buildTool(_ args: [String: Any], _ connection: Connection) throws -> String {
        let (s, ws) = try tied(connection)
        guard let wb = workbench else { throw Failure(message: Self.noSession) }
        let name = (args["recipe"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? mainSync { ws.defaultRecipeName }
        guard ws.recipe(named: name) != nil else {
            throw Failure(message: "there is no recipe called \(name): the recipes are \(ws.recipeNames.joined(separator: ", "))")
        }
        // The remote recipe uploads source code: only the person's yes, given in Greenroom, lets it run. An agent cannot give it.
        if let refusal = ws.refusal(forRecipe: name) {
            if name == "remote" {
                throw Failure(message: "The remote recipe uploads this repository's source code to the person's own boat.dev account, and they have not allowed it. Ask them to allow it in Greenroom (the row's Build with > remote); an agent cannot give that yes. Meanwhile use another recipe.")
            }
            throw Failure(message: refusal)
        }
        // One call waits at most 200 s (the shim gives up at 300); the build goes on and a second call joins it.
        let timeout = clamp(args["timeout_s"], 10, 200, 200)
        var why = ""
        // Never start a CI workflow from an agent's call: only the person's own Build button may.
        let job: BuildJob? = mainSync {
            wb.sessions.buildQueue.start(s, workspace: ws, recipeName: name, store: wb.sessions.store, environment: ["GREENROOM_CI_DISPATCH": "0"], error: { why = $0 })
        }
        var running = job
        if running == nil, why.contains("already building") { running = mainSync { wb.sessions.buildQueue.job(for: s) } }   // join it
        guard let j = running else { throw Failure(message: why.isEmpty ? "the build could not be started" : why) }
        let started = Date()
        let end = started.addingTimeInterval(timeout)
        while true {
            let state = mainSync { j.state }
            switch state {
            case .queued, .running: break
            case .built(let b):
                var out = ["built \(b.key) with the \(j.recipeName) recipe, \(age(b.date)), in \(Int(Date().timeIntervalSince(started))) s"
                           + (b.sha.map { " from \(String($0.prefix(7)))" } ?? "") + (b.dirty ? " with uncommitted changes" : "")]
                if mainSync({ wb.sessions.simulator(for: s) }) != nil { out.append("the session's simulator reloads on it, with its data kept") }
                return out.joined(separator: "\n")
            case .failed(let reason):
                var text = "build failed (\(j.recipeName) recipe): \(reason)"
                let tail = errorLines(mainSync { j.lines })
                if !tail.isEmpty { text += "\n" + tail }
                if j.recipeName == "ci", (reason + tail).contains("no CI run") {
                    text += "\nNo CI run exists for this commit. A ci build started by an agent never starts a workflow: only the person's Build button in Greenroom may. Use the local recipe, or ask them."
                }
                throw Failure(message: text)
            case .cancelled:
                throw Failure(message: "the build was cancelled in Greenroom")
            }
            if Date() > end {
                throw Failure(message: "still building after \(Int(timeout)) s: the \(j.recipeName) build goes on in Greenroom. Call build again to join it.")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// The log's last error lines: lines that say error or failure, else just its last lines.
    private func errorLines(_ log: [String]) -> String {
        let all = log.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let bad = all.filter { l in ["error", "failed", "exception", "fatal", "what went wrong"].contains { l.localizedCaseInsensitiveContains($0) } }
        let pick = bad.isEmpty ? Array(all.suffix(12)) : Array(bad.suffix(12))
        return pick.map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }.joined(separator: "\n")
    }

    // MARK: link_apk

    func linkAPKTool(_ args: [String: Any], _ connection: Connection) throws -> String {
        guard let wb = workbench else { throw Failure(message: Self.noSession) }
        guard let rawPath = (args["apk"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            throw Failure(message: "link_apk requires apk: the path to a local .apk file")
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let apkURL = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard apkURL.pathExtension.lowercased() == "apk",
              FileManager.default.fileExists(atPath: apkURL.path, isDirectory: &isDir), !isDir.boolValue,
              FileManager.default.isReadableFile(atPath: apkURL.path) else {
            throw Failure(message: "\(rawPath) is not a readable .apk file")
        }
        let prNumber = (args["pr_number"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        let shouldOpen = (args["open"] as? Bool) ?? false

        if let tiedSession = try? tied(connection) {
            let s = tiedSession.session
            let linkedBuild: Build? = blocking {
                await wb.sessions.linkLocalAPK(apkURL, to: s, prNumber: prNumber, open: shouldOpen)
            }
            guard let build = linkedBuild else { throw Failure(message: "could not store \(apkURL.lastPathComponent)") }
            let prNote = (build.prNumber ?? prNumber).map { " (PR #\($0))" } ?? ""
            mainSync { wb.toast.show("Linked \(apkURL.lastPathComponent) to \(s.title)\(prNote)") }
            return "linked \(apkURL.lastPathComponent) [\(build.key)] to \(label(s))\(prNote)"
        }
        if let prNumber {
            let result: (build: Build?, linkedTargets: [String]) = blocking {
                await wb.sessions.linkLocalAPK(apkURL, toPR: prNumber, workspace: nil, open: shouldOpen)
            }
            guard let build = result.build else { throw Failure(message: "could not store \(apkURL.lastPathComponent)") }
            let targetDesc = result.linkedTargets.isEmpty ? "PR #\(prNumber) in store" : result.linkedTargets.joined(separator: ", ")
            mainSync { wb.toast.show("Linked \(apkURL.lastPathComponent) to PR #\(prNumber)") }
            return "linked \(apkURL.lastPathComponent) [\(build.key)] to \(targetDesc)"
        }
        throw Failure(message: "link_apk needs either a worktree of an added repository or a pr_number")
    }

    // MARK: changes

    private func baseRef(_ arg: String?, _ s: Session, _ sessions: [Session]) throws -> BaseRef {
        let a = (arg ?? "").trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return .baseBranch }
        if a.hasPrefix("session:") {
            let b = String(a.dropFirst(8))
            guard let other = sessions.first(where: { $0.workspace.path == s.workspace.path && ($0.branch == b || $0.worktree.lastPathComponent == b) }) else {
                throw Failure(message: "no session on a branch called \(b) in this repository")
            }
            return .session(other.worktree.path)
        }
        if a.hasPrefix("pr:") || a.hasPrefix("#") {
            guard let n = PullRequestRef.parse(a.hasPrefix("pr:") ? String(a.dropFirst(3)) : a) else { throw Failure(message: "pr: takes a pull request number") }
            return .pullRequest(n.number)
        }
        if a.hasPrefix("/") || a.hasPrefix("~") || a.lowercased().hasSuffix(".apk") {
            // As launch does: an .apk, readable, that is a file. Anything else is not an APK to compare with.
            guard a.hasPrefix("/") || a.hasPrefix("~") else { throw Failure(message: "base: give the .apk's full path (starting with / or ~)") }
            let url = URL(fileURLWithPath: (a as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard url.pathExtension.lowercased() == "apk", FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw Failure(message: "base: \(a) is not a readable .apk file")
            }
            return .apk(url)
        }
        return .ref(a)
    }

    func changesTool(_ args: [String: Any], _ connection: Connection) throws -> String {
        let (s, ws) = try tied(connection)
        guard let wb = workbench else { throw Failure(message: Self.noSession) }
        if let a = (args["base"] as? String)?.trimmingCharacters(in: .whitespaces), a.hasPrefix("snapshot:") {
            return try changesFromSnapshots(String(a.dropFirst(9)), s, ws, wb)
        }
        guard let head = headBuild(s) else { throw Failure(message: "no build yet for \(label(s)): call build") }
        let timeout = clamp(args["timeout_s"], 10, 200, 200)
        let deadline = Date().addingTimeInterval(timeout)   // one deadline for the whole call, the base's fetch included
        let (sessions, store) = mainSync { (wb.sessions.sessions, wb.sessions.store) }
        let ref = try baseRef(args["base"] as? String, s, sessions)
        let wt = s.worktree
        // The fetch (CI, gh) may take long: it runs on, and a call that gave up waiting leaves it for the next one to join.
        let key = wt.path + "|" + ((args["base"] as? String) ?? "")
        var box: ResolveBox!
        var begun = false
        changesLock.lock()
        // Entered under the lock: a second call that finds the box must find its group already entered, or it would not wait.
        if let b = pendingResolves[key] { box = b } else { box = ResolveBox(); box.group.enter(); pendingResolves[key] = box; begun = true }
        changesLock.unlock()
        if begun {
            let mine: ResolveBox = box
            Task.detached { [weak self] in
                let r = await Bases.resolve(base: ref, in: ws, sessions: sessions, store: store, worktree: wt)
                mine.result = r
                self?.finishResolve(key)
                mine.group.leave()
            }
        }
        if box.group.wait(timeout: .now() + max(0.5, deadline.timeIntervalSinceNow)) == .timedOut {
            throw Failure(message: "still fetching the base: it goes on in Greenroom. Call changes again with the same base to join it.")
        }
        guard let resolution = box.result else { throw Failure(message: "the base could not be resolved") }
        let base: Build
        switch resolution {
        case .failed(let why): throw Failure(message: why)
        case .offer(let o): return o.message + "\nNothing was started: ask the person to build it in Greenroom, or compare with an apk path."
        case .build(let b): base = b
        }
        let headNote = "\(label(s)) \(String(head.key.prefix(8))) (\(head.source.rawValue), \(age(head.date)))"
        let baseNote = "\(String(base.key.prefix(8))) (\(base.source.rawValue), \(age(base.date)))" + (base.key == head.key ? ", the same build" : "")
        let header = "changes: \(headNote) against \(baseNote)"
        let evidence = mainSync { wb.sessions.evidence }
        let (start, baseOption) = AgentCheckHooks.changesOptions(differentBuild: base.key != head.key)
        // One build against itself: nothing to walk twice (as the Changes sheet does).
        if base.key == head.key, baseOption.isEmpty {
            let set = ChangeSet.identical(folder: evidence.changesFolder(head: head.key, base: base.key), map: ScreenMapData.read(evidence.mapFolder(for: head.key)))
            setLastChanges(set, for: s.worktree.path)
            return AgentChanges.describe(set, header: header)
        }
        // From history: both builds have a stored map, so nothing is walked. Try the session's walk profiles (signed in
        // first, matching the GUI's Changes sheet) before falling back to the unsigned comparison profile.
        if baseOption.isEmpty {
            let root = evidence.store.root
            let profiles = candidateProfiles(for: s, start: start, wb: wb)
            let found: (MapSnapshot, MapSnapshot)? = blocking {
                for profile in profiles {
                    if let h = await History.snapshot(of: head, workspace: ws.root, profile: profile, stateRoot: root),
                       let b = await History.snapshot(of: base, workspace: ws.root, profile: profile, stateRoot: root) {
                        return (h, b)
                    }
                }
                return nil
            }
            if let (h, b) = found {
                let named = (args["base"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ws.baseRef
                let note = baselineNote(named, base: b, buildSHA: base.sha, in: ws.root)
                let set = ChangeSet.fromHistory(head: h, base: b, store: History.store(stateRoot: root, workspace: ws.root),
                                                folder: evidence.changesFolder(head: head.key, base: base.key), baseline: note)
                setLastChanges(set, for: s.worktree.path)
                return AgentChanges.describe(set, header: "changes from history, no walk started: \(headNote) against \(baseNote)")
            }
        }
        var result: Result<Evidence.ChangesResult, Evidence.Failure>?
        let done = DispatchSemaphore(value: 0)
        mainSync {
            _ = evidence.changes(head: head, base: base, start: start, baseOption: baseOption) { r in result = r; done.signal() }
        }
        if done.wait(timeout: .now() + max(0.5, deadline.timeIntervalSinceNow)) == .timedOut {
            throw Failure(message: "still comparing after \(Int(timeout)) s: the walk goes on in Greenroom while another call waits for it. Call changes again with the same base to join it.")
        }
        guard let result else { throw Failure(message: "the comparison ended with no answer") }
        switch result {
        case .failure(let f): throw Failure(message: "the comparison failed: \(f.message)")
        case .success(let r):
            guard let set = ChangeSet.read(r.folder) else { throw Failure(message: "the comparison finished but its result could not be read") }
            setLastChanges(set, for: s.worktree.path)
            return AgentChanges.describe(set, header: header)
        }
    }

    // MARK: History

    /// "main at 53ffe80", and how far behind the base build's commit the stored map is when it is not that commit's own.
    func baselineNote(_ name: String, base: MapSnapshot, buildSHA: String?, in dir: URL) -> String {
        var note = "\(name) at \(base.commit.prefix(7))"
        if let sha = buildSHA, !sha.isEmpty, !sha.hasPrefix("-"), !base.commit.hasPrefix(sha) {
            let commit = base.commit
            let n: Int? = blocking { await Git.run(["rev-list", "--count", commit + ".." + sha], in: dir).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
            if let n {
                if n > 0 { note += ", \(n) commit\(n == 1 ? "" : "s") behind the build's \(sha.prefix(7))" }
            }
        }
        return note
    }

    /// `changes` with base `snapshot:REF`: the stored map of that commit against the head's (the build's commit, else the
    /// session's own when it is clean). Nothing is built or walked.
    private func changesFromSnapshots(_ ref: String, _ s: Session, _ ws: Workspace, _ wb: Workbench) throws -> String {
        guard !ref.isEmpty, !ref.hasPrefix("-") else { throw Failure(message: "base snapshot: takes a commit, branch or tag with a stored map (history lists them)") }
        let ctx = historyContext(s, ws, wb)
        guard let (commit, _) = blocking({ await History.resolve(ref, in: ws.root) }) else { throw Failure(message: "\(ref) is not a commit of this repository") }
        guard let base = ctx.store.snapshot(profile: ctx.profile.id, commit: commit) else {
            throw Failure(message: "no stored map of \(commit.prefix(7)) for this workspace and profile: history lists the commits that have one")
        }
        let build = headBuild(s)
        var head: MapSnapshot?
        if let build, History.fileable(build) { head = blocking { await History.snapshot(of: build, workspace: ws.root, profile: ctx.profile, stateRoot: ctx.root) } }
        if head == nil, !s.dirty, let (c, t) = blocking({ await History.resolve(s.head, in: ws.root) }) {
            head = ctx.store.snapshot(profile: ctx.profile.id, commit: c) ?? ctx.store.snapshot(profile: ctx.profile.id, tree: t)
        }
        guard let head else {
            throw Failure(message: "no stored map of \(label(s))'s commit \(s.shortHead)\(s.dirty ? " (it has uncommitted changes, which no map stands for)" : ""): history lists what is stored")
        }
        let folder = mainSync { wb.sessions.evidence }.changesFolder(head: "snap-" + head.commit.prefix(12), base: "snap-" + base.commit.prefix(12))
        let set = ChangeSet.fromHistory(head: head, base: base, store: ctx.store, folder: folder,
                                        baseline: base.commit.hasPrefix(ref) || ref.count < 8 ? "the stored map of \(base.commit.prefix(7))" : "the stored map of \(ref) at \(base.commit.prefix(7))")
        setLastChanges(set, for: s.worktree.path)
        return AgentChanges.describe(set, header: "changes from history, no walk started: \(label(s)) \(head.commit.prefix(7)) (stored map) against \(base.commit.prefix(7)) (stored map)")
    }

    /// Profiles to check when reading stored snapshots for a session: the session's walk profiles (signed in first) plus
    /// the plain comparison profile as fallback, deduplicated in order.
    private func candidateProfiles(for s: Session, start: String?, wb: Workbench) -> [MapProfile] {
        mainSync {
            let evidence = wb.sessions.evidence
            var out: [MapProfile] = []
            func add(_ p: MapProfile) {
                var p = p
                if let start, !start.isEmpty { p.starts = [start] }
                if !out.contains(where: { $0.id == p.id }) { out.append(p) }
            }
            for p in evidence.walkProfiles(worktree: s.worktree.path, withData: wb.sessions.walksWithData(s)) { add(p) }
            add(evidence.changesProfile(start: start, workspace: s.workspace))
            return out
        }
    }

    private func historyContext(_ s: Session, _ ws: Workspace, _ wb: Workbench) -> (store: MapStore, profile: MapProfile, root: URL) {
        let evidence = mainSync { wb.sessions.evidence }
        let root = evidence.store.root
        let store = History.store(stateRoot: root, workspace: ws.root)
        if Engine.agentCheck {
            let profile = evidence.changesProfile(start: nil, workspace: ws.root)
            AgentCheckHooks.seedHistory(store: store, profile: profile, workspace: ws.root)
            return (store, profile, root)
        }
        let candidates = candidateProfiles(for: s, start: nil, wb: wb)
        let profile = candidates.first { !store.commits(profile: $0.id).isEmpty } ?? candidates.first ?? evidence.changesProfile(start: nil, workspace: ws.root)
        return (store, profile, root)
    }

    /// The snapshots stored for the session's workspace and profile, oldest first.
    private func storedSnapshots(_ ctx: (store: MapStore, profile: MapProfile, root: URL)) -> [MapSnapshot] {
        ctx.store.commits(profile: ctx.profile.id).compactMap { ctx.store.snapshot(profile: ctx.profile.id, commit: $0) }
            .sorted { ($0.walked, $0.commit) < ($1.walked, $1.commit) }
    }

    /// `history`: with no argument the stored snapshots, newest first; with `screen` that screen's lineage over time.
    func historyTool(_ args: [String: Any], _ connection: Connection) throws -> String {
        let (s, ws) = try tied(connection)
        guard let wb = workbench else { throw Failure(message: Self.noSession) }
        let ctx = historyContext(s, ws, wb)
        let snaps = storedSnapshots(ctx)
        let name = ws.root.lastPathComponent
        guard !snaps.isEmpty else {
            return "history: no snapshots stored for \(name) (profile \(ctx.profile.id)) yet: a walk of a clean commit files one"
        }
        let query = (args["screen"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let mine = s.dirty ? nil : s.head
        func day(_ snap: MapSnapshot) -> String { String(snap.walked.prefix(16)).replacingOccurrences(of: "T", with: " ") }
        func short(_ snap: MapSnapshot) -> String { String(snap.commit.prefix(7)) + (mine.map { snap.commit.hasPrefix($0) || $0.hasPrefix(snap.commit) } == true ? " (this session)" : "") }

        if query.isEmpty {
            var lines = ["history: \(snaps.count) snapshot\(snaps.count == 1 ? "" : "s") of \(name), profile \(ctx.profile.id), newest first"]
            for (i, snap) in snaps.enumerated().reversed() {
                var line = "\(short(snap))  \(day(snap))  \(snap.screens.count) screens"
                if i > 0 {
                    let c = MapPairing.diff(head: snap, base: snaps[i - 1]).counts
                    line += c.differing == 0 ? "  no change against \(snaps[i - 1].commit.prefix(7))"
                        : "  +\(c.added) new, ~\(c.modified) changed, -\(c.removed) gone against \(snaps[i - 1].commit.prefix(7))"
                } else { line += "  the first" }
                if !snap.incomplete.isEmpty { line += "  (walk did not finish)" }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }

        // One screen: the lineage the query names (an id, a lineage or a title, newest snapshot first), then each commit that changed it.
        let q = query.lowercased()
        var lineages: [String] = []
        for snap in snaps.reversed() {
            for sc in snap.screens where sc.id == query || sc.lineage == query || sc.title.lowercased() == q || sc.id.lowercased() == q {
                if !lineages.contains(sc.lineage) { lineages.append(sc.lineage) }
            }
            if !lineages.isEmpty { break }
        }
        guard let lineage = lineages.first else { throw Failure(message: "no screen \"\(query)\" in the stored maps: give a screen's title or id") }
        var lines: [String] = []
        var titleNow = query
        var changed = 0
        for (i, snap) in snaps.enumerated() {
            guard let here = snap.screens.first(where: { $0.lineage == lineage }) else {
                if i > 0, snaps[i - 1].screens.contains(where: { $0.lineage == lineage }) { lines.append("\(short(snap))  \(day(snap))  gone"); changed += 1 }
                continue
            }
            titleNow = here.title.isEmpty ? here.activity : here.title
            if i == 0 { lines.append("\(short(snap))  \(day(snap))  first stored (\(here.id))"); changed += 1; continue }
            let prev = snaps[i - 1]
            guard prev.screens.contains(where: { $0.lineage == lineage }) else { lines.append("\(short(snap))  \(day(snap))  new (\(here.id))"); changed += 1; continue }
            let d = MapPairing.diff(head: snap, base: prev)
            if let ch = d.change(lineage), ch.status == .modified {
                var parts: [String] = []
                for r in [MapDiff.Reason.visual, .structure, .routes, .text] where ch.reasons.contains(r) {
                    switch r {
                    case .visual: parts.append("visual")
                    case .structure: parts.append("structure (now \(here.id))")
                    case .routes:
                        for st in [MapDiff.EdgeChange.Status.added, .removed, .retargeted] {
                            let n = d.edges.filter { $0.from == lineage && $0.status == st }.count
                            if n > 0 { parts.append("\(n) route\(n == 1 ? "" : "s") \(st == .retargeted ? "redirected" : st.rawValue)") }
                        }
                    case .text: let n = ch.textAdded.count + ch.textRemoved.count; parts.append("\(n) text\(n == 1 ? "" : "s") changed")
                    }
                }
                lines.append("\(short(snap))  \(day(snap))  " + parts.joined(separator: ", "))
                changed += 1
            }
        }
        let others = lineages.count > 1 ? "; \(lineages.count - 1) other screen\(lineages.count == 2 ? "" : "s") has that title: pass its id" : ""
        return (["history of \(titleNow) (\(lineage)): changed in \(changed) of \(snaps.count) snapshots\(others)"] + (lines.isEmpty ? ["never changed"] : lines)).joined(separator: "\n")
    }

    /// `screenshot` with `screen` and `commit`: the stored capture of a screen at that commit.
    func historyPicture(_ args: [String: Any], _ connection: Connection) throws -> [[String: Any]] {
        let (s, ws) = try tied(connection)
        guard let wb = workbench else { throw Failure(message: Self.noSession) }
        let ctx = historyContext(s, ws, wb)
        let commit = (args["commit"] as? String ?? "").lowercased(), query = (args["screen"] as? String) ?? ""
        guard commit.count >= 4, commit.allSatisfy({ $0.isHexDigit }) else { throw Failure(message: "commit is a commit's hash (7 digits or more) from history") }
        let matches = storedSnapshots(ctx).filter { $0.commit.hasPrefix(commit) }
        guard let snap = matches.first, matches.count == 1 else {
            throw Failure(message: matches.isEmpty ? "no stored map of \(commit): history lists the commits that have one" : "\(commit) is ambiguous: give more digits")
        }
        let q = query.lowercased()
        guard let sc = snap.screens.first(where: { $0.id == query || $0.lineage == query }) ?? snap.screens.first(where: { $0.title.lowercased() == q }),
              let combo = sc.captures.keys.sorted().first, let hash = sc.captures[combo] else {
            throw Failure(message: "\(query) has no stored capture at \(snap.commit.prefix(7)): history with screen names the commits that have it")
        }
        guard let file = ctx.store.blobURL(hash) else { throw Failure(message: "the capture is no longer in the store (it was pruned)") }
        return try Self.scaledPicture(file, maxSize: args["max_size"] as? Int ?? 1000, label: "\(sc.title.isEmpty ? sc.id : sc.title) at \(snap.commit.prefix(7)) \(combo)")
    }

    // MARK: screenshot with a screen id

    func changePicture(_ args: [String: Any], _ connection: Connection) throws -> [[String: Any]] {
        let (s, _) = try tied(connection)
        guard let set = lastChanges(for: s.worktree.path) else { throw Failure(message: "no comparison yet for \(label(s)): call changes first, then pass one of its screen ids") }
        guard let screen = args["screen"] as? String, !screen.isEmpty else { throw Failure(message: "screen is a screen id from changes") }
        let side = (args["side"] as? String) ?? "head"
        guard ["head", "base", "diff"].contains(side) else { throw Failure(message: "side is head, base or diff") }
        guard let file = AgentChanges.capture(set, screen: screen, side: side) else {
            throw Failure(message: "\(screen) has no \(side) capture in the last comparison (call changes to see the screen ids; new screens have no base, gone ones no head, same ones no diff)")
        }
        return try Self.scaledPicture(file, maxSize: args["max_size"] as? Int ?? 1000, label: "\(screen) \(side)")
    }

    static func scaledPicture(_ file: URL, maxSize: Int, label: String) throws -> [[String: Any]] {
        guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: file)) ?? Data()), let cg = rep.cgImage else {
            throw Failure(message: "that capture could not be read: the comparison's folder may have been pruned, call changes again")
        }
        let longest = max(cg.width, cg.height)
        let scale = maxSize > 0 && longest > maxSize ? CGFloat(maxSize) / CGFloat(longest) : 1
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(message: "the capture could not be drawn") }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else {
            throw Failure(message: "the capture could not be encoded")
        }
        return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                ["type": "text", "text": "\(label) \(w)x\(h) (capture \(cg.width)x\(cg.height))"]]
    }


    func finishResolve(_ key: String) { changesLock.lock(); pendingResolves[key] = nil; changesLock.unlock() }
    func setLastChanges(_ set: ChangeSet, for worktree: String) { changesLock.lock(); lastChanges[worktree] = set; changesLock.unlock() }
    func lastChanges(for worktree: String) -> ChangeSet? { changesLock.lock(); defer { changesLock.unlock() }; return lastChanges[worktree] }

    // MARK: Recording

    /// Starts the recording of this simulator if it belongs to a session whose workspace records the agent.
    func beginRecording(_ sim: Simulator) {
        guard let wb = workbench, let session = sessionOf(sim) else { return }
        let (enabled, live) = mainSync { (wb.sessions.recordsAgent(session), recording.isActive(sim)) }
        guard enabled else { return }
        var key: String?
        if !live {
            let builds = mainSync { wb.sessions.store.builds.standardizedFileURL.path + "/" }
            let apk = sim.apk.standardizedFileURL.path
            key = apk.hasPrefix(builds) ? apk.dropFirst(builds.count).split(separator: "/").first.map(String.init) : headBuild(session)?.key
        }
        mainSync { recording.begin(sim, session: session, key: key, workbench: wb, enabled: true) }
    }

    func noteRecording(_ tool: String, _ args: [String: Any], failed: Bool) {
        guard let wb = workbench, let sim = currentSim else { return }
        let session = sessionOf(sim)
        let enabled = session.map { s in mainSync { wb.sessions.recordsAgent(s) } } ?? false
        mainSync { recording.note(sim, shape: AgentRecording.shape(tool: tool, args: args), tool: tool, failed: failed, enabled: enabled) }
    }
}

// MARK: - Reading a comparison

/// What `changes` says, from the Changes sheet's own model (`ChangeSet`, Changes.swift): the same pairing, the same
/// "not reached" honesty for a walk that did not finish, the same crash and unfinished lines.
enum AgentChanges {
    static func describe(_ set: ChangeSet, header: String) -> String {
        var lines = [header]
        if let b = set.baseline, set.diff != nil { lines.append("baseline: " + b) }
        for c in set.screens {
            switch c.status {
            case .new: lines.append("+ \(c.title) (new) [\(c.id)]")
            case .gone: lines.append("- \(c.title) (gone) [\(c.id)]")
            case .changed:
                lines.append("~ \(c.title): \(set.reasons(of: c, tool: true) ?? c.detail) [\(c.id)]")
                for l in set.controlLines(of: c) where l.hasPrefix(">") { lines.append("> \(c.title): " + l.dropFirst(2)) }
            case .unreached: lines.append("? \(c.title) (not reached: \(c.detail)) [\(c.id)]")
            case .same: break
            }
        }
        let n = set.summary
        lines.append("\(n.new) new, \(n.changed) changed, \(n.gone) gone, \(n.same) the same" + (set.unreached > 0 ? ", \(set.unreached) not reached (a walk did not finish)" : ""))
        if set.identical { lines.append("head and base are the same build: nothing was walked") }
        if set.diff != nil {
            let found = set.crashStatus()
            if found.isEmpty { lines.append("crashes: none") } else {
                lines.append("crashes: \(found.count)")
                for c in found.prefix(3) { lines.append("  \(c.status): \(c.detail)") }
            }
        } else if set.crashes.isEmpty { lines.append("crashes: none") }
        else {
            lines.append("crashes: \(set.crashes.count)")
            for c in set.crashes.prefix(3) { lines.append("  \(c.side == .base ? "base" : "head"): " + (c.detail.split(separator: "\n").first.map(String.init) ?? "a crash")) }
        }
        if !set.unfinished.isEmpty { lines.append("not finished: " + set.unfinished.joined(separator: "; ")) }
        if set.screens.isEmpty, !set.identical { lines.append("(this walk compared no screens)") }
        return lines.joined(separator: "\n")
    }

    /// The stored picture of a screen (its id as `changes` printed it, or the base's own id): `head`, `base` or `diff`.
    /// Only a file that really lies inside the comparison's folder is served.
    static func capture(_ set: ChangeSet, screen: String, side: String) -> URL? {
        let c = set.screens.first { $0.id == screen } ?? set.screens.first { $0.headID == screen || $0.baseID == screen }
        guard let c else { return nil }
        let url: URL?
        switch side {
        case "head": url = c.head
        case "base": url = c.base
        default: url = c.diff
        }
        guard let url, url.isInside(set.folder) || set.storeFolder.map({ url.isInside($0) }) == true, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

// MARK: - Checks (--agent-check only)

/// What `scripts/mcp-check.py --sessions` needs inside the app, none of it reachable without `--agent-check`: a
/// stand-in recipe as the workspace's `local` one, no automatic walks, and a small, fixed walk for `changes`.
enum AgentCheckHooks {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// The pause switch, flipped from outside by a file in the state folder (the check cannot click the popover).
    static var pausedByCheck: Bool {
        Engine.agentCheck && FileManager.default.fileExists(atPath: Engine.shared.state.appendingPathComponent("agent-paused-check").path)
    }

    /// `GREENROOM_CHECK_RECIPE`: the `local` recipe is this executable.
    static func adjust(_ ws: inout Workspace) {
        if let r = env["GREENROOM_CHECK_RECIPE"], r.hasPrefix("/") { ws.recipes["local"] = Recipe(executable: r) }
    }

    /// Applied to the stored workspaces once the added repositories are in: the stand-in recipe, and `GREENROOM_CHECK_AUTO=off`.
    static func configure(_ sessions: SessionsController) {
        for i in sessions.workspaces.indices {
            adjust(&sessions.workspaces[i])
            if env["GREENROOM_CHECK_AUTO"] == "off" { sessions.workspaces[i].auto = .off }
            if let off = env["GREENROOM_CHECK_RECORD_OFF"], !off.isEmpty,
               off.split(separator: "\n").contains(where: { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path == sessions.workspaces[i].root.path }) {
                sessions.workspaces[i].recordAgent = false   // the per-workspace switch, off for this repository
            }
        }
        if let d = env["GREENROOM_CHECK_CRAWL_DEPTH"].flatMap(Int.init) { sessions.evidence.budget.depth = d }
        if let n = env["GREENROOM_CHECK_CRAWL_SECONDS"].flatMap(Int.init) { sessions.evidence.budget.seconds = n }
        sessions.store.saveWorkspaces(sessions.workspaces)
    }

    /// A comparison's walk: a deep link to start from, and (when the builds differ) launch options for the base build
    /// only (`crawl.py --base-option`), so one APK can stand for two builds that look different. Empty off the check.
    static func changesOptions(differentBuild: Bool) -> (start: String?, baseOption: String) {
        guard Engine.agentCheck else { return (nil, "") }
        let start = env["GREENROOM_CHECK_CRAWL_START"].flatMap { $0.isEmpty ? nil : $0 }
        return (start, differentBuild ? (env["GREENROOM_CHECK_BASE_OPTION"] ?? "") : "")
    }

    /// `GREENROOM_CHECK_HISTORY_SEED=PAIR:BASE_SHA:HEAD_SHA` (a name from `MapFixtures.golden()` and two commits of the repository):
    /// the pair's two maps are stored as those commits' snapshots under the app's profile, with small pictures for their
    /// captures, so `changes` and `history` can be checked with no walk. Once; a store that has them is left alone.
    static func seedHistory(store: MapStore, profile: MapProfile, workspace: URL) {
        guard Engine.agentCheck, let spec = env["GREENROOM_CHECK_HISTORY_SEED"] else { return }
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 3, let pair = MapFixtures.golden().first(where: { $0.name == parts[0] }) else { return }
        for (snap, sha, when) in [(pair.base, parts[1], "2026-11-01T10:00:00Z"), (pair.head, parts[2], "2026-11-02T10:00:00Z")] {
            if store.snapshot(profile: profile.id, commit: sha) != nil { continue }
            var s = snap
            s.commit = sha
            s.tree = "tree-" + sha
            s.profile = profile
            s.walked = when
            for sc in s.screens {
                for hash in sc.captures.values where store.blobURL(hash) == nil {
                    let dir = store.folder.appendingPathComponent("blobs", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let bytes = Array(hash.utf8)
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    let c = NSColor(deviceRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
                    for x in 0..<64 { for y in 0..<64 { rep.setColor(c, atX: x, y: y) } }
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(hash + ".png"))
                }
            }
            _ = store.save(s)
        }
    }
}
