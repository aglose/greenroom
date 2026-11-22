import CoreGraphics
import Foundation

/// `Greenroom --map-layout-check`: the layout holds on `MapFixtures`' maps. No two cards overlap and each stands in its
/// depth's column; groups hold their members and do not overlap; 2,000 screens take under 200 ms; screens added to a
/// map move only the screens below them in their own group and column, down by whole rows; a golden pair's head keeps
/// its unchanged screens where the base had them; a collapsed group is one tile; the layout reads back to the same bytes.
enum MapLayoutCheck {
    static func run() -> Never {
        var ok = true
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; print("[greenroom] map-layout: \(good ? "ok  " : "FAIL") \(what)") }
        let m = MapLayout.Metrics()

        func overlaps(_ l: MapLayout) -> Int {
            var bad = 0
            // Cards of a column, top to bottom: each must end above the next begins.
            var columns: [CGFloat: [CGRect]] = [:]
            for f in l.frames.values { columns[f.minX, default: []].append(f) }
            for list in columns.values {
                let s = list.sorted { $0.minY < $1.minY }
                for (a, b) in zip(s, s.dropFirst()) where a.maxY > b.minY { bad += 1 }
            }
            return bad
        }
        func columns(_ s: MapSnapshot, _ l: MapLayout) -> Bool {
            s.screens.allSatisfy { sc in l.frames[sc.lineage.isEmpty ? sc.id : sc.lineage].map { $0.minX == m.pad + CGFloat(sc.depth) * m.columnPitch && $0.size == CGSize(width: m.cardWidth, height: m.cardHeight) } ?? false }
        }
        func groupsHold(_ l: MapLayout) -> Bool {
            for g in l.groups where !g.collapsed { for k in g.members { guard let f = l.frames[k], g.frame.contains(f) else { return false } } }
            for (i, a) in l.groups.enumerated() { for b in l.groups[(i + 1)...] where a.frame.intersects(b.frame) { return false } }
            return true
        }

        for n in [15, 500, 2000] {
            let s = MapFixtures.make(screens: n, seed: 7)
            let l = MapLayout.make(s)
            expect(l.frames.count == n && overlaps(l) == 0, "\(n) screens: \(l.frames.count) frames, no two overlap, \(l.groups.count) groups, canvas \(Int(l.size.width)) x \(Int(l.size.height))")
            expect(columns(s, l), "\(n) screens: each in its depth's column")
            expect(groupsHold(l), "\(n) screens: each group's members are inside its frame, group frames do not overlap")
            expect(MapJSON.encode(MapLayout.make(s)) == MapJSON.encode(l), "\(n) screens: laid out the same way twice")
        }

        let big = MapFixtures.large()
        var best = Double.infinity
        for _ in 0..<3 {
            let t = Date()
            _ = MapLayout.make(big.base)
            best = min(best, Date().timeIntervalSince(t) * 1000)
        }
        expect(best < 200, "2000 screens laid out in \(Int(best.rounded())) ms (best of 3; limit 200)")

