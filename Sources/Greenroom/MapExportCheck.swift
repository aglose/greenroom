import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `Greenroom --map-export-check DIR`: the HTML export (MapExport), headless. The "mixed" golden pair (500 screens) and
/// the "grow" pair are exported into `DIR/mixed` and `DIR/grow` with generated stand-in pictures (the fixtures name
/// captures that no file holds), then, with no browser: index.html reaches nothing over the network, every picture
/// the data names exists, the data holds the diff's counts and each screen the diff names with its reasons (and every
/// mutation's screen), and the folder is under `MapExport.sizeLimit`. Prints the folders.
enum MapExportCheck {
    static func run(dir: URL) -> Never {
        var ok = true
        func expect(_ good: Bool, _ what: String) { if !good { ok = false }; print("[greenroom] map-export: \(good ? "ok  " : "FAIL") \(what)") }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // GREENROOM_EXPORT_LARGE=1 adds the 2,000-screen pair, to look at the page with that many.
        let more = ProcessInfo.processInfo.environment["GREENROOM_EXPORT_LARGE"] == "1" ? [MapFixtures.large()] : []
        for pair in MapFixtures.golden().filter({ $0.name == "mixed" || $0.name == "grow" }) + more {
            let name = pair.name
            let pictures = dir.appendingPathComponent("stand-ins-" + name, isDirectory: true)
            try? fm.removeItem(at: pictures)
            try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)
            let baseHashes = Set(pair.base.screens.flatMap { $0.captures.values })
            // Which hash is which screen's, so a changed head picture is the base's with something drawn on it.
            var owner: [String: (lineage: String, combo: String, changed: Bool)] = [:]
            for s in pair.base.screens { for (c, h) in s.captures { owner[h] = (s.lineage, c, false) } }
            for s in pair.head.screens { for (c, h) in s.captures where owner[h] == nil { owner[h] = (s.lineage, c, baseHashes.isSuperset(of: []) && pair.base.screens.contains { $0.lineage == s.lineage }) } }
            var made = 0
            let blob: (String) -> URL? = { hash in
                guard let o = owner[hash] else { return nil }
                let url = pictures.appendingPathComponent(hash + ".png")
                if !fm.fileExists(atPath: url.path) {
                    guard let png = standIn(lineage: o.lineage, combo: o.combo, variant: o.changed ? hash : nil) else { return nil }
                    try? png.write(to: url)
                    made += 1
                }
                return url
            }

            let out = dir.appendingPathComponent(name, isDirectory: true)
            let diff = pair.expected
            let c = diff.counts
            let total: Int
            do {
                total = try MapExport.write(head: pair.head, base: pair.base, diff: diff, blob: blob, to: out, title: "Greenroom \(name) export check", names: (base: "main", head: "pull request"))
            } catch {
                expect(false, "\(name): written (\(error))")
                continue
            }
            print("[greenroom] map-export: \(name): \(pair.head.screens.count) screens, +\(c.added) -\(c.removed) ~\(c.modified) =\(c.same), \(made) stand-in pictures made")

            // The page.
            let html = (try? String(contentsOf: out.appendingPathComponent("index.html"), encoding: .utf8)) ?? ""
            expect(!html.isEmpty && !html.lowercased().contains("http"), "\(name): index.html reaches nothing over the network (no \"http\")")
            expect(!html.contains("<link") && html.components(separatedBy: "<script").count == 3, "\(name): index.html has its styles inline and only data.js and its own script")

            // The data.
            let raw = (try? String(contentsOf: out.appendingPathComponent(MapExport.dataName), encoding: .utf8)) ?? ""
            let prefix = "window.GREENROOM_MAP = "
            var json = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if json.hasPrefix(prefix) { json = String(json.dropFirst(prefix.count)) }
            if json.hasSuffix(";") { json = String(json.dropLast()) }
            guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any], let screens = root["screens"] as? [[String: Any]] else {
                expect(false, "\(name): data.js reads as JSON")
                continue
            }
            expect(true, "\(name): data.js reads as JSON (\(screens.count) screens)")

