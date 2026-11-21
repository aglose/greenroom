import AppKit

/// `Greenroom --scripts-check DIR APK`: per-device app data, variables and scripts against real simulators, with
/// the engine's state in DIR/scripts-check/engine-state and variables in memory (never the Keychain). One
/// `[greenroom] scripts: PASS|FAIL ...` line per expectation, then `done` or `failed`.
enum ScriptsCheck {
    static func run(workbench wb: Workbench, dir: URL, apk: URL) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            func say(_ s: String) { fputs("[greenroom] scripts: \(s)\n", stdout); fflush(stdout) }
            func expect(_ what: String, _ ok: Bool, _ detail: String = "") {
                say((ok ? "PASS " : "FAIL ") + what + (ok || detail.isEmpty ? "" : " (\(detail))"))
                if !ok { failures += 1 }
            }
            @MainActor func wait(_ what: String, _ seconds: Double = 180, _ cond: @MainActor () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 200_000_000) }
                say("timed out waiting for \(what)")
                return false
            }
            @MainActor func finish() { say(failures == 0 ? "done" : "failed (\(failures))"); NSApp.terminate(nil) }
            func ready(_ s: Simulator?) -> Bool { s?.state == .running && (s?.framesShown ?? 0) > 0 }
            let data = Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true)
            func slots() -> [String] {
                ((try? fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []).flatMap { pkg in
                    ((try? fm.contentsOfDirectory(atPath: pkg.path)) ?? []).filter { !$0.hasSuffix(".device") }
                }
            }
            func slot(_ s: Simulator) -> String? { DevHooks.value("--data-slots", in: s.options) }

            // 1. A plain launch runs on the phone's own slot.
            guard let first = wb.open(apk, remember: false), await wait("the first frame", 240, { ready(first) }) else { expect("the APK opens", false); return finish() }
            expect("a plain launch uses the phone's data slot", slot(first) == "gdphone", first.options.joined(separator: " "))
            expect("... which the engine keeps as gdphone-0", slots().contains("gdphone-0"), slots().joined(separator: ","))

            // 2. Variables (in memory here) reach a script; a secret one is masked in what comes back.
            let secret = "hunter2-\(Int.random(in: 1000...9999))"
            do {
                try Variables.shared.set(.init(name: "GR_CHECK_SECRET", value: secret, secret: true))
                try Variables.shared.set(.init(name: "GR_CHECK_PLAIN", value: "hello", secret: false))
            } catch { expect("variables are stored", false, error.localizedDescription) }
            expect("a reserved name is refused", (try? Variables.shared.set(.init(name: "GREENROOM_X", value: "1", secret: false))) == nil)
            expect("PATH is refused", !Variables.isValid("PATH") && Variables.isValid("LOGIN_EMAIL"))

            let scripts = dir.appendingPathComponent("scripts-check/scripts", isDirectory: true)
            try? fm.createDirectory(at: scripts, withIntermediateDirectories: true)
            func write(_ name: String, _ body: String) -> Scripts.Script {
                let url = scripts.appendingPathComponent(name)
                try? fm.removeItem(at: url)
                fm.createFile(atPath: url.path, contents: Data(("#!/bin/bash\nset -eu\n" + body).utf8), attributes: [.posixPermissions: 0o700])
                return Scripts.Script(url: url, fromWorktree: false)
            }
            func runIt(_ s: Scripts.Script, on sim: Simulator, timeout: TimeInterval = 60) async -> ScriptRun.Outcome? {
                guard let r = ScriptRun(script: s, sim: sim, worktree: nil) else { return nil }
                return await Task.detached { r.runSync(timeout: timeout) }.value
            }

            let good = write("good.sh", """
                echo "plain=$GR_CHECK_PLAIN secret=$GR_CHECK_SECRET device=$GREENROOM_DEVICE"
                gr ping
                gr wait "FAB clicks" 30
                gr type "typed by gr"
                echo "on screen: $(gr nodes | cut -c1-60)"
                """)
            if let o = await runIt(good, on: first) {
                let out = o.output.joined(separator: "\n")
                expect("a script runs to exit 0", o.code == 0, out)
                expect("... with the variables", out.contains("plain=hello") && out.contains("device=phone"), out)
                expect("... a secret masked in its output", out.contains("secret=••••") && !out.contains(secret), out)
                expect("... and gr reaches the simulator", out.contains("on screen: [") && !out.contains("gr: "), out)
            } else { expect("a script starts", false) }

            let bad = write("bad.sh", "gr wait \"NOT ON ANY SCREEN\" 2\n")
            if let o = await runIt(bad, on: first) {
                expect("a script whose wait fails exits non-zero", (o.code ?? 0) != 0, o.output.joined(separator: "\n"))
                expect("... and says why", o.output.contains { $0.contains("did not appear within 2 s") }, o.output.joined(separator: "\n"))
            } else { expect("the failing script starts", false) }

            // 3. Approvals follow the file's contents.
            Scripts.approve(good, true)
            expect("an allowed script may be run by agents", Scripts.approval(good) == .yes)
            _ = write("good.sh", "echo changed\n")
            expect("... and not once it has changed", Scripts.approval(good) == .changed)
            Scripts.approve(good, false)
            expect("... nor once disallowed", Scripts.approval(good) == .no)
            expect("a worktree's script is never an agent's", Scripts.approval(Scripts.Script(url: good.url, fromWorktree: true)) == .no)

            // 4. A second phone of the same APK while the first runs starts on a clone, gone once it has exited.
            guard let second = wb.openBeside(apk: apk, device: "phone"), await wait("the second phone", 240, { ready(second) }) else {
                expect("a second phone opens", false); return finish()
            }
            let clone = slot(second) ?? ""
            expect("a second phone runs on a clone of the phone's data", clone.hasPrefix("gc"), second.options.joined(separator: " "))
            expect("... whose folder exists", slots().contains(clone + "-0"), slots().joined(separator: ","))

            // 5. Another device has its own slot.
            guard let tablet = wb.openBeside(apk: apk, device: "tablet"), await wait("the tablet", 240, { ready(tablet) }) else {
                expect("a tablet opens", false); return finish()
            }
            expect("a tablet uses its own slot", slot(tablet) == "gdtablet", tablet.options.joined(separator: " "))

            Engine.shared.close(second)
            let gone = await wait("the clone's removal", 40, { !slots().contains(clone + "-0") })
            expect("the clone's data is removed after its simulator exits", gone, slots().joined(separator: ","))
            expect("... and the phone's own data stays", slots().contains("gdphone-0"))

            // 6. A fresh launch never touches the device's data.
            guard let fresh = wb.open(apk, remember: false, options: ["--fresh"]), await wait("the fresh launch", 240, { ready(fresh) }) else {
                expect("a fresh launch opens", false); return finish()
            }
            expect("a fresh launch runs on a throwaway slot", slot(fresh)?.hasPrefix("gf") == true, fresh.options.joined(separator: " "))

            Variables.shared.remove("GR_CHECK_SECRET")
            Variables.shared.remove("GR_CHECK_PLAIN")
            expect("variables are removed", Variables.shared.names().isEmpty)
            finish()
        }
    }
}
