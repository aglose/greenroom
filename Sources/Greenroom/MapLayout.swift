import CoreGraphics
import Foundation

// The map's layout (docs/MAP-HISTORY-PLAN.md, "The canvas at scale", package C1): where each screen of a `MapSnapshot`
// sits on the canvas. Pure geometry over the snapshot's own fields: Foundation and CoreGraphics only, no layers, so it
// runs off the main thread and its result is cached (it is Codable). The renderer reads `frames` and `groups`.
//
// The grid is whole rows and whole columns: a column per depth, and a row is one card and the gap below it. Screens
// gather into groups, the section each hangs from; a group is a band, its depth columns left to right. A column
// taller than `wrapRows` goes on in a column beside it, and the bands are packed in shelves (left to right, a new
// shelf below when one is full) in a stable order, with the shelf width and wrap chosen so the canvas comes near the
// aspect asked for. A band has spare rows below its tallest column, so a screen that appears finds room without
// moving the next group. Given the previous layout, a lineage keeps its row; a new screen goes beside its
// parent's other children and moves only the screens below it in its own column, down by whole rows, until a gap
// (where a screen was removed, or a spare row) takes up the shift.

struct MapLayout: Codable, Equatable {
    /// The sizes everything is laid out with; the defaults are the canvas's today.
    struct Metrics: Codable, Equatable {
        var cardWidth: CGFloat = 96
        var cardHeight: CGFloat = 248
        /// Between columns and between rows.
        var gapX: CGFloat = 150
        var gapY: CGFloat = 34
        /// Around the whole canvas.
        var pad: CGFloat = 70
        /// A group's frame stands this far outside its cards (less than half of `gapY`, so two bands never touch).
        var inset: CGFloat = 12

        var rowPitch: CGFloat { cardHeight + gapY }
        var columnPitch: CGFloat { cardWidth + gapX }
    }

    struct Group: Codable, Equatable {
        /// "g:" and the key of the screen the group hangs from (the home screen is its own group).
        var id: String
        var title: String
        /// The band the group's cards stand in; the one tile it is when collapsed.
        var frame: CGRect
        /// The members' keys (lineage, or id when there is none), by column then row.
        var members: [String]
        var minDepth: Int
        var maxDepth: Int
        var collapsed: Bool
        /// The band's first row on the canvas, and how many rows it holds (cards, gaps and spare rows).
        var startRow: Int
        var rows: Int
        /// The band's first column on the canvas, and how many columns each depth has (from `minDepth`; more than one
        /// when the depth's screens wrap).
        var col = 0
        var columns: [Int] = []
    }

    var metrics: Metrics
    /// By key: the screen's lineage, or its id when the lineage is empty. A collapsed group's members have none.
    var frames: [String: CGRect]
    /// In stacking order, top to bottom.
    var groups: [Group]
    var size: CGSize
    /// What the packing chose: rows a column holds before it wraps, and columns a shelf of bands holds. A layout made
    /// from this one keeps them, so nothing moves for the choice.
    var wrapRows = 1
    var shelfColumns = 1

    func group(_ id: String) -> Group? { groups.first { $0.id == id } }

    /// Lays `snapshot` out. With `previous` (made with the same metrics) the lineages it holds keep their place.
    /// `compact` forgets the previous rows and packs the groups again, but keeps their order. `aspect` is the canvas's
    /// width over height the packing aims for.
    static func make(_ snapshot: MapSnapshot, previous: MapLayout? = nil, collapsed: Set<String> = [], metrics: Metrics = Metrics(), compact: Bool = false, aspect: CGFloat = 1.6) -> MapLayout {
        Builder(snapshot, previous: previous, collapsed: collapsed, metrics: metrics, compact: compact, aspect: aspect).build()
    }

    // MARK: -

    /// The same two ordered screens as a pair, for sorting.
    private struct Node {
        var key: String
        var screen: MapSnapshot.Screen
        var depth: Int
        var parent: Int?
        /// The control's place on its parent that leads here.
        var order: Int
        var group = 0
    }

