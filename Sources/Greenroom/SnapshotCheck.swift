import AppKit

/// `Greenroom --snapshots-check DIR APK SPEC.json`: the screenshot tests end to end. The spec's folder is copied to a
/// temporary one and the spec cut to 2 screens in 2 appearances. Goldens are recorded, a run is made against them
/// (all same), one golden image is edited and a run is made (one different), that is accepted, and a last run is made
/// (all same). One `[greenroom] snapshots: ...` line per run; the window is captured with the grid and with the
/// golden, actual and difference of the changed tile, side by side and wiped.
enum SnapshotCheck {
    static func runIfAsked(_ workbench: Workbench) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshots-check"), i + 3 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let apk = URL(fileURLWithPath: args[i + 2])
        let sourceSpec = URL(fileURLWithPath: args[i + 3])
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        workbench.window.setContentSize(NSSize(width: 1440, height: 900))
        workbench.window.center()

        // A copy of the spec's folder, the spec cut down.
        let work = fm.temporaryDirectory.appendingPathComponent("greenroom-snapshots-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: work)
        do {
            try fm.copyItem(at: sourceSpec.deletingLastPathComponent(), to: work)
            let spec = work.appendingPathComponent(sourceSpec.lastPathComponent)
            var json = (try JSONSerialization.jsonObject(with: Data(contentsOf: spec)) as? [String: Any]) ?? [:]
            json["screens"] = Array(((json["screens"] as? [Any]) ?? []).prefix(2))
            json["matrix"] = ["device": ["phone"], "appearance": ["light", "dark"]]
            json.removeValue(forKey: "exclude")
            json["goldens"] = "check-goldens"
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: spec)
            try? fm.removeItem(at: work.appendingPathComponent("goldens"))
            let review = workbench.snapshotReview
            review.setSpec(spec)
            review.setAPK(apk)
            review.open(loadLast: false)
            go(review, work: work, dir: dir)
        } catch {
            print("[greenroom] snapshots check failed to set up: \(error.localizedDescription)")
            finish(false, work)
        }
    }

    private static func finish(_ ok: Bool, _ work: URL) {
        for k in ["snapshotSpec", "snapshotAPK", "snapshotGoldens", "snapshotRun"] { UserDefaults.standard.removeObject(forKey: k) }
        try? FileManager.default.removeItem(at: work)
        print("[greenroom] snapshots check: \(ok ? "PASS" : "FAIL")")
        Engine.shared.stopAll()
        fflush(stdout)
        exit(ok ? 0 : 1)
    }

    private static func go(_ review: SnapshotReview, work: URL, dir: URL) {
        var ok = true
        func expect(_ label: String, _ outcome: SnapshotRun.Outcome, _ want: [SnapshotResult.Kind: Int]) {
            switch outcome {
            case .finished(let code, let list):
                let got = SnapshotReview.counts(list)
                let good = got == want
                if !good { ok = false }
                print("[greenroom] snapshots: \(label): \(SnapshotReview.summary(list)), script exit \(code), \(good ? "as expected" : "UNEXPECTED")")
            case .failed(let why): ok = false; print("[greenroom] snapshots: \(label): failed: \(why)")
            case .cancelled: ok = false; print("[greenroom] snapshots: \(label): cancelled")
            }
        }
        func after(_ t: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
        review.start(.record) { o in
            expect("record goldens", o, [.recorded: 4])
            after(0.6) { capture(review, dir.appendingPathComponent("1-recorded.png")) }
            after(1) {
                review.start(.compare) { o in
                    expect("run 1, nothing changed", o, [.same: 4])
                    // Edit one golden: a magenta box over its top left.
                    let golden = (FileManager.default.enumerator(at: work.appendingPathComponent("check-goldens"), includingPropertiesForKeys: nil)?
                        .compactMap { $0 as? URL }.filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }.first)
                    guard let golden, let rep = NSBitmapImageRep(data: (try? Data(contentsOf: golden)) ?? Data()) else { print("[greenroom] snapshots: no golden to edit"); finish(false, work); return }
                    if let image = rep.cgImage, let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.1, blue: 0.7, alpha: 1))
                        ctx.fill(CGRect(x: 40, y: image.height - 400, width: image.width / 2, height: 220))
                        if let edited = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: edited).representation(using: .png, properties: [:]) { try? png.write(to: golden) }
                    }
                    print("[greenroom] snapshots: edited golden \(golden.deletingLastPathComponent().lastPathComponent)/\(golden.lastPathComponent)")
                    review.start(.compare) { o in
                        expect("run 2, one golden edited", o, [.same: 3, .different: 1])
                        _ = review.selectFirst(.different)
                        after(1.0) {
                            capture(review, dir.appendingPathComponent("2-different-side-by-side.png"))
                            review.setMode(wipe: true)
                            review.setWipe(0.45)
                            after(0.8) {
                                capture(review, dir.appendingPathComponent("3-different-wipe.png"))
                                review.setMode(wipe: false)
                                let n = review.acceptSelectedForCheck()
                                print("[greenroom] snapshots: accepted \(n)")
                                if n != 1 { ok = false }
                                review.start(.compare) { o in
                                    expect("run 3, after accepting", o, [.same: 4])
                                    after(0.6) {
                                        capture(review, dir.appendingPathComponent("4-accepted.png"))
                                        finish(ok, work)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The window as it is on screen (see AppDelegate.captureWindow), or AppKit's drawing of it when the screen is locked.
    private static func capture(_ review: SnapshotReview, _ file: URL) {
        guard let window = review.window else { return }
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        if !locked, let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
           let image = unsafeBitCast(sym, to: Capture.self)(.null, 8, UInt32(window.windowNumber), 9)?.takeRetainedValue() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
        } else if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
            print("[greenroom] the screen is locked: \(file.lastPathComponent) is AppKit's drawing, without the glass")
        }
    }
}
