import AppKit

/// `Greenroom --map-surface-check DIR`: the map's renderer (MapSurface) on made-up maps (MapFixtures), in a window of
/// its own, with no workbench and no simulator. On the 2,000-screen pair it sweeps the magnification from the whole
/// map to 8x, pans at four details and zooms all the way in and out, driven by the display link; it counts the layers
/// alive at every step, times the scroll handler with `CACurrentMediaTime` (culling, paths and Core Animation's commit
/// together, per frame), and watches the pictures' memory against the pyramid's limit. Then it selects a screen and
/// checks its routes are lit, and shows a 15-screen map at 1x as the old canvas would. Window captures go to DIR.
/// One `[greenroom] map-surface:` line per finding.
enum MapSurfaceCheck {
    static func run(dir: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(dir: dir)
        DispatchQueue.main.async { runner.start() }
        app.run()
        exit(1)
    }

    // MARK: Fixtures as the surface takes them

    /// A pair's head with the base's gone screens added back, every route by lineage, and the comparison's verdicts.
    static func input(_ pair: MapFixtures.Pair) -> MapSurfaceInput {
        let head = pair.head, base = pair.base, diff = pair.expected
        func lineages(_ s: MapSnapshot) -> [String: String] { Dictionary(s.screens.map { ($0.id, $0.lineage) }, uniquingKeysWith: { a, _ in a }) }
        let headL = lineages(head), baseL = lineages(base)
        let headOut = Dictionary(grouping: head.edges, by: \.from), baseOut = Dictionary(grouping: base.edges, by: \.from)
        func screen(_ s: MapSnapshot.Screen, _ l: [String: String], _ snap: MapSnapshot) -> MapSurfaceScreen {
            let out = (snap.commit == head.commit ? headOut : baseOut)[s.id] ?? []
            return MapSurfaceScreen(lineage: s.lineage, id: s.id, title: s.title, activity: s.activity, depth: s.depth, parent: s.parent.flatMap { l[$0] },
                                    captures: s.captures, crashes: out.filter { $0.to == "CRASH" }.count, exits: out.filter { $0.to == "EXIT" }.count,
                                    loops: out.filter { $0.to == s.id }.count)
        }
        let inHead = Set(head.screens.map(\.lineage))
        var screens = head.screens.map { screen($0, headL, head) }
        screens += base.screens.filter { !inHead.contains($0.lineage) }.map { screen($0, baseL, base) }

        let changed = Dictionary(diff.edges.map { ($0.from + "\u{1}" + $0.cmd, $0.status) }, uniquingKeysWith: { a, _ in a })
        var edges: [String: MapSurfaceEdge] = [:]
        var order: [String] = []
        func add(_ from: String, _ to: String, _ label: String, _ change: MapSurfaceEdge.Change?) {
            let key = from + ">" + to + (change == .removed ? "-" : "")
            if edges[key] == nil { edges[key] = MapSurfaceEdge(from: from, to: to, labels: [], change: change); order.append(key) }
            edges[key]!.labels.append(label)
        }
        for e in head.edges {
            guard let to = e.to.flatMap({ headL[$0] }), let from = headL[e.from], from != to else { continue }
            let status = changed[from + "\u{1}" + e.cmd]
            add(from, to, e.action, status == .added || status == .retargeted ? .added : nil)
        }
        for e in base.edges {
            guard let to = e.to.flatMap({ baseL[$0] }), let from = baseL[e.from], from != to else { continue }
            let status = changed[from + "\u{1}" + e.cmd]
            if status == .removed || status == .retargeted { add(from, to, e.action, .removed) }
        }
        return MapSurfaceInput(screens: screens, edges: order.map { edges[$0]! }, placement: placement(screens),
                               changes: Dictionary(diff.screens.map { ($0.lineage, $0) }, uniquingKeysWith: { a, _ in a }), combo: "light")
    }

