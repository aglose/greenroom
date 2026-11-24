import AppKit
import ImageIO
import IOSurface
import UniformTypeIdentifiers

/// Where a capture's pixels come from: its blob (the SHA-256 of the PNG), the longest side wanted in pixels (0: as it
/// is), and a completion that may be called on any thread. The store reads the PNG; a check draws a stand-in.
typealias MapImageSource = (_ blob: String, _ maxPixel: Int, _ done: @escaping (CGImage?) -> Void) -> Void

/// A decoded picture in an IOSurface: a layer shows it as it is, so Core Animation copies nothing on the main thread
/// when it commits (a CGImage of a whole capture is ten megabytes copied there).
final class MapPicture {
    let surface: IOSurface
    var contents: Any { surface }
    var bytes: Int { surface.allocationSize }
    var pixelWidth: Int { surface.width }
    var pixelHeight: Int { surface.height }
    init(surface: IOSurface) { self.surface = surface }

    /// A `width` × `height` picture drawn by `draw` into a context whose origin is the bottom left, as Core Graphics
    /// has it. Any thread.
    static func draw(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> MapPicture? {
        guard width > 0, height > 0, let surface = IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: 0x4247_5241,   // 'BGRA'
        ]) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let ctx = CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx)
        return MapPicture(surface: surface)
    }
}

/// The map's pictures at three sizes: 96 and 384 pixels wide, made once per blob into a folder on disk, and the capture
/// itself for the few cards seen up close. Everything is decoded off the main thread, with the card's rounded corners
/// already in the pixels (so a card needs no mask layer), and kept in memory under a byte limit, least recently used
/// first out. A card that leaves the view cancels what it asked for.
final class MapPyramid {
    enum Tier: Int, CaseIterable {
        case small = 96, large = 384
        /// The capture as the source has it, never written to disk.
        case full = 0
    }

    /// A request a card holds while it waits; `cancel` drops its completion, and the work when no one else waits.
    final class Ticket {
        fileprivate let key: String
        fileprivate weak var pyramid: MapPyramid?
        fileprivate var done: ((MapPicture) -> Void)?
        fileprivate init(key: String, pyramid: MapPyramid, done: @escaping (MapPicture) -> Void) { self.key = key; self.pyramid = pyramid; self.done = done }
        func cancel() { pyramid?.cancel(self) }
    }

    let folder: URL
    let byteLimit: Int
    /// The corner's radius as a share of the picture's width (a card's 12 points over its 96).
    var cornerFraction: CGFloat = 12.0 / 96.0

    private let source: MapImageSource
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "greenroom-map-pyramid"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()
    private struct Entry { let image: MapPicture; let bytes: Int; var used: UInt64 }
    private var memory: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var pending: [String: (op: Operation, tickets: [Ticket])] = [:]
    /// The blobs whose 96 and 384 files are on disk (filled as they are made or found).
    private var onDisk = Set<String>()
    private let diskLock = NSLock()

    private(set) var bytesInMemory = 0
    /// The most the memory ever held, for checks.
    private(set) var peakBytes = 0
    var imagesInMemory: Int { memory.count }
    var loading: Int { pending.count }
    /// Requests dropped because their card left the view before the picture came.
    private(set) var cancelled = 0

    init(folder: URL, byteLimit: Int = 128 << 20, source: @escaping MapImageSource) {
        self.folder = folder
        self.byteLimit = byteLimit
        self.source = source
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private static func key(_ blob: String, _ tier: Tier) -> String { "\(blob)|\(tier.rawValue)" }
    private func file(_ blob: String, _ tier: Tier) -> URL { folder.appendingPathComponent("\(blob.prefix(2))/\(blob)-\(tier.rawValue).png") }

    /// The picture if it is in memory now. Main thread.
    func cached(_ blob: String, _ tier: Tier) -> MapPicture? {
        let k = Self.key(blob, tier)
        guard var e = memory[k] else { return nil }
        clock += 1
        e.used = clock
        memory[k] = e
        return e.image
    }

    /// The best picture in memory at `tier` or below: what a card shows while the one it wants is on its way.
    func best(_ blob: String, upTo tier: Tier) -> MapPicture? {
        let order: [Tier] = [.full, .large, .small]
        for t in order.drop(while: { $0 != tier }) { if let i = cached(blob, t) { return i } }
        return nil
    }

    /// Asks for a picture. A hit in memory is handed back at once (and no ticket); otherwise `done` is called on the
    /// main thread when it is decoded, unless the ticket is cancelled first. Main thread.
    func request(_ blob: String, _ tier: Tier, done: @escaping (MapPicture) -> Void) -> Ticket? {
        if let hit = cached(blob, tier) { done(hit); return nil }
        let k = Self.key(blob, tier)
        let ticket = Ticket(key: k, pyramid: self, done: done)
        if pending[k] != nil { pending[k]!.tickets.append(ticket); return ticket }
        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self, let op, !op.isCancelled else { return }
            let image = self.make(blob, tier, isCancelled: { op.isCancelled })
            DispatchQueue.main.async { self.finish(k, image) }
        }
        pending[k] = (op, [ticket])
        queue.addOperation(op)
        return ticket
    }

