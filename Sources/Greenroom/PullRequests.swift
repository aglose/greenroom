import AppKit
import CryptoKit

// Pull requests without a worktree, as rows in a "Review" section (docs/SESSIONS-PLAN.md, "2. Builds"): added by
// number or address, their build fetched by the `ci` recipe, opened in a simulator with a data slot of their own,
// removable. Nothing is checked out.

struct PullRequest: Codable, Equatable {
    /// The repository's main checkout (a workspace's root).
    var workspace: String
    var number: Int
    var title: String
    var headSha: String
    var headRef: String
    /// The stored build of `headSha`, once fetched.
    var buildKey: String?
    var added: Date

    var id: String { workspace + "#" + String(number) }

    init(workspace: String, number: Int, title: String, headSha: String, headRef: String, buildKey: String? = nil, added: Date = Date()) {
        self.workspace = workspace; self.number = number; self.title = title; self.headSha = headSha; self.headRef = headRef
        self.buildKey = buildKey; self.added = added
    }

    private enum Keys: String, CodingKey { case workspace, number, title, headSha, headRef, buildKey, added }
    /// Tolerant: a missing optional field is its default; a record with no workspace or number is not one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(workspace: try c.decode(String.self, forKey: .workspace), number: try c.decode(Int.self, forKey: .number),
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
        SessionStore.slot(for: store.root.appendingPathComponent("sessions/pulls/\(Self.hash(p.workspace))-\(p.number)", isDirectory: true))
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
        if let slug = ref.slug, !GitHubRemote.slugs(of: workspace.root).contains(where: { $0.caseInsensitiveCompare(slug) == .orderedSame }) {
            return (nil, "That pull request is in \(slug), which is not a remote of \(workspace.root.lastPathComponent)")
        }
        let (info, why) = await GH.pull(input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: ""), number: ref.number, in: workspace.root)
        guard let info else { return (nil, why) }
        _ = all   // loaded
        var pull = PullRequest(workspace: workspace.root.path, number: ref.number, title: info.title, headSha: info.sha, headRef: info.ref)
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
            let result = await Bases.resolve(sha: p.headSha, ref: p.headRef, in: ws, sessions: known, store: store) { [weak self] line in
                guard let self, case .fetching = self.states[p.id] ?? .idle, !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                self.states[p.id] = .fetching(line)
                self.change()
            }
            switch result {
            case .build(let b):
                states[p.id] = .idle
                if let i = items.firstIndex(where: { $0.id == p.id }) { items[i].buildKey = b.key; save() }
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

    /// Re-reads the pull request from GitHub (a push moves its head) and fetches the build of the new head.
    func refresh(_ p: PullRequest) {
        guard let ws = sessions?.workspaces.first(where: { $0.root.path == p.workspace }) else { return }
        Task { @MainActor in
            let (info, why) = await GH.pull(String(p.number), number: p.number, in: ws.root)
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
        if let sim = simulator(of: p) { wb.select(sim); return }
        guard let b = build(of: p), FileManager.default.fileExists(atPath: b.apk.path) else { fetch(p, thenOpen: true); return }
        _ = wb.open(b.apk, remember: false, options: ["--data-slots", slot(of: p)])
    }

    func remove(_ p: PullRequest) {
        _ = all
        if let sim = simulator(of: p) { Engine.shared.close(sim) }
        items.removeAll { $0.id == p.id }
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
        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = running ? .systemGreen : .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = NSTextField(labelWithString: "#\(row.pull.number) \(row.pull.title)")
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
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
            if row.build != nil { detail = "\(String(row.pull.headSha.prefix(7))) · CI build" }
            else { detail = String(row.pull.headSha.prefix(7)) + " · no build yet" }
            if row.repo != workspaces.first?.root.lastPathComponent || workspaces.count > 1 { detail = row.repo + " · " + detail }
        }
        if case .fetching = row.state {} else {
            views.append(ClosureButton(symbol: "arrow.clockwise", tip: "Look on GitHub for a newer head and fetch its build") { [weak self] in self?.pulls.refresh(row.pull) })
        }
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = color
        sub.lineBreakMode = .byTruncatingTail
        sub.toolTip = detail
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 0
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, text] + views)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        return stack
    }

    func pullMenuItems(for row: PullRow) -> [NSMenuItem] {
        [ClosureMenuItem("Open #\(row.pull.number)") { [weak self] in self?.pulls.open(row.pull) },
         ClosureMenuItem("Look for a Newer Head") { [weak self] in self?.pulls.refresh(row.pull) },
         ClosureMenuItem("Remove Pull Request") { [weak self] in self?.pulls.remove(row.pull) }]
    }

    func openPull(_ row: PullRow) { pulls.open(row.pull) }
    func removePull(_ row: PullRow) { pulls.remove(row.pull) }
    func closePullSimulator(_ row: PullRow) { if let sim = row.simulator { Engine.shared.close(sim) } }
}
