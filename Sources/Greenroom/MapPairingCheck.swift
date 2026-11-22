import Foundation

/// `Greenroom --map-pairing-check`: the pairing (MapPairing) finds from ids, routes and edges alone the lineages the
/// fixtures were made with. Every golden pair and the large one, their heads' lineages blanked, are paired against
/// their bases and compared to exactly the pair's expected difference, restructured screens paired by position; then
/// the cases the goldens lack, made with `MapFixtures.apply`. No window, no engine.
enum MapPairingCheck {
    static func run() -> Never {
        var ok = true
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; print("[greenroom] map-pairing: \(good ? "ok  " : "FAIL") \(what)") }

        func blank(_ s: MapSnapshot) -> MapSnapshot {
            var s = s
            for i in s.screens.indices { s.screens[i].lineage = "" }
            return s
        }
        func unpaired(_ d: MapDiff) -> MapDiff {
            var d = d
            for i in d.screens.indices { d.screens[i].pairing = nil }
            return d
        }
        func lineage(_ s: MapSnapshot, _ id: String) -> String? { s.screen(id)?.lineage }
        func commit(_ name: String) -> String { MapJSON.sha256("pairing-check|" + name) }

        /// Pairs `head` (blanked) with `base`, requires the expected difference, and that `restructured` were paired
        /// by position. Gives the difference with its pairings.
        @discardableResult
        func check(_ name: String, base: MapSnapshot, head: MapSnapshot, restructured: [String], by: MapDiff.Pairing = .position) -> MapDiff {
            let expected = MapDiff.compare(base: base, head: head)
            let d = MapPairing.diff(head: blank(head), base: base)
            let missed = d.screens.filter { $0.status != .added && $0.status != .removed && $0.pairing == nil }.count
            expect(unpaired(d) == expected && missed == 0, "\(name): paired from ids, routes and edges, the difference is the expected one (+\(d.counts.added) -\(d.counts.removed) ~\(d.counts.modified))")
            if !restructured.isEmpty {
                let ways = restructured.map { d.change($0)?.pairing }
                expect(ways.allSatisfy { $0 == by }, "\(name): \(restructured.count) restructured screen(s) paired by \(by.rawValue) (\(ways.map { $0?.rawValue ?? "none" }.joined(separator: ", ")))")
            }
            return d
        }
        func restructured(_ p: MapFixtures.Pair) -> [String] {
            p.mutations.compactMap { if case .restructure(let l) = $0 { return l } else { return nil } }
        }

        for p in MapFixtures.golden() { check(p.name, base: p.base, head: p.head, restructured: restructured(p)) }

        // A parent, its child and its grandchild restructured in one commit: resolved from the paired ancestor down.
        let map = MapFixtures.make(screens: 40, seed: 3)
        let branches = MapFixtures.branches(of: map)
        if let top = branches.first(where: { b in branches.contains { $0.parent == b.id } }),
           let middle = branches.first(where: { $0.parent == top.id }),
           let bottom = map.screens.first(where: { $0.parent == middle.id }) {
            let chain = [top.lineage, middle.lineage, bottom.lineage]
            let head = MapFixtures.apply(chain.map { .restructure($0) }, to: map, commit: commit("chain"))
            check("chain", base: map, head: head, restructured: chain)
        } else {
            expect(false, "chain: the fixture has no three screens in a line")
        }

        // The home screen restructured. Controls lead back to it, so its position pairs it.
        let home = map.screens.first { $0.parent == nil }!
        let rehomed = MapFixtures.apply([.restructure(home.lineage)], to: map, commit: commit("home"))
        let backLinks = map.edges.filter { $0.to == home.id && $0.from != home.id }.count
        check("home, with \(backLinks) controls back to it", base: map, head: rehomed, restructured: [home.lineage], by: backLinks > 0 ? .position : .route)
        // And when nothing leads to it (only the launcher does), its route pairs it; its children keep their ids.
        var alone = map
        alone.edges.removeAll { $0.to == home.id }
        let realone = MapFixtures.apply([.restructure(home.lineage)], to: alone, commit: commit("home-alone"))
        check("home, nothing leading to it", base: alone, head: realone, restructured: [home.lineage], by: .route)
        // And with its first section restructured too: the route pairs home, the position then pairs the section.
        if let section = alone.screens.first(where: { $0.parent == home.id }) {
            let both = MapFixtures.apply([.restructure(home.lineage), .restructure(section.lineage)], to: alone, commit: commit("home-section"))
            let d = check("home and a section, nothing leading to home", base: alone, head: both, restructured: [section.lineage])
            expect(d.change(home.lineage)?.pairing == .route, "home and a section: home paired by route")
        }

