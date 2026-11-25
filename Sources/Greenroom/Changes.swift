import AppKit
import AVFoundation

// Changes (docs/SESSIONS-PLAN.md, "4. Changes" and "3. Evidence", the change tour): a build against a base. The model
// is read from a `changes/<head key>-<base key>` folder the engine's `crawl.py HEAD --base BASE` made (Evidence.changes),
// `ChangesRun` resolves the base and asks for that folder, and `ChangeTour` records both builds at each screen that
// differs. The sheet is ChangesSheet.swift.

extension URL {
    /// Whether this path, with symlinks and `..` resolved, is inside `folder`: a path read from a crawl's JSON must not lead out of it.
    func isInside(_ folder: URL) -> Bool {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

// MARK: - The model

enum ChangeStatus: String {
    case new, changed, gone, same
    /// The other side's walk did not finish, so this screen may be there after all: neither new nor gone.
    case unreached

    var color: NSColor {
        switch self {
        case .new: return Design.accent
        case .changed: return Design.warning
        case .gone: return Design.record
        case .same, .unreached: return Design.mute
        }
    }
    var word: String { self == .unreached ? "not reached" : rawValue }
}

/// What a comparison found for one screen of the map: its edge colour and badge on the map.
struct MapMark {
    let label: String
    let color: NSColor
    /// Routes into this screen take its colour (new and gone screens: the way there is new, or no longer there).
    let tintRoutes: Bool
}

/// One screen of a comparison: in the head, in the base, or in both.
struct ChangeScreen {
    /// The id in the merged map: the head's id, or `base:<id>` for a screen only the base has.
    let id: String
    let headID: String?
    let baseID: String?
    let title: String
    let activity: String
    let status: ChangeStatus
    /// Captures in the same combination: the head's, the base's, and the difference image.
    let head: URL?
    let base: URL?
    let diff: URL?
    let pixels: Int?
    let total: Int?
    let sizeChanged: Bool
    let why: String?

    var percent: Double? {
        guard let p = pixels, let t = total, t > 0 else { return nil }
        return Double(p) / Double(t) * 100
    }

    /// One line: "4,812 px differ (0.35%)", "size changed", "new screen", "no longer there".
    var detail: String {
        switch status {
        case .new: return "new screen"
        case .gone: return "no longer there"
        case .same: return "the same"
        case .unreached: return why ?? "a walk did not finish"
        case .changed:
            if sizeChanged { return "size changed" }
            if let p = pixels {
                let n = ChangeScreen.number.string(from: NSNumber(value: p)) ?? "\(p)"
                if let pc = percent { return pc < 0.01 ? "\(n) px differ (<0.01%)" : String(format: "%@ px differ (%.2f%%)", n, pc) }
                return "\(n) px differ"
            }
            return why ?? "structure differs"
        }
    }

    static let number: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; return f }()
}

struct ChangeFinding {
    enum Side { case head, base }
    let side: Side
    let kind: String
    let detail: String
}

/// A finished comparison, read from its folder.
struct ChangeSet {
    let folder: URL
    let summary: Evidence.ChangesSummary
    /// Screens one build reached that the other's unfinished walk may simply not have got to: not counted as new or gone.
    let unreached: Int
    /// Head and base are one build: nothing was walked, there is nothing to differ.
    var identical = false
    /// The stored difference this comparison was made from (history), with each lineage's title: what `reasons(of:)` says, and the
    /// crashes as new, fixed or still there. Nil for a comparison a walk made.
    var diff: MapDiff?
    var lineageTitles: [String: String] = [:]
    /// Where the baseline came from, in a line: "walked both builds", "main at 53ffe80, 6 commits behind the merge base".
    var baseline: String?
    /// Why the walk looked at a screen again, by the head's screen id ("SettingsFragment.kt changed"): the changed
    /// files that reach it. Empty when the whole app was walked.
    var walkedBecause: [String: [String]] = [:]
    /// Changes the head's walk could not trace to screens ("app start changed (App.kt)"): what they reach was not walked again.
    var unplaced: [String] = []
    /// The history store's folder: a comparison from history shows the store's own pictures.
    var storeFolder: URL?
    /// Every pair, in the crawler's order: the head's screens, then those only the base has.
    let screens: [ChangeScreen]
    let headMap: ScreenMapData
    let baseMap: ScreenMapData?
    /// The head's map with the base-only screens and their routes added, for the Map tab.
    let merged: ScreenMapData
    let marks: [String: MapMark]
    let crashes: [ChangeFinding]
    /// What the walks did not finish, in words.
    let unfinished: [String]
    let reportURL: URL?
    /// The two snapshots the map shows, when the comparison came from the history; else made from the folder on demand.
    var mapSource: MapSource? = nil

    var differing: [ChangeScreen] { screens.filter { $0.status == .new || $0.status == .changed || $0.status == .gone } }
    var isUnchanged: Bool { summary.differing == 0 }
    func screen(_ id: String) -> ChangeScreen? { screens.first { $0.id == id } }