    private struct Band {
        var id: String
        var title: String
        var anchorDepth: Int
        var anchorKey: String
        var nodes: [Int] = []
        var minDepth = Int.max, maxDepth = 0
    }

    private struct Builder {
        let metrics: Metrics
        let collapsed: Set<String>
        let previous: MapLayout?
        let compact: Bool
        let aspect: CGFloat
        var nodes: [Node] = []
        var bands: [Band] = []
        /// Neighbours over the snapshot's edges, one step in either direction, by node.
        var near: [[Int]] = []
        /// The group each key stood in in the previous layout.
        var prevGroupOf: [String: String] = [:]

        init(_ s: MapSnapshot, previous: MapLayout?, collapsed: Set<String>, metrics: Metrics, compact: Bool, aspect: CGFloat) {
            self.aspect = aspect
            self.metrics = metrics
            self.collapsed = collapsed
            self.previous = previous?.metrics == metrics ? previous : nil
            self.compact = compact
            for g in self.previous?.groups ?? [] where !g.collapsed { for k in g.members { prevGroupOf[k] = g.id } }

            // The screens in a fixed order, whatever order the snapshot holds them in.
            let sorted = s.screens.sorted { ($0.lineage.isEmpty ? $0.id : $0.lineage, $0.id) < ($1.lineage.isEmpty ? $1.id : $1.lineage, $1.id) }
            var seen = Set<String>()
            var indexOfId: [String: Int] = [:]
            for sc in sorted {
                var key = sc.lineage.isEmpty ? sc.id : sc.lineage
                if !seen.insert(key).inserted { key = sc.id; var n = 1; while !seen.insert(key).inserted { key = sc.id + "#\(n)"; n += 1 } }
                indexOfId[sc.id] = indexOfId[sc.id] ?? nodes.count
                nodes.append(Node(key: key, screen: sc, depth: max(0, sc.depth), parent: nil, order: Int.max))
            }
            for i in nodes.indices { nodes[i].parent = nodes[i].screen.parent.flatMap { indexOfId[$0] }.flatMap { $0 == i ? nil : $0 } }
            near = Array(repeating: [], count: nodes.count)
            for e in s.edges {
                guard let a = indexOfId[e.from], let to = e.to, let b = indexOfId[to], a != b else { continue }
                if nodes[b].parent == a { nodes[b].order = min(nodes[b].order, e.order) }
                if !near[a].contains(b) { near[a].append(b) }
                if !near[b].contains(a) { near[b].append(a) }
            }

            // A screen belongs to the section it hangs from: the depth-1 ancestor on its parent chain.
            var byAnchor: [Int: Int] = [:]
            for i in nodes.indices {
                var cur = i, steps = 0
                while nodes[cur].depth > 1, let p = nodes[cur].parent, steps < 10_000 { cur = p; steps += 1 }
                if let g = byAnchor[cur] { nodes[i].group = g; bands[g].nodes.append(i); continue }
                byAnchor[cur] = bands.count
                nodes[i].group = bands.count
                bands.append(Band(id: "g:" + nodes[cur].key, title: nodes[cur].screen.title, anchorDepth: nodes[cur].depth, anchorKey: nodes[cur].key, nodes: [i]))
            }
            for b in bands.indices {
                for i in bands[b].nodes {
                    bands[b].minDepth = min(bands[b].minDepth, nodes[i].depth)
                    bands[b].maxDepth = max(bands[b].maxDepth, nodes[i].depth)
                }
            }
        }

        /// The groups top to bottom: those the previous layout stacked, in its order, then new ones, home first.
        func stacking() -> [Int] {
            let fresh = bands.indices.sorted { a, b in
                (bands[a].anchorDepth, bands[a].title, bands[a].anchorKey) < (bands[b].anchorDepth, bands[b].title, bands[b].anchorKey)
            }
            guard let previous else { return fresh }
            var before: [String: Int] = [:]
            for (i, g) in previous.groups.enumerated() { before[g.id] = i }
            let known = fresh.filter { before[bands[$0].id] != nil }.sorted { before[bands[$0].id]! < before[bands[$1].id]! }
            return known + fresh.filter { before[bands[$0].id] == nil }
        }

