import AppKit

extension AppDelegate {
    /// `Greenroom --resize-check DIR [APK]`: sizes the workbench down to its minimum and back up, and prints one
    /// `[greenroom] resize:` line per size, `FAIL` where the window did not take the width asked for (something inside
    /// holding it wider, as the hidden map and changes sheets once did). Captures the window at each size.
    func resizeCheckIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--resize-check"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let wb = workbench!
        if i + 2 < args.count { wb.open(URL(fileURLWithPath: args[i + 2]), remember: false) }
        let min = wb.window.contentMinSize
        let sizes: [NSSize] = [NSSize(width: 1440, height: 900), NSSize(width: 1200, height: 800), NSSize(width: 1000, height: 700),
                               min, NSSize(width: 1100, height: 760), NSSize(width: 1600, height: 900)]
        var k = 0, failures = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            guard k < sizes.count else {
                t.invalidate()
                print("[greenroom] resize: \(failures == 0 ? "PASS" : "FAIL \(failures)")")
                NSApp.terminate(nil)
                return
            }
            let s = sizes[k]; k += 1
            let w = wb.window
            var f = w.frameRect(forContentRect: NSRect(origin: .zero, size: s))
            f.origin = w.frame.origin
            w.setFrame(f, display: true)
            w.contentView!.layoutSubtreeIfNeeded()
            let got = w.contentLayoutRect.size
            let ok = abs(got.width - s.width) < 1
            if !ok { failures += 1 }
            print("[greenroom] resize: \(ok ? "ok" : "FAIL") asked \(Int(s.width))x\(Int(s.height)) got \(Int(got.width))x\(Int(w.contentView!.frame.height))")
            self.captureWindow(to: dir.appendingPathComponent("\(k)-\(Int(s.width))x\(Int(s.height)).png"))
        }
    }
}
