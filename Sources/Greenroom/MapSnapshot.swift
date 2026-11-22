import CryptoKit
import Foundation

// Map history's contract (docs/MAP-HISTORY-PLAN.md): the stored form of one commit's screen map (`MapSnapshot`), the
// settings two walks must share to be compared (`MapProfile`), and the difference of two snapshots (`MapDiff`).
// Everything here is plain data and pure functions: no simulator, no files, no AppKit. The store (MapStore), the
// pairing (MapDiff's `pair`, package H2), git (MapGit) and the canvas are built against these shapes.

/// The one JSON form everything is written in: sorted keys, pretty printed, a final newline. The same value always
/// gives the same bytes, so a snapshot can be compared, hashed and kept in git.
enum MapJSON {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = (try? e.encode(value)) ?? Data()
        data.append(10)
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
}

/// How a walk was made (`.greenroom/map.json` in the repository). Two snapshots are compared only when their
/// profiles have the same `id`; another profile is another history.
struct MapProfile: Codable, Equatable {
    var depth = 2
    var seconds = 120
    /// Deep links the walk starts from; none is the launcher activity.
    var starts: [String] = []
    /// The capture combinations, in order ("light", "dark").
    var combos: [String] = ["light"]
    /// The sign-in script's name, when the walk runs signed in.
    var signIn: String?
    var offline = false

    /// Eight hex digits over the settings: the name of this history in the store and in git's refs.
    var id: String { String(MapJSON.sha256(MapJSON.encode(self)).prefix(8)) }
}

/// One commit's screen map. Screens are in id order and edges in (from, order) order (`canonical`), captures are named
/// by the SHA-256 of their PNG, so the bytes of `data()` depend only on what the walk found.
struct MapSnapshot: Codable, Equatable {
    static let schema = 1
    /// Where an edge leads when it is not a screen (crawl.json's words); nil is a control that was not followed.
    static let pseudo: Set<String> = ["EXIT", "CRASH", "SKIPPED", "FAILED"]

    struct Deps: Codable, Equatable {
        /// App classes whose code ran while the screen was reached and shown.
        var classes: [String] = []
        /// Resources it resolved, as `type/name` ("layout/trip_row").
        var resources: [String] = []
    }

    struct Screen: Codable, Equatable {
        /// crawl.json's id: `Activity-HASH`, the activity and a hash of the screen's structure.
        var id: String
        /// The same for as long as the screen can be paired with its predecessor: its id where it first appeared and
        /// that commit's first seven digits ("TripsActivity-1f0e9a22@53ffe80"). Empty until the store assigns it.
        var lineage: String
        var activity: String
        var title: String
        var depth: Int
        var parent: String?
        /// The route: a deep link (nil: the launcher activity), then control commands.
        var start: String?
        var steps: [String]
        /// Combination name to the capture's blob (the SHA-256 of the PNG).
        var captures: [String: String]
        var texts: [String]
        var settled = true
        var flaky: String?
        /// Nil: walked at this snapshot's commit. Else the commit whose walk this entry was carried from.
        var carriedFrom: String?
        var deps: Deps?
    }

    struct Edge: Codable, Equatable {
        var from: String
        /// The control's place among the screen's controls, as the walk tried them.
        var order: Int
        var action: String
        var cmd: String
        /// A screen's id, one of `pseudo`, or nil for a control that was not followed.
        var to: String?
        var note: String?
    }

    struct Finding: Codable, Equatable {
        var kind: String
        var detail: String
        var steps: [String]
    }

    var schema = MapSnapshot.schema
    var commit: String
    /// The commit's git tree: a commit with the same tree is the same app and shares this snapshot.
    var tree: String
    var profile: MapProfile
    /// The engine's version: a new engine may read screens differently, so it starts a full walk.
    var engine: String
    /// When the walk ended, ISO 8601.
    var walked: String
    var screens: [Screen]
    var edges: [Edge]
    var findings: [Finding] = []
    /// What the walk did not finish, in crawl.json's words ("--max-seconds ...").
    var incomplete: [String] = []
    var seconds: Double = 0

    func screen(_ id: String) -> Screen? { screens.first { $0.id == id } }

