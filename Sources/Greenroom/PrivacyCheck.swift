import AppKit

/// `Greenroom --privacy-check SECONDS APK` (scripts/network-check.sh): the whole app at work for a while, so the check
/// around it sees every connection the app and its engine might make by themselves. Opens the APK in the workbench,
/// shows each pane in turn, drives the app a little, stays idle for the
/// rest of SECONDS and quits as the menu would. Prints one line per step; makes no judgement itself.
enum PrivacyCheck {
    static func runIfAsked(_ delegate: AppDelegate) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--privacy-check"), i + 2 < args.count,
              let seconds = Double(args[i + 1]) else { return }
        let workbench = delegate.workbench!
        guard let sim = workbench.open(URL(fileURLWithPath: args[i + 2]), remember: false) else {
            print("[greenroom] privacy-check: the APK did not open"); exit(2)
        }
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        let started = Date()
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            waited += 0.5
            guard sim.framesShown > 0 || waited > 120 else { return }
            timer.invalidate()
            print("[greenroom] privacy-check: first frame \(sim.framesShown > 0 ? "shown" : "not shown") after \(Int(waited)) s")
            let steps: [(String, () -> Void)] = [
                ("network pane", { workbench.setShowingNetwork(true) }),
                ("device pane", { workbench.setShowingDevice(true) }),
                ("diagnostics pane", { workbench.setShowingDiagnostics(true) }),
                ("recordings pane", { workbench.setShowingRecordings(true) }),
                ("tests pane", { workbench.setShowingTests(true) }),
                ("timeline", { workbench.setShowingTimeline(true) }),
                ("log", { workbench.setShowingLog(true) }),
                ("palette", { workbench.showPalette(nil) }),
                ("input", { sim.send("tap 300 1690"); sim.send("tap 130 1690") }),
                ("activity", { sim.send("activity") }),
            ]
            var t = 0.0
            for (name, step) in steps {
                t += 1.5
                after(t) { step(); print("[greenroom] privacy-check: \(name)") }
            }
            let rest = max(2, seconds - Date().timeIntervalSince(started) - t)
            after(t + rest) {
                print("[greenroom] privacy-check: idle until \(Int(Date().timeIntervalSince(started))) s, quitting")
                NSApp.terminate(nil)
            }
        }
    }
}
