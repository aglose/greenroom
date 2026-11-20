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

    /// `Greenroom --window-shot FILE [APK]`: for checking the layout from a script. Opens the APK, waits, writes the
    /// window as AppKit draws it to FILE (the video layer is composited elsewhere and stays blank) and quits.
    private func windowShotIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--window-shot"), i + 1 < args.count else { return }
        if i + 2 < args.count { workbench.open(URL(fileURLWithPath: args[i + 2])) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [self] in
            if let frame = workbench.window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            let sims = Engine.shared.simulators
            print("[greenroom] window-shot: \(sims.count) simulators, first \(sims.first.map { "\($0.state) \($0.framesShown) frames" } ?? "none")")
            NSApp.terminate(nil)
        }
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
