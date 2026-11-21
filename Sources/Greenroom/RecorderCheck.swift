import AppKit
import AVFoundation

/// `Greenroom --recorder-check DIR APK`: File > Record Screen (`ScreenRecording`, as the menu runs it) on the test app.
/// Ten seconds with taps, two chapter marks and a rotation, read back with AVFoundation: one H.264 track at the
/// stream's size, a duration within 0.3 s of the time recorded (counting the continuation file the rotation makes),
/// enough samples, a sync first sample, a mid-file frame that is not black, both chapters, no `.part` left. Then a
/// still screen for 5 s (still about 5 s); closing the simulator mid-recording (the file is finished and plays);
/// the engine quitting mid-recording (it ends there); a folder that cannot be written (ends with a message, no file);
/// the menu item's title; distinct names. One `[greenroom] recorder: ok|FAIL` line per step, then
/// `recorder check: PASS|FAIL`; exits 0 or 1. Files go to a store of DIR's own; no player window is opened.
enum RecorderCheck {
    static func run(workbench wb: Workbench, dir: URL, apk: URL) {
        Task { @MainActor in
            let fm = FileManager.default
            var failures = 0
            func say(_ s: String) { fputs("[greenroom] recorder: \(s)\n", stdout); fflush(stdout) }
            func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; say((ok ? "ok " : "FAIL ") + what) }
            @MainActor func wait(_ what: String, _ seconds: Double = 120, _ cond: @MainActor () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
                say("timed out waiting for \(what)")
                return false
            }
            func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
            func finish() -> Never {
                say(failures == 0 ? "done" : "stopped with \(failures) failure(s)")
                print("recorder check: " + (failures == 0 ? "PASS" : "FAIL"))
                fflush(stdout)
                Engine.shared.stopAll()
                exit(failures == 0 ? 0 : 1)
            }
            let out = dir.resolvingSymlinksInPath()
            try? fm.removeItem(at: out)
            try? fm.createDirectory(at: out, withIntermediateDirectories: true)
            // The check's own store: files land in out/state/recordings-video, nothing of the person's is touched.
            let store = SessionStore(root: out.appendingPathComponent("state", isDirectory: true))
            wb.sessions.use(store: store)
            let videos = store.root.appendingPathComponent("recordings-video", isDirectory: true)
            let screen = ScreenRecording.shared

            @MainActor func openSim() async -> Simulator? {
                guard let s = wb.open(apk, remember: false) else { say("FAIL could not open the APK"); failures += 1; return nil }
                guard await wait("the first frame", 120, { s.state == .running && s.framesShown > 0 }) else { failures += 1; return nil }
                await sleep(2)   // the app settles
                return s
            }
            /// The finished files in the recordings folder, the first file of a recording first.
            func mp4s() -> [URL] {
                let names = ((try? fm.contentsOfDirectory(atPath: videos.path)) ?? []).filter { $0.hasSuffix(".mp4") }
                return names.sorted { ($0.count, $0) < ($1.count, $1) }.map { videos.appendingPathComponent($0) }
            }
            func noPart() -> Bool { !((try? fm.contentsOfDirectory(atPath: videos.path)) ?? []).contains { $0.hasSuffix(".part") } }
            func clear() { try? fm.removeItem(at: videos) }
            func chapters(of file: URL) -> [Recorder.Chapter] {
                let url = file.deletingPathExtension().appendingPathExtension("chapters.json")
                return (try? JSONDecoder().decode([Recorder.Chapter].self, from: Data(contentsOf: url))) ?? []
            }
            func duration(_ f: URL) async -> Double { (try? await AVURLAsset(url: f).load(.duration).seconds) ?? 0 }
            /// File > Record Screen, as the menu does it; stopping waits for the toast's moment: the recorder is gone and the file is there.
            @MainActor func toggleAndSettle(_ sim: Simulator, expecting n: Int) async {
                wb.toggleScreenRecording(nil)
                if screen.recorder(for: sim) == nil {
                    _ = await wait("the files", 30) { screen.recorder(for: sim) == nil && noPart() && mp4s().count >= n }
                }
            }

            guard var sim = await openSim() else { finish() }

            // 0. The menu item reads "Stop" while recording; the file names of one second differ.
            let item = NSMenuItem(title: "Record Screen", action: nil, keyEquivalent: "")
            item.representedObject = "toggleScreenRecording:"
            let delegate = NSApp.delegate as? AppDelegate
            _ = delegate?.validateMenuItem(item)
            let idleTitle = item.title
            expect(screen.newFile(for: sim, in: wb) != screen.newFile(for: sim, in: wb), "two recordings started in one second get different names")

            // 1. Ten seconds with taps, two marks and a rotation, through File > Record Screen.
            let startSize = sim.deviceSize
            wb.toggleScreenRecording(nil)
            let t0 = Date()
            expect(Recorder.isRecording(sim), "recording started")
            _ = delegate?.validateMenuItem(item)
            expect(idleTitle == "Record Screen" && item.title == "Stop Recording Screen", "the menu item reads '\(item.title)' while recording")
            let xs = [180, 540, 900, 1260, 360, 720]
            for k in 0..<6 {
                await sleep(1.0)
                sim.send("tap \(xs[k]) 1690")
                if k == 1 { screen.recorder(for: sim)?.mark("second tab") }
                if k == 3 { screen.recorder(for: sim)?.mark("fourth tab") }
            }
            sim.send("rotate right")
            await sleep(3.5)
            let stopAt = Date()
            await toggleAndSettle(sim, expecting: 2)
            let recorded = stopAt.timeIntervalSince(t0)
            let files = mp4s()
            expect(files.count == 2 && !Recorder.isRecording(sim), "stopped with \(files.map(\.lastPathComponent))")
            expect(noPart(), "no .part file left")
            guard let first = files.first else { finish() }

            var total = 0.0
            for f in files { total += await duration(f) }
            expect(abs(total - recorded) <= 0.3, String(format: "duration %.2f s over %d file(s) against %.2f s recorded", total, files.count, recorded))
            let asset = AVURLAsset(url: first)
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let allTracks = (try? await asset.load(.tracks)) ?? []
            expect(tracks.count == 1 && allTracks.count == 1, "one video track")
            if let track = tracks.first {
                let descs = (try? await track.load(.formatDescriptions)) ?? []
                let codec = descs.first.map { CMFormatDescriptionGetMediaSubType($0) }
                let size = (try? await track.load(.naturalSize)) ?? .zero
                expect(codec == kCMVideoCodecType_H264, "the track is H.264")
                expect(size == startSize, "size \(Int(size.width))x\(Int(size.height)) is the stream's \(Int(startSize.width))x\(Int(startSize.height))")
                if let reader = try? AVAssetReader(asset: asset) {
                    let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                    reader.add(o)
                    reader.startReading()
                    var n = 0, firstSync = false
                    while let s = o.copyNextSampleBuffer() { if n == 0 { firstSync = Recorder.isSync(s) }; n += 1 }
                    expect(n > 20, "\(n) samples")
                    expect(firstSync, "the first sample is a sync sample")
                } else { expect(false, "could not read samples") }
                let gen = AVAssetImageGenerator(asset: asset)
                gen.requestedTimeToleranceBefore = .positiveInfinity
                gen.requestedTimeToleranceAfter = .positiveInfinity
                let mid = ((try? await asset.load(.duration).seconds) ?? 2) / 2
                if let image = try? await gen.image(at: CMTime(seconds: mid, preferredTimescale: 600)).image {
                    let bright = Self.meanBrightness(image)
                    expect(bright > 0.04, String(format: "a frame from %.1f s: %dx%d, mean brightness %.2f", mid, image.width, image.height, bright))
                } else { expect(false, "could not decode a frame from the middle") }
            }
            let marks = chapters(of: first)
            expect(marks.map(\.title) == ["second tab", "fourth tab"] && marks[0].t > 1 && marks[1].t > marks[0].t,
                   "chapters \(marks.map { "\($0.title)@\(String(format: "%.2f", $0.t))" })")
            await sleep(1.5)
            expect(mp4s().count == 2 && noPart(), "nothing is written after stop (\(mp4s().count) files)")

            // 2. A still screen for 5 s.
            clear()
            sim.send("rotate left")
            await sleep(1.5)
            sim.send("home")
            await sleep(2.5)   // nothing moves from here on
            wb.toggleScreenRecording(nil)
            let s0 = Date()
            await sleep(5)
            let s1 = Date()
            await toggleAndSettle(sim, expecting: 1)
            let sFiles = mp4s()
            let sSeconds = await duration(sFiles.first ?? first)
            expect(sFiles.count == 1 && abs(sSeconds - s1.timeIntervalSince(s0)) <= 0.3, String(format: "still screen: %.2f s against %.2f s recorded", sSeconds, s1.timeIntervalSince(s0)))
            expect(noPart(), "no .part file left after the still recording")

            // 3. Closing the simulator mid-recording finishes the file.
            clear()
            wb.toggleScreenRecording(nil)
            let c0 = Date()
            await sleep(3)
            wb.closeSelected(nil)
            let closed = Date().timeIntervalSince(c0)
            let cFiles = mp4s()
            expect(screen.recorder(for: sim) == nil && !Recorder.isRecording(sim), "the recorder ended with its simulator")
            expect(cFiles.count == 1 && noPart(), "closing finished the file at once (\(cFiles.count) file, no .part: \(noPart()))")
            if let f = cFiles.first {
                let d = await duration(f)
                let playable = (try? await AVURLAsset(url: f).load(.isPlayable)) ?? false
                expect(playable && abs(d - closed) <= 0.4, String(format: "it plays, %.2f s against %.2f s", d, closed))
            }

            // 4. The engine ending by itself: the recording stops there and holds the last picture only to that moment.
            clear()
            guard let sim2 = await openSim() else { finish() }
            sim = sim2
            var endedReason = ""
            wb.toggleScreenRecording(nil)
            screen.onEndedByItself = { _, _, why in endedReason = why }   // after the menu's own handler was set
            let e0 = Date()
            await sleep(2.5)
            sim.send("quit")
            _ = await wait("the simulator to end", 30) { !sim.isAlive }
            let endedAt = Date().timeIntervalSince(e0)
            _ = await wait("the recording to end", 15) { screen.recorder(for: sim) == nil && mp4s().count == 1 && noPart() }
            await sleep(4)   // a later stop must not pad the file
            let eFiles = mp4s()
            let eDur = await duration(eFiles.first ?? first)
            expect(!Recorder.isRecording(sim) && eFiles.count == 1 && noPart(), "the recording ended when the simulator did (\(endedReason.isEmpty ? "no message" : endedReason))")
            expect(eDur > 1.5 && eDur <= endedAt + 0.4, String(format: "its length %.2f s is up to the end at %.2f s, not up to the wait after it", eDur, endedAt))
            Engine.shared.close(sim)

            // 5. A file that cannot be written: the recording ends with a reason and leaves nothing under the final name.
            guard let sim3 = await openSim() else { finish() }
            sim = sim3
            let locked = out.appendingPathComponent("locked", isDirectory: true)
            try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            var failReason = ""
            screen.onEndedByItself = { _, _, why in failReason = why }
            _ = screen.start(sim, to: locked.appendingPathComponent("x.mp4"))
            let ended = await wait("the failed recording to end", 15) { screen.recorder(for: sim) == nil }
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            expect(ended && !Recorder.isRecording(sim) && !failReason.isEmpty && ((try? fm.contentsOfDirectory(atPath: locked.path)) ?? []).isEmpty,
                   "an unwritable folder ends the recording with a message ('\(failReason)') and leaves no file")
            finish()
        }
    }


    /// Mean of the red, green and blue channels, 0...1, over a small copy of the picture.
    static func meanBrightness(_ image: CGImage) -> Double {
        let w = 32, h = 32
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0
        for i in stride(from: 0, to: px.count, by: 4) { sum += Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) }
        return Double(sum) / Double(w * h * 3 * 255)
    }
}
