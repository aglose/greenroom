import AppKit
import CryptoKit
import UniformTypeIdentifiers

// Pull requests without a worktree, as rows in a "Review" section (docs/SESSIONS-PLAN.md, "2. Builds"): added by
// number or address, their build fetched by the `ci` recipe, opened in a simulator with a data slot of their own,
// removable. Nothing is checked out.

struct PullRequest: Codable, Equatable {
    /// The repository's main checkout (a workspace's root).
    var workspace: String
    /// `owner/repo` on GitHub: with the number, what the pull request is (its row's id and its data slot).
    var slug: String
    var number: Int
    var title: String
    var headSha: String
    var headRef: String
    /// The stored build of `headSha`, once fetched.
    var buildKey: String?
    var added: Date

    var id: String { (slug.isEmpty ? workspace : slug.lowercased()) + "#" + String(number) }

    init(workspace: String, slug: String = "", number: Int, title: String, headSha: String, headRef: String, buildKey: String? = nil, added: Date = Date()) {
        self.workspace = workspace; self.slug = slug; self.number = number; self.title = title; self.headSha = headSha; self.headRef = headRef
        self.buildKey = buildKey; self.added = added
    }

    private enum Keys: String, CodingKey { case workspace, slug, number, title, headSha, headRef, buildKey, added }
    /// Tolerant: a missing optional field is its default; a record with no workspace or number is not one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(workspace: try c.decode(String.self, forKey: .workspace), slug: (try? c.decodeIfPresent(String.self, forKey: .slug)) ?? "", number: try c.decode(Int.self, forKey: .number),
                  title: (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "", headSha: (try? c.decodeIfPresent(String.self, forKey: .headSha)) ?? "",
                  headRef: (try? c.decodeIfPresent(String.self, forKey: .headRef)) ?? "", buildKey: try? c.decodeIfPresent(String.self, forKey: .buildKey),
                  added: (try? c.decodeIfPresent(Date.self, forKey: .added)) ?? Date(timeIntervalSince1970: 0))
    }
}

/// `sessions/pulls.json`: the pull requests the person added. One bad record is skipped, not the file.
struct PullStore {
    let file: URL

    private struct Lossy: Decodable {
        let value: PullRequest?
        init(from decoder: Decoder) throws { value = try? PullRequest(from: decoder) }
    }

    func load() -> [PullRequest] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return ((try? d.decode([Lossy].self, from: data)) ?? []).compactMap(\.value)
    }

    func save(_ list: [PullRequest]) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try e.encode(list).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("Greenroom: could not save the pull requests: \(error.localizedDescription)") }
    }
}

/// One row of the Review section.
struct PullRow {
    enum State: Equatable {
        case idle
        case fetching(String)
        case failed(String)
        case offer(String)
    }
    var pull: PullRequest
    var repo: String
    var state: State
    var build: Build?
    var simulator: Simulator?
}

final class PullRows {
    private weak var sessions: SessionsController?
    private var items: [PullRequest] = []
    private var loaded: URL?
    private var states: [String: PullRow.State] = [:]
    private var openWhenReady = Set<String>()

    init(sessions: SessionsController) { self.sessions = sessions }

    private var store: SessionStore { sessions?.store ?? SessionStore.shared }
    private var file: PullStore { PullStore(file: store.root.appendingPathComponent("sessions/pulls.json")) }

    /// The pull requests of the workspaces that are still added (the store may have changed since the last look).
    var all: [PullRequest] {
        if loaded != store.root { items = file.load(); loaded = store.root; states = [:] }
        let roots = Set((sessions?.workspaces ?? []).map(\.root.path))
        return items.filter { roots.contains($0.workspace) }
    }

    func state(of p: PullRequest) -> PullRow.State { states[p.id] ?? .idle }
    func build(of p: PullRequest) -> Build? { p.buildKey.flatMap { store.build($0) } }

    /// The data slot a pull request's app keeps its data in: its own, not any session's.
    func slot(of p: PullRequest) -> String {
        SessionStore.slot(for: store.root.appendingPathComponent("sessions/pulls/\(Self.hash(p.id))", isDirectory: true))
    }
    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    func simulator(of p: PullRequest) -> Simulator? {
        let slot = slot(of: p)
        return Engine.shared.simulators.first { $0.isAlive && SessionsController.slot(of: $0) == slot }
    }
    func owns(_ sim: Simulator) -> Bool { all.contains { slot(of: $0) == SessionsController.slot(of: sim) } }

