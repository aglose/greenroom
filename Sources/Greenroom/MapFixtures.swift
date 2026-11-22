import Foundation

// Made-up screen maps for map history's packages (docs/MAP-HISTORY-PLAN.md, "Fixtures instead of walks"): a map of any
// size from a seed, a list of mutations that turns it into the next commit's map, and five golden pairs whose
// difference is known because the mutations are. No simulator and no walk: a package's check runs in seconds.
//
// A fixture's captures are named as real ones are (64 hex digits) but there are no PNGs behind them: the name is a
// hash of the lineage, the combination and the commit that last changed the picture. A package that needs pixels draws
// its own from the name.

/// SplitMix64: the same seed gives the same map on every Mac and every run.
struct MapRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

enum MapFixtures {
    /// One change a commit makes to the app, named by lineage so it survives a screen changing its id.
    enum Mutation: Codable, Equatable {
        /// A new screen behind a new control named `label` on `parent`.
        case add(parent: String, label: String)
        /// A screen with no screens behind it goes, with every control that led to it.
        case remove(String)
        /// Its pixels change, nothing else.
        case restyle(String)
        /// A visible string is added (and so its pixels change).
        case retext(String)
        /// Its tree changes: a new id in the same place.
        case restructure(String)
        /// The control `cmd` on `from` now leads to `to`.
        case retarget(from: String, cmd: String, to: String)
    }

    struct Pair {
        let name: String
        let base: MapSnapshot
        let head: MapSnapshot
        let mutations: [Mutation]
        /// What `MapDiff.compare` gives for the two, which the pairing (H2) must reach from ids, routes and edges alone.
        let expected: MapDiff
    }

    static let sections = ["Trips", "Search", "Saved", "Inbox", "Profile", "Settings"]

    private static func sha(_ text: String) -> String { String(MapJSON.sha256(text).prefix(40)) }
    private static func blob(_ lineage: String, _ combo: String, _ commit: String) -> String { MapJSON.sha256("fixture|\(lineage)|\(combo)|\(commit)") }

    /// A map of `n` screens: a home screen, a section behind each of its controls, and screens level by level below
    /// them, with some controls that lead back to earlier screens, close the app or are on the safety list.
    static func make(screens n: Int, seed: UInt64, combos: [String] = ["light"], fanout: Int = 4) -> MapSnapshot {
        var rng = MapRandom(seed: seed)
        let commit = sha("commit|\(seed)|\(n)"), short = String(commit.prefix(7))
        var profile = MapProfile()
        profile.combos = combos
        var screens: [MapSnapshot.Screen] = []
        var edges: [MapSnapshot.Edge] = []
        var order: [String: Int] = [:]
        var sectionOf: [String: String] = [:]

        func place(_ activity: String, _ title: String, depth: Int, parent: String?, steps: [String], section: String) -> String {
            let id = activity + "-" + String(MapJSON.sha256("\(seed)|\(screens.count)|\(title)").prefix(8))
            let lineage = id + "@" + short
            let texts = [title, "Item \(rng.below(90) + 10)", "Row \(rng.below(900) + 100)"]
            screens.append(.init(id: id, lineage: lineage, activity: activity, title: title, depth: depth, parent: parent, start: nil, steps: steps,
                                 captures: Dictionary(uniqueKeysWithValues: combos.map { ($0, blob(lineage, $0, commit)) }), texts: texts))
            sectionOf[id] = section
            return id
        }
        func control(on from: String, _ action: String, to: String?, note: String? = nil) -> String {
            let cmd = "tap-text " + action
            edges.append(.init(from: from, order: order[from, default: 0], action: action, cmd: cmd, to: to, note: note))
            order[from, default: 0] += 1
            return cmd
        }

        _ = place("MainActivity", "Home", depth: 0, parent: nil, steps: [], section: "Home")
        var next = 0
        while screens.count < n {
            let parent = screens[next]
            next += 1
            let wanted = parent.depth == 0 ? min(sections.count, n - 1) : 1 + rng.below(fanout)
            for j in 0..<wanted where screens.count < n {
                let section = parent.depth == 0 ? sections[j % sections.count] : (sectionOf[parent.id] ?? "Home")
                let title = parent.depth == 0 ? section : "\(section) \(screens.count)"
                let activity = section + (parent.depth > 0 && rng.chance(20) ? "DetailActivity" : "Activity")
                let cmd = "tap-text " + title
                let id = place(activity, title, depth: parent.depth + 1, parent: parent.id, steps: parent.steps + [cmd], section: section)
                _ = control(on: parent.id, title, to: id)
            }
        }
        for i in 1..<max(1, screens.count) {
            let s = screens[i]
            // Up to three controls back to earlier screens and two that stay on the screen, as a real app's walk has
            // (about five controls a screen).
            var targets = Set<String>()
            for _ in 0..<rng.below(4) {
                let target = screens[rng.below(i)]
                if targets.insert(target.id).inserted { _ = control(on: s.id, "Open " + target.title, to: target.id) }
            }
            for k in 0..<rng.below(3) { _ = control(on: s.id, "Toggle \(k + 1)", to: s.id) }
            if rng.chance(5) { _ = control(on: s.id, "Close", to: "EXIT") }
            if rng.chance(5) { _ = control(on: s.id, "Delete", to: "SKIPPED", note: "on the safety list") }
        }
        return MapSnapshot(commit: commit, tree: sha("tree|" + commit), profile: profile, engine: "fixture", walked: "2026-01-01T09:41:00Z",
                           screens: screens, edges: edges, seconds: Double(n) * 1.3).canonical()
    }

