import Foundation

/// The agent's view of Greenroom itself: its settings, the repositories and their settings, every session, the job
/// queue, pull requests, the matrix wall and the agent activity log. What only the owner may decide (telemetry,
/// pausing agents, an agent's own recording, uploading code or screens, programs to run) is answered but never set.
extension AgentTools {
    static let appTools: [Tool] = [
        ("app", "Greenroom itself: its version, the engine's, where it keeps its state, and every app setting with its value. With "
            + "setting and value it changes one: " + appSettingKeys + ". Some are the owner's alone and are answered but not set.",
         schema(["setting": str, "value": str], sim: false)),
        ("workspace", "A repository added to Greenroom and its settings (default: this worktree's; repo names another by folder name "
            + "or path). With setting and value it changes one: base_ref, module, variant, default_recipe, auto (off|on_build|on_turn_end: "
            + "walk each build), walk_with_data, quick_walk, keep_main, unsigned_baseline, skip_local_apk_scan, disable_local_builds, "
            + "ci_workflow, ci_artifact, ci_apk. Skin and launch options: launch_settings. Sharing maps through git, remote builds, "
            + "custom recipes, the PR fetch script and recording agents are the owner's to change.",
         schema(["repo": str, "setting": str, "value": str], sim: false)),
        ("sessions", "Every repository added to Greenroom with its sessions (worktrees): branch, title, build (age, source, stale), "
            + "simulator, pull request, the walk of its newest build; then the repository's main build and the pull requests "
            + "Greenroom holds. repo keeps one repository.", schema(["repo": str], sim: false)),
        ("session_action", "Act on a session by its branch, title or worktree path (default: this worktree's): open (start or select its "
            + "simulator), close (stop it), build (queue its default recipe or recipe, without waiting: build in a worktree waits), "
            + "cancel_build, walk (walk its newest build again for the screen map), stop_walk, show (show it in the sidebar), hide. "
            + "Or add_repository with path: add a git repository to Greenroom.",
         schema(["action": ["type": "string", "enum": ["open", "close", "build", "cancel_build", "walk", "stop_walk", "show", "hide", "add_repository"]],
                 "session": ["type": "string", "description": "a branch, a title or a worktree path"],
                 "recipe": str, "path": ["type": "string", "description": "add_repository: the repository's folder"]], required: ["action"], sim: false)),
        ("jobs", "Greenroom's job queue: builds, walks, comparisons and fetches, running then waiting then the recent ones. action "
            + "cancel, pause, resume or prioritize acts on one (job: the id at the start of its line); pause_all and resume_all on all.",
         schema(["action": ["type": "string", "enum": ["list", "cancel", "pause", "resume", "prioritize", "pause_all", "resume_all"]],
                 "job": ["type": "string", "description": "a job's id, from the list"]], sim: false)),
        ("pull_requests", "The pull requests Greenroom holds (their CI builds run on data of their own). action list (default), add "
            + "(number or address, to repo or this worktree's repository: fetches its build), fetch (again), open (its simulator), "
            + "close (its simulator), remove (from Greenroom).",
         schema(["action": ["type": "string", "enum": ["list", "add", "fetch", "open", "close", "remove"]],
                 "pr": ["type": "string", "description": "a number (or for add an address)"], "repo": str], sim: false)),
        ("matrix", "The matrix wall: one APK on every combination of devices, appearances, locales and text sizes at once, side by side "
            + "with input mirrored to all (at most 16). action run (default) or close. Answers the simulators' ids; drive one with sim, "
            + "or compare two.",
         schema(["action": ["type": "string", "enum": ["run", "close"]],
                 "apk": ["type": "string", "description": "default: this worktree's newest build, else the only running simulator's APK"],
                 "devices": ["type": "array", "items": ["type": "string", "enum": devices]],
                 "appearances": ["type": "array", "items": ["type": "string", "enum": ["light", "dark"]]],
                 "locales": strings, "font_scales": ["type": "array", "items": ["type": "number"]]], sim: false)),
        ("agent_activity", "What agents did in Greenroom, as the Agent popover shows it: the newest calls (time, tool, what came of it, "
            + "the session), the client, whether the owner paused agents, and whether each repository records them.",
         schema(["limit": ["type": "integer", "description": "newest N calls (default 30, at most 200)"], "all": ["type": "boolean", "description": "every session's calls, not only this worktree's"]], sim: false)),
    ]