    func rows() -> [PullRow] {
        all.map { p in
            PullRow(pull: p, repo: URL(fileURLWithPath: p.workspace).lastPathComponent, state: state(of: p), build: build(of: p), simulator: simulator(of: p))
        }
    }

    private func change() { sessions?.onChange?() }
    private func save() { file.save(items) }

    // MARK: Add, fetch, open, remove

    /// Adds a pull request typed or pasted as a number or an address, and starts fetching its CI build. Gives the
    /// pull request, or why not.
    @MainActor @discardableResult
    func add(_ input: String, to workspace: Workspace) async -> (PullRequest?, String) {
        guard let ref = PullRequestRef.parse(input) else { return (nil, "\"\(input)\" is not a pull request number or address") }
        let repoName = workspace.root.lastPathComponent
        var slug: String
        if let named = ref.slug {
            // An address names its repository: it must be one of this workspace's remotes.
            guard let own = GitHubRemote.slugs(of: workspace.root).first(where: { $0.caseInsensitiveCompare(named) == .orderedSame }) else {
                return (nil, "That pull request is in \(named), which is none of \(repoName)'s remotes")
            }
            slug = own
        } else {
            guard let own = await GitHubRemote.repoSlug(for: workspace.root) else { return (nil, "\(repoName) has no GitHub remote, so it has no pull requests to add") }
            slug = own
        }
        let (info, why) = await GH.pull(number: ref.number, slug: slug, in: workspace.root)
        guard let info else { return (nil, why) }
        _ = all   // loaded
        var pull = PullRequest(workspace: workspace.root.path, slug: slug, number: ref.number, title: info.title, headSha: info.sha, headRef: info.ref)
        if let i = items.firstIndex(where: { $0.id == pull.id }) {
            if items[i].headSha == pull.headSha { pull.buildKey = items[i].buildKey }
            items[i] = pull
        } else {
            items.append(pull)
        }
        save()
        change()
        fetch(pull)
        return (pull, "")
    }

    /// Fetches the pull request's head build: the stored one, else CI's.
    func fetch(_ p: PullRequest, thenOpen: Bool = false) {
        guard let ws = sessions?.workspaces.first(where: { $0.root.path == p.workspace }) else { return }
        if case .fetching = state(of: p) { if thenOpen { openWhenReady.insert(p.id) }; return }
        if thenOpen { openWhenReady.insert(p.id) }
        states[p.id] = .fetching("starting")
        change()
        let store = self.store, known = sessions?.sessions ?? []
        Task { @MainActor in
            await Self.fetchHead(of: p, in: ws.root)
            let result = await Bases.resolve(sha: p.headSha, ref: p.headRef, in: ws, sessions: known, store: store, pullRequest: true, slug: p.slug.isEmpty ? nil : p.slug, prNumber: p.number, prTitle: p.title) { [weak self] line in
                guard let self, case .fetching = self.states[p.id] ?? .idle, !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                self.states[p.id] = .fetching(line)
                self.change()
            }
            switch result {
            case .build(let b):
                states[p.id] = .idle
                if let i = items.firstIndex(where: { $0.id == p.id }) { items[i].buildKey = b.key; save() }
                // The pull request's build is walked like a session's (its row owner is "pr:ID").
                sessions?.evidence.buildArrived(worktree: "pr:" + p.id, build: b, auto: sessions?.workspaces.first { $0.root.path == p.workspace }?.auto ?? .onBuild)
                change()
                if openWhenReady.remove(p.id) != nil, let current = all.first(where: { $0.id == p.id }) { open(current) }
                else if let current = all.first(where: { $0.id == p.id }), let sim = simulator(of: current), sim.apk.resolvingSymlinksInPath().path != b.apk.resolvingSymlinksInPath().path {
                    DevHooks.shared.relaunch(sim, apk: b.apk, options: sim.options)   // a new head: same data, new build
                }
            case .offer(let o):
                openWhenReady.remove(p.id)
                states[p.id] = .offer(o.message)
                change()
            case .failed(let why):
                openWhenReady.remove(p.id)
                states[p.id] = .failed(why)
                change()
            }
        }
    }