    /// The next commit's map: `base` with the mutations made, its screens keeping their lineages.
    static func apply(_ mutations: [Mutation], to base: MapSnapshot, commit: String) -> MapSnapshot {
        var s = base
        s.commit = commit
        s.tree = sha("tree|" + commit)
        let short = String(commit.prefix(7))
        func index(_ lineage: String) -> Int? { s.screens.firstIndex { $0.lineage == lineage } }
        func repaint(_ i: Int) {
            for combo in s.screens[i].captures.keys { s.screens[i].captures[combo] = blob(s.screens[i].lineage, combo, commit) }
        }
        for m in mutations {
            switch m {
            case .restyle(let l):
                if let i = index(l) { repaint(i) }
            case .retext(let l):
                guard let i = index(l) else { continue }
                s.screens[i].texts.append("Changed in " + short)
                repaint(i)
            case .restructure(let l):
                guard let i = index(l) else { continue }
                let old = s.screens[i].id
                let new = s.screens[i].activity + "-" + String(MapJSON.sha256(old + "|" + commit).prefix(8))
                s.screens[i].id = new
                repaint(i)
                for j in s.screens.indices where s.screens[j].parent == old { s.screens[j].parent = new }
                for j in s.edges.indices {
                    if s.edges[j].from == old { s.edges[j].from = new }
                    if s.edges[j].to == old { s.edges[j].to = new }
                }
            case .add(let parent, let label):
                guard let p = index(parent) else { continue }
                let on = s.screens[p]
                let id = "AddedActivity-" + String(MapJSON.sha256(label + "|" + commit).prefix(8))
                let lineage = id + "@" + short
                let cmd = "tap-text " + label
                s.screens.append(.init(id: id, lineage: lineage, activity: "AddedActivity", title: label, depth: on.depth + 1, parent: on.id, start: on.start,
                                       steps: on.steps + [cmd], captures: Dictionary(uniqueKeysWithValues: s.profile.combos.map { ($0, blob(lineage, $0, commit)) }),
                                       texts: [label]))
                let order = (s.edges.filter { $0.from == on.id }.map(\.order).max() ?? -1) + 1
                s.edges.append(.init(from: on.id, order: order, action: label, cmd: cmd, to: id, note: nil))
            case .remove(let l):
                guard let i = index(l) else { continue }
                let id = s.screens[i].id
                s.screens.remove(at: i)
                s.edges.removeAll { $0.from == id || $0.to == id }
            case .retarget(let from, let cmd, let to):
                guard let f = index(from), let t = index(to) else { continue }
                let fromID = s.screens[f].id
                if let j = s.edges.firstIndex(where: { $0.from == fromID && $0.cmd == cmd }) { s.edges[j].to = s.screens[t].id }
            }
        }
        return s.canonical()
    }

    // MARK: Picking what to change

    /// Screens with nothing behind them (never the home screen), in id order.
    static func leaves(of s: MapSnapshot) -> [MapSnapshot.Screen] {
        let parents = Set(s.screens.compactMap(\.parent))
        return s.screens.filter { $0.parent != nil && !parents.contains($0.id) }
    }

    /// Screens with screens behind them (never the home screen), in id order.
    static func branches(of s: MapSnapshot) -> [MapSnapshot.Screen] {
        let parents = Set(s.screens.compactMap(\.parent))
        return s.screens.filter { $0.parent != nil && parents.contains($0.id) }
    }