            let counts = root["counts"] as? [String: Int] ?? [:]
            var byStatus: [String: Int] = [:]
            for s in screens { byStatus[s["st"] as? String ?? "", default: 0] += 1 }
            let same = counts["added"] == c.added && counts["removed"] == c.removed && counts["modified"] == c.modified && counts["same"] == c.same && counts["notCompared"] == c.notCompared
                && (byStatus["added"] ?? 0) == c.added && (byStatus["removed"] ?? 0) == c.removed && (byStatus["modified"] ?? 0) == c.modified && (byStatus["same"] ?? 0) == c.same
            expect(same, "\(name): the data holds the diff's counts: +\(byStatus["added"] ?? 0) -\(byStatus["removed"] ?? 0) ~\(byStatus["modified"] ?? 0) =\(byStatus["same"] ?? 0)")

            let byKey = Dictionary(screens.compactMap { s in (s["k"] as? String).map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
            var wrong: [String] = []
            for ch in diff.screens where ch.status != .same {
                guard let s = byKey[ch.lineage], s["st"] as? String == ch.status.rawValue, (s["rs"] as? [String] ?? []) == ch.reasons.map(\.rawValue) else { wrong.append(ch.lineage); continue }
            }
            expect(wrong.isEmpty, "\(name): every changed screen is in the data with its status and reasons (\(diff.screens.filter { $0.status != .same }.count), wrong: \(wrong.count))")

            var missing: [String] = []
            for m in pair.mutations {
                switch m {
                case .restyle(let l): if !(byKey[l]?["rs"] as? [String] ?? []).contains("visual") { missing.append("restyle " + l) }
                case .retext(let l): if !(byKey[l]?["rs"] as? [String] ?? []).contains("text") { missing.append("retext " + l) }
                case .restructure(let l): if !(byKey[l]?["rs"] as? [String] ?? []).contains("structure") { missing.append("restructure " + l) }
                case .remove(let l): if byKey[l]?["st"] as? String != "removed" { missing.append("remove " + l) }
                case .retarget(let from, _, _): if !(byKey[from]?["rs"] as? [String] ?? []).contains("routes") { missing.append("retarget " + from) }
                case .add(_, let label): if !screens.contains(where: { $0["st"] as? String == "added" && $0["t"] as? String == label }) { missing.append("add " + label) }
                }
            }
            expect(missing.isEmpty, "\(name): each of the \(pair.mutations.count) mutations shows as its screen with its reason \(missing)")

            // Pictures: every one named exists, the changed ones have both sides and a difference, nothing else is there.
            var named = Set<String>()
            func collect(_ any: Any) {
                if let s = any as? String { if s.hasPrefix("img/") { named.insert(s) } }
                else if let a = any as? [Any] { a.forEach(collect) }
                else if let d = any as? [String: Any] { d.values.forEach(collect) }
            }
            collect(screens)
            let absent = named.filter { !fm.fileExists(atPath: out.appendingPathComponent($0).path) }
            expect(!named.isEmpty && absent.isEmpty, "\(name): all \(named.count) pictures the data names exist (missing \(absent.count))")
            var onDisk = Set<String>()
            if let e = fm.enumerator(at: out.appendingPathComponent("img"), includingPropertiesForKeys: nil) { for case let u as URL in e { onDisk.insert("img/" + u.lastPathComponent) } }
            expect(onDisk == named, "\(name): the folder holds only the pictures the data names (\(onDisk.count) files)")
            let modifiedWithVisual = screens.filter { $0["st"] as? String == "modified" && ($0["rs"] as? [String] ?? []).contains("visual") }
            expect(modifiedWithVisual.allSatisfy { ($0["df"] as? [String: String])?.isEmpty == false && ($0["bi"] as? [String: String])?.isEmpty == false && ($0["hi"] as? [String: String])?.isEmpty == false },
                   "\(name): a visually changed screen has base, head and a difference picture")
            let thumbs = screens.filter { $0["th"] != nil }
            let wide = thumbs.compactMap { ($0["th"] as? String).flatMap { path in thumbWidth(out.appendingPathComponent(path)) } }
            expect(wide.count == thumbs.count && wide.allSatisfy { $0 <= MapExport.thumbWidth } && thumbs.count == screens.count - byStatus["added", default: 0] - byStatus["removed", default: 0] - byStatus["modified", default: 0],
                   "\(name): every other screen has a thumbnail at most \(MapExport.thumbWidth) pixels wide (\(thumbs.count))")

            expect(total < MapExport.sizeLimit, "\(name): the folder is \(total / 1024) KB, under \(MapExport.sizeLimit / 1_000_000) MB")
            print("[greenroom] map-export: \(name): \(out.path)")
        }

        // With no base: one map, no comparison.
        let solo = MapFixtures.make(screens: 30, seed: 11)
        let soloOut = dir.appendingPathComponent("single", isDirectory: true)
        let soloPictures = dir.appendingPathComponent("stand-ins-single", isDirectory: true)
        try? fm.createDirectory(at: soloPictures, withIntermediateDirectories: true)
        var soloOwner: [String: (String, String)] = [:]
        for s in solo.screens { for (c, h) in s.captures { soloOwner[h] = (s.lineage, c) } }
        let soloBlob: (String) -> URL? = { h in
            guard let o = soloOwner[h], let png = standIn(lineage: o.0, combo: o.1, variant: nil) else { return nil }
            let u = soloPictures.appendingPathComponent(h + ".png"); try? png.write(to: u); return u
        }
        if let total = try? MapExport.write(head: solo, base: nil, diff: nil, blob: soloBlob, to: soloOut, title: "Greenroom single map", names: (base: "", head: "main")) {
            let json = (try? String(contentsOf: soloOut.appendingPathComponent(MapExport.dataName), encoding: .utf8)) ?? ""
            expect(total > 0 && json.contains("\"hasBase\":false") && !json.contains("\"st\":\"added\""), "single: a map with no base exports with no comparison")
            print("[greenroom] map-export: single: \(soloOut.path)")
        } else { expect(false, "single: written") }

        print("[greenroom] map-export: folders under \(dir.path)")
        print(ok ? "[greenroom] map-export: PASS" : "[greenroom] map-export: FAIL")
        exit(ok ? 0 : 1)
    }