    /// Whether the walk was cut short by something other than its depth (a depth limit is the profile's choice): then
    /// a screen missing here may only not have been reached.
    var cutShort: Bool { incomplete.contains { !$0.hasPrefix("--max-depth") } }

    /// The stored order: screens by id, edges by screen and control order, dependency lists sorted.
    func canonical() -> MapSnapshot {
        var s = self
        s.screens.sort { $0.id < $1.id }
        for i in s.screens.indices {
            s.screens[i].deps?.classes.sort()
            s.screens[i].deps?.resources.sort()
        }
        s.edges.sort { ($0.from, $0.order, $0.cmd) < ($1.from, $1.order, $1.cmd) }
        return s
    }

    func data() -> Data { MapJSON.encode(canonical()) }
    static func read(_ data: Data) -> MapSnapshot? {
        guard let s = MapJSON.decode(MapSnapshot.self, from: data), s.schema == schema else { return nil }
        return s
    }
}

/// What differs between two snapshots of one profile. Screens are named by lineage, so a screen whose structure (and
/// with it its id) changed is one modified screen.
struct MapDiff: Codable, Equatable {
    enum Status: String, Codable {
        case added, removed, modified, same
        /// Never settles, flaky, or a walk that was cut short did not reach it: not counted as a change.
        case notCompared
    }

    /// Why a screen is modified. More than one can hold.
    enum Reason: String, Codable, CaseIterable {
        /// A capture's pixels differ.
        case visual
        /// The tree changed: the screen has another id.
        case structure
        /// Visible strings were added or removed.
        case text
        /// A control was added or removed, or leads somewhere else.
        case routes
    }

    /// How a head screen was matched with a base screen (set by the pairing, package H2).
    enum Pairing: String, Codable { case id, position, route }

    struct Pixels: Codable, Equatable {
        var differing: Int
        var total: Int
    }

    struct ScreenChange: Codable, Equatable {
        var lineage: String
        /// The screen's id in each snapshot; nil where it is not.
        var base: String?
        var head: String?
        var status: Status
        var reasons: [Reason] = []
        var pairing: Pairing?
        /// The combinations whose captures differ (their blobs do).
        var visual: [String] = []
        /// How much of each differing capture differs, once the images were compared (the store does; nil before).
        var pixels: [String: Pixels]?
        var textAdded: [String] = []
        var textRemoved: [String] = []
        /// For `notCompared`: why, in words.
        var why: String?
    }

    struct EdgeChange: Codable, Equatable {
        enum Status: String, Codable { case added, removed, retargeted }
        /// The lineage of the screen the control is on.
        var from: String
        var cmd: String
        var action: String
        var status: Status
        /// Where it led and leads: a lineage, one of `MapSnapshot.pseudo`, or "UNFOLLOWED".
        var baseTo: String?
        var headTo: String?
    }

    struct FindingChange: Codable, Equatable {
        enum Status: String, Codable { case new, fixed, still }
        var kind: String
        var detail: String
        var status: Status
    }

    struct Counts: Codable, Equatable {
        var added = 0, removed = 0, modified = 0, same = 0, notCompared = 0
        var differing: Int { added + removed + modified }
    }

    var baseCommit: String
    var headCommit: String
    var profile: String
    /// By lineage.
    var screens: [ScreenChange]
    /// By (from, cmd). Only edges that differ.
    var edges: [EdgeChange]
    var findings: [FindingChange]
    var counts: Counts

    func change(_ lineage: String) -> ScreenChange? { screens.first { $0.lineage == lineage } }
    func data() -> Data { MapJSON.encode(self) }

