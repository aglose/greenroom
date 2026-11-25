import AppKit

/// `Greenroom --map-detail-check DIR`: the detail column (MapDetail) and the time strip (MapTimeline) on a history of
/// six made-up snapshots, in a window, with no simulator. The history is `MapFixtures.make` with the mutations applied
/// one after another (restyle, retext, restructure, add, remove with retarget); each blob is a small picture drawn from
/// its name. It checks the words and lists of each kind of change, the difference picture, the filmstrip's frames, the
/// handles, the large viewer, and 500 snapshots' tag labels, and captures the column for a modified, an added and a
/// removed screen, the viewer and the strip to DIR. One `[greenroom] map-detail:` line per finding.
enum MapDetailCheck {
    static func run(dir: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let runner = Runner(dir: dir)
        DispatchQueue.main.async { runner.start() }
        app.run()
        exit(1)
    }

    // MARK: Pictures from names

    /// A 720×1560 picture whose header band, body and rows come from the blob's name: another name, another picture.
    static func draw(_ blob: String, dark: Bool) -> CGImage? {
        var bytes: [UInt8] = []
        var hex = Substring(blob)
        while hex.count >= 2 { bytes.append(UInt8(hex.prefix(2), radix: 16) ?? 0); hex = hex.dropFirst(2) }
        while bytes.count < 16 { bytes.append(UInt8(bytes.count * 37 & 0xff)) }
        let w = 720, h = 1560
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func c(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
        ctx.setFillColor(dark ? c(30, 32, 36) : c(246, 247, 249))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Top down, as a screen is read.
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(c(bytes[0] & 0xf0 | 0x08, bytes[1] & 0xf0 | 0x08, bytes[2] & 0xf0 | 0x08))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 220))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
        ctx.fill(CGRect(x: 40, y: 120, width: 200 + CGFloat(bytes[3] & 0x3f) * 5, height: 40))
        // The rows stand where they stand on every capture; only the first (a card) takes its colour from the name.
        ctx.setFillColor(c(bytes[4] & 0xf0 | 0x08, bytes[5] & 0xf0 | 0x08, bytes[6] & 0xf0 | 0x08))
        ctx.fill(CGRect(x: 40, y: 280, width: 640, height: 150))
        for r in 0..<6 {
            ctx.setFillColor(dark ? c(58, 62, 70) : c(222, 225, 231))
            ctx.fillEllipse(in: CGRect(x: 40, y: 500 + CGFloat(r) * 170, width: 100, height: 100))
            ctx.fill(CGRect(x: 170, y: 520 + CGFloat(r) * 170, width: 420, height: 24))
            ctx.fill(CGRect(x: 170, y: 565 + CGFloat(r) * 170, width: 280, height: 18))
        }
        return ctx.makeImage()
    }

    // MARK: The window

    private final class Runner: NSObject {
        let dir: URL
        let window: NSWindow
        let content = NSView()
        let timeline = MapTimeline()
        let detail = MapDetail()
        var ok = true
        var history: [MapSnapshot] = []
        var kinds: [String: String] = [:]
        var combos: [String: Bool] = [:]
        var cache: [String: CGImage] = [:]
        var requests = 0

        init(dir: URL) {
            self.dir = dir
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 940), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Map detail check"
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = Design.stage
            super.init()
            content.wantsLayer = true
            content.layer?.backgroundColor = Design.stage.cgColor
            timeline.translatesAutoresizingMaskIntoConstraints = false
            detail.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(timeline); content.addSubview(detail)
            NSLayoutConstraint.activate([
                timeline.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), timeline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                timeline.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                detail.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 12), detail.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
                detail.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            ])
            window.contentView = content
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }

        func expect(_ good: Bool, _ what: String) {
            if !good { ok = false }
            print("[greenroom] map-detail: \(good ? "ok  " : "FAIL") \(what)")
            fflush(stdout)
        }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

        func capture(_ name: String, _ w: NSWindow? = nil) {
            let window = w ?? self.window
            let file = dir.appendingPathComponent(name)
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
            if !locked, let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
               let image = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(window.windowNumber), 9)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
            } else if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
            }
        }

        /// Resolves a blob as the owner would: a picture, at once.
        func image(_ blob: String, _ done: @escaping (CGImage?) -> Void) {
            requests += 1
            if let hit = cache[blob] { done(hit); return }
            let img = MapDetailCheck.draw(blob, dark: combos[blob] ?? false)
            if let img { cache[blob] = img }
            done(img)
        }

        // MARK: The history

        var x = "", y = "", z = "", parent = "", same = "", retargeted = "", retargetTo = "", added = ""

        func build() {
            let s0 = MapFixtures.make(screens: 15, seed: 1, combos: ["light", "dark"])
            let leaves = MapFixtures.leaves(of: s0), branches = MapFixtures.branches(of: s0)
            x = leaves[0].lineage; z = leaves[1].lineage; y = branches[0].lineage; parent = branches[1].lineage
            let cross = MapFixtures.crossEdges(of: s0).first { e in
                let from = s0.screen(e.from)?.lineage
                return from != z && from != x && e.to != nil && s0.screen(e.to!)?.lineage != z && from != parent
            }!
            retargeted = s0.screen(cross.from)!.lineage
            retargetTo = s0.screens.first { $0.id != cross.to && $0.id != cross.from && $0.lineage != z }!.lineage
            let retargetCmd = cross.cmd
            let steps: [[MapFixtures.Mutation]] = [
                [.restyle(x)], [.retext(x)], [.restructure(y)], [.add(parent: parent, label: "Invite a friend")],
                [.remove(z), .retarget(from: retargeted, cmd: retargetCmd, to: retargetTo)],
            ]
            history = [s0]
            for (i, m) in steps.enumerated() { history.append(MapFixtures.apply(m, to: history[i], commit: MapJSON.sha256("detail-check|\(i)"))) }
            added = history[4].screens.first { $0.title == "Invite a friend" }!.lineage
            // Screens nothing touches are the same.
            let touched: Set<String> = [x, y, z, parent, retargeted, added]
            same = s0.screens.first { !touched.contains($0.lineage) && $0.parent != nil && !touched.contains(s0.screen($0.parent!)?.lineage ?? "") }!.lineage
            for s in history { for sc in s.screens { for (c, b) in sc.captures { combos[b] = c == "dark" } } }
        }

        func diff(_ a: Int, _ b: Int) -> MapDiff { MapDiff.compare(base: history[a], head: history[b]) }

        /// Shows `lineage` between two snapshots of the history and returns what the column says.
        @discardableResult
        func show(_ lineage: String, _ a: Int, _ b: Int, history range: [MapSnapshot]? = nil, diff d: MapDiff? = nil) -> MapDetail {
            detail.show(lineage: lineage, head: history[b], base: history[a], diff: d ?? diff(a, b), history: range ?? history, image: { [self] blob, done in image(blob, done) })
            return detail
        }

        func start() {
            build()
            window.setContentSize(NSSize(width: 1000, height: 940))
            // The strip first, on the six.
            func entries(_ h: [MapSnapshot]) -> [MapTimelineEntry] {
                h.enumerated().map { i, s in
                    let counts = i == 0 ? MapDiff.Counts() : MapDiff.compare(base: h[i - 1], head: s).counts
                    return MapTimelineEntry(commit: s.commit, label: String(s.commit.prefix(7)), date: Date(timeIntervalSince1970: 1_767_000_000 + Double(i) * 86_400),
                                            tag: i == 0 ? "v1.0" : (i == 4 ? "v1.1" : nil), added: counts.added, removed: counts.removed, modified: counts.modified)
                }
            }
            let six = entries(history)
            var heard: [(String, String)] = []
            timeline.onChange = { heard.append(($0, $1)) }
            timeline.show(six)
            expect(timeline.baseIndex == 4 && timeline.headIndex == 5, "the strip opens on the last two snapshots")
            expect(timeline.set(base: 1, head: 3), "setting base 1 and head 3 is taken")
            expect(heard.last.map { $0 == (six[1].commit, six[3].commit) } ?? false, "onChange reports the pair chosen: \(heard.last.map { "\($0.0.prefix(7)) \($0.1.prefix(7))" } ?? "nothing")")
            let before = heard.count
            expect(!timeline.set(base: 4), "a base after the head is refused")
            expect(!timeline.set(head: 0), "a head before the base is refused")
            expect(timeline.baseIndex == 1 && timeline.headIndex == 3 && heard.count == before, "a refusal changes nothing and says nothing")
            timeline.headPopup.selectItem(at: 0)
            _ = timeline.headPopup.target?.perform(timeline.headPopup.action, with: timeline.headPopup)
            expect(timeline.headIndex == 3 && timeline.headPopup.indexOfSelectedItem == 3, "the popup refuses a head before the base and goes back to it")
            timeline.basePopup.selectItem(at: 2)
            _ = timeline.basePopup.target?.perform(timeline.basePopup.action, with: timeline.basePopup)
            expect(timeline.baseIndex == 2 && heard.last.map { $0 == (six[2].commit, six[3].commit) } ?? false, "the popup picks a base by name")
            // The pointer: a handle dragged past the other stops against it.
            func click(_ type: NSEvent.EventType, _ at: CGFloat) {
                let p = timeline.convert(NSPoint(x: at, y: 20), to: nil)
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                switch type {
                case .leftMouseDown: timeline.mouseDown(with: e)
                case .leftMouseDragged: timeline.mouseDragged(with: e)
                default: timeline.mouseUp(with: e)
                }
            }
            window.layoutIfNeeded()
            timeline.layoutSubtreeIfNeeded()
            click(.leftMouseDown, timeline.handleX(2)); click(.leftMouseDragged, timeline.handleX(5)); click(.leftMouseUp, timeline.handleX(5))
            expect(timeline.baseIndex == 3 && timeline.headIndex == 3, "dragging the base past the head stops it at the head (base \(timeline.baseIndex), head \(timeline.headIndex))")
            click(.leftMouseDown, timeline.handleX(5)); click(.leftMouseUp, timeline.handleX(5))
            expect(timeline.headIndex == 5, "a click moves the nearer handle (head \(timeline.headIndex))")
            timeline.show(six, base: six[0].commit, head: six[5].commit)

            // 500 snapshots: marks merge, tags stay, no two tag labels touch.
            var many: [MapTimelineEntry] = []
            for i in 0..<500 {
                // Tags every 25 and a crowd of them in the middle.
                let tagged = i % 25 == 0 || (240...262).contains(i) && i % 2 == 0
                many.append(MapTimelineEntry(commit: String(format: "%040x", i * 7919), label: String(format: "%07x", i * 7919), date: nil, tag: tagged ? "v\(i / 25).\(i % 25)" : nil,
                                             added: i % 11 == 0 ? 1 : 0, removed: 0, modified: i % 3 == 0 ? (i % 17) : 0))
            }
            let tags = many.filter { $0.tag != nil }.count
            let wide = MapTimeline(frame: NSRect(x: 0, y: 0, width: 1000, height: MapTimeline.height))
            wide.show(many)
            wide.layoutSubtreeIfNeeded()
            let rects = wide.tagLabelRects
            var touching = 0
            for i in rects.indices { for j in rects.indices where j > i && rects[i].insetBy(dx: -2, dy: 0).intersects(rects[j]) { touching += 1 } }
            let layoutMarks = MapTimelineLayout.marks(many, width: 744)
            expect(layoutMarks.filter(\.isTag).count == tags, "all \(tags) tags keep their marks among \(layoutMarks.count) (500 snapshots merge into density)")
            expect(layoutMarks.count < 250 && layoutMarks.count > tags, "500 snapshots draw \(layoutMarks.count) marks, not 500")
            expect(touching == 0 && rects.count >= 10 && rects.allSatisfy { $0.minX >= 0 && $0.maxX <= wide.bounds.width },
                   "500 snapshots lay out \(rects.count) of \(tags) tag labels, \(touching) touching")
            // Narrower, and with the real strip's width, still none.
            for width in [300.0, 500.0, 1400.0] {
                let ms = MapTimelineLayout.marks(many, width: width)
                let ls = MapTimelineLayout.tagLabels(many, marks: ms, width: width) { ceil(($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .medium)]).width) }
                var bad = 0
                for i in ls.indices { for j in ls.indices where j > i && ls[i].rect.intersects(ls[j].rect) { bad += 1 } }
                expect(bad == 0 && !ls.isEmpty, "at \(Int(width)) points: \(ls.count) labels, \(bad) touching, \(ms.count) marks")
            }

            // Words and lists, one kind of change at a time.
            var d = show(x, 0, 1)
            expect(d.statusText.range(of: #"^modified: visual \d+\.\d\d%$"#, options: .regularExpression) != nil, "restyled: “\(d.statusText)”")
            let pix = d.pictures
            expect(pix?.compares == true && pix?.combos == ["light", "dark"], "a restyled screen compares both combinations")
            expect((pix?.difference["light"] != nil) && (pix?.differing["light"]?.differing ?? 0) > 0, "its difference picture is not empty (\(pix?.differing["light"]?.differing ?? 0) pixels)")
            expect(pix?.difference["dark"] != nil, "and there is one for dark")

            d = show(x, 1, 2)
            expect(d.statusText.range(of: #"^modified: visual \d+\.\d\d%, 1 text changed$"#, options: .regularExpression) != nil, "retexted: “\(d.statusText)”")
            expect(d.textLines == ["+ Changed in " + history[2].commit.prefix(7)], "its text list: \(d.textLines)")

            d = show(y, 2, 3)
            expect(d.statusText.contains("structure changed") && d.statusText.hasPrefix("modified: visual"), "restructured: “\(d.statusText)”")

            d = show(parent, 3, 4)
            expect(d.statusText == "modified: 1 route added", "a control added: “\(d.statusText)”")
            expect(d.controlLines == ["+ Invite a friend -> Invite a friend"], "its controls list: \(d.controlLines)")
            expect(d.changedControlLeads(0), "the new control leads somewhere that can be selected")
            var selected: [String] = []
            d.onSelect = { selected.append($0) }
            d.pressChangedControl(0)
            expect(selected == [added], "pressing it selects the other screen by lineage")

            d = show(added, 3, 4)
            expect(d.statusText == "added" && d.pictures?.compares == false && d.pictures?.single == "Added" && d.pictures?.head["light"] != nil, "an added screen: “\(d.statusText)”, its one picture")

            d = show(z, 4, 5)
            expect(d.statusText == "removed" && d.pictures?.compares == false && d.pictures?.single == "Removed" && d.pictures?.head["light"] != nil, "a removed screen: “\(d.statusText)”, its one picture")

            d = show(retargeted, 4, 5)
            let titleTo = history[5].screens.first { $0.lineage == retargetTo }!.title
            expect(d.statusText.hasPrefix("modified") && d.statusText.contains("route"), "a control retargeted: “\(d.statusText)”")
            expect(d.controlLines.contains { $0.hasPrefix("~ ") && $0.hasSuffix("-> " + titleTo) }, "its controls list says where it leads now: \(d.controlLines)")
            selected = []
            d.onSelect = { selected.append($0) }
            if let i = d.controlLines.firstIndex(where: { $0.hasPrefix("~ ") }) { d.pressChangedControl(i) }
            expect(selected == [retargetTo], "pressing it selects the new target")

            d = show(same, 0, 1)
            let sp = d.pictures
            expect(d.statusText == "same" && sp?.difference.isEmpty == true && sp?.differing.isEmpty == true, "an untouched screen: “\(d.statusText)”, no difference picture")
            expect(sp?.head["light"] != nil, "it shows the head")

            // Never settles.
            var flaky = history[1]
            if let i = flaky.screens.firstIndex(where: { $0.lineage == same }) { flaky.screens[i].settled = false }
            var flakyBase = history[0]
            if let i = flakyBase.screens.firstIndex(where: { $0.lineage == same }) { flakyBase.screens[i].settled = false }
            let fd = MapDiff.compare(base: flakyBase, head: flaky)
            detail.show(lineage: same, head: flaky, base: flakyBase, diff: fd, history: history, image: { [self] b, done in image(b, done) })
            expect(detail.statusText == "not compared: it never settles", "a screen that never settles: “\(detail.statusText)”")

            // The route.
            d = show(x, 0, 5)
            var copied = ""
            var wentTo = ""
            d.onCopyRoute = { copied = $0 }
            d.onGo = { wentTo = $0 }
            d.copyRoute(); d.goPressed()
            expect(!copied.isEmpty && copied == NSPasteboard.general.string(forType: .string) && copied.hasPrefix("restart"), "copy route puts the commands on the pasteboard and says so")
            expect(wentTo == x, "go there says which lineage")

            // The filmstrip.
            expect(MapDetail.frames(lineage: x, history: history).map(\.count) == [1, 1, 4], "restyled then retexted: frames cover [1, 1, 4] snapshots")
            expect(d.frames.count == 3 && d.frames.map(\.changed) == [false, true, true], "three frames across six snapshots, the last two marked changed (\(d.frames.count))")
            expect(d.frames.last?.label == String(history[2].commit.prefix(7)) + " – " + String(history[5].commit.prefix(7)), "the last is labelled with its commit range: \(d.frames.last?.label ?? "")")
            expect(MapDetail.frames(lineage: y, history: history).count == 2, "restructured: its capture changed at the restructure, one more frame (\(MapDetail.frames(lineage: y, history: history).count))")
            expect(MapDetail.frames(lineage: same, history: history).count == 1, "an untouched screen is one frame")
            let fa = MapDetail.frames(lineage: added, history: history)
            expect(fa.count == 1 && fa[0].count == 2 && !fa[0].changed, "an added screen has no frames before it was there")
            let fz = MapDetail.frames(lineage: z, history: history)
            expect(fz.count == 2 && !fz[1].present && fz[1].changed, "a removed screen ends in a frame where it is not there")
            var picked: [String] = []
            d.onPickCommit = { picked.append($0) }
            d.pickFrame(1)
            expect(picked == [history[1].commit], "a frame's press gives its first commit to make the base")

            // Captures: the column for the three kinds.
            after(0.2) { self.captures() }
        }

        func captures() {
            timeline.show((0..<6).map { i in MapTimelineEntry(commit: history[i].commit, label: String(history[i].commit.prefix(7)), date: nil, tag: i == 0 ? "v1.0" : (i == 4 ? "v1.1" : nil),
                                                              added: i == 4 ? 1 : 0, removed: i == 5 ? 1 : 0, modified: i == 0 ? 0 : i + 1) }, base: history[0].commit, head: history[5].commit)
            show(x, 0, 5)
            after(0.5) {
                self.capture("detail-modified.png")
                self.show(self.added, 3, 4)
                self.after(0.4) {
                    self.capture("detail-added.png")
                    self.show(self.z, 4, 5)
                    self.after(0.4) {
                        self.capture("detail-removed.png")
                        self.viewer()
                    }
                }
            }
        }

        func viewer() {
            show(x, 0, 5)
            after(0.3) {
                self.detail.openViewer()
                guard let w = self.detail.viewer, let v = w.contentView as? MapPictureViewer else { self.expect(false, "a click opens the large viewer"); return self.finish() }
                self.expect(true, "a click opens the large viewer")
                self.after(0.5) {
                    self.expect(v.paneCount == 3, "side by side shows base, head and difference")
                    self.capture("viewer-side-by-side.png", w)
                    // Another mode, then actual pixels.
                    self.detail.viewer?.makeKeyAndOrderFront(nil)
                    v.setMode(.difference)
                    self.after(0.3) {
                        self.expect(v.paneCount == 1 && v.firstPane?.imageA != nil, "difference only shows the one picture")
                        guard let pane = v.firstPane else { return self.finish() }
                        pane.setFactor(pane.actualFactor)
                        self.expect(abs(pane.scale * (w.backingScaleFactor) - 1) < 0.01 && v.zoomText == "100%", "zooms to actual pixels: \(v.zoomText)")
                        let c0 = v.zoom.center
                        pane.pan(dx: 40, dy: 60)
                        self.expect(v.zoom.center != c0, "and pans")
                        self.capture("viewer-actual-pixels.png", w)
                        v.setMode(.wipe)
                        self.after(0.3) {
                            self.expect(v.paneCount == 1 && v.firstPane?.imageA != nil && v.firstPane?.imageB != nil, "wipe lays base under head")
                            self.capture("viewer-wipe.png", w)
                            w.close()
                            self.timelineCaptures()
                        }
                    }
                }
            }
        }

        func timelineCaptures() {
            // The strip alone, six and 500, on the stage, for a look.
            let big = MapTimeline(frame: NSRect(x: 0, y: 0, width: 976, height: MapTimeline.height))
            var many: [MapTimelineEntry] = []
            for i in 0..<500 {
                let tagged = i % 25 == 0 || (240...262).contains(i) && i % 2 == 0
                many.append(MapTimelineEntry(commit: String(format: "%040x", i * 7919), label: String(format: "%07x", i * 7919), date: nil, tag: tagged ? "v\(i / 25).\(i % 25)" : nil,
                                             added: i % 11 == 0 ? 1 : 0, removed: 0, modified: i % 3 == 0 ? (i % 17) : 0))
            }
            big.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(big)
            NSLayoutConstraint.activate([big.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 12), big.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                                         big.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -354)])
            big.show(many, base: many[120].commit, head: many[380].commit)
            detail.isHidden = true
            after(0.4) {
                self.capture("timeline.png")
                self.finish()
            }
        }

        func finish() {
            print("[greenroom] map-detail: \(ok ? "PASS" : "FAIL")")
            fflush(stdout)
            exit(ok ? 0 : 1)
        }
    }
}
