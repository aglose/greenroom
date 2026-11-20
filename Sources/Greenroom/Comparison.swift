import AppKit
import CoreGraphics

/// How two simulators' screens differ: in what is on them (nodes) and, when the screens are the same size, in
/// their pixels. `a` is the base (the build or device compared against), `b` the other.
struct ScreenComparison {
    struct Moved { let a: ScreenNode; let b: ScreenNode }

    var onlyA: [ScreenNode] = []
    var onlyB: [ScreenNode] = []
    var moved: [Moved] = []
    /// Whether both screens have the same pixel size (positions and pixels are compared only then).
    var sameSize = false
    var pixelsDiffering: Int?
    var pixelsTotal: Int?
    /// Where pixels differ, as rectangles in device pixels (a coarse grid, runs merged).
    var cells: [CGRect] = []

    var nodeDifferences: Int { onlyA.count + onlyB.count + moved.count }
    var isSame: Bool { nodeDifferences == 0 && (pixelsDiffering ?? 0) == 0 }

    var pixelPercent: Double? {
        guard let d = pixelsDiffering, let t = pixelsTotal, t > 0 else { return nil }
        return Double(d) / Double(t) * 100
    }

    /// One line: `2 differences, 1.3% of pixels`.
    var summary: String {
        var parts: [String] = [nodeDifferences == 0 ? "same content" : "\(nodeDifferences) difference\(nodeDifferences == 1 ? "" : "s") in content"]
        if let p = pixelPercent { parts.append(p == 0 ? "identical pixels" : String(format: "%.2f%% of pixels differ", p)) }
        else if !sameSize { parts.append("screens of different sizes: positions and pixels not compared") }
        return parts.joined(separator: ", ")
    }

    /// `- "Sign in" click` (only on a), `+ "Log in" click` (only on b), `> "Add" click 733,1533 -> 733,1410` (moved).
    func lines(limit: Int = 40) -> [String] {
        func plain(_ n: ScreenNode) -> String { String(n.line.drop { $0 != " " }.dropFirst()).isEmpty ? "(unlabelled)" : String(n.line.drop { $0 != " " }.dropFirst()) }
        var out = onlyA.map { "- " + plain($0) } + onlyB.map { "+ " + plain($0) }
        out += moved.map { m in
            let size = (m.a.right - m.a.left != m.b.right - m.b.left) || (m.a.bottom - m.a.top != m.b.bottom - m.b.top)
            return "> \(plain(m.a)) \(m.a.left),\(m.a.top) -> \(m.b.left),\(m.b.top)" + (size ? " (resized \(m.a.right - m.a.left)x\(m.a.bottom - m.a.top) -> \(m.b.right - m.b.left)x\(m.b.bottom - m.b.top))" : "")
        }
        if out.count > limit { out = Array(out.prefix(limit)) + ["... \(out.count - limit) more"] }
        return out
    }

    // MARK: Nodes

    private static func key(_ n: ScreenNode) -> String { (n.field ? "f" : n.click ? "c" : "t") + "\u{1}" + n.label }

    /// Nodes are matched by their text and kind, in order. What has no match on the other side is only there;
    /// matched nodes at another place or size count as moved (same-sized screens only; `tolerance` pixels allowed).
    static func nodes(a: [ScreenNode], b: [ScreenNode], sameSize: Bool, tolerance: Int = 4) -> ScreenComparison {
        var result = ScreenComparison()
        result.sameSize = sameSize
        let left = a.filter { !$0.label.isEmpty || $0.click || $0.field }
        let right = b.filter { !$0.label.isEmpty || $0.click || $0.field }
        var free = Dictionary(grouping: right.indices, by: { key(right[$0]) })
        var used = Set<Int>()
        for n in left {
            let k = key(n)
            if var candidates = free[k], !candidates.isEmpty {
                let j = candidates.removeFirst()
                free[k] = candidates
                used.insert(j)
                let m = right[j]
                if sameSize, !n.label.isEmpty,
                   abs(n.left - m.left) > tolerance || abs(n.top - m.top) > tolerance
                    || abs((n.right - n.left) - (m.right - m.left)) > tolerance || abs((n.bottom - n.top) - (m.bottom - m.top)) > tolerance {
                    result.moved.append(Moved(a: n, b: m))
                }
            } else if !n.label.isEmpty || sameSize {
                result.onlyA.append(n)
            }
        }
        result.onlyB = right.indices.filter { !used.contains($0) && (!right[$0].label.isEmpty || sameSize) }.map { right[$0] }
        if sameSize {
            // Unlabelled things to tap match by their box: drop pairs that are in the same place on both sides.
            func box(_ n: ScreenNode) -> String { "\(n.left / 4),\(n.top / 4),\(n.right / 4),\(n.bottom / 4)" }
            let aBoxes = Set(result.onlyA.filter { $0.label.isEmpty }.map(box)), bBoxes = Set(result.onlyB.filter { $0.label.isEmpty }.map(box))
            let both = aBoxes.intersection(bBoxes)
            result.onlyA.removeAll { $0.label.isEmpty && both.contains(box($0)) }
            result.onlyB.removeAll { $0.label.isEmpty && both.contains(box($0)) }
        }
        return result
    }