        /// Each member's row inside its group's band, by node; for groups the previous layout holds (expanded in both)
        /// the rows it had, and room made for what is new.
        func slots(of g: Int, prev: MapLayout.Group?) -> [Int: Int] {
            let members = bands[g].nodes
            var slot: [Int: Int] = [:]
            var cells: [Int: [Int?]] = [:]
            var rest: [Int] = []

            if let prev, let previous, !prev.collapsed, !compact {
                for i in members {
                    guard let f = previous.frames[nodes[i].key], prevGroupOf[nodes[i].key] == prev.id, nodes[i].depth >= prev.minDepth,
                          nodes[i].depth - prev.minDepth < prev.columns.count else { rest.append(i); continue }
                    let d = nodes[i].depth
                    let offset = prev.columns[..<(d - prev.minDepth)].reduce(0, +)
                    let sub = Int(((f.minX - metrics.pad) / metrics.columnPitch).rounded()) - prev.col - offset
                    let row = Int(((f.minY - metrics.pad) / metrics.rowPitch).rounded()) - prev.startRow
                    let at = sub * previous.wrapRows + row
                    var cell = cells[d] ?? []
                    if sub >= 0, sub < prev.columns[d - prev.minDepth], row >= 0, row < previous.wrapRows, at >= cell.count || cell[at] == nil {
                        while cell.count <= at { cell.append(nil) }
                        cell[at] = i
                        cells[d] = cell
                        slot[i] = at
                    } else { rest.append(i) }
                }
                // New screens, column by column so a parent is placed before its children, each next to its siblings.
                for i in rest.sorted(by: { (nodes[$0].depth, nodes[$0].order, nodes[$0].key) < (nodes[$1].depth, nodes[$1].order, nodes[$1].key) }) {
                    let d = nodes[i].depth
                    var cell = cells[d] ?? []
                    func parentRow(_ n: Int) -> Int { nodes[n].parent.flatMap { slot[$0] } ?? -1 }
                    let mine = parentRow(i)
                    var at = 0
                    if let sibling = cell.indices.last(where: { s in cell[s].map { nodes[$0].parent == nodes[i].parent && nodes[i].parent != nil } ?? false }) {
                        at = sibling + 1
                    } else if let last = cell.indices.last(where: { s in cell[s].map { parentRow($0) <= mine } ?? false }) {
                        at = last + 1
                    }
                    // Free at `at`, else the run below it moves down one row until a gap takes it.
                    while cell.count <= at { cell.append(nil) }
                    var end = at
                    while end < cell.count, cell[end] != nil { end += 1 }
                    if end == cell.count { cell.append(nil) }
                    var k = end
                    while k > at { cell[k] = cell[k - 1]; if let m = cell[k] { slot[m] = k }; k -= 1 }
                    cell[at] = i
                    slot[i] = at
                    cells[d] = cell
                }
                return slot
            }

            // Fresh: a column's screens follow their parents' order, then two passes over the edges bring each next to
            // the neighbours it is joined to in the column before (down) and after (up).
            var inColumn: [Int: [Int]] = [:]
            for i in members { inColumn[nodes[i].depth, default: []].append(i) }
            let depths = inColumn.keys.sorted()
            var position: [Int: Double] = [:]
            func place(_ d: Int, by rank: (Int) -> Double?) {
                guard let list = inColumn[d] else { return }
                let ordered = list.enumerated().sorted { a, b in
                    let ra = rank(a.element) ?? position[a.element] ?? 0, rb = rank(b.element) ?? position[b.element] ?? 0
                    return ra != rb ? ra < rb : (a.offset, nodes[a.element].key) < (b.offset, nodes[b.element].key)
                }.map(\.element)
                inColumn[d] = ordered
                for (r, i) in ordered.enumerated() { position[i] = Double(r) }
            }
            for d in depths {
                // Parent's row first, then the control's place on the parent: ties are broken by the sort's stability.
                let list = (inColumn[d] ?? []).sorted { (nodes[$0].order, nodes[$0].key) < (nodes[$1].order, nodes[$1].key) }
                inColumn[d] = list
                for (r, i) in list.enumerated() { position[i] = Double(r) }
                place(d) { i in nodes[i].parent.flatMap { position[$0] }.map { $0 * 1_000 + Double(nodes[i].order == Int.max ? 999 : min(nodes[i].order, 998)) } ?? -1 }
            }
            func pull(_ d: Int, from other: Int) {
                place(d) { i in
                    let ns = near[i].filter { nodes[$0].group == g && nodes[$0].depth == other }
                    return ns.isEmpty ? nil : ns.reduce(0.0) { $0 + (position[$1] ?? 0) } / Double(ns.count)
                }
            }
            for d in depths.dropFirst() { pull(d, from: d - 1) }
            for d in depths.dropLast().reversed() { pull(d, from: d + 1) }
            for d in depths.dropFirst() { pull(d, from: d - 1) }
            for (_, list) in inColumn { for (r, i) in list.enumerated() { slot[i] = r } }
            return slot
        }