    /// Controls that lead to a screen which is not behind theirs in the tree: retargeting one orphans nothing.
    static func crossEdges(of s: MapSnapshot) -> [MapSnapshot.Edge] {
        let parent = Dictionary(s.screens.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        return s.edges.filter { e in
            guard let to = e.to, let p = parent[to] else { return false }
            return p != e.from
        }
    }

    private static func pair(_ name: String, screens n: Int, seed: UInt64, combos: [String] = ["light"], _ pick: (MapSnapshot) -> [Mutation]) -> Pair {
        let base = make(screens: n, seed: seed, combos: combos)
        let mutations = pick(base)
        let head = apply(mutations, to: base, commit: sha("commit|\(name)|head"))
        return Pair(name: name, base: base, head: head, mutations: mutations, expected: MapDiff.compare(base: base, head: head))
    }

    private static func retargets(_ s: MapSnapshot, _ count: Int) -> [Mutation] {
        let lineage = Dictionary(s.screens.map { ($0.id, $0.lineage) }, uniquingKeysWith: { a, _ in a })
        // One control per screen, so `count` retargets touch `count` screens.
        var seen = Set<String>()
        return crossEdges(of: s).filter { seen.insert($0.from).inserted }.prefix(count).compactMap { e in
            // Anywhere but where it leads now and the screen it is on.
            guard let from = lineage[e.from], let to = s.screens.first(where: { $0.id != e.to && $0.id != e.from }) else { return nil }
            return .retarget(from: from, cmd: e.cmd, to: to.lineage)
        }
    }

    /// The five pairs every package's check can lean on.
    static func golden() -> [Pair] {
        [
            pair("restyle", screens: 15, seed: 1, combos: ["light", "dark"]) { s in
                let l = leaves(of: s)
                return [.restyle(l[0].lineage), .restyle(s.screens.first { $0.parent == nil }!.lineage), .retext(l[1].lineage)]
            },
            pair("grow", screens: 15, seed: 2) { s in
                let l = leaves(of: s), b = branches(of: s)
                return [.add(parent: b[0].lineage, label: "Invite a friend"), .add(parent: l[0].lineage, label: "Receipt"), .remove(l[1].lineage)]
            },
            pair("restructure", screens: 40, seed: 3) { s in
                [.restructure(branches(of: s)[0].lineage), .restructure(leaves(of: s)[0].lineage)]
            },
            pair("retarget", screens: 40, seed: 4) { s in retargets(s, 2) },
            pair("mixed", screens: 500, seed: 5, combos: ["light", "dark"]) { s in
                let l = leaves(of: s), b = branches(of: s)
                return [.restyle(l[3].lineage), .retext(b[5].lineage), .restructure(b[9].lineage), .add(parent: b[20].lineage, label: "Export"),
                        .remove(l[40].lineage)] + retargets(s, 1)
            },
        ]
    }

    /// A large pair for timing: `n` screens and twenty changes.
    static func large(screens n: Int = 2000) -> Pair {
        pair("large", screens: n, seed: 9, combos: ["light", "dark"]) { s in
            let l = leaves(of: s), b = branches(of: s)
            var m: [Mutation] = []
            for i in 0..<5 {
                m += [.restyle(l[i * 7].lineage), .restructure(b[i * 11].lineage), .add(parent: b[i * 13 + 1].lineage, label: "New \(i)"), .remove(l[i * 17 + 3].lineage)]
            }
            return m
        }
    }
}

/// `Greenroom --map-contract-check [DIR]`: the contract holds. Every golden pair is written and read back to the same
/// bytes, is made the same way twice, differs from itself in nothing, and differs from its head in exactly its
/// mutations; the bytes are the ones this file names, so a change to the format is a change someone made on purpose.
/// With DIR the pairs are written there (`<name>/base.json`, `head.json`, `diff.json`, `mutations.json`) for the
/// packages that read them from outside the app. No window, no engine.
enum MapContractCheck {
    /// SHA-256 over each pair's base, head and difference. Changing the snapshot's or the difference's form changes
    /// these: update them in the same commit, and say so in its message.
    static let digests: [String: String] = [
        "restyle": "f0d76b1a5b679a46f6c7f50ad8bacbb629aa2cdf3e95c1215d37f1947b812a2b",
        "grow": "9e6918b1ac3ce835866f5ad4f3900ca8271e2c99e2b706dcf080b5ef5ddb5fe5",
        "restructure": "056570e0c7111b96044e9cbde26175dfb8840418e73ddb5fdf97ec1c832540cf",
        "retarget": "d3d0d727c485d38e4bef1b2de8f08f1e7989cf2820b986910128d20dc80f158c",
        "mixed": "14f1506749a7a04cea13564abca9ae43b01b86bbcfeb9910d9a8468cf938f9c4",
    ]

    static func run(dir: URL?) -> Never {
        var ok = true
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; print("[greenroom] map-contract: \(good ? "ok  " : "FAIL") \(what)") }