    /// The ref a pull request's head is kept under in the repository, so its commit stays there for its map.
    static func headRef(of p: PullRequest) -> String { "refs/greenroom/pulls/\(p.number)" }

    /// Makes the pull request's head commit known to the repository (nothing is checked out): without it the walk of
    /// its build has no place in the map's history, and nothing says which files it changed since main. A commit
    /// already there (a session's branch) is left alone. A fetch that fails changes nothing: the build still opens.
    static func fetchHead(of p: PullRequest, in root: URL) async {
        guard !p.headSha.isEmpty, !p.headSha.hasPrefix("-") else { return }
        if await Git.run(["cat-file", "-e", p.headSha + "^{commit}"], in: root) != nil { return }
        let remote = await remote(for: p.slug, in: root)
        _ = await Git.run(["fetch", "--quiet", "--no-tags", remote, "+refs/pull/\(p.number)/head:" + headRef(of: p)], in: root, timeout: 120)
    }

    /// The name of the remote whose address is the GitHub repository `slug` (`origin` when none is, or no slug).
    static func remote(for slug: String, in root: URL) async -> String {
        guard !slug.isEmpty, let list = await Git.run(["remote", "-v"], in: root) else { return "origin" }
        for line in list.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 2, GitHubRemote.slug(of: parts[1])?.caseInsensitiveCompare(slug) == .orderedSame { return parts[0] }
        }
        return "origin"
    }

    /// Re-reads the pull request from GitHub (a push moves its head) and fetches the build of the new head.
    func refresh(_ p: PullRequest) {
        guard let ws = sessions?.workspaces.first(where: { $0.root.path == p.workspace }) else { return }
        Task { @MainActor in
            let (info, why) = await GH.pull(number: p.number, slug: p.slug.isEmpty ? nil : p.slug, in: ws.root)
            guard let info else { states[p.id] = .failed(why); change(); return }
            if let i = items.firstIndex(where: { $0.id == p.id }) {
                if items[i].headSha != info.sha { items[i].buildKey = nil }
                items[i].headSha = info.sha; items[i].headRef = info.ref; items[i].title = info.title
                save()
                fetch(items[i])
            }
        }
    }

    /// A click: the running simulator, else the build in a simulator of its own data, else fetch it first.
    func open(_ p: PullRequest) {
        guard let wb = sessions?.workbench else { return }
        if sessions?.deferUntilLaunchSetup(URL(fileURLWithPath: p.workspace), { [weak self] in self?.open(p) }) == true { return }
        if let sim = simulator(of: p) { wb.select(sim); return }
        guard let b = build(of: p), FileManager.default.fileExists(atPath: b.apk.path) else { fetch(p, thenOpen: true); return }
        let s = slot(of: p)
        let extra = sessions?.signInLaunchOptions(forWorkspace: URL(fileURLWithPath: p.workspace), targetSlot: s) ?? []
        let own = sessions?.launchOptions(forWorkspace: URL(fileURLWithPath: p.workspace)) ?? []
        let sim = wb.open(b.apk, remember: false, options: ["--data-slots", s] + extra + own)
        sim?.displayLabel = "#\(p.number) \(p.headRef.isEmpty ? p.title : p.headRef) · \(String(p.headSha.prefix(7)))"
        wb.refreshCaptions()
    }

    /// Links a local APK on disk directly to `pull` (without running CI or local Gradle), filing it in the store and
    /// reloading or opening the pull request's simulator.
    @MainActor
    func linkLocalAPK(_ apk: URL, to p: PullRequest, open shouldOpen: Bool = false) async -> Build? {
        let store = self.store
        let build = await Task.detached(priority: .userInitiated) {
            store.record(apk: apk, source: .file, sha: p.headSha.isEmpty ? nil : p.headSha, ref: p.headRef.isEmpty ? nil : p.headRef, dirty: false, date: Date(), prNumber: p.number)
        }.value
        guard let build else { return nil }
        applyLinkedBuild(build, toPR: p.number, workspace: p.workspace, open: shouldOpen)
        return build
    }

    /// Associates a filed build with any Review pull request matching `prNumber` (and optionally `workspace`).
    @discardableResult
    func applyLinkedBuild(_ build: Build, toPR prNumber: Int, workspace: String? = nil, open shouldOpen: Bool = false) -> Bool {
        _ = all
        var matched = false
        for i in items.indices where items[i].number == prNumber && (workspace == nil || items[i].workspace == workspace) {
            items[i].buildKey = build.key
            states[items[i].id] = .idle
            matched = true
            let p = items[i]
            sessions?.evidence.buildArrived(worktree: "pr:" + p.id, build: build, auto: sessions?.workspaces.first { $0.root.path == p.workspace }?.auto ?? .onBuild)
            if let sim = simulator(of: p), sim.apk.resolvingSymlinksInPath().path != build.apk.resolvingSymlinksInPath().path {
                DevHooks.shared.relaunch(sim, apk: build.apk, options: sim.options)
            } else if shouldOpen {
                open(p)
            }
        }
        if matched {
            save()
            change()
        }
        return matched
    }

    /// Opens a file chooser to link a local `.apk` file to pull request `p`.
    func chooseLocalAPK(for p: PullRequest) {
        guard let window = sessions?.workbench?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "apk") ?? .data]
        panel.message = "Choose a local APK to link to PR #\(p.number) (\(p.title))"
        panel.prompt = "Link APK"
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if await self.linkLocalAPK(url, to: p, open: true) != nil {
                    self.sessions?.workbench?.toast.show("Linked \(url.lastPathComponent) to PR #\(p.number)")
                } else {
                    self.sessions?.workbench?.toast.show("Could not link \(url.lastPathComponent)", problem: true)
                }
            }
        }
    }

    func remove(_ p: PullRequest) {
        _ = all
        if let sim = simulator(of: p) { Engine.shared.close(sim) }
        items.removeAll { $0.id == p.id }
        if let ws = sessions?.workspaces.first(where: { $0.root.path == p.workspace }) {
            Task { _ = await Git.run(["update-ref", "-d", Self.headRef(of: p)], in: ws.root) }
        }
        states[p.id] = nil
        save()
        change()
    }

    // MARK: Adding from the UI

    /// "Add pull request…": a text field in a sheet; the workspace is the current session's, else the first.
    func askAndAdd() {
        guard let sessions, let window = sessions.workbench?.window else { return }
        guard let ws = sessions.currentSession.flatMap({ sessions.workspace(of: $0) }) ?? sessions.workspaces.first else {
            sessions.workbench?.toast.show("Add a repository first", problem: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Add a pull request of \(ws.root.lastPathComponent)"
        alert.informativeText = "Its number or address. Greenroom fetches the build GitHub Actions made of its head (the ci recipe, with your gh sign-in) and opens it in a simulator with data of its own. Nothing is checked out."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "42 or https://github.com/owner/repo/pull/42"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, let self else { return }
            let text = field.stringValue
            Task { @MainActor in
                let (pull, why) = await self.add(text, to: ws)
                if pull == nil { self.sessions?.workbench?.toast.show(why, problem: true) }
            }
        }
    }
}

