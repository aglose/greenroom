import AppKit
import AVFoundation
import CoreMedia

/// Writes a simulator's H.264 stream into an MP4 without encoding it again: the access units the app already
/// receives go to an `AVAssetWriter` in passthrough.
///
/// - The tap is `Simulator.sampleTap`, a closure that is nil unless someone records: nothing is paid otherwise.
/// - A file begins on a keyframe (one is asked for, and asked for again until it arrives; samples before it are
///   dropped).
/// - Times are the stream's own (`presentMicros`), never the time of arrival: the engine drops frames for a slow
///   viewer and repeats a still screen. Arrival time is used only to hold the last picture on a still screen up to
///   the moment of `stop` (or of `mark`), by lengthening the final sample.
/// - A size change (rotation, another device) brings new parameter sets. That file is ended cleanly (its last
///   picture is held until the new keyframe) and the recording **continues in a numbered file**: `NAME.mp4`,
///   `NAME-2.mp4`, ... An MP4 track has one picture size, and a continuation keeps each file playable on its own.
///   Each file has its own `.chapters.json`, with times counted from that file's start.
/// - Files are written as `NAME.mp4.part` and renamed when finished, so a crash leaves nothing under the final name.
/// - Chapters: `NAME.chapters.json`, `[{"t": seconds, "title": "..."}]`.
final class Recorder {
    struct Chapter: Codable { let t: Double; let title: String }

    let simulator: Simulator
    private(set) var isRecording = false
    /// Called on the main thread when recording starts or ends.
    static let didChange = Notification.Name("GreenroomRecorderDidChange")

    private let queue = DispatchQueue(label: "greenroom-recorder")
    private var live: Segment?              // queue only
    private var finished: [URL] = []        // queue only
    private var chapters: [(title: String, at: Double)] = []   // queue only; `at` is seconds into the whole recording
    private var base: URL?                  // the requested file, without .mp4
    private var segmentNumber = 0
    private var lastPTS: CMTime = .invalid  // stream time of the newest sample
    private var lastArrival: Double = 0     // uptime when it arrived
    private var originPTS: CMTime = .invalid // stream time of the first sample of the whole recording
    private var wantKeyframe: DispatchSourceTimer?

    init(simulator: Simulator) { self.simulator = simulator }

    // MARK: The one dependence on the stream

    /// The stream must be on for this simulator, and a picture must be coming: today the engine's H.264 stream is
    /// always on, so this asks for a keyframe and a redraw. If display moves to shared surfaces (PLAN.md phase 0),
    /// this is the one place that starts the stream (or an encoder fed from the surfaces) for a recorder.
    private func streamMustBeOn() {
        simulator.requestKeyframe()
        simulator.control?.send("redraw")
    }

    // MARK: API

    /// Begins a recording that will end up at `url` (a `.mp4` path). Returns false when one is running already or
    /// the folder cannot be made.
    @discardableResult
    func start(to url: URL) -> Bool {
        guard !isRecording else { return false }
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch { return false }
        isRecording = true
        queue.sync {
            base = url.deletingPathExtension()
            live = nil; finished = []; chapters = []; segmentNumber = 0
            lastPTS = .invalid; originPTS = .invalid
        }
        simulator.sampleTap = { [weak self] sample in
            let arrival = ProcessInfo.processInfo.systemUptime
            self?.queue.async { self?.take(sample, arrival: arrival) }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Until the first keyframe is in, keep asking.
            if self.live == nil { DispatchQueue.main.async { self.streamMustBeOn() } } else { self.wantKeyframe?.cancel(); self.wantKeyframe = nil }
        }
        wantKeyframe = timer
        timer.resume()
        NotificationCenter.default.post(name: Self.didChange, object: simulator)
        return true
    }