    /// The difference of two snapshots whose screens already carry their lineages (the store assigns them through the
    /// pairing). Pure: the same two snapshots give the same bytes.
    static func compare(base: MapSnapshot, head: MapSnapshot) -> MapDiff {
        let baseBy = Dictionary(base.screens.map { ($0.lineage, $0) }, uniquingKeysWith: { a, _ in a })
        let headBy = Dictionary(head.screens.map { ($0.lineage, $0) }, uniquingKeysWith: { a, _ in a })

        // Each screen's controls, by command, and where each leads as a lineage.
        func outgoing(_ s: MapSnapshot) -> [String: [String: (action: String, to: String)]] {
            let lineage = Dictionary(s.screens.map { ($0.id, $0.lineage) }, uniquingKeysWith: { a, _ in a })
            var out: [String: [String: (action: String, to: String)]] = [:]
            for e in s.edges {
                guard let from = lineage[e.from] else { continue }
                let to = e.to.map { MapSnapshot.pseudo.contains($0) ? $0 : (lineage[$0] ?? "?") } ?? "UNFOLLOWED"
                out[from, default: [:]][e.cmd] = (e.action, to)
            }
            return out
        }
        let baseOut = outgoing(base), headOut = outgoing(head)

        var screens: [ScreenChange] = []
        var edges: [EdgeChange] = []
        for lineage in Set(baseBy.keys).union(headBy.keys).sorted() {
            let b = baseBy[lineage], h = headBy[lineage]
            let bo = baseOut[lineage] ?? [:], ho = headOut[lineage] ?? [:]
            var routes = false
            for cmd in Set(bo.keys).union(ho.keys).sorted() {
                switch (bo[cmd], ho[cmd]) {
                case let (was?, nil): edges.append(EdgeChange(from: lineage, cmd: cmd, action: was.action, status: .removed, baseTo: was.to, headTo: nil)); routes = true
                case let (nil, now?): edges.append(EdgeChange(from: lineage, cmd: cmd, action: now.action, status: .added, baseTo: nil, headTo: now.to)); routes = true
                case let (was?, now?) where was.to != now.to:
                    edges.append(EdgeChange(from: lineage, cmd: cmd, action: now.action, status: .retargeted, baseTo: was.to, headTo: now.to)); routes = true
                default: break
                }
            }
            guard let b, let h else {
                if let h {
                    screens.append(base.cutShort
                        ? ScreenChange(lineage: lineage, base: nil, head: h.id, status: .notCompared, why: "the base's walk did not finish, so it may be there too")
                        : ScreenChange(lineage: lineage, base: nil, head: h.id, status: .added))
                } else if let b {
                    screens.append(head.cutShort
                        ? ScreenChange(lineage: lineage, base: b.id, head: nil, status: .notCompared, why: "the head's walk did not finish, so it may still be there")
                        : ScreenChange(lineage: lineage, base: b.id, head: nil, status: .removed))
                }
                continue
            }
            var change = ScreenChange(lineage: lineage, base: b.id, head: h.id, status: .same)
            // A screen that never settles has a different capture on every walk: its pixels say nothing.
            let steady = b.settled && h.settled && b.flaky == nil && h.flaky == nil
            if steady {
                change.visual = Set(b.captures.keys).intersection(h.captures.keys).filter { b.captures[$0] != h.captures[$0] }.sorted()
            }
            let was = Set(b.texts), now = Set(h.texts)
            change.textAdded = now.subtracting(was).sorted()
            change.textRemoved = was.subtracting(now).sorted()
            for r in Reason.allCases {
                switch r {
                case .visual: if !change.visual.isEmpty { change.reasons.append(r) }
                case .structure: if b.id != h.id { change.reasons.append(r) }
                case .text: if was != now { change.reasons.append(r) }
                case .routes: if routes { change.reasons.append(r) }
                }
            }
            if !change.reasons.isEmpty { change.status = .modified }
            else if !steady { change.status = .notCompared; change.why = "it never settles, so its captures are not compared" }
            screens.append(change)
        }

        func key(_ f: MapSnapshot.Finding) -> String { f.kind + "\u{1}" + (f.detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? "") }
        let wasFound = Dictionary(base.findings.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let nowFound = Dictionary(head.findings.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let findings: [FindingChange] = Set(wasFound.keys).union(nowFound.keys).sorted().map { k in
            let f = nowFound[k] ?? wasFound[k]!
            return FindingChange(kind: f.kind, detail: f.detail, status: wasFound[k] == nil ? .new : (nowFound[k] == nil ? .fixed : .still))
        }

        var counts = Counts()
        for s in screens {
            switch s.status {
            case .added: counts.added += 1
            case .removed: counts.removed += 1
            case .modified: counts.modified += 1
            case .same: counts.same += 1
            case .notCompared: counts.notCompared += 1
            }
        }
        return MapDiff(baseCommit: base.commit, headCommit: head.commit, profile: head.profile.id, screens: screens, edges: edges, findings: findings, counts: counts)
    }
}
