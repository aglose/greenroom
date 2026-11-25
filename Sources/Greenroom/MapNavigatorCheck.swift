import AppKit

/// `Greenroom --map-navigator-check DIR`: getting around the map (MapNavigator) on made-up maps (MapFixtures), in a
/// window of its own, with no simulator. On the 500-screen "mixed" pair it checks what opens (the changed screens and
/// their one-step neighbours, the rest folded), the filters' counts against the comparison's, search, folding a group
/// and opening it again, the removed screen, the minimap and the keys. On the 2,000-screen pair it times opening from a
/// cached layout and counts the surface's layers. Window captures go to DIR. One `[greenroom] map-navigator:` line per
/// finding, and a last PASS or FAIL.
enum MapNavigatorCheck {
    static func run(dir: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(dir: dir)
        // From a timer, not a block on the main queue: the script waits on blocks that queue runs, and one that runs inside
        // another would never get its turn.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in runner.start() }
        app.run()
        exit(1)
    }

    private final class Runner {
        let dir: URL
        let window: NSWindow
        let nav: MapNavigator
        var ok = true

        init(dir: URL) {
            self.dir = dir
            let folder = dir.appendingPathComponent("pyramid")
            try? FileManager.default.removeItem(at: folder)
            let pyramid = MapPyramid(folder: folder, byteLimit: 96 << 20) { blob, maxPixel, done in MapSurfaceCheck.standIn(blob, maxPixel, done) }
            nav = MapNavigator(pyramid: pyramid)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Map navigator check"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = Design.stage
            window.contentView = nav
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }

        func expect(_ good: Bool, _ what: String) {
            if !good { ok = false }
            print("[greenroom] map-navigator: \(good ? "ok  " : "FAIL") \(what)")
            fflush(stdout)
        }

        /// Runs the main loop until the navigator has no plan on its way (or a few seconds have passed), then a beat more
        /// for the surface's own deferred work.
        func settle(_ seconds: Double = 0.3) {
            let limit = Date().addingTimeInterval(20)
            while nav.busy, Date() < limit { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(seconds))
        }

