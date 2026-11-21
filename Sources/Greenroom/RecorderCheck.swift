import AppKit
import AVFoundation

/// `Greenroom --recorder-check DIR APK`: records the test app for about 10 s while tapping between its bottom tabs
/// and rotating once, with two chapter marks, then opens the result with AVFoundation: one H.264 track at the
/// stream's size, a duration within 0.3 s of the time recorded (counting the continuation file the rotation makes),
/// enough samples, a first sample that is a sync sample, a mid-file frame that is not black, both chapters, no
/// `.part` file left. Then 5 s of a still screen, which must still last about 5 s. One `[greenroom] recorder: ok|FAIL`
/// line per step, then `recorder check: PASS|FAIL`; exits 0 or 1. No window of a player is opened.
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

            guard let sim = wb.open(apk, remember: false) else { say("FAIL could not open the APK"); failures += 1; finish() }
            guard await wait("the first frame", 120, { sim.state == .running && sim.framesShown > 0 }) else { failures += 1; finish() }
            await sleep(2)   // the app settles

            func stopped(_ r: Recorder) async -> [URL] {
                await withCheckedContinuation { c in r.stop { c.resume(returning: $0) } }
            }
            func chapters(of file: URL) -> [Recorder.Chapter] {
                let url = file.deletingPathExtension().appendingPathExtension("chapters.json")
                return (try? JSONDecoder().decode([Recorder.Chapter].self, from: Data(contentsOf: url))) ?? []
            }
            func noPart(_ folder: URL) -> Bool { !((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasSuffix(".part") } }

            // 1. Ten seconds with taps, two marks and a rotation.
            let startSize = sim.deviceSize
            let file = out.appendingPathComponent("tabs.mp4")
            let rec = Recorder(simulator: sim)
            expect(rec.start(to: file) && rec.isRecording, "recording started")
            let t0 = Date()
            let xs = [180, 540, 900, 1260, 360, 720]
            for k in 0..<6 {
                await sleep(1.0)
                sim.send("tap \(xs[k]) 1690")
                if k == 1 { rec.mark("second tab") }
                if k == 3 { rec.mark("fourth tab") }
            }
            sim.send("rotate right")
            await sleep(3.5)
            let files = await stopped(rec)
            let recorded = Date().timeIntervalSince(t0)
            expect(!files.isEmpty && !rec.isRecording, "stopped with \(files.map(\.lastPathComponent))")
            expect(files.first == file, "the first file is the one asked for")
            expect(noPart(out), "no .part file left")
            guard let first = files.first else { finish() }

            var total = 0.0
            for f in files {
                let asset = AVURLAsset(url: f)
                let dur = (try? await asset.load(.duration).seconds) ?? 0
                total += dur
            }
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
                // Samples, the first one a sync sample.
                if let reader = try? AVAssetReader(asset: asset) {
                    let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                    reader.add(o)
                    reader.startReading()
                    var n = 0, firstSync = false
                    while let s = o.copyNextSampleBuffer() { if n == 0 { firstSync = Recorder.isSync(s) }; n += 1 }
                    expect(n > 20, "\(n) samples")
                    expect(firstSync, "the first sample is a sync sample")
                } else { expect(false, "could not read samples") }
                // A frame from the middle is not black.
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
            expect(marks.map(\.title) == ["second tab", "fourth tab"] && marks.count == 2 && marks[0].t > 1 && marks[1].t > marks[0].t,
                   "chapters \(marks.map { "\($0.title)@\(String(format: "%.2f", $0.t))" })")
            expect(files.count == 2, "the rotation continued in a second file (\(files.count) files)")

            // 2. A still screen for 5 s.
            sim.send("rotate left")
            await sleep(1.5)
            sim.send("home")
            await sleep(2.5)   // nothing moves from here on
            let still = out.appendingPathComponent("still.mp4")
            let rec2 = Recorder(simulator: sim)
            _ = rec2.start(to: still)
            let s0 = Date()
            await sleep(5)
            let sFiles = await stopped(rec2)
            let sRecorded = Date().timeIntervalSince(s0)
            let sDur = sFiles.first.map { AVURLAsset(url: $0) }
            let sSeconds = (try? await sDur?.load(.duration).seconds) ?? 0
            expect(sFiles.count == 1 && abs(sSeconds - sRecorded) <= 0.3, String(format: "still screen: %.2f s against %.2f s recorded", sSeconds, sRecorded))
            expect(noPart(out), "no .part file left after the still recording")
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
