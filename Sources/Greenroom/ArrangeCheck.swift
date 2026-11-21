import AppKit

extension AppDelegate {
    /// `Greenroom --arrange-check DIR APK`: three devices side by side, then arranged by hand through the views' own
    /// mouse handling: one moved by its body, one shrunk past its minimum and grown past the stage, one snapped beside
    /// another, one closed with its button, and Tidy Up. Prints one `[greenroom] arrange:` line per step, with `FAIL`
    /// where a rule does not hold, and captures the window at each stage. `GREENROOM_MEMORY_LABEL_MB=1` shows the
    /// memory label whatever the reading.
    func arrangeCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--arrange-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let apk = URL(fileURLWithPath: args[i + 2])
        let wb = workbench!
        wb.window.setContentSize(NSSize(width: 1500, height: 1000))
        wb.window.center()
        guard let first = wb.open(apk, remember: false) else { return }
        let grid = wb.stage
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            if !ok { failures += 1 }
            print("[greenroom] arrange: \(ok ? "ok" : "FAIL") \(what)")
        }
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func r(_ rect: CGRect) -> String { "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))" }
        /// A press, a drag in steps and a release, sent to the view as the window would send them.
        func drag(_ v: SimulatorView, from p: CGPoint, by d: CGSize) {
            func event(_ type: NSEvent.EventType, _ at: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: v.convert(at, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: wb.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            v.mouseDown(with: event(.leftMouseDown, p))
            for k in 1...8 { v.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: p.x + d.width * CGFloat(k) / 8, y: p.y + d.height * CGFloat(k) / 8))) }
            v.mouseUp(with: event(.leftMouseUp, CGPoint(x: p.x + d.width, y: p.y + d.height)))
            grid.layoutSubtreeIfNeeded()
        }
        /// A point on the device's body, away from the picture: the middle of the caption.
        func body(_ v: SimulatorView) -> CGPoint { CGPoint(x: v.bounds.midX, y: v.pictureFrame.maxY + 28) }
        func grip(_ v: SimulatorView) -> CGPoint {
            let g = v.subviews.first { $0 is ChipImage }!.frame
            return CGPoint(x: g.midX, y: g.midY)
        }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            waited += 0.5
            guard first.framesShown > 0 || waited > 90 else { return }
            timer.invalidate()
            wb.openBeside(apk: apk, device: "phone")
            wb.openBeside(apk: apk, device: "tablet")
            after(10) {
                grid.layoutSubtreeIfNeeded()
                let views = grid.views
                check(views.count == 3, "three devices side by side (\(views.count))")
                print("[greenroom] arrange: tiled " + views.map { r($0.frame) }.joined(separator: " | "))
                check(!grid.isArranged, "tiled before anything is moved")
                self.captureWindow(to: dir.appendingPathComponent("1-tiled.png"))
                guard views.count == 3 else { NSApp.terminate(nil); return }
                let (a, b, c) = (views[0], views[1], views[2])

                // Move: the picture follows the pointer; the rest stay where their pictures were.
                let bPicture = b.convert(b.pictureFrame, to: grid)
                let before = a.frame
                drag(a, from: body(a), by: CGSize(width: 120, height: 60))
                check(grid.isArranged, "arranged once a device is moved")
                check(abs(a.frame.minY - before.minY) > 1 || abs(a.frame.minX - before.minX) > 1, "moved: \(r(before)) -> \(r(a.frame))")
                let bAfter = b.convert(b.pictureFrame, to: grid)
                check(abs(bAfter.minX - bPicture.minX) <= 1.5 && abs(bAfter.minY - bPicture.minY) <= 1.5 && abs(bAfter.width - bPicture.width) <= 2,
                      "the others' pictures stay put: \(r(bPicture)) -> \(r(bAfter))")
                check(grid.bounds.contains(a.frame), "the moved device stays on the stage")

                // Shrink far past the minimum: it stops there, its shape kept.
                drag(b, from: grip(b), by: CGSize(width: -3000, height: -3000))
                check(abs(b.pictureLongSide - b.minimumLongSide) <= 2, "shrunk to the minimum: long side \(Int(b.pictureLongSide)), minimum \(Int(b.minimumLongSide))")
                let s = b.simulator?.deviceSize ?? .zero
                let shape = b.pictureFrame.width / b.pictureFrame.height, want = s.width / max(s.height, 1)
                check(abs(shape - want) < 0.02, String(format: "shape kept: %.3f against the device's %.3f", shape, want))
                // Grow far past the stage: it stops at the stage's edge.
                drag(b, from: grip(b), by: CGSize(width: 4000, height: 4000))
                check(grid.bounds.insetBy(dx: -1, dy: -1).contains(b.frame), "grown to the stage's edge: \(r(b.frame)) in \(r(grid.bounds))")
                drag(b, from: grip(b), by: CGSize(width: -260, height: -260))
                self.captureWindow(to: dir.appendingPathComponent("2-arranged.png"))

                // Snap: dropped a few points off the tablet's left edge, the phone lines up with it.
                drag(c, from: body(c), by: CGSize(width: -3000, height: -3000))
                check(c.frame.minX == 0 && c.frame.minY == 0, "pushed into the corner stops at it: \(r(c.frame))")
                let target = CGPoint(x: c.frame.maxX + 6, y: 40)
                drag(a, from: body(a), by: CGSize(width: target.x - a.frame.minX, height: target.y - a.frame.minY))
                check(a.frame.minX == c.frame.maxX, "snapped beside the other device: \(Int(a.frame.minX)) against \(Int(c.frame.maxX))")

                // A click on a device behind another brings it to the front.
                let behind = grid.subviews.firstIndex(of: b)! < grid.subviews.firstIndex(of: c)!
                drag(b, from: CGPoint(x: b.pictureFrame.midX, y: b.pictureFrame.midY), by: .zero)
                check(grid.subviews.firstIndex(of: b)! > grid.subviews.firstIndex(of: c)!, "a click brings a device to the front (it was \(behind ? "behind" : "in front"))")

                // A device opened now gets a free spot rather than the tiles.
                wb.openBeside(apk: apk, device: "phone")
                after(4) {
                    grid.layoutSubtreeIfNeeded()
                    let fresh = grid.views.last!
                    let overlaps = grid.views.dropLast().filter { $0.frame.insetBy(dx: 8, dy: 8).intersects(fresh.frame) }.count
                    check(grid.views.count == 4 && grid.isArranged, "a fourth device joins the arrangement")
                    print("[greenroom] arrange: the fourth at \(r(fresh.frame)), overlapping \(overlaps)")
                    // The memory label.
                    after(4) {
                        check(!grid.memoryLabel.isHidden, "memory label shown: \"\(grid.memoryLabel.stringValue)\" (\(grid.memoryLabel.toolTip ?? "")) at \(r(grid.memoryLabel.frame))")
                        check(grid.views.filter(\.hovering).count <= 1, "at most one device shows its close button and grip (\(grid.views.filter(\.hovering).count))")
                        self.captureWindow(to: dir.appendingPathComponent("3-fourth.png"))
                        // Close with the button on its corner.
                        let closing = fresh.simulator
                        (fresh.subviews.first { $0 is NSButton } as? NSButton)?.performClick(nil)
                        after(1.5) {
                            check(!Engine.shared.simulators.contains { $0 === closing }, "closed with its button")
                            check(grid.views.count == 3 && grid.isArranged, "the rest keep their places (\(grid.views.count))")
                            wb.tidyUp(nil)
                            after(1) {
                                check(!grid.isArranged, "Tidy Up tiles them again: " + grid.views.map { r($0.frame) }.joined(separator: " | "))
                                self.captureWindow(to: dir.appendingPathComponent("4-tidy.png"))
                                print("[greenroom] arrange: \(failures == 0 ? "passed" : "\(failures) failed")")
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }
}