        func capture(_ name: String) {
            let file = dir.appendingPathComponent(name)
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
            if !locked, let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
               let image = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(window.windowNumber), 9)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
            } else if let root = window.contentView?.layer {
                let scale = window.backingScaleFactor, size = window.contentView!.bounds.size
                guard let ctx = MapPyramid.context(Int(size.width * scale), Int(size.height * scale)) else { return }
                ctx.setFillColor(Design.stage.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
                ctx.scaleBy(x: scale, y: scale)
                root.render(in: ctx)
                if let image = ctx.makeImage() { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file) }
            }
        }

        func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }

        func key(_ s: MapSnapshot.Screen) -> String { s.lineage.isEmpty ? s.id : s.lineage }

        func start() {
            mixed()
            whole()
            large()
            print("[greenroom] map-navigator: \(ok ? "PASS" : "FAIL")")
            fflush(stdout)
            exit(ok ? 0 : 1)
        }

        // MARK: The changes in the whole map

        /// Unfolded under a comparison: what did not change steps back, the view opens on the first place where
        /// screens changed, and the stepper goes round the places.
        func whole() {
            let unit = MapSurface.regions(of: [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 40, y: 0, width: 10, height: 10),
                                               CGRect(x: 500, y: 0, width: 10, height: 10), CGRect(x: 20, y: 30, width: 10, height: 10)], reach: 25)
            expect(unit == [CGRect(x: 0, y: 0, width: 50, height: 40), CGRect(x: 500, y: 0, width: 10, height: 10)],
                   "frames near each other are one place, a far one another (\(unit.count))")

            let pair = MapFixtures.golden().first { $0.name == "mixed" }!
            nav.show(pair.head, diff: pair.expected, base: pair.base)
            settle()
            expect(!nav.surface.spotlight && nav.regions.isEmpty && nav.regionTitle.isEmpty, "folded to the changes, nothing is dimmed and there is no stepper")
            nav.toggleFold()
            settle(0.6)
            guard let scroll = nav.surface.enclosingScrollView else { expect(false, "the surface is in a scroll view"); return }
            let changed = nav.surface.changedFrames, regions = nav.regions
            let covered = changed.allSatisfy { f in regions.contains { $0.contains(f) } }
            let apart = regions.indices.allSatisfy { i in regions.indices.allSatisfy { j in i == j || !regions[i].insetBy(dx: -MapNavigator.regionReach, dy: -MapNavigator.regionReach).intersects(regions[j]) } }
            expect(nav.surface.spotlight && !changed.isEmpty && !regions.isEmpty && covered && apart,
                   "the whole map: \(changed.count) changed screens stand in \(regions.count) place(s), each screen in one, the places apart")
            func centred(_ r: CGRect) -> Bool {
                let v = scroll.contentView.bounds
                return v.contains(CGPoint(x: r.midX, y: r.midY)) || v.contains(r)
            }
            let all = nav.surface.bounds.size
            let closer = scroll.magnification > scroll.minMagnification * 1.05 || regions[0].width > all.width * 0.6 || regions[0].height > all.height * 0.6
            expect(centred(regions[0]) && closer, "it opens on the first place, closer than the whole map (\(String(format: "%.2f", scroll.magnification))x against \(String(format: "%.2f", scroll.minMagnification))x to fit)")
            expect(regions.count > 1 ? nav.regionTitle.contains("1 of \(regions.count)") : nav.regionTitle == "Show the changes", "the stepper says where: “\(nav.regionTitle)”")
            capture("7-whole-first-place.png")
            if regions.count > 1 {
                nav.stepRegion(1)
                settle(0.7)
                expect(nav.regionIndex == 1 && centred(regions[1]) && nav.regionTitle.contains("2 of \(regions.count)"), "the stepper goes to the next place: “\(nav.regionTitle)”")
                capture("8-whole-next-place.png")
                nav.keyDown(with: key("r", code: 15, flags: .shift))
                settle(0.7)
                expect(nav.regionIndex == 0 && centred(regions[0]), "Shift-R goes back")
            }
            nav.toggleFold()
            settle(0.6)
            expect(!nav.surface.spotlight && nav.regions.isEmpty && nav.regionTitle.isEmpty, "folded again, the dimming and the stepper go")
        }

        // MARK: The 500-screen pair

        func mixed() {
            let pair = MapFixtures.golden().first { $0.name == "mixed" }!
            let head = pair.head, base = pair.base, diff = pair.expected
            nav.show(head, diff: diff, base: base)
            settle()
            guard let plan = nav.plan, let model = nav.model else { expect(false, "the map opened"); return }

            // What should be shown, worked out from the comparison and the two snapshots' routes alone.
            func lineages(_ s: MapSnapshot) -> [String: String] { Dictionary(s.screens.map { ($0.id, $0.lineage) }, uniquingKeysWith: { a, _ in a }) }
            let headL = lineages(head), baseL = lineages(base)
            let changed = Set(diff.screens.filter { [.added, .removed, .modified].contains($0.status) }.map(\.lineage))
            var near = changed
            func join(_ a: String?, _ b: String?) {
                guard let a, let b else { return }
                if changed.contains(a) { near.insert(b) }
                if changed.contains(b) { near.insert(a) }
            }
            for e in head.edges { join(headL[e.from], e.to.flatMap { headL[$0] }) }
            let gone = Dictionary(diff.edges.filter { $0.status == .removed || $0.status == .retargeted }.map { ($0.from + "\u{1}" + $0.cmd, true) }, uniquingKeysWith: { a, _ in a })
            for e in base.edges where gone[(baseL[e.from] ?? "") + "\u{1}" + e.cmd] != nil { join(baseL[e.from], e.to.flatMap { baseL[$0] }) }
            let universe = Set(head.screens.map(\.lineage)).union(diff.screens.filter { $0.head == nil }.map(\.lineage))
            expect(!changed.isEmpty && near.count > changed.count, "the pair has \(changed.count) changed screens and \(near.count) with their neighbours, of \(universe.count)")
            expect(plan.shown == near, "opening shows the changed screens and their neighbours: \(plan.shown.count) of \(universe.count) (expected \(near.count))")
            expect(plan.folded == universe.count - near.count && nav.foldTitle.hasPrefix("\(plan.folded) unchanged"),
                   "the rest is folded into a line: “\(nav.foldTitle)”")
            expect(near.allSatisfy { nav.surface.frame(of: $0) != nil } && nav.surface.liveCards >= 0, "every shown screen has a card on the map")
            expect(universe.subtracting(near).allSatisfy { nav.surface.frame(of: $0) == nil }, "no folded screen has one")
            expect(plan.input.placement.groups.count + plan.collapsed.count == plan.groups.count, "\(plan.groups.count) groups, none folded below 300 shown screens")
            nav.surface.update()
            // The pictures come from the pyramid off the main thread: give them a moment, then count the cards that have one.
            let wait = Date().addingTimeInterval(5)
            while nav.surface.picturedCards < min(nav.surface.liveCards, 6), Date() < wait { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            settle()
            expect(nav.surface.detail >= .middle && nav.surface.picturedCards > 0, "cards in view show their pictures: \(nav.surface.picturedCards) of \(nav.surface.liveCards) live cards, at \(nav.surface.detail)")
            capture("1-changes-first.png")

            // The removed screen stands in its base place, marked removed.
            let removed = diff.screens.first { $0.status == .removed }!
            expect(nav.surface.frame(of: removed.lineage) != nil && plan.input.changes[removed.lineage]?.status == .removed
                   && plan.input.screens.contains { $0.lineage == removed.lineage }, "the removed screen is on the map, marked removed")
            expect(plan.input.edges.contains { $0.change == .removed } && plan.input.edges.contains { $0.change == .added }, "its routes are drawn as removed, new ones as added")

            // The filters' counts are the comparison's.
            let c = diff.counts
            let titles = nav.segmentTitles
            let want = ["All \(universe.count)", "Changed \(c.differing)", "Added \(c.added)", "Removed \(c.removed)", "Modified \(c.modified)", "Crashes 0", "Not compared \(c.notCompared)"]
            expect(titles == want, "filters carry their counts: \(titles.joined(separator: " · "))")
            for f in MapNavigator.Filter.allCases where f != .all {
                nav.setFilter(f)
                settle(0.05)
                let expected: Set<String> = switch f {
                case .changed: changed
                case .added, .removed, .modified, .notCompared: Set(diff.screens.filter { s in
                    switch f { case .added: s.status == .added; case .removed: s.status == .removed; case .modified: s.status == .modified; default: s.status == .notCompared }
                }.map(\.lineage))
                default: []
                }
                let p = nav.plan!
                expect(p.shown == expected && expected.allSatisfy { nav.surface.frame(of: $0) != nil }, "\(f.name): \(p.shown.count) screens shown, \(expected.count) expected, each with a card")
            }
            nav.setFilter(.added)
            settle()
            let addedPlan = nav.plan!
            expect(addedPlan.layout.size.height < plan.layout.size.height + 1 && addedPlan.layout.frames.count == addedPlan.shown.count, "a filter lays out what is shown: no holes (canvas \(Int(addedPlan.layout.size.width)) × \(Int(addedPlan.layout.size.height)))")
            capture("2-filter-added.png")
            nav.setFilter(.all)
            settle()

            // Search finds a hidden screen by a word of its text, and reveals it.
            let hidden = head.screens.first { !near.contains($0.lineage) && $0.depth >= 3 }!
            let word = hidden.texts.first { $0.hasPrefix("Row") }!
            nav.search(word)
            expect(nav.searchMatches > 0 && nav.searchResultKeys.contains(key(hidden)), "search “\(word)” finds \(nav.searchMatches) screens, the one with that text among them")
            nav.search(hidden.title.lowercased())
            expect(nav.searchResultKeys.first == key(hidden) && model.items[model.index[key(hidden)]!].section == hidden.title.components(separatedBy: " ").first!,
                   "its title finds it first, in its group “\(model.items[model.index[key(hidden)]!].section)”")
            nav.search(word)
            nav.setFilter(.removed)
            settle(0.05)
            nav.reveal(key(hidden))
            settle(0.6)
            expect(nav.filter == .all && !nav.foldTitle.hasPrefix("\(plan.folded) unchanged") && nav.surface.selected == key(hidden) && nav.surface.frame(of: key(hidden)) != nil,
                   "revealing it clears the filter and the fold and selects it")
            capture("3-search-reveal.png")
            nav.clearSearch(refocus: false)

            // Groups: the unchanged ones open folded, a changed one can be folded and opened.
            let all = nav.plan!
            expect(all.shown.count == universe.count && all.collapsed.count > 0 && all.groups.values.contains { !$0.collapsed && $0.changed > 0 }
                   && all.groups.values.filter { $0.collapsed }.allSatisfy { $0.changed == 0 },
                   "all \(all.shown.count) screens: \(all.collapsed.count) of \(all.groups.count) groups folded, all with no changes")
            let tile = all.groups.values.first { $0.collapsed }!
            expect(nav.surface.frame(of: tile.id) != nil && all.input.screens.first { $0.lineage == tile.id }?.title == tile.summary, "a folded group is one tile: “\(tile.summary)”")
            let open = all.groups.values.filter { !$0.collapsed && $0.changed > 0 }.min { $0.id < $1.id }!
            func frames(_ p: MapNavigatorPlan) -> [String: CGRect] { Dictionary(uniqueKeysWithValues: p.layout.frames.map { ($0.key, $0.value) }) }
            let before = frames(all)
            nav.toggleGroup(open.id)
            settle(0.1)
            let folded = nav.plan!
            let after = frames(folded)
            expect(folded.collapsed.contains(open.id) && open.members.allSatisfy { nav.surface.frame(of: $0) == nil } && nav.surface.frame(of: open.id) != nil,
                   "folding “\(open.title)” removes its \(open.members.count) cards and leaves a tile")
            expect(folded.groups[open.id]?.summary == "\(open.title): \(open.members.count) screens, \(open.changed) changed", "its tile reads “\(folded.groups[open.id]?.summary ?? "")”")
            let aboveHold = all.layout.groups.prefix { $0.id != open.id }.allSatisfy { g in g.members.allSatisfy { before[$0] == after[$0] } }
            expect(aboveHold, "the groups above it did not move")
            capture("4-group-folded.png")
            // The tile close up: its name, count, changes and first pictures, not a card with a missing picture.
            nav.scroll.magnification = 1
            if let f = nav.surface.frame(of: open.id) {
                let clip = nav.scroll.contentView
                clip.scroll(to: clip.constrainBoundsRect(NSRect(x: f.minX - 400, y: f.minY - 300, width: clip.bounds.width, height: clip.bounds.height)).origin)
                nav.scroll.reflectScrolledClipView(clip)
                nav.surface.update()
            }
            settle(2.5)
            capture("4b-group-tile.png")
            if let root = window.contentView?.layer {   // the layers as they stand, for when the screen capture is of a window not yet redrawn
                let scale = window.backingScaleFactor, size = window.contentView!.bounds.size
                if let ctx = MapPyramid.context(Int(size.width * scale), Int(size.height * scale)) {
                    ctx.setFillColor(Design.stage.cgColor)
                    ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
                    ctx.scaleBy(x: scale, y: scale)
                    root.render(in: ctx)
                    if let image = ctx.makeImage() { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("4c-group-tile-layers.png")) }
                }
            }
            nav.toggleGroup(open.id)
            settle(0.1)
            let back = frames(nav.plan!)
            expect(open.members.allSatisfy { nav.surface.frame(of: $0) == back[$0] && back[$0] == before[$0] }, "opening it again puts its cards in the same frames")
            expect(before.allSatisfy { back[$0.key] == $0.value }, "and every other screen is where it was: \(before.count) frames compared")
            // Clicking the title of an open group folds it.
            let g0 = nav.plan!.titledGroupsForCheck.first!
            nav.surface.onGroup?(0)
            settle(0.1)
            expect(nav.plan!.collapsed.contains(g0), "a click on a group's title folds it")
            nav.toggleGroup(g0)
            settle(0.1)

            // The minimap.
            expect(nav.minimapIsVisible && nav.plan!.minimap != nil, "the minimap has its picture, made with the layout")
            let picture = nav.plan!.minimap
            nav.scroll.magnification = 2
            nav.surface.update()
            let target = CGPoint(x: nav.surface.bounds.width * 0.6, y: nav.surface.bounds.height * 0.5)
            nav.minimapView.onMove?(target)
            let visible = nav.surface.convert(nav.scroll.contentView.bounds, from: nav.scroll.contentView)
            expect(abs(visible.midX - target.x) < 2 && abs(visible.midY - target.y) < 2, "a click on the minimap centres the view there (asked \(Int(target.x)),\(Int(target.y)), got \(Int(visible.midX)),\(Int(visible.midY)) of \(Int(nav.surface.bounds.width)) × \(Int(nav.surface.bounds.height)))")
            expect(nav.plan!.minimap === picture, "scrolling leaves the picture as it was")
            capture("5-minimap.png")

            // The keys.
            nav.surface.fitAll()
            nav.setFilter(.changed)
            settle()
            let order = nav.plan!.changedOrder
            nav.window?.makeFirstResponder(nav.surface)
            nav.surface.select(nil, reveal: false)
            nav.keyDown(with: key("n", code: 45))
            settle(0.4)
            let first = nav.surface.selected
            nav.keyDown(with: key("n", code: 45))
            settle(0.4)
            let second = nav.surface.selected
            nav.keyDown(with: key("p", code: 35))
            settle(0.4)
            expect(first == order.first && second == order.dropFirst().first && nav.surface.selected == first, "N and P walk the \(order.count) changed screens in reading order")
            nav.keyDown(with: key("f", code: 3))
            expect(nav.scroll.magnification == nav.scroll.minMagnification, "F fits the whole map")
            expect(nav.performKeyEquivalent(with: key("f", code: 3, flags: .command)) && nav.window?.firstResponder is NSText, "⌘F goes to the search field")
            nav.search("zzzz-no-such-screen")
            expect(nav.searchMatches == 0, "a search with no answer says so")
            nav.keyDown(with: key("\u{1b}", code: 53))
            expect(nav.searchMatches == 0 && nav.searchResultKeys.isEmpty, "Escape clears the search")
            nav.setFilter(.all)
            settle()
        }

        // MARK: The 2,000-screen pair

        func large() {
            let pair = MapFixtures.large()
            nav.clearCaches()
            var t = CACurrentMediaTime()
            nav.show(pair.head, diff: pair.expected, base: pair.base)
            settle(0)
            let cold = (CACurrentMediaTime() - t) * 1000
            let plan = nav.plan!
            print(String(format: "[greenroom] map-navigator: 2,000 screens, first open (model, layout, minimap off the main thread) %.0f ms; %d shown, %d folded", cold, plan.shown.count, plan.folded))

            t = CACurrentMediaTime()
            nav.show(pair.head, diff: pair.expected, base: pair.base)
            let warm = (CACurrentMediaTime() - t) * 1000
            expect(nav.plan != nil && nav.lastOpen.cached && warm < 300, String(format: "opening on the changes from the cached layout: %.0f ms (limit 300)", warm))

            // Every screen on the map, so the heavy case: unfold once (laid out), fold, and time the way back.
            nav.toggleFold()
            settle()
            let everything = nav.plan!
            nav.toggleFold()
            settle(0.1)
            t = CACurrentMediaTime()
            nav.toggleFold()
            let heavy = (CACurrentMediaTime() - t) * 1000
            expect(nav.lastOpen.cached && nav.plan?.id == everything.id && heavy < 300,
                   String(format: "opening all %d screens (%d groups, %d folded) from the cached layout: %.0f ms (limit 300)", everything.shown.count, everything.groups.count, everything.collapsed.count, heavy))
            settle(0.4)
            var most = 0, at = ""
            func sample(_ what: String) { let n = nav.surface.layerCount; if n > most { most = n; at = what } }
            sample("fitted")
            capture("6-large-fit.png")
            // In and out over a changed screen.
            let focus = everything.changedOrder.first(where: { nav.surface.frame(of: $0) != nil }).flatMap { nav.surface.frame(of: $0) } ?? CGRect(x: 500, y: 500, width: 96, height: 248)
            let centre = CGPoint(x: focus.midX, y: focus.midY)
            for m in [0.2, 0.45, 1, 2.5, 8, 1, 0.45] as [CGFloat] {
                nav.scroll.setMagnification(m, centeredAt: centre)
                nav.surface.update()
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
                sample(String(format: "%.2fx", m))
                if m == 1 { capture("7-large-1x.png") }
            }
            // And with every group open: 2,000 cards on the map.
            for g in nav.plan!.collapsed.sorted() { nav.toggleGroup(g); settle(0.05) }
            nav.surface.fitAll()
            sample("all open, fitted")
            for m in [0.45, 1, 2.5] as [CGFloat] {
                nav.scroll.setMagnification(max(m, nav.scroll.minMagnification), centeredAt: centre)
                nav.surface.update()
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
                sample(String(format: "all open, %.2fx", m))
            }
            expect(most <= 300, "the surface holds at most \(most) layers over the whole map and its zooms (limit 300, at \(at))")
            nav.toggleFold()
            settle()
        }
    }
}

extension MapNavigatorPlan {
    /// The first titled group's id: for checks.
    var titledGroupsForCheck: [String] { titledGroups }
}
