import Foundation

// Map history's pairing (docs/MAP-HISTORY-PLAN.md, "The diff", package H2): which screen of a base snapshot each screen
// of a head snapshot continues, so a screen keeps its lineage when its tree (and with it its id) changes. It reads only
// what a walk gives: ids, parents, routes, edges and activity names; never the head's own lineages. Pure: the same two
// snapshots give the same lineages, whatever order their screens and edges come in.
//
// In order, a head screen takes a base screen's lineage when:
// 1. `.id`: the base has a screen with its id.
// 2. `.position`: a paired screen's control (the same command) leads to it here and, in the base, to a screen not yet
//    paired. This runs outwards from what is paired, round by round, so a chain of restructured screens resolves from
//    its paired ancestor down.
// 3. `.route`: an unpaired base screen has its start and steps. One at a time, shallowest first, and after each the
//    positions are followed again from it, so a restructured home screen brings its restructured children with it.
// 4. Otherwise it is new: `<id>@<the head commit's first seven digits>`. A base screen left over was removed.
//
// A base screen pairs with at most one head screen, and a head screen with one base screen. Ties are settled by order,
// never by a dictionary's: within a round of positions the candidates are taken in (the control is the head screen's
// parent's and the base screen's parent's (a link in the tree beats a link back), the from-screen's lineage, the
// command, the head id, the base id) order, the first to claim a screen keeps it. Routes are tried in (depth, head id)
// order against base screens in id order.
enum MapPairing {
    /// The head with every screen's lineage set, and how each paired lineage was matched (new screens are not in it).
    static func pair(head: MapSnapshot, base: MapSnapshot?) -> (MapSnapshot, [String: MapDiff.Pairing]) {
        var out = head
        let short = String(head.commit.prefix(7))
        guard let base else {
            for i in out.screens.indices { out.screens[i].lineage = out.screens[i].id + "@" + short }
            return (out.canonical(), [:])
        }

        let headByID = Dictionary(head.screens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let baseByID = Dictionary(base.screens.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Each screen's controls by command, where they lead (screens only), the first by control order on a repeat.
        func controls(_ s: MapSnapshot, _ known: [String: MapSnapshot.Screen]) -> [String: [(cmd: String, to: String)]] {
            var byFrom: [String: [String: (order: Int, to: String)]] = [:]
            for e in s.edges {
                guard let to = e.to, known[to] != nil, known[e.from] != nil else { continue }
                if let have = byFrom[e.from]?[e.cmd], have.order <= e.order { continue }
                byFrom[e.from, default: [:]][e.cmd] = (e.order, to)
            }
            return byFrom.mapValues { $0.map { (cmd: $0.key, to: $0.value.to) }.sorted { $0.cmd < $1.cmd } }
        }
        let headControls = controls(head, headByID)
        let baseControls = controls(base, baseByID).mapValues { Dictionary($0.map { ($0.cmd, $0.to) }, uniquingKeysWith: { a, _ in a }) }

        var baseOf: [String: String] = [:]   // head id -> base id
        var taken = Set<String>()            // base ids paired
        var how: [String: MapDiff.Pairing] = [:]  // head id -> how

        func join(_ h: String, _ b: String, _ p: MapDiff.Pairing) {
            baseOf[h] = b
            taken.insert(b)
            how[h] = p
        }

        // 1. The same id.
        for s in head.screens.sorted(by: { $0.id < $1.id }) where baseByID[s.id] != nil && !taken.contains(s.id) { join(s.id, s.id, .id) }

        // 2. Position, outwards from `frontier` round by round.
        func follow(_ start: [String]) {
            var frontier = start.sorted()
            while !frontier.isEmpty {
                struct Candidate { let tree: Bool; let from: String; let cmd: String; let head: String; let base: String }
                var candidates: [Candidate] = []
                for h in frontier {
                    guard let b = baseOf[h], let theirs = baseControls[b], let from = baseByID[b] else { continue }
                    for c in headControls[h] ?? [] {
                        guard baseOf[c.to] == nil, let bt = theirs[c.cmd], !taken.contains(bt) else { continue }
                        let tree = headByID[c.to]?.parent == h && baseByID[bt]?.parent == b
                        candidates.append(Candidate(tree: tree, from: from.lineage, cmd: c.cmd, head: c.to, base: bt))
                    }
                }
                candidates.sort { ($0.tree ? 0 : 1, $0.from, $0.cmd, $0.head, $0.base) < ($1.tree ? 0 : 1, $1.from, $1.cmd, $1.head, $1.base) }
                var next: [String] = []
                for c in candidates where baseOf[c.head] == nil && !taken.contains(c.base) {
                    join(c.head, c.base, .position)
                    next.append(c.head)
                }
                frontier = next.sorted()
            }
        }
        follow(Array(baseOf.keys))

        // 3. Route, one screen at a time, following positions from each.
        func route(_ s: MapSnapshot.Screen) -> String { (s.start ?? "\u{0}") + "\u{1}" + s.steps.joined(separator: "\u{1}") }
        var baseByRoute: [String: [String]] = [:]
        for s in base.screens.sorted(by: { $0.id < $1.id }) { baseByRoute[route(s), default: []].append(s.id) }
        for s in head.screens.sorted(by: { ($0.depth, $0.id) < ($1.depth, $1.id) }) where baseOf[s.id] == nil {
            guard let b = baseByRoute[route(s)]?.first(where: { !taken.contains($0) }) else { continue }
            join(s.id, b, .route)
            follow([s.id])
        }

        // 4. The rest is new.
        var pairings: [String: MapDiff.Pairing] = [:]
        for i in out.screens.indices {
            let id = out.screens[i].id
            if let b = baseOf[id], let lineage = baseByID[b]?.lineage {
                out.screens[i].lineage = lineage
                pairings[lineage] = how[id]
            } else {
                out.screens[i].lineage = id + "@" + short
            }
        }
        return (out.canonical(), pairings)
    }

    /// Pair, compare, and say on each paired screen how it was matched.
    static func diff(head: MapSnapshot, base: MapSnapshot) -> MapDiff {
        let (paired, how) = pair(head: head, base: base)
        var d = MapDiff.compare(base: base, head: paired)
        for i in d.screens.indices where d.screens[i].base != nil && d.screens[i].head != nil {
            d.screens[i].pairing = how[d.screens[i].lineage]
        }
        return d
    }
}
