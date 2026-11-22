import CoreGraphics
import Foundation

// The map's layout (docs/MAP-HISTORY-PLAN.md, "The canvas at scale", package C1): where each screen of a `MapSnapshot`
// sits on the canvas. Pure geometry over the snapshot's own fields: Foundation and CoreGraphics only, no layers, so it
// runs off the main thread and its result is cached (it is Codable). The renderer reads `frames` and `groups`.
//
// The grid is whole rows and whole columns: a column per depth, and a row is one card and the gap below it. Screens
// gather into groups, the section each hangs from; a group is a horizontal band of rows, and bands stack down the
// canvas in a stable order. A band has spare rows below its tallest column, so a screen that appears finds room
// without moving the next group. Given the previous layout, a lineage keeps its row; a new screen goes beside its
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
    }

    var metrics: Metrics
    /// By key: the screen's lineage, or its id when the lineage is empty. A collapsed group's members have none.
    var frames: [String: CGRect]
    /// In stacking order, top to bottom.
    var groups: [Group]
    var size: CGSize

    func group(_ id: String) -> Group? { groups.first { $0.id == id } }

    /// Lays `snapshot` out. With `previous` (made with the same metrics) the lineages it holds keep their place.
    /// `compact` forgets the previous rows and packs the groups again, but keeps their order.
    static func make(_ snapshot: MapSnapshot, previous: MapLayout? = nil, collapsed: Set<String> = [], metrics: Metrics = Metrics(), compact: Bool = false) -> MapLayout {
        Builder(snapshot, previous: previous, collapsed: collapsed, metrics: metrics, compact: compact).build()
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
        var nodes: [Node] = []
        var bands: [Band] = []
        /// Neighbours over the snapshot's edges, one step in either direction, by node.
        var near: [[Int]] = []
        /// The group each key stood in in the previous layout.
        var prevGroupOf: [String: String] = [:]

        init(_ s: MapSnapshot, previous: MapLayout?, collapsed: Set<String>, metrics: Metrics, compact: Bool) {
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
                    guard let f = previous.frames[nodes[i].key] else { rest.append(i); continue }
                    let col = Int(((f.minX - metrics.pad) / metrics.columnPitch).rounded())
                    let row = Int(((f.minY - metrics.pad) / metrics.rowPitch).rounded()) - prev.startRow
                    var cell = cells[col] ?? []
                    if col == nodes[i].depth, row >= 0, row >= cell.count || cell[row] == nil, prevGroupOf[nodes[i].key] == prev.id {
                        while cell.count <= row { cell.append(nil) }
                        cell[row] = i
                        cells[col] = cell
                        slot[i] = row
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

        func build() -> MapLayout {
            var prevBy: [String: MapLayout.Group] = [:]
            for g in previous?.groups ?? [] { prevBy[g.id] = g }

            var frames: [String: CGRect] = [:]
            var groups: [Group] = []
            var cursor = 0
            var shift = 0
            var deepest = 0
            for g in stacking() {
                let band = bands[g]
                deepest = max(deepest, band.maxDepth)
                let isCollapsed = collapsed.contains(band.id)
                let prev = compact ? nil : prevBy[band.id]
                let usable = prev.flatMap { $0.collapsed == isCollapsed ? $0 : nil }
                let candidate = prev.map { $0.startRow + shift } ?? 0
                let start = max(cursor, candidate)

                var slot: [Int: Int] = [:]
                var rows = 1
                if !isCollapsed {
                    slot = slots(of: g, prev: usable)
                    let need = (slot.values.max() ?? 0) + 1
                    rows = usable.map { max($0.rows, need) } ?? need + max(3, need / 8)
                    // A collapsed band that opens: its size is its need again, with room.
                    for i in band.nodes {
                        let s = slot[i] ?? 0
                        frames[nodes[i].key] = CGRect(x: metrics.pad + CGFloat(nodes[i].depth) * metrics.columnPitch,
                                                      y: metrics.pad + CGFloat(start + s) * metrics.rowPitch,
                                                      width: metrics.cardWidth, height: metrics.cardHeight)
                    }
                }
                let ordered = band.nodes.sorted { (nodes[$0].depth, slot[$0] ?? 0, nodes[$0].key) < (nodes[$1].depth, slot[$1] ?? 0, nodes[$1].key) }
                let left = metrics.pad + CGFloat(band.minDepth) * metrics.columnPitch
                let right = metrics.pad + CGFloat(band.maxDepth) * metrics.columnPitch + metrics.cardWidth
                let top = metrics.pad + CGFloat(start) * metrics.rowPitch
                let frame = isCollapsed
                    ? CGRect(x: left, y: top, width: metrics.cardWidth, height: metrics.cardHeight)
                    : CGRect(x: left - metrics.inset, y: top - metrics.inset, width: right - left + 2 * metrics.inset,
                             height: CGFloat(rows - 1) * metrics.rowPitch + metrics.cardHeight + 2 * metrics.inset)
                groups.append(Group(id: band.id, title: band.title, frame: frame, members: ordered.map { nodes[$0].key }, minDepth: band.minDepth,
                                    maxDepth: band.maxDepth, collapsed: isCollapsed, startRow: start, rows: rows))
                if let prev { shift = start - prev.startRow + rows - prev.rows }
                cursor = start + rows
            }
            let columns = deepest + 1
            let size = CGSize(width: metrics.pad * 2 + CGFloat(columns) * metrics.cardWidth + CGFloat(columns - 1) * metrics.gapX,
                              height: metrics.pad * 2 + CGFloat(max(cursor, 1)) * metrics.cardHeight + CGFloat(max(cursor, 1) - 1) * metrics.gapY)
            return MapLayout(metrics: metrics, frames: frames, groups: groups, size: size)
        }
    }
}
