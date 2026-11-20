import AppKit

extension AppDelegate {
    /// `Greenroom --map-check DIR APK`: opens the app, walks it two taps deep with light and dark captures, and checks
    /// the map: enough screens, the Trips screen among them, routes drawn, the arrow keys move the selection. Then
    /// "Go there" replays the route to Trips on the open device, which must then show a trip. The window is captured
    /// mid-walk (ghosts), with the map, with a screen selected and after going there. One `[greenroom] map:` line per step.
    func mapCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--map-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let apk = URL(fileURLWithPath: args[i + 2])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.window.setContentSize(NSSize(width: 1500, height: 960))
        workbench.window.center()
        guard let sim = workbench.open(apk, remember: false) else { print("[greenroom] map check: FAIL (no device)"); exit(1) }
        let map = workbench.screenMap
        var ok = true
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; print("[greenroom] map: \(good ? "ok  " : "FAIL") \(what)") }
        func end() {
            print("[greenroom] map check: \(ok ? "PASS" : "FAIL")")
            for k in ["mapAPK", "mapRun", "mapDepth", "mapTime", "mapCaptures"] { UserDefaults.standard.removeObject(forKey: k) }
            fflush(stdout)
            Engine.shared.stopAll()
            exit(ok ? 0 : 1)
        }
        workbench.showMap()
        map.setAPK(apk)
        map.configure(depth: 1, time: 1, captures: 1)
        let started = Date()
        guard map.walk() else { expect(false, "the walk starts (Python 3 found)"); end(); return }
        var shotWalking = false
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
            let t = Date().timeIntervalSince(started)
            if !shotWalking, t > 14 { shotWalking = true; captureWindow(to: dir.appendingPathComponent("1-walking.png")) }
            guard map.run == nil || t > 400 else { return }
            timer.invalidate()
            guard let data = map.data else { expect(false, "the walk finished with a map"); end(); return }
            let transitions = data.edges.filter { if case .screen = $0.to { return true } else { return false } }.count
            print(String(format: "[greenroom] map: %d screens, %d transitions, %d curves, %d crashes, %d combos, walked in %.0f s",
                         data.screens.count, transitions, map.canvas.routeCount, data.crashes.count, data.combos.count, t))
            expect(data.screens.count >= 5, "at least 5 screens")
            expect(map.canvas.routeCount >= 3, "routes drawn between screens")
            expect(data.screens.allSatisfy { $0.captures.count == 2 }, "every screen captured light and dark")
            let trips = data.screens.first { $0.texts.contains("Tokyo weekend") && $0.depth == 1 }
            expect(trips != nil, "the Trips screen was found one tap in")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                captureWindow(to: dir.appendingPathComponent("2-map.png"))
                guard let trips else { end(); return }
                map.canvas.select(trips.id)
                // Right from the start follows the first route out; left comes back.
                map.canvas.select(data.screens.first?.id)
                map.canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                          characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!)
                let right = map.canvas.selected
                expect(right != nil && right != data.screens.first?.id, "the right arrow moves to a screen one tap in")
                map.canvas.select(trips.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    captureWindow(to: dir.appendingPathComponent("3-selected.png"))
                    workbench.goThere(trips, data) { arrived in
                        expect(arrived, "Go there replayed \(trips.steps.joined(separator: ", "))")
                        DispatchQueue.global().async {
                            let nodes = sim.sendSync("nodes")
                            DispatchQueue.main.async { [self] in
                                expect(nodes.contains("Tokyo weekend"), "the device shows the Trips screen afterwards")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                                    captureWindow(to: dir.appendingPathComponent("4-there.png"))
                                    end()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