    private static func thumbWidth(_ url: URL) -> Int? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return nil }
        return p[kCGImagePropertyPixelWidth] as? Int
    }

    /// A made-up 540 x 1200 screenshot: colours and blocks from the lineage, dark or light by `combo`. With a `variant`
    /// (the hash of a changed capture) a bar is drawn that the base's picture lacks.
    static func standIn(lineage: String, combo: String, variant: String?) -> Data? {
        let w = 540, h = 1200
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let digest = MapJSON.sha256(lineage)
        let bytes = Array(digest.utf8).map { Int($0) % 16 }
        func f(_ i: Int) -> CGFloat { CGFloat(bytes[i % bytes.count]) / 15 }
        let dark = combo == "dark"
        ctx.setFillColor(dark ? CGColor(gray: 0.09, alpha: 1) : CGColor(gray: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.2 + f(0) * 0.5, green: 0.3 + f(1) * 0.5, blue: 0.4 + f(2) * 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 170, width: w, height: 170))
        for i in 0..<7 {
            let y = h - 230 - i * 140, tall = 100 + Int(f(i + 3) * 30)
            ctx.setFillColor(dark ? CGColor(gray: 0.17 + f(i) * 0.05, alpha: 1) : CGColor(gray: 0.88 - f(i) * 0.05, alpha: 1))
            ctx.fill(CGRect(x: 30, y: y - tall, width: w - 60, height: tall))
            ctx.setFillColor(CGColor(srgbRed: f(i + 7), green: 0.5, blue: f(i + 11), alpha: 1))
            ctx.fill(CGRect(x: 50, y: y - tall + 20, width: Int(60 + f(i + 13) * 200), height: 18))
        }
        if let variant {
            let v = Array(variant.utf8).map { Int($0) % 16 }
            ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.3, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 40 + v[0] * 8, y: 90 + v[1] * 40, width: 300, height: 56))
        }
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
