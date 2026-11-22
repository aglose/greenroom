import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var workbench: Workbench!
    /// Device > Run Script's items (made before the workbench, so it asks for it when the menu opens).
    private lazy var scriptsMenu = ScriptsMenu { [weak self] in self?.workbench }

    func applicationDidFinishLaunching(_ note: Notification) {
        AppIcon.apply()
        Updates.shared.start()
        Reports.shared.start()
        buildMenus()
        workbench = Workbench()
        workbench.window.makeKeyAndOrderFront(nil)
        let early = openedEarly; openedEarly = []
        if !early.isEmpty { application(NSApp, open: early) }
        if !CommandLine.arguments.contains("--background") { NSApp.activate() }
        startAgentServer()
        // `kill` (and a script that started the app) quits it as the menu would: simulators stopped, nothing left behind.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term
        ReportsCheck.runIfAsked()
        askAboutReportsIfDue()
        windowShotIfAsked()
        compareCheckIfAsked()
        inspectCheckIfAsked()
        recordCheckIfAsked()
        stageCheckIfAsked()
        networkCheckIfAsked()
        testsCheckIfAsked()
        motionCheckIfAsked()
        paletteCheckIfAsked()
        mockCheckIfAsked()
        extrasCheckIfAsked()
        devHooksCheckIfAsked()
        sessionsCheckIfAsked()
        scriptsCheckIfAsked()
        buildsCheckIfAsked()
        claudeCheckIfAsked()
        recorderCheckIfAsked()
        recipesCheckIfAsked()
        evidenceCheckIfAsked()
        changesCheckIfAsked()
        historyLiveIfAsked()
        replayCheckIfAsked()
        SnapshotCheck.runIfAsked(workbench)
        mapCheckIfAsked()
        mapSignInCheckIfAsked()
        arrangeCheckIfAsked()
        PrivacyCheck.runIfAsked(self)   // scripts/network-check.sh
        matrixCheckIfAsked()
        PerfCheck.runIfAsked(self)   // `--snapshots-check`, SnapshotCheck.swift
    }

    /// `Greenroom --mock-check DIR APK`: the test app fetches a page; the request is failed from the network pane and
    /// fetched again, then mocked with a short body and fetched again. What the app shows is printed each time.
    private func mockCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--mock-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.window.setContentSize(NSSize(width: 1600, height: 1000))
        workbench.window.center()
        guard let sim = workbench.open(URL(fileURLWithPath: args[i + 2]), remember: false) else { return }
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func shows(_ label: String, then: @escaping () -> Void) {
            sim.send("nodes") { nodes in
                let line = ScreenNode.parse(nodes).map(\.label).first { $0.hasPrefix("get okhttp") } ?? "(not found)"
                let last = sim.activity.requests.last { $0.url.contains("apple.com") && $0.method == "GET" }
                print("[greenroom] mock \(label): app shows '\(line)'; last request \(last.map { "\($0.status) \($0.mocked ? "by a rule" : "from the server")" } ?? "none")")
                then()
            }
        }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
            waited += 0.5
            guard sim.framesShown > 2 || waited > 90 else { return }
            timer.invalidate()
            sim.send("open apksim://network?url=https://www.apple.com/")
            after(3) { sim.send("tap-text Get") }
            after(8) { [self] in
                workbench.setShowingNetwork(true)
                shows("1 real") { [self] in
                    workbench.network.debugSelect(containing: "apple.com")
                    after(1.5) { [self] in
                        workbench.network.debugFail()
                        after(1.5) { sim.send("tap-text Get") }
                        after(6) { [self] in
                            shows("2 failed") { [self] in
                                captureWindow(to: dir.appendingPathComponent("1-failed.png"))
                                print("[greenroom] rules: " + workbench.network.rules.map { "\($0["method"] ?? "") \($0["pattern"] ?? "") \($0["status"] ?? "") hits \($0["hits"] ?? "")" }.joined(separator: " | "))
                                sim.send("network rule clear") { [self] _ in
                                    workbench.network.debugSelect(containing: "apple.com")
                                    after(1.5) { [self] in
                                        workbench.network.debugMock(body: "hello from Greenroom")
                                        after(1.5) { sim.send("tap-text Get") }
                                        after(6) { [self] in
                                            shows("3 mocked") { [self] in
                                                captureWindow(to: dir.appendingPathComponent("2-mocked.png"))
                                                NSApp.terminate(nil)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `Greenroom --palette-check DIR APK`: ⌘K opened over a running app; a few searches typed (their top results
    /// printed), then "dark" run from it.
    private func paletteCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--palette-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.window.setContentSize(NSSize(width: 1440, height: 900))
        workbench.window.center()
        guard let sim = workbench.open(URL(fileURLWithPath: args[i + 2]), remember: false) else { return }
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
            waited += 0.5
            guard sim.framesShown > 2 || waited > 90 else { return }
            timer.invalidate()
            after(2) { [self] in
                workbench.showPalette(nil)
                after(1) { [self] in
                    captureWindow(to: dir.appendingPathComponent("1-open.png"))
                    for q in ["dark", "dkm", "fr", "3g", "rot", "net", "fold", "kill"] {
                        workbench.palette.search(q)
                        print("[greenroom] palette '\(q)': " + workbench.palette.results.prefix(4).joined(separator: " | "))
                    }
                    workbench.palette.search("dark")
                    after(0.6) { [self] in
                        captureWindow(to: dir.appendingPathComponent("2-dark.png"))
                        workbench.palette.runSelected()
                        after(3) { [self] in
                            sim.send("config") { answer in
                                print("[greenroom] after running 'dark': palette shown \(self.workbench.showingPalette), night \(answer.contains("night") && !answer.contains("nonight") ? "yes" : "no?"), toast '\(self.workbench.toast.text)'")
                                self.captureWindow(to: dir.appendingPathComponent("3-ran.png"))
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    /// `Greenroom --motion-check DIR APK` (run with GREENROOM_SLOW_MOTION=6): the window captured in the middle of
    /// each transition: empty, starting, a second device arriving, a rotation, a pane sliding in, a toast.
    private func motionCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--motion-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let apk = URL(fileURLWithPath: args[i + 2])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.window.setContentSize(NSSize(width: 1440, height: 900))
        workbench.window.center()
        let mid = Design.move / 2
        func shot(_ name: String) { captureWindow(to: dir.appendingPathComponent(name + ".png")) }
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        after(1) { [self] in
            shot("1-empty")
            guard let sim = workbench.open(apk, remember: false, options: ["--appearance", "dark"]) else { return }
            after(0.6) { shot("2-starting") }
            var waited = 0.0
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [self] timer in
                waited += 0.25
                guard sim.framesShown > 2 || waited > 90 else { return }
                timer.invalidate()
                after(Design.move + 1) { [self] in
                    shot("3-running")
                    workbench.openBeside(apk: apk, device: "pixel-10-pro-fold")
                    after(mid) { shot("4-second-arriving") }
                    after(Design.move + 12) { [self] in
                        shot("5-two")
                        workbench.rotate(nil)
                        after(1.2 + mid) { shot("6-rotating") }
                        after(1.2 + Design.move + 2) { [self] in
                            shot("7-rotated")
                            workbench.setShowingDevice(true)
                            workbench.toast.show("Screenshot copied, and saved as engine-testapp.png")
                            after(mid) { shot("8-pane-sliding") }
                            after(Design.move + 1) { shot("9-pane-open"); NSApp.terminate(nil) }
                        }
                    }
                }
            }
        }
    }

    /// `Greenroom --network-check DIR APK`: the test app's network screen makes a few requests (one to a host that
    /// answers, others that fail); the network pane and timeline are captured, then with a request picked.
    private func networkCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--network-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.window.setContentSize(NSSize(width: 1600, height: 1000))
        workbench.window.center()
        guard let sim = workbench.open(URL(fileURLWithPath: args[i + 2]), remember: false, options: ["--appearance", "dark"]) else { return }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
            waited += 0.5
            guard sim.framesShown > 0 || waited > 90 else { return }
            timer.invalidate()
            sim.send("open apksim://network?url=https://www.apple.com/")
            let taps = ["Get", "Get URL", "Fetch", "Fetch other"]
            for (n, t) in taps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(n) * 2) { sim.send("tap-text \(t)") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(taps.count) * 2 + 3) { [self] in
                workbench.setShowingNetwork(true)
                workbench.setShowingTimeline(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    let reqs = sim.activity.requests
                    print("[greenroom] network: \(reqs.count) requests: " + reqs.map { "\($0.method) \($0.shortURL.prefix(60)) \($0.status) \($0.ms)ms" }.joined(separator: " | "))
                    print("[greenroom] timeline: touches \(sim.activity.touches.count) frames \(sim.activity.frames.count) log marks \(sim.activity.logs.count)")
                    captureWindow(to: dir.appendingPathComponent("1-network-timeline.png"))
                    // The timeline's own layers on the stage colour, readable even with the screen locked.
                    if let l = workbench.timelineDock.layer {
                        let scale: CGFloat = 2, b = workbench.timelineDock.bounds
                        if let ctx = CGContext(data: nil, width: Int(b.width * scale), height: Int(b.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                            ctx.setFillColor(Design.stage.cgColor)
                            ctx.fill(CGRect(x: 0, y: 0, width: b.width * scale, height: b.height * scale))
                            ctx.scaleBy(x: scale, y: scale)
                            l.render(in: ctx)
                            if let img = ctx.makeImage() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("1b-timeline-layers.png")) }
                        }
                    }
                    if let first = reqs.first { workbench.debugScrub(to: first.start.addingTimeInterval(0.01)) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                        captureWindow(to: dir.appendingPathComponent("2-scrubbed.png"))
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    // MARK: Tests pane check

    /// `Greenroom --tests-check DIR APP.apk TEST.apk [CLASSFILTER]`: opens the Tests pane, runs, waits for the end and
    /// prints one summary line; the window is captured as it starts, while it runs, when it ends and with a failure picked.
    private func testsCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--tests-check"), i + 3 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.window.setContentSize(NSSize(width: 1500, height: 960))
        workbench.window.center()
        let pane = workbench.tests
        pane.setInputs(test: URL(fileURLWithPath: args[i + 3]), app: URL(fileURLWithPath: args[i + 2]), filter: i + 4 < args.count ? args[i + 4] : "")
        workbench.setShowingTests(true)
        var shotsTaken = 0
        pane.onFinish = { [self] run in
            let secs = String(format: "%.1f", run.elapsed)
            print("[greenroom] tests: \(run.passed) passed, \(run.failed) failed, \(run.ignored) ignored in \(secs) s")
            if let p = run.problem { print("[greenroom] engine said: \(p)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                captureWindow(to: dir.appendingPathComponent("3-done.png"))
                if let f = run.allTests.first(where: { $0.status == .failed }) {
                    pane.select(f.id)
                    print("[greenroom] picked \(f.id): bundle \(run.bundleFolder(for: f)?.path ?? "none"), movie \(run.movieFile(for: f)?.lastPathComponent ?? "none")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                        captureWindow(to: dir.appendingPathComponent("4-failure.png"))
                        NSApp.terminate(nil)
                    }
                } else { NSApp.terminate(nil) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            guard pane.start() else { print("[greenroom] tests: could not start"); NSApp.terminate(nil); return }
            captureWindow(to: dir.appendingPathComponent("1-start.png"))
            // Mid-run: the first moment some results are in and the run is still going.
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] t in
                guard let r = pane.run, r.isRunning else { if pane.run?.isRunning == false { t.invalidate() }; return }
                if r.done >= 3, shotsTaken == 0 { shotsTaken = 1; captureWindow(to: dir.appendingPathComponent("2-running.png")) }
            }
            // A hang must not hold the check for ever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 900) { print("[greenroom] tests: timed out"); NSApp.terminate(nil) }
        }
    }

    /// `Greenroom --stage-check DIR APK`: the stage with a phone, a foldable and a watch side by side, captured once
    /// all three show a picture, then with the log and the inspector open.
    private func stageCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--stage-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let apk = URL(fileURLWithPath: args[i + 2])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.window.setContentSize(NSSize(width: 1440, height: 900))
        workbench.window.center()
        captureWindow(to: dir.appendingPathComponent("0-empty.png"))
        guard workbench.open(apk, remember: false, options: ["--appearance", "dark"]) != nil else { return }
        workbench.openBeside(apk: apk, device: "pixel-10-pro-fold")
        workbench.openBeside(apk: apk, device: "watch")
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
            waited += 0.5
            let sims = Engine.shared.simulators
            guard sims.count == 3, sims.allSatisfy({ $0.framesShown > 0 }) || waited > 120 else { return }
            timer.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                captureWindow(to: dir.appendingPathComponent("1-three.png"))
                print("[greenroom] stage: " + sims.map { "\($0.name) \(Int($0.deviceSize.width))x\(Int($0.deviceSize.height)) frames \($0.framesShown)" }.joined(separator: ", "))
                workbench.setShowingLog(true)
                workbench.setMirror(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    captureWindow(to: dir.appendingPathComponent("2-log-mirror.png"))
                    workbench.setShowingLog(false)
                    workbench.setSideBySide(false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                        captureWindow(to: dir.appendingPathComponent("3-one.png"))
                        workbench.setShowingDevice(true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                            captureWindow(to: dir.appendingPathComponent("4-device.png"))
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
    }

    /// `Greenroom --visual-check DIR APK`: for looking at the workbench from a script. Opens the APK and writes
    /// pictures of the real window (as the window server composites it, video included) into DIR at each step:
    /// launch, a click, typing, dark appearance, rotated, tablet. Beside each, the engine's own pixels (`*-engine.png`).
    private func windowShotIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--visual-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.open(URL(fileURLWithPath: args[i + 2]), remember: false)
        try? FileManager.default.createDirectory(at: Engine.shared.screenshots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [self] timer in
            waited += 0.25
            guard let sim = Engine.shared.simulators.first else { return }
            guard sim.framesShown > 0 || waited > 90 else { return }
            timer.invalidate()
            let steps: [(String, Double, () -> Void)] = [
                ("1-launch", 5, {}),
                ("2-click", 2, { self.workbench.debugClick(atFraction: CGPoint(x: 0.5, y: 0.5)) }),
                ("2b-typed", 2, { self.workbench.debugType("typed in Greenroom") }),
                ("3-dark", 3, { self.workbench.appearance(nil) }),
                ("4-rotated", 3, { self.workbench.rotate(nil) }),
                ("5-tablet", 4, { self.workbench.rotate(nil); sim.send("device tablet") }),
                ("6-beside", 14, { sim.send("device phone"); self.workbench.openBeside(apk: sim.apk, device: "tablet") }),
                ("7-mirrored", 4, {
                    self.workbench.setMirror(true)
                    self.workbench.debugClick(atFraction: CGPoint(x: 0.5, y: 0.5))
                    self.workbench.debugType(" x2")
                }),
            ]
            var at = 0.0
            for (name, wait, action) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { action() }
                at += wait
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [self] in
                    captureWindow(to: dir.appendingPathComponent("\(name).png"))
                    sim.send("shot screenshots/vc-\(name).png") { _ in
                        let from = Engine.shared.screenshots.appendingPathComponent("vc-\(name).png")
                        let to = dir.appendingPathComponent("\(name)-engine.png")
                        try? FileManager.default.removeItem(at: to)
                        try? FileManager.default.moveItem(at: from, to: to)
                    }
                    for other in Engine.shared.simulators.dropFirst() {
                        other.send("stats") { print("[greenroom] \(name) (second): device \(Int(other.deviceSize.width))x\(Int(other.deviceSize.height)) \($0.split(separator: " ").filter { $0.hasPrefix("lastDown") }.joined())") }
                    }
                    sim.send("stats") { print("[greenroom] \(name): device \(Int(sim.deviceSize.width))x\(Int(sim.deviceSize.height)) frames \(sim.framesShown) \($0.split(separator: " ").filter { $0.hasPrefix("lastDown") || $0.hasPrefix("frames=") }.joined(separator: " "))") }
                }
                at += 0.6
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + at + 1) { NSApp.terminate(nil) }
        }
    }

    /// `Greenroom --compare-check DIR APK [X,Y]`: opens the APK twice in compare mode and captures the window while
    /// the two are the same, then after a tap at X,Y (device pixels) on the first one alone.
    private func compareCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--compare-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1]), apk = URL(fileURLWithPath: args[i + 2])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let base = workbench.open(apk, remember: false) else { return }
        var second: Simulator?
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [self] timer in
            waited += 0.25
            if second == nil, base.state == .running, base.framesShown > 0 {
                second = workbench.compare(with: apk)
                defaults_forgetRecent(apk)
            }
            guard let other = second, (other.state == .running && other.framesShown > 0) || waited > 120 else { return }
            timer.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [self] in
                captureWindow(to: dir.appendingPathComponent("c1-same.png"))
                print("[greenroom] c1: " + workbench.compareText.replacingOccurrences(of: "\n", with: " | "))
                workbench.setMirror(false)
                if i + 3 < args.count { base.send("tap " + args[i + 3].replacingOccurrences(of: ",", with: " ")) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [self] in
                captureWindow(to: dir.appendingPathComponent("c2-different.png"))
                print("[greenroom] c2: " + workbench.compareText.replacingOccurrences(of: "\n", with: " | "))
                NSApp.terminate(nil)
            }
        }
    }

    /// `Greenroom --inspect-check DIR APK`: opens the APK with the inspector, clicks the middle of the picture and
    /// captures the window: the click must pick a node (not tap the app) and outline it.
    private func inspectCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--inspect-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let sim = workbench.open(URL(fileURLWithPath: args[i + 2]), remember: false) else { return }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [self] timer in
            waited += 0.25
            guard (sim.state == .running && sim.framesShown > 0) || waited > 120 else { return }
            timer.invalidate()
            workbench.setInspecting(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
                workbench.debugClick(atFraction: CGPoint(x: 0.584, y: 0.881))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [self] in
                captureWindow(to: dir.appendingPathComponent("i1-inspector.png"))
                sim.send("stats") { [self] stats in
                    let down = stats.split(separator: " ").first { $0.hasPrefix("lastDown") } ?? ""
                    print("[greenroom] inspector: \(workbench.inspectorNodes.count) nodes, outline \(workbench.inspectorOutline.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none"), app \(down)")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// `Greenroom --record-check DIR APK`: opens the APK with the log panel, records, taps, saves the recording
    /// into the state folder and reports it; captures the window.
    private func recordCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--record-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let sim = workbench.open(URL(fileURLWithPath: args[i + 2]), remember: false) else { return }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [self] timer in
            waited += 0.25
            guard (sim.state == .running && sim.framesShown > 0) || waited > 120 else { return }
            timer.invalidate()
            workbench.setShowingLog(true)
            workbench.toggleRecording(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in workbench.debugClick(atFraction: CGPoint(x: 0.5, y: 0.5)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [self] in
                captureWindow(to: dir.appendingPathComponent("r1-log.png"))
                let recording = workbench.isRecording
                workbench.saveRecording { [self] file, answer in
                    let size = file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
                    print("[greenroom] record: on=\(recording) log lines \(workbench.logLines.count) saved \(file?.lastPathComponent ?? "nothing") \(size) bytes | \(answer.prefix(160))")
                    if let file { try? FileManager.default.copyItem(at: file, to: dir.appendingPathComponent("check.apkrec")) }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// `Greenroom --devhooks-check DIR APK`: see DevHooksCheck.
    private func devHooksCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--devhooks-check"), i + 2 < args.count else { return }
        DevHooksCheck.run(workbench: workbench, dir: URL(fileURLWithPath: args[i + 1]), apk: URL(fileURLWithPath: args[i + 2])) { [self] in captureWindow(to: $0) }
    }

    /// `Greenroom --scripts-check DIR APK`: see ScriptsCheck.
    private func scriptsCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--scripts-check"), i + 2 < args.count else { return }
        ScriptsCheck.run(workbench: workbench, dir: URL(fileURLWithPath: args[i + 1]), apk: URL(fileURLWithPath: args[i + 2]))
    }

    /// `Greenroom --sessions-check DIR APK`: see SessionsCheck.
    private func sessionsCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--sessions-check"), i + 2 < args.count else { return }
        SessionsCheck.run(workbench: workbench, dir: URL(fileURLWithPath: args[i + 1]), apk: URL(fileURLWithPath: args[i + 2]))
    }

    /// `Greenroom --recipes-check DIR APK`: see RecipesCheck.
    private func recipesCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--recipes-check"), i + 2 < args.count else { return }
        RecipesCheck.run(workbench: workbench, dir: URL(fileURLWithPath: args[i + 1]), apk: URL(fileURLWithPath: args[i + 2]))
    }

    /// `Greenroom --builds-check DIR APK`: see BuildsCheck.
    private func buildsCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--builds-check"), i + 2 < args.count else { return }
        BuildsCheck.run(workbench: workbench, dir: URL(fileURLWithPath: args[i + 1]), apk: URL(fileURLWithPath: args[i + 2]))
    }

    /// `Greenroom --claude-check DIR`: see ClaudeCheck.
    private func claudeCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--claude-check"), i + 1 < args.count else { return }
        ClaudeCheck.run(workbench: workbench, dir: URL(fileURLWithPath: args[i + 1]))
    }

    /// `Greenroom --recorder-check DIR APK`: see RecorderCheck.
    private func recorderCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--recorder-check"), i + 2 < args.count else { return }
        RecorderCheck.run(workbench: workbench, dir: URL(fileURLWithPath: args[i + 1]), apk: URL(fileURLWithPath: args[i + 2]))
    }

    private func defaults_forgetRecent(_ apk: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentApks") ?? []
        paths.removeAll { $0 == apk.path }
        UserDefaults.standard.set(paths, forKey: "recentApks")
    }

    /// The window as it is on screen. CGWindowListCreateImage is gone from the SDK's headers but still there, and
    /// needs no screen-recording permission for the process's own window.
    func captureWindow(to file: URL) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(sym, to: Capture.self)
        // .optionIncludingWindow = 8; .boundsIgnoreFraming | .bestResolution = 1 | 8
        // With the screen locked the window server hands out a blank picture. Then AppKit draws the content view
        // instead: no video and no glass, but the layout, the captions and the marks a comparison makes.
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        if !locked, let image = capture(.null, 8, UInt32(workbench.window.windowNumber), 9)?.takeRetainedValue() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
        } else if let view = workbench.window.contentView, let root = view.layer {
            // The layer tree rendered by Core Animation: shape and text layers, backgrounds and the glass panes' own
            // fills come out; the video and the glass blur do not.
            let scale = workbench.window.backingScaleFactor
            let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(Design.stage.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            view.effectiveAppearance.performAsCurrentDrawingAppearance { root.render(in: ctx) }   // the window's own (dark) appearance, not the system's
            if let image = ctx.makeImage() { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file) }
            print("[greenroom] the screen is locked: \(file.lastPathComponent) is Core Animation's drawing, without the video or blur")
        }
    }

    private let agent = AgentServer()
    private var termSource: DispatchSourceSignal?

    private func startAgentServer() {
        agent.tools.workbench = workbench
        workbench.agentTools = agent.tools
        agent.tools.onActivity = { [weak self] tool, summary, failed, session in
            self?.workbench.agentActivity.add(tool, summary, failed: failed, session: session)
        }
        agent.onClient = { [weak self] name in self?.workbench.agentActivity.connected(name) }
        workbench.agentActivity.onChange = { [weak self] in self?.workbench.agentChanged() }
        do { try agent.start() } catch { NSLog("Greenroom: the agent interface could not start: \(error)") }
        // Checks (--agent-check only): repositories to add to Sessions at launch (GREENROOM_ADD_REPOSITORY, one per line).
        for folder in (Engine.agentCheck ? ProcessInfo.processInfo.environment["GREENROOM_ADD_REPOSITORY"] ?? "" : "").split(separator: "\n") {
            let added = workbench.sessions.addRepository(URL(fileURLWithPath: String(folder), isDirectory: true))
            let controller = workbench.sessions
            Task { @MainActor in _ = await added.value; AgentCheckHooks.configure(controller) }   // the check's stand-in recipe
        }
    }

    /// Files and links macOS asks the app to open before the workbench exists (an APK double-clicked to launch it,
    /// or documents reopened at launch): opened once it does.
    private var openedEarly: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard workbench != nil else { openedEarly += urls; return }
        for url in urls {
            if url.pathExtension.lowercased() == "apkrec" { workbench.view(recording: url) } else { workbench.open(url) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { workbench?.window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
        Reports.shared.saveUsage()
        agent.stop()
        TestRun.terminateAll()
        workbench?.sessions.buildQueue.terminateAll()   // a running recipe is not left behind
        ReplayRunner.shared.cancelAll(wait: true)   // replays started from the recordings pane
        ScreenRecording.shared.stopAll()   // recordings end as finished files
        Engine.shared.stopAll()
    }

    // MARK: Menus

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.beginSheetModal(for: workbench.window) { [weak self] response in
            guard response == .OK else { return }
            panel.urls.forEach { self?.workbench.open($0) }
        }
    }

    @objc private func clearRecents(_ sender: Any?) {
        Recents.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
        Engine.shared.onChange?()
    }

    @objc private func showLogs(_ sender: Any?) {
        try? Engine.shared.prepare()
        NSWorkspace.shared.open(Engine.shared.logs)
    }

    @objc private func showWorkbench(_ sender: Any?) { workbench.window.makeKeyAndOrderFront(nil) }

    private func buildMenus() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About \(Variant.name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if Updates.shared.available {
            let check = app.addItem(withTitle: "Check for Updates…", action: #selector(Updates.checkForUpdates(_:)), keyEquivalent: "")
            check.target = Updates.shared
        }
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(showSettings(_:)), ","))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(Variant.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(Variant.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: Variant.name))

        let file = NSMenu(title: "File")
        file.addItem(item("Open APK…", #selector(openDocument(_:)), "o"))
        file.addItem(to(workbench: #selector(Workbench.compareWithAPK(_:)), "Compare With APK…", "O", [.command, .shift]))
        file.addItem(to(workbench: #selector(Workbench.addRepository(_:)), "Add Repository…", "o", [.command, .option]))
        file.addItem(item("Clear Recent APKs", #selector(clearRecents(_:)), ""))
        file.addItem(.separator())
        file.addItem(to(workbench: #selector(Workbench.toggleRecording(_:)), "Record", "r", [.command, .option]))
        file.addItem(to(workbench: #selector(Workbench.toggleScreenRecording(_:)), "Record Screen", "r", [.command, .control]))   // ⌘R is Rotate
        file.addItem(to(workbench: #selector(Workbench.saveRecordingAndShow(_:)), "Save Recording", "S", [.command, .shift]))
        file.addItem(to(workbench: #selector(Workbench.saveRecordingAndView(_:)), "Save Recording and Open Timeline", "S", [.command, .option]))
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(SimulatorView.paste(_:)), keyEquivalent: "v")
        main.addItem(submenu(edit, title: "Edit"))

        let device = NSMenu(title: "Device")
        device.addItem(to(workbench: #selector(Workbench.back(_:)), "Back", "["))
        device.addItem(to(workbench: #selector(Workbench.home(_:)), "Home", "H", [.command, .shift]))
        device.addItem(to(workbench: #selector(Workbench.rotate(_:)), "Rotate", "r"))
        device.addItem(to(workbench: #selector(Workbench.appearance(_:)), "Switch Light and Dark", "A", [.command, .shift]))
        device.addItem(.separator())
        device.addItem(to(workbench: #selector(Workbench.toggleSideBySide(_:)), "Side by Side", "\\"))
        device.addItem(to(workbench: #selector(Workbench.tidyUp(_:)), "Tidy Up Simulators", "\\", [.command, .option]))
        device.addItem(to(workbench: #selector(Workbench.toggleMirror(_:)), "Mirror Input", "M", [.command, .shift]))
        device.addItem(to(workbench: #selector(Workbench.toggleCompare(_:)), "Compare", "D", [.command, .shift]))
        device.addItem(to(workbench: #selector(Workbench.showChanges(_:)), "Changes…", "d"))
        device.addItem(to(workbench: #selector(Workbench.showMatrix(_:)), "Matrix Wall…", "x", [.command, .option]))
        device.addItem(to(workbench: #selector(Workbench.closeMatrix(_:)), "Close Matrix Wall", ""))
        device.addItem(.separator())
        let scripts = NSMenuItem(title: "Run Script", action: nil, keyEquivalent: "")
        scripts.submenu = NSMenu(title: "Run Script")
        scripts.submenu?.delegate = scriptsMenu
        device.addItem(scripts)
        device.addItem(.separator())
        device.addItem(to(workbench: #selector(Workbench.screenshot(_:)), "Save Screenshot", "s"))
        device.addItem(to(workbench: #selector(Workbench.restart(_:)), "Restart App", "R", [.command, .shift]))
        device.addItem(to(workbench: #selector(Workbench.closeSelected(_:)), "Close Simulator", "W", [.command, .shift]))
        main.addItem(submenu(device, title: "Device"))

        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(item("Workbench", #selector(showWorkbench(_:)), "0"))
        main.addItem(submenu(win, title: "Window"))
        NSApp.windowsMenu = win

        win.addItem(to(workbench: #selector(Workbench.showPalette(_:)), "Command Palette…", "k"))
        win.addItem(to(workbench: #selector(Workbench.showAgent(_:)), "Agent Activity", "A", [.command, .option]))
        win.addItem(to(workbench: #selector(Workbench.toggleInspector(_:)), "Inspector", "i", [.command, .option]))
        win.addItem(to(workbench: #selector(Workbench.toggleLog(_:)), "Log", "L", [.command, .shift]))

        let help = NSMenu(title: "Help")
        help.addItem(item("Show Simulator Logs", #selector(showLogs(_:)), ""))
        main.addItem(submenu(help, title: "Help"))

        NSApp.mainMenu = main
    }

    /// A menu item whose action the workbench performs (looked up when chosen: the workbench is made after the menus).
    private func to(workbench action: Selector, _ title: String, _ key: String, _ mask: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(forward(_:)), keyEquivalent: key)
        i.keyEquivalentModifierMask = mask
        i.target = self
        i.representedObject = NSStringFromSelector(action)
        return i
    }

    /// The Record Screen item reads "Stop Recording" while the selected simulator is being recorded.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.representedObject as? String == "toggleScreenRecording:" {
            item.title = Recorder.isRecording(workbench.selected) ? "Stop Recording Screen" : "Record Screen"
        }
        return true
    }

    @objc private func forward(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        _ = workbench.perform(NSSelectorFromString(name), with: sender)
    }

    @objc private func showSettings(_ sender: Any?) { SettingsWindow.shared.show() }


    /// Asked once, a few seconds after the first ordinary launch; dismissed, everything stays off.
    private func askAboutReportsIfDue() {
        let args = CommandLine.arguments
        guard !Reports.shared.asked, !args.contains(where: { $0.hasPrefix("--") }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in
            guard !Reports.shared.asked else { return }
            let window: NSWindow = workbench.window
            Reports.shared.asked = true
            let alert = NSAlert()
            alert.messageText = "Help improve Greenroom?"
            alert.informativeText = """
                Greenroom can send crash reports of its own and a daily count of which of its features you used. \
                Never anything from your APKs: no names, paths, screens, logs or traffic. Off unless you choose it; \
                Settings > Privacy shows each report before it goes and turns this off again.
                """
            alert.addButton(withTitle: "Send Crash Reports and Usage")
            alert.addButton(withTitle: "Crash Reports Only")
            alert.addButton(withTitle: "Don't Send")
            alert.beginSheetModal(for: window) { answer in
                Reports.shared.crashes = answer == .alertFirstButtonReturn || answer == .alertSecondButtonReturn
                Reports.shared.usage = answer == .alertFirstButtonReturn
            }
        }
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = menu
        return i
    }
}
