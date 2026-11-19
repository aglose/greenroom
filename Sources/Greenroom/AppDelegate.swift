import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let library = LibraryView(frame: NSRect(x: 0, y: 0, width: 420, height: 460))

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenus()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Greenroom"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 340, height: 300)
        window.contentView = library
        window.setFrameAutosaveName("Library")
        if window.frame.origin == .zero { window.center() }
        window.makeKeyAndOrderFront(nil)

        library.open = { [weak self] in self?.open($0) }
        Engine.shared.onChange = { [weak self] in self?.refreshStatus() }
        refreshStatus()
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
        Engine.shared.stopAll()
    }

    private func open(_ apk: URL) {
        do {
            try Engine.shared.launch(apk: apk)
            Recents.add(apk)
            NSDocumentController.shared.noteNewRecentDocumentURL(apk)
            library.reload()
        } catch {
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: window)
        }
    }

    private func refreshStatus() {
        let n = Engine.shared.running.count
        let sims = n == 0 ? "No simulators running" : n == 1 ? "1 simulator running" : "\(n) simulators running"
        library.setStatus("\(sims) · engine \(Engine.shared.version) · your APKs stay on this Mac")
    }

    // MARK: Menus

    @objc private func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            panel.urls.forEach { self?.open($0) }
        }
    }

    @objc private func clearRecents(_ sender: Any?) {
        Recents.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
        library.reload()
    }

    @objc private func showLogs(_ sender: Any?) {
        try? Engine.shared.prepare()
        NSWorkspace.shared.open(Engine.shared.logs)
    }

    @objc private func showLibrary(_ sender: Any?) { window.makeKeyAndOrderFront(nil) }

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

        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(item("Library", #selector(showLibrary(_:)), "0"))
        main.addItem(submenu(win, title: "Window"))
        NSApp.windowsMenu = win

        let help = NSMenu(title: "Help")
        help.addItem(item("Show Simulator Logs", #selector(showLogs(_:)), ""))
        main.addItem(submenu(help, title: "Help"))

        NSApp.mainMenu = main
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