extension SessionsController {
    /// The Review section's rows (empty: no section).
    func pullRows() -> [PullRow] { pulls.rows() }

    func pullCell(_ row: PullRow) -> NSView {
        let running = row.simulator?.state == .running
        let icon = NSImageView(image: NSImage(systemSymbolName: running ? "circle.fill" : "arrow.triangle.pull", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = running ? Design.accent : .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: running ? 8.5 : 10, weight: .medium)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let numLabel = NSTextField(labelWithString: "#\(row.pull.number)")
        numLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        numLabel.textColor = Design.accent
        numLabel.setContentHuggingPriority(.required, for: .horizontal)
        numLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        numLabel.translatesAutoresizingMaskIntoConstraints = false
        let numPill = NSView()
        numPill.wantsLayer = true
        numPill.layer?.cornerRadius = 4.5
        numPill.layer?.backgroundColor = Design.accent.withAlphaComponent(0.14).cgColor
        numPill.addSubview(numLabel)
        NSLayoutConstraint.activate([
            numLabel.topAnchor.constraint(equalTo: numPill.topAnchor, constant: 1.5),
            numLabel.bottomAnchor.constraint(equalTo: numPill.bottomAnchor, constant: -1.5),
            numLabel.leadingAnchor.constraint(equalTo: numPill.leadingAnchor, constant: 5),
            numLabel.trailingAnchor.constraint(equalTo: numPill.trailingAnchor, constant: -5),
        ])

        let name = NSTextField(labelWithString: row.pull.title.isEmpty ? row.pull.headRef : row.pull.title)
        name.font = .systemFont(ofSize: 12.5, weight: .medium)
        name.textColor = Design.ink
        name.maximumNumberOfLines = 1
        name.lineBreakMode = .byTruncatingTail
        name.cell?.usesSingleLineMode = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var detail: String
        var color: NSColor = .secondaryLabelColor
        var views: [NSView] = []
        switch row.state {
        case .fetching(let line):
            detail = "fetching the CI build: " + line
            let spin = NSProgressIndicator()
            spin.style = .spinning; spin.controlSize = .small; spin.isIndeterminate = true; spin.startAnimation(nil)
            views.append(spin)
        case .failed(let why):
            detail = why.split(separator: "\n").last.map(String.init) ?? why
            color = .systemRed
        case .offer(let why):
            detail = why
            color = .systemOrange
        case .idle:
            var bits: [String] = []
            if !row.pull.headRef.isEmpty { bits.append(row.pull.headRef) }
            bits.append(String(row.pull.headSha.prefix(7)))
            bits.append(row.build != nil ? "CI build" : "no build yet")
            if row.repo != workspaces.first?.root.lastPathComponent || workspaces.count > 1 { bits.insert(row.repo, at: 0) }
            detail = bits.joined(separator: " · ")
        }
        if case .fetching = row.state {} else {
            views.append(ClosureButton(symbol: "arrow.clockwise", tip: "Look on GitHub for a newer head and fetch its build") { [weak self] in self?.pulls.refresh(row.pull) })
        }
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let headerRow = NSStackView(views: [icon, numPill, name, headerSpacer] + views)
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 5

        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = color
        sub.alignment = .left
        sub.maximumNumberOfLines = 1
        sub.lineBreakMode = .byTruncatingTail
        sub.cell?.usesSingleLineMode = true
        sub.toolTip = detail

        let cardStack = NSStackView(views: [headerRow, sub])
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 3
        cardStack.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8.5
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor(white: 1, alpha: 0.032).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(white: 1, alpha: 0.068).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            headerRow.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
            sub.widthAnchor.constraint(equalTo: cardStack.widthAnchor),
        ])

