import AppKit

extension AppDelegate {
    /// `Greenroom --replay-check DIR APK [OTHER.apk]`: opens the APK, records a short session, saves it, shows the
    /// recordings pane, replays it on the same APK (expect same) and, given OTHER, searches [APK, OTHER] for the
    /// first build that differs. One `[greenroom] replay:` line per result; window captures in DIR.
    func replayCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--replay-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let apk = URL(fileURLWithPath: args[i + 2])
        let other = i + 3 < args.count && !args[i + 3].hasPrefix("--") ? URL(fileURLWithPath: args[i + 3]) : nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.window.setContentSize(NSSize(width: 1500, height: 940))
        workbench.window.center()
        Self.bisectSelfTest()
        guard let sim = workbench.open(apk, remember: false) else { print("[greenroom] replay: could not open \(apk.lastPathComponent)"); NSApp.terminate(nil); return }
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func shot(_ name: String) { captureWindow(to: dir.appendingPathComponent(name)) }
        func finish() { print("[greenroom] replay: check done"); NSApp.terminate(nil) }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [self] timer in
            waited += 0.25
            guard (sim.state == .running && sim.framesShown > 0) || waited > 120 else { return }
            timer.invalidate()
            workbench.toggleRecording(nil)
            // A short session: three taps a second apart.
            for (k, p) in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.89, y: 0.86), CGPoint(x: 0.89, y: 0.86)].enumerated() {
                after(4 + Double(k)) { [self] in workbench.debugClick(atFraction: p) }
            }
            after(9) { [self] in
                workbench.saveRecording { [self] file, answer in
                    guard let file else { print("[greenroom] replay: recording not saved: \(answer.prefix(120))"); finish(); return }
                    print("[greenroom] replay: saved \(file.lastPathComponent)")
                    workbench.setShowingRecordings(true)
                    let pane = workbench.recordingsView
                    after(2.5) {
                        shot("p1-list.png")
                        guard let rec = pane.recordings.first(where: { $0.url == file }) else {
                            print("[greenroom] replay: the pane does not list \(file.lastPathComponent) (\(pane.recordings.count) listed)"); finish(); return
                        }
                        pane.debugSelect(file)
                        print("[greenroom] replay: listed \(pane.recordings.count): \(rec.name), \(rec.meta), package \(rec.package ?? "?"), build \(rec.apkName ?? "?")")
                        pane.replay(rec, apk: apk) { outcome in
                            print("[greenroom] replay: same build -> \(outcome.word): \(outcome.detail)")
                            guard let other else { after(0.6) { shot("p3-replayed.png"); finish() }; return }
                            after(0.6) { shot("p3-replayed.png") }
                            pane.bisect(rec, builds: [apk, other]) { conclusion in
                                print("[greenroom] replay: bisect [\(apk.lastPathComponent), \(other.lastPathComponent)] -> \(pane.resultSummary) | \(String(describing: conclusion))")
                                after(1.0) {
                                    shot("p4-bisect.png")
                                    print("[greenroom] replay: frames shown \(pane.framesShown)")
                                    finish()
                                }
                            }
                            after(0.5) { shot("p4-bisect-running.png") }
                        }
                        after(4) { shot("p2-running.png") }
                    }
                }
            }
        }
    }

    /// The search's choices on a scripted list of builds, no engine: six builds, the third cannot be replayed, the
    /// fifth is the first to differ.
    static func bisectSelfTest() {
        func run(_ n: Int, bad: Int, skip: Set<Int>) -> (Bisect.Conclusion?, [Int]) {
            var b = Bisect(count: n)
            var tried: [Int] = []
            while let k = b.next {
                tried.append(k)
                b.record(k, skip.contains(k) ? .skip : (k >= bad ? .bad : .good))
            }
            return (b.conclusion, tried)
        }
        let a = run(6, bad: 4, skip: [2]), c = run(3, bad: 9, skip: []), d = run(5, bad: 2, skip: [3])
        let ok = a.0 == .firstDifferent(index: 4, lastGood: 3, skippedBetween: []) && c.0 == .noneDiffers
            && d.0 == .firstDifferent(index: 2, lastGood: 1, skippedBetween: [])
        print("[greenroom] replay: bisect logic \(ok ? "ok" : "WRONG"): 6 builds, first different 4 -> \(a.0.map { "\($0)" } ?? "nil") tried \(a.1); none differ -> tried \(c.1); first different 2 -> tried \(d.1)")
    }
}