    /// Whether a call of `name` with `args` only reads: it is then answered while the owner has paused agents.
    static func readsOnly(_ name: String, _ args: [String: Any]) -> Bool {
        if readOnly.contains(name) { return true }
        let action = args["action"] as? String
        switch name {
        case "app", "workspace", "launch_settings": return args["setting"] == nil && args["value"] == nil && args["skin"] == nil && args["options"] == nil
        case "jobs", "pull_requests", "network_rule": return action == nil || action == "list"
        case "recorder", "devtools": return action == nil || action == "status" || action == "list" || action == "har_list"
        case "snapshots": return action == nil || action == "status"
        case "tests": return args["test_apk"] == nil && args["stop"] == nil
        case "clipboard": return args["text"] == nil
        case "background": return args["run_job"] == nil
        default: return false
        }
    }

    func appCall(_ name: String, _ args: [String: Any], _ connection: Connection) throws -> [[String: Any]]? {
        switch name {
        case "app": return text(try appTool(args))
        case "workspace": return text(try workspaceTool(args, connection))
        case "sessions": return text(try sessionsTool(args))
        case "session_action": return text(try sessionAction(args, connection))
        case "jobs": return text(try jobsTool(args))
        case "pull_requests": return text(try pullRequestsTool(args, connection))
        case "matrix": return text(try matrixTool(args, connection))
        case "agent_activity": return text(try agentActivityTool(args, connection))
        default: return nil
        }
    }

    // MARK: app

    private struct AppSetting {
        let key: String
        let about: String
        let get: () -> String
        /// nil: the owner's alone.
        let set: ((String) throws -> Void)?
    }

    private static func flag(_ v: String) throws -> Bool {
        switch v.lowercased() {
        case "on", "true", "yes", "1": return true
        case "off", "false", "no", "0": return false
        default: throw Failure(message: "the value is on or off")
        }
    }

    private static func number(_ v: String, _ range: ClosedRange<Double>) throws -> Double {
        guard let n = Double(v), range.contains(n) else { throw Failure(message: "the value is a number from \(range.lowerBound.clean) to \(range.upperBound.clean)") }
        return n
    }

    private static let appSettingKeys = "sessions_warm, auto_archive, jobs_at_once, evidence_cap_gb, build_timeout_minutes, reopen_last, app_icon, update_checks"

    /// Main thread.
    private func appSettings() -> [AppSetting] {
        let d = UserDefaults.standard
        let sessions = workbench?.sessions
        return [
            AppSetting(key: "sessions_warm", about: "session simulators kept running at once (1-6)",
                       get: { String(sessions?.warmLimit ?? 3) },
                       set: { sessions?.warmLimit = Int(try Self.number($0, 1...6)) }),
            AppSetting(key: "auto_archive", about: "archive a session once its pull request is merged",
                       get: { (sessions?.autoArchiveEnabled ?? true) ? "on" : "off" },
                       set: { sessions?.autoArchiveEnabled = try Self.flag($0) }),
            AppSetting(key: "jobs_at_once", about: "jobs (builds, walks, comparisons) run at once, 0 for no limit",
                       get: { String(JobQueue.shared.limit) },
                       set: { JobQueue.shared.limit = Int(try Self.number($0, 0...16)) }),
            AppSetting(key: "evidence_cap_gb", about: "the size walks' maps and comparisons may take on disk, in GB",
                       get: { (d.object(forKey: "evidenceCapGB") as? Double ?? 5).clean },
                       set: { d.set(try Self.number($0, 0.5...500), forKey: "evidenceCapGB") }),
            AppSetting(key: "build_timeout_minutes", about: "how long a recipe may run before it is stopped",
                       get: { (d.object(forKey: "buildTimeoutMinutes") as? Double ?? 30).clean },
                       set: { d.set(try Self.number($0, 1...240), forKey: "buildTimeoutMinutes") }),
            AppSetting(key: "reopen_last", about: "reopen the last session or APK when Greenroom starts",
                       get: { LastOpened.enabled ? "on" : "off" },
                       set: { LastOpened.enabled = try Self.flag($0) }),
            AppSetting(key: "app_icon", about: "the Dock icon: " + AppIconStyle.allCases.map(\.rawValue).joined(separator: ", "),
                       get: { AppIcon.current.rawValue },
                       set: { v in
                           guard let style = AppIconStyle(rawValue: v) else { throw Failure(message: "app_icon is one of " + AppIconStyle.allCases.map(\.rawValue).joined(separator: ", ")) }
                           d.set(style.rawValue, forKey: AppIcon.defaultsKey)
                           AppIcon.apply(style)
                       }),
            AppSetting(key: "update_checks", about: "check for Greenroom updates automatically",
                       get: { Updates.shared.available ? (Updates.shared.checksAutomatically ? "on" : "off") : "not in this build" },
                       set: { v in
                           guard Updates.shared.available else { throw Failure(message: "this build of Greenroom does not update itself") }
                           Updates.shared.checksAutomatically = try Self.flag(v)
                       }),
            AppSetting(key: "crash_reports", about: "send crash reports (the owner's choice)", get: { Reports.shared.crashes ? "on" : "off" }, set: nil),
            AppSetting(key: "usage_reports", about: "send usage counts (the owner's choice)", get: { Reports.shared.usage ? "on" : "off" }, set: nil),
            AppSetting(key: "claude_sessions", about: "read Claude Code's session titles (the owner's choice)", get: { ClaudeSessions.shared.enabled ? "on" : "off" }, set: nil),
            AppSetting(key: "t3_sessions", about: "read T3 Code's sessions (the owner's choice)", get: { T3Sessions.shared.enabled ? "on" : "off" }, set: nil),
            AppSetting(key: "agents_paused", about: "agents' actions are refused (the owner's switch in the Agent popover)", get: { self.paused || AgentCheckHooks.pausedByCheck ? "on" : "off" }, set: nil),
        ]
    }

