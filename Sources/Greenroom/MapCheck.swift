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
            guard !map.isWalking || t > 400 else { return }
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

extension AppDelegate {
    /// `Greenroom --map-signin-check DIR APK`: a walk that signs in with a script first. The script opens the test app's
    /// apksim://slot screen and taps Write (a Settings value that outlives the process, as a sign-in's token does); the
    /// walk, started at that screen, must then find "setting=written" from app start on, which a walk with no sign-in
    /// does not. The walk's throwaway slot must be gone afterwards, and a failing script must stop the walk with its
    /// reason. One `[greenroom] map-signin:` line per step.
    func mapSignInCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--map-signin-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let apk = URL(fileURLWithPath: args[i + 2])
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let map = workbench.screenMap
        var ok = true
        func say(_ s: String) { print("[greenroom] map-signin: \(s)"); fflush(stdout) }
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; say("\(good ? "ok  " : "FAIL") \(what)") }
        func script(_ name: String, _ body: String) -> URL {
            let u = dir.appendingPathComponent(name)
            try? fm.removeItem(at: u)
            fm.createFile(atPath: u.path, contents: Data(("#!/bin/bash\nset -euo pipefail\n" + body).utf8), attributes: [.posixPermissions: 0o700])
            return u
        }
        let good = script("sign-in.sh", """
            gr open "apksim://slot"
            gr wait "Slot state" 30
            gr tap-text "Write"
            gr wait "setting=written" 20
            echo "signed in"
            """)
        let bad = script("bad-sign-in.sh", "echo \"no such account\"\nexit 3\n")
        let data = Engine.shared.engineState.appendingPathComponent("cache/data", isDirectory: true)
        func walkSlots() -> [String] {
            ((try? fm.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)) ?? []).flatMap { pkg in
                ((try? fm.contentsOfDirectory(atPath: pkg.path)) ?? []).filter { $0.hasPrefix("evg") }
            }
        }
        let before = Set(walkSlots())
        func end() {
            say(ok ? "PASS" : "FAIL")
            for k in ["mapAPK", "mapRun", "mapDepth", "mapTime", "mapCaptures", "mapStart", "mapSignIn"] { UserDefaults.standard.removeObject(forKey: k) }
            Engine.shared.stopAll()
            exit(ok ? 0 : 1)
        }
        func walk(_ script: URL?, then: @escaping (ScreenMapData?, Double) -> Void) {
            map.chooseSignIn(script)
            let started = Date()
            guard map.walk() else { expect(false, "the walk starts (Python 3 found)"); end(); return }
            var sawSignIn = false
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { timer in
                if map.statusText.hasPrefix("Signing in") { sawSignIn = true }
                let t = Date().timeIntervalSince(started)
                guard !map.isWalking || t > 500 else { return }
                timer.invalidate()
                if script != nil { expect(sawSignIn, "the status said it was signing in") }
                then(map.data, t)
            }
        }
        workbench.showMap()
        map.setAPK(apk)
        map.configure(depth: 0, time: 0, captures: 2, start: "apksim://slot")
        walk(good) { d, t in
            let first = d?.screens.first
            say(String(format: "signed-in walk: %d screens in %.0f s; first screen: %@", d?.screens.count ?? 0, t, first?.texts.joined(separator: " | ") ?? "none"))
            expect(d != nil, "the signed-in walk finished with a map")
            expect(first?.texts.contains { $0.contains("at app start: setting=written") } == true, "the walk saw what the script did, from app start on")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                expect(Set(walkSlots()).subtracting(before).isEmpty, "the walk's slot is removed afterwards")
                walk(nil) { d, _ in
                    expect(d?.screens.first?.texts.contains { $0.contains("setting=written") } == false, "a walk with no sign-in does not see it")
                    walk(bad) { d, _ in
                        say("failed sign-in: \(map.statusText)")
                        expect(d == nil, "a failing script gives no map")
                        expect(map.statusText.contains("bad-sign-in.sh failed (exit 3): no such account"), "... and says which script failed and why")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            expect(Set(walkSlots()).subtracting(before).isEmpty, "... and its slot is removed")
                            end()
                        }
                    }
                }
            }
        }
    }
}
