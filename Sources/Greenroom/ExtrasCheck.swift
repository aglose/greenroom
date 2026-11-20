import AppKit

extension AppDelegate {
    /// `Greenroom --extras-check DIR APK`: opens the app with the Diagnostics pane, waits for live numbers, audits the
    /// screen, lists background work, sets and reads the clipboard, and captures the window with the pane open and
    /// with the audit's boxes drawn. Prints one `[greenroom] extras:` line per step.
    func extrasCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--extras-check"), i + 2 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.window.setContentSize(NSSize(width: 1500, height: 1000))
        workbench.window.center()
        guard let sim = workbench.open(URL(fileURLWithPath: args[i + 2]), remember: false, options: ["--appearance", "dark"]) else { return }
        let pane = workbench.diagnostics
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] timer in
            waited += 0.5
            guard sim.framesShown > 0 || waited > 90 else { return }
            timer.invalidate()
            sim.send("tap 720 1690")   // the Shader tab animates, so there is a frame rate to read
            workbench.setShowingDiagnostics(true)
            pane.setShowOnDevices(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [self] in
                let m = pane.latest
                print("[greenroom] extras: samples \(pane.sampleCount), fps \(m?.fps.map { String(format: "%.1f", $0) } ?? "-"), p50 \(m?.p50 ?? -1) ms, p95 \(m?.p95 ?? -1) ms, heap \(m?.heap ?? -1) MB, footprint \(m?.footprint ?? -1) MB, cpu \(m?.cpuMs ?? -1) ms, pace \(m?.pace ?? "-")")
                captureWindow(to: dir.appendingPathComponent("1-pane.png"))
                sim.send("open apksim://composeapp/settings")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
                    pane.audit()
                    pane.refreshAll()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                        print("[greenroom] extras: audit \(pane.findings.count) findings: " + pane.findings.map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)) \($0.text)" }.joined(separator: " | "))
                        let c = pane.backgroundCounts
                        print("[greenroom] extras: background jobs \(c.jobs), services \(c.services), alarms \(c.alarms)")
                        pane.flash(0)
                        pane.setClipboardForCheck("hello from greenroom")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                            print("[greenroom] extras: clipboard \"\(pane.clipboardShown)\"")
                            captureWindow(to: dir.appendingPathComponent("2-audit.png"))
                            // The app's own CPU, 10 s with the pane open (sampling) and 10 s with it closed.
                            func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
                            let a = cpu()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
                                let b = cpu()
                                workbench.setShowingDiagnostics(false)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                                    let c = cpu()
                                    print(String(format: "[greenroom] extras: app CPU, pane open %.1f%% of a core, closed %.1f%% (sampling stopped: %@)", (b - a) * 10, (c - b) * 10, pane.isSampling ? "no" : "yes"))
                                    NSApp.terminate(nil)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