    static func read(_ folder: URL) -> ChangeSet? {
        guard let headMap = ScreenMapData.read(folder),
              let data = try? Data(contentsOf: folder.appendingPathComponent("crawl.json")),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pairs = raw["compare"] as? [[String: Any]] else { return nil }
        let baseMap = ScreenMapData.read(folder, screensKey: "base_screens", edgesKey: "base_edges")
        let diffs = raw["diffs"] as? [String: [String: Any]] ?? [:]
        let combos = headMap.combos

        func capture(_ s: MapScreen?, _ combo: String?) -> URL? {
            guard let s else { return nil }
            return s.captures.first { $0.combo == combo }?.file ?? s.captures.first?.file
        }

        // A walk cut short (a time or screen limit; a depth limit is the budget's choice) leaves screens the other side reached
        // looking new or gone: they are "not reached" instead.
        let cut = ((raw["incomplete"] as? [String]) ?? []).filter { !($0.hasPrefix("base: ") ? String($0.dropFirst(6)) : $0).hasPrefix("--max-depth") }
        let headCut = cut.contains { !$0.hasPrefix("base: ") }, baseCut = cut.contains { $0.hasPrefix("base: ") }
        var screens: [ChangeScreen] = []
        var baseToMerged: [String: String] = [:]
        for p in pairs {
            var status = ChangeStatus(rawValue: (p["status"] as? String) ?? "") ?? .same
            var why = p["why"] as? String
            if status == .gone, headCut { status = .unreached; why = "the head's walk did not finish, so it may still be there" }
            if status == .new, baseCut { status = .unreached; why = "the base's walk did not finish, so it may be there too" }
            let headID = p["id"] as? String, baseID = p["base"] as? String
            let id = headID ?? ("base:" + (baseID ?? "?"))
            if let baseID { baseToMerged[baseID] = id }
            let hs = headID.flatMap { headMap.screen($0) }, bs = baseID.flatMap { baseMap?.screen($0) }
            let d = headID.flatMap { diffs[$0] } ?? [:]
            func part(_ c: String) -> [String: Any]? { d[c] as? [String: Any] }
            let combo = combos.first { (part($0)?["differs"] as? Bool) == true } ?? combos.first { part($0)?["map"] != nil } ?? combos.first
            let info = combo.flatMap { part($0) }
            let diffFile = (info?["map"] as? String).map { folder.appendingPathComponent($0) }.flatMap { $0.isInside(folder) ? $0 : nil }
            screens.append(ChangeScreen(
                id: id, headID: headID, baseID: baseID, title: hs?.label ?? bs?.label ?? id, activity: hs?.activity ?? bs?.activity ?? "",
                status: status, head: capture(hs, combo), base: capture(bs, combo),
                diff: diffFile.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
                pixels: info?["pixels"] as? Int, total: info?["total"] as? Int, sizeChanged: (info?["sizeChanged"] as? Bool) ?? false,
                why: why))
        }

        // The head's findings only: the base build's crashes are marked on the base-only screens by their edges, not as the head's.
        var headFindings: [MapFinding] = []
        for f in (raw["findings"] as? [[String: Any]]) ?? [] where (f["build"] as? String) != "base" {
            headFindings.append(MapFinding(kind: (f["kind"] as? String) ?? "", detail: (f["detail"] as? String) ?? "",
                                           steps: ((f["path"] as? [String: Any])?["steps"] as? [String]) ?? []))
        }
        var crashes: [ChangeFinding] = []
        for f in (raw["findings"] as? [[String: Any]]) ?? [] {
            let kind = (f["kind"] as? String) ?? ""
            guard kind == "crash" || kind == "compare" else { continue }
            crashes.append(ChangeFinding(side: (f["build"] as? String) == "base" ? .base : .head, kind: kind, detail: (f["detail"] as? String) ?? ""))
        }
        let unfinished = ((raw["incomplete"] as? [String]) ?? []).map(unfinishedLine)
        var set = assemble(folder: folder, screens: screens, baseToMerged: baseToMerged, headMap: headMap, baseMap: baseMap, headFindings: headFindings,
                           crashes: crashes, unfinished: unfinished)
        set.baseline = "walked both builds"
        return set
    }

    /// A comparison of two stored snapshots (`History.changeSet`) that remembers its difference, so its lines can say why a screen
    /// differs. `baseline` says where the base came from.
    static func fromHistory(head: MapSnapshot, base: MapSnapshot, store: MapStore, folder: URL, baseline: String) -> ChangeSet {
        var set = History.changeSet(head: head, base: base, store: store, folder: folder)
        set.diff = MapPairing.diff(head: head, base: base)
        var titles: [String: String] = [:]
        for snap in [base, head] { for s in snap.screens { titles[s.lineage] = s.title.isEmpty ? s.activity : s.title } }
        for s in MapPairing.pair(head: head, base: base).0.screens { titles[s.lineage] = s.title.isEmpty ? s.activity : s.title }
        set.lineageTitles = titles
        set.baseline = baseline
        set.storeFolder = store.folder
        return set
    }

    /// The stored change a screen of this comparison stands for.
    func change(of c: ChangeScreen) -> MapDiff.ScreenChange? { diff?.screens.first { $0.head == c.headID && $0.base == c.baseID } }

    private func routeWord(_ status: MapDiff.EdgeChange.Status, _ n: Int) -> String {
        "\(n) route\(n == 1 ? "" : "s") \(status == .retargeted ? "redirected" : status.rawValue)"
    }

    /// Why a modified screen differs, in words: "visual 0.35%, 1 route added, 2 texts changed". `tool` keeps the walk's own wording
    /// for the pixels ("4,812 px differ (0.35%)"). Nil when this comparison has no stored difference (a walk's) or the screen is not modified.
    func reasons(of c: ChangeScreen, tool: Bool = false) -> String? {
        guard let diff, let ch = change(of: c), ch.status == .modified else { return nil }
        var parts: [String] = []
        for r in [MapDiff.Reason.visual, .structure, .routes, .text] where ch.reasons.contains(r) {
            switch r {
            case .visual:
                if tool, c.pixels != nil || c.sizeChanged { parts.append(c.detail) }
                else if c.sizeChanged { parts.append("visual (size changed)") }
                else if let pc = c.percent { parts.append(pc < 0.01 ? "visual <0.01%" : String(format: "visual %.2f%%", pc)) }
                else { parts.append("visual") }
            case .structure: parts.append("structure")
            case .routes:
                for st in [MapDiff.EdgeChange.Status.added, .removed, .retargeted] {
                    let n = diff.edges.filter { $0.from == ch.lineage && $0.status == st }.count
                    if n > 0 { parts.append(routeWord(st, n)) }
                }
            case .text:
                let n = ch.textAdded.count + ch.textRemoved.count
                parts.append("\(n) text\(n == 1 ? "" : "s") changed")
            }
        }
        return parts.joined(separator: ", ")
    }