    /// A chapter at the current time of the recording.
    func mark(_ title: String) {
        let now = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in chapters.append((title, elapsed(at: now))) }
    }

    /// Ends the recording: the last picture is held up to now, the files are finished and renamed, and
    /// `completion` (main thread) gets the files (more than one when the screen changed size; empty when nothing
    /// ever arrived).
    func stop(completion: @escaping ([URL]) -> Void) {
        guard isRecording else { completion([]); return }
        isRecording = false
        simulator.sampleTap = nil
        wantKeyframe?.cancel(); wantKeyframe = nil
        let now = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            let end = streamTime(at: now)
            closeSegment(at: end, last: true)
            let files = finished
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChange, object: self.simulator)
                completion(files)
            }
        }
    }

    // MARK: Timeline (queue)

    /// The stream's time at an uptime: the newest sample's time plus what has passed since it arrived.
    private func streamTime(at uptime: Double) -> CMTime {
        guard lastPTS.isValid else { return .invalid }
        return CMTimeAdd(lastPTS, CMTime(seconds: max(0, uptime - lastArrival), preferredTimescale: 1_000_000))
    }

    private func elapsed(at uptime: Double) -> Double {
        let t = streamTime(at: uptime)
        guard t.isValid, originPTS.isValid else { return 0 }
        return max(0, CMTimeSubtract(t, originPTS).seconds)
    }

    // MARK: Samples (queue)

    private func take(_ sample: CMSampleBuffer, arrival: Double) {
        guard let desc = CMSampleBufferGetFormatDescription(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }
        let isKey = Self.isSync(sample)
        let dims = CMVideoFormatDescriptionGetDimensions(desc)

        if let seg = live {
            guard CMTimeCompare(pts, seg.lastPTS) > 0 else { return }   // the stream's times only go forward
            if dims.width != seg.width || dims.height != seg.height {
                // A new size: only a keyframe may begin the continuation. The old file holds its last picture to here.
                guard isKey else { simulatorAsksKey(); return }
                closeSegment(at: pts)
                openSegment(first: sample, desc: desc, pts: pts)
            } else {
                seg.append(sample, pts: pts)
            }
        } else {
            guard isKey else { return }   // wait for a keyframe
            if !originPTS.isValid { originPTS = pts }
            openSegment(first: sample, desc: desc, pts: pts)
        }
        lastPTS = pts
        lastArrival = arrival
    }

    private func simulatorAsksKey() { DispatchQueue.main.async { self.streamMustBeOn() } }

    private func openSegment(first: CMSampleBuffer, desc: CMFormatDescription, pts: CMTime) {
        guard let base else { return }
        segmentNumber += 1
        let name = segmentNumber == 1 ? base : URL(fileURLWithPath: base.path + "-\(segmentNumber)")
        guard let seg = Segment(target: name.appendingPathExtension("mp4"), desc: desc, firstPTS: pts,
                                offset: originPTS.isValid ? CMTimeSubtract(pts, originPTS).seconds : 0) else { return }
        live = seg
        seg.append(first, pts: pts)
    }

    /// Ends the open file with its last picture held up to `end` (stream time), and writes its chapters.
    private func closeSegment(at end: CMTime, last: Bool = false) {
        guard let seg = live else { return }
        live = nil
        // A chapter exactly on a boundary belongs to the later file.
        let spanEnd = seg.offset + CMTimeSubtract(end, seg.firstPTS).seconds
        let mine = chapters.filter { $0.at >= seg.offset && ($0.at < spanEnd || last) }
        if let url = seg.finish(endingAt: end) {
            let list = mine.map { Chapter(t: max(0, ($0.at - seg.offset) * 1000).rounded() / 1000, title: $0.title) }
            let json = (try? JSONEncoder().encode(list)) ?? Data("[]".utf8)
            try? json.write(to: url.deletingPathExtension().appendingPathExtension("chapters.json"))
            finished.append(url)
        }
    }

    static func isSync(_ sample: CMSampleBuffer) -> Bool {
        guard let a = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]], let first = a.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    /// Whether a recorder is running for this simulator.
    static func isRecording(_ sim: Simulator?) -> Bool { sim.map { ScreenRecording.shared.recorder(for: $0) != nil } ?? false }

    // MARK: One file

    /// One MP4 being written: samples are held one back so each gets its duration from the next one's time.
    private final class Segment {
        let target: URL, part: URL
        let width: Int32, height: Int32
        let firstPTS: CMTime
        let offset: Double
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput
        private var held: (sample: CMSampleBuffer, pts: CMTime)?
        private var backlog: [CMSampleBuffer] = []   // the writer was not ready: waiting, in order
        private(set) var lastPTS: CMTime
        private(set) var count = 0

        init?(target: URL, desc: CMFormatDescription, firstPTS: CMTime, offset: Double) {
            self.target = target
            part = target.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: part)
            let d = CMVideoFormatDescriptionGetDimensions(desc)
            width = d.width; height = d.height
            self.firstPTS = firstPTS; self.offset = offset
            lastPTS = firstPTS
            guard let w = try? AVAssetWriter(outputURL: part, fileType: .mp4) else { return nil }
            writer = w
            input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: desc)
            input.expectsMediaDataInRealTime = true
            guard w.canAdd(input) else { return nil }
            w.add(input)
            guard w.startWriting() else { return nil }
            w.startSession(atSourceTime: .zero)
        }

        func append(_ sample: CMSampleBuffer, pts: CMTime) {
            if let h = held { write(h.sample, pts: h.pts, duration: CMTimeSubtract(pts, h.pts)) }
            held = (sample, pts)
            lastPTS = pts
        }

        private func write(_ sample: CMSampleBuffer, pts: CMTime, duration: CMTime) {
            var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: CMTimeSubtract(pts, firstPTS),
                                            decodeTimeStamp: CMTimeSubtract(pts, firstPTS))
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                        sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr, let copy else { return }
            backlog.append(copy)
            drain()
        }

        private func drain() {
            while let next = backlog.first, input.isReadyForMoreMediaData, writer.status == .writing {
                input.append(next)
                backlog.removeFirst()
                count += 1
            }
        }

        /// Writes the held picture up to `end`, finishes and renames the file. Nil when nothing was written.
        func finish(endingAt end: CMTime) -> URL? {
            if let h = held {
                let tail = CMTimeSubtract(end.isValid ? end : h.pts, h.pts)
                write(h.sample, pts: h.pts, duration: CMTimeMaximum(tail, CMTime(value: 1, timescale: 30)))
                held = nil
            }
            // The writer takes what it can; wait (bounded) for the rest.
            let deadline = Date().addingTimeInterval(5)
            while !backlog.isEmpty, Date() < deadline { drain(); if !backlog.isEmpty { Thread.sleep(forTimeInterval: 0.01) } }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTimeSubtract(CMTimeMaximum(end.isValid ? end : lastPTS, lastPTS), firstPTS))
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            _ = done.wait(timeout: .now() + 20)
            guard writer.status == .completed, count > 0 else {
                try? FileManager.default.removeItem(at: part)
                return nil
            }
            try? FileManager.default.removeItem(at: target)
            do { try FileManager.default.moveItem(at: part, to: target) } catch { return nil }
            return target
        }
    }
}

