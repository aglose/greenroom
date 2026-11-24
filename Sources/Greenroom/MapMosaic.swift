import AppKit

/// The map from far away: every card in a region drawn into one bitmap from very small copies of the captures (24
/// or 48 pixels wide, as a game picks a mip by distance), so a card too small for a layer of its own still shows its
/// colours. The small copies are scaled from the pyramid's 96-pixel files and kept in memory; everything here but
/// `render`'s call and its completions runs on the mosaic's own queue.
final class MapMosaic {
    /// One card: where it is in the canvas, its capture, its status's colour and whether a focus leaves it lit.
    struct Item {
        let frame: CGRect
        let blob: String
        let border: CGColor?
        let lit: Bool
    }

    enum Mip: Int { case tiny = 24, mini = 48 }
    /// The most pixels one mosaic may have (four bytes each).
    static let pixelBudget: CGFloat = 6_000_000
    /// The finest a mosaic is drawn, in pixels a canvas point: a 96-point card from its 48-pixel copy.
    static let finest: CGFloat = 0.5
    /// The mip a card is drawn from at `scale` pixels a point.
    static func mip(at scale: CGFloat) -> Mip { scale * 96 <= 30 ? .tiny : .mini }

    /// Called on the main thread after a batch of small copies was loaded: there is more to draw.
    var onLoaded: (() -> Void)?

    private let pyramid: MapPyramid
    private let queue = DispatchQueue(label: "greenroom-map-mosaic", qos: .userInitiated)
    private let lock = NSLock()
    private var copies: [Mip: [String: CGImage]] = [.tiny: [:], .mini: [:]]
    private let limits: [Mip: Int] = [.tiny: 8000, .mini: 1500]
    private var failed = Set<String>()
    private let batch = 48

    /// Small copies in memory, for checks.
    var copiesInMemory: Int { lock.lock(); defer { lock.unlock() }; return copies.values.reduce(0) { $0 + $1.count } }

    init(pyramid: MapPyramid) { self.pyramid = pyramid }

    /// Draws `items` over `region` (canvas points, origin top left) at `scale` pixels a point with what is in memory,
    /// and hands the picture to `done` on the main thread; then loads some of the copies that were missing and says
    /// so through `onLoaded`. Main thread.
    func render(_ items: [Item], region: CGRect, scale: CGFloat, done: @escaping (MapPicture?) -> Void) {
        queue.async { [self] in
            let mip = Self.mip(at: scale)
            var missing: [String] = []
            let picture = draw(items, region, scale, mip, &missing)
            DispatchQueue.main.async { done(picture) }
            guard !missing.isEmpty else { return }
            let todo = Array(missing.prefix(batch))
            DispatchQueue.concurrentPerform(iterations: todo.count) { k in self.load(todo[k], mip) }
            DispatchQueue.main.async { self.onLoaded?() }
        }
    }

    private func copy(_ blob: String, _ mip: Mip) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return copies[mip]?[blob]
    }

    private func load(_ blob: String, _ mip: Mip) {
        guard let source = pyramid.thumbnail(blob) else {
            lock.lock(); failed.insert(blob); lock.unlock()
            return
        }
        let w = mip.rawValue, h = max(1, source.height * w / max(source.width, 1))
        guard let ctx = MapPyramid.context(w, h) else { return }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { return }
        lock.lock()
        // Crude, and rare: a map with more screens than this starts the level over.
        if (copies[mip]?.count ?? 0) >= (limits[mip] ?? 0) { copies[mip] = [:] }
        copies[mip]?[blob] = image
        lock.unlock()
    }

    private func draw(_ items: [Item], _ region: CGRect, _ scale: CGFloat, _ mip: Mip, _ missing: inout [String]) -> MapPicture? {
        let width = Int((region.width * scale).rounded(.up)), height = Int((region.height * scale).rounded(.up))
        lock.lock()
        let wanted = copies[mip] ?? [:], fallback = mip == .mini ? copies[.tiny] ?? [:] : [:], failed = self.failed
        lock.unlock()
        var absent: [String] = []
        let picture = MapPicture.draw(width, height) { ctx in
            ctx.interpolationQuality = .medium
            let radius = 12 * scale
            for item in items {
                let image = wanted[item.blob]
                if image == nil, !failed.contains(item.blob) { absent.append(item.blob) }
                guard let image = image ?? fallback[item.blob] else { continue }
                // The canvas reads top down, the bitmap bottom up.
                let r = CGRect(x: (item.frame.minX - region.minX) * scale, y: CGFloat(height) - (item.frame.maxY - region.minY) * scale,
                               width: item.frame.width * scale, height: item.frame.height * scale)
                ctx.saveGState()
                ctx.setAlpha(item.lit ? 1 : 0.28)
                let path = radius >= 1.5 ? CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
                                         : CGPath(rect: r, transform: nil)
                ctx.addPath(path)
                ctx.clip()
                ctx.draw(image, in: r)
                // Inside the clip, so half of the line shows: a hairline for a plain card, the status's colour thicker.
                ctx.addPath(path)
                ctx.setStrokeColor(item.border ?? CGColor(gray: 1, alpha: 0.16))
                ctx.setLineWidth(item.border == nil ? 2 : max(3, 5 * scale))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        missing = absent
        return picture
    }
}