        /// What a band takes: columns for each depth, and rows.
        struct Dim { var spans: [Int]; var rows: Int; var width: Int { spans.reduce(0, +) } }

        func dim(_ band: Band, slot: [Int: Int], prev: MapLayout.Group?, collapsed: Bool, wrap r: Int) -> Dim {
            if collapsed { return Dim(spans: [], rows: 1) }
            var count = Array(repeating: 0, count: band.maxDepth - band.minDepth + 1)
            for i in band.nodes { count[nodes[i].depth - band.minDepth] = max(count[nodes[i].depth - band.minDepth], (slot[i] ?? 0) + 1) }
            var spans = count.map { max(1, ($0 + r - 1) / r) }
            if let prev { for (k, was) in prev.columns.enumerated() where k < spans.count && prev.minDepth == band.minDepth { spans[k] = max(spans[k], was) } }
            let need = count.max() ?? 1
            let rows = prev.map { min(r, max($0.rows, need)) } ?? (need >= r ? r : min(r, need + max(3, need / 8)))
            return Dim(spans: spans, rows: max(1, rows))
        }

        /// Shelf packing in the given order: each band's origin, and the whole's columns and rows.
        func pack(_ dims: [(width: Int, rows: Int)], shelf: Int) -> (at: [(col: Int, row: Int)], cols: Int, rows: Int) {
            var at: [(col: Int, row: Int)] = []
            var x = 0, y = 0, high = 0, cols = 0
            for d in dims {
                if x > 0, x + d.width > shelf { y += high; x = 0; high = 0 }
                at.append((x, y))
                x += d.width
                high = max(high, d.rows)
                cols = max(cols, x)
            }
            return (at, cols, y + high)
        }

        func points(cols: Int, rows: Int) -> CGSize {
            CGSize(width: metrics.pad * 2 + CGFloat(cols) * metrics.cardWidth + CGFloat(max(cols - 1, 0)) * metrics.gapX,
                   height: metrics.pad * 2 + CGFloat(max(rows, 1)) * metrics.cardHeight + CGFloat(max(rows, 1) - 1) * metrics.gapY)
        }

