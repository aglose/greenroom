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
        let timeout = clamp(args["timeout_s"], 10, 7200, 1500)
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
                throw Failure(message: "still building after \(Int(timeout)) s: the \(j.recipeName) build goes on in Greenroom. Call build again to wait for it.")
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
            return .apk(URL(fileURLWithPath: (a as NSString).expandingTildeInPath))
        }
        return .ref(a)
    }

    func changesTool(_ args: [String: Any], _ connection: Connection) throws -> String {
        let (s, ws) = try tied(connection)
        guard let wb = workbench else { throw Failure(message: Self.noSession) }
        guard let head = headBuild(s) else { throw Failure(message: "no build yet for \(label(s)): call build") }
        let timeout = clamp(args["timeout_s"], 10, 7200, 600)
        let (sessions, store) = mainSync { (wb.sessions.sessions, wb.sessions.store) }
        let ref = try baseRef(args["base"] as? String, s, sessions)
        let wt = s.worktree
        let resolution = blocking { await Bases.resolve(base: ref, in: ws, sessions: sessions, store: store, worktree: wt) }
        let base: Build
        switch resolution {
        case .failed(let why): throw Failure(message: why)
        case .offer(let o): return o.message + "\nNothing was started: ask the person to build it in Greenroom, or compare with an apk path."
        case .build(let b): base = b
        }
        var result: Result<Evidence.ChangesResult, Evidence.Failure>?
        let done = DispatchSemaphore(value: 0)
        var token: Evidence.Token?
        mainSync {
            token = wb.sessions.evidence.changes(head: head, base: base) { r in result = r; done.signal() }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            mainSync { token?.cancel() }
            throw Failure(message: "the comparison did not finish within \(Int(timeout)) s and was stopped (a walk takes a minute or two for a large app). Call changes again with a longer timeout_s.")
        }
        guard let result else { throw Failure(message: "the comparison ended with no answer") }
        switch result {
        case .failure(let f): throw Failure(message: "the comparison failed: \(f.message)")
        case .success(let r):
            lastChanges[s.worktree.path] = r.folder
            let headNote = "\(label(s)) \(String(head.key.prefix(8))) (\(head.source.rawValue), \(age(head.date)))"
            let baseNote = "\(String(base.key.prefix(8))) (\(base.source.rawValue), \(age(base.date)))" + (base.key == head.key ? ", the same build" : "")
            return AgentChanges.describe(folder: r.folder, header: "changes: \(headNote) against \(baseNote)")
        }
    }

    // MARK: screenshot with a screen id

    func changePicture(_ args: [String: Any], _ connection: Connection) throws -> [[String: Any]] {
        let (s, _) = try tied(connection)
        guard let folder = lastChanges[s.worktree.path] else { throw Failure(message: "no comparison yet for \(label(s)): call changes first, then pass one of its screen ids") }
        guard let screen = args["screen"] as? String, !screen.isEmpty else { throw Failure(message: "screen is a screen id from changes") }
        let side = (args["side"] as? String) ?? "head"
        guard ["head", "base", "diff"].contains(side) else { throw Failure(message: "side is head, base or diff") }
        guard let file = AgentChanges.capture(folder: folder, screen: screen, side: side) else {
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

    func noteRecording(_ tool: String, _ summary: String, failed: Bool) {
        guard let sim = currentSim else { return }
        mainSync { recording.note(sim, tool: tool, summary: summary, failed: failed) }
    }
}

// MARK: - Reading a comparison

/// What `changes` says, read from the comparison folder's `crawl.json` (a small reader of its own: the Changes sheet
/// has another).
enum AgentChanges {
    private static func load(_ folder: URL) -> [String: Any]? {
        (try? Data(contentsOf: folder.appendingPathComponent("crawl.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// A screen as a breadcrumb of its titles from the first screen it was reached from: "Settings > Privacy".
    private static func label(_ id: String, in screens: [[String: Any]]) -> String {
        var byId: [String: [String: Any]] = [:]
        for s in screens { if let i = s["id"] as? String { byId[i] = s } }
        var chain: [String] = []
        var at: String? = id
        var guardCount = 0
        while let cur = at, let s = byId[cur], guardCount < 8 {
            let title = (s["title"] as? String) ?? ""
            let activity = ((s["activity"] as? String) ?? cur).split(separator: ".").last.map(String.init) ?? cur
            chain.insert(title.isEmpty ? activity : title, at: 0)
            at = s["parent"] as? String
            guardCount += 1
        }
        if chain.count > 1 { chain.removeFirst() }   // the first screen is where every walk starts
        return chain.isEmpty ? id : chain.joined(separator: " > ")
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func describe(folder: URL, header: String) -> String {
        guard let doc = load(folder) else { return header + "\nthe comparison's crawl.json could not be read" }
        let heads = (doc["screens"] as? [[String: Any]]) ?? []
        let bases = (doc["base_screens"] as? [[String: Any]]) ?? []
        let pairs = (doc["compare"] as? [[String: Any]]) ?? []
        let diffs = (doc["diffs"] as? [String: [String: [String: Any]]]) ?? [:]
        var lines = [header]
        var counts = ["new": 0, "changed": 0, "gone": 0, "same": 0]
        for p in pairs {
            let status = (p["status"] as? String) ?? ""
            counts[status, default: 0] += 1
            let id = p["id"] as? String, base = p["base"] as? String
            switch status {
            case "new": if let id { lines.append("+ \(label(id, in: heads)) (new) [\(id)]") }
            case "gone": if let base { lines.append("- \(label(base, in: bases)) (gone) [\(base)]") }
            case "changed":
                guard let id else { continue }
                var px = 0, sizeChanged = false
                for (_, d) in diffs[id] ?? [:] { px = max(px, (d["pixels"] as? Int) ?? 0); if d["sizeChanged"] as? Bool == true { sizeChanged = true } }
                let why: String
                if sizeChanged { why = "its size differs" }
                else if px > 0 { why = "\(grouped(px)) px differ" }
                else { why = ((p["why"] as? String) ?? "differs").replacingOccurrences(of: "\n", with: " ") }
                lines.append("~ \(label(id, in: heads)): \(why) [\(id)]")
            default: break
            }
        }
        lines.append("\(counts["new"]!) new, \(counts["changed"]!) changed, \(counts["gone"]!) gone, \(counts["same"]!) the same")
        let findings = (doc["findings"] as? [[String: Any]]) ?? []
        let crashes = findings.filter { ($0["kind"] as? String) == "crash" }
        if crashes.isEmpty { lines.append("crashes: none") }
        else {
            lines.append("crashes: \(crashes.count)")
            for c in crashes.prefix(3) { lines.append("  " + (((c["detail"] as? String) ?? "").split(separator: "\n").first.map(String.init) ?? "a crash")) }
        }
        let unfinished = ((doc["incomplete"] as? [String]) ?? []).filter { !$0.hasPrefix("--max-depth") }
        if !unfinished.isEmpty { lines.append("not finished: " + unfinished.joined(separator: "; ")) }
        if pairs.isEmpty { lines.append("(this walk compared no screens)") }
        return lines.joined(separator: "\n")
    }

    /// The stored picture of a screen: `head` (the new build's), `base`, or `diff` (the map of differing pixels).
    static func capture(folder: URL, screen: String, side: String) -> URL? {
        guard let doc = load(folder) else { return nil }
        let pairs = (doc["compare"] as? [[String: Any]]) ?? []
        let p = pairs.first { ($0["id"] as? String) == screen } ?? pairs.first { ($0["base"] as? String) == screen }
        guard let p else { return nil }
        let id = p["id"] as? String, base = p["base"] as? String
        let combos = (doc["combos"] as? [String]) ?? []
        func first(_ screens: [[String: Any]], _ want: String?) -> URL? {
            guard let want, let s = screens.first(where: { ($0["id"] as? String) == want }), let caps = s["captures"] as? [String: String] else { return nil }
            for c in combos + caps.keys.sorted() { if let rel = caps[c] { let u = folder.appendingPathComponent(rel); if FileManager.default.fileExists(atPath: u.path) { return u } } }
            return nil
        }
        switch side {
        case "head": return first((doc["screens"] as? [[String: Any]]) ?? [], id)
        case "base": return first((doc["base_screens"] as? [[String: Any]]) ?? [], base)
        default:
            guard let id, let d = (doc["diffs"] as? [String: [String: [String: Any]]])?[id] else { return nil }
            for c in combos + d.keys.sorted() { if let rel = d[c]?["map"] as? String { let u = folder.appendingPathComponent(rel); if FileManager.default.fileExists(atPath: u.path) { return u } } }
            return nil
        }
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
        sessions.store.saveWorkspaces(sessions.workspaces)
    }

    /// A comparison's walk: a deep link to start from, a small budget, and (when the builds differ) launch options
    /// for the base build only (`crawl.py --base-option`), so one APK can stand for two builds that look different.
    static func tune(_ s: inout CrawlRun.Settings, differentBuild: Bool) {
        if let u = env["GREENROOM_CHECK_CRAWL_START"], !u.isEmpty { s.start = u }
        if let d = env["GREENROOM_CHECK_CRAWL_DEPTH"].flatMap(Int.init) { s.depth = d }
        if let n = env["GREENROOM_CHECK_CRAWL_SECONDS"].flatMap(Int.init) { s.seconds = n }
        if differentBuild, let o = env["GREENROOM_CHECK_BASE_OPTION"], !o.isEmpty { s.baseOption = o }
    }
}