    private func title(ofLineage l: String?) -> String {
        guard let l else { return "nothing" }
        switch l {
        case "EXIT": return "the app closing"
        case "CRASH": return "a crash"
        case "SKIPPED", "FAILED": return "nothing (\(l.lowercased()))"
        case "UNFOLLOWED": return "an unfollowed control"
        default: return lineageTitles[l] ?? l
        }
    }

    /// The controls of a screen that were added, removed or sent elsewhere, one line each: `+ "Open Home"`, `- "Share"`,
    /// `> "Open Home" now leads to Inbox`.
    func controlLines(of c: ChangeScreen) -> [String] {
        guard let diff, let ch = change(of: c) else { return [] }
        return diff.edges.filter { $0.from == ch.lineage }.sorted { ($0.status.rawValue, $0.cmd) < ($1.status.rawValue, $1.cmd) }.map { e in
            switch e.status {
            case .added: return "+ \"\(Self.plain(e.action))\""
            case .removed: return "- \"\(Self.plain(e.action))\""
            case .retargeted: return "> \"\(Self.plain(e.action))\" now leads to \(Self.plain(title(ofLineage: e.headTo)))"
            }
        }
    }

    /// A stored crash finding of the comparison: new, fixed, or still there.
    func crashStatus() -> [(status: String, detail: String)] {
        (diff?.findings ?? []).filter { $0.kind == "crash" || $0.kind == "compare" }.map {
            ($0.status == .new ? "new" : $0.status == .fixed ? "fixed" : "still there", $0.detail.split(separator: "\n").first.map(String.init) ?? $0.detail)
        }
    }

    /// "The walk of the head stopped at the time limit": one line of crawl.json's `incomplete`, in words.
    static func unfinishedLine(_ line: String) -> String {
        let isBase = line.hasPrefix("base: ")
        let text = isBase ? String(line.dropFirst(6)) : line
        let what: String
        if text.hasPrefix("--max-seconds") { what = "stopped at the time limit" }
        else if text.hasPrefix("--max-depth") { what = "did not open the deepest level" }
        else if text.hasPrefix("--max-screens") { what = "stopped at the screen limit" }
        else { what = text }
        return "The walk of the \(isBase ? "base" : "head") \(what)"
    }

    /// The merged map, the marks and the counts, from the screens a comparison found (a walk's `compare` list or a history diff).
    /// `baseToMerged` names each base id by the id its pair has in the merged map.
    static func assemble(folder: URL, screens: [ChangeScreen], baseToMerged: [String: String], headMap: ScreenMapData, baseMap: ScreenMapData?,
                         headFindings: [MapFinding], crashes: [ChangeFinding], unfinished: [String]) -> ChangeSet {
        // The merged map: the head's screens, plus the base's that no screen of the head reaches, with the edges that
        // lead into or out of them (base ids named by the head's where the two are paired).
        var mergedScreens = headMap.screens
        var mergedEdges = headMap.edges
        if let baseMap {
            let goneIDs = Set(screens.filter { $0.status == .gone }.compactMap(\.baseID))
            for s in baseMap.screens where goneIDs.contains(s.id) {
                mergedScreens.append(MapScreen(id: "base:" + s.id, activity: s.activity, title: s.title, depth: s.depth,
                                               parent: s.parent.flatMap { baseToMerged[$0] ?? "base:" + $0 }, start: s.start, steps: s.steps,
                                               captures: s.captures, texts: s.texts, settled: s.settled, flaky: s.flaky, controls: s.controls))
            }
            func mapped(_ id: String) -> String { baseToMerged[id] ?? "base:" + id }
            for e in baseMap.edges {
                let from = mapped(e.from)
                var to = e.to
                if case .screen(let t) = e.to { to = .screen(mapped(t)) }
                let touchesGone = goneIDs.contains(e.from) || { if case .screen(let t) = e.to { return goneIDs.contains(t) } else { return false } }()
                guard touchesGone else { continue }
                mergedEdges.append(MapEdge(from: from, action: e.action, cmd: e.cmd, to: to, note: e.note))
            }
        }
        let merged = ScreenMapData(folder: folder, apkName: headMap.apkName, screens: mergedScreens, edges: mergedEdges, findings: headFindings,
                                   combos: headMap.combos, incomplete: headMap.incomplete, seconds: headMap.seconds, apk: headMap.apk)
        var marks: [String: MapMark] = [:]
        for s in screens {
            switch s.status {
            case .new: marks[s.id] = MapMark(label: "new", color: s.status.color, tintRoutes: true)
            case .changed: marks[s.id] = MapMark(label: "changed", color: s.status.color, tintRoutes: false)
            case .gone: marks[s.id] = MapMark(label: "gone", color: s.status.color, tintRoutes: true)
            case .unreached: marks[s.id] = MapMark(label: "not reached", color: s.status.color, tintRoutes: false)
            case .same: break
            }
        }

        let report = folder.appendingPathComponent("report.html")
        var counts = Evidence.ChangesSummary()
        for c in screens { switch c.status { case .new: counts.new += 1; case .changed: counts.changed += 1; case .gone: counts.gone += 1; case .same: counts.same += 1; case .unreached: break } }
        return ChangeSet(folder: folder, summary: counts, unreached: screens.filter { $0.status == .unreached }.count, screens: screens, headMap: headMap, baseMap: baseMap, merged: merged,
                         marks: marks, crashes: crashes, unfinished: unfinished,
                         reportURL: FileManager.default.fileExists(atPath: report.path) ? report : nil)
    }