        func build() -> MapLayout {
            var prevBy: [String: MapLayout.Group] = [:]
            for g in previous?.groups ?? [] { prevBy[g.id] = g }
            let order = stacking()

            // Each band's screens' places in its columns; those the previous layout held keep theirs.
            var slotOf: [Int: [Int: Int]] = [:]
            var usable: [Int: MapLayout.Group] = [:]
            for g in order {
                let isCollapsed = collapsed.contains(bands[g].id)
                if isCollapsed { continue }
                let prev = compact ? nil : prevBy[bands[g].id].flatMap { $0.collapsed ? nil : $0 }
                if let prev { usable[g] = prev }
                slotOf[g] = slots(of: g, prev: prev)
            }

            func dims(_ r: Int) -> [Dim] {
                order.map { dim(bands[$0], slot: slotOf[$0] ?? [:], prev: usable[$0], collapsed: collapsed.contains(bands[$0].id), wrap: r) }
            }
            var wrap = 1, shelf = 1
            if let previous, !compact, previous.wrapRows > 0 {
                wrap = previous.wrapRows
                shelf = previous.shelfColumns
            } else {
                // The wrap and shelf width whose canvas is nearest the aspect asked for, then the smaller.
                let tallest = max(1, slotOf.values.flatMap { $0.values }.max().map { $0 + 1 } ?? 1)
                var wraps: [Int] = [], r = 2
                while r < tallest { wraps.append(r); r = max(r + 1, r * 5 / 4) }
                wraps.append(max(tallest, 2))
                var best = (score: Double.infinity, wrap: wraps[0], shelf: 1)
                for r in wraps {
                    let d = dims(r).map { (width: $0.width == 0 ? 1 : $0.width, rows: $0.rows) }
                    let widest = d.map(\.width).max() ?? 1, total = d.map(\.width).reduce(0, +)
                    var shelves = Set<Int>([widest, total])
                    var w = Double(widest)
                    while w < Double(total) { shelves.insert(Int(w.rounded())); w *= 1.15 }
                    for sh in shelves.sorted() {
                        let packed = pack(d, shelf: sh), size = points(cols: packed.cols, rows: packed.rows)
                        let score = abs(log(Double(size.width / size.height) / Double(aspect))) + 0.25 * log(Double(size.width * size.height) / 1e6)
                        if score < best.score { best = (score, r, sh) }
                    }
                }
                wrap = best.wrap
                shelf = best.shelf
            }

            let sized = dims(wrap)
            let packed = pack(sized.map { (width: $0.width == 0 ? 1 : $0.width, rows: $0.rows) }, shelf: shelf)
            var frames: [String: CGRect] = [:]
            var groups: [Group] = []
            for (n, g) in order.enumerated() {
                let band = bands[g], dim = sized[n], origin = packed.at[n]
                let isCollapsed = collapsed.contains(band.id)
                let slot = slotOf[g] ?? [:]
                var offsets: [Int] = []
                var run = 0
                for w in dim.spans { offsets.append(run); run += w }
                for i in band.nodes where !isCollapsed {
                    let s = slot[i] ?? 0, d = nodes[i].depth - band.minDepth
                    frames[nodes[i].key] = CGRect(x: metrics.pad + CGFloat(origin.col + offsets[d] + s / wrap) * metrics.columnPitch,
                                                  y: metrics.pad + CGFloat(origin.row + s % wrap) * metrics.rowPitch,
                                                  width: metrics.cardWidth, height: metrics.cardHeight)
                }
                let ordered = band.nodes.sorted { (nodes[$0].depth, slot[$0] ?? 0, nodes[$0].key) < (nodes[$1].depth, slot[$1] ?? 0, nodes[$1].key) }
                let left = metrics.pad + CGFloat(origin.col) * metrics.columnPitch, top = metrics.pad + CGFloat(origin.row) * metrics.rowPitch
                let frame = isCollapsed
                    ? CGRect(x: left, y: top, width: metrics.cardWidth, height: metrics.cardHeight)
                    : CGRect(x: left - metrics.inset, y: top - metrics.inset, width: CGFloat(dim.width - 1) * metrics.columnPitch + metrics.cardWidth + 2 * metrics.inset,
                             height: CGFloat(dim.rows - 1) * metrics.rowPitch + metrics.cardHeight + 2 * metrics.inset)
                groups.append(Group(id: band.id, title: band.title, frame: frame, members: ordered.map { nodes[$0].key }, minDepth: band.minDepth,
                                    maxDepth: band.maxDepth, collapsed: isCollapsed, startRow: origin.row, rows: dim.rows, col: origin.col, columns: dim.spans))
            }
            return MapLayout(metrics: metrics, frames: frames, groups: groups, size: points(cols: packed.cols, rows: packed.rows), wrapRows: wrap, shelfColumns: shelf)
        }
    }
}
