import AppKit

// A pull request checked out as a session: its head fetched into a local branch, in a worktree of its own under the
// store's `worktrees/` folder (where Changes keeps its checkouts too), shown in the sidebar and built and opened like
// any other session. Unlike the Review section's rows (PullRequests.swift), the code is there to read and change.

/// The pull requests being checked out now, so a second click does not race the first.
private enum PullCheckouts { static var running = Set<String>() }

extension SessionsController {
    /// "Check Out Pull Request…": its number or address in a sheet, then `checkOutPull`. The repository is `workspace`,
    /// else the current session's, else the first.
    func askAndCheckOutPull(in workspace: URL? = nil) {
        guard let window = workbench?.window else { return }
        let ws = workspace.flatMap { w in workspaces.first { $0.root.path == w.path } }
            ?? currentSession.flatMap { self.workspace(of: $0) } ?? workspaces.first
        guard let ws else { workbench?.toast.show("Add a repository first", problem: true); return }
        let alert = NSAlert()
        alert.messageText = "Check out a pull request of \(ws.root.lastPathComponent)"
        alert.informativeText = "Its number or address. Greenroom fetches its branch into a worktree of its own, adds it to the sidebar as a session, and builds and opens it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "42 or https://github.com/owner/repo/pull/42"
        alert.accessoryView = field
        alert.addButton(withTitle: "Check Out")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            let text = field.stringValue
            guard let ref = PullRequestRef.parse(text) else {
                self.workbench?.toast.show("\"\(text)\" is not a pull request number or address", problem: true)
                return
            }
            var slug: String?
            if let named = ref.slug {
                // An address names its repository: it must be one of this workspace's remotes.
                guard let own = GitHubRemote.slugs(of: ws.root).first(where: { $0.caseInsensitiveCompare(named) == .orderedSame }) else {
                    self.workbench?.toast.show("That pull request is in \(named), which is none of \(ws.root.lastPathComponent)'s remotes", problem: true)
                    return
                }
                slug = own
            }
            self.checkOutPull(number: ref.number, slug: slug, in: ws)
        }
    }

    /// Checks pull request `number` out as a session (see `checkOutPullRequest`), says how it went, and opens it.
    func checkOutPull(number: Int, slug: String?, in ws: Workspace) {
        let key = ws.root.path + "#\(number)"
        guard !PullCheckouts.running.contains(key) else { workbench?.toast.show("Pull request #\(number) is being checked out already"); return }
        PullCheckouts.running.insert(key)
        workbench?.toast.show("Fetching pull request #\(number)…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (worktree, message) = await self.checkOutPullRequest(number: number, slug: slug, in: ws)
            PullCheckouts.running.remove(key)
            guard let worktree else { self.workbench?.toast.show(message, problem: true); return }
            self.workbench?.toast.show(message)
            let want = worktree.resolvingSymlinksInPath().path
            if let s = self.sessions.first(where: { $0.worktree.resolvingSymlinksInPath().path == want }) {
                self.activate(s)
            } else {
                self.runWhenListed = want   // built and opened once the refresh lists it
                self.refresh()
            }
        }
    }

    /// Fetches pull request `number`'s head and gives the worktree it is checked out in, and what was done; or nil and
    /// why not. The local branch is the pull request's own branch name, or `pr-N` when that name is taken by an
    /// unrelated branch (a fork's `main`, say). A branch already checked out somewhere is that worktree. A local
    /// branch behind the head is moved up to it; one with commits of its own is left as it is.
    @MainActor
    func checkOutPullRequest(number: Int, slug givenSlug: String?, in ws: Workspace) async -> (URL?, String) {
        let root = ws.root
        let repoName = root.lastPathComponent
        var slug = givenSlug ?? ""
        if slug.isEmpty {
            guard let own = await GitHubRemote.repoSlug(for: root) else { return (nil, "\(repoName) has no GitHub remote, so it has no pull requests to check out") }
            slug = own
        }
        let (got, why) = await GH.pull(number: number, slug: slug, in: root)
        guard let info = got else { return (nil, why) }
        func git(_ args: [String], timeout: TimeInterval = 30) async -> String? { await Git.run(args, in: root, timeout: timeout) }

        // The head, under the ref the Review section keeps it in too.
        let remote = await PullRows.remote(for: slug, in: root)
        let kept = "refs/greenroom/pulls/\(number)"
        guard await git(["fetch", "--quiet", "--no-tags", remote, "+refs/pull/\(number)/head:\(kept)"], timeout: 300) != nil else {
            return (nil, "git could not fetch pull request #\(number) from \(remote)")
        }
        let sha: String
        if !info.sha.hasPrefix("-"), await git(["cat-file", "-e", info.sha + "^{commit}"]) != nil { sha = info.sha }
        else if let s = await git(["rev-parse", "--verify", "--quiet", kept + "^{commit}"])?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { sha = s }
        else { return (nil, "git fetched pull request #\(number) but has no commit for it") }

        // Which local branch: its own name when free (or already this pull request's), else pr-N.
        let validName: Bool
        if info.ref.isEmpty || info.ref.hasPrefix("-") { validName = false }
        else { validName = await git(["check-ref-format", "--branch", info.ref]) != nil }
        let base = MainBuilds.shortName(ws.baseRef)
        var candidates: [String] = []
        if validName && info.ref != base { candidates.append(info.ref) }
        candidates.append("pr-\(number)")
        let marker = "greenroomPr"
        var branch: String?
        var exists = false
        for name in candidates {
            let has = await git(["rev-parse", "--verify", "--quiet", "refs/heads/" + name]) != nil
            if !has { branch = name; break }
            let ours = await git(["config", "--get", "branch.\(name).\(marker)"])?.trimmingCharacters(in: .whitespacesAndNewlines) == String(number)
            // A branch of the same name in the repository itself is that branch; a fork's may be anything.
            if ours || (!info.crossRepository && name == info.ref) { branch = name; exists = true; break }
        }
        guard let branch else { return (nil, "Branches \(candidates.joined(separator: " and ")) are taken by other work: rename one and try again") }

        let pullNote = GH.BranchPull(number: number, title: info.title, branch: branch, state: info.state, isDraft: info.isDraft, url: info.url)
        func remember() { checkedOutPRs[root.path, default: [:]][branch] = pullNote }

        var note = ""
        if exists {
            // Checked out already: that worktree is the session.
            if let w = await Git.worktrees(of: root).first(where: { $0.branch == branch }) {
                remember()
                let behind = w.head != sha ? " (it is at \(w.head.prefix(7)), the pull request at \(sha.prefix(7)): pull to update it)" : ""
                return (w.path, "#\(number) is checked out in \(w.path.lastPathComponent) already\(behind)")
            }
            if await git(["merge-base", "--is-ancestor", "refs/heads/" + branch, sha]) != nil {
                _ = await git(["branch", "--force", "--no-track", branch, sha])
            } else if await git(["merge-base", "--is-ancestor", sha, "refs/heads/" + branch]) == nil {
                note = " (your branch \(branch) has commits the pull request does not, so it was left as it is)"
            }
        } else {
            guard await git(["branch", "--no-track", branch, sha]) != nil else { return (nil, "git could not make the branch \(branch)") }
            _ = await git(["config", "branch.\(branch).\(marker)", String(number)])
        }
        // Its own branch in the repository itself is its upstream, so pull and push work as usual.
        if !info.crossRepository && branch == info.ref,
           await git(["fetch", "--quiet", "--no-tags", remote, "+refs/heads/\(branch):refs/remotes/\(remote)/\(branch)"], timeout: 300) != nil {
            _ = await git(["branch", "--set-upstream-to=\(remote)/\(branch)", branch])
        }

        // The worktree, under the store's worktrees folder.
        let folder = store.root.appendingPathComponent("worktrees", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var dir = folder.appendingPathComponent("\(repoName)-pr-\(number)", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = folder.appendingPathComponent("\(repoName)-pr-\(number)-\(n)", isDirectory: true)
            n += 1
        }
        _ = await git(["worktree", "prune"])   // a worktree whose folder was deleted still holds its branch
        guard await git(["worktree", "add", dir.path, branch], timeout: 600) != nil else {
            return (nil, "git could not check \(branch) out in a worktree")
        }
        // The untracked local.properties (the SDK's folder), as main's worktree gets it.
        let props = "local.properties"
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(props).path) {
            try? FileManager.default.copyItem(at: root.appendingPathComponent(props), to: dir.appendingPathComponent(props))
        }
        remember()
        return (dir, "Checked out #\(number) \(info.title.isEmpty ? branch : info.title) as \(branch)\(note)")
    }
}