    private func appTool(_ args: [String: Any]) throws -> String {
        guard workbench != nil else { throw Failure(message: "Greenroom is not ready") }
        if let key = args["setting"] as? String {
            guard let value = (args["value"] as? String)?.trimmingCharacters(in: .whitespaces) else { throw Failure(message: "setting needs value") }
            try mainSync {
                guard let s = appSettings().first(where: { $0.key == key }) else {
                    throw Failure(message: "no setting \(key): the settings are \(appSettings().map(\.key).joined(separator: ", "))")
                }
                guard let set = s.set else { throw Failure(message: "\(key) is the owner's to change, in Greenroom") }
                try set(value)
            }
            return "\(key): " + mainSync { appSettings().first { $0.key == key }?.get() ?? value }
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development build"
        let build = info["CFBundleVersion"] as? String
        var lines = ["\(Variant.name) \(version)" + (build.map { " (\($0))" } ?? ""),
                     "engine: apksim \(Engine.shared.version)",
                     "state: \(Self.tilde(Engine.shared.state.path))"]
        let (sims, repos) = mainSync { (Engine.shared.simulators.filter(\.isAlive).count, workbench?.sessions.workspaces.count ?? 0) }
        lines.append("\(sims) simulator\(sims == 1 ? "" : "s") running, \(repos) repositor\(repos == 1 ? "y" : "ies") added")
        lines.append("stage: " + mainSync { workbench?.stageSummary ?? "unknown" })
        lines.append("settings:")
        lines += mainSync { appSettings().map { "  \($0.key) = \($0.get())  (\($0.about)\($0.set == nil ? "; read only" : ""))" } }
        return lines.joined(separator: "\n")
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: workspace

    /// The repository `repo` names (its folder name or path), else the connection's, else the only one.
    func workspaceNamed(_ repo: String?, _ connection: Connection) throws -> Workspace {
        guard let wb = workbench else { throw Failure(message: "Greenroom is not ready") }
        let all = mainSync { wb.sessions.workspaces }
        if let r = repo?.trimmingCharacters(in: .whitespaces), !r.isEmpty {
            let path = (r as NSString).expandingTildeInPath
            if let ws = all.first(where: { $0.root.path == path || $0.root.lastPathComponent == r }) { return ws }
            throw Failure(message: "no repository \(r) in Greenroom: " + (all.isEmpty ? "none is added" : "the repositories are " + all.map { $0.root.lastPathComponent }.joined(separator: ", ")))
        }
        if let s = connection.session, let ws = all.first(where: { $0.root.path == s.workspace.path }) { return ws }
        if all.count == 1 { return all[0] }
        throw Failure(message: all.isEmpty ? "no repository is added to Greenroom (session_action add_repository adds one)"
                                           : "say which repository with repo: " + all.map { $0.root.lastPathComponent }.joined(separator: ", "))
    }

    private func workspaceTool(_ args: [String: Any], _ connection: Connection) throws -> String {
        guard let wb = workbench else { throw Failure(message: "Greenroom is not ready") }
        var ws = try workspaceNamed(args["repo"] as? String, connection)
        if let key = args["setting"] as? String {
            guard let value = (args["value"] as? String)?.trimmingCharacters(in: .whitespaces) else { throw Failure(message: "setting needs value") }
            let root = ws.root
            /// Changes the stored workspace and saves it, as Settings does.
            func update(_ change: @escaping (inout Workspace) -> Void) {
                mainSync {
                    guard let i = wb.sessions.workspaces.firstIndex(where: { $0.root.path == root.path }) else { return }
                    change(&wb.sessions.workspaces[i])
                    wb.sessions.store.saveWorkspaces(wb.sessions.workspaces)
                    wb.sessions.onChange?()
                }
            }
            func safeText(_ v: String, _ what: String) throws -> String {
                guard v.count <= 200, !v.contains(where: { $0.isNewline || $0 == "\0" }) else { throw Failure(message: "\(what) is one line of at most 200 characters") }
                return v
            }
            switch key {
            case "base_ref":
                guard value.range(of: "^[A-Za-z0-9._/-]{1,200}$", options: .regularExpression) != nil, !value.contains("..") else { throw Failure(message: "base_ref is a branch, tag or commit (origin/main)") }
                update { $0.baseRef = value }
            case "module":
                guard value.isEmpty || value.range(of: "^[A-Za-z0-9_:.-]{1,120}$", options: .regularExpression) != nil else { throw Failure(message: "module is a Gradle module (app, :feature:app), or \"\" for the one Greenroom finds") }
                mainSync { wb.sessions.setAppModule(value.isEmpty ? nil : value, for: root) }
            case "variant":
                guard value.range(of: "^[A-Za-z0-9_]{1,60}$", options: .regularExpression) != nil else { throw Failure(message: "variant is a build variant (debug)") }
                update { $0.variant = value }
            case "default_recipe":
                guard ws.recipeNames.contains(value) else { throw Failure(message: "default_recipe is one of \(ws.recipeNames.joined(separator: ", "))") }
                if let why = ws.refusal(forRecipe: value) { throw Failure(message: why) }
                ws.defaultRecipeName = value
            case "auto":
                let map: [String: Auto] = ["off": .off, "on_build": .onBuild, "on_turn_end": .onTurnEnd]
                guard let a = map[value] else { throw Failure(message: "auto is off, on_build or on_turn_end") }
                update { $0.auto = a }
            case "walk_with_data": let on = try Self.flag(value); update { $0.walkWithData = on }
            case "quick_walk": let on = try Self.flag(value); update { $0.quickWalk = on }
            case "keep_main": let on = try Self.flag(value); mainSync { wb.sessions.setKeepMain(on, for: root) }
            case "unsigned_baseline": let on = try Self.flag(value); mainSync { wb.sessions.setUnsignedBaseline(on, for: root) }
            case "skip_local_apk_scan": let on = try Self.flag(value); mainSync { wb.sessions.setSkipLocalAPKScan(on, for: root) }
            case "disable_local_builds": let on = try Self.flag(value); mainSync { wb.sessions.setDisableLocalBuilds(on, for: root) }
            case "ci_workflow": let v = try safeText(value, key); update { $0.ci.workflow = v }
            case "ci_artifact": let v = try safeText(value, key); update { $0.ci.artifact = v }
            case "ci_apk": let v = try safeText(value, key); update { $0.ci.apk = v }
            case "skin", "launch_options", "options":
                throw Failure(message: "launch_settings changes the skin and launch options")
            case "share_maps", "share_signed_in_maps", "remote_consent", "recipes", "pr_fetch_script", "record_agent":
                throw Failure(message: "\(key) is the owner's to change, in Greenroom > Settings > Recipes (it uploads to a remote, runs a program, or watches you)")
            default:
                throw Failure(message: "no setting \(key): call workspace for the list")
            }
            ws = try workspaceNamed(root.path, connection)
            return "\(ws.root.lastPathComponent): \(key) changed\n" + describe(ws)
        }
        return describe(ws)
    }

    private func describe(_ ws: Workspace) -> String {
        let onOff = { (b: Bool) in b ? "on" : "off" }
        let auto: String = { switch ws.auto { case .off: return "off"; case .onBuild: return "on_build"; case .onTurnEnd: return "on_turn_end" } }()
        let custom = ws.recipes.keys.sorted()
        return [
            "\(ws.root.lastPathComponent) (\(Self.tilde(ws.root.path)))",
            "base_ref = \(ws.baseRef)",
            "module = \(ws.module ?? "(found by Greenroom)")",
            "variant = \(ws.variant)",
            "default_recipe = \(ws.defaultRecipeName) (recipes: \(ws.recipeNames.joined(separator: ", ")))",
            "auto = \(auto) (walk each new build for the screen map)",
            "walk_with_data = \(onOff(ws.walkWithData)), quick_walk = \(onOff(ws.quickWalk)), keep_main = \(onOff(ws.keepMain)), unsigned_baseline = \(onOff(ws.unsignedBaseline))",
            "skip_local_apk_scan = \(onOff(ws.skipLocalAPKScan)), disable_local_builds = \(onOff(ws.disableLocalBuilds))",
            "ci_workflow = \(ws.ci.workflow.isEmpty ? "none" : ws.ci.workflow), ci_artifact = \(ws.ci.artifact.isEmpty ? "any" : ws.ci.artifact), ci_apk = \(ws.ci.apk.isEmpty ? "*.apk" : ws.ci.apk)",
            "skin = \(ws.skin.isEmpty ? "none" : ws.skin), launch options = \(ws.launchOptions.isEmpty ? "none" : ws.launchOptions) (launch_settings)",
            "owner's: share_maps = \(onOff(ws.shareMaps)), share_signed_in_maps = \(onOff(ws.shareSignedInMaps)), remote builds = \(ws.remote.consent == true ? "allowed" : "not allowed"), "
                + "record_agent = \(onOff(ws.recordAgent)), pr_fetch_script = \(ws.prFetchScript.isEmpty ? "none" : "set"), custom recipes = \(custom.isEmpty ? "none" : custom.joined(separator: ", "))",
        ].joined(separator: "\n")
    }

    // MARK: sessions

    private func buildText(_ b: Build?, stale: Bool) -> String {
        guard let b else { return "no build" }
        return "build \(b.key) \(b.source.rawValue) \(age(b.date))" + (stale ? " (stale)" : "")
    }

    private func walkText(_ e: Evidence.Entry?) -> String? {
        guard let e else { return nil }
        switch e.status {
        case .queued: return "walk queued"
        case .walking(let depth, let known): return "walking (depth \(depth), \(known) screens)" + (e.paused ? ", paused" : "")
        case .done(let screens, let crashes, let unfinished):
            return "walked: \(screens) screens" + (crashes > 0 ? ", \(crashes) crash\(crashes == 1 ? "" : "es")" : "") + (unfinished ? ", unfinished" : "")
                + (e.changedWords.map { ", \($0)" } ?? "")
        case .failed(let why): return "walk failed: \(why.split(separator: "\n").last ?? "")"
        case .stopped: return "walk stopped"
        case .needsSignIn: return "not walked: it needs a sign-in"
        }
    }

    private func sessionsTool(_ args: [String: Any]) throws -> String {
        guard let wb = workbench else { throw Failure(message: "Greenroom is not ready") }
        let only = args["repo"] as? String
        let filter = try only.map { try workspaceNamed($0, Connection()).root.path }
        return mainSync {
            let c = wb.sessions
            var lines: [String] = []
            for ws in c.workspaces where filter == nil || ws.root.path == filter {
                lines.append("\(ws.root.lastPathComponent) (\(Self.tilde(ws.root.path)))")
                for s in c.sessions where s.workspace.path == ws.root.path {
                    let b = c.builds[s.worktree.path] ?? s.build
                    var parts = ["  \(s.branch ?? "detached \(s.shortHead)")"]
                    if s.title != (s.branch ?? "") { parts.append(ScreenNode.quote(s.title)) }
                    parts.append("\(s.shortHead)\(s.dirty ? " +changes" : "")")
                    parts.append(buildText(b, stale: s.isStale))
                    if let sim = c.simulator(for: s) { parts.append("simulator \(id(sim))") }
                    if let n = s.prNumber { parts.append("PR #\(n)\(s.prState.map { " \($0)" } ?? "")") }
                    if let w = walkText(c.evidence.entry(of: s.worktree.path)) { parts.append(w) }
                    if !c.isShown(s) { parts.append("hidden") }
                    lines.append(parts.joined(separator: " | ") + (s.worktree.path == ws.root.path ? "" : " | \(Self.tilde(s.worktree.path))"))
                }
                if let m = c.mainRow(for: ws.root) {
                    var line = "  main build (\(m.name)): " + buildText(m.newest, stale: m.current == nil && m.newest != nil)
                    switch m.state { case .checking(let what): line += " | \(what)"; case .failed(let why): line += " | failed: \(why)"; case .idle: break }
                    if let sim = m.simulator { line += " | simulator \(id(sim))" }
                    lines.append(line)
                }
            }
            let pulls = c.pullRows().filter { filter == nil || $0.pull.workspace == filter }
            if !pulls.isEmpty {
                lines.append("pull requests:")
                for r in pulls { lines.append("  " + pullLine(r)) }
            }
            return lines.isEmpty ? "no repository is added to Greenroom (session_action add_repository adds one)" : lines.joined(separator: "\n")
        }
    }

    private func pullLine(_ r: PullRow) -> String {
        var line = "#\(r.pull.number) \(r.repo) \(ScreenNode.quote(r.pull.title)) | \(buildText(r.build, stale: false))"
        switch r.state {
        case .idle: break
        case .fetching(let what): line += " | fetching: \(what)"
        case .failed(let why): line += " | failed: \(why)"
        case .offer(let what): line += " | \(what)"
        }
        if let sim = r.simulator { line += " | simulator \(id(sim))" }
        return line
    }

    /// The session `name` names (a branch, a title, a worktree path), else the connection's.
    private func sessionNamed(_ name: String?, _ connection: Connection) throws -> Session {
        guard let wb = workbench else { throw Failure(message: "Greenroom is not ready") }
        if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty {
            let path = (n as NSString).expandingTildeInPath
            let all = mainSync { wb.sessions.sessions }
            let hits = all.filter { $0.worktree.path == path || $0.branch == n } + all.filter { $0.title == n }
            guard let s = hits.first else { throw Failure(message: "no session \(n): call sessions") }
            if Set(hits.map(\.worktree.path)).count > 1, !all.contains(where: { $0.worktree.path == path }) {
                throw Failure(message: "several sessions are \(n): give the worktree path (\(hits.map { Self.tilde($0.worktree.path) }.joined(separator: ", ")))")
            }
            return s
        }
        guard let s = connection.session, let now = mainSync({ wb.sessions.session(atWorktree: s.worktree) }) else {
            throw Failure(message: "say which session with session (a branch or worktree path): call sessions")
        }
        return now
    }

    private func sessionAction(_ args: [String: Any], _ connection: Connection) throws -> String {
        guard let wb = workbench else { throw Failure(message: "Greenroom is not ready") }
        let action = args["action"] as? String ?? ""
        if action == "add_repository" {
            guard let p = args["path"] as? String, !p.isEmpty else { throw Failure(message: "add_repository needs path: the repository's folder") }
            let folder = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &dir), dir.boolValue else { throw Failure(message: "\(p) is not a folder") }
            // What the person took out of Sessions is theirs to put back.
            if let known = blocking({ await Git.mainCheckout(of: folder) })?.resolvingSymlinksInPath(), AgentAdoption.isRemoved(known),
               mainSync({ wb.sessions.workspace(at: known) }) == nil {
                throw Failure(message: "\(known.lastPathComponent) was removed from Greenroom by the person at the Mac: only they can add it back, with File > Add Repository…")
            }
            let task = mainSync { wb.sessions.addRepository(folder, quietIfExisting: true, byAgent: true) }
            guard let root = blocking({ await task.value }) else { throw Failure(message: "\(p) is not a git repository Greenroom can add") }
            return "added \(root.lastPathComponent) (\(Self.tilde(root.path))): its worktrees are sessions; sessions lists them"
        }
        let s = try sessionNamed(args["session"] as? String, connection)
        let name = s.branch ?? s.shortHead
        switch action {
        case "open":
            let ok = mainSync { wb.sessions.activate(s) }
            guard ok else { throw Failure(message: "\(name) has no build to open: session_action build makes one") }
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if let sim = mainSync({ wb.sessions.simulator(for: s) }), mainSync({ sim.state }) == .running { return "\(id(sim)) runs \(name)" }
                Thread.sleep(forTimeInterval: 0.3)
            }
            return "\(name) is starting: call simulators"
        case "close":
            guard mainSync({ wb.sessions.simulator(for: s) }) != nil else { return "\(name) has no simulator running" }
            mainSync { wb.sessions.closeSimulator(of: s) }
            return "\(name)'s simulator closed (its data is kept)"
        case "build":
            let ws = try workspaceNamed(s.workspace.path, connection)
            let recipe = (args["recipe"] as? String) ?? ws.defaultRecipeName
            guard ws.recipeNames.contains(recipe) else { throw Failure(message: "recipe is one of \(ws.recipeNames.joined(separator: ", "))") }
            if let why = ws.refusal(forRecipe: recipe) { throw Failure(message: why) }
            if recipe == "remote", ws.remote.consent != true { throw Failure(message: "the remote recipe uploads source code: only the person at the Mac can allow it, in Greenroom") }
            var problem: String?
            mainSync { _ = wb.sessions.buildQueue.start(s, workspace: ws, recipeName: recipe, store: wb.sessions.store) { problem = $0 } }
            if let problem { throw Failure(message: problem) }
            return "\(name): \(recipe) build queued (jobs shows it; sessions shows the build when it lands)"
        case "cancel_build":
            guard mainSync({ wb.sessions.buildQueue.isBuilding(s.worktree.path) }) else { return "\(name) is not building" }
            mainSync { wb.sessions.cancelBuild(s) }
            return "\(name): build cancelled"
        case "walk":
            guard mainSync({ wb.sessions.hasBuild(s) }) else { throw Failure(message: "\(name) has no build to walk") }
            mainSync { wb.sessions.walkAgain(s) }
            return "\(name): walk queued (sessions shows its progress, changes and history read its map)"
        case "stop_walk":
            mainSync { wb.sessions.stopWalking(s) }
            return "\(name): walk stopped"
        case "show":
            mainSync { wb.sessions.show(s) }
            return "\(name) is shown in the sidebar"
        case "hide":
            mainSync { wb.sessions.remove(s) }
            return "\(name) is hidden from the sidebar (its simulator closed; its worktree and data are untouched)"
        default:
            throw Failure(message: "action is open, close, build, cancel_build, walk, stop_walk, show, hide or add_repository")
        }
    }

