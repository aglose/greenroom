import AppKit

/// `Greenroom --perf-check DIR APK`: what the app itself costs. Time from opening an APK to its first picture; the
/// app's own CPU (not the engine's) idle with one device running, with each pane open in turn, and after closing them
/// all (nothing may keep polling); its memory footprint at each step.
enum PerfCheck {
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func runIfAsked(_ app: AppDelegate) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--perf-check"), i + 2 < args.count else { return }
        let wb = app.workbench!
        wb.window.setContentSize(NSSize(width: 1440, height: 900))
        print(String(format: "[greenroom] perf: window up, app footprint %.0f MB", footprintMB()))
        let opened = Date()
        guard let sim = wb.open(URL(fileURLWithPath: args[i + 2]), remember: false) else { return }
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        /// The app's CPU over `seconds`, as a percent of one core.
        func measure(_ label: String, _ seconds: Double, then: @escaping () -> Void) {
            let c0 = cpuSeconds(), t0 = Date()
            after(seconds) {
                let pct = (cpuSeconds() - c0) / Date().timeIntervalSince(t0) * 100
                print(String(format: "[greenroom] perf: %@: app CPU %.1f%% of a core, footprint %.0f MB", label, pct, footprintMB()))
                then()
            }
        }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            waited += 0.05
            guard sim.framesShown > 0 || waited > 120 else { return }
            timer.invalidate()
            print(String(format: "[greenroom] perf: APK to first picture %.2f s", Date().timeIntervalSince(opened)))
            // The app's own screen is still; the engine idles. Then each pane, one at a time.
            after(4) {
                let panes: [(String, () -> Void)] = [
                    ("device pane", { wb.setShowingDevice(true) }),
                    ("network pane", { wb.setShowingNetwork(true) }),
                    ("diagnostics pane", { wb.setShowingDiagnostics(true) }),
                    ("tests pane", { wb.setShowingTests(true) }),
                    ("recordings pane", { wb.setShowingRecordings(true) }),
                    ("timeline", { wb.show(nil, closing: wb.rightPane); wb.setShowingTimeline(true) }),
                    ("timeline, not redrawing", { wb.timelineDock.setShown(false) }),
                    ("log", { wb.setShowingTimeline(false); wb.setShowingLog(true) }),
                ]
                func step(_ k: Int) {
                    guard k < panes.count else {
                        wb.setShowingLog(false)
                        wb.show(nil, closing: wb.rightPane)
                        after(1.5) {
                            measure("idle again, every pane closed", 10) { NSApp.terminate(nil) }
                        }
                        return
                    }
                    panes[k].1()
                    after(1.5) { measure(panes[k].0 + " open", 6) { step(k + 1) } }
                }
                measure("idle, one device, no panes", 10) { step(0) }
            }
        }
    }
}
