import AppKit

// `Greenroom --smoke APK` (CI and scripts/bundle.sh --check): runs the APK headless in the bundled engine until its
// first frame, prints the engine's output, and exits with its status. No window, no app.
let arguments = CommandLine.arguments

// `Greenroom --mcp`: the agent interface on stdin and stdout, passed on to the running app (AgentShim).
if arguments.contains("--mcp") { AgentShim.run() }
// `Greenroom --connect-check DIR`: Connect Claude Code against a stand-in `claude` (ConnectCheck).
if let i = arguments.firstIndex(of: "--connect-check"), i + 1 < arguments.count { ConnectCheck.run(dir: URL(fileURLWithPath: arguments[i + 1])) }
// `Greenroom --t3-check DIR`: T3 Code's threads through a stand-in `t3` (T3Check).
if let i = arguments.firstIndex(of: "--t3-check"), i + 1 < arguments.count { T3Check.run(dir: URL(fileURLWithPath: arguments[i + 1])) }
// `Greenroom --t3-live REPO`: one read of your own T3 Code's threads for REPO, printed.
if let i = arguments.firstIndex(of: "--t3-live"), i + 1 < arguments.count { T3Check.live(repo: URL(fileURLWithPath: arguments[i + 1])) }
// `Greenroom --map-contract-check [DIR]`: map history's stored form and its fixtures (MapFixtures).
if let i = arguments.firstIndex(of: "--map-contract-check") {
    MapContractCheck.run(dir: i + 1 < arguments.count ? URL(fileURLWithPath: arguments[i + 1]) : nil)
}
// `Greenroom --map-layout-check`: the map's layout (MapLayout) on the fixtures.
if arguments.contains("--map-layout-check") { MapLayoutCheck.run() }
if let i = arguments.firstIndex(of: "--smoke"), i + 1 < arguments.count {
    let apk = URL(fileURLWithPath: arguments[i + 1])
    do {
        var status: Int32 = 1
        let instance = try Engine.shared.launch(apk: apk, options: ["--headless", "--exit-after-first-frame"])
        instance.process.waitUntilExit()
        status = instance.process.terminationStatus
        let log = (try? String(contentsOf: instance.log, encoding: .utf8)) ?? ""
        print(log, terminator: "")
        print("[greenroom] smoke: engine \(Engine.shared.version) exit \(status)")
        Engine.shared.stopAll()
        exit(status)
    } catch {
        FileHandle.standardError.write(Data("[greenroom] smoke failed: \(error.localizedDescription)\n".utf8))
        exit(2)
    }
}

// `Greenroom --smoke-stream APK`: the workbench's path without a window. Starts the APK headless, connects the
// control channel and the screen stream, decodes frames for a few seconds while tapping and typing, and reports.
if let i = arguments.firstIndex(of: "--smoke-stream"), i + 1 < arguments.count {
    do {
        let sim = try Engine.shared.open(apk: URL(fileURLWithPath: arguments[i + 1]))
        var samples = 0, firstFrame: Double?
        let started = Date()
        sim.onSample = { _ in samples += 1; if firstFrame == nil { firstFrame = Date().timeIntervalSince(started) } }
        var stats = "", activity = ""
        func finish() {
            let size = sim.deviceSize
            print("[greenroom] smoke-stream: \(samples) frames decoded, first after \(String(format: "%.2f", firstFrame ?? -1)) s, device \(Int(size.width))x\(Int(size.height)), state \(sim.state)")
            print("[greenroom] activity: \(activity)")
            print("[greenroom] control channel: \(sim.isPrivate ? "token required" : "open to local programs (this engine has no --control-token-file)")")
            print("[greenroom] stats: \(stats.prefix(160))")
            let ok = samples > 0 && size.width > 0 && !activity.isEmpty && !activity.hasPrefix("error")
            if !ok, let log = try? String(contentsOf: sim.log, encoding: .utf8) {
                print("[greenroom] engine log, last lines:\n" + log.split(separator: "\n").suffix(25).joined(separator: "\n"))
            }
            Engine.shared.stopAll()
            exit(ok ? 0 : 1)
        }
        // Wait for the first frame (a cold engine on a slow machine takes a while), then drive the app briefly.
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            waited += 0.25
            let ended: Bool = { if case .ended = sim.state { return true }; return false }()
            guard firstFrame != nil || waited >= 120 || ended else { return }
            timer.invalidate()
            guard firstFrame != nil else { finish(); return }
            sim.send("tap 411 600")
            sim.type("hi there")
            sim.send("activity") { activity = $0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sim.send("stats") { stats = $0 } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }
        }
        RunLoop.main.run()
    } catch {
        FileHandle.standardError.write(Data("[greenroom] smoke-stream failed: \(error.localizedDescription)\n".utf8))
        exit(2)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