    fileprivate func cancel(_ t: Ticket) {
        t.done = nil
        guard var p = pending[t.key] else { return }
        p.tickets.removeAll { $0 === t }
        if p.tickets.isEmpty {
            p.op.cancel()
            pending[t.key] = nil
            cancelled += 1
        } else { pending[t.key] = p }
    }

    private func finish(_ k: String, _ image: MapPicture?) {
        guard let p = pending.removeValue(forKey: k) else { return }
        guard let image else { return }
        let bytes = image.bytes
        clock += 1
        memory[k] = Entry(image: image, bytes: bytes, used: clock)
        bytesInMemory += bytes
        evict()
        peakBytes = max(peakBytes, bytesInMemory)
        for t in p.tickets { t.done?(image); t.done = nil }
    }

    /// Least recently used out until the memory is under its limit again.
    private func evict() {
        guard bytesInMemory > byteLimit else { return }
        for (k, e) in memory.sorted(by: { $0.value.used < $1.value.used }) {
            guard bytesInMemory > byteLimit else { break }
            memory[k] = nil
            bytesInMemory -= e.bytes
        }
    }

    /// Lets go of everything in memory (the files stay).
    func purge() {
        memory = [:]
        bytesInMemory = 0
    }

    // MARK: Off the main thread

    /// The picture at `tier`, decoded and rounded: from disk when the pyramid has it, else from the source, writing
    /// both thumbnail sizes for next time.
    private func make(_ blob: String, _ tier: Tier, isCancelled: () -> Bool) -> MapPicture? {
        if tier == .full {
            guard let raw = fetch(blob, 0), !isCancelled() else { return nil }
            return rounded(raw, width: raw.width)
        }
        return thumbnail(blob, tier, isCancelled: isCancelled).flatMap { rounded($0, width: $0.width) }
    }

    /// The 96-pixel thumbnail as it is on disk, corners square: what the mosaic scales its small copies from. Any
    /// thread but the main one.
    func thumbnail(_ blob: String) -> CGImage? { thumbnail(blob, .small, isCancelled: { false }) }

    private func thumbnail(_ blob: String, _ tier: Tier, isCancelled: () -> Bool) -> CGImage? {
        let url = file(blob, tier)
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            return img
        }
        guard let raw = fetch(blob, Tier.large.rawValue * 3), !isCancelled() else { return nil }
        // Both sizes at once: the source is the expensive part.
        var made: [Tier: CGImage] = [:]
        for t in [Tier.small, .large] {
            guard let img = scaled(raw, width: t.rawValue) else { continue }
            made[t] = img
            write(img, to: file(blob, t))
        }
        diskLock.lock(); onDisk.insert(blob); diskLock.unlock()
        return made[tier]
    }

    private func fetch(_ blob: String, _ maxPixel: Int) -> CGImage? {
        let wait = DispatchSemaphore(value: 0)
        var out: CGImage?
        source(blob, maxPixel) { out = $0; wait.signal() }
        wait.wait()
        return out
    }

    private func scaled(_ image: CGImage, width: Int) -> CGImage? {
        let height = max(1, Int((CGFloat(image.height) * CGFloat(width) / CGFloat(max(image.width, 1))).rounded()))
        guard let ctx = Self.context(width, height) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// The picture with the card's corners cut, drawn into a fresh bitmap: decoded here, not on the main thread.
    private func rounded(_ image: CGImage, width: Int) -> MapPicture? {
        let height = image.height * width / max(image.width, 1)
        let r = CGFloat(width) * cornerFraction
        return MapPicture.draw(width, height) { ctx in
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func write(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        // rename(2) replaces whatever another thread wrote there first: the same picture.
        if rename(tmp.path, url.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }

    static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// The files on disk (both sizes of every blob made so far): for checks.
    var blobsOnDisk: Int { diskLock.lock(); defer { diskLock.unlock() }; return onDisk.count }
}
