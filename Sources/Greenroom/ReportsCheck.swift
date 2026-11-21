import AppKit

/// Checks for the opt-in reports (scripts/reports-check.sh, which turns both kinds on for the run only, through the
/// argument domain, and points them at a local receiver):
/// - `Greenroom --reports-crash`: arms the crash handlers and crashes, so the next launch finds a crash of Greenroom's own;
/// - `Greenroom --reports-check APK`: opens the APK, uses a few features, ends an engine as a crash would, seals the
///   day's usage, prints every waiting report, checks each holds only the allowed fields and nothing naming the APK,
///   then sends them without the usual day's wait and prints how many left the outbox.
enum ReportsCheck {
    static let allowedKeys: Set<String> = ["kind", "day", "app", "build", "engine", "macos", "counts", "status", "signal", "frames"]

    static func runIfAsked() {
        let args = CommandLine.arguments
        if args.contains("--reports-crash") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                print("[greenroom] reports-check: crashing on purpose"); fflush(stdout)
                let p = UnsafeMutablePointer<Int>(bitPattern: 8)!
                p.pointee = 1
            }
            return
        }
        guard let i = args.firstIndex(of: "--reports-check"), i + 1 < args.count,
              let delegate = NSApp.delegate as? AppDelegate else { return }
        let apk = URL(fileURLWithPath: args[i + 1])
        let r = Reports.shared
        print("[greenroom] reports-check: crashes \(r.crashes), usage \(r.usage), endpoint \(r.endpoint?.absoluteString ?? "none")")
        let wb = delegate.workbench!
        guard let sim = wb.open(apk, remember: false) else { print("[greenroom] reports-check: the APK did not open"); exit(2) }
        var waited = 0.0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            waited += 0.5
            guard sim.framesShown > 0 || waited > 120 else { return }
            timer.invalidate()
            wb.setShowingNetwork(true); wb.setShowingDiagnostics(true); wb.showPalette(nil)
            r.engineEnded(status: 134)   // as a native crash of the engine would end it
            r.engineEnded(status: 10)    // the app's own crash: never reported
            r.saveUsage()
            r.sealUsage(before: "9999-12-31")
            var bad: [String] = []
            let names = [apk.lastPathComponent, apk.deletingPathExtension().lastPathComponent, apk.path, "composeapp", "dev.apksim.composeapp"]
            let waiting = r.waiting()
            for (file, text) in waiting {
                print("[greenroom] reports-check: \(file.lastPathComponent): " + text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: ""))
                guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { bad.append("unreadable"); continue }
                for k in json.keys where !allowedKeys.contains(k) { bad.append("field \(k)") }
                for k in (json["counts"] as? [String: Any] ?? [:]).keys where Reports.Feature(rawValue: k) == nil { bad.append("count \(k)") }
                for n in names where text.contains(n) { bad.append("names the APK (\(n))") }
            }
            let kinds = waiting.map { $0.1 }.map { t in ["crash", "engine-exit", "usage"].first { t.contains("\"kind\" : \"\($0)\"") } ?? "?" }
            print("[greenroom] reports-check: waiting \(kinds.sorted().joined(separator: ", ")); problems: \(bad.isEmpty ? "none" : bad.joined(separator: ", "))")
            r.send(holdSeconds: 0) {
                print("[greenroom] reports-check: after sending, \(r.waiting().count) left in the outbox")
                Engine.shared.stopAll()
                exit(bad.isEmpty ? 0 : 1)
            }
        }
    }
}