    /// Head and base are one build: nothing is walked. `map` is the head's evidence map when it has one (its screens count as the same).
    static func identical(folder: URL, map: ScreenMapData?) -> ChangeSet {
        let empty = ScreenMapData(folder: folder, apkName: "", screens: [], edges: [], findings: [], combos: [], incomplete: [], seconds: 0, apk: nil)
        let m = map ?? empty
        var counts = Evidence.ChangesSummary()
        counts.same = m.screens.count
        var set = ChangeSet(folder: folder, summary: counts, unreached: 0, screens: [], headMap: m, baseMap: nil, merged: m, marks: [:], crashes: [],
                            unfinished: [], reportURL: nil)
        set.identical = true
        return set
    }

    /// A line of text from the app or the crawler for a Markdown summary: one line, and an `@name` in backticks so that pasting
    /// it into GitHub notifies nobody.
    static func plain(_ text: String) -> String {
        let one = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return one.contains("@") ? "`" + one.replacingOccurrences(of: "`", with: "'") + "`" : one
    }

    /// The summary for a pull request description: counts, then a line per screen that differs.
    func markdown(head: String, base: String) -> String {
        var out = ["## Changes: \(Self.plain(head)) against \(Self.plain(base))", ""]
        let s = summary
        out.append("\(s.new) new, \(s.changed) changed, \(s.gone) gone, \(s.same) the same" + (unreached > 0 ? ", \(unreached) not reached (a walk did not finish)." : "."))
        if let baseline { out.append(""); out.append("Baseline: \(Self.plain(baseline)).") }
        if !differing.isEmpty { out.append("") }
        for c in differing {
            switch c.status {
            case .new: out.append("+ \(Self.plain(c.title)) (new)")
            case .changed:
                out.append("~ \(Self.plain(c.title)): \(Self.plain(reasons(of: c) ?? c.detail))")
                let controls = controlLines(of: c)
                for l in controls.prefix(3) { out.append("  " + l) }
                if controls.count > 3 { out.append("  +\(controls.count - 3) more") }
            case .gone: out.append("- \(Self.plain(c.title)) (gone)")
            case .same, .unreached: break
            }
        }
        if identical { out.append(""); out.append("Head and base are the same build.") }
        else if isUnchanged { out.append(""); out.append(unreached > 0 ? "No screen differs among those both walks reached." : "No screen differs.") }
        if diff != nil {
            let found = crashStatus()
            if !found.isEmpty { out.append(""); for c in found { out.append("Crash, \(c.status): \(Self.plain(c.detail))") } }
        } else if !crashes.isEmpty {
            out.append("")
            for c in crashes { out.append("Crash in the \(c.side == .base ? "base" : "head"): \(Self.plain(c.detail.split(separator: "\n").first.map(String.init) ?? c.detail))") }
        }
        if !unfinished.isEmpty { out.append(""); out += unfinished.map { "Note: " + $0 + "." } }
        return out.joined(separator: "\n") + "\n"
    }

    static func describe(_ b: Build, name: String? = nil) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let source: String
        switch b.source { case .local: source = "built here"; case .ci: source = "CI"; case .remote: source = "remote"; case .file: source = "file" }
        var lead = name ?? b.ref ?? b.apk.deletingPathExtension().lastPathComponent
        if let sha = b.sha, !sha.isEmpty { lead += " " + String(sha.prefix(7)) }
        return "\(lead) (\(source), \(abs(b.date.timeIntervalSinceNow) < 60 ? "just now" : f.localizedString(for: b.date, relativeTo: Date())))"
    }
}

// MARK: - A comparison being made

/// Resolves the base through `Bases`, then asks `Evidence.changes` for the pair. It builds nothing: a base with no build
/// ends in an offer the sheet shows, and the person decides.
final class ChangesRun {
    enum State {
        case idle
        case resolving
        case offer(BuildOffer)
        case walking(depth: Int?, known: Int, since: Date)
        /// The comparison is with the base branch, and the project has no map of it yet: its one full walk is not
        /// done. Nothing is compared until it is; `waiting` while that walk is on its way (the comparison then starts
        /// by itself), false when something has to be done first.
        case needsMain(title: String, text: String, waiting: Bool)
        case done(ChangeSet)
        case failed(String)
        case cancelled
    }

    private(set) var state: State = .idle { didSet { onState?(state) } }
    var onState: ((State) -> Void)?
    private(set) var head: Build?
    private(set) var base: Build?
    let session: Session
    private unowned let controller: SessionsController
    private var generation = 0
    private var token: Evidence.Token?

    init(session: Session, controller: SessionsController) { self.session = session; self.controller = controller }

    var isActive: Bool {
        switch state {
        case .resolving, .walking: return true
        case .needsMain(_, _, let waiting): return waiting
        default: return false
        }
    }

    /// The session's newest build, filed in the store if only the worktree's Gradle output exists.
    private func headBuild() async -> Build? {
        let path = session.worktree.path
        if let b = controller.builds[path] ?? session.build { return b }
        guard let out = session.outputs else { return nil }
        let store = controller.store, sha = session.head, ref = session.branch, dirty = session.dirty
        return await Task.detached { store.record(apk: out.apk, source: .local, sha: sha, ref: ref, dirty: dirty, date: out.date) }.value
    }

