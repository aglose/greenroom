import AppKit

/// Device > Run Script: the scripts that can run on the chosen simulator, rebuilt each time the menu opens.
final class ScriptsMenu: NSObject, NSMenuDelegate {
    private let workbench: () -> Workbench?
    init(workbench: @escaping () -> Workbench?) { self.workbench = workbench }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let wb = workbench() else { return }
        let sim = wb.selected.flatMap { $0.isAlive ? $0 : nil }
        let scripts = Scripts.available(for: sim.flatMap { wb.worktree(of: $0) })
        if scripts.isEmpty {
            let none = menu.addItem(withTitle: "No Scripts Yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
        }
        var fromWorktree = false
        for s in scripts {
            if s.fromWorktree && !fromWorktree {
                fromWorktree = true
                menu.addItem(.separator())
                let head = menu.addItem(withTitle: "This Session's (.greenroom/scripts)", action: nil, keyEquivalent: "")
                head.isEnabled = false
            }
            let item = menu.addItem(withTitle: s.name, action: sim == nil ? nil : #selector(Workbench.runScript(_:)), keyEquivalent: "")
            item.target = wb
            item.representedObject = s.url
            item.isEnabled = sim != nil
            item.toolTip = sim == nil ? "Open an APK first: a script runs on the chosen simulator" : "Run \(s.name) on \(sim!.name)"
        }
        menu.addItem(.separator())
        for (title, action) in [("New Script…", #selector(Workbench.newScript(_:))), ("Show Scripts Folder", #selector(Workbench.showScriptsFolder(_:))),
                                ("Variables…", #selector(Workbench.showVariables(_:)))] {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            i.target = wb
        }
    }
}

extension Workbench {
    /// The worktree of the session `sim` belongs to, if it is a session's.
    func worktree(of sim: Simulator) -> URL? { sessions.session(forSimulator: sim)?.worktree }

    @objc func runScript(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        runScript(at: url)
    }

    /// Runs the script at `url` on the chosen simulator, its output in a window of its own.
    func runScript(at url: URL) {
        guard let sim = selected, sim.isAlive else { toast.show("No device is running", problem: true); return }
        let wt = worktree(of: sim)
        guard let script = Scripts.available(for: wt).first(where: { $0.url == url }) else { toast.show("That script is gone", problem: true); return }
        ScriptWindow.start(script, on: sim, worktree: wt, relativeTo: window)
    }

    @objc func newScript(_ sender: Any?) {
        do {
            let url = try Scripts.newScript()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            // Opened in the text editor, never with the default app for .sh (Terminal would run it).
            if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            }
        } catch {
            NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    @objc func showScriptsFolder(_ sender: Any?) {
        Scripts.prepareFolder()
        NSWorkspace.shared.open(Scripts.folder)
    }

    @objc func showVariables(_ sender: Any?) { SettingsWindow.shared.show() }
}