    /// A stand-in for MapLayout: a column per depth as the old canvas had, children in their parents' order; a depth
    /// with more screens than fit wraps into more columns, so a big map comes out about as wide as a screen is.
    static func placement(_ screens: [MapSurfaceScreen]) -> MapPlacement {
        let w: CGFloat = 96, h: CGFloat = 248, gapX: CGFloat = 150, gapY: CGFloat = 34, wrapGap: CGFloat = 54
        let byDepth = Dictionary(grouping: screens, by: \.depth)
        let tallest = byDepth.values.map(\.count).max() ?? 1
        let wrap = Int((Double(screens.count) * Double(w + wrapGap) * Double(h + gapY) / 1.6).squareRoot() / Double(h + gapY))
        let rows = tallest <= 40 ? tallest : max(8, wrap)
        let big = tallest > 40
        let pad: CGFloat = 70, top: CGFloat = big ? 360 : 70
        let height = CGFloat(rows) * h + CGFloat(rows - 1) * gapY
        var rowOf: [String: Int] = [:]
        var frames: [String: CGRect] = [:]
        var groups: [MapPlacement.Group] = []
        var x = pad
        for d in byDepth.keys.sorted() {
            let here = byDepth[d]!.enumerated().sorted { a, b in
                let pa = a.element.parent.flatMap { rowOf[$0] } ?? -1, pb = b.element.parent.flatMap { rowOf[$0] } ?? -1
                return pa != pb ? pa < pb : a.offset < b.offset
            }.map(\.element)
            let cols = (here.count + rows - 1) / rows
            for (k, s) in here.enumerated() {
                rowOf[s.lineage] = k
                let col = k / rows, row = k % rows
                let inCol = min(rows, here.count - col * rows)
                let y = top + (height - (CGFloat(inCol) * h + CGFloat(inCol - 1) * gapY)) / 2 + CGFloat(row) * (h + gapY)
                frames[s.lineage] = CGRect(x: x + CGFloat(col) * (w + wrapGap), y: y, width: w, height: h)
            }
            let width = CGFloat(cols) * w + CGFloat(cols - 1) * wrapGap
            groups.append(.init(frame: CGRect(x: x - 28, y: top - 28, width: width + 56, height: height + 56),
                                title: d == 0 ? "Start" : "\(d) tap\(d == 1 ? "" : "s") in · \(here.count) screen\(here.count == 1 ? "" : "s")"))
            x += width + gapX
        }
        return MapPlacement(frames: frames, groups: groups, size: CGSize(width: x - gapX + pad, height: top + height + pad))
    }