        // A screen removed and another added under the same parent behind another control: two changes, not one.
        if let leaf = MapFixtures.leaves(of: map).first, let parent = map.screens.first(where: { $0.id == leaf.parent }) {
            let head = MapFixtures.apply([.remove(leaf.lineage), .add(parent: parent.lineage, label: "Something else")], to: map, commit: commit("swap"))
            let d = check("removed and added under one parent", base: map, head: head, restructured: [])
            expect(d.counts.added == 1 && d.counts.removed == 1 && d.change(leaf.lineage)?.status == .removed, "removed and added under one parent: not paired")
        }

        // A tie: a restructured screen is reached from its parent and from another paired screen, and in the head that
        // other screen's control leads to a new screen instead. The control in the tree wins.
        if let link = map.edges.first(where: { e in
            guard let to = e.to, e.from != to, let t = map.screen(to), t.parent != nil, t.parent != e.from else { return false }
            return map.screen(e.from) != nil
        }), let target = map.screen(link.to!) {
            var head = MapFixtures.apply([.restructure(target.lineage)], to: map, commit: commit("tie"))
            let moved = head.screens.first { $0.lineage == target.lineage }!
            var rival = moved
            rival.id = "TieActivity-" + String(MapJSON.sha256("tie").prefix(8))
            rival.lineage = rival.id + "@" + String(head.commit.prefix(7))
            rival.parent = link.from
            head.screens.append(rival)
            if let j = head.edges.firstIndex(where: { $0.from == link.from && $0.cmd == link.cmd }) { head.edges[j].to = rival.id }
            head = head.canonical()
            let (paired, how) = MapPairing.pair(head: blank(head), base: map)
            expect(lineage(paired, moved.id) == target.lineage && how[target.lineage] == .position && lineage(paired, rival.id) == rival.lineage,
                   "tie: two head screens reach one base screen; the one its parent's control leads to takes it, the other is new")
        } else {
            expect(false, "tie: the fixture has no control back to a screen")
        }

        // The same input gives the same bytes: twice, and with its screens and edges in another order.
        let mixed = MapFixtures.golden().first { $0.name == "mixed" }!
        let once = MapPairing.pair(head: blank(mixed.head), base: mixed.base), twice = MapPairing.pair(head: blank(mixed.head), base: mixed.base)
        var rng = MapRandom(seed: 42)
        func shuffle(_ s: MapSnapshot) -> MapSnapshot {
            var s = s
            for i in s.screens.indices.reversed() { s.screens.swapAt(i, rng.below(i + 1)) }
            for i in s.edges.indices.reversed() { s.edges.swapAt(i, rng.below(i + 1)) }
            return s
        }
        let shuffledHead = shuffle(blank(mixed.head)), shuffledBase = shuffle(mixed.base)
        let shuffled = MapPairing.pair(head: shuffledHead, base: shuffledBase)
        expect(once.0.data() == twice.0.data() && MapJSON.encode(once.1) == MapJSON.encode(twice.1)
               && once.0.data() == shuffled.0.data() && MapJSON.encode(once.1) == MapJSON.encode(shuffled.1),
               "mixed: paired twice and in another order, the same bytes")

        // No base: everything is new.
        let (fresh, none) = MapPairing.pair(head: blank(mixed.head), base: nil)
        let short = String(mixed.head.commit.prefix(7))
        expect(none.isEmpty && fresh.screens.allSatisfy { $0.lineage == $0.id + "@" + short }, "no base: every screen is new")

        // A base made outside the app has no lineages: it is given `<id>@<commit>` first, and the difference is the same.
        let outside = MapFixtures.golden().first { $0.name == "mixed" }!
        let seededBase = MapPairing.seeded(blank(outside.base))
        let baseShort = String(outside.base.commit.prefix(7))
        let viaOutside = MapPairing.diff(head: blank(outside.head), base: blank(outside.base))
        expect(seededBase.screens.allSatisfy { $0.lineage == $0.id + "@" + baseShort }
               && viaOutside.counts == MapPairing.diff(head: blank(outside.head), base: seededBase).counts
               && viaOutside.screens.allSatisfy { $0.status == .added || $0.lineage.hasSuffix("@" + baseShort) || $0.lineage.hasSuffix("@" + String(outside.head.commit.prefix(7))) },
               "base with no lineages: given <id>@<its commit's first seven digits>, then paired as usual")

        // The large pair, and its time.
        let big = MapFixtures.large()
        check("large", base: big.base, head: big.head, restructured: restructured(big))
        let blanked = blank(big.head)
        var best = Double.infinity
        for _ in 0..<3 {
            let t = Date()
            _ = MapPairing.pair(head: blanked, base: big.base)
            best = min(best, Date().timeIntervalSince(t))
        }
        expect(best < 0.1, String(format: "large: %d screens, %d edges paired in %.0f ms (under 100)", big.head.screens.count, big.head.edges.count, best * 1000))

        print("[greenroom] map-pairing check: \(ok ? "PASS" : "FAIL")")
        exit(ok ? 0 : 1)
    }
}