    func start(base ref: BaseRef, baseOption: String = "", start: String? = nil) {
        cancel()
        generation += 1
        let gen = generation
        state = .resolving
        let session = self.session
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let head = await self.headBuild() else {
                if gen == self.generation { self.state = .failed("\(session.title) has no build yet. Build it first, then compare.") }
                return
            }
            guard gen == self.generation else { return }
            self.head = head
            guard let ws = self.controller.workspace(of: session) else { self.state = .failed("That repository is no longer in Sessions."); return }
            // With the base branch: from the project's map of it, with only what this branch changed walked. Never a
            // walk of the base for this comparison.
            if case .baseBranch = ref, baseOption.isEmpty, start == nil, await self.fromMain(head: head, workspace: ws, gen: gen) { return }
            guard gen == self.generation else { return }
            let resolved = await Bases.resolve(base: ref, in: ws, sessions: self.controller.sessions, store: self.controller.store, worktree: session.worktree)
            guard gen == self.generation else { return }
            switch resolved {
            case .failed(let why): self.state = .failed(why)
            case .offer(let o): self.state = .offer(o)
            case .build(let base):
                self.base = base
                if base.key == head.key, baseOption.isEmpty {
                    // One build against itself: nothing to walk twice.
                    let evidence = self.controller.evidence
                    let map = ScreenMapData.read(evidence.mapFolder(for: head.key))
                    self.state = .done(ChangeSet.identical(folder: evidence.changesFolder(head: head.key, base: base.key), map: map))
                    return
                }
                self.state = .walking(depth: nil, known: 0, since: Date())
                // From history: both builds' maps are stored, so nothing is walked. A stored base and a head with none is
                // walked alone (the evidence walk files it), then compared from history. Anything else is a pair walk, as before.
                if baseOption.isEmpty, await self.fromHistory(head: head, base: base, workspace: ws, start: start, gen: gen) { return }
                guard gen == self.generation else { return }
                self.token = self.controller.evidence.changes(head: head, base: base, start: start, baseOption: baseOption, progress: { [weak self] e in
                    guard let self, gen == self.generation, case .walking(var depth, var known, let since) = self.state else { return }
                    switch e {
                    case .level(let d, _, let k): depth = d; known = k
                    case .capturing(let n, _): depth = -1; known = n
                    case .line, .screen: return
                    }
                    self.state = .walking(depth: depth, known: known, since: since)
                }, completion: { [weak self] result in
                    guard let self, gen == self.generation else { return }
                    switch result {
                    case .success(let r):
                        if let set = ChangeSet.read(r.folder) {
                            self.state = .done(set)
                            // The pair's walk gave both builds' maps: filed, so the next comparison with this base walks only its head.
                            if baseOption.isEmpty { self.fileFromPair(folder: r.folder, head: head, base: base, workspace: ws, start: start) }
                        } else { self.state = .failed("The comparison finished but its result could not be read.") }
                    case .failure(let f): self.state = f.message == "cancelled" ? .cancelled : .failed(f.message)
                    }
                })
            }
        }
    }

    /// Answers from stored snapshots when it can. True when the comparison ended here (done or failed); false to walk the pair.
    @MainActor
    private func fromHistory(head: Build, base: Build, workspace ws: Workspace, start: String?, gen: Int) async -> Bool {
        let evidence = controller.evidence
        let profile = evidence.changesProfile(start: start)
        let root = evidence.store.root
        let folder = evidence.changesFolder(head: head.key, base: base.key)
        func attempt() async -> ChangeSet? {
            await Task.detached { await History.changeSet(head: head, base: base, workspace: ws.root, profile: profile, stateRoot: root, folder: folder) }.value
        }
        if let set = await attempt() {
            guard gen == generation else { return true }
            state = .done(set)
            return true
        }
        // Only the head lacks a map: one walk of it (it is filed when it ends), no walk of the base.
        guard start == nil, History.fileable(head), await History.hasSnapshot(of: base, workspace: ws.root, profile: profile, stateRoot: root) else { return false }
        let result: Result<Evidence.ChangesResult, Evidence.Failure> = await withCheckedContinuation { c in
            self.token = evidence.walkHead(head, progress: { [weak self] e in
                guard let self, gen == self.generation, case .walking(var depth, var known, let since) = self.state else { return }
                switch e {
                case .level(let d, _, let k): depth = d; known = k
                case .capturing(let n, _): depth = -1; known = n
                case .line, .screen: return
                }
                self.state = .walking(depth: depth, known: known, since: since)
            }, completion: { c.resume(returning: $0) })
        }
        guard gen == generation else { return true }
        switch result {
        case .failure(let f):
            state = f.message == "cancelled" ? .cancelled : .failed(f.message)
            return true
        case .success:
            await evidence.awaitFiling(head)
            guard gen == generation else { return true }
            if let set = await attempt() { state = .done(set); return true }
            return false
        }
    }

    // MARK: Against the project's map of the base branch

    /// What the base branch's first walk is doing, for the card that holds a comparison back.
    private func mainWords(_ ws: Workspace) -> (title: String, text: String, waiting: Bool) {
        let name = MainBuilds.shortName(ws.baseRef)
        let evidence = controller.evidence, main = controller.mainBuilds
        let intro = "A pull request is compared with a map of \(name), made by walking \(name) once for this project. After that, only the screens a change touches are walked."
        guard main.applies(to: ws) else {
            return ("\(name) has not been walked yet", intro + " Turn on \u{201C}Keep \(name) Built\u{201D} in the repository's + menu and the walk starts by itself.", false)
        }
        if ws.auto == .off {
            return ("\(name) has not been walked yet", intro + " Walking is off for this repository: turn it on in the repository's + menu.", false)
        }
        switch evidence.entry(of: main.trunk(of: ws.root).path) {
        case nil:
            return ("Waiting for a build of \(name)", intro + " Its walk starts when the build is there.", true)
        case let e?:
            switch e.status {
            case .queued: return ("\(name)'s first walk is queued", intro, true)
            case .walking(_, let known):
                let n = max(known, e.explored)
                return ("Walking \(name) for the first time", intro + (n > 0 ? " \(n) screen\(n == 1 ? "" : "s") found so far." : ""), true)
            case .failed(let why): return ("\(name)'s walk failed", why + " Walk it again from \(name)'s row.", false)
            case .stopped: return ("\(name)'s walk was stopped", intro + " Walk it again from \(name)'s row.", false)
            case .done:
                return e.saved ? ("\(name)'s map cannot be used here", "\(name) was walked with other settings than this session's walks (signed in or not, or how deep), so the two cannot be compared. Walk \(name) again from its row.", false)
                    : ("Filing \(name)'s map", intro, true)
            }
        }
    }

    /// The comparison with the base branch, from the stored map of it. True when the comparison ended or is held here;
    /// false to compare as before (an engine that cannot start from an earlier walk, a build with uncommitted changes).
    @MainActor
    private func fromMain(head: Build, workspace ws: Workspace, gen: Int) async -> Bool {
        let evidence = controller.evidence, root = evidence.store.root, path = session.worktree.path
        guard History.fileable(head), let python = SnapshotRun.python() else { return false }
        let support = await Task.detached { CrawlRun.support(python: python) }.value
        guard support.seed, support.recordDeps, gen == generation else { return false }
        let withData = controller.walksWithData(session)
        let profiles = evidence.walkProfiles(worktree: path, withData: withData)

        // 1. The map of the base branch: held here until it is there.
        func baseline() async -> (profile: MapProfile, snapshot: MapSnapshot, behind: Int)? {
            for p in profiles {
                if let b = await History.baseline(of: head, profile: p, candidates: [ws], stateRoot: root) { return (p, b.snapshot, b.behind) }
            }
            return nil
        }
        var found = await baseline()
        if found == nil { controller.mainBuilds.ensure(ws) }
        while found == nil {
            guard gen == generation else { return true }
            let w = mainWords(ws)
            state = .needsMain(title: w.title, text: w.text, waiting: w.waiting)
            guard w.waiting else { return true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard gen == generation else { return true }
            found = await baseline()
        }
        guard gen == generation, let base = found else { return true }

        // 2. This build's own map: the session's walk of it (seeded from the base branch's, so only what changed).
        func snapshot() async -> MapSnapshot? { await History.snapshot(of: head, workspace: ws.root, profile: base.profile, stateRoot: root) }
        var mine = await snapshot()
        if mine == nil {
            let since = Date()
            state = .walking(depth: nil, known: 0, since: since)
            evidence.buildArrived(worktree: path, build: head, auto: .onBuild, withData: withData)
            walking: while true {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard gen == generation else { return true }
                guard let e = evidence.entry(of: path), e.key == head.key else { state = .failed("A newer build of \(session.title) arrived. Compare again."); return true }
                switch e.status {
                case .queued: break
                case .walking(let depth, let known): state = .walking(depth: depth, known: max(known, e.explored), since: since)
                case .failed(let why): state = .failed(why); return true
                case .stopped: state = .cancelled; return true
                case .done: break walking
                }
            }
            await evidence.awaitFiling(head)
            guard gen == generation else { return true }
            mine = await snapshot()
        }
        // Walked, and not filed under the base's settings (signed in on one side only): compared as before.
        guard let mine else { return false }

        let folder = evidence.changesFolder(head: head.key, base: "map-" + String(base.snapshot.commit.prefix(12)))
        let name = MainBuilds.shortName(ws.baseRef), short = String(base.snapshot.commit.prefix(7))
        if mine.commit == base.snapshot.commit {
            state = .done(ChangeSet.identical(folder: folder, map: ScreenMapData.read(evidence.mapFolder(for: head.key))))
            return true
        }
        let words = base.behind == 0 ? "\(name) at \(short), where this branch left it"
            : "\(name) at \(short), \(base.behind) commit\(base.behind == 1 ? "" : "s") before this branch left it"
        let note = Evidence.impactNote(evidence.mapFolder(for: head.key))
        let why = note?.why ?? [:]
        let store = History.store(stateRoot: root, workspace: ws.root), baseSnap = base.snapshot
        var set = await Task.detached { ChangeSet.fromHistory(head: mine, base: baseSnap, store: store, folder: folder, baseline: words) }.value
        guard gen == generation else { return true }
        set.walkedBecause = why
        set.unplaced = note?.unplaced ?? []
        state = .done(set)
        return true
    }

    /// Files the heads and bases of a finished pair walk (each that has a commit and is not dirty).
    private func fileFromPair(folder: URL, head: Build, base: Build, workspace ws: Workspace, start: String?) {
        let evidence = controller.evidence
        let profile = evidence.changesProfile(start: start), root = evidence.store.root, engine = Engine.shared.version
        Task.detached {
            // The base first: the head's baseline is then the base when it is the merge base.
            await History.fileFromPair(folder: folder, build: base, side: .base, workspace: ws, profile: profile, stateRoot: root, engine: engine)
            await History.fileFromPair(folder: folder, build: head, side: .head, workspace: ws, profile: profile, stateRoot: root, engine: engine)
        }
    }

    func cancel() {
        generation += 1
        token?.cancel()
        token = nil
        if isActive { state = .cancelled }
    }
}