    // MARK: jobs

    private static func jobID(_ j: QueueJob) -> String { String(j.id.uuidString.prefix(8)).lowercased() }

    private func jobsTool(_ args: [String: Any]) throws -> String {
        let q = JobQueue.shared
        let action = args["action"] as? String ?? "list"
        if action == "pause_all" { mainSync { q.pauseAll() } }
        else if action == "resume_all" { mainSync { q.resumeAll() } }
        else if action != "list" {
            guard let want = (args["job"] as? String)?.lowercased(), !want.isEmpty else { throw Failure(message: "\(action) needs job: an id from the list") }
            let message: String? = try mainSync {
                guard let j = q.jobs.first(where: { Self.jobID($0).hasPrefix(want) }) else { throw Failure(message: "no job \(want): call jobs") }
                switch action {
                case "cancel": q.cancel(j); return nil
                case "pause": return q.pause(j)
                case "resume": q.resume(j); return nil
                case "prioritize": q.prioritize(j); return nil
                default: throw Failure(message: "action is list, cancel, pause, resume, prioritize, pause_all or resume_all")
                }
            }
            if let message { throw Failure(message: message) }
        }
        return mainSync {
            let active = q.active, recent = q.recent.prefix(10)
            var lines: [String] = [active.isEmpty ? "no jobs running or waiting" + (q.limit > 0 ? " (at most \(q.limit) at once)" : "") : "\(q.running.count) running, \(q.waiting.count) waiting" + (q.limit > 0 ? " (at most \(q.limit) at once)" : "")]
            func line(_ j: QueueJob) -> String {
                let state: String = {
                    switch j.state {
                    case .queued: return j.held ? "held" : "queued"
                    case .running: return "running"
                    case .paused: return "paused"
                    case .done: return "done"
                    case .failed: return "failed"
                    case .cancelled: return "cancelled"
                    }
                }()
                let pct = j.fraction.map { " \(Int($0 * 100))%" } ?? ""
                let took = j.elapsed.map { " \(Int($0)) s" } ?? ""
                return "\(Self.jobID(j)) \(j.kind) \(state)\(pct)\(took) | \(j.title) | \(j.statusLine)"
            }
            lines += active.map(line)
            if !recent.isEmpty { lines.append("recent:"); lines += recent.map { "  " + line($0) } }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: pull requests

    private func pullRequestsTool(_ args: [String: Any], _ connection: Connection) throws -> String {
        guard let wb = workbench else { throw Failure(message: "Greenroom is not ready") }
        let action = args["action"] as? String ?? "list"
        func list() -> String {
            mainSync {
                let rows = wb.sessions.pullRows()
                return rows.isEmpty ? "no pull requests in Greenroom (pull_requests add brings one)" : rows.map(pullLine).joined(separator: "\n")
            }
        }
        if action == "list" { return list() }
        guard let pr = (args["pr"] as? String)?.trimmingCharacters(in: .whitespaces), !pr.isEmpty else { throw Failure(message: "\(action) needs pr: a number" + (action == "add" ? " or address" : "")) }
        if action == "add" {
            let ws = try workspaceNamed(args["repo"] as? String, connection)
            let (added, words) = blocking { @MainActor in await wb.sessions.pulls.add(pr, to: ws) }
            guard let added else { throw Failure(message: words) }
            return "added #\(added.number) \(ScreenNode.quote(added.title)): \(words)\n" + list()
        }
        let number = Int(pr.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        let repoPath = try (args["repo"] as? String).map { try workspaceNamed($0, connection).root.path }
        let rows = mainSync { wb.sessions.pullRows() }.filter { $0.pull.number == number && (repoPath == nil || $0.pull.workspace == repoPath) }
        guard let row = rows.first else { throw Failure(message: "no pull request #\(pr) in Greenroom: call pull_requests") }
        guard rows.count == 1 else { throw Failure(message: "#\(pr) is in several repositories: say which with repo") }
        switch action {
        case "fetch": mainSync { wb.sessions.pulls.fetch(row.pull) }; return "#\(row.pull.number): fetching its build again"
        case "open": mainSync { wb.sessions.openPull(row) }; return "#\(row.pull.number): opening (simulators shows it)"
        case "close": mainSync { wb.sessions.closePullSimulator(row) }; return "#\(row.pull.number): its simulator closed"
        case "remove": mainSync { wb.sessions.removePull(row) }; return "#\(row.pull.number) removed from Greenroom"
        default: throw Failure(message: "action is list, add, fetch, open, close or remove")
        }
    }

    // MARK: matrix

    private func matrixTool(_ args: [String: Any], _ connection: Connection) throws -> String {
        guard let wb = workbench else { throw Failure(message: "Greenroom is not ready") }
        if args["action"] as? String == "close" {
            let n = mainSync { wb.matrixSims.count }
            mainSync { wb.closeMatrix(nil) }
            return n == 0 ? "no matrix is open" : "the matrix's \(n) simulators closed"
        }
        let apk: URL
        if let p = args["apk"] as? String { apk = try apkFile(p) }
        else if let s = connection.session, let b = mainSync({ wb.sessions.builds[s.worktree.path] ?? wb.sessions.session(atWorktree: s.worktree)?.build }) { apk = b.apk }
        else if let s = try? sim([:]) { apk = s.apk }
        else { throw Failure(message: "matrix needs apk: no build of this worktree and no single running simulator to take it from") }
        var m = Matrix()
        if let d = args["devices"] as? [String], !d.isEmpty {
            guard d.allSatisfy(AgentTools.devices.contains) else { throw Failure(message: "devices are \(AgentTools.devices.joined(separator: ", "))") }
            m.devices = d
        }
        if let a = args["appearances"] as? [String], !a.isEmpty {
            guard a.allSatisfy(["light", "dark"].contains) else { throw Failure(message: "appearances are light and dark") }
            m.appearances = a
        }
        if let l = args["locales"] as? [String], !l.isEmpty {
            guard l.allSatisfy({ $0.range(of: AgentTools.settings["locale"]!, options: .regularExpression) != nil }) else { throw Failure(message: "locales are such as en-US, de-DE, ar-EG") }
            m.locales = l
        }
        if let f = args["font_scales"] as? [Double], !f.isEmpty {
            guard f.allSatisfy({ (0.5...3).contains($0) }) else { throw Failure(message: "font_scales are from 0.5 to 3") }
            m.fontScales = f.map { $0 == 1 ? "1.0" : String($0) }
        }
        let cells = m.cells.count
        guard cells <= Matrix.maxCells else { throw Failure(message: "\(cells) combinations: at most \(Matrix.maxCells) run at once") }
        let sims: [Simulator] = mainSync {
            var out: [Simulator] = []
            wb.runMatrix(m, apk: apk) { out = $0 }
            return out
        }
        guard !sims.isEmpty else { throw Failure(message: "the matrix did not start") }
        let deadline = Date().addingTimeInterval(90)
        while mainSync({ sims.contains { $0.state == .starting } }), Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        let lines = sims.map { s in "\(id(s)) \(mainSync { s.cellLabel ?? "" }) \(mainSync { s.state == .running } ? "running" : "not running")" }
        return (["\(apk.lastPathComponent) on \(sims.count) simulators, input mirrored to all (matrix close ends it)"] + lines).joined(separator: "\n")
    }

    // MARK: agent activity

    private func agentActivityTool(_ args: [String: Any], _ connection: Connection) throws -> String {
        guard let wb = workbench else { throw Failure(message: "Greenroom is not ready") }
        let limit = min(max(args["limit"] as? Int ?? 30, 1), 200)
        let all = args["all"] as? Bool == true || connection.session == nil
        return mainSync {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            var lines = ["client: \(wb.agentActivity.client ?? "unknown"), agents \(paused || AgentCheckHooks.pausedByCheck ? "PAUSED by the owner" : "allowed")"]
            for ws in wb.sessions.workspaces { lines.append("\(ws.root.lastPathComponent): agents' sessions \(ws.recordAgent ? "recorded" : "not recorded")") }
            let entries = wb.agentActivity.entries(session: connection.session?.worktree.path, all: all).suffix(limit)
            if entries.isEmpty { lines.append("no calls yet") }
            for e in entries {
                lines.append("\(f.string(from: e.time)) \(e.tool)\(e.failed ? " FAILED" : "") | \(e.summary.split(separator: "\n").first ?? "")" + (all ? (e.label.map { " | \($0)" } ?? "") : ""))
            }
            // What harnesses' hooks said (`greenroom hook`): this worktree's, or everyone's.
            let mine = connection.session?.worktree.resolvingSymlinksInPath().path
            let hooks = HookLog.shared.events.filter { e in
                guard !all, let mine else { return true }
                let at = e.cwd.resolvingSymlinksInPath().path
                return at == mine || at.hasPrefix(mine + "/")
            }.suffix(limit)
            for e in hooks { lines.append("\(f.string(from: e.time)) hook \(e.harness) \(e.event) | \(e.cwd.lastPathComponent)") }
            return lines.joined(separator: "\n")
        }
    }
}

private extension Double {
    var clean: String { self == rounded() ? String(Int(self)) : String(self) }
}
