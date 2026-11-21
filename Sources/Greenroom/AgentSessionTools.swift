import AppKit

// The agent's tools for a session (docs/SESSIONS-PLAN.md, "5. The Claude Code link", "What the agent gets"):
// `session`, `build`, `changes` and `screenshot`'s `screen`, and the recording of an agent's session. All of them work
// only for a connection tied to a session (the shim's folder is a worktree of an added repository), and say so
// plainly when it is not. They use what the app already has: the build queue (`Builds.start`, so the remote
// recipe's consent holds), `Bases.resolve` and `Evidence.changes`. Nothing here starts a build of a base: an
// unbuilt base is answered as text. Called off the main thread.

extension AgentTools {
    static let noSession = "this folder is not a worktree of a repository added to Greenroom: run the agent from a worktree of one"

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
    private func tied(_ connection: Connection) throws -> (session: Session, workspace: Workspace) {
        guard let wb = workbench, let old = connection.session else { throw Failure(message: Self.noSession) }
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

    private func age(_ date: Date) -> String {
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
        let sim = mainSync { wb.sessions.simulator(for: s) }
        lines.append(sim.map { "simulator: \(id($0)) running" } ?? "simulator: none (launch starts it)")
        if let c = s.claude, let title = c.title { lines.append("claude session: \(ScreenNode.quote(title)) (\(c.status.rawValue))") }
        let taking = mainSync { recording.recording(for: s.worktree.path) }
        if let r = taking, r.live { lines.append("recording: your session is being recorded for the person (\(r.file.lastPathComponent))") }
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
        if name == "remote", ws.refusal(forRecipe: "remote") != nil {
            throw Failure(message: "The remote recipe uploads this repository's source code to the person's own boat.dev account, and they have not allowed it. Ask them to allow it in Greenroom (the row's Build with > remote); an agent cannot give that yes. Meanwhile use the local recipe.")
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
        if let b = pendingResolves[key] { box = b } else { box = ResolveBox(); pendingResolves[key] = box; begun = true }
        changesLock.unlock()
        if begun {
            let mine: ResolveBox = box
            mine.group.enter()
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
        let maxSize = args["max_size"] as? Int ?? 1000
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
                ["type": "text", "text": "\(screen) \(side) \(w)x\(h) (capture \(cg.width)x\(cg.height))"]]
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
        for c in set.screens {
            switch c.status {
            case .new: lines.append("+ \(c.title) (new) [\(c.id)]")
            case .gone: lines.append("- \(c.title) (gone) [\(c.id)]")
            case .changed: lines.append("~ \(c.title): \(c.detail) [\(c.id)]")
            case .unreached: lines.append("? \(c.title) (not reached: \(c.detail)) [\(c.id)]")
            case .same: break
            }
        }
        let n = set.summary
        lines.append("\(n.new) new, \(n.changed) changed, \(n.gone) gone, \(n.same) the same" + (set.unreached > 0 ? ", \(set.unreached) not reached (a walk did not finish)" : ""))
        if set.identical { lines.append("head and base are the same build: nothing was walked") }
        if set.crashes.isEmpty { lines.append("crashes: none") }
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
        guard let url, url.isInside(set.folder), FileManager.default.fileExists(atPath: url.path) else { return nil }
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
}
