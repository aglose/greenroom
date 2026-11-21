import AppKit

/// `Greenroom --builds-check DIR APK`: a temporary git repository with two worktrees and stand-in recipes written
/// here (one that prints lines and copies APK, one that fails with an error line, one that exits 0 without
/// writing the file, one that sleeps and starts a child so a cancel can be seen to end the whole group) plus a
/// stand-in `gradlew` for `local.sh` itself. Verifies the environment contract, the log arriving line by line, a
/// build becoming a `Build` and the session's simulator reloading with its data, a failure and the no-file case
/// leaving the old build running with their reason, cancel ending the process group, and two builds of one
/// workspace running one after the other. One `[greenroom] builds: ok|FAIL ...` line per step, then
/// `builds check: PASS|FAIL`; exits 0 or 1. The store is DIR's own; no Gradle, JDK or network is used.
enum BuildsCheck {
    static func run(workbench wb: Workbench, dir: URL, apk: URL) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            let sessions = wb.sessions

            func say(_ s: String) { fputs("[greenroom] builds: \(s)\n", stdout); fflush(stdout) }
            func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; say((ok ? "ok " : "FAIL ") + what) }
            @MainActor func wait(_ what: String, _ seconds: Double = 120, _ cond: @MainActor () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
                say("timed out waiting for \(what)")
                return false
            }
            func ready(_ s: Simulator?) -> Bool { s?.state == .running && (s?.framesShown ?? 0) > 0 }
            @MainActor func finish() -> Never {
                say(failures == 0 ? "done" : "stopped with \(failures) failure(s)")
                print("builds check: " + (failures == 0 ? "PASS" : "FAIL"))
                fflush(stdout)
                Engine.shared.stopAll()
                exit(failures == 0 ? 0 : 1)
            }
            func git(_ args: [String], in folder: URL) -> Bool {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-c", "user.name=Check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false"] + args
                p.currentDirectoryURL = folder
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return false }
                p.waitUntilExit()
                return p.terminationStatus == 0
            }
            func alive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

            // The repository, two worktrees, and the stand-in recipes.
            let base = dir.resolvingSymlinksInPath()
            try? fm.removeItem(at: base)
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            let repo = base.appendingPathComponent("repo", isDirectory: true)
            try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
            try? "build/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try? "hello\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            guard git(["init", "-q", "-b", "main"], in: repo), git(["add", "."], in: repo), git(["commit", "-q", "-m", "first"], in: repo) else {
                say("FAIL could not make the repository (is /usr/bin/git there?)"); failures += 1; finish()
            }
            func worktree(_ n: String) -> URL { base.appendingPathComponent("wt-" + n, isDirectory: true) }
            func apkPath(_ n: String) -> URL { worktree(n).appendingPathComponent("app/build/outputs/apk/debug/app-debug.apk") }
            for n in ["a", "b"] {
                guard git(["worktree", "add", "-q", "-b", "feat-" + n, worktree(n).path], in: repo) else { say("FAIL worktree \(n)"); failures += 1; finish() }
            }
            try? fm.createDirectory(at: apkPath("a").deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: apk, to: apkPath("a"))
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: apkPath("a").path)

            let bin = base.appendingPathComponent("recipes", isDirectory: true)
            try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let order = base.appendingPathComponent("order.txt")
            let childPid = base.appendingPathComponent("child.pid")
            setenv("CHECK_APK", apk.path, 1)
            setenv("CHECK_ORDER", order.path, 1)
            setenv("CHECK_CHILD", childPid.path, 1)
            func recipe(_ name: String, _ body: String) -> Recipe {
                let f = bin.appendingPathComponent(name + ".sh")
                try? ("#!/bin/bash\n" + body + "\n").write(to: f, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
                return Recipe(executable: f.path)
            }
            let recipes: [String: Recipe] = [
                // Prints the contract, then lines half a second apart (one on stderr), then the APK.
                "ok": recipe("ok", """
                for v in GREENROOM_WORKTREE GREENROOM_REPO GREENROOM_REF GREENROOM_SHA GREENROOM_DIRTY GREENROOM_MODULE GREENROOM_VARIANT GREENROOM_OUT PATH JAVA_HOME ANDROID_HOME; do echo "ENV $v=${!v-}"; done
                echo "pwd $(pwd -P)"
                echo "line one"; sleep 0.5; echo "line two" >&2; sleep 0.5; printf 'line three without a newline'
                cp "$CHECK_APK" "$GREENROOM_OUT"
                """),
                "fail": recipe("fail", "echo compiling; echo 'e: Foo.kt:3 error: boom, unresolved reference' >&2; echo 'BUILD FAILED' >&2; exit 1"),
                "nofile": recipe("nofile", "echo 'all done, nothing written'; exit 0"),
                // A child in the group and a TERM-proof sleep: only a kill of the group ends both.
                "sleep": recipe("sleep", "(trap '' TERM; sleep 300) & echo $! > \"$CHECK_CHILD\"; echo started; trap '' TERM; while :; do sleep 1; done"),
                // Two of these must not overlap: a start and an end line each into one file.
                "order": recipe("order", "n=$(basename \"$GREENROOM_WORKTREE\"); echo \"start $n\" >> \"$CHECK_ORDER\"; sleep 1.5; cp \"$CHECK_APK\" \"$GREENROOM_OUT\"; echo \"end $n\" >> \"$CHECK_ORDER\""),
            ]

            let store = SessionStore(root: base.appendingPathComponent("state", isDirectory: true))
            sessions.use(store: store)
            let added = await sessions.addRepository(worktree("a")).value
            guard added == repo.resolvingSymlinksInPath(), let wsIndex = sessions.workspaces.firstIndex(where: { $0.root == added }) else { say("FAIL repository not added"); failures += 1; finish() }
            sessions.workspaces[wsIndex].recipes = recipes
            store.saveWorkspaces(sessions.workspaces)
            func row(_ n: String) -> Session? { sessions.sessions.first { $0.worktree.lastPathComponent == "wt-" + n } }
            _ = await wait("the rows", 30) { row("a") != nil && row("b") != nil && row("a")?.outputs != nil }
            guard let a0 = row("a"), let b0 = row("b") else { say("FAIL rows missing"); failures += 1; finish() }
            let ws = sessions.workspaces[wsIndex]
            let apkKey = SessionStore.key(of: apk) ?? "?"
            let q = sessions.buildQueue

            /// Starts a build and waits for it to end; gives the job.
            @MainActor func build(_ s: Session, _ name: String, _ seconds: Double = 60) async -> BuildJob? {
                guard let job = q.start(s, workspace: ws, recipeName: name, store: store, error: { say("start refused: \($0)") }) else { return nil }
                _ = await wait("build \(name)", seconds) { !job.isActive }
                return job
            }

            // 0. The login shell's environment is resolved (off the main thread).
            let shellEnv: [String: String] = await Task.detached { LoginEnvironment.resolve().env }.value
            let shellPath: String = shellEnv["PATH"] ?? ""
            let hasJava = shellEnv["JAVA_HOME"] != nil, hasSdk = shellEnv["ANDROID_HOME"] != nil
            expect(shellPath.contains("/usr/bin"), "the login shell's environment resolves (PATH has \(shellPath.split(separator: ":").count) entries, JAVA_HOME \(hasJava ? "set" : "unset"), ANDROID_HOME \(hasSdk ? "set" : "unset"))")
            // The shell is the account's (not $SHELL), asked as `-l -i -c /usr/bin/env`, with a deadline: a stand-in
            // shell that ignores SIGTERM and leaves a child holding the pipe must not hold a build.
            func shellScript(_ name: String, _ body: String) -> String {
                let f = bin.appendingPathComponent(name)
                try? ("#!/bin/bash\n" + body + "\n").write(to: f, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
                return f.path
            }
            let shellChild = base.appendingPathComponent("shell-child.pid")
            LoginEnvironment.shellOverride = shellScript("stuck-shell", "trap '' TERM; (trap '' TERM; sleep 300) & echo $! > \"\(shellChild.path)\"; echo 'banner without an equals sign'; sleep 300")
            LoginEnvironment.deadline = 2
            LoginEnvironment.reset()
            let askStart = Date()
            let stuck: (env: [String: String], note: String?) = await Task.detached { LoginEnvironment.resolve() }.value
            let asked = Date().timeIntervalSince(askStart)
            let shellKid = pid_t((try? String(contentsOf: shellChild, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            _ = await wait("the stuck shell's child to end", 10) { !alive(shellKid) }
            expect(asked < 6 && (stuck.note ?? "").contains("did not finish") && !alive(shellKid) && shellKid > 0,
                   "a login shell that ignores SIGTERM and leaves a child on the pipe is killed with its group at the deadline (\(String(format: "%.1f", asked)) s, child gone \(!alive(shellKid))): \(stuck.note ?? "no note")")
            LoginEnvironment.shellOverride = shellScript("fish-like-shell", "echo 'Welcome'; echo 'PATH=/shell/bin:/usr/bin'; echo 'JAVA_HOME=/shell/jdk'; echo 'SECRET_TOKEN=do-not-log'")
            LoginEnvironment.reset()
            let fine = LoginEnvironment.resolve()
            expect(fine.note == nil && fine.env["PATH"]?.hasPrefix("/shell/bin:") == true && fine.env["SECRET_TOKEN"] == ProcessInfo.processInfo.environment["SECRET_TOKEN"],
                   "the shell's env output is parsed whatever the shell prints around it (only PATH, JAVA_HOME and the SDK variables are read)")
            LoginEnvironment.shellOverride = shellScript("empty-shell", "echo 'PATH='")
            LoginEnvironment.reset()
            let emptyRun = RecipeRun(recipe: recipes["ok"]!, job: RecipeJob(worktree: worktree("b"), repo: repo, ref: "", sha: "", dirty: false, module: "", variant: "debug", out: base.appendingPathComponent("empty-out/app.apk")))
            let emptyOutcome: RecipeOutcome = await withCheckedContinuation { c in emptyRun.start { c.resume(returning: $0) } }
            let noted = emptyRun.lines.first { $0.hasPrefix("note:") } ?? ""
            expect(emptyOutcome == .built && noted.contains("gave no PATH") && !emptyRun.lines.contains { $0.contains("do-not-log") || $0.contains("/shell/") },
                   "an empty capture is said in the build log, without values (\(noted))")
            LoginEnvironment.shellOverride = nil
            LoginEnvironment.deadline = 8
            LoginEnvironment.reset()

            // Line splitting: \n, \r\n and a lone \r end a line, a runaway line is cut.
            var splitter = LineSplitter(cap: 10)
            var got = splitter.feed(Data("a\rb\r\nc\n12345678901234".utf8))
            if let rest = splitter.finish() { got.append(rest) }
            expect(got == ["a", "b", "c", "1234567890 […line cut]", "1234"], "progress lines split on \\r, and a line with no end is capped: \(got)")

            LoginEnvironment.override = ["PATH": "/check/bin:/usr/bin:/bin", "JAVA_HOME": "/check/jdk", "ANDROID_HOME": "/check/sdk"]

            // 1. A simulator on a's worktree build, with data to keep.
            expect(sessions.activate(a0), "a's simulator started from its worktree's APK")
            guard await wait("a's first frame", 180, { ready(sessions.simulator(for: a0)) }), let simA = sessions.simulator(for: a0) else { failures += 1; finish() }
            let data = Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true)
            func slotFolders(_ slot: String) -> [URL] {
                ((try? fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []).flatMap { pkg in
                    ((try? fm.contentsOfDirectory(at: pkg, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(a0.slot + "-") && !$0.lastPathComponent.hasSuffix(".device") }
                }
            }
            _ = await wait("a's data folder", 60) { !slotFolders(a0.slot).isEmpty }
            let marker = "greenroom-builds-check"
            for f in slotFolders(a0.slot) { try? "kept".write(to: f.appendingPathComponent(marker), atomically: true, encoding: .utf8) }
            func hasMarker() -> Bool { slotFolders(a0.slot).contains { fm.fileExists(atPath: $0.appendingPathComponent(marker).path) } }
            expect(hasMarker(), "a marker is in a's data")

            // 2. A build with a dirty tree: the contract, the log line by line, a Build, the simulator reloaded.
            try? "edited\n".write(to: worktree("a").appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            sessions.refresh()
            _ = await wait("a to show as edited", 20) { row("a")?.dirty == true }
            guard let a1 = row("a") else { failures += 1; finish() }
            var arrivals: [(String, Date)] = []
            q.onLine = { _, line in arrivals.append((line, Date())) }
            let began = Date()
            guard let job1 = q.start(a1, workspace: ws, recipeName: "ok", store: store, error: { say("start refused: \($0)") }) else { failures += 1; finish() }
            expect(q.isBuilding(a1.worktree.path) && sessions.buildAccessories(for: a1).views.count >= 2, "the row shows the build running (spinner and Cancel)")
            _ = await wait("the first build", 60) { !job1.isActive }
            let env = Dictionary(uniqueKeysWithValues: job1.lines.filter { $0.hasPrefix("ENV ") }.compactMap { l -> (String, String)? in
                let kv = l.dropFirst(4).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return kv.count == 2 ? (String(kv[0]), String(kv[1])) : nil
            })
            func real(_ p: String?) -> String? { p.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
            let sameWorktree: Bool = real(env["GREENROOM_WORKTREE"]) == real(a1.worktree.path)
            let sameRepo: Bool = real(env["GREENROOM_REPO"]) == real(repo.path)
            let gitFields: Bool = env["GREENROOM_REF"] == "feat-a" && env["GREENROOM_SHA"] == a1.head && env["GREENROOM_DIRTY"] == "1"
            let settings: Bool = env["GREENROOM_MODULE"] == "" && env["GREENROOM_VARIANT"] == "debug"
            let outPath: String = env["GREENROOM_OUT"] ?? ""
            let outOK: Bool = outPath.hasSuffix("/app.apk") && outPath.hasPrefix(base.path)
            let contract = "ref \(env["GREENROOM_REF"] ?? "?"), sha \(env["GREENROOM_SHA"] ?? "?"), dirty \(env["GREENROOM_DIRTY"] ?? "?"), module '\(env["GREENROOM_MODULE"] ?? "?")', variant \(env["GREENROOM_VARIANT"] ?? "?")"
            expect(sameWorktree && sameRepo && gitFields && settings && outOK, "the environment contract reached the recipe (\(contract))")
            let ownPath = (env["PATH"] ?? "")
            let procEnv = ProcessInfo.processInfo.environment
            let javaOK: Bool = env["JAVA_HOME"] == (procEnv["JAVA_HOME"] ?? "/check/jdk")
            let sdkOK: Bool = env["ANDROID_HOME"] == (procEnv["ANDROID_HOME"] ?? "/check/sdk")
            expect(ownPath.hasPrefix("/check/bin:") && javaOK && sdkOK,
                   "the login shell's PATH comes first, JAVA_HOME and ANDROID_HOME reach the recipe (JAVA_HOME \(env["JAVA_HOME"] ?? "?"))")
            expect(real(job1.lines.first { $0.hasPrefix("pwd ") }.map { String($0.dropFirst(4)) }) == real(a1.worktree.path), "the recipe runs in the worktree")
            func at(_ text: String) -> Date? { arrivals.first { $0.0 == text }?.1 }
            if let t1 = at("line one"), let t2 = at("line two"), let t3 = at("line three without a newline") {
                expect(t2.timeIntervalSince(t1) > 0.3 && t3.timeIntervalSince(t2) > 0.3 && t3.timeIntervalSince(began) < 30,
                       "the log arrived line by line (stdout, stderr and a last line with no newline), \(String(format: "%.1f", t2.timeIntervalSince(t1))) s and \(String(format: "%.1f", t3.timeIntervalSince(t2))) s apart")
            } else {
                expect(false, "the log arrived line by line (saw \(arrivals.map(\.0).suffix(4)))")
            }
            var built: Build?
            if case .built(let b) = job1.state { built = b }
            let buildOK: Bool = built?.key == apkKey && built?.source == .local && built?.sha == a1.head && built?.ref == "feat-a"
            let buildFile: Bool = fm.fileExists(atPath: built?.apk.path ?? "")
            expect(buildOK && buildFile, "the build is a Build in the store (key \(built?.key ?? "none"), source local, sha \(String(a1.head.prefix(7))))")
            let log = built.map { store.folder(of: $0.key).appendingPathComponent("build.log") }
            expect((log.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "").contains("line two"), "builds/<key>/build.log holds the log")
            guard await wait("a's reload", 120, { let n = sessions.simulator(for: a0); return n != nil && n !== simA && ready(n) }), let simA2 = sessions.simulator(for: a0) else {
                expect(false, "a's simulator reloaded on the new build"); finish()
            }
            let runsBuild: Bool = simA2.apk.resolvingSymlinksInPath().path == built?.apk.resolvingSymlinksInPath().path
            expect(runsBuild && simA2.options == simA.options && !simA.isAlive,
                   "a's simulator reloaded on the filed build, same options, the old one ended")
            expect(hasMarker(), "a's data survived the reload")
            expect(row("a")?.build?.key == apkKey, "the session's newest build is the new one")

            // 3. A failure keeps the old build running and shows why; so does a recipe that writes nothing.
            let before = row("a")?.build
            let jobF = await build(a1, "fail")
            let why = jobF?.failure ?? ""
            expect(why.contains("boom") && !why.contains("compiling"), "a failing recipe: the reason is the log's last error lines (\(why.replacingOccurrences(of: "\n", with: " | ")))")
            expect(sessions.simulator(for: a0) === simA2 && simA2.isAlive && row("a")?.build == before, "the old build stays and its simulator is left running")
            let detail = sessions.buildAccessories(for: a1).detail ?? ""
            expect(detail.hasPrefix("build failed") && (detail.contains("BUILD FAILED") || detail.contains("boom")), "the row shows the failure (\(detail))")
            let jobN = await build(a1, "nofile")
            expect((jobN?.failure ?? "").contains("no APK") && sessions.simulator(for: a0) === simA2 && row("a")?.build == before,
                   "exit 0 without a file is a failure with that reason, and the old build stays (\(jobN?.failure ?? "none"))")

            // 4. local.sh itself, against a stand-in gradlew shaped like Gradle's outputs.
            let w = worktree("a")
            try? fm.createDirectory(at: w.appendingPathComponent("app"), withIntermediateDirectories: true)
            try? fm.createDirectory(at: w.appendingPathComponent("lib"), withIntermediateDirectories: true)
            try? "plugins { id 'com.android.application' }\n".write(to: w.appendingPathComponent("app/build.gradle"), atomically: true, encoding: .utf8)
            try? "plugins { id 'com.android.library' }\n".write(to: w.appendingPathComponent("lib/build.gradle"), atomically: true, encoding: .utf8)
            let gradlew = """
            #!/bin/bash
            echo "stand-in gradle: $@"
            m="${1%%:*}"; rest="${1#:}"; m="${rest%%:*}"; task="${rest#*:}"
            [ "$task" = "assembleDebug" ] || { echo "error: unexpected task $task" >&2; exit 1; }
            o="$m/build/outputs/apk"
            mkdir -p "$o/debug" "$o/release"
            cp "$CHECK_APK" "$o/debug/$m-debug.apk"
            cp "$CHECK_APK" "$o/debug/$m-debug-androidTest.apk"; printf 'x' >> "$o/debug/$m-debug-androidTest.apk"
            sleep 1.1
            cp "$CHECK_APK" "$o/release/$m-release.apk"; printf 'release' >> "$o/release/$m-release.apk"
            """
            try? gradlew.write(to: w.appendingPathComponent("gradlew"), atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: w.appendingPathComponent("gradlew").path)
            sessions.refresh()
            _ = await wait("a to show", 20) { row("a") != nil }
            let jobL = await build(row("a") ?? a1, "local")
            var localBuild: Build?
            if case .built(let b)? = jobL?.state { localBuild = b }
            let notable: [String] = (jobL?.lines ?? []).filter { $0.contains("application module") || $0.hasPrefix("+") || $0.hasPrefix("built") }
            expect(localBuild?.key == apkKey, "local.sh found the application module, ran ./gradlew :app:assembleDebug and took the debug APK, not the newer release or the test one (\(notable.joined(separator: " | ")); \(jobL?.failure ?? "ok"))")
            expect(sessions.simulator(for: a0) === simA2, "the same build twice reloads nothing")
            // The recipe's choices, against scratch projects with a stand-in gradlew that writes what AGP writes.
            @MainActor func localRun(_ folder: URL, variant: String = "debug", module: String = "") async -> (RecipeOutcome, [String], String?) {
                let out = base.appendingPathComponent("scratch-out/app.apk")
                let job = RecipeJob(worktree: folder, repo: folder, ref: "", sha: "", dirty: false, module: module, variant: variant, out: out)
                let run = RecipeRun(recipe: Recipe.builtIn("local")!, job: job)
                let outcome: RecipeOutcome = await withCheckedContinuation { c in run.start { c.resume(returning: $0) } }
                return (outcome, run.lines, try? String(contentsOf: out, encoding: .utf8))
            }
            func reasonOf(_ o: RecipeOutcome) -> String { if case .failed(let r) = o { return r }; return o == .built ? "built" : "cancelled" }
            func project(_ name: String, buildFile: String, file: String = "app/build.gradle.kts", gradlew: String? = nil) -> URL {
                let d = base.appendingPathComponent(name, isDirectory: true)
                try? fm.createDirectory(at: d.appendingPathComponent((file as NSString).deletingLastPathComponent), withIntermediateDirectories: true)
                try? buildFile.write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8)
                if let gradlew {
                    try? ("#!/bin/bash\necho \"stand-in gradle: $@\"\n" + gradlew + "\n").write(to: d.appendingPathComponent("gradlew"), atomically: true, encoding: .utf8)
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.appendingPathComponent("gradlew").path)
                }
                return d
            }
            // What AGP leaves next to a variant's APKs: output-metadata.json with the variant's name and files.
            let writeVariant = """
            # usage: variant_dir NAME FOLDER ELEMENTS...   (an element is "outputfile:TYPE:ABI")
            variant() { name="$1"; dir="app/build/outputs/apk/$2"; shift 2; mkdir -p "$dir"; els=""
              for e in "$@"; do f="${e%%:*}"; r="${e#*:}"; t="${r%%:*}"; abi="${r#*:}"
                echo "content of $f" > "$dir/$f"
                flt='[]'; [ -n "$abi" ] && flt="[{\\"filterType\\":\\"ABI\\",\\"value\\":\\"$abi\\"}]"
                els="$els{\\"type\\":\\"ONE_OF_MANY\\",\\"outputType\\":{\\"type\\":\\"$t\\"},\\"filters\\":$flt,\\"outputFile\\":\\"$f\\"},"
              done
              printf '{"version":3,"artifactType":{"type":"APK","kind":"Directory"},"applicationId":"x","variantName":"%s","elements":[%s]}' "$name" "${els%,}" > "$dir/output-metadata.json"; }
            """
            let none = project("none", buildFile: "plugins { }\n", file: "lib/build.gradle")
            let r1 = await localRun(none)
            expect(reasonOf(r1.0).contains("no Android application module") && reasonOf(r1.0).contains("(module)"), "local.sh says plainly when there is no application module, and names the setting (\(reasonOf(r1.0)))")
            let two = project("two", buildFile: "plugins { id 'com.android.application' }\n", file: "one/build.gradle")
            try? fm.createDirectory(at: two.appendingPathComponent("two"), withIntermediateDirectories: true)
            try? "plugins { alias(libs.plugins.androidApplication) }\n".write(to: two.appendingPathComponent("two/build.gradle.kts"), atomically: true, encoding: .utf8)
            let r2 = await localRun(two)
            expect(reasonOf(r2.0).contains("several application modules") && reasonOf(r2.0).contains("one") && reasonOf(r2.0).contains("two"), "local.sh says plainly when there are several, catalog alias included (\(reasonOf(r2.0)))")
            // A version-catalog alias finds the module; flavors: 'debug' is ambiguous and says so, 'freeDebug' is one build whose universal APK wins.
            let flavors = project("flavors", buildFile: "plugins { alias(libs.plugins.android.application) }\n", gradlew: writeVariant + """

            case "$1" in
              :app:assembleDebug) variant freeDebug free/debug free-universal.apk:UNIVERSAL: free-arm.apk:ONE_OF_MANY:arm64-v8a; variant paidDebug paid/debug paid-universal.apk:UNIVERSAL: ;;
              :app:assembleFreeDebug) variant freeDebug free/debug free-arm.apk:ONE_OF_MANY:arm64-v8a free-universal.apk:UNIVERSAL: free-v7.apk:ONE_OF_MANY:armeabi-v7a ;;
              *) echo "error: unexpected $1" >&2; exit 1 ;;
            esac
            """)
            let r3 = await localRun(flavors)
            expect(reasonOf(r3.0).contains("freeDebug") && reasonOf(r3.0).contains("paidDebug") && reasonOf(r3.0).contains("(variant)") && r3.1.contains("application module: app"),
                   "a catalog alias finds the module; two flavors of 'debug' fail naming both and the variant setting (\(reasonOf(r3.0).replacingOccurrences(of: "\n", with: " ")))")
            let r4 = await localRun(flavors, variant: "freeDebug")
            expect(r4.0 == .built && r4.2 == "content of free-universal.apk\n", "variant freeDebug: output-metadata.json picks the universal APK over the ABI splits (\(reasonOf(r4.0)), got \(r4.2 ?? "nothing"))")
            let abi = project("abi", buildFile: "plugins { id(\"com.android.application\") }\n", gradlew: writeVariant + """

            variant debug debug app-v7.apk:ONE_OF_MANY:armeabi-v7a app-arm64.apk:ONE_OF_MANY:arm64-v8a app-x86.apk:ONE_OF_MANY:x86
            """)
            let r5 = await localRun(abi)
            expect(r5.0 == .built && r5.2 == "content of app-arm64.apk\n", "without a universal APK the arm64-v8a one is taken (\(reasonOf(r5.0)))")
            // No metadata (an old plugin): only a file this run wrote counts; a leftover does not.
            let legacy = project("legacy", buildFile: "plugins { id 'com.android.application' }\n", file: "app/build.gradle", gradlew: "exit 0")
            let old = legacy.appendingPathComponent("app/build/outputs/apk/debug/app-debug.apk")
            try? fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "stale".write(to: old, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400)], ofItemAtPath: old.path)
            let r6 = await localRun(legacy)
            expect(reasonOf(r6.0).contains("written by this build"), "a stale APK left in the outputs is not taken (\(reasonOf(r6.0)))")
            let legacy2 = project("legacy2", buildFile: "plugins { id 'com.android.application' }\n", file: "app/build.gradle", gradlew: "mkdir -p app/build/outputs/apk/debug; echo fresh > app/build/outputs/apk/debug/app-debug.apk")
            let r7 = await localRun(legacy2)
            expect(r7.0 == .built && r7.2 == "fresh\n", "without metadata the APK this run wrote is taken (\(reasonOf(r7.0)))")

            // 5. Cancel ends the whole process group: the recipe, its child, and what the child started.
            q.onLine = nil
            let jobS = q.start(a1, workspace: ws, recipeName: "sleep", store: store)
            _ = await wait("the sleeper's child", 20) { (try? String(contentsOf: childPid, encoding: .utf8))?.isEmpty == false && jobS?.lines.contains("started") == true }
            let child = pid_t((try? String(contentsOf: childPid, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            let leader = jobS?.run?.pid ?? 0
            expect(alive(child) && alive(leader), "the recipe and its child run (pids \(leader), \(child))")
            q.cancel(a1.worktree.path)
            let ended = await wait("the cancel", 15) { jobS?.state == .cancelled }
            let gone = await wait("the group to end", 15) { !alive(child) && !alive(leader) }
            expect(ended && gone, "cancel ended the recipe and its child, which ignored TERM (cancelled \(ended), both gone \(gone))")
            expect(sessions.simulator(for: a0) === simA2 && row("a")?.build == before, "the old build is untouched after a cancel")

            // 6. Two builds of one workspace run one after the other.
            try? fm.removeItem(at: order)
            let jA = q.start(a1, workspace: ws, recipeName: "order", store: store)
            let jB = q.start(b0, workspace: ws, recipeName: "order", store: store)
            expect(jA?.state == .running && jB?.state == .queued, "the second build of the repository waits (a running, b queued)")
            _ = await wait("both", 60) { jA?.isActive == false && jB?.isActive == false }
            let lines = ((try? String(contentsOf: order, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            expect(lines == ["start wt-a", "end wt-a", "start wt-b", "end wt-b"], "the builds ran one after the other: \(lines.joined(separator: ", "))")
            var bothBuilt = false
            if case .built? = jA?.state, case .built? = jB?.state { bothBuilt = true }
            expect(bothBuilt, "both became builds")

            // 7. A deadline ends a recipe that closed its output and kept running; quitting the app ends a running one.
            let hang = recipe("hang", "(sleep 300) & echo $! > \"$CHECK_CHILD\"; exec >&- 2>&-; sleep 300")
            let hangRun = RecipeRun(recipe: hang, job: RecipeJob(worktree: worktree("b"), repo: repo, ref: "", sha: "", dirty: false, module: "", variant: "debug", out: base.appendingPathComponent("hang-out/app.apk")))
            hangRun.timeout = 2
            let hangStart = Date()
            let hangOutcome: RecipeOutcome = await withCheckedContinuation { c in hangRun.start { c.resume(returning: $0) } }
            let hangKid = pid_t((try? String(contentsOf: childPid, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            _ = await wait("the hung recipe's child", 10) { !alive(hangKid) }
            expect(reasonOf(hangOutcome).contains("longer than") && Date().timeIntervalSince(hangStart) < 15 && !alive(hangKid) && !alive(hangRun.pid),
                   "a recipe that closes stdout and keeps running is stopped at the deadline with a reason, group and all (\(reasonOf(hangOutcome)))")
            try? fm.removeItem(at: childPid)
            let jobQ = q.start(a1, workspace: ws, recipeName: "sleep", store: store)
            _ = await wait("the sleeper to start", 20) { (try? String(contentsOf: childPid, encoding: .utf8))?.isEmpty == false && jobQ?.lines.contains("started") == true }
            let quitKid = pid_t((try? String(contentsOf: childPid, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            let quitLead = jobQ?.run?.pid ?? 0
            q.terminateAll()   // what applicationWillTerminate calls
            var quitGone = !alive(quitKid)
            if !quitGone { quitGone = await wait("the group to die", 5) { !alive(quitKid) && !alive(quitLead) } }
            expect(quitKid > 0 && quitGone, "quitting the app kills a running recipe's group synchronously")
            _ = await wait("the quit build to settle", 15) { jobQ?.isActive == false }

            for f in slotFolders(a0.slot) { try? fm.removeItem(at: f) }
            LoginEnvironment.override = nil
            finish()
        }
    }
}
