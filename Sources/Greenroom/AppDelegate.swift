import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var workbench: Workbench!

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenus()
        workbench = Workbench()
        workbench.window.makeKeyAndOrderFront(nil)
        if !CommandLine.arguments.contains("--background") { NSApp.activate() }
        startAgentServer()
        // `kill` (and a script that started the app) quits it as the menu would: simulators stopped, nothing left behind.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term
        windowShotIfAsked()
        compareCheckIfAsked()
        inspectCheckIfAsked()
        recordCheckIfAsked()
        stageCheckIfAsked()
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
                        NSApp.terminate(nil)
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

    private func defaults_forgetRecent(_ apk: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentApks") ?? []
        paths.removeAll { $0 == apk.path }
        UserDefaults.standard.set(paths, forKey: "recentApks")
    }

    /// The window as it is on screen. CGWindowListCreateImage is gone from the SDK's headers but still there, and
    /// needs no screen-recording permission for the process's own window.
    private func captureWindow(to file: URL) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(sym, to: Capture.self)
        // .optionIncludingWindow = 8; .boundsIgnoreFraming | .bestResolution = 1 | 8
        // With the screen locked the window server hands out a blank picture. Then AppKit draws the content view
        // instead: no video and no glass, but the layout, the captions and the marks a comparison makes.
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        if !locked, let image = capture(.null, 8, UInt32(workbench.window.windowNumber), 9)?.takeRetainedValue() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
        } else if let view = workbench.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
            print("[greenroom] the screen is locked: \(file.lastPathComponent) is AppKit's drawing, without the video")
        }
    }

    private let agent = AgentServer()
    private var termSource: DispatchSourceSignal?

    private func startAgentServer() {
        agent.tools.workbench = workbench
        workbench.agentTools = agent.tools
        agent.tools.onActivity = { [weak self] tool, summary, failed in
            self?.workbench.agentActivity.add(tool, summary, failed: failed)
        }
        agent.onClient = { [weak self] name in self?.workbench.agentActivity.connected(name) }
        workbench.agentActivity.onChange = { [weak self] in self?.workbench.agentChanged() }
        do { try agent.start() } catch { NSLog("Greenroom: the agent interface could not start: \(error)") }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension.lowercased() == "apkrec" { workbench.view(recording: url) } else { workbench.open(url) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { workbench.window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
        agent.stop()
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
        app.addItem(withTitle: "About Greenroom", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Greenroom", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Greenroom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "Greenroom"))

        let file = NSMenu(title: "File")
        file.addItem(item("Open APK…", #selector(openDocument(_:)), "o"))
        file.addItem(to(workbench: #selector(Workbench.compareWithAPK(_:)), "Compare With APK…", "O", [.command, .shift]))
        file.addItem(item("Clear Recent APKs", #selector(clearRecents(_:)), ""))
        file.addItem(.separator())
        file.addItem(to(workbench: #selector(Workbench.toggleRecording(_:)), "Record", "r", [.command, .option]))
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
        device.addItem(to(workbench: #selector(Workbench.toggleMirror(_:)), "Mirror Input", "M", [.command, .shift]))
        device.addItem(to(workbench: #selector(Workbench.toggleCompare(_:)), "Compare", "D", [.command, .shift]))
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

    @objc private func forward(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        _ = workbench.perform(NSSelectorFromString(name), with: sender)
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
