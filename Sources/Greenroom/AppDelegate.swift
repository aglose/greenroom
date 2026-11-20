import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var workbench: Workbench!

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenus()
        workbench = Workbench()
        workbench.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        windowShotIfAsked()
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
                    sim.send("stats") { print("[greenroom] \(name): device \(Int(sim.deviceSize.width))x\(Int(sim.deviceSize.height)) frames \(sim.framesShown) \($0.split(separator: " ").filter { $0.hasPrefix("lastDown") || $0.hasPrefix("frames=") }.joined(separator: " "))") }
                }
                at += 0.6
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + at + 1) { NSApp.terminate(nil) }
        }
    }

    /// The window as it is on screen. CGWindowListCreateImage is gone from the SDK's headers but still there, and
    /// needs no screen-recording permission for the process's own window.
    private func captureWindow(to file: URL) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let capture = unsafeBitCast(sym, to: Capture.self)
        // .optionIncludingWindow = 8; .boundsIgnoreFraming | .bestResolution = 1 | 8
        guard let image = capture(.null, 8, UInt32(workbench.window.windowNumber), 9)?.takeRetainedValue() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { workbench.open($0) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { workbench.window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
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
        file.addItem(item("Clear Recent APKs", #selector(clearRecents(_:)), ""))
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
        device.addItem(to(workbench: #selector(Workbench.screenshot(_:)), "Save Screenshot", "s"))
        device.addItem(to(workbench: #selector(Workbench.restart(_:)), "Restart App", "R", [.command, .shift]))
        device.addItem(to(workbench: #selector(Workbench.closeSelected(_:)), "Close Simulator", "W", [.command, .shift]))
        main.addItem(submenu(device, title: "Device"))

        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(item("Workbench", #selector(showWorkbench(_:)), "0"))
        main.addItem(submenu(win, title: "Window"))
        NSApp.windowsMenu = win

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
