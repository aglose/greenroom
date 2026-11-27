import AppKit

// The empty stage's way in for someone with source and no APK: a project folder on this Mac, or a GitHub repository
// cloned here. Either becomes a repository in Sessions, and the worktree it names is built with the repository's
// recipe and opened when the build lands (`activate`).

extension SessionsController {
    /// "Open a project folder…": a git checkout of an Android app, added to Sessions, then built and run.
    func chooseProjectToRun() {
        guard let window = workbench?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose an Android project folder (a git checkout with a Gradle wrapper): Greenroom builds it and runs it"
        panel.prompt = "Build and Run"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let folder = panel.url else { return }
            self?.run(project: folder)
        }
    }

    /// Adds the repository `folder` is in and builds and opens the worktree `folder` is in.
    func run(project folder: URL) {
        Task { @MainActor in
            guard let top = await Git.toplevel(of: folder) else {
                self.workbench?.toast.show(Git.available ? "\(folder.lastPathComponent) is not a git repository: run `git init` in it, or choose an APK" : Self.noGit, problem: true)
                return
            }
            let isApp = await Task.detached(priority: .userInitiated) { AndroidProject.isApp(top) }.value
            guard isApp else {
                self.workbench?.toast.show("\(top.lastPathComponent) does not look like an Android app: no Gradle wrapper and app module were found", problem: true)
                return
            }
            self.runWhenListed = top.path
            if await self.addRepository(top, quietIfExisting: true).value == nil { self.runWhenListed = nil }
        }
    }

    /// "Clone from GitHub…": asks for a repository, clones it into ~/Developer, then builds and runs it.
    func askToClone() {
        guard let window = workbench?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Clone from GitHub"
        alert.informativeText = "A repository's address or owner/name. It is cloned into ~/Developer, built on this Mac and opened."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "owner/repository or https://github.com/…"
        if let copied = NSPasteboard.general.string(forType: .string), Self.cloneSource(copied) != nil { field.stringValue = copied.trimmingCharacters(in: .whitespacesAndNewlines) }
        alert.accessoryView = field
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            let text = field.stringValue
            guard let source = Self.cloneSource(text) else {
                self?.workbench?.toast.show("“\(text)” is not a GitHub repository: try owner/name", problem: true)
                return
            }
            self?.clone(source)
        }
    }

    /// The URL to clone and the folder name for what was typed: `owner/name`, a github.com address (https, with or
    /// without `.git`, or a page inside the repository), or `git@github.com:owner/name`. Nil for anything else.
    static func cloneSource(_ text: String) -> (url: String, owner: String, name: String)? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var ssh = false
        for prefix in ["https://", "http://", "www."] where s.lowercased().hasPrefix(prefix) { s.removeFirst(prefix.count) }
        if s.lowercased().hasPrefix("git@github.com:") { s.removeFirst("git@github.com:".count); ssh = true }
        else if s.lowercased().hasPrefix("github.com/") { s.removeFirst("github.com/".count) }
        else if s.contains(":") || s.contains("@") { return nil }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        let ok = { (p: String) in !p.isEmpty && !p.hasPrefix("-") && !p.hasPrefix(".") && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
        guard ok(owner), !owner.contains("."), ok(name) else { return nil }   // owners have no dots: "gitlab.com/…" is not one
        let url = ssh ? "git@github.com:\(owner)/\(name).git" : "https://github.com/\(owner)/\(name).git"
        return (url, owner, name)
    }

    /// Clones into ~/Developer/<name> (or uses the clone of that repository already there), then adds and runs it.
    func clone(_ source: (url: String, owner: String, name: String)) {
        let fm = FileManager.default
        guard Git.available else { workbench?.toast.show(Self.noGit, problem: true); return }
        let developer = fm.homeDirectoryForCurrentUser.appendingPathComponent("Developer", isDirectory: true)
        workbench?.toast.show("Cloning \(source.owner)/\(source.name)…")
        Task { @MainActor in
            try? fm.createDirectory(at: developer, withIntermediateDirectories: true)
            // A folder of that name already: the same repository is used as it is; another gets a numbered name.
            var target = developer.appendingPathComponent(source.name, isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                if let remote = await Git.run(["remote", "get-url", "origin"], in: target),
                   Self.cloneSource(remote)?.owner.lowercased() == source.owner.lowercased(),
                   Self.cloneSource(remote)?.name.lowercased() == source.name.lowercased() {
                    self.run(project: target)
                    return
                }
                target = developer.appendingPathComponent("\(source.name)-\(n)", isDirectory: true)
                n += 1
            }
            // Blobs are fetched as they are checked out: a large history clones in a fraction of the time.
            guard await Git.run(["clone", "--quiet", "--filter=blob:none", "--", source.url, target.path], in: developer, timeout: 900) != nil else {
                try? fm.removeItem(at: target)   // a half-made clone
                self.workbench?.toast.show("Could not clone \(source.owner)/\(source.name). A private repository needs git signed in to GitHub first.", problem: true)
                return
            }
            self.workbench?.toast.show("Cloned into ~/Developer/\(target.lastPathComponent)")
            self.run(project: target)
        }
    }
}
