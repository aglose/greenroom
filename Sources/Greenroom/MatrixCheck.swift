import AppKit

/// `Greenroom --matrix-check DIR APK`: a matrix wall of four phones (light and dark, English and German) on the APK;
/// one mirrored tap on the bottom bar's second tab must reach every cell; then the Shader tab, mirrored, animates
/// everywhere, and the frames each cell draws in 3 s are counted with the pointer on none and on the first.
/// Prints a line per step and captures the window into DIR.
extension AppDelegate {
    func matrixCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--matrix-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.window.setContentSize(NSSize(width: 1600, height: 1000))
        workbench.window.center()
        var m = Matrix()
        m.devices = ["phone"]; m.appearances = ["light", "dark"]; m.locales = ["en-US", "de-DE"]
        workbench.runMatrix(m, apk: URL(fileURLWithPath: args[i + 2])) { [self] sims in matrixCheck(dir: dir, sims: sims) }
    }

    private func matrixCheck(dir: URL, sims: [Simulator]) {
        print("[greenroom] matrix: \(sims.count) cells: " + sims.map { "\($0.cellLabel ?? "?") [\($0.options.joined(separator: " "))]" }.joined(separator: " | "))
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        func frames(_ done: @escaping ([Int]) -> Void) {
            var out = [Int](repeating: -1, count: sims.count), left = sims.count
            for (k, s) in sims.enumerated() {
                s.send("stats") { a in
                    out[k] = Int(a.split(separator: " ").first { $0.hasPrefix("frames=") }?.dropFirst(7) ?? "") ?? -1
                    left -= 1; if left == 0 { done(out) }
                }
            }
        }
        func rates(_ label: String, _ done: @escaping () -> Void) {
            frames { a in after(3) { frames { b in
                print("[greenroom] matrix: frames a second, \(label): " + zip(a, b).map { String(format: "%.0f", Double($1 - $0) / 3) }.joined(separator: ", "))
                done()
            } } }
        }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
            waited += 0.5
            guard sims.allSatisfy({ $0.framesShown > 0 }) || waited > 150 else { return }
            timer.invalidate()
            print("[greenroom] matrix: all cells showing after \(Int(waited)) s: \(sims.allSatisfy { $0.framesShown > 0 })")
            after(3) { [self] in
                // The bottom bar's second tab (Trips in the test app), as fractions of the screen: the same place on every cell.
                workbench.clickForCheck(CGPoint(x: 355.0 / 822, y: 1690.0 / 1782))
                after(3) { [self] in
                    var answers = [String](repeating: "", count: sims.count), left = sims.count
                    for (k, s) in sims.enumerated() {
                        s.send("nodes") { a in
                            answers[k] = a.contains("vacation") ? "on Trips" : "not on Trips"
                            left -= 1
                            guard left == 0 else { return }
                            print("[greenroom] matrix: after one mirrored tap: " + zip(sims, answers).map { "\($0.cellLabel ?? "?") \($1)" }.joined(separator: ", "))
                            self.captureWindow(to: dir.appendingPathComponent("1-trips.png"))
                            self.workbench.clickForCheck(CGPoint(x: 720.0 / 822, y: 1690.0 / 1782))
                            after(3) { [self] in
                                rates("pointer on none") {
                                    self.workbench.matrixHover(sims[0], inside: true)
                                    after(1) {
                                        rates("pointer on the first") {
                                            self.captureWindow(to: dir.appendingPathComponent("2-shader.png"))
                                            self.workbench.closeMatrix(nil)
                                            after(2) { print("[greenroom] matrix: closed, \(Engine.shared.simulators.filter(\.isAlive).count) running"); NSApp.terminate(nil) }
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
}