    /// A made-up capture drawn from the blob's bytes: a phone screen's bar, title and rows, coloured and sized by them.
    static func standIn(_ blob: String, _ maxPixel: Int, _ done: (CGImage?) -> Void) {
        var bytes: [UInt8] = []
        var hex = Substring(blob)
        while hex.count >= 2 { bytes.append(UInt8(hex.prefix(2), radix: 16) ?? 0); hex = hex.dropFirst(2) }
        while bytes.count < 32 { bytes.append(UInt8(bytes.count * 37 & 0xff)) }
        let scale = maxPixel == 0 ? 1 : min(1, CGFloat(maxPixel) / 2340)
        let w = Int(1080 * scale), h = Int(2340 * scale)
        guard let ctx = MapPyramid.context(w, h) else { done(nil); return }
        ctx.scaleBy(x: scale, y: scale)
        // Top down, as a screen is read.
        ctx.translateBy(x: 0, y: 2340)
        ctx.scaleBy(x: 1, y: -1)
        let hue = CGFloat(bytes[0]) / 255, dark = bytes[1] & 1 == 1
        func color(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat) -> CGColor { NSColor(hue: h.truncatingRemainder(dividingBy: 1), saturation: s, brightness: b, alpha: 1).cgColor }
        ctx.setFillColor(dark ? color(hue, 0.15, 0.13) : color(hue, 0.04, 0.98))
        ctx.fill(CGRect(x: 0, y: 0, width: 1080, height: 2340))
        ctx.setFillColor(color(hue, 0.62, dark ? 0.55 : 0.78))
        ctx.fill(CGRect(x: 0, y: 0, width: 1080, height: 330))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.9).cgColor)
        ctx.fill(CGRect(x: 60, y: 190, width: 300 + CGFloat(bytes[2]) * 1.6, height: 64))
        let rows = 5 + Int(bytes[3] % 5)
        for r in 0..<rows {
            let y = 400 + CGFloat(r) * 1800 / CGFloat(rows)
            let b = bytes[4 + r % 24]
            ctx.setFillColor(color(hue + CGFloat(b) / 1024, 0.45, dark ? 0.45 : 0.85))
            ctx.fillEllipse(in: CGRect(x: 60, y: y + 20, width: 150, height: 150))
            ctx.setFillColor(dark ? NSColor(white: 1, alpha: 0.55).cgColor : NSColor(white: 0, alpha: 0.6).cgColor)
            ctx.fill(CGRect(x: 250, y: y + 40, width: 280 + CGFloat(b) * 2.4, height: 44))
            ctx.setFillColor(dark ? NSColor(white: 1, alpha: 0.25).cgColor : NSColor(white: 0, alpha: 0.22).cgColor)
            ctx.fill(CGRect(x: 250, y: y + 110, width: 200 + CGFloat(bytes[(5 + r) % 32]) * 2.2, height: 34))
        }
        ctx.setFillColor(color(hue + 0.5, 0.7, 0.85))
        ctx.fillEllipse(in: CGRect(x: 840, y: 2080, width: 180, height: 180))
        done(ctx.makeImage())
    }

    // MARK: The script

    private final class Runner: NSObject {
        let dir: URL
        let window: NSWindow
        let scroll: NSScrollView
        let surface: MapSurface
        let pyramid: MapPyramid
        var ok = true
        var mostLayers = 0, mostLayersAt = ""
        // The current scripted motion, run by the display link.
        var motion: ((Double) -> Bool)?
        var motionDone: (() -> Void)?
        var motionStart = 0.0
        var lastTick = 0.0
        var slowestHandler = 0.0, longestInterval = 0.0, frames = 0, late = 0, nominal = 1.0 / 60
        var link: CADisplayLink?

        init(dir: URL) {
            self.dir = dir
            let folder = dir.appendingPathComponent("pyramid")
            try? FileManager.default.removeItem(at: folder)
            pyramid = MapPyramid(folder: folder, byteLimit: 96 << 20) { blob, maxPixel, done in MapSurfaceCheck.standIn(blob, maxPixel, done) }
            (scroll, surface) = MapSurface.scrollView(pyramid: pyramid)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Map surface check"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = Design.stage
            super.init()
            window.contentView = scroll
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }

        func expect(_ good: Bool, _ what: String) {
            if !good { ok = false }
            print("[greenroom] map-surface: \(good ? "ok  " : "FAIL") \(what)")
            fflush(stdout)
        }
        func note(_ what: String) { print("[greenroom] map-surface: \(what)"); fflush(stdout) }

        func sample(_ at: String) {
            let n = surface.layerCount
            if n > mostLayers { mostLayers = n; mostLayersAt = at }
        }

        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

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

        var focus = CGPoint.zero
        var focusLineage = ""

        func zoom(_ m: CGFloat, at p: CGPoint) {
            scroll.setMagnification(m, centeredAt: p)
            surface.update()
        }

        func start() {
            let made = CACurrentMediaTime()
            let pair = MapFixtures.large()
            let input = MapSurfaceCheck.input(pair)
            note(String(format: "large: %d screens, %d routes (from %d edges), %d groups; input made in %.0f ms", input.screens.count, input.edges.count,
                        pair.head.edges.count, input.placement.groups.count, (CACurrentMediaTime() - made) * 1000))
            let t0 = CACurrentMediaTime()
            surface.show(input)
            surface.fitAll()
            note(String(format: "shown and fitted in %.0f ms; whole map at %.3fx, canvas %.0f × %.0f points", (CACurrentMediaTime() - t0) * 1000,
                        scroll.magnification, surface.bounds.width, surface.bounds.height))
            // The screen the sweep closes in on: a modified one with routes out, in the middle of the map.
            let mid = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
            let candidates = input.screens.filter { input.changes[$0.lineage]?.status == .modified && surface.routeCount(of: $0.lineage).out >= 3 }
            let pick = candidates.min { a, b in
                let fa = surface.frame(of: a.lineage)!, fb = surface.frame(of: b.lineage)!
                return hypot(fa.midX - mid.x, fa.midY - mid.y) < hypot(fb.midX - mid.x, fb.midY - mid.y)
            } ?? input.screens[input.screens.count / 2]
            focusLineage = pick.lineage
            let f = surface.frame(of: pick.lineage)!
            focus = CGPoint(x: f.midX, y: f.minY + (f.height - 40) / 2)
            after(1.2) { [self] in
                sample("whole map")
                expect(surface.detail == .far && surface.liveCards == 0, "the whole map is far: tiles and titles, \(surface.layerCount) layers, no cards")
                capture("1-far.png")
                sweep()
            }
        }

        /// From the whole map to 8x in sixteen steps, settling at each so the pictures come.
        func sweep() {
            let lo = scroll.minMagnification, hi = MapSurface.maxMagnification
            let steps = (0...15).map { lo * pow(hi / lo, CGFloat($0) / 15) }
            var counts: [String] = []
            func step(_ k: Int) {
                guard k < steps.count else {
                    note("sweep, layers alive per magnification: " + counts.joined(separator: ", "))
                    expect(mostLayers < 300, "fewer than 300 layers alive at every zoom of the sweep (most: \(mostLayers), at \(mostLayersAt))")
                    shots()
                    return
                }
                zoom(steps[k], at: focus)
                after(0.45) { [self] in
                    sample(String(format: "%.2fx", steps[k]))
                    counts.append(String(format: "%.2fx %d", steps[k], surface.layerCount))
                    step(k + 1)
                }
            }
            step(0)
        }

        func shots() {
            let plan: [(CGFloat, String)] = [(0.6, "2-middle.png"), (1.25, "3-near.png"), (5, "4-closest.png")]
            func shot(_ k: Int) {
                guard k < plan.count else {
                    expect(surface.detail == .closest && surface.liveCards > 0 && surface.liveCards <= 12, "at 5x only the few cards in view are alive (\(surface.liveCards))")
                    motions()
                    return
                }
                zoom(plan[k].0, at: focus)
                after(1.2) { [self] in
                    sample(String(format: "%.2fx", plan[k].0))
                    capture(plan[k].1)
                    shot(k + 1)
                }
            }
            shot(0)
        }

        // MARK: Motion, frame by frame

        @objc func tick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            nominal = link.duration > 0 ? link.duration : nominal
            if lastTick > 0 {
                let gap = now - lastTick
                longestInterval = max(longestInterval, gap)
                if gap > nominal * 1.5 { late += 1 }
            }
            if motion != nil, lastTick > 0, now - lastTick > 0.03 {
                note(String(format: "late tick: %.1f ms after the last, at %.2fx (%@), last update %.1f ms", (now - lastTick) * 1000,
                            scroll.magnification, "\(surface.detail)", surface.lastUpdate * 1000))
            }
            lastTick = now
            guard let motion else { return }
            let t0 = CACurrentMediaTime()
            let more = motion(t0 - motionStart)
            CATransaction.flush()
            slowestHandler = max(slowestHandler, CACurrentMediaTime() - t0)
            frames += 1
            sample("in motion")
            if !more {
                self.motion = nil
                let done = motionDone
                motionDone = nil
                lastTick = 0
                done?()
            }
        }

        func run(_ name: String, _ body: @escaping (Double) -> Bool, then: @escaping () -> Void) {
            slowestHandler = 0; longestInterval = 0; frames = 0; late = 0
            motionStart = CACurrentMediaTime()
            motion = body
            motionDone = { [self] in
                results.append((name, frames, slowestHandler, longestInterval, late))
                note(String(format: "%@: %d frames, slowest handler and commit %.1f ms, longest display interval %.1f ms (%d late of %.1f ms)",
                            name, frames, slowestHandler * 1000, longestInterval * 1000, late, nominal * 1000))
                then()
            }
        }
        var results: [(String, Int, Double, Double, Int)] = []

        func pan(_ name: String, at m: CGFloat, then: @escaping () -> Void) {
            zoom(m, at: focus)
            after(0.8) { [self] in
                let clip = scroll.contentView
                let start = clip.bounds.origin
                // 1,200 view points a second: right for a second and a half, then down and back.
                let speed = 1200 / Double(m)
                run(String(format: "pan at %.2fx", m), { t in
                    let x = t < 1.5 ? t : 1.5 - min(t - 1.5, 1.5) * 0.5
                    let y = t < 1.5 ? 0 : min(t - 1.5, 1.5)
                    let o = NSPoint(x: start.x + speed * x, y: start.y + speed * y)
                    clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: o, size: clip.bounds.size)).origin)
                    self.scroll.reflectScrolledClipView(clip)
                    return t < 3
                }, then: then)
            }
        }

        func motions() {
            let l = surface.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            let fit = scroll.minMagnification
            pan("far", at: fit) { [self] in
                pan("middle", at: 0.6) { [self] in
                    pan("near", at: 1.25) { [self] in
                        pan("closest", at: 4) { [self] in
                            zoom(fit, at: focus)
                            after(0.6) { [self] in
                                // In from the whole map to 8x over three seconds and out again, about the focus.
                                run("zoom", { t in
                                    let u = t < 3 ? t / 3 : max(0, 2 - t / 3)
                                    self.zoom(fit * pow(MapSurface.maxMagnification / fit, CGFloat(u)), at: self.focus)
                                    return t < 6
                                }) { [self] in
                                    judgeMotion()
                                }
                            }
                        }
                    }
                }
            }
        }

        func judgeMotion() {
            link?.invalidate()
            let worst = results.map(\.2).max() ?? 1
            let frames = results.map(\.1).reduce(0, +)
            expect(frames > 300 && worst < 0.016,
                   String(format: "scripted pan and zoom: %d frames, none over 16 ms in the scroll handler and commit (slowest %.1f ms)", frames, worst * 1000))
            let late = results.map(\.4).reduce(0, +)
            note(String(format: "display link: %d of %d frames came late (more than 1.5 × %.1f ms after the one before)", late, frames, nominal * 1000))
            expect(mostLayers < 300, "fewer than 300 layers alive through the motion too (most: \(mostLayers), at \(mostLayersAt))")
            note(String(format: "slowest culling pass (outside the display link too): %.1f ms", surface.slowestUpdate * 1000))
            expect(pyramid.peakBytes <= pyramid.byteLimit && pyramid.bytesInMemory <= pyramid.byteLimit,
                   String(format: "pictures in memory under the cache's limit: at most %.1f MB of %.0f MB, %d pictures now (%.1f MB); %d requests cancelled as cards left the view; %d blobs on disk",
                          Double(pyramid.peakBytes) / 1e6, Double(pyramid.byteLimit) / 1e6, pyramid.imagesInMemory, Double(pyramid.bytesInMemory) / 1e6,
                          pyramid.cancelled, pyramid.blobsOnDisk))
            selection()
        }

        // MARK: Selection and the small map

        func selection() {
            zoom(1.0, at: focus)
            surface.select(focusLineage, reveal: false)
            let routes = surface.routeCount(of: focusLineage)
            let drawn = surface.drawnRoutes
            expect(surface.selected == focusLineage && (drawn[.out] ?? 0) == routes.out && (drawn[.into] ?? 0) == routes.into && routes.out > 0,
                   "selecting a screen lights its routes: \(drawn[.out] ?? 0) of \(routes.out) out, \(drawn[.into] ?? 0) of \(routes.into) in, \(drawn[.dim] ?? 0) others dimmed")
            // The right arrow follows the first route out to a deeper screen.
            surface.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!)
            let moved = surface.selected
            expect(moved != nil && moved != focusLineage, "the right arrow moves the selection on")
            surface.select(focusLineage, reveal: false)
            after(1.0) { [self] in
                capture("5-selected.png")
                zoom(scroll.minMagnification, at: focus)
                after(0.6) { [self] in
                    expect((surface.drawnRoutes[.out] ?? 0) == routes.out, "far away the selected screen's routes are still lit (\(surface.drawnRoutes[.out] ?? 0))")
                    capture("6-selected-far.png")
                    small()
                }
            }
        }

        func small() {
            let pair = MapFixtures.golden()[0]
            let input = MapSurfaceCheck.input(pair)
            surface.show(input)
            surface.fitAll()
            let whole = scroll.magnification
            zoom(1, at: CGPoint(x: surface.bounds.midX, y: surface.bounds.midY))
            after(1.5) { [self] in
                let inView = input.screens.filter { surface.frame(of: $0.lineage)!.intersects(surface.visibleRect) }.count
                expect(whole < 1 && scroll.magnification == 1 && surface.detail == .near && surface.liveCards >= inView && inView >= 8,
                       String(format: "a %d-screen map fits at %.2fx and at 1x draws its cards as the old canvas did (%d in view, %d alive, %d layers)",
                              input.screens.count, whole, inView, surface.liveCards, surface.layerCount))
                capture("7-small.png")
                surface.select(input.screens.first { surface.routeCount(of: $0.lineage).out >= 2 }?.lineage, reveal: false)
                after(0.8) { [self] in
                    capture("8-small-selected.png")
                    print("[greenroom] map-surface check: \(ok ? "PASS" : "FAIL") (captures in \(dir.path))")
                    fflush(stdout)
                    exit(ok ? 0 : 1)
                }
            }
        }
    }
}