    // MARK: Pixels

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? data : nil
    }

    /// Counts pixels whose colour differs by more than `delta` in any channel, and where they are (cells of `cell`
    /// pixels with any such pixel, runs along a row merged). Nil when the pictures are not the same size.
    static func pixels(a: CGImage, b: CGImage, delta: Int = 12, cell: Int = 24) -> (differing: Int, total: Int, cells: [CGRect])? {
        guard a.width == b.width, a.height == b.height, let pa = rgba(a), let pb = rgba(b) else { return nil }
        let w = a.width, h = a.height
        let cols = (w + cell - 1) / cell, rows = (h + cell - 1) / cell
        var flagged = [Bool](repeating: false, count: cols * rows)
        var differing = 0
        pa.withUnsafeBufferPointer { x in
            pb.withUnsafeBufferPointer { y in
                for row in 0..<h {
                    let base = row * w * 4
                    // Rows that are byte for byte the same (most of them) are skipped in one comparison.
                    if memcmp(x.baseAddress! + base, y.baseAddress! + base, w * 4) == 0 { continue }
                    for col in 0..<w {
                        let i = base + col * 4
                        if abs(Int(x[i]) - Int(y[i])) > delta || abs(Int(x[i+1]) - Int(y[i+1])) > delta || abs(Int(x[i+2]) - Int(y[i+2])) > delta {
                            differing += 1
                            flagged[(row / cell) * cols + col / cell] = true
                        }
                    }
                }
            }
        }
        var cells: [CGRect] = []
        for r in 0..<rows {
            var c = 0
            while c < cols {
                guard flagged[r * cols + c] else { c += 1; continue }
                var end = c
                while end + 1 < cols, flagged[r * cols + end + 1] { end += 1 }
                cells.append(CGRect(x: c * cell, y: r * cell, width: min((end + 1) * cell, w) - c * cell, height: min((r + 1) * cell, h) - r * cell))
                c = end + 1
            }
        }
        return (differing, w * h, cells)
    }

    /// A picture of the differences: `b` dimmed, with the differing areas in magenta.
    static func map(b: CGImage, cells: [CGRect], maxSize: Int = 1000) -> Data? {
        let longest = max(b.width, b.height)
        let scale = maxSize > 0 && longest > maxSize ? CGFloat(maxSize) / CGFloat(longest) : 1
        let w = Int(CGFloat(b.width) * scale), h = Int(CGFloat(b.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(b, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.1, blue: 0.7, alpha: 0.75))
        for c in cells {
            ctx.fill(CGRect(x: c.minX * scale, y: CGFloat(h) - c.maxY * scale, width: c.width * scale, height: c.height * scale))
        }
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

extension Simulator {
    /// The app's pixels as the engine draws them. Never on the main thread.
    func capture() -> CGImage? {
        let dir = Engine.shared.screenshots
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = "capture-\(UUID().uuidString).png"
        let file = dir.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: file) }
        guard !sendSync("shot screenshots/\(name)").hasPrefix("error"), let data = try? Data(contentsOf: file) else { return nil }
        return NSBitmapImageRep(data: data)?.cgImage
    }

    /// Compares this simulator's screen (the base) with another's, once both have gone quiet. Never on the main thread.
    func compare(with other: Simulator, pixels: Bool = true) -> (comparison: ScreenComparison, otherImage: CGImage?) {
        _ = sendSync("settle 2500 150", timeout: 10)
        _ = other.sendSync("settle 2500 150", timeout: 10)
        let sizes = DispatchQueue.main.sync { (deviceSize, other.deviceSize) }
        let same = sizes.0 == sizes.1 && sizes.0.width > 0
        var result = ScreenComparison.nodes(a: ScreenNode.parse(sendSync("nodes")), b: ScreenNode.parse(other.sendSync("nodes")), sameSize: same)
        var image: CGImage?
        if pixels, same, let a = capture(), let b = other.capture(), let p = ScreenComparison.pixels(a: a, b: b) {
            result.pixelsDiffering = p.differing
            result.pixelsTotal = p.total
            result.cells = p.cells
            image = b
        }
        return (result, image)
    }
}