// MARK: - The change tour

/// For each new or changed screen (12 at most) a hidden simulator of the head build and one of the base build are taken
/// there by the map's own route (what "Go there" replays), held for 1.5 s, and recorded with a chapter mark per screen:
/// `tour-head.mp4`, `tour-base.mp4`, `tour.json` beside the comparison. A new screen has no base route: its base
/// simulator just stands where it is. Cached with the pair; skipped, with a line saying why, when a route cannot be replayed.
final class ChangeTour {
    struct Stop: Codable, Equatable {
        var id: String
        var title: String
        var status: String
        /// Reached on the head's simulator, and on the base's (a new screen has no base route).
        var head: Bool
        var base: Bool
    }

    struct Result {
        let folder: URL
        let head: URL?
        let base: URL?
        /// Why there is no tour.
        let skipped: String?
        let stops: [Stop]

        static func read(_ folder: URL) -> Result? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("tour.json")),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let stops = ((json["stops"] as? [[String: Any]]) ?? []).map {
                Stop(id: ($0["id"] as? String) ?? "", title: ($0["title"] as? String) ?? "", status: ($0["status"] as? String) ?? "",
                     head: ($0["head"] as? Bool) ?? false, base: ($0["base"] as? Bool) ?? false)
            }
            func file(_ n: String) -> URL? {
                let u = folder.appendingPathComponent(n)
                return FileManager.default.fileExists(atPath: u.path) ? u : nil
            }
            return Result(folder: folder, head: file("tour-head.mp4"), base: file("tour-base.mp4"), skipped: json["skipped"] as? String, stops: stops)
        }

        func chapters(of file: URL?) -> [Recorder.Chapter] {
            guard let file else { return [] }
            let url = file.deletingPathExtension().appendingPathExtension("chapters.json")
            return (try? JSONDecoder().decode([Recorder.Chapter].self, from: Data(contentsOf: url))) ?? []
        }
    }

    enum Outcome { case done(Result), cancelled, failed(String) }

    static let maxStops = 12
    static let hold = 1.5

    private(set) var isRunning = false
    private var cancelled = false
    private var sims: [Simulator] = []
    private var slots: [String] = []
    private var logs: [URL] = []
    /// The engine processes of the simulators this tour started, for checks.
    private(set) var processIDs: [Int32] = []

    /// Tours running now. Their simulators are not on the stage (`Engine.simulators`), so nothing else would quit them
    /// when the app does.
    private static var active: [ChangeTour] = []
    private static let quitObserver: NSObjectProtocol = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
        quitAll()
    }

    /// Quits every running tour's simulators and removes their data slots and logs (the app is quitting). Bounded.
    static func quitAll() {
        for t in active { t.cancelled = true; t.teardown(wait: true) }
        pendingLock.lock(); let left = pendingLogs; pendingLogs = []; pendingLock.unlock()
        for f in left { try? FileManager.default.removeItem(at: f) }   // a finished tour's cleanup the quit overtook
    }

    /// Logs of simulators that were quit and whose process has not yet been seen to exit: removed then, or at quit.
    private static var pendingLogs: Set<URL> = []
    private static let pendingLock = NSLock()

    /// Removes tour logs nothing owns: a crash or a quit that overtook a cleanup left them (older than ten minutes, not a running tour's).
    static func sweepLogs() {
        let mine = Set(active.flatMap(\.logs))
        let dir = Engine.shared.logs
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.lastPathComponent.hasPrefix("tour-") && !mine.contains(f) {
            let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if Date().timeIntervalSince(d) > 600 { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// The screens a tour visits, the first 12 that are new or changed.
    static func stops(of set: ChangeSet) -> [ChangeScreen] {
        Array(set.screens.filter { $0.status == .new || $0.status == .changed }.prefix(maxStops))
    }

    func cancel() {
        cancelled = true
        for s in sims { s.quit() }
    }

    /// `baseOptions` are the engine options of the base build's launches (as the comparison's own walk had).
    func start(set: ChangeSet, head: Build, base: Build, baseOptions: [String], progress: @escaping (String) -> Void,
               completion: @escaping (Outcome) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        _ = Self.quitObserver
        Self.sweepLogs()
        Self.active.append(self)
        Task { @MainActor in
            let outcome = await self.run(set: set, head: head, base: base, baseOptions: baseOptions, progress: progress)
            self.isRunning = false
            Self.active.removeAll { $0 === self }
            completion(outcome)
        }
    }

    private func skip(_ folder: URL, _ why: String, stops: [Stop] = []) -> Outcome {
        write(folder, skipped: why, stops: stops)
        return .done(Result(folder: folder, head: nil, base: nil, skipped: why, stops: stops))
    }

    private func write(_ folder: URL, skipped: String?, stops: [Stop]) {
        var json: [String: Any] = ["stops": stops.map { ["id": $0.id, "title": $0.title, "status": $0.status, "head": $0.head, "base": $0.base] as [String: Any] }]
        if let skipped { json["skipped"] = skipped }
        try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("tour.json"), options: .atomic)
    }

    /// A simulator that is not on the stage, so it is not in `Engine.simulators`: this tour (and `ChangeTour.quitAll`) quits it.
    /// The caller calls `Engine.prepare` once before the first: it clears the tokens folder while no simulator is on the
    /// stage, and these are not, so calling it again here would delete the first simulator's token before the second started.
    private func sim(apk: URL, options: [String]) throws -> Simulator {
        let log = Engine.shared.logs.appendingPathComponent("tour-\(UUID().uuidString.prefix(8)).log")
        logs.append(log)
        let s = Simulator(apk: apk, log: log)
        try s.start(launcher: Engine.shared.launcher, stateDir: Engine.shared.engineState, options: options, controlToken: Engine.shared.supportsControlToken)
        sims.append(s)
        processIDs.append(s.processID)
        return s
    }

    private func teardown(wait: Bool = false) {
        let all = sims, names = slots, files = logs, root = Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true)
        sims = []; slots = []; logs = []
        Self.pendingLock.lock(); files.forEach { Self.pendingLogs.insert($0) }; Self.pendingLock.unlock()
        for s in all { s.quit() }
        let finish = {
            for s in all { s.waitUntilExit() }
            for n in names { SlotClone.remove(n, in: root) }
            for f in files { try? FileManager.default.removeItem(at: f) }
            Self.pendingLock.lock(); files.forEach { Self.pendingLogs.remove($0) }; Self.pendingLock.unlock()
        }
        if wait {
            finish()   // the app is quitting: Simulator.quit ends a process that ignores "quit" after 3 s
        } else {
            DispatchQueue.global(qos: .utility).async(execute: finish)
        }
    }

    /// The controls of a route as `Go there` replays them: a restart (at the route's deep link), each step, a settle after each.
    private static func navigate(_ sim: Simulator, start: String?, steps: [String]) -> String? {
        let commands = [start.map { "restart \($0)" } ?? "restart"] + steps
        for (i, c) in commands.enumerated() {
            let answer = sim.sendSync(c)
            if answer.hasPrefix("error") { return "step \(i) (\(ScreenMap.describe(c))) failed: " + answer.replacingOccurrences(of: "error: ", with: "") }
            _ = sim.sendSync("settle 1500 100")
        }
        return nil
    }

    @MainActor
    private func run(set: ChangeSet, head: Build, base: Build, baseOptions: [String], progress: @escaping (String) -> Void) async -> Outcome {
        let folder = set.folder
        let wanted = Self.stops(of: set)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("tour.json"))
        if wanted.isEmpty { return skip(folder, "No screen is new or changed, so there is nothing to record.") }
        // Each tour records under names of its own and moves them into place at the end, so a tour that was cancelled and is
        // still finishing never shares a file with the one that replaced it.
        let tag = String(UUID().uuidString.prefix(8))
        let headFile = folder.appendingPathComponent("tour-\(tag)-head.mp4"), baseFile = folder.appendingPathComponent("tour-\(tag)-base.mp4")

        // A route per screen: the head's for a new or changed screen, the base's for a changed one.
        struct Route { var start: String?; var steps: [String] }
        func route(_ map: ScreenMapData?, _ id: String?) -> Route? {
            guard let id, let s = map?.screen(id) else { return nil }
            return Route(start: s.start, steps: s.steps)
        }
        let headRoutes = wanted.map { route(set.headMap, $0.headID) }
        let baseRoutes = wanted.map { $0.status == .changed ? route(set.baseMap, $0.baseID) : nil }
        if headRoutes.allSatisfy({ $0 == nil }) { return skip(folder, "The map has no route to these screens, so the tour cannot replay them.") }

        // Two hidden simulators, each with data of its own that goes afterwards.
        let slotH = SlotClone.freshName(), slotB = SlotClone.freshName()
        slots = [slotH, slotB]
        let hs: Simulator, bs: Simulator
        do {
            try Engine.shared.prepare()
            hs = try sim(apk: head.apk, options: ["--data-slots", slotH, "--appearance", "light"])
            bs = try sim(apk: base.apk, options: ["--data-slots", slotB, "--appearance", "light"] + baseOptions)
        } catch {
            teardown()
            return skip(folder, "The tour could not start the two builds: \(error.localizedDescription)")
        }
        progress("Starting both builds…")
        let ready = Date().addingTimeInterval(150)
        while !cancelled, Date() < ready, !(hs.state == .running && hs.framesShown > 0 && bs.state == .running && bs.framesShown > 0) {
            if !hs.isAlive || !bs.isAlive { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if cancelled { teardown(); return .cancelled }
        guard hs.state == .running, bs.state == .running, hs.framesShown > 0, bs.framesShown > 0 else {
            teardown()
            return skip(folder, "The tour could not start the two builds (one of them did not draw a first frame).")
        }
        let hr = Recorder(simulator: hs), br = Recorder(simulator: bs)
        guard hr.start(to: headFile), br.start(to: baseFile) else {
            teardown()
            return skip(folder, "The tour could not start recording.")
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)   // the first keyframes

        var stops: [Stop] = []
        for (i, screen) in wanted.enumerated() where !cancelled {
            progress("Recording \(screen.title) (\(i + 1) of \(wanted.count))…")
            let hRoute = headRoutes[i], bRoute = baseRoutes[i]
            async let headResult: String? = Task.detached { if let r = hRoute { return Self.navigate(hs, start: r.start, steps: r.steps) } else { return "no route" } }.value
            async let baseResult: String? = Task.detached { if let r = bRoute { return Self.navigate(bs, start: r.start, steps: r.steps) } else { return nil } }.value
            let (hFail, bFail) = await (headResult, baseResult)
            hr.mark(screen.title)
            br.mark(screen.title)
            try? await Task.sleep(nanoseconds: UInt64(Self.hold * 1e9))
            stops.append(Stop(id: screen.id, title: screen.title, status: screen.status.word, head: hFail == nil, base: bRoute != nil && bFail == nil))
        }

        async let hFiles: [URL] = withCheckedContinuation { c in hr.stop { c.resume(returning: $0) } }
        async let bFiles: [URL] = withCheckedContinuation { c in br.stop { c.resume(returning: $0) } }
        let (hf, bf) = await (hFiles, bFiles)
        teardown()
        func discard(_ files: [URL]) {
            for f in files { try? FileManager.default.removeItem(at: f); try? FileManager.default.removeItem(at: f.deletingPathExtension().appendingPathExtension("chapters.json")) }
        }
        if cancelled { discard(hf + bf); return .cancelled }
        guard !stops.isEmpty, stops.contains(where: { $0.head }), let hFile = hf.first else {
            discard(hf + bf)
            return skip(folder, "No route could be replayed on the head build, so there is no tour.", stops: stops)
        }
        // Into place: the clips and their chapters under their final names (the files this tour made are all there is of them).
        func place(_ file: URL?, as name: String) -> URL? {
            let fm = FileManager.default
            let final = folder.appendingPathComponent(name)
            for u in [final, final.deletingPathExtension().appendingPathExtension("chapters.json")] { try? fm.removeItem(at: u) }
            guard let file, (try? fm.moveItem(at: file, to: final)) != nil else { return nil }
            let side = file.deletingPathExtension().appendingPathExtension("chapters.json")
            try? fm.moveItem(at: side, to: final.deletingPathExtension().appendingPathExtension("chapters.json"))
            return final
        }
        let placedHead = place(hFile, as: "tour-head.mp4"), placedBase = place(bf.first, as: "tour-base.mp4")
        discard(Array(hf.dropFirst()) + Array(bf.dropFirst()))
        write(folder, skipped: nil, stops: stops)
        return .done(Result(folder: folder, head: placedHead, base: placedBase, skipped: nil, stops: stops))
    }
}
