import AppKit

extension AppDelegate {
    /// `Greenroom --map-check DIR APK`: opens the app, walks it two taps deep with light and dark captures, and checks
    /// the map: enough screens, the Trips screen among them, routes drawn, the arrow keys move the selection. Then
    /// "Go there" replays the route to Trips on the open device, which must then show a trip. The window is captured
    /// mid-walk (ghosts), with the map, with a screen selected and after going there. Then the app is walked again from
    /// its slot screen with a stand-in history (the first walk imported as the baseline of an invented commit, since the
    /// test app has no repository) and the window is captured with the comparison: the header, the changes first, the
    /// strip over two stored snapshots. One `[greenroom] map:` line per step.
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
            for k in ["mapAPK", "mapRun", "mapWalkDepth", "mapWalkTime", "mapCaptures", "mapStart", "mapSignIn"] { UserDefaults.standard.removeObject(forKey: k) }
            fflush(stdout)
            Engine.shared.stopAll()
            exit(ok ? 0 : 1)
        }
        workbench.showMap()
        map.setAPK(apk)
        map.configure(depth: 1, time: 1, captures: 1, start: "")   // a start link kept from an earlier run would change what is walked
        map.chooseSignIn(nil)   // nor would a sign-in left chosen
        // With no map yet, the sheet opens on the onboarding card: the app chosen, and Walk ready.
        if map.data == nil {
            expect(!map.onboarding.isHidden && map.onboarding.state.app == apk.lastPathComponent && map.onboarding.walkEnabled, "before a walk the sheet shows the onboarding card, ready to walk \(apk.lastPathComponent)")
        }
        // The card is captured once the sheet has arrived, then the walk starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
        if !map.onboarding.isHidden { captureWindow(to: dir.appendingPathComponent("0-onboarding.png")) }
        let started = Date()
        guard map.walk() else { expect(false, "the walk starts (Python 3 found)"); end(); return }
        var shotWalking = false
        /// A second walk from the slot screen, compared with the first as if the first were the baseline commit's.
        func diffWalk(first: ScreenMapData) {
            let fm = FileManager.default
            let root = dir.appendingPathComponent("history", isDirectory: true)
            try? fm.removeItem(at: root)
            let store = MapStore(root: root, repo: "map-check")
            map.context = { _ in
                MapContext(store: store, commit: "2222222222222222222222222222222222222222", tree: "tree2", engine: "check") { profile in
                    guard let b = store.importWalk(first.folder, commit: "1111111111111111111111111111111111111111", tree: "tree1", profile: profile, engine: "check", walked: Date().addingTimeInterval(-3600)) else { return nil }
                    let (paired, _) = MapPairing.pair(head: b, base: nil)
                    store.save(paired)
                    return (paired, 2)
                }
            }
            map.configure(depth: 1, time: 1, captures: 1, start: "apksim://slot")
            workbench.showMap()   // "Go there" closed the sheet
            map.chooseSignIn(nil)   // opening re-picks a kept sign-in this Mac may have for the app
            guard map.walk() else { expect(false, "the second walk starts"); end(); return }
            let again = Date()
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
                let t = Date().timeIntervalSince(again)
                guard (!map.isWalking && (map.snapshot != nil || map.data == nil) && !map.host.navigator.busy) || t > 400 else { return }
                timer.invalidate()
                guard let src = map.host.source, map.data != nil else { expect(false, "the second walk finished with a map (\(map.statusText))"); end(); return }
                expect(src.base?.commit.hasPrefix("1111111") == true && src.diff != nil, "the second walk is compared with the stored baseline")
                expect(map.statusText != "" && src.head.commit.hasPrefix("2222222"), "and filed under its own commit")
                expect(store.snapshot(profile: src.head.profile.id, commit: "2222222222222222222222222222222222222222") != nil, "the walk is in the store")
                let c = src.diff?.counts
                expect((c?.differing ?? 0) > 0, "the comparison found changes (new \(c?.added ?? 0), changed \(c?.modified ?? 0), gone \(c?.removed ?? 0))")
                expect(map.compareText.contains("compared with 1111111") && map.compareText.contains("2 commits behind"), "the header says: \(map.compareText)")
                expect(map.host.navigator.model?.hasDiff == true && map.host.navigator.filter == .all, "the map opens with the comparison, changes first")
                // The strip over the two stored snapshots; moving a handle re-diffs and redraws in place.
                let strip = map.timelineControl
                expect(!strip.isHidden && strip.base?.hasPrefix("1111111") == true && strip.head?.hasPrefix("2222222") == true, "the strip shows the two stored snapshots, base and head at their ends")
                let moved = src.head.screens.compactMap { s in map.host.navigator.surface.frame(of: s.lineage).map { (s.lineage, $0) } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                    captureWindow(to: dir.appendingPathComponent("5-diff.png"))
                    // Export, with no panel: index.html and the data, with the comparison.
                    let out = dir.appendingPathComponent("export", isDirectory: true)
                    expect(map.canExportNow, "Export is enabled with a map and no walk running")
                    var exportDone = false
                    map.exportNow(to: out) { r in
                        defer { exportDone = true }
                        let fm = FileManager.default
                        let ok = (try? r.get()) != nil && fm.fileExists(atPath: out.appendingPathComponent("index.html").path) && fm.fileExists(atPath: out.appendingPathComponent(MapExport.dataName).path)
                        expect(ok, "Export writes index.html and \(MapExport.dataName) for the comparison")
                        expect(map.statusText.hasPrefix("Exported to"), "and the status line says so: \(map.statusText.suffix(40))")
                    }
                    strip.set(base: 1)
                    let wait = Date()
                    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
                        guard (!map.host.navigator.busy && exportDone && map.host.source?.base?.commit.hasPrefix("2222222") == true) || Date().timeIntervalSince(wait) > 20 else { return }
                        t.invalidate()
                        expect(map.host.source?.diff?.counts.differing == 0, "moving the base handle to the head re-diffs: nothing differs")
                        // The screens the base alone had are gone from the view, so a card that hung from one slides to the left; it keeps its row.
                        let kept = moved.filter { l, f in map.host.navigator.surface.frame(of: l).map { $0.minY == f.minY && $0.size == f.size } ?? false }.count
                        expect(!moved.isEmpty && kept == moved.count, "the card still there keeps its row and size when the pair changes (\(kept) of \(moved.count))")
                        end()
                    }
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
            let t = Date().timeIntervalSince(started)
            if !shotWalking, t > 14, map.isWalking {
                shotWalking = true
                captureWindow(to: dir.appendingPathComponent("1-walking.png"))
                expect(map.onboarding.isHidden, "the onboarding card goes while the walk runs")
                // Closed, the walk goes on and the top bar shows it; asking for a walk again joins it instead of starting another.
                let running = map.run
                map.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    let chip = workbench.walkChip
                    expect(map.isWalking && !chip.isHidden && (chip.progress?.text.isEmpty == false), "with the map closed the top bar shows the walk: \(chip.progress?.text ?? "nothing")")
                    captureWindow(to: dir.appendingPathComponent("1b-closed.png"))
                    workbench.showMap(walk: true)
                    expect(map.isOpen && map.run === running, "asking to walk again while one runs reopens it, not a new walk")
                }
            }
            guard (!map.isWalking && (map.snapshot != nil || map.data == nil) && !map.host.navigator.busy) || t > 400 else { return }
            timer.invalidate()
            expect(workbench.walkChip.isHidden, "the top bar's walk chip goes when the walk ends")
            guard let data = map.data else { expect(false, "the walk finished with a map"); end(); return }
            let transitions = data.edges.filter { if case .screen = $0.to { return true } else { return false } }.count
            print(String(format: "[greenroom] map: %d screens, %d transitions, %d curves, %d crashes, %d combos, walked in %.0f s",
                         data.screens.count, transitions, map.host.navigator.surface.routeCount, data.crashes.count, data.combos.count, t))
            expect(data.screens.count >= 5, "at least 5 screens")
            let surface = map.host.navigator.surface
            expect(map.snapshot?.screens.count == data.screens.count, "the walk is a snapshot of \(data.screens.count) screens (\(map.snapshot?.screens.count ?? 0))")
            expect(surface.routeCount >= 3, "routes drawn between screens")
            expect(!map.host.navigator.isHidden && map.host.ghosts.isHidden, "the map shows and the ghost cards are gone")
            expect(data.screens.allSatisfy { $0.captures.count == 2 }, "every screen captured light and dark")
            let trips = data.screens.first { $0.texts.contains("Tokyo weekend") && $0.depth == 1 }
            expect(trips != nil, "the Trips screen was found one tap in")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                captureWindow(to: dir.appendingPathComponent("2-map.png"))
                guard let trips else { end(); return }
                func lineage(_ id: String?) -> String? { id.flatMap { map.host.source?.lineage(ofHeadScreen: $0) } }
                guard let tripsLineage = lineage(trips.id) else { expect(false, "the Trips screen has a place on the map"); end(); return }
                map.host.select(tripsLineage)
                expect(map.host.detail.lineage == tripsLineage && !map.host.detail.isHidden, "selecting a screen fills the detail column")
                // Right from the start follows the first route out; left comes back.
                map.host.select(lineage(data.screens.first?.id))
                surface.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                       characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!)
                let right = surface.selected
                expect(right != nil && right != lineage(data.screens.first?.id), "the right arrow moves to a screen one tap in")
                map.host.select(tripsLineage)
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
                                    diffWalk(first: data)
                                }
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
            for k in ["mapAPK", "mapRun", "mapWalkDepth", "mapWalkTime", "mapCaptures", "mapStart", "mapSignIn"] { UserDefaults.standard.removeObject(forKey: k) }
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