        // Twenty screens added: only the groups that gained one change, and only downwards by whole rows.
        let base = big.base
        let branches = MapFixtures.branches(of: base)
        let adds = (0..<20).map { MapFixtures.Mutation.add(parent: branches[$0 * 7 + 1].lineage, label: "Added \($0)") }
        let grown = MapFixtures.apply(adds, to: base, commit: "feedface")
        let before = MapLayout.make(base), after = MapLayout.make(grown, previous: before)
        func groupIds(_ l: MapLayout) -> [String: String] { var r: [String: String] = [:]; for g in l.groups { for k in g.members { r[k] = g.id } }; return r }
        let was = groupIds(before), now = groupIds(after)
        let gained = Set(grown.screens.map { $0.lineage }.filter { before.frames[$0] == nil }.compactMap { now[$0] })
        var outside = 0, sideways = 0, up = 0, partial = 0, moved = 0
        for (k, f) in before.frames {
            guard let g = after.frames[k], g != f else { continue }
            moved += 1
            if !gained.contains(was[k] ?? "") { outside += 1 }
            if g.minX != f.minX { sideways += 1 }
            if g.minY < f.minY { up += 1 }
            if (g.minY - f.minY).truncatingRemainder(dividingBy: m.rowPitch) != 0 { partial += 1 }
        }
        expect(after.frames.count == base.screens.count + 20 && overlaps(after) == 0 && groupsHold(after), "adding 20 screens: \(after.frames.count) frames, none overlap, groups hold")
        expect(outside == 0, "adding 20 screens (\(gained.count) groups gained one): \(moved) moved, \(outside) outside those groups")
        expect(sideways == 0 && up == 0 && partial == 0, "adding 20 screens: those that moved went down by whole rows (sideways \(sideways), up \(up), partial \(partial))")

        // Each golden pair: the head laid out from the base's layout keeps what is unchanged.
        for p in MapFixtures.golden() {
            let a = MapLayout.make(p.base), b = MapLayout.make(p.head, previous: a)
            let gs = groupIds(b)
            let added = p.head.screens.filter { a.frames[$0.lineage] == nil }
            // Screens an insertion may have moved: below an added one in the same group and column.
            let room = Set(added.map { (gs[$0.lineage] ?? "", $0.depth) }.map { "\($0.0)|\($0.1)" })
            var kept = 0, displaced = 0, wrong: [String] = []
            for sc in p.head.screens {
                guard let f = a.frames[sc.lineage], let g = b.frames[sc.lineage] else { continue }
                if f == g { kept += 1; continue }
                if room.contains("\(gs[sc.lineage] ?? "")|\(sc.depth)"), g.minX == f.minX, g.minY > f.minY,
                   (g.minY - f.minY).truncatingRemainder(dividingBy: m.rowPitch) == 0 { displaced += 1 } else { wrong.append(sc.lineage) }
            }
            expect(wrong.isEmpty && overlaps(b) == 0, "\(p.name): head laid out from the base's layout keeps \(kept) of its shared screens, \(displaced) moved down below \(added.count) added, \(wrong.count) elsewhere")
        }

        // Collapsing a group.
        let full = MapLayout.make(base)
        if let target = full.groups.max(by: { $0.members.count < $1.members.count }) {
            let shut = MapLayout.make(base, collapsed: [target.id])
            let tile = shut.group(target.id)
            expect(target.members.allSatisfy { shut.frames[$0] == nil } && shut.frames.count == full.frames.count - target.members.count,
                   "collapsing \"\(target.title)\" (\(target.members.count) screens) removes its members' frames")
            expect(tile?.collapsed == true && tile?.frame.size == CGSize(width: m.cardWidth, height: m.cardHeight) && overlaps(shut) == 0,
                   "the collapsed group is one tile, and nothing overlaps it")
            expect(shut.size.height < full.size.height, "the canvas shrinks: \(Int(full.size.height)) to \(Int(shut.size.height))")
            let again = MapLayout.make(base, previous: shut, collapsed: [])
            expect(again.frames.count == full.frames.count && overlaps(again) == 0 && groupsHold(again), "opening it again lays its members out below the others, without overlap")
            let withPrev = MapLayout.make(base, previous: full, collapsed: [target.id])
            expect(withPrev.size.height < full.size.height && overlaps(withPrev) == 0, "collapsing from the open layout shrinks the canvas too")
        } else { expect(false, "a group to collapse") }

        let bytes = MapJSON.encode(full)
        expect(MapJSON.decode(MapLayout.self, from: bytes).map(MapJSON.encode) == bytes, "the layout reads back to the same bytes (\(bytes.count / 1024) KB)")

        print("[greenroom] map-layout check: \(ok ? "PASS" : "FAIL")")
        exit(ok ? 0 : 1)
    }
}