// MARK: - In the app: File > Record Screen

/// The recorders the person started, one per simulator, and where their files go.
final class ScreenRecording {
    static let shared = ScreenRecording()
    private var running: [ObjectIdentifier: Recorder] = [:]

    func recorder(for sim: Simulator) -> Recorder? { running[ObjectIdentifier(sim)] }

    /// `evidence/<build key>/video/` for a simulator of a session with a build, else `recordings-video/` of the state folder.
    func folder(for sim: Simulator, in wb: Workbench) -> URL {
        let store = wb.sessions.store
        if let key = wb.sessions.session(forSimulator: sim)?.build?.key {
            return store.root.appendingPathComponent("evidence/\(key)/video", isDirectory: true)
        }
        return store.root.appendingPathComponent("recordings-video", isDirectory: true)
    }

    func newFile(for sim: Simulator, in wb: Workbench, prefix: String = "screen") -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return folder(for: sim, in: wb).appendingPathComponent("\(prefix)-\(f.string(from: Date())).mp4")
    }

    @discardableResult
    func start(_ sim: Simulator, to url: URL) -> Recorder? {
        guard running[ObjectIdentifier(sim)] == nil else { return nil }
        let r = Recorder(simulator: sim)
        guard r.start(to: url) else { return nil }
        running[ObjectIdentifier(sim)] = r
        return r
    }

    func stop(_ sim: Simulator, completion: @escaping ([URL]) -> Void) {
        guard let r = running.removeValue(forKey: ObjectIdentifier(sim)) else { return completion([]) }
        r.stop(completion: completion)
    }

    /// Finishes every recording (the app is quitting).
    func stopAll() {
        let all = Array(running.values)
        running.removeAll()
        for r in all { let s = DispatchSemaphore(value: 0); r.stop { _ in s.signal() }; _ = s.wait(timeout: .now() + 10) }
    }
}

extension Workbench {
    /// File > Record Screen: starts or stops a recording of the selected simulator.
    @objc func toggleScreenRecording(_ sender: Any?) {
        guard let sim = selected else { toast.show("Open a simulator to record it", problem: true); return }
        let rec = ScreenRecording.shared
        if rec.recorder(for: sim) != nil {
            rec.stop(sim) { [weak self] files in
                guard let self else { return }
                guard let first = files.first else { self.toast.show("Nothing was recorded", problem: true); return }
                self.toast.show("Recorded \(first.lastPathComponent)" + (files.count > 1 ? " and \(files.count - 1) more (the screen changed size)" : ""),
                                action: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
            }
        } else if rec.start(sim, to: rec.newFile(for: sim, in: self)) != nil {
            toast.show("Recording the screen. Choose Record Screen again to stop")
        } else {
            toast.show("Could not start the recording", problem: true)
        }
    }
}