        let pairs = MapFixtures.golden(), again = MapFixtures.golden()
        for (p, q) in zip(pairs, again) {
            let base = p.base.data(), head = p.head.data(), diff = p.expected.data(), mutations = MapJSON.encode(p.mutations)
            let c = p.expected.counts
            print("[greenroom] map-contract: \(p.name): \(p.base.screens.count) screens, \(p.base.edges.count) edges, \(base.count / 1024) KB; +\(c.added) -\(c.removed) ~\(c.modified) =\(c.same)")

            let roundTrip = MapSnapshot.read(base)?.data() == base && MapSnapshot.read(head)?.data() == head
                && MapJSON.decode(MapDiff.self, from: diff)?.data() == diff
                && MapJSON.decode([MapFixtures.Mutation].self, from: mutations).map(MapJSON.encode) == mutations
            expect(roundTrip, "\(p.name): read back and written again, byte for byte")
            expect(q.base.data() == base && q.head.data() == head && q.expected.data() == diff, "\(p.name): made the same way twice")
            let own = MapDiff.compare(base: p.base, head: p.base)
            expect(own.counts.differing == 0 && own.edges.isEmpty && own.counts.same == p.base.screens.count, "\(p.name): a map differs from itself in nothing")

            // The difference is the mutations, no more and no fewer.
            var added = 0, removed = Set<String>(), touched: [String: Set<MapDiff.Reason>] = [:]
            let lineage = Dictionary(p.base.screens.map { ($0.id, $0.lineage) }, uniquingKeysWith: { a, _ in a })
            for m in p.mutations {
                switch m {
                case .add(let parent, _): added += 1; touched[parent, default: []].insert(.routes)
                case .remove(let l):
                    removed.insert(l)
                    let id = p.base.screens.first { $0.lineage == l }?.id
                    for e in p.base.edges where e.to == id { if let from = lineage[e.from] { touched[from, default: []].insert(.routes) } }
                case .restyle(let l): touched[l, default: []].insert(.visual)
                case .retext(let l): touched[l, default: []].formUnion([.visual, .text])
                case .restructure(let l): touched[l, default: []].formUnion([.visual, .structure])
                case .retarget(let from, _, _): touched[from, default: []].insert(.routes)
                }
            }
            for l in removed { touched[l] = nil }
            let modified = p.expected.screens.filter { $0.status == .modified }
            let reasonsMatch = modified.allSatisfy { Set($0.reasons) == touched[$0.lineage] }
            expect(!p.mutations.isEmpty && c.added == added && c.removed == removed.count && modified.count == touched.count && reasonsMatch && c.notCompared == 0,
                   "\(p.name): differs in exactly its \(p.mutations.count) mutations, each with its reasons")

            let digest = MapJSON.sha256(base + head + diff)
            if let want = digests[p.name] { expect(digest == want, "\(p.name): the bytes are the ones named (\(digest.prefix(12)))") }
            else { expect(false, "\(p.name): no digest named; it is \(digest)") }

            if let dir {
                let folder = dir.appendingPathComponent(p.name, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (name, data) in [("base.json", base), ("head.json", head), ("diff.json", diff), ("mutations.json", mutations)] {
                    try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
                }
            }
        }

        // What the walk did not finish must not read as a change.
        if let grow = pairs.first(where: { $0.name == "grow" }) {
            var cut = grow.head
            cut.incomplete = ["--max-seconds 120: 3 screens not explored"]
            let d = MapDiff.compare(base: grow.base, head: cut)
            expect(d.counts.removed == 0 && d.counts.notCompared == grow.expected.counts.removed, "a head walk cut short: a missing screen is not compared, not removed")
            var restless = grow.base
            restless.screens[0].settled = false
            var moved = restless
            moved.screens[0].captures = moved.screens[0].captures.mapValues { _ in String(repeating: "0", count: 64) }
            let e = MapDiff.compare(base: restless, head: moved)
            expect(e.counts.modified == 0 && e.counts.notCompared == 1, "a screen that never settles: other pixels are not a change")
        }

        let started = Date()
        let big = MapFixtures.large()
        let made = Date().timeIntervalSince(started)
        let t = Date()
        let diff = MapDiff.compare(base: big.base, head: big.head)
        let compared = Date().timeIntervalSince(t)
        print(String(format: "[greenroom] map-contract: large: %d screens, %d edges, %.1f MB; made in %.0f ms, compared in %.0f ms",
                     big.base.screens.count, big.base.edges.count, Double(big.base.data().count) / 1_048_576, made * 1000, compared * 1000))
        expect(diff.counts.added == 5 && diff.counts.removed == 5 && compared < 0.5, "large: 5 added, 5 removed, compared in under half a second")

        print("[greenroom] map-contract check: \(ok ? "PASS" : "FAIL")")
        exit(ok ? 0 : 1)
    }
}