        let wrapper = NSView()
        wrapper.toolTip = "#\(row.pull.number) \(row.pull.title)\n\(detail)"
        wrapper.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 3),
            card.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -3),
            card.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 1),
            card.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -1),
        ])
        return wrapper
    }

    func pullMenuItems(for row: PullRow) -> [NSMenuItem] {
        [ClosureMenuItem("Open #\(row.pull.number)") { [weak self] in self?.pulls.open(row.pull) },
         ClosureMenuItem("Link Local APK to #\(row.pull.number)…") { [weak self] in self?.pulls.chooseLocalAPK(for: row.pull) },
         ClosureMenuItem("Check Out #\(row.pull.number) as a Session") { [weak self] in
             guard let self, let ws = self.workspaces.first(where: { $0.root.path == row.pull.workspace }) else { return }
             self.checkOutPull(number: row.pull.number, slug: row.pull.slug.isEmpty ? nil : row.pull.slug, in: ws)
         },
         ClosureMenuItem("Look for a Newer Head") { [weak self] in self?.pulls.refresh(row.pull) },
         ClosureMenuItem("Remove Pull Request") { [weak self] in self?.pulls.remove(row.pull) }]
    }

    func openPull(_ row: PullRow) { pulls.open(row.pull) }
    func removePull(_ row: PullRow) { pulls.remove(row.pull) }
    func closePullSimulator(_ row: PullRow) { if let sim = row.simulator { Engine.shared.close(sim) } }
}
