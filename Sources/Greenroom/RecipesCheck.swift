import AppKit

/// `Greenroom --recipes-check DIR APK`: the `ci` and `remote` recipes and base resolution, against stand-in `gh` and
/// `boat` programs written here and put first on the recipes' PATH (they record their arguments and behave from a small
/// state folder). Nothing leaves the machine: the real `gh` and `boat` are never on the PATH the recipes get. A fresh
/// folder inside DIR holds the repository (an `origin` that is a local bare repository, two worktrees), the store and
/// the stand-ins; DIR itself is never deleted. One `[greenroom] recipes: ok|FAIL ...` line per step, then
/// `recipes check: PASS|FAIL`.
enum RecipesCheck {
    static func run(workbench wb: Workbench, dir: URL, apk: URL) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            let sessions = wb.sessions

            func say(_ s: String) { fputs("[greenroom] recipes: \(s)\n", stdout); fflush(stdout) }
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
                print("recipes check: " + (failures == 0 ? "PASS" : "FAIL"))
                fflush(stdout)
                Engine.shared.stopAll()
                exit(failures == 0 ? 0 : 1)
            }
            func git(_ args: [String], in folder: URL) -> Bool {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["-c", "user.name=Check", "-c", "user.email=check@example.invalid", "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always"] + args
                p.currentDirectoryURL = folder
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return false }
                p.waitUntilExit()
                return p.terminationStatus == 0
            }
            func gitOut(_ args: [String], in folder: URL) -> String {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = args
                p.currentDirectoryURL = folder
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return "" }
                let d = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func write(_ f: URL, _ text: String, exec: Bool = false) {
                try? fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: f, atomically: true, encoding: .utf8)
                if exec { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path) }
            }
            func alive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

            // Nothing the recipes run may be the real gh or boat: the process's own PATH is cut down, and the recipes get
            // the stand-ins' folder first.
            setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
            setenv("GREENROOM_CI_GRACE", "0", 1)
            setenv("GREENROOM_CI_POLL", "1", 1)
            setenv("GREENROOM_CI_APPEAR_SECONDS", "20", 1)
            setenv("GREENROOM_REMOTE_POLL", "0.5", 1)

            let base = dir.resolvingSymlinksInPath().appendingPathComponent("recipes-check-" + UUID().uuidString.prefix(6).lowercased(), isDirectory: true)
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            say("working in \(base.path)")
            let bin = base.appendingPathComponent("bin", isDirectory: true)
            let ghState = base.appendingPathComponent("gh-state", isDirectory: true)
            let boatState = base.appendingPathComponent("boat-state", isDirectory: true)
            for d in [bin, ghState, boatState] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
            setenv("CHECK_GH", ghState.path, 1)
            setenv("CHECK_BOAT", boatState.path, 1)

            // Test APKs: the real one (to open in a simulator) and unique copies (so each recipe's build has its own key).
            func variant(_ tag: String) -> URL {
                let f = base.appendingPathComponent("apk-\(tag).apk")
                try? fm.copyItem(at: apk, to: f)
                if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data("greenroom-recipes-check-\(tag)".utf8)); try? h.close() }
                return f
            }
            let ciApk = variant("ci"), remoteApk = variant("remote"), freshApk = variant("fresh"), fileApk = variant("file")
            func keyOf(_ f: URL) -> String { SessionStore.key(of: f) ?? "?" }
            let ciKey = keyOf(ciApk), remoteKey = keyOf(remoteApk)
            setenv("CHECK_GH_APK", ciApk.path, 1)
            setenv("CHECK_REMOTE_APK", remoteApk.path, 1)

            // ---- The stand-in gh -----------------------------------------------------------------------------------
            write(bin.appendingPathComponent("gh"), #"""
            #!/bin/bash
            S="${CHECK_GH:?}"
            echo "gh $*" >> "$S/calls.log"
            a=(); skip=0
            for x in "$@"; do if [ $skip = 1 ]; then skip=0; elif [ "$x" = -R ]; then skip=1; else a+=("$x"); fi; done
            set -- "${a[@]}"
            case "$1" in
              auth) [ -e "$S/noauth" ] && { echo "You are not logged into any GitHub hosts. Run gh auth login to authenticate." >&2; exit 1; }; exit 0 ;;
              run)
                case "$2" in
                  list)
                    sha=""; a=("$@"); i=0
                    while [ $i -lt ${#a[@]} ]; do [ "${a[$i]}" = "--commit" ] && sha="${a[$((i+1))]}"; i=$((i+1)); done
                    if [ -f "$S/dispatched" ]; then
                      n=$(cat "$S/dispatched")
                      if [ "$n" -gt 0 ]; then echo $((n-1)) > "$S/dispatched"; exit 0; fi
                      [ -f "$S/runs-after-dispatch.tsv" ] && cat "$S/runs-after-dispatch.tsv"; exit 0
                    fi
                    f="$S/runs-$sha.tsv"; [ -f "$f" ] || f="$S/runs.tsv"; [ -f "$f" ] && cat "$f"; exit 0 ;;
                  watch)
                    [ -f "$S/watch.fail" ] && { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
                    sleep 1
                    c="success"; [ -f "$S/watch.final" ] && c="$(cat "$S/watch.final")"
                    awk -F'\t' -v id="$3" -v c="$c" 'BEGIN{OFS="\t"} $1==id{$2="completed";$3=c} {print}' "$S/runs.tsv" > "$S/runs.tmp" && mv "$S/runs.tmp" "$S/runs.tsv"
                    [ "$c" = success ] ;;
                  view) echo "https://example.invalid/runs/$3" ;;
                  download)
                    id="$3"; name=""; dir=""; a=("$@"); i=0
                    while [ $i -lt ${#a[@]} ]; do case "${a[$i]}" in -n) name="${a[$((i+1))]}";; -D) dir="${a[$((i+1))]}";; esac; i=$((i+1)); done
                    mkdir -p "$dir"
                    files="app-debug.apk"; [ -f "$S/files-$name.txt" ] && files="$(cat "$S/files-$name.txt")"
                    for f in $files; do case "$f" in *.apk) cp "${CHECK_GH_APK:?}" "$dir/$f" ;; *) echo x > "$dir/$f" ;; esac; done ;;
                esac ;;
              api)
                path=""; for x in "$@"; do case "$x" in repos/*) path="$x" ;; esac; done
                case "$path" in
                  */git/ref/heads/*) [ -f "$S/refsha" ] && { cat "$S/refsha"; exit 0; }; exit 1 ;;
                  */artifacts*)
                    id="$(printf '%s' "$path" | sed -E 's|.*/runs/([0-9]+)/artifacts.*|\1|')"
                    [ -f "$S/artifacts-$id.txt" ] || exit 0
                    while IFS= read -r n; do
                      e=false; [ -f "$S/expired.txt" ] && grep -qx "$n" "$S/expired.txt" && e=true
                      printf '%s\t%s\n' "$n" "$e"
                    done < "$S/artifacts-$id.txt"; exit 0 ;;
                esac ;;
              workflow) echo 2 > "$S/dispatched" ;;
              pr)
                n="${3##*/}"; n="$(printf '%s' "$n" | tr -d '#')"
                [ -f "$S/pr-$n.json" ] && { cat "$S/pr-$n.json"; exit 0; }
                echo "no pull requests found for $3" >&2; exit 1 ;;
              *) echo "stand-in gh: unexpected $*" >&2; exit 9 ;;
            esac
            """#, exec: true)

            // ---- The stand-in boat ---------------------------------------------------------------------------------
            // A sandbox is a folder: /home/user is box/ID/home/user. exec runs the command there (detached: in a session of its own).
            write(bin.appendingPathComponent("boat"), #"""
            #!/bin/bash
            S="${CHECK_BOAT:?}"
            echo "boat $*" >> "$S/calls.log"
            box() { echo "$S/box/$1"; }
            map() { case "$2" in /*) echo "$(box "$1")$2" ;; *) echo "$(box "$1")/home/user/$2" ;; esac; }
            case "$1" in
              new)
                shift; t=""; [ "$1" = "--snapshot" ] && t="$2"
                id="sbx-from-$t"; mkdir -p "$(box "$id")/home/user"; echo running > "$(box "$id")/state"
                echo "created sandbox $id" ;;
              start)
                [ "$2" = "sbx-bad" ] && { echo "no such sandbox sbx-bad" >&2; exit 1; }
                mkdir -p "$(box "$2")/home/user"; echo running > "$(box "$2")/state" ;;
              stop)
                [ -n "${CHECK_BOAT_STOP_DELAY:-}" ] && sleep "$CHECK_BOAT_STOP_DELAY"
                if [ -f "$(box "$2")/pids" ]; then while read -r p; do kill -KILL -- "-$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done < "$(box "$2")/pids"; fi
                mkdir -p "$(box "$2")"; echo stopped > "$(box "$2")/state" ;;
              exec)
                id="$2"; shift 2; det=0; cwd=""
                while [ $# -gt 0 ]; do case "$1" in --detach) det=1; shift ;; --cwd) cwd="$2"; shift 2 ;; *) break ;; esac; done
                [ "$(cat "$(box "$id")/state" 2>/dev/null)" = running ] || { echo "sandbox $id is not running" >&2; exit 1; }
                dest="$(map "$id" "$cwd")"; mkdir -p "$dest"
                if [ "$det" = 1 ]; then
                  ( cd "$dest" && HOME="$(box "$id")/home/user" perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash -c "$1" > /dev/null 2>&1 < /dev/null & echo $! >> "$(box "$id")/pids" )
                else
                  ( cd "$dest" && HOME="$(box "$id")/home/user" bash -c "$1" )
                fi ;;
              scp)
                a="$2"; b="$3"
                if [[ "$a" =~ ^([^/:]+):(/.*)$ ]]; then cp "$(map "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")" "$b"
                elif [[ "$b" =~ ^([^/:]+):(/.*)$ ]]; then t="$(map "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")"; mkdir -p "$(dirname "$t")"; cp "$a" "$t"
                else echo "stand-in boat: scp needs ID:PATH" >&2; exit 2; fi ;;
              *) echo "stand-in boat: unexpected $*" >&2; exit 9 ;;
            esac
            """#, exec: true)

            // ---- The repository: an origin (local bare), main, two worktrees, a stand-in gradlew ----------------------
            let origin = base.appendingPathComponent("origin.git", isDirectory: true)
            let repo = base.appendingPathComponent("repo", isDirectory: true)
            try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
            write(repo.appendingPathComponent(".gitignore"), "build/\nignored.log\n")
            write(repo.appendingPathComponent("README.md"), "hello\n")
            write(repo.appendingPathComponent("old.txt"), "to be deleted\n")
            write(repo.appendingPathComponent("app/build.gradle.kts"), "plugins { id(\"com.android.application\") }\n")
            write(repo.appendingPathComponent("gradlew"), #"""
            #!/bin/sh
            # Stand-in Gradle for the remote recipe: prints steps, and writes the APK where AGP does.
            echo "stand-in gradle: $@"
            echo "README says: $(cat README.md)"
            echo "step one"
            sleep 1.2
            case "$CHECK_GRADLE" in
              fail) echo "error: boom, unresolved reference" >&2; exit 1 ;;
              sleep) echo "sleeping"; sleep 300 ;;
            esac
            echo "step two"
            mkdir -p app/build/outputs/apk/debug
            cp "$CHECK_REMOTE_APK" app/build/outputs/apk/debug/app-debug.apk
            """#, exec: true)
            guard git(["init", "-q", "-b", "main"], in: repo), git(["add", "."], in: repo), git(["commit", "-q", "-m", "first"], in: repo),
                  git(["init", "-q", "--bare", "-b", "main", origin.path], in: base),
                  git(["remote", "add", "origin", origin.path], in: repo), git(["push", "-q", "-u", "origin", "main"], in: repo) else {
                say("FAIL could not make the repository (is /usr/bin/git there?)"); failures += 1; finish()
            }
            func worktree(_ n: String) -> URL { base.appendingPathComponent("wt-" + n, isDirectory: true) }
            for n in ["a", "b"] {
                guard git(["worktree", "add", "-q", "-b", "feat-" + n, worktree(n).path, "main"], in: repo),
                      git(["branch", "-q", "--set-upstream-to=origin/main", "feat-" + n], in: repo) else { say("FAIL worktree \(n)"); failures += 1; finish() }
            }
            let mainSha = gitOut(["rev-parse", "HEAD"], in: repo)
            let originShort = String(mainSha.prefix(7))
            let aApk = worktree("a").appendingPathComponent("app/build/outputs/apk/debug/app-debug.apk")
            try? fm.createDirectory(at: aApk.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: apk, to: aApk)

            let store = SessionStore(root: base.appendingPathComponent("state", isDirectory: true))
            sessions.use(store: store)
            let added = await sessions.addRepository(worktree("a")).value
            guard added == repo.resolvingSymlinksInPath(), let wsIndex = sessions.workspaces.firstIndex(where: { $0.root == added }) else { say("FAIL repository not added"); failures += 1; finish() }
            func row(_ n: String) -> Session? { sessions.sessions.first { $0.worktree.lastPathComponent == "wt-" + n } }
            _ = await wait("the rows", 30) { row("a") != nil && row("b") != nil }
            guard let a0 = row("a"), row("b") != nil else { say("FAIL rows missing"); failures += 1; finish() }
            func setWS(_ f: (inout Workspace) -> Void) { f(&sessions.workspaces[wsIndex]); store.saveWorkspaces(sessions.workspaces) }
            func ws() -> Workspace { sessions.workspaces[wsIndex] }
            let q = sessions.buildQueue

            @MainActor func build(_ s: Session?, _ name: String, _ seconds: Double = 90) async -> BuildJob? {
                guard let s, let job = q.start(s, workspace: ws(), recipeName: name, store: store, error: { say("start refused: \($0)") }) else { return nil }
                _ = await wait("build \(name)", seconds) { !job.isActive }
                return job
            }
            func failure(_ j: BuildJob?) -> String { j?.failure ?? (j.map { "\($0.state)" } ?? "no job") }
            func builtKey(_ j: BuildJob?) -> String? { if case .built(let b)? = j?.state { return b.key }; return nil }
            func ghCalls() -> [String] { ((try? String(contentsOf: ghState.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
            func boatCalls() -> [String] { ((try? String(contentsOf: boatState.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
            func ghReset(runs: [String] = [], artifacts: [String: [String]] = [:], files: [String: [String]] = [:]) {
                for f in (try? fm.contentsOfDirectory(atPath: ghState.path)) ?? [] { try? fm.removeItem(at: ghState.appendingPathComponent(f)) }
                if !runs.isEmpty { write(ghState.appendingPathComponent("runs.tsv"), runs.joined(separator: "\n") + "\n") }
                for (id, names) in artifacts { write(ghState.appendingPathComponent("artifacts-\(id).txt"), names.joined(separator: "\n") + "\n") }
                for (name, list) in files { write(ghState.appendingPathComponent("files-\(name).txt"), list.joined(separator: " ")) }
            }
            func boatReset() {
                for f in (try? fm.contentsOfDirectory(atPath: boatState.path)) ?? [] { try? fm.removeItem(at: boatState.appendingPathComponent(f)) }
                unsetenv("CHECK_GRADLE"); unsetenv("CHECK_BOAT_STOP_DELAY")
            }
            let standIns = ["PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
            LoginEnvironment.override = standIns

            // ===== 0. Settings are read tolerantly ==============================================================
            let odd = #"[{"root":"file:///tmp/x","ci":{"artifact":5,"apk":"*.apk","bogus":1},"remote":"junk"},{"root":"file:///tmp/y","ci":{"workflow":"ci.yml"},"remote":{"consent":true,"sandbox":"sbx-9"}}]"#
            let decoded = (try? JSONDecoder().decode([Workspace].self, from: Data(odd.utf8))) ?? []
            expect(decoded.count == 2 && decoded[0].ci.artifact == "" && decoded[0].ci.apk == "*.apk" && decoded[0].remote == RemoteSettings()
                   && decoded[1].ci.workflow == "ci.yml" && decoded[1].remote.consent == true && decoded[1].remote.sandbox == "sbx-9",
                   "settings with a mistyped field, a wrong shape and an unknown key still load, field by field")
            expect(GitHubRemote.slug(of: "git@github.com:example/app.git") == "example/app" && GitHubRemote.slug(of: "https://github.com/example/app") == "example/app"
                   && GitHubRemote.slug(of: "ssh://git@github.com/example/app.git") == "example/app" && GitHubRemote.slug(of: "https://gitlab.com/example/app.git") == nil
                   && GitHubRemote.slug(of: "/tmp/origin.git") == nil, "GitHub remotes are recognised in https, ssh and scp form, and others are not")
            expect(PullRequestRef.parse("42")?.number == 42 && PullRequestRef.parse("#7")?.number == 7
                   && PullRequestRef.parse("https://github.com/o/r/pull/9")?.slug == "o/r" && PullRequestRef.parse("https://github.com/o/r/issues/9") == nil && PullRequestRef.parse("x") == nil
                   && PullRequestRef.parse("https://github.com/o/r/pull/9#issuecomment-5")?.number == 9 && PullRequestRef.parse("https://github.com/o/r/pull/9/files?w=1")?.slug == "o/r",
                   "a pull request is a number, #number or an address")
            expect(CIBehind.describe(ciSha: mainSha, ahead: 2, dirty: false) == "CI has \(originShort), 2 commits behind"
                   && CIBehind.describe(ciSha: mainSha, ahead: 1, dirty: true) == "CI has \(originShort), 1 commit behind"
                   && CIBehind.describe(ciSha: mainSha, ahead: 0, dirty: true) == "CI has \(originShort), without your edits" && CIBehind.describe(ciSha: mainSha, ahead: 0, dirty: false) == nil
                   && CIBehind.describe(ciSha: mainSha, ahead: 2, dirty: false, known: false) == "pushed: \(originShort), 2 commits behind",
                   "the row's CI note: commits behind, edits not in it, nothing when CI has what the worktree is")

            // ===== 1. The recipe menu offers ci only with a GitHub remote ========================================
            func recipeMenu() -> [String] {
                guard let s = row("b"), let item = sessions.buildMenuItems(for: s).first(where: { $0.title == "Build with" }) else { return [] }
                return item.submenu?.items.map(\.title) ?? []
            }
            GitHubRemote.forget(repo)
            let before = recipeMenu()
            expect(before.contains("local") && before.contains("remote") && !before.contains("ci"), "no GitHub remote: the Build with menu has local and remote, not ci (\(before.joined(separator: ", ")))")
            _ = git(["remote", "add", "upstream", "https://github.com/example/app.git"], in: repo)
            GitHubRemote.forget(repo)
            let after = recipeMenu()
            expect(after.contains("ci") && after.contains("Build Settings…") && after.contains("Prepare Remote Builder…"), "with a GitHub remote ci is offered, with the settings and the remote builder's steps (\(after.joined(separator: ", ")))")

            // ===== 2. ci: a finished run's artifact arrives ======================================================
            ghReset(runs: ["101\tcompleted\tsuccess\tCI"], artifacts: ["101": ["app-debug"]])
            let j1 = await build(row("b"), "ci")
            var b1: Build?
            if case .built(let x)? = j1?.state { b1 = x }
            let list1 = ghCalls()
            expect(b1?.key == ciKey && b1?.source == .ci && b1?.sha == mainSha && b1?.dirty == false && list1.contains { $0.hasPrefix("gh run list -R example/app --commit \(mainSha)") } && list1.contains { $0.hasPrefix("gh run download -R example/app 101 -n app-debug") },
                   "a finished run: gh run list, gh run download -n app-debug, and the APK is a CI Build of that commit (\(failure(j1)))")
            _ = await wait("b's build", 20) { row("b")?.build?.key == ciKey }
            expect(row("b")?.build?.key == ciKey, "the session's newest build is the CI one")

            // ===== 3. an in-progress run is waited for ===========================================================
            ghReset(runs: ["102\tin_progress\t\tCI"], artifacts: ["102": ["app-debug"]])
            let j2 = await build(row("b"), "ci")
            expect(builtKey(j2) == ciKey && ghCalls().contains { $0.hasPrefix("gh run watch -R example/app 102") } && (j2?.lines.contains { $0.contains("waiting for CI run 102") } ?? false),
                   "an in-progress run: gh run watch, then its artifact (\(failure(j2)))")

            // ===== 4. no run + a workflow: dispatched, the run waited for ========================================
            ghReset(artifacts: ["9001": ["app-debug"]])
            write(ghState.appendingPathComponent("runs-after-dispatch.tsv"), "9001\tcompleted\tsuccess\tCI\n")
            write(ghState.appendingPathComponent("refsha"), (row("b")?.head ?? "") + "\n")
            setWS { $0.ci.workflow = "ci.yml" }
            let j3 = await build(row("b"), "ci")
            let c3 = ghCalls()
            expect(builtKey(j3) == ciKey && c3.contains("gh workflow run -R example/app ci.yml --ref feat-b") && c3.filter { $0.hasPrefix("gh run list") }.count >= 3 && c3.contains { $0.hasPrefix("gh run download -R example/app 9001") },
                   "no run and a workflow set: gh workflow run ci.yml --ref feat-b, after checking the branch on GitHub is at the commit, then the run that appeared (\(failure(j3)); \(c3.filter { $0.hasPrefix("gh run list") }.count) lists)")
            // The branch on GitHub is somewhere else: nothing is started, and the plain "not pushed" message.
            ghReset()
            write(ghState.appendingPathComponent("refsha"), String(repeating: "1", count: 40) + "\n")
            let j3b = await build(row("b"), "ci")
            expect(failure(j3b).contains("CI can only build pushed commits: push, or use the local recipe") && !ghCalls().contains { $0.contains("workflow run") },
                   "a workflow is started only when the branch on GitHub is at the commit (\(failure(j3b)))")
            // And with no workflow: a plain message.
            setWS { $0.ci.workflow = "" }
            ghReset()
            _ = await wait("b's build to show", 20) { row("b")?.build?.key == ciKey }
            let keep = row("b")?.build
            let j4 = await build(row("b"), "ci")
            expect(failure(j4).contains("no CI run for") && failure(j4).contains("no workflow is set") && row("b")?.build == keep, "no run and no workflow: a plain message, the last build stays (\(failure(j4)))")

            // ===== 5. The plain failures keep the last good build =================================================
            ghReset(runs: ["103\tcompleted\tfailure\tCI"])
            let j5 = await build(row("b"), "ci")
            expect(failure(j5).contains("https://example.invalid/runs/103") && row("b")?.build == keep, "a failed run fails with its URL, the last build stays (\(failure(j5)))")
            ghReset(runs: ["104\tcompleted\tsuccess\tCI"], artifacts: ["104": ["debug-apk", "release-apk", "logs"]], files: ["debug-apk": ["app-debug.apk"], "release-apk": ["app-release.apk"], "logs": ["out.txt"]])
            let j6 = await build(row("b"), "ci")
            expect(failure(j6).contains("debug-apk") && failure(j6).contains("release-apk") && !failure(j6).contains("logs") && failure(j6).contains("CI artifact") && row("b")?.build == keep,
                   "several artifacts with an APK are listed and the setting is named (\(failure(j6)))")
            setWS { $0.ci.artifact = "debug-apk" }
            let mark7 = ghCalls().count
            let j7 = await build(row("b"), "ci")
            let calls7 = Array(ghCalls().dropFirst(mark7))
            expect(builtKey(j7) == ciKey && calls7.contains { $0.hasPrefix("gh run download -R example/app 104 -n debug-apk") } && !calls7.contains { $0.hasPrefix("gh run download -R example/app 104 -n release-apk") },
                   "with the CI artifact setting only that artifact is downloaded (\(failure(j7)))")
            setWS { $0.ci.artifact = ""; $0.ci.apk = "app-release*.apk" }
            let mark8 = ghCalls().count
            let j8 = await build(row("b"), "ci")
            expect(builtKey(j8) == ciKey && ghCalls().dropFirst(mark8).contains { $0.hasPrefix("gh run download -R example/app 104 -n release-apk") }, "the APK pattern setting picks the artifact whose APK matches (\(failure(j8)))")
            setWS { $0.ci.apk = "" }
            ghReset(runs: ["105\tcompleted\tsuccess\tCI"], artifacts: ["105": ["app-debug"]])
            write(ghState.appendingPathComponent("noauth"), "")
            let j9 = await build(row("b"), "ci")
            expect(failure(j9).contains("not signed in") && row("b")?.build == keep, "gh not signed in: a plain message (\(failure(j9)))")
            LoginEnvironment.override = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            let j10 = await build(row("b"), "ci")
            expect(failure(j10).contains("needs the GitHub CLI") && row("b")?.build == keep, "gh missing: a plain message (\(failure(j10)))")
            LoginEnvironment.override = standIns
            try? fm.removeItem(at: ghState.appendingPathComponent("noauth"))
            // gh run watch failing at once is shown, not looped on; a run waiting for approval says so; both are bounded.
            ghReset(runs: ["107\tin_progress\t\tCI"], artifacts: ["107": ["app-debug"]])
            write(ghState.appendingPathComponent("watch.fail"), "")
            let jw = await build(row("b"), "ci")
            expect(failure(jw).contains("gh run watch could not follow CI run 107") && failure(jw).contains("502") && row("b")?.build == keep, "gh run watch failing at once: its error is shown, no loop (\(failure(jw)))")
            ghReset(runs: ["108\twaiting\t\tCI"])
            setenv("GREENROOM_CI_WAIT", "3", 1)
            let jq = await build(row("b"), "ci")
            unsetenv("GREENROOM_CI_WAIT")
            expect(failure(jq).contains("waiting for approval") && row("b")?.build == keep, "a run waiting for approval says so, and the wait has a limit (\(failure(jq)))")
            ghReset(runs: ["109\tcompleted\tsuccess\tCI"], artifacts: ["109": ["app-debug"]])
            write(ghState.appendingPathComponent("expired.txt"), "app-debug\n")
            let je = await build(row("b"), "ci")
            setWS { $0.ci.artifact = "app-debug" }
            let je2 = await build(row("b"), "ci")
            setWS { $0.ci.artifact = "" }
            expect(failure(je).contains("artifact app-debug of run 109 expired: re-run the workflow") && failure(je2).contains("artifact app-debug of run 109 expired: re-run the workflow")
                   && ghCalls().contains { $0.contains("api --paginate repos/example/app/actions/runs/109/artifacts") }, "an expired artifact has its own message (with or without the setting), and the artifacts are paginated (\(failure(je)))")

            // ===== 6. An unpushed commit, and the row's note =====================================================
            ghReset(runs: ["106\tcompleted\tsuccess\tCI"], artifacts: ["106": ["app-debug"]])
            let ja = await build(row("a"), "ci")
            expect(builtKey(ja) == ciKey, "a (at origin's commit) fetches CI's build (\(failure(ja)))")
            _ = await wait("a's build to show", 20) { row("a")?.build?.key == ciKey }
            let aGood = row("a")?.build
            write(worktree("a").appendingPathComponent("feature.txt"), "a change\n")
            _ = git(["add", "."], in: worktree("a")); _ = git(["commit", "-q", "-m", "second"], in: worktree("a"))
            sessions.refresh()
            _ = await wait("a to be ahead", 20) { row("a")?.ahead == 1 }
            let markB = ghCalls().count
            let jb = await build(row("a"), "ci")
            expect(failure(jb).contains("CI can only build pushed commits: push, or use the local recipe") && row("a")?.build == aGood && !ghCalls().dropFirst(markB).contains { $0.hasPrefix("gh run list") },
                   "an unpushed commit: \"CI can only build pushed commits: push, or use the local recipe\", no run looked for, the last build stays (\(failure(jb)))")
            ws().defaultRecipeName = "ci"
            var note: String?
            if let s = row("a") {
                _ = await wait("the row's CI note", 15) { note = CIBehind.note(for: s, store: store) {}; return note != nil }
            }
            expect(note == "CI has \(originShort), 1 commit behind", "the row says what CI has: \(note ?? "nothing")")
            ws().defaultRecipeName = "local"

            // ===== 7. Pull requests as rows ======================================================================
            let prSha = String(repeating: "ab", count: 20)
            write(ghState.appendingPathComponent("pr-42.json"), #"{"headRefOid":"\#(prSha)","headRefName":"feature-x","title":"Add things"}"# + "\n")
            write(ghState.appendingPathComponent("pr-43.json"), #"{"headRefOid":"\#(String(repeating: "cd", count: 20))","headRefName":"feature-y","title":"Other things"}"# + "\n")
            write(ghState.appendingPathComponent("runs-\(prSha).tsv"), "201\tcompleted\tsuccess\tCI\n")
            write(ghState.appendingPathComponent("artifacts-201.txt"), "app-debug\n")
            setenv("CHECK_GH_APK", apk.path, 1)     // the real APK: this one is opened in a simulator
            let pulls = sessions.pulls
            let (bad, badWhy) = await pulls.add("https://github.com/other/thing/pull/43", to: ws())
            expect(bad == nil && badWhy.contains("other/thing") && badWhy.contains("none of repo"), "a pull request address of another repository is refused (\(badWhy))")
            let (pr, prWhy) = await pulls.add("42", to: ws())
            expect(pr?.title == "Add things" && pr?.headSha == prSha && prWhy.isEmpty, "gh pr view 42 gives the head and the title (\(prWhy))")
            _ = await wait("the pull request's build", 60) { pulls.rows().first?.state == .idle && pulls.rows().first?.build != nil }
            let prRow = pulls.rows().first
            expect(prRow?.pull.number == 42 && prRow?.build?.sha == prSha && prRow?.build?.source == .ci && sessions.pullRows().count == 1
                   && ghCalls().contains("gh pr view 42 -R example/app --json headRefOid,headRefName,title") && ghCalls().contains { $0.hasPrefix("gh run list -R example/app --commit \(prSha)") } && prRow?.pull.slug == "example/app" && prRow?.pull.id == "example/app#42",
                   "the row appears in Review and its build is fetched by the ci recipe, no worktree involved")
            guard let pull = prRow?.pull else { say("FAIL no pull request row"); failures += 1; finish() }
            expect(PullStore(file: store.root.appendingPathComponent("sessions/pulls.json")).load().count == 1, "the pull request is kept in sessions/pulls.json")
            pulls.open(pull)
            guard await wait("the pull request's simulator", 180, { ready(pulls.simulator(of: pull)) }), let prSim = pulls.simulator(of: pull) else { expect(false, "the pull request opened in a simulator (simulators: \(Engine.shared.simulators.map { "\($0.state) alive \($0.isAlive) frames \($0.framesShown) \($0.options)" }), wanted slot \(pulls.slot(of: pull)))"); finish() }
            let prSlot = pulls.slot(of: pull)
            expect(DevHooks.value("--data-slots", in: prSim.options) == prSlot && prSlot != a0.slot && prSlot != row("b")?.slot && sessions.session(forSimulator: prSim) == nil && pulls.owns(prSim),
                   "it opened in a simulator with a data slot of its own (\(prSlot), the sessions' are \(a0.slot) and \(row("b")?.slot ?? "?"))")
            try? fm.removeItem(at: ghState.appendingPathComponent("runs.tsv"))   // the stand-in answers any commit with it
            setWS { $0.ci.workflow = "ci.yml" }
            let (pr2, pr2Why) = await pulls.add("https://github.com/example/app/pull/43", to: ws())
            _ = await wait("the second pull request to settle", 60) { if case .offer = pulls.state(of: pr2 ?? pull) { return true }; return false }
            var pr2Msg = ""
            if let pr2, case .offer(let m) = pulls.state(of: pr2) { pr2Msg = m }
            expect(pr2 != nil && pr2Why.isEmpty && pr2Msg.contains("no CI run for"), "an address works too, and a pull request CI has not built says so on its row (\(pr2Msg); add said \(pr2Why); state \(pr2.map { "\(pulls.state(of: $0))" } ?? "no pull request"); calls \(ghCalls().suffix(4)))")
            setWS { $0.ci.workflow = "" }
            expect(pr2Msg.contains("not started here") && pr2Msg.contains("pull request's code") && !ghCalls().contains { $0.contains("workflow run") },
                   "a pull request row never starts a workflow, even with one set, and its offer warns that building it runs its code here (\(pr2Msg))")
            if let pr2 { pulls.remove(pr2) }
            pulls.remove(pull)
            _ = await wait("the simulator to end", 30) { !prSim.isAlive }
            expect(!prSim.isAlive && pulls.rows().isEmpty && PullStore(file: store.root.appendingPathComponent("sessions/pulls.json")).load().isEmpty, "removing a pull request ends its simulator and its row")
            let junkFile = store.root.appendingPathComponent("sessions/pulls.json")
            write(junkFile, #"[{"workspace":"/x","number":3,"title":"Kept"},{"number":"no workspace"},{"workspace":"/y","number":"x"}]"#)
            expect(PullStore(file: junkFile).load().map(\.title) == ["Kept"], "a bad pull request record is skipped, not the file")
            write(junkFile, "[]")

            // ===== 8. Base resolution ============================================================================
            setenv("CHECK_GH_APK", ciApk.path, 1)
            ghReset()
            let wsNow = ws()
            let known = sessions.sessions
            let listsBefore = ghCalls().filter { $0.hasPrefix("gh run list") }.count
            let r1 = await Bases.resolve(base: .baseBranch, in: wsNow, sessions: known, store: store, worktree: worktree("b"))
            var r1Key: String?
            if case .build(let b) = r1 { r1Key = b.key }
            expect(r1Key == ciKey && ghCalls().filter { $0.hasPrefix("gh run list") }.count == listsBefore, "the base branch: the merge base's stored build is taken first, CI is not asked")
            let r2 = await Bases.resolve(base: .ref("main"), in: wsNow, sessions: known, store: store)
            let r3 = await Bases.resolve(base: .session(row("b")!.worktree.path), in: wsNow, sessions: known, store: store)
            let r4 = await Bases.resolve(base: .apk(fileApk), in: wsNow, sessions: known, store: store)
            var keys: [String?] = []
            for r in [r2, r3, r4] { if case .build(let b) = r { keys.append(b.key) } else { keys.append(nil) } }
            var r4Source: Build.Source?
            if case .build(let b) = r4 { r4Source = b.source }
            expect(keys == [ciKey, ciKey, keyOf(fileApk)] && r4Source == .file, "a branch, another session and an APK file resolve to builds (\(keys); session: \(r3); history \(store.history(of: row("b")!.worktree.path)))")
            let r5 = await Bases.resolve(base: .ref("no-such-branch"), in: wsNow, sessions: known, store: store)
            var r5Why = ""
            if case .failed(let w) = r5 { r5Why = w }
            expect(r5Why.contains("No branch or commit called no-such-branch"), "an unknown branch fails plainly (\(r5Why))")
            write(ghState.appendingPathComponent("pr-44.json"), #"{"headRefOid":"\#(mainSha)","headRefName":"feature-z","title":"Same commit"}"# + "\n")
            let r6 = await Bases.resolve(base: .pullRequest(44), in: wsNow, sessions: known, store: store)
            var r6Key: String?
            if case .build(let b) = r6 { r6Key = b.key }
            expect(r6Key == ciKey && ghCalls().contains("gh pr view 44 -R example/app --json headRefOid,headRefName,title"), "a pull request number resolves through gh pr view, then to its commit's stored build")
            // A commit nobody has built: CI says no (unpushed), the worktree's APK is older than it: an offer, nothing started.
            let sessionsBefore = Set(known.map(\.worktree.path))
            let r7 = await Bases.resolve(base: .ref("feat-a"), in: wsNow, sessions: known, store: store)
            var offer: BuildOffer?
            if case .offer(let o) = r7 { offer = o }
            expect(offer != nil && offer!.ciReason.contains("pushed commits") && offer!.message.contains("local recipe") && offer!.message.contains("does not start a build in a scratch worktree")
                   && Set(sessions.sessions.map(\.worktree.path)) == sessionsBefore && !q.jobs.values.contains { $0.isActive },
                   "no stored build, CI cannot, no fresh worktree: an offer that says what could build it, nothing started (\(offer?.message ?? "no offer"))")
            // The same commit, once its worktree has a fresh APK: taken from there.
            try? fm.removeItem(at: aApk)
            try? fm.copyItem(at: freshApk, to: aApk)
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: aApk.path)
            sessions.refresh()
            _ = await wait("a's fresh APK", 20) { row("a")?.outputs != nil && row("a")?.isStale == false }
            let r8 = await Bases.resolve(base: .ref("feat-a"), in: wsNow, sessions: sessions.sessions, store: store)
            var r8b: Build?
            if case .build(let b) = r8 { r8b = b }
            expect(r8b?.key == keyOf(freshApk) && r8b?.source == .local && r8b?.sha == gitOut(["rev-parse", "feat-a"], in: repo) && r8b?.dirty == false,
                   "a worktree already at the commit with a fresh APK is used (\(r8b?.key ?? "none"))")

            // ===== 9. The remote recipe ==========================================================================
            let consentText = RemoteConsent.makeAlert(repo: "repo").informativeText
            let consentAlert = RemoteConsent.makeAlert(repo: "repo")
            expect(consentText.contains("uploads this repository's source code to your own boat.dev account") && consentText.contains("secret in an untracked file") && consentText.contains(".env*")
                   && consentText.contains("stays in the stopped sandbox") && consentAlert.buttons.first?.title == "Don't Upload",
                   "the first-use sheet says it uploads this repository's source code to the person's own boat.dev account, warns about secrets in untracked files, says where the source stays, and defaults to Don't Upload")
            expect(RemoteBuilder.script.contains("boat new") && RemoteBuilder.script.contains("sdkmanager") && RemoteBuilder.makeAlert().informativeText.contains("runs nothing"), "Prepare remote builder shows its steps and script, and says it runs nothing")
            let pb = NSPasteboard(name: NSPasteboard.Name("greenroom-recipes-check-" + UUID().uuidString))
            RemoteBuilder.copy(to: pb)
            expect(pb.string(forType: .string) == RemoteBuilder.script, "Copy Script copies the script")
            pb.releaseGlobally()

            // The tree to upload: a committed file edited, a tracked file deleted, an untracked file, ignored ones.
            let w = worktree("b")
            write(w.appendingPathComponent("README.md"), "edited after the commit\n")
            try? fm.removeItem(at: w.appendingPathComponent("old.txt"))
            write(w.appendingPathComponent("notes/new.txt"), "untracked\n")
            write(w.appendingPathComponent("ignored.log"), "secret\n")
            for secret in [".env", "keystore.properties", "upload.jks", "id_rsa_deploy", "local.properties"] { write(w.appendingPathComponent(secret), "top secret\n") }
            let nested = w.appendingPathComponent("nested", isDirectory: true)
            write(nested.appendingPathComponent("inside.txt"), "a nested repository's file\n")
            write(nested.appendingPathComponent("ignored-in-nested.key"), "private\n")
            _ = git(["init", "-q", "-b", "main"], in: nested); _ = git(["add", "inside.txt"], in: nested); _ = git(["commit", "-q", "-m", "n"], in: nested)
            try? fm.createSymbolicLink(atPath: w.appendingPathComponent("link-out").path, withDestinationPath: "/etc/hosts")
            try? fm.createSymbolicLink(atPath: w.appendingPathComponent("link-in").path, withDestinationPath: "README.md")
            write(w.appendingPathComponent("build/junk.bin"), "junk\n")
            sessions.refresh()
            _ = await wait("b to be edited", 20) { row("b")?.dirty == true }
            boatReset()
            setWS { $0.remote = RemoteSettings(); $0.remote.sandbox = "sbx-1" }
            // Without the stored yes nothing runs.
            var refused = ""
            let noJob = q.start(row("b")!, workspace: ws(), recipeName: "remote", store: store, error: { refused = $0 })
            expect(noJob == nil && refused.contains("has not been allowed") && refused.contains("source code") && boatCalls().isEmpty && ghCalls().allSatisfy { !$0.contains("boat") },
                   "without the stored yes the queue starts nothing and boat is never run (\(refused))")
            let bare = RecipeRun(recipe: Recipe.builtIn("remote")!, job: RecipeJob(worktree: w, repo: repo, ref: "feat-b", sha: "x", dirty: true, module: "", variant: "debug",
                                                                               out: base.appendingPathComponent("bare-out/app.apk"), extra: ["GREENROOM_REMOTE_SANDBOX": "sbx-1"]))
            let bareOutcome: RecipeOutcome = await withCheckedContinuation { c in bare.start { c.resume(returning: $0) } }
            var bareWhy = ""
            if case .failed(let x) = bareOutcome { bareWhy = x }
            expect(bareWhy.contains("have not allowed") && boatCalls().isEmpty, "the script itself refuses without the yes, before any boat call (\(bareWhy))")
            sessions.setRemoteConsent(true, forRoot: repo.resolvingSymlinksInPath().path)
            expect(SessionStore(root: store.root).loadWorkspaces().first?.remote.consent == true, "the yes is stored with the workspace")

            // A build: the upload, the streamed log, the APK, the sandbox stopped.
            var arrivals: [(String, Date)] = []
            q.onLine = { _, line in arrivals.append((line, Date())) }
            let rj1 = await build(row("b"), "remote", 120)
            q.onLine = nil
            var rb: Build?
            if case .built(let x)? = rj1?.state { rb = x }
            expect(rb?.key == remoteKey && rb?.source == .remote && rb?.sha == row("b")?.head && rb?.dirty == true, "the remote build's APK came back as a Build (\(failure(rj1)))")
            let src = boatState.appendingPathComponent("box/sbx-1/home/user/greenroom/src", isDirectory: true)
            func has(_ p: String) -> Bool { fm.fileExists(atPath: src.appendingPathComponent(p).path) }
            let readme = (try? String(contentsOf: src.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
            expect(has("gradlew") && has("app/build.gradle.kts") && has(".gitignore") && readme == "edited after the commit\n" && !has("old.txt") && has("notes/new.txt") && !has("ignored.log") && !has("build/junk.bin")
                   && !has(".env") && !has("keystore.properties") && !has("upload.jks") && !has("id_rsa_deploy") && !has("local.properties")
                   && !has("nested") && !has("link-out") && has("link-in"),
                   "the upload held HEAD's files, the uncommitted edit and deletion and the untracked file, and not the ignored ones (README \(readme.debugDescription), old.txt \(has("old.txt")), ignored.log \(has("ignored.log")))")
            let upLog = (rj1?.lines ?? []).joined(separator: "\n")
            expect(upLog.contains("uploading") && upLog.contains("untracked file(s):") && upLog.contains("notes/new.txt")
                   && upLog.contains("left out, their names look like secrets") && upLog.contains(".env") && upLog.contains("upload.jks") && upLog.contains("local.properties")
                   && upLog.contains("skipped") && upLog.contains("nested/") && upLog.contains("link-out(symlink out of the tree)"),
                   "the log names the untracked files uploaded, the secret-looking ones left out, and the nested repository and outside symlink skipped")
            func at(_ text: String) -> Date? { arrivals.first { $0.0 == text }?.1 }
            if let t1 = at("step one"), let t2 = at("step two") {
                expect(t2.timeIntervalSince(t1) > 0.6, "the log streamed while it ran: step one and step two arrived \(String(format: "%.1f", t2.timeIntervalSince(t1))) s apart")
            } else { expect(false, "the log streamed (saw \(arrivals.map(\.0).suffix(5)))") }
            let calls1 = boatCalls()
            expect(calls1.first == "boat start sbx-1" && calls1.last == "boat stop sbx-1" && (try? String(contentsOf: boatState.appendingPathComponent("box/sbx-1/state"), encoding: .utf8)) == "stopped\n"
                   && calls1.contains { $0.hasPrefix("boat scp") && $0.contains("sbx-1:/home/user/greenroom/upload.tar") } && calls1.contains { $0.hasPrefix("boat exec sbx-1 --detach --cwd /home/user/greenroom") },
                   "the sandbox was resumed, the tree uploaded by boat scp, the build run detached, and the sandbox stopped at the end")

            // A failing build still stops the sandbox.
            boatReset(); setenv("CHECK_GRADLE", "fail", 1)
            let rj2 = await build(row("b"), "remote", 120)
            expect(failure(rj2).contains("boom") && (rj2?.lines.contains { $0.contains("remote build failed") } ?? false) && boatCalls().last == "boat stop sbx-1" && row("b")?.build?.key == remoteKey,
                   "a failing remote build: the reason is Gradle's, the sandbox is stopped, the last build stays (\(failure(rj2)))")

            // A cancel stops it too, even when the stop takes longer than the two seconds a cancel allows.
            boatReset(); setenv("CHECK_GRADLE", "sleep", 1); setenv("CHECK_BOAT_STOP_DELAY", "3", 1)
            let rj3 = q.start(row("b")!, workspace: ws(), recipeName: "remote", store: store)
            _ = await wait("the build to be running remotely", 90) { rj3?.lines.contains("sleeping") == true }
            let pidsFile = boatState.appendingPathComponent("box/sbx-1/pids")
            let remotePid = pid_t(((try? String(contentsOf: pidsFile, encoding: .utf8)) ?? "").split(separator: "\n").last.map(String.init) ?? "") ?? 0
            expect(alive(remotePid), "a long remote build runs detached (pid \(remotePid))")
            q.cancel(row("b")!.worktree.path)
            let cancelled = await wait("the cancel", 20) { rj3?.state == .cancelled }
            let stoppedAfter = await wait("the sandbox to be stopped after the cancel", 20) { (try? String(contentsOf: boatState.appendingPathComponent("box/sbx-1/state"), encoding: .utf8)) == "stopped\n" }
            expect(cancelled && stoppedAfter && !alive(remotePid) && boatCalls().last == "boat stop sbx-1", "cancel: the job is cancelled, and the sandbox was stopped afterwards (the stop took 3 s) and its build with it (cancelled \(cancelled), stopped \(stoppedAfter), build alive \(alive(remotePid)), calls \(boatCalls().suffix(3)), state \((try? String(contentsOf: boatState.appendingPathComponent("box/sbx-1/state"), encoding: .utf8)) ?? "none"), log tail \(rj3?.lines.suffix(3) ?? []))")

            // A template: a sandbox is made and its id printed; no sandbox and no template is a plain message.
            boatReset()
            setWS { $0.remote.sandbox = ""; $0.remote.template = "tmpl-1" }
            let rj4 = await build(row("b"), "remote", 120)
            expect(builtKey(rj4) == remoteKey && boatCalls().first == "boat new --snapshot tmpl-1" && boatCalls().last == "boat stop sbx-from-tmpl-1" && (rj4?.lines.contains { $0.contains("remote sandbox: sbx-from-tmpl-1") } ?? false),
                   "from a template: boat new --snapshot, the new id printed for the person to keep, the sandbox stopped (\(failure(rj4)))")
            expect(ws().remote.sandbox == "sbx-from-tmpl-1", "the sandbox made from the template is saved in the workspace's settings (\(ws().remote.sandbox))")
            boatReset()
            setWS { $0.remote.sandbox = ""; $0.remote.template = "" }
            let rj5 = await build(row("b"), "remote")
            expect(failure(rj5).contains("no sandbox is set") && boatCalls().isEmpty, "no sandbox and no template: a plain message, boat not run (\(failure(rj5)))")
            setWS { $0.remote.sandbox = "sbx-bad" }
            let rj6 = await build(row("b"), "remote")
            expect(failure(rj6).contains("could not resume the sandbox sbx-bad") && boatCalls().last == "boat stop sbx-bad", "a sandbox that cannot be resumed: a plain message, and a stop is still asked for (\(failure(rj6)))")
            LoginEnvironment.override = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            boatReset()
            let rj7 = await build(row("b"), "remote")
            expect(failure(rj7).contains("needs the boat CLI") && boatCalls().isEmpty, "boat missing: a plain message (\(failure(rj7)))")
            LoginEnvironment.override = standIns
            setWS { $0.remote.sandbox = "sbx-1"; $0.remote.template = "" }

            // Module and variant are checked before they reach a remote command.
            boatReset()
            setWS { $0.module = "app;touch pwned" }
            let rj8 = await build(row("b"), "remote")
            expect(failure(rj8).contains("may not carry") && boatCalls().isEmpty, "a module with shell characters is refused before any boat call (\(failure(rj8)))")
            setWS { $0.module = nil; $0.variant = "debug && echo" }
            let rj9 = await build(row("b"), "remote")
            expect(failure(rj9).contains("may not carry") && boatCalls().isEmpty, "so is a variant (\(failure(rj9)))")
            setWS { $0.variant = "debug" }

            // Polling has a limit, and a sandbox that went away is noticed; both stop it.
            boatReset(); setenv("CHECK_GRADLE", "sleep", 1)
            setenv("GREENROOM_REMOTE_WAIT", "4", 1)
            let rj10 = await build(row("b"), "remote", 120)
            unsetenv("GREENROOM_REMOTE_WAIT")
            expect(failure(rj10).contains("did not finish within 4 seconds") && boatCalls().last == "boat stop sbx-1", "a remote build that never finishes is given up on at the limit, and the sandbox is stopped (\(failure(rj10)))")
            boatReset(); setenv("CHECK_GRADLE", "sleep", 1)
            let rj11 = q.start(row("b")!, workspace: ws(), recipeName: "remote", store: store)
            _ = await wait("the remote build to run", 90) { rj11?.lines.contains("sleeping") == true }
            try? "stopped\n".write(to: boatState.appendingPathComponent("box/sbx-1/state"), atomically: true, encoding: .utf8)   // the sandbox goes away
            _ = await wait("the build to notice", 60) { rj11?.isActive == false }
            expect(failure(rj11).contains("lost contact with the sandbox sbx-1") && boatCalls().last == "boat stop sbx-1", "a sandbox that went away is noticed and the run fails (\(failure(rj11)))")

            // The 30-minute limit (here 8 s) and the app quitting send SIGTERM first: the sandbox is stopped, even by a slow stop.
            boatReset(); setenv("CHECK_GRADLE", "sleep", 1); setenv("CHECK_BOAT_STOP_DELAY", "1", 1)
            let limited = RecipeRun(recipe: Recipe.builtIn("remote")!, job: RecipeJob(worktree: worktree("b"), repo: repo, ref: "feat-b", sha: "x", dirty: true, module: "", variant: "debug",
                                                                                    out: base.appendingPathComponent("limited-out/app.apk"), extra: ["GREENROOM_REMOTE_CONSENT": "1", "GREENROOM_REMOTE_SANDBOX": "sbx-1"]))
            limited.timeout = 8
            let limitedAt = Date()
            let limitedOutcome: RecipeOutcome = await withCheckedContinuation { c in limited.start { c.resume(returning: $0) } }
            var limitedWhy = ""
            if case .failed(let x) = limitedOutcome { limitedWhy = x }
            expect(limitedWhy.contains("longer than") && (try? String(contentsOf: boatState.appendingPathComponent("box/sbx-1/state"), encoding: .utf8)) == "stopped\n" && boatCalls().last == "boat stop sbx-1" && Date().timeIntervalSince(limitedAt) < 40,
                   "the time limit sends SIGTERM first: the remote recipe stopped its sandbox before it ended (\(limitedWhy))")
            boatReset(); setenv("CHECK_GRADLE", "sleep", 1); setenv("CHECK_BOAT_STOP_DELAY", "1", 1)
            let rj12 = q.start(row("b")!, workspace: ws(), recipeName: "remote", store: store)
            _ = await wait("the remote build to run", 90) { rj12?.lines.contains("sleeping") == true }
            q.terminateAll()   // what applicationWillTerminate calls: returns once the recipe has cleaned up
            expect((try? String(contentsOf: boatState.appendingPathComponent("box/sbx-1/state"), encoding: .utf8)) == "stopped\n" && boatCalls().last == "boat stop sbx-1",
                   "quitting the app sends SIGTERM first and waits: the sandbox is stopped when terminateAll returns")
            _ = await wait("the quit build to settle", 20) { rj12?.isActive == false }

            // A run killed without cleanup leaves its sandbox and folder in remote-state: the launch sweep, and the next run, deal with it.
            func stateFile() -> URL { store.root.appendingPathComponent("sessions/work/\(row("b")!.slot)/remote-state") }
            @MainActor func leaveOne() async -> RemoteLeftovers.Record? {
                boatReset(); setenv("CHECK_GRADLE", "sleep", 1)
                let j = q.start(row("b")!, workspace: ws(), recipeName: "remote", store: store)
                _ = await wait("the remote build to run", 90) { j?.lines.contains("sleeping") == true }
                let rec = (try? String(contentsOf: stateFile(), encoding: .utf8)).map { RemoteLeftovers.parse($0) }
                if let pid = j?.run?.pid { killpg(pid, SIGKILL) }       // no trap runs
                _ = await wait("the killed run to end", 30) { j?.isActive == false }
                return rec
            }
            let left = await leaveOne()
            let running = (try? String(contentsOf: boatState.appendingPathComponent("box/sbx-1/state"), encoding: .utf8)) == "running\n"
            expect(left?.sandbox == "sbx-1" && left?.tmp.contains("greenroom-remote.") == true && !(left?.root ?? "").isEmpty && fm.fileExists(atPath: stateFile().path) && running
                   && fm.fileExists(atPath: left?.tmp ?? "/nonexistent"), "a killed run leaves its sandbox running and its folder, and remote-state names both (\(left.map { "\($0)" } ?? "none"))")
            let callsBefore = boatCalls().count
            setWS { $0.remote.consent = false }
            _ = await RemoteLeftovers.sweep(workspaces: sessions.workspaces, store: store)
            expect(boatCalls().count == callsBefore && fm.fileExists(atPath: stateFile().path), "the launch sweep does nothing, and runs no boat, for a workspace that has not allowed the remote recipe")
            setWS { $0.remote.consent = true }
            let said = await RemoteLeftovers.sweep(workspaces: sessions.workspaces, store: store)
            expect(boatCalls().last == "boat stop sbx-1" && !fm.fileExists(atPath: stateFile().path) && !fm.fileExists(atPath: left?.tmp ?? "") && said.count == 2
                   && (try? String(contentsOf: boatState.appendingPathComponent("box/sbx-1/state"), encoding: .utf8)) == "stopped\n", "with the yes, the launch sweep stops the sandbox and removes the folder and the state file (\(said))")
            let left2 = await leaveOne()
            unsetenv("CHECK_GRADLE")
            let rj13 = await build(row("b"), "remote", 120)
            expect(left2 != nil && builtKey(rj13) == remoteKey && (rj13?.lines.contains { $0.contains("sbx-1, which an earlier run left running") } ?? false) && !fm.fileExists(atPath: stateFile().path),
                   "the next run stops what the killed one left, then builds (\(failure(rj13)))")

            // The row's CI note follows the upstream's commit when a fetch moves it.
            CIBehind.maxAge = 0.5
            var n1: String?
            let bRow = row("b")!
            _ = await wait("the first note", 15) { n1 = CIBehind.note(for: bRow, store: store) {}; return n1 != nil }
            let aHead = gitOut(["rev-parse", "feat-a"], in: repo)
            _ = git(["update-ref", "refs/remotes/origin/main", aHead], in: repo)
            var n2: String?
            _ = await wait("the moved upstream to show", 15) { n2 = CIBehind.note(for: bRow, store: store) {}; return n2 != nil && n2 != n1 }
            expect(n1 == "CI has \(originShort), without your edits" && n2 == "pushed: \(String(aHead.prefix(7))), without your edits",
                   "the note follows the upstream after a fetch, and says only \"pushed\" for a commit with no known CI build (\(n1 ?? "none") then \(n2 ?? "none"))")
            _ = git(["update-ref", "refs/remotes/origin/main", mainSha], in: repo)
            CIBehind.maxAge = 20

            LoginEnvironment.override = nil
            setWS { $0.remote.consent = nil }
            finish()
        }
    }
}
