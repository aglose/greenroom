import AppKit

/// `Greenroom --main-check DIR APK`: a temporary repository with an "origin" it pushes to, a stand-in local recipe
/// (it prints the commit it was given and copies APK) and two worktrees, one built and one not. Verifies main's row:
/// only an Android project gets one; main's newest commit is built by itself in a worktree of its own that is not a
/// session row, with the main checkout's local.properties; a click runs it in a data slot of its own; a commit pushed
/// to origin is fetched and built when asked; "Keep main built" off takes the row away. Then the sessions rules: a
/// worktree with no build is not suggested, and a click on it builds it and opens it. One `[greenroom] main: ok|FAIL
/// ...` line per step, then `main check: PASS|FAIL`; exits 0 or 1. The store is DIR's own; no Gradle or network.
enum MainCheck {
    static func run(workbench wb: Workbench, dir: URL, apk: URL) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            let sessions = wb.sessions

            func say(_ s: String) { fputs("[greenroom] main: \(s)\n", stdout); fflush(stdout) }
            func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; say((ok ? "ok " : "FAIL ") + what) }
            @MainActor func wait(_ what: String, _ seconds: Double = 120, _ cond: @MainActor () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 200_000_000) }
                say("timed out waiting for \(what)")
                return false
            }
            func ready(_ s: Simulator?) -> Bool { s?.state == .running && (s?.framesShown ?? 0) > 0 }
            var slots: [String] = []
            let data = Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true)
            func slotFolders(_ slot: String) -> [URL] {
                ((try? fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []).flatMap { pkg in
                    ((try? fm.contentsOfDirectory(at: pkg, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(slot + "-") }
                }
            }
            @MainActor func finish() -> Never {
                Engine.shared.stopAll()
                for s in slots { for f in slotFolders(s) { try? fm.removeItem(at: f) } }
                say(failures == 0 ? "done" : "stopped with \(failures) failure(s)")
                print("main check: " + (failures == 0 ? "PASS" : "FAIL"))
                fflush(stdout)
                exit(failures == 0 ? 0 : 1)
            }
            @discardableResult
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
            func head(_ ref: String, in folder: URL) -> String {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["rev-parse", ref]
                p.currentDirectoryURL = folder
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return "" }
                let d = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func write(_ text: String, _ file: URL, executable: Bool = false) {
                try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: file, atomically: true, encoding: .utf8)
                if executable { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
            }

            // The repositories: origin (bare), a clone that pushes to it, the person's checkout, and a plain one.
            let base = dir.resolvingSymlinksInPath()
            try? fm.removeItem(at: base)
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            let origin = base.appendingPathComponent("origin.git", isDirectory: true)
            let pusher = base.appendingPathComponent("pusher", isDirectory: true)
            let repo = base.appendingPathComponent("repo", isDirectory: true)
            let plain = base.appendingPathComponent("plain", isDirectory: true)
            try? fm.createDirectory(at: origin, withIntermediateDirectories: true)
            guard git(["init", "-q", "--bare", "-b", "main"], in: origin), git(["clone", "-q", origin.path, pusher.path], in: base) else {
                say("FAIL could not make the repositories (is /usr/bin/git there?)"); failures += 1; finish()
            }
            write("build/\nlocal.properties\n", pusher.appendingPathComponent(".gitignore"))
            write("#!/bin/sh\necho 'not a real gradle'\nexit 1\n", pusher.appendingPathComponent("gradlew"), executable: true)
            write("plugins { id(\"com.android.application\") }\n", pusher.appendingPathComponent("app/build.gradle.kts"))
            write("one\n", pusher.appendingPathComponent("README.md"))
            guard git(["checkout", "-q", "-b", "main"], in: pusher) || true, git(["add", "."], in: pusher), git(["commit", "-q", "-m", "first"], in: pusher),
                  git(["push", "-q", "origin", "main"], in: pusher), git(["clone", "-q", origin.path, repo.path], in: base) else {
                say("FAIL could not push the first commit"); failures += 1; finish()
            }
            write("sdk.dir=/check/sdk\n", repo.appendingPathComponent("local.properties"))
            try? fm.createDirectory(at: plain, withIntermediateDirectories: true)
            write("notes\n", plain.appendingPathComponent("README.md"))
            git(["init", "-q", "-b", "main"], in: plain); git(["add", "."], in: plain); git(["commit", "-q", "-m", "notes"], in: plain)
            func worktree(_ n: String) -> URL { base.appendingPathComponent("wt-" + n, isDirectory: true) }
            for n in ["x", "y"] { git(["worktree", "add", "-q", "-b", "feat-" + n, worktree(n).path], in: repo) }
            let builtAPK = worktree("y").appendingPathComponent("app/build/outputs/apk/debug/app-debug.apk")
            try? fm.createDirectory(at: builtAPK.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: apk, to: builtAPK)

            // The stand-in local recipe: what it was told, then the APK.
            setenv("CHECK_APK", apk.path, 1)
            let recipeFile = base.appendingPathComponent("recipes/local.sh")
            write("#!/bin/bash\necho \"SHA $GREENROOM_SHA\"\n[ -f local.properties ] && echo 'has local.properties'\nsleep 0.5\ncp \"$CHECK_APK\" \"$GREENROOM_OUT\"\n", recipeFile, executable: true)

            let store = SessionStore(root: base.appendingPathComponent("state", isDirectory: true))
            let root = repo.resolvingSymlinksInPath()
            var ws = Workspace(root: root)
            ws.recipes = ["local": Recipe(executable: recipeFile.path)]
            var plainWs = Workspace(root: plain.resolvingSymlinksInPath())
            plainWs.recipes = ws.recipes
            store.saveWorkspaces([ws, plainWs])
            AndroidProject.forget()
            sessions.use(store: store)

            // 1. Only an Android project gets main's row (including multi-composite repos with nested modules or wrappers).
            expect(AndroidProject.isApp(root) && !AndroidProject.isApp(plain), "the Android repository is an app project, the plain one is not")
            let compositeRoot = base.appendingPathComponent("composite-root", isDirectory: true)
            write("#!/bin/sh\nexit 1\n", compositeRoot.appendingPathComponent("gradlew"), executable: true)
            write("includeBuild(\"build-logic\")\nincludeBuild(\"mobile\")\n", compositeRoot.appendingPathComponent("settings.gradle.kts"))
            write("plugins { id(\"com.android.application\") }\n", compositeRoot.appendingPathComponent("mobile/app/build.gradle.kts"))
            let compositeNested = base.appendingPathComponent("composite-nested", isDirectory: true)
            write("#!/bin/sh\nexit 1\n", compositeNested.appendingPathComponent("android/gradlew"), executable: true)
            write("plugins { alias(libs.plugins.company.app) }\nandroid { defaultConfig { applicationId = \"com.example.app\" } }\n",
                  compositeNested.appendingPathComponent("android/apps/consumer/build.gradle.kts"))
            let compositeLibOnly = base.appendingPathComponent("composite-lib", isDirectory: true)
            write("#!/bin/sh\nexit 1\n", compositeLibOnly.appendingPathComponent("gradlew"), executable: true)
            write("plugins { id(\"com.android.library\") }\nandroid { defaultConfig { testApplicationId = \"com.example.test\" } }\n",
                  compositeLibOnly.appendingPathComponent("core/lib/build.gradle.kts"))
            expect(AndroidProject.isApp(compositeRoot) && AndroidProject.isApp(compositeNested) && !AndroidProject.isApp(compositeLibOnly),
                   "multi-composite Android repositories are detected (root or nested gradlew, nested app module or applicationId), library-only is not")
            let compositeApk = compositeNested.appendingPathComponent("android/apps/consumer/build/outputs/apk/debug/consumer-debug.apk")
            try? fm.createDirectory(at: compositeApk.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: apk, to: compositeApk)
            expect(SessionStore.isBuildOutput(compositeApk, in: compositeNested) && SessionStore.newestAPK(in: compositeNested)?.apk.lastPathComponent == "consumer-debug.apk",
                   "build outputs nested inside composite builds are found")
            expect(sessions.mainRow(for: plainWs.root) == nil, "the plain repository has no main row")

            // 2. Main's newest commit is built by itself, in a worktree of its own, with local.properties.
            let first = head("HEAD", in: pusher)
            func row() -> MainRow? { sessions.mainRow(for: root) }
            _ = await wait("main's first build", 60) { row()?.current != nil && row()?.isBusy == false }
            let r1 = row()
            expect(r1?.name == "main" && r1?.sha == first && r1?.current != nil, "main's row has a build of origin/main's head \(first.prefix(7)): \(r1?.current?.key ?? "none")")
            let lines = r1?.job?.lines ?? []
            expect(lines.contains("SHA \(first)") && lines.contains("has local.properties"), "the local recipe built that commit with the main checkout's local.properties")
            let trunk = sessions.mainBuilds.trunk(of: root)
            expect(head("HEAD", in: trunk) == first && trunk.path.hasPrefix(store.root.path), "main's worktree is under the state folder, at that commit")
            expect(!sessions.sessions.contains { sessions.mainBuilds.isTrunk($0.worktree) }, "main's worktree is not a session row")
            expect(sessions.groups().first { $0.workspace == root }?.sessions.isEmpty == true, "no worktree shows until it is added or used")

            // 3. A click runs it with data of its own.
            slots.append(sessions.mainBuilds.slot(of: root))
            sessions.openMain(root)
            guard await wait("main's first frame", 180, { ready(sessions.mainBuilds.simulator(of: root)) }), let simMain = sessions.mainBuilds.simulator(of: root) else { failures += 1; finish() }
            expect(sessions.mainBuilds.owns(simMain) && sessions.session(forSimulator: simMain) == nil && row()?.simulator === simMain,
                   "main runs in its own slot, on its row, not a session's")

            // 4. A commit pushed to origin is fetched and built when asked; the running simulator stays main's.
            write("two\n", pusher.appendingPathComponent("README.md"))
            git(["commit", "-q", "-am", "second"], in: pusher)
            git(["push", "-q", "origin", "main"], in: pusher)
            let second = head("HEAD", in: pusher)
            sessions.updateMain(root)
            _ = await wait("main's second build", 60) { row()?.sha == second && row()?.current != nil && row()?.isBusy == false }
            expect(row()?.sha == second && row()?.current != nil && (row()?.job?.lines ?? []).contains("SHA \(second)"),
                   "the new main \(second.prefix(7)) was fetched and built (an identical APK counts as that commit's)")
            expect(head("HEAD", in: trunk) == second, "main's worktree moved to the new commit")
            let checks = (row()?.job?.id)
            sessions.mainBuilds.ensureAll()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            expect(row()?.job?.id == checks && row()?.isBusy == false, "a look within ten minutes does not build again")

            // 5. Worktrees: one with no build is not suggested; a click on it builds it and opens it.
            guard let x = sessions.sessions.first(where: { $0.worktree.lastPathComponent == "wt-x" }),
                  let y = sessions.sessions.first(where: { $0.worktree.lastPathComponent == "wt-y" }) else { say("FAIL the worktrees are not rows"); failures += 1; finish() }
            expect(!sessions.isSuggested(x) && sessions.newestAPK(for: x) == nil && sessions.newestAPK(for: y) != nil, "x has no build and is not suggested; y has one")
            slots.append(x.slot)
            expect(sessions.activate(x), "a click on x is taken")
            expect(sessions.isShown(x), "x is in the sidebar once clicked")
            guard await wait("x's build and first frame", 180, { ready(sessions.simulator(for: x)) }) else { failures += 1; finish() }
            expect(sessions.buildQueue.job(for: x)?.lines.contains("SHA \(x.head)") == true, "x was built with its recipe, then opened")

            // 6. "Keep main built" off: no row, its simulator quits.
            sessions.setKeepMain(false, for: root)
            _ = await wait("main's simulator to quit", 30) { sessions.mainBuilds.simulator(of: root) == nil }
            expect(row() == nil && sessions.mainBuilds.simulator(of: root) == nil, "off, main has no row and its simulator quit")
            sessions.setKeepMain(true, for: root)
            expect(row() != nil, "on again, the row is back")
            finish()
        }
    }
}
