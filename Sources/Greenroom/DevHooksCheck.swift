import AppKit

/// `Greenroom --devhooks-check DIR APK`: each developer hook run against a real simulator, one
/// `[greenroom] devhooks: ...` line per step, the window captured after the visible ones.
enum DevHooksCheck {
    static func run(workbench wb: Workbench, dir: URL, apk: URL, capture: @escaping (URL) -> Void) {
        Task { @MainActor in
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let hooks = DevHooks.shared
            func say(_ s: String) { fputs("[greenroom] devhooks: \(s)\n", stdout); fflush(stdout) }
            @MainActor func wait(_ what: String, _ seconds: Double = 180, _ cond: @MainActor () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 200_000_000) }
                say("timed out waiting for \(what)")
                return false
            }
            func ready(_ s: Simulator?) -> Bool { s?.state == .running && (s?.framesShown ?? 0) > 0 }
            @MainActor func finish(_ ok: Bool) { say(ok ? "done" : "failed"); NSApp.terminate(nil) }

            // 1. Open.
            guard let first = wb.open(apk, remember: false) else { return finish(false) }
            guard await wait("the first frame", 180, { ready(first) }) else { return finish(false) }
            say("opened \(first.name), running")

            // 2. adb.
            var sim = first
            hooks.connectADB(sim)
            guard await wait("the relaunch with adb", 120, { wb.selected !== sim && ready(wb.selected) }), let withADB = wb.selected,
                  await wait("the adb port", 60, { hooks.adbPort(of: withADB) != nil }), let port = hooks.adbPort(of: withADB) else { return finish(false) }
            say("adb port \(port); old simulator ended: \(!first.isAlive); simulators on stage: \(Engine.shared.simulators.count)")
            sim = withADB
            try? await Task.sleep(nanoseconds: 800_000_000)
            capture(dir.appendingPathComponent("d1-adb.png"))
            let adb = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/adb" }.first { fm.isExecutableFile(atPath: $0) }
            if let adb {
                func tool(_ args: [String]) async -> String {
                    await Task.detached {
                        let p = Process(); let pipe = Pipe()
                        p.executableURL = URL(fileURLWithPath: adb); p.arguments = args
                        p.standardOutput = pipe; p.standardError = pipe
                        guard (try? p.run()) != nil else { return "could not run adb" }
                        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: killer)
                        p.waitUntilExit(); killer.cancel()
                        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    }.value
                }
                say("adb connect: \(await tool(["connect", "localhost:\(port)"]))")
                say("sys.boot_completed = \(await tool(["-s", "localhost:\(port)", "shell", "getprop", "sys.boot_completed"]))")
                say("adb disconnect: \(await tool(["disconnect", "localhost:\(port)"]))")
            } else {
                say("adb is not on PATH: connect/getprop skipped")
            }

            // 3. Debugger.
            hooks.attachDebugger(sim)
            guard await wait("the relaunch with a debugger", 120, { wb.selected !== sim && ready(wb.selected) }), let withDebug = wb.selected,
                  let debugPort = DevHooks.debugPort(of: withDebug) else { return finish(false) }
            sim = withDebug
            say("debug port \(debugPort); something listens: \(DevHooks.listens(on: debugPort)); adb kept: \(DevHooks.hasADB(sim))")
            try? await Task.sleep(nanoseconds: 800_000_000)
            capture(dir.appendingPathComponent("d2-debug.png"))

            // 4. Watch a folder holding a copy of the APK.
            let build = dir.appendingPathComponent("build", isDirectory: true)
            try? fm.removeItem(at: build)
            try? fm.createDirectory(at: build, withIntermediateDirectories: true)
            let copy = build.appendingPathComponent(apk.lastPathComponent)
            try? fm.copyItem(at: apk, to: copy)
            hooks.watch(folder: build, name: apk.lastPathComponent)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let before = sim
            try? fm.removeItem(at: copy)
            try? fm.copyItem(at: apk, to: copy)   // a new build lands
            let t0 = Date()
            guard await wait("the reload", 120, { wb.selected !== before && ready(wb.selected) && wb.selected?.apk.path == copy.path }), let reloaded = wb.selected else { return finish(false) }
            say("reloaded after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s: \(reloaded.name) from the build folder, options kept: \(reloaded.options == before.options), old ended: \(!before.isAlive), on stage: \(Engine.shared.simulators.count)")
            sim = reloaded
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            capture(dir.appendingPathComponent("d3-watch.png"))
            hooks.stopWatch()

            // 5. Record traffic to a HAR.
            let har = dir.appendingPathComponent("check.har")
            try? fm.removeItem(at: har)
            let beforeRecord = sim
            hooks.record(sim, to: har)
            guard await wait("the relaunch that records", 120, { wb.selected !== beforeRecord && ready(wb.selected) }), let recording = wb.selected else { return finish(false) }
            say("recording to \(har.lastPathComponent): \(DevHooks.har(of: recording)?.mode ?? "no mode")")
            recording.send("open apksim://network?url=https://www.apple.com/") { say("open: \($0)") }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            recording.send("tap-text Get") { say("tap Get: \($0)") }
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            recording.send("network save") { say("network save: \($0)") }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            capture(dir.appendingPathComponent("d4-record.png"))
            var report = ""
            hooks.onHarReport = { report = $0 }
            wb.closeSelected(nil)
            guard await wait("the HAR report", 60, { !report.isEmpty }) else { return finish(false) }
            let size = (try? fm.attributesOfItem(atPath: har.path)[.size] as? Int) ?? 0
            say("\(report); file \(size) bytes")
            let ok = size > 0 && report.hasPrefix("Saved") && !report.contains(": 0 request")
            finish(ok)
        }
    }
}
