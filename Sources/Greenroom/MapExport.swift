import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Map history's HTML export (docs/MAP-HISTORY-PLAN.md, "Sharing", package S1): one folder that people without Greenroom
// open in a browser, from a zip or a static host, to see what a pull request or a release candidate changed.
//
//   index.html   the page: its styles and script inline, no network, no external anything (see `MapExportPage`)
//   data.js      `window.GREENROOM_MAP = {...}`: the screens with their positions (MapLayout), statuses, reasons, texts,
//                the edges and the changed edges, and the names of the pictures
//   img/         changed screens at full size (base and head, as the walk captured them) and a difference image made
//                with `ScreenComparison.pixels`/`.map`; unchanged screens as JPEG thumbnails 384 pixels wide; nothing else
//
// Decisions (the owner was asleep): the page lives in Swift strings, not in Resources/, so there is nothing to find at
// run time and nothing for scripts/bundle.sh to copy; it draws on a canvas, not SVG, which stays smooth with 2,000
// screens and needs no namespace URL (the check requires that index.html holds no "http" at all). Removed screens
// stand where the base's layout had them, as dashed ghosts. A comparison pairs head and base by lineage, so `head` must
// carry lineages (the pairing gives it them); without a base the map is one commit's and every screen is "plain".
enum MapExport {
    /// A 500-screen export with a handful of changes stays under this.
    static let sizeLimit = 40_000_000
    static let thumbWidth = 384
    /// Where in the folder the page's data is, and its global.
    static let dataName = "data.js"

    private static func key(_ s: MapSnapshot.Screen) -> String { s.lineage.isEmpty ? s.id : s.lineage }

    private static func shortName(_ text: String) -> String { String(text.prefix(20)) }

    /// Writes the export into `folder` (made if needed; what an earlier export left there is replaced) and gives the
    /// bytes it holds, which it prints. `diff` is `MapDiff.compare` of the two (nil with no `base`).
    @discardableResult
    static func write(head: MapSnapshot, base baseIn: MapSnapshot?, diff: MapDiff?, blob: (String) -> URL?, to folder: URL, title: String, names: (base: String, head: String)) throws -> Int {
        let fm = FileManager.default
        let base = baseIn.map(MapPairing.seeded)
        let diff = base == nil ? nil : diff
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in ["index.html", dataName, "img"] { try? fm.removeItem(at: folder.appendingPathComponent(old)) }
        let img = folder.appendingPathComponent("img", isDirectory: true)
        try fm.createDirectory(at: img, withIntermediateDirectories: true)

        // Positions: the head's layout, the base's where a screen is gone.
        let baseLayout = base.map { MapLayout.make($0) }
        let layout = MapLayout.make(head, previous: baseLayout)

        // Every screen of either map, by key.
        var headBy: [String: MapSnapshot.Screen] = [:], baseBy: [String: MapSnapshot.Screen] = [:]
        for s in head.screens { headBy[key(s)] = s }
        for s in base?.screens ?? [] { baseBy[key(s)] = s }
        let keys = Set(headBy.keys).union(baseBy.keys).sorted()
        var index: [String: Int] = [:]
        for (i, k) in keys.enumerated() { index[k] = i }
        var headIds: [String: Int] = [:], baseIds: [String: Int] = [:]
        for s in head.screens { headIds[s.id] = index[key(s)] }
        for s in base?.screens ?? [] { baseIds[s.id] = index[key(s)] }

        // Pictures.
        var fullPaths: [String: String] = [:], thumbPaths: [String: String] = [:]
        func fullImage(_ hash: String?) -> String? {
            guard let hash else { return nil }
            if let p = fullPaths[hash] { return p }
            guard let src = blob(hash), fm.fileExists(atPath: src.path) else { return nil }
            let rel = "img/" + shortName(hash) + ".png"
            guard (try? fm.copyItem(at: src, to: folder.appendingPathComponent(rel))) != nil else { return nil }
            fullPaths[hash] = rel
            return rel
        }
        func thumbImage(_ hash: String?) -> String? {
            guard let hash else { return nil }
            if let p = thumbPaths[hash] { return p }
            guard let src = blob(hash), let data = thumbnail(of: src, width: thumbWidth) else { return nil }
            let rel = "img/t-" + shortName(hash) + ".jpg"
            guard (try? data.write(to: folder.appendingPathComponent(rel))) != nil else { return nil }
            thumbPaths[hash] = rel
            return rel
        }
        func cgImage(_ hash: String?) -> CGImage? {
            guard let hash, let src = blob(hash), let s = CGImageSourceCreateWithURL(src as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(s, 0, nil)
        }
        func preferred(_ combos: [String]) -> String? { combos.contains("light") ? "light" : combos.sorted().first }

        var screens: [[String: Any]] = []
        var spill = 0
        for k in keys {
            let h = headBy[k], b = baseBy[k]
            let ch = diff?.change(k)
            let status = ch?.status.rawValue ?? (diff == nil ? "plain" : "same")
            let main = h ?? b!
            var o: [String: Any] = ["k": k, "t": main.title.isEmpty ? main.activity : main.title, "a": main.activity, "st": status, "dep": main.depth]
            var frame = layout.frames[k] ?? baseLayout?.frames[k]
            if frame == nil {
                frame = CGRect(x: layout.metrics.pad + CGFloat(spill) * layout.metrics.columnPitch, y: layout.size.height + 40, width: layout.metrics.cardWidth, height: layout.metrics.cardHeight)
                spill += 1
            }
            o["x"] = Int(frame!.minX.rounded()); o["y"] = Int(frame!.minY.rounded())
            o["w"] = Int(frame!.width.rounded()); o["h"] = Int(frame!.height.rounded())
            if let g = layout.groups.firstIndex(where: { $0.members.contains(k) }) { o["g"] = g }
            if let h { o["hid"] = h.id }
            if let b { o["bid"] = b.id }
            if !main.texts.isEmpty { o["tx"] = main.texts }
            let route = (h ?? b!)
            o["start"] = route.start ?? ""
            if !route.steps.isEmpty { o["steps"] = route.steps }
            if let ch {
                if !ch.reasons.isEmpty { o["rs"] = ch.reasons.map(\.rawValue) }
                if !ch.textAdded.isEmpty { o["ta"] = ch.textAdded }
                if !ch.textRemoved.isEmpty { o["tr"] = ch.textRemoved }
                if let why = ch.why { o["why"] = why }
            }
            if let f = h?.flaky ?? b?.flaky { o["flaky"] = f }

            let changed = status == "added" || status == "removed" || status == "modified"
            if changed {
                var hi: [String: String] = [:], bi: [String: String] = [:]
                if status != "removed" { for (c, hash) in h?.captures ?? [:] { if let p = fullImage(hash) { hi[c] = p } } }
                if status != "added" { for (c, hash) in b?.captures ?? [:] { if let p = fullImage(hash) { bi[c] = p } } }
                if !hi.isEmpty { o["hi"] = hi }
                if !bi.isEmpty { o["bi"] = bi }
                if status == "modified", let ch {
                    var df: [String: String] = [:], px: [String: Double] = [:], sizes: [String] = []
                    for c in ch.visual {
                        guard let a = cgImage(b?.captures[c]), let bb = cgImage(h?.captures[c]) else { continue }
                        guard let r = ScreenComparison.pixels(a: a, b: bb) else { sizes.append(c); continue }
                        px[c] = r.total > 0 ? (Double(r.differing) / Double(r.total) * 10_000).rounded() / 100 : 0
                        if r.differing > 0, let png = ScreenComparison.map(b: bb, cells: r.cells) {
                            let rel = "img/d-" + shortName(MapJSON.sha256(k + "|" + c)) + ".png"
                            if (try? png.write(to: folder.appendingPathComponent(rel))) != nil { df[c] = rel }
                        }
                    }
                    if !df.isEmpty { o["df"] = df }
                    if !px.isEmpty { o["px"] = px }
                    if !sizes.isEmpty { o["dz"] = sizes }
                }
            } else {
                let captures = (h ?? b!).captures
                if let c = preferred(Array(captures.keys)), let p = thumbImage(captures[c]) { o["th"] = p; o["thc"] = c }
            }
            screens.append(o)
        }

        // Edges: the head's controls that lead to a screen, flat pairs; then the ones the diff names.
        var flat: [Int] = []
        for e in head.edges {
            guard let f = headIds[e.from], let to = e.to, let t = headIds[to], f != t else { continue }
            flat += [f, t]
        }
        var changedEdges: [[String: Any]] = []
        func target(_ lineage: String?) -> (Int, String?) {
            guard let lineage else { return (-1, nil) }
            if let i = index[lineage] { return (i, nil) }
            return (-1, lineage == "?" ? nil : lineage)
        }
        for e in diff?.edges ?? [] {
            guard let f = index[e.from] else { continue }
            let (bt, bp) = target(e.baseTo), (ht, hp) = target(e.headTo)
            var o: [String: Any] = ["f": f, "st": e.status.rawValue, "cmd": e.cmd, "a": e.action, "bt": bt, "ht": ht]
            if let bp { o["bp"] = bp }
            if let hp { o["hp"] = hp }
            changedEdges.append(o)
        }

        let groups: [[String: Any]] = layout.groups.map {
            ["t": $0.title, "x": Int($0.frame.minX.rounded()), "y": Int($0.frame.minY.rounded()), "w": Int($0.frame.width.rounded()), "h": Int($0.frame.height.rounded())]
        }
        var maxY = layout.size.height, maxX = layout.size.width
        for s in screens { maxY = max(maxY, CGFloat((s["y"] as! Int) + (s["h"] as! Int)) + 40); maxX = max(maxX, CGFloat((s["x"] as! Int) + (s["w"] as! Int)) + 40) }

        var counts: [String: Int] = ["total": screens.count]
        if let c = diff?.counts { counts["added"] = c.added; counts["removed"] = c.removed; counts["modified"] = c.modified; counts["same"] = c.same; counts["notCompared"] = c.notCompared }
        let combos = Array(Set(head.screens.flatMap { $0.captures.keys }).union((base?.screens ?? []).flatMap { $0.captures.keys })).sorted()
        let data: [String: Any] = [
            "title": title,
            "names": [names.base, names.head],
            "hasBase": base != nil,
            "commits": [base.map { String($0.commit.prefix(7)) } ?? "", String(head.commit.prefix(7))],
            "walked": [base?.walked ?? "", head.walked],
            "incomplete": [base?.incomplete ?? [], head.incomplete],
            "counts": counts,
            "combos": combos,
            "size": [Int(maxX), Int(maxY)],
            "groups": groups,
            "screens": screens,
            "edges": flat,
            "changed": changedEdges,
            "findings": (diff?.findings ?? []).filter { $0.status != .still }.map { ["kind": $0.kind, "detail": $0.detail, "status": $0.status.rawValue] },
        ]
        let json = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes])
        var js = Data("window.GREENROOM_MAP = ".utf8)
        js.append(json)
        js.append(Data(";\n".utf8))
        try js.write(to: folder.appendingPathComponent(dataName))
        try Data(MapExportPage.html(title: title).utf8).write(to: folder.appendingPathComponent("index.html"))

        let total = bytes(in: folder)
        print("[greenroom] map-export: wrote \(total) bytes (\(total / 1024) KB) to \(folder.path): \(screens.count) screens, \(fullPaths.count) full pictures, \(thumbPaths.count) thumbnails")
        return total
    }

    /// The bytes of every file under `folder`.
    static func bytes(in folder: URL) -> Int {
        var total = 0
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += v?.fileSize ?? 0 }
        }
        return total
    }

    /// A JPEG of the picture at `url`, `width` pixels wide (as it is when it is narrower), on an opaque background.
    static func thumbnail(of url: URL, width: Int) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = min(width, full.width)
        let h = max(1, Int((Double(full.height) * Double(w) / Double(max(full.width, 1))).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

/// The page. Greenroom's dark stage (Design.swift's stage, ink, accent, difference) as the dark scheme and a quiet paper
/// version of it as the light one, following the viewer's system. Plain JavaScript over `window.GREENROOM_MAP`; text is
/// only ever set with `textContent`.
enum MapExportPage {
    static func html(title: String) -> String {
        let safe = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        return page.replacingOccurrences(of: "__TITLE__", with: safe)
    }

    static let page = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>__TITLE__</title>
<style>
:root{--bg:#121316;--panel:#181a1e;--raise:rgba(255,255,255,.06);--raise2:rgba(255,255,255,.12);--stroke:rgba(255,255,255,.1);--ink:#f2f3f5;--mute:#a4a8b0;--accent:#3dd68c;--on-accent:#06281a;--add:#3dd68c;--rem:#ff5247;--mod:#ffc04d;--nc:#9a93f0;--same:#5d6169;--diff:#ff6fcf;--band:rgba(255,255,255,.035);--card:#1f2126;--dot:rgba(255,255,255,.055)}
@media (prefers-color-scheme:light){:root{--bg:#f4f4f1;--panel:#fff;--raise:rgba(0,0,0,.05);--raise2:rgba(0,0,0,.1);--stroke:rgba(0,0,0,.13);--ink:#16181b;--mute:#5a5f67;--accent:#12905a;--on-accent:#fff;--add:#12905a;--rem:#c9302a;--mod:#9a6200;--nc:#5b4bd6;--same:#9aa0a8;--diff:#c4208f;--band:rgba(0,0,0,.035);--card:#e9e9e5;--dot:rgba(0,0,0,.06)}}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif;display:grid;grid-template-rows:auto minmax(0,1fr);overflow:hidden}
button,input{font:inherit;color:inherit}
button{cursor:pointer}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
h2[tabindex]:focus-visible{outline:0}
header{padding:12px 16px 10px;border-bottom:1px solid var(--stroke)}
h1{font-size:16px;margin:0 0 2px;letter-spacing:.01em}
.names{color:var(--mute);margin:0 0 8px}
.names b{color:var(--ink);font-weight:600}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{border:1px solid var(--stroke);background:var(--raise);border-radius:999px;padding:2px 10px;display:inline-flex;gap:6px;align-items:baseline}
.chip b{font-variant-numeric:tabular-nums}
.chip[aria-pressed=true]{background:var(--raise2);border-color:var(--mute)}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block;background:var(--same);flex:none}
.s-added{--c:var(--add)}.s-removed{--c:var(--rem)}.s-modified{--c:var(--mod)}.s-notCompared{--c:var(--nc)}.s-same,.s-plain{--c:var(--same)}
.dot{background:var(--c)}
.when{color:var(--mute);font-size:12px;margin:8px 0 0}
.warn{margin:8px 0 0;padding:6px 10px;border-radius:8px;border:1px solid var(--mod);color:var(--ink);font-size:12.5px}
.warn b{color:var(--mod)}
.tabs{display:none}
main{display:grid;grid-template-columns:340px minmax(0,1fr);min-height:0}
aside{border-right:1px solid var(--stroke);overflow:auto;min-height:0;padding:8px}
aside h2{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--mute);margin:8px 8px 6px;font-weight:600}
.row{display:block;width:100%;text-align:left;background:none;border:1px solid transparent;border-radius:10px;padding:7px 10px;margin:0 0 2px}
.row:hover{background:var(--raise)}
.row[aria-current=true]{background:var(--raise2);border-color:var(--stroke)}
.row .t{display:flex;gap:8px;align-items:center;font-weight:600}
.row .t span:last-child{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.row .k{font-size:11px;color:var(--c);text-transform:uppercase;letter-spacing:.06em;margin-left:auto;flex:none}
.row .u{color:var(--mute);font-size:12.5px;margin:1px 0 0 16px}
.empty{color:var(--mute);padding:10px}
#stage{position:relative;min-width:0;min-height:0;overflow:hidden;background-image:radial-gradient(var(--dot) 1px,transparent 1px);background-size:22px 22px}
canvas{display:block;width:100%;height:100%;touch-action:none;user-select:none;-webkit-user-select:none;cursor:grab}
canvas.drag{cursor:grabbing}
#tools{position:absolute;left:12px;top:12px;right:12px;display:flex;gap:8px;flex-wrap:wrap;pointer-events:none}
#tools>*{pointer-events:auto}
.bar{display:flex;gap:6px;align-items:center;background:var(--panel);border:1px solid var(--stroke);border-radius:12px;padding:4px}
.bar input[type=search]{background:transparent;border:0;padding:4px 8px;width:210px;outline-offset:0;color:var(--ink)}
.btn{background:var(--raise);border:1px solid var(--stroke);border-radius:8px;padding:3px 10px}
.btn:hover{background:var(--raise2)}
.btn[aria-pressed=true]{background:var(--accent);color:var(--on-accent);border-color:var(--accent)}
#tip{position:absolute;pointer-events:none;background:var(--panel);border:1px solid var(--stroke);border-radius:8px;padding:3px 8px;font-size:12px;max-width:260px;display:none}
#panel{position:absolute;top:0;right:0;bottom:0;width:min(580px,100%);background:var(--panel);border-left:1px solid var(--stroke);overflow:auto;box-shadow:-12px 0 30px rgba(0,0,0,.25)}
#panel[hidden]{display:none}
#panel .in{padding:14px 16px 28px}
.ph{display:flex;gap:8px;align-items:flex-start}
.ph h2{margin:0;font-size:17px;flex:1;overflow-wrap:anywhere}
.badge{display:inline-flex;gap:6px;align-items:center;border:1px solid var(--c);color:var(--c);border-radius:999px;padding:0 9px;font-size:12px;margin:4px 0}
.small{color:var(--mute);font-size:12px;overflow-wrap:anywhere}
.mono{font-family:ui-monospace,Menlo,Consolas,monospace}
.sec{margin:16px 0 0}
.sec h3{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--mute);margin:0 0 6px;font-weight:600}
.seg{display:inline-flex;border:1px solid var(--stroke);border-radius:9px;overflow:hidden;margin:0 6px 8px 0}
.seg button{background:none;border:0;padding:3px 12px;border-right:1px solid var(--stroke)}
.seg button:last-child{border-right:0}
.seg button[aria-pressed=true]{background:var(--raise2);font-weight:600}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:10px;align-items:start}
.pair.one{grid-template-columns:minmax(0,300px)}
figure{margin:0}
figcaption{color:var(--mute);font-size:12px;margin:0 0 4px}
.shot{display:block;width:100%;height:auto;max-height:78vh;object-fit:contain;border-radius:10px;border:1px solid var(--stroke);background:var(--card)}
.wipe{position:relative;max-width:340px;margin:0 auto}
.wipe img{display:block;width:100%;height:auto;border-radius:10px;border:1px solid var(--stroke);background:var(--card)}
.wipe .over{position:absolute;left:0;top:0;height:100%;clip-path:inset(0 0 0 var(--p,50%))}
.wipe .line{position:absolute;top:0;bottom:0;left:var(--p,50%);width:2px;background:var(--diff);pointer-events:none}
.wipe .lab{position:absolute;top:6px;font-size:11px;background:rgba(0,0,0,.6);color:#fff;padding:0 6px;border-radius:6px;pointer-events:none}
input[type=range]{width:100%;max-width:340px;display:block;margin:8px auto 0;accent-color:var(--diff)}
ul.l{margin:0;padding:0;list-style:none}
ul.l li{padding:2px 0 2px 18px;position:relative;overflow-wrap:anywhere}
ul.l li::before{content:attr(data-m);position:absolute;left:2px;font-weight:700;color:var(--c,var(--mute))}
ol.route{margin:0;padding-left:22px}
ol.route li{padding:1px 0}
.link{background:none;border:0;padding:0;color:var(--accent);text-decoration:underline;text-underline-offset:2px;text-align:left}
.nav{display:flex;gap:6px}
::selection{background:var(--accent);color:var(--on-accent)}
@media (max-width:760px){
 body{grid-template-rows:auto auto minmax(0,1fr)}
 .tabs{display:flex;gap:6px;padding:6px 12px;border-bottom:1px solid var(--stroke)}
 .tabs button{flex:1;background:var(--raise);border:1px solid var(--stroke);border-radius:9px;padding:6px}
 .tabs button[aria-pressed=true]{background:var(--accent);color:var(--on-accent);border-color:var(--accent)}
 main{grid-template-columns:minmax(0,1fr)}
 aside{border-right:0}
 body[data-view=map] aside,body[data-view=list] #stage{display:none}
 #panel{position:fixed;inset:0;width:100%;border:0;z-index:5}
 .bar input[type=search]{width:120px}
 #tools{left:8px;right:8px;top:8px}
 .btn{padding:3px 8px}
 header{padding:10px 12px 8px}
 .pair{grid-template-columns:1fr 1fr;gap:6px}
 .names{font-size:13px}
}
@media (prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
</style>
</head>
<body data-view="list">
<header>
 <h1 id="title"></h1>
 <p class="names" id="names"></p>
 <div class="chips" id="chips" role="group" aria-label="Counts"></div>
 <p class="when" id="when"></p>
 <div id="warns"></div>
</header>
<div class="tabs" role="group" aria-label="View"><button id="tabList" aria-pressed="true">Changes</button><button id="tabMap" aria-pressed="false">Map</button></div>
<main>
 <aside aria-label="Changes" id="side"><h2 id="listHead"></h2><div id="list" role="list"></div></aside>
 <section id="stage" aria-label="Screen map">
  <canvas id="cv" tabindex="0" aria-label="Screen map: drag to pan, scroll or pinch to zoom, plus and minus keys zoom, arrow keys pan"></canvas>
  <div id="tools">
   <div class="bar"><input id="q" type="search" placeholder="Search titles and texts" aria-label="Search titles and texts" autocomplete="off"><span class="small" id="qn" aria-live="polite"></span></div>
   <div class="bar"><button class="btn" id="mode" aria-pressed="true" title="Show the changed screens and their neighbours; the rest stay faint">Changes and neighbours</button><button class="btn" id="fit" title="Fit the whole map">Fit all</button><button class="btn" id="fitc" title="Fit the changed screens">Fit changes</button><button class="btn" id="zin" aria-label="Zoom in">+</button><button class="btn" id="zout" aria-label="Zoom out">&minus;</button></div>
  </div>
  <div id="tip" role="presentation"></div>
  <div id="panel" hidden role="dialog" aria-label="Screen"></div>
 </section>
</main>
<noscript><p style="padding:16px">This page needs JavaScript to draw the map.</p></noscript>
<script src="data.js"></script>
<script>
(() => {
'use strict';
const D = window.GREENROOM_MAP;
if (!D) { document.body.textContent = 'data.js did not load.'; return; }
const S = D.screens, N = S.length;
const $ = id => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
const WORD = {added:'Added', removed:'Removed', modified:'Modified', same:'Unchanged', notCompared:'Not compared', plain:'Screen'};
const ORDER = {added:0, removed:1, modified:2, notCompared:3, same:4, plain:5};
const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const phone = matchMedia('(max-width: 760px)');

// ---- data
const isChanged = s => s.st === 'added' || s.st === 'removed' || s.st === 'modified';
const changed = []; S.forEach((s, i) => { if (isChanged(s)) changed.push(i); });
changed.sort((a, b) => ORDER[S[a].st] - ORDER[S[b].st] || S[a].t.localeCompare(S[b].t));
const outs = S.map(() => []), ins = S.map(() => []), adj = S.map(() => new Set());
for (let i = 0; i < D.edges.length; i += 2) { const f = D.edges[i], t = D.edges[i+1]; outs[f].push(t); ins[t].push(f); adj[f].add(t); adj[t].add(f); }
const ceBy = {}; D.changed.forEach(e => { (ceBy[e.f] = ceBy[e.f] || []).push(e); [e.f, e.ht, e.bt].forEach(x => { if (x >= 0) adj[e.f].add(x), (adj[x] = adj[x] || new Set()).add(e.f); }); });
const hay = [];
const haystack = i => hay[i] || (hay[i] = [S[i].t, S[i].a, ...(S[i].tx || []), ...(S[i].ta || []), ...(S[i].tr || [])].join('\n').toLowerCase());
const title = i => i >= 0 ? S[i].t : '';

// ---- words
function pct(v) { return v < 0.01 ? '<0.01' : (+v.toFixed(2)).toString(); }
function counts(i) { const c = {added:0, removed:0, retargeted:0}; (ceBy[i] || []).forEach(e => c[e.st]++); return c; }
function plural(n, w) { return n + ' ' + w + (n === 1 ? '' : 's'); }
function reasons(s, i) {
  if (s.st === 'added') return ['new screen'];
  if (s.st === 'removed') return ['no longer reached'];
  if (s.st === 'notCompared') return [s.why || 'not compared'];
  const out = [];
  (s.rs || []).forEach(r => {
    if (r === 'visual') { const v = Object.values(s.px || {}); out.push(v.length ? 'looks different (' + pct(Math.max(...v)) + '% of pixels)' : 'looks different'); }
    else if (r === 'structure') out.push('layout changed');
    else if (r === 'text') out.push('text: ' + [(s.ta || []).length && (s.ta.length + ' added'), (s.tr || []).length && (s.tr.length + ' removed')].filter(Boolean).join(', '));
    else if (r === 'routes') { const c = counts(i); out.push('controls: ' + [c.added && c.added + ' added', c.removed && c.removed + ' removed', c.retargeted && c.retargeted + ' redirected'].filter(Boolean).join(', ')); }
  });
  return out;
}
function when(iso) { if (!iso) return ''; const d = new Date(iso); return isNaN(d) ? iso : d.toLocaleString([], {dateStyle:'medium', timeStyle:'short'}); }
function stepWords(cmd) { const m = /^tap-text (.*)$/.exec(cmd); return m ? 'Tap “' + m[1] + '”' : cmd; }

// ---- header
document.title = D.title;
$('title').textContent = D.title;
const names = $('names');
if (D.hasBase) {
  const b = el('b', null, D.names[0]); const h = el('b', null, D.names[1]);
  names.append(b, ' (' + D.commits[0] + ')  →  ', h, ' (' + D.commits[1] + ')');
} else { names.append(el('b', null, D.names[1]), D.commits[1] ? ' (' + D.commits[1] + ')' : ''); }
let filter = null;
const chips = $('chips');
function chip(key, label, n) {
  const b = el('button', 'chip s-' + key); b.setAttribute('aria-pressed', 'false'); b.dataset.k = key;
  b.append(el('span', 'dot'), label, el('b', null, String(n)));
  b.addEventListener('click', () => { filter = filter === key ? null : key; chips.querySelectorAll('button').forEach(x => x.setAttribute('aria-pressed', String(x.dataset.k === filter))); renderList(); });
  chips.append(b);
}
if (D.hasBase) { ['added','removed','modified','same','notCompared'].forEach(k => chip(k, WORD[k], D.counts[k] || 0)); }
else { const c = el('span', 'chip', ''); c.append(el('b', null, String(N)), ' screens'); chips.append(c); }
const walked = D.hasBase ? 'Walked: ' + D.names[0] + ' ' + when(D.walked[0]) + ' · ' + D.names[1] + ' ' + when(D.walked[1]) : 'Walked ' + when(D.walked[1]);
$('when').textContent = walked;
[[D.names[0], D.incomplete[0]], [D.names[1], D.incomplete[1]]].forEach(([n, list]) => {
  if (list && list.length) { const w = el('p', 'warn'); w.append(el('b', null, n + ': the walk did not finish. '), list.join('; ')); $('warns').append(w); }
});
(D.findings || []).forEach(f => { const w = el('p', 'warn'); w.append(el('b', null, (f.status === 'new' ? 'New finding' : 'Fixed finding') + ' (' + f.kind + '): '), f.detail.split('\n')[0]); $('warns').append(w); });

// ---- list
let sel = -1, matches = null;
const listEl = $('list');
function row(i) {
  const s = S[i], b = el('button', 'row s-' + s.st); b.dataset.i = i; b.setAttribute('role', 'listitem');
  const t = el('div', 't'); t.append(el('span', 'dot'), el('span', null, s.t), el('span', 'k', WORD[s.st]));
  b.append(t);
  const r = reasons(s, i).join(' · '); if (r) b.append(el('div', 'u', r));
  if (i === sel) b.setAttribute('aria-current', 'true');
  b.addEventListener('click', () => select(i, true));
  return b;
}
function currentList() {
  if (matches) return [...matches];
  if (D.hasBase) return filter ? S.map((_, i) => i).filter(i => S[i].st === filter).sort((a, b) => S[a].t.localeCompare(S[b].t)) : changed;
  return S.map((_, i) => i).sort((a, b) => S[a].dep - S[b].dep || S[a].t.localeCompare(S[b].t));
}
function renderList() {
  const items = currentList();
  $('listHead').textContent = matches ? 'Search results (' + items.length + ')' : D.hasBase ? (filter ? WORD[filter] + ' screens (' + items.length + ')' : 'Changes (' + items.length + ')') : 'Screens (' + items.length + ')';
  listEl.textContent = '';
  if (!items.length) { listEl.append(el('div', 'empty', matches ? 'Nothing matches.' : D.hasBase ? 'No screens changed.' : 'No screens.')); return; }
  const frag = document.createDocumentFragment();
  items.slice(0, 600).forEach(i => frag.append(row(i)));
  if (items.length > 600) frag.append(el('div', 'empty', 'The first 600 of ' + items.length + '. Search to narrow them.'));
  listEl.append(frag);
}
listEl.addEventListener('keydown', e => {
  const rows = [...listEl.querySelectorAll('.row')]; const at = rows.indexOf(document.activeElement); if (at < 0) return;
  const to = e.key === 'ArrowDown' ? at + 1 : e.key === 'ArrowUp' ? at - 1 : e.key === 'Home' ? 0 : e.key === 'End' ? rows.length - 1 : null;
  if (to == null) return; e.preventDefault(); const r = rows[Math.max(0, Math.min(rows.length - 1, to))]; r.focus();
});
function markCurrent() { listEl.querySelectorAll('.row').forEach(r => r.toggleAttribute('aria-current', +r.dataset.i === sel)); }

// ---- canvas
const cv = $('cv'), ctx = cv.getContext('2d');
let C = {}; const Z = {tx:0, ty:0, k:.1}; let W = 1, H = 1, dpr = 1, dirty = false, mode = changed.length ? 'near' : 'all', foc = null, fitK = .1;
function colors() { const cs = getComputedStyle(document.documentElement); const g = n => cs.getPropertyValue('--' + n).trim(); C = {bg:g('bg'), ink:g('ink'), mute:g('mute'), accent:g('accent'), add:g('add'), rem:g('rem'), mod:g('mod'), nc:g('nc'), same:g('same'), diff:g('diff'), band:g('band'), card:g('card'), stroke:g('stroke')}; C.st = {added:C.add, removed:C.rem, modified:C.mod, notCompared:C.nc, same:C.same, plain:C.same}; }
colors(); matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { colors(); invalidate(); });
function invalidate() { if (!dirty) { dirty = true; requestAnimationFrame(draw); } }
function focusSet() {
  if (mode === 'all') { foc = null; return; }
  foc = new Uint8Array(N);
  const add = i => { foc[i] = 1; adj[i].forEach(j => foc[j] = 1); };
  changed.forEach(add); if (sel >= 0) add(sel); if (matches) matches.forEach(i => foc[i] = 1);
}
const imgs = new Map();
function picture(path) {
  let e = imgs.get(path);
  if (!e) { e = {img: new Image(), ok: false, at: 0}; e.img.decoding = 'async'; e.img.onload = () => { e.ok = true; invalidate(); }; e.img.src = path; imgs.set(path, e);
    if (imgs.size > 160) { let old = null; for (const [p, v] of imgs) if (!old || v.at < old[1].at) old = [p, v]; if (old && old[0] !== path) imgs.delete(old[0]); } }
  e.at = performance.now(); return e.ok ? e.img : null;
}
function schemeCombo() { return matchMedia('(prefers-color-scheme: dark)').matches && D.combos.includes('dark') ? 'dark' : D.combos.includes('light') ? 'light' : D.combos[0]; }
function cardPath(s) {
  if (s.th) return s.th;
  const m = s.st === 'removed' ? s.bi : s.hi; if (!m) return null;
  return m[schemeCombo()] || m.light || Object.values(m)[0];
}
const rr = (x, y, w, h, r) => { ctx.beginPath(); if (ctx.roundRect) ctx.roundRect(x, y, w, h, r); else ctx.rect(x, y, w, h); };
function curve(a, b, color, width, dash, arrow) {
  const A = S[a], B = S[b]; const fw = B.x > A.x + A.w / 2;
  const x1 = fw ? A.x + A.w : A.x, y1 = A.y + A.h / 2, x2 = fw ? B.x : B.x + B.w, y2 = B.y + B.h / 2, d = Math.max(40, Math.abs(x2 - x1) * .4) * (fw ? 1 : -1);
  ctx.strokeStyle = color; ctx.fillStyle = color; ctx.lineWidth = width / Z.k; ctx.setLineDash(dash ? [6 / Z.k, 4 / Z.k] : []);
  ctx.beginPath(); ctx.moveTo(x1, y1); ctx.bezierCurveTo(x1 + d, y1, x2 - d, y2, x2, y2); ctx.stroke(); ctx.setLineDash([]);
  if (arrow) { const s = 7 / Z.k, dx = fw ? 1 : -1; ctx.beginPath(); ctx.moveTo(x2, y2); ctx.lineTo(x2 - dx * s * 1.6, y2 - s * .6); ctx.lineTo(x2 - dx * s * 1.6, y2 + s * .6); ctx.fill(); }
}
function draw() {
  dirty = false;
  const rect = cv.getBoundingClientRect(); const w = Math.max(1, rect.width), h = Math.max(1, rect.height), r = Math.min(2, devicePixelRatio || 1);
  if (w !== W || h !== H || r !== dpr) { W = w; H = h; dpr = r; cv.width = Math.round(w * r); cv.height = Math.round(h * r); }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, W, H);
  const k = Z.k; ctx.translate(Z.tx, Z.ty); ctx.scale(k, k);
  const x0 = -Z.tx / k, y0 = -Z.ty / k, x1 = (W - Z.tx) / k, y1 = (H - Z.ty) / k;
  // bands
  ctx.font = '600 ' + Math.max(12, Math.min(26, 13)) / k + 'px system-ui,sans-serif'; ctx.textBaseline = 'bottom'; ctx.textAlign = 'left'; ctx.lineJoin = 'round';
  D.groups.forEach(g => {
    if (g.x > x1 || g.y > y1 || g.x + g.w < x0 || g.y + g.h < y0) return;
    ctx.fillStyle = C.band; rr(g.x, g.y, g.w, g.h, 14); ctx.fill();
    ctx.lineWidth = 3 / k; ctx.strokeStyle = C.bg; ctx.strokeText(g.t, g.x + 4 / k, g.y - 4 / k); ctx.fillStyle = C.mute; ctx.fillText(g.t, g.x + 4 / k, g.y - 4 / k);
  });
  // edges
  D.changed.forEach(e => {
    if (e.st === 'added') { if (e.ht >= 0) curve(e.f, e.ht, C.add, 2, false, true); }
    else if (e.st === 'removed') { if (e.bt >= 0) curve(e.f, e.bt, C.rem, 2, true, true); }
    else { if (e.bt >= 0) curve(e.f, e.bt, C.rem, 1.5, true, false); if (e.ht >= 0) curve(e.f, e.ht, C.mod, 2, false, true); }
  });
  if (sel >= 0) { outs[sel].forEach(t => curve(sel, t, C.accent, 1.5, false, true)); ins[sel].forEach(f => curve(f, sel, C.mute, 1.2, false, true)); }
  // screens
  const pw = S.length ? S[0].w * k : 0, q = matches;
  ctx.textBaseline = 'alphabetic'; ctx.textAlign = 'center';
  for (let i = 0; i < N; i++) {
    const s = S[i]; if (s.x > x1 || s.y > y1 || s.x + s.w < x0 || s.y + s.h < y0 - 20 / k) continue;
    const ch = isChanged(s), inFocus = !foc || foc[i], hit = q && q.has(i), dim = (q && !hit) || !inFocus;
    const col = C.st[s.st];
    if (pw < 6) {
      ctx.globalAlpha = dim ? .2 : ch ? 1 : .6; ctx.fillStyle = col; const mw = Math.max(s.w, 3 / k), mh = Math.max(s.h, 6 / k); ctx.fillRect(s.x, s.y, mw, mh);
      if (hit) { ctx.globalAlpha = 1; ctx.fillStyle = C.diff; ctx.fillRect(s.x - mw * .3, s.y - mh * .1, mw * 1.6, mh * 1.2); }
      if (i === sel) { ctx.globalAlpha = 1; ctx.strokeStyle = C.accent; ctx.lineWidth = 2 / k; ctx.strokeRect(s.x - 4 / k, s.y - 4 / k, s.w + 8 / k, s.h + 8 / k); }
      continue;
    }
    ctx.globalAlpha = dim ? .28 : s.st === 'removed' ? .75 : 1;
    ctx.fillStyle = C.card; rr(s.x, s.y, s.w, s.h, 8 / k > 6 ? 6 : 8 / k * 1); ctx.fill();
    if (pw >= 40 && !dim) {
      const p = cardPath(s), im = p && picture(p);
      if (im) { const pad = 3, r2 = im.width / im.height, bw = s.w - pad * 2, bh = s.h - pad * 2; let dw = bw, dh = bw / r2; if (dh > bh) { dh = bh; dw = bh * r2; } ctx.save(); rr(s.x, s.y, s.w, s.h, 6); ctx.clip(); ctx.drawImage(im, s.x + (s.w - dw) / 2, s.y + (s.h - dh) / 2, dw, dh); ctx.restore(); }
    }
    ctx.strokeStyle = col; ctx.lineWidth = (ch ? 2.5 : 1) / k; ctx.setLineDash(s.st === 'removed' ? [6 / k, 4 / k] : []); rr(s.x, s.y, s.w, s.h, 6); ctx.stroke(); ctx.setLineDash([]);
    if (hit) { ctx.globalAlpha = 1; ctx.strokeStyle = C.diff; ctx.lineWidth = 3 / k; rr(s.x - 4 / k, s.y - 4 / k, s.w + 8 / k, s.h + 8 / k, 8 / k); ctx.stroke(); }
    if (i === sel) { ctx.globalAlpha = 1; ctx.strokeStyle = C.accent; ctx.lineWidth = 3 / k; rr(s.x - 5 / k, s.y - 5 / k, s.w + 10 / k, s.h + 10 / k, 9 / k); ctx.stroke(); }
    if (pw >= 24 && ch) { ctx.globalAlpha = dim ? .28 : 1; const g = {added:'+', removed:'−', modified:'~'}[s.st], rad = 9 / k; ctx.fillStyle = col; ctx.beginPath(); ctx.arc(s.x + s.w - rad * .6, s.y + rad * .6, rad, 0, 6.3); ctx.fill(); ctx.fillStyle = C.bg; ctx.font = '700 ' + 13 / k + 'px system-ui'; ctx.textBaseline = 'middle'; ctx.fillText(g, s.x + s.w - rad * .6, s.y + rad * .6 + .5 / k); ctx.textBaseline = 'alphabetic'; }
    if (pw >= 44) { ctx.globalAlpha = dim ? .35 : 1; ctx.fillStyle = ch ? C.ink : C.mute; ctx.font = (ch ? '600 ' : '') + 12 / k + 'px system-ui,sans-serif'; const room = Math.floor((s.w + 100) * k / 6.4); ctx.fillText(s.t.length > room ? s.t.slice(0, Math.max(3, room - 1)) + '…' : s.t, s.x + s.w / 2, s.y + s.h + 15 / k); }
  }
  ctx.globalAlpha = 1;
}
function view(tx, ty, k) { Z.k = Math.max(fitK * .5, Math.min(4, k)); Z.tx = tx; Z.ty = ty; invalidate(); }
function zoomAt(cx, cy, f) { const k = Math.max(fitK * .5, Math.min(4, Z.k * f)), r = k / Z.k; view(cx - (cx - Z.tx) * r, cy - (cy - Z.ty) * r, k); }
function fitBox(x0, y0, x1, y1, pad = 40) {
  const r = cv.getBoundingClientRect(); const w = r.width, h = r.height, bw = x1 - x0 + pad * 2, bh = y1 - y0 + pad * 2;
  const k = Math.min(w / bw, h / bh, 1.2); view((w - (x1 - x0) * k) / 2 - x0 * k, (h - (y1 - y0) * k) / 2 - y0 * k, k);
}
function fitAll() { fitBox(0, 0, D.size[0], D.size[1], 10); }
function fitChanges() {
  if (!changed.length) return fitAll(); let a = 1e9, b = 1e9, c = -1e9, d = -1e9;
  changed.forEach(i => { const s = S[i]; a = Math.min(a, s.x); b = Math.min(b, s.y); c = Math.max(c, s.x + s.w); d = Math.max(d, s.y + s.h); }); fitBox(a, b, c, d);
}
let anim = 0;
function flyTo(cx, cy, k, offsetRight) {
  const r = cv.getBoundingClientRect(); const free = Math.max(120, r.width - offsetRight);
  const tx = free / 2 - cx * k, ty = r.height / 2 - cy * k, from = {...Z}; k = Math.max(fitK * .5, Math.min(4, k));
  if (reduce) { view(tx, ty, k); return; }
  const t0 = performance.now(), id = ++anim;
  const step = now => { if (id !== anim) return; const u = Math.min(1, (now - t0) / 260), e = 1 - Math.pow(1 - u, 3); Z.k = from.k + (k - from.k) * e; Z.tx = from.tx + (tx - from.tx) * e; Z.ty = from.ty + (ty - from.ty) * e; invalidate(); if (u < 1) requestAnimationFrame(step); };
  requestAnimationFrame(step);
}
function resize() { const r = cv.getBoundingClientRect(); fitK = Math.min(r.width / (D.size[0] + 20), r.height / (D.size[1] + 20)); invalidate(); }
new ResizeObserver(resize).observe(cv);
function at(px, py) {
  const x = (px - Z.tx) / Z.k, y = (py - Z.ty) / Z.k, m = Math.max(0, 3 / Z.k - 0) ;
  for (let i = N - 1; i >= 0; i--) { const s = S[i], w = Math.max(s.w, 3 / Z.k), h = Math.max(s.h, 6 / Z.k); if (x >= s.x - m && x <= s.x + w + m && y >= s.y - m && y <= s.y + h + m) return i; }
  return -1;
}
// pointers
const ptrs = new Map(); let moved = 0, pinch = 0;
cv.addEventListener('pointerdown', e => { cv.setPointerCapture(e.pointerId); ptrs.set(e.pointerId, [e.offsetX, e.offsetY]); moved = 0; if (ptrs.size === 2) { const [a, b] = [...ptrs.values()]; pinch = Math.hypot(a[0] - b[0], a[1] - b[1]); } cv.classList.add('drag'); anim++; });
cv.addEventListener('pointermove', e => {
  const p = ptrs.get(e.pointerId);
  if (!p) { const i = at(e.offsetX, e.offsetY), t = $('tip'); if (i >= 0) { t.textContent = S[i].t + ' · ' + WORD[S[i].st]; t.style.display = 'block'; t.style.left = Math.min(e.offsetX + 14, W - 200) + 'px'; t.style.top = (e.offsetY + 16) + 'px'; cv.style.cursor = 'pointer'; } else { t.style.display = 'none'; cv.style.cursor = ''; } return; }
  const dx = e.offsetX - p[0], dy = e.offsetY - p[1]; moved += Math.abs(dx) + Math.abs(dy); p[0] = e.offsetX; p[1] = e.offsetY;
  if (ptrs.size === 1) view(Z.tx + dx, Z.ty + dy, Z.k);
  else if (ptrs.size === 2) { const [a, b] = [...ptrs.values()], d = Math.hypot(a[0] - b[0], a[1] - b[1]); if (pinch > 0) zoomAt((a[0] + b[0]) / 2, (a[1] + b[1]) / 2, d / pinch); pinch = d; }
});
const up = e => { const was = ptrs.has(e.pointerId); ptrs.delete(e.pointerId); if (!ptrs.size) cv.classList.remove('drag'); pinch = 0; if (was && e.type === 'pointerup' && moved < 6 && !ptrs.size) { const i = at(e.offsetX, e.offsetY); if (i >= 0) select(i, false); else close(); } };
cv.addEventListener('pointerup', up); cv.addEventListener('pointercancel', up);
cv.addEventListener('pointerleave', () => { $('tip').style.display = 'none'; });
cv.addEventListener('wheel', e => { e.preventDefault(); zoomAt(e.offsetX, e.offsetY, Math.exp(-e.deltaY * (e.ctrlKey ? .01 : .0016))); anim++; }, {passive: false});
cv.addEventListener('keydown', e => {
  const r = cv.getBoundingClientRect(), s = 60;
  if (e.key === '+' || e.key === '=') zoomAt(r.width / 2, r.height / 2, 1.3); else if (e.key === '-') zoomAt(r.width / 2, r.height / 2, 1 / 1.3); else if (e.key === '0') fitAll();
  else if (e.key === 'ArrowLeft') view(Z.tx + s, Z.ty, Z.k); else if (e.key === 'ArrowRight') view(Z.tx - s, Z.ty, Z.k); else if (e.key === 'ArrowUp') view(Z.tx, Z.ty + s, Z.k); else if (e.key === 'ArrowDown') view(Z.tx, Z.ty - s, Z.k); else return;
  e.preventDefault();
});
$('zin').onclick = () => { const r = cv.getBoundingClientRect(); zoomAt(r.width / 2, r.height / 2, 1.4); };
$('zout').onclick = () => { const r = cv.getBoundingClientRect(); zoomAt(r.width / 2, r.height / 2, 1 / 1.4); };
$('fit').onclick = fitAll; $('fitc').onclick = fitChanges;
const modeBtn = $('mode');
if (!changed.length) modeBtn.hidden = $('fitc').hidden = true;
modeBtn.onclick = () => { mode = mode === 'near' ? 'all' : 'near'; modeBtn.setAttribute('aria-pressed', String(mode === 'near')); modeBtn.textContent = mode === 'near' ? 'Changes and neighbours' : 'Everything'; focusSet(); invalidate(); };
if (mode === 'all') modeBtn.setAttribute('aria-pressed', 'false');

// ---- search
let qt = 0;
$('q').addEventListener('input', () => { clearTimeout(qt); qt = setTimeout(search, 120); });
$('q').addEventListener('keydown', e => { if (e.key === 'Enter') { const f = [...(matches || [])][0]; if (f != null) select(f, true); } });
function search() {
  const words = $('q').value.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) { matches = null; $('qn').textContent = ''; }
  else { matches = new Set(); for (let i = 0; i < N; i++) { const h = haystack(i); if (words.every(w => h.includes(w))) matches.add(i); } $('qn').textContent = plural(matches.size, 'match'); }
  focusSet(); renderList(); invalidate();
  if (matches && matches.size && matches.size < 40) { let a = 1e9, b = 1e9, c = -1e9, d = -1e9; matches.forEach(i => { const s = S[i]; a = Math.min(a, s.x); b = Math.min(b, s.y); c = Math.max(c, s.x + s.w); d = Math.max(d, s.y + s.h); }); fitBox(a, b, c, d, 120); }
}

// ---- panel
const panel = $('panel'); let pm = {mode: 'side', combo: null};
function select(i, fly) {
  sel = i; focusSet(); markCurrent(); renderPanel(); invalidate();
  try { history.replaceState(null, '', '#' + encodeURIComponent(S[i].k)); } catch (e) {}
  if (fly && !phone.matches) { const s = S[i]; flyTo(s.x + s.w / 2, s.y + s.h / 2, Math.max(Z.k, .7), Math.min(580, W)); }
  if (fly && phone.matches) invalidate();
}
function close() {
  if (sel < 0 && panel.hidden) return; const had = sel; sel = -1; panel.hidden = true; focusSet(); markCurrent(); invalidate();
  try { history.replaceState(null, '', location.pathname + location.search); } catch (e) {}
  const r = listEl.querySelector('.row[data-i="' + had + '"]'); if (r && !phone.matches) r.focus(); else if (phone.matches) cv.focus();
}
function link(i, text) { if (i < 0) return el('span', null, text); const b = el('button', 'link', text); b.onclick = () => select(i, true); return b; }
function sec(name, body) { const s = el('div', 'sec'); s.append(el('h3', null, name)); s.append(body); return s; }
function shot(src, alt, cls) { const im = el('img', cls || 'shot'); im.alt = alt; im.decoding = 'async'; im.src = src; return im; }
function fig(label, src, alt) { const f = el('figure'); f.append(el('figcaption', null, label), shot(src, alt)); return f; }
function renderPanel() {
  const i = sel, s = S[i]; panel.hidden = false; panel.textContent = ''; panel.scrollTop = 0;
  const box = el('div', 'in'); panel.append(box);
  const head = el('div', 'ph'); const h2 = el('h2', null, s.t); h2.tabIndex = -1; head.append(h2);
  const nav = el('div', 'nav'); const pos = changed.indexOf(i);
  const mk = (label, aria, to) => { const b = el('button', 'btn', label); b.setAttribute('aria-label', aria); b.disabled = to == null; b.onclick = () => select(to, true); return b; };
  if (D.hasBase && pos >= 0) nav.append(mk('‹', 'Previous change', pos > 0 ? changed[pos - 1] : null), mk('›', 'Next change', pos < changed.length - 1 ? changed[pos + 1] : null));
  const x = el('button', 'btn', 'Close'); x.setAttribute('aria-label', 'Close (Escape)'); x.onclick = close; nav.append(x);
  head.append(nav); box.append(head);
  const badge = el('span', 'badge s-' + s.st); badge.append(el('span', 'dot'), WORD[s.st]); box.append(badge);
  const rs = reasons(s, i).join(' · '); if (rs) box.append(el('div', null, rs));
  const ids = el('div', 'small mono'); ids.textContent = s.a + (s.bid && s.hid && s.bid !== s.hid ? '  ' + s.bid + ' → ' + s.hid : '  ' + (s.hid || s.bid)); box.append(ids);
  if (s.flaky) box.append(el('div', 'small', 'Flaky: ' + s.flaky));

  // pictures
  const combos = [...new Set([...Object.keys(s.hi || {}), ...Object.keys(s.bi || {})])].sort();
  if (s.th) {
    const b = el('div', 'pair one'); b.append(fig('Head (small picture; the export keeps full size only for changes)', s.th, s.t)); box.append(sec('Picture', b));
  } else if (combos.length) {
    if (!pm.combo || !combos.includes(pm.combo)) pm.combo = combos.includes(schemeCombo()) ? schemeCombo() : combos[0];
    const c = pm.combo, bi = (s.bi || {})[c], hi = (s.hi || {})[c], df = (s.df || {})[c];
    const modes = [['side', 'Side by side']]; if (bi && hi) modes.push(['wipe', 'Wipe']); if (df) modes.push(['diff', 'Difference']);
    if (!modes.some(m => m[0] === pm.mode)) pm.mode = 'side';
    const ctl = el('div');
    if (combos.length > 1) { const g = el('div', 'seg'); combos.forEach(n => { const b = el('button', null, n[0].toUpperCase() + n.slice(1)); b.setAttribute('aria-pressed', String(n === c)); b.onclick = () => { pm.combo = n; renderPanel(); }; g.append(b); }); ctl.append(g); }
    if (modes.length > 1) { const g = el('div', 'seg'); modes.forEach(([m, l]) => { const b = el('button', null, l); b.setAttribute('aria-pressed', String(m === pm.mode)); b.onclick = () => { pm.mode = m; renderPanel(); }; g.append(b); }); ctl.append(g); }
    const body = el('div');
    if (pm.mode === 'wipe' && bi && hi) {
      const w = el('div', 'wipe'); const over = shot(hi, 'Head'); over.className = 'over'; const l = el('div', 'line'), a = el('span', 'lab', D.names[0]), b = el('span', 'lab', D.names[1]); a.style.left = '6px'; b.style.right = '6px';
      w.append(shot(bi, 'Base'), over, l, a, b); const r = document.createElement('input'); r.type = 'range'; r.min = 0; r.max = 100; r.value = 50; r.setAttribute('aria-label', 'Wipe between ' + D.names[0] + ' and ' + D.names[1]);
      r.oninput = () => w.style.setProperty('--p', r.value + '%'); body.append(w, r);
    } else if (pm.mode === 'diff' && df) {
      const f = fig('Difference' + (s.px && s.px[c] != null ? ': ' + pct(s.px[c]) + '% of pixels' : ''), df, 'Difference'); f.style.maxWidth = '340px'; body.append(f);
    } else {
      const p = el('div', 'pair' + (bi && hi ? '' : ' one')); if (bi) p.append(fig(D.names[0], bi, 'Base')); if (hi) p.append(fig(D.names[1], hi, 'Head')); body.append(p);
    }
    if ((s.dz || []).includes(c)) body.append(el('p', 'small', 'The two pictures are different sizes, so there is no difference image.'));
    box.append(sec('Picture', (() => { const d = el('div'); d.append(ctl, body); return d; })()));
  }
  // texts
  if ((s.ta || []).length || (s.tr || []).length) {
    const u = el('ul', 'l'); (s.ta || []).forEach(t => { const li = el('li', null, t); li.dataset.m = '+'; li.style.setProperty('--c', 'var(--add)'); u.append(li); }); (s.tr || []).forEach(t => { const li = el('li', null, t); li.dataset.m = '−'; li.style.setProperty('--c', 'var(--rem)'); u.append(li); }); box.append(sec('Text added and removed', u));
  } else if ((s.tx || []).length) { const u = el('ul', 'l'); s.tx.forEach(t => { const li = el('li', null, t); li.dataset.m = '·'; u.append(li); }); box.append(sec('Text on the screen', u)); }
  // controls
  const ce = ceBy[i] || [];
  if (ce.length) {
    const u = el('ul', 'l');
    ce.forEach(e => {
      const li = el('li'); const where = (t, p) => t >= 0 ? link(t, S[t].t) : el('span', null, p === 'UNFOLLOWED' ? 'nothing (not followed)' : p || 'somewhere else');
      if (e.st === 'added') { li.dataset.m = '+'; li.style.setProperty('--c', 'var(--add)'); li.append('Added: ' + e.a + ' → ', where(e.ht, e.hp)); }
      else if (e.st === 'removed') { li.dataset.m = '−'; li.style.setProperty('--c', 'var(--rem)'); li.append('Removed: ' + e.a + ' → ', where(e.bt, e.bp)); }
      else { li.dataset.m = '~'; li.style.setProperty('--c', 'var(--mod)'); li.append('Redirected: ' + e.a + ' used to open ', where(e.bt, e.bp), ', now opens ', where(e.ht, e.hp)); }
      u.append(li);
    });
    box.append(sec('Controls', u));
  }
  // route
  const o = el('ol', 'route'); o.append(el('li', null, s.start ? 'Open the link ' + s.start : 'Open the app'));
  (s.steps || []).forEach(t => o.append(el('li', null, stepWords(t)))); o.append(el('li', null, 'You are on “' + s.t + '”'));
  box.append(sec('How to get there', o));
  if (s.why) box.append(el('p', 'small', s.why));
  if (!phone.matches) setTimeout(() => { if (sel === i && !panel.contains(document.activeElement)) h2.focus({preventScroll: true}); }, 0);
}
document.addEventListener('keydown', e => {
  if (e.key !== 'Escape') return;
  if (!panel.hidden) { close(); e.preventDefault(); } else if ($('q').value) { $('q').value = ''; search(); }
});

// ---- phone tabs
function setView(v) { document.body.dataset.view = v; $('tabList').setAttribute('aria-pressed', String(v === 'list')); $('tabMap').setAttribute('aria-pressed', String(v === 'map')); if (v === 'map') { resize(); if (needFit) { needFit = false; fitInitial(); } invalidate(); } }
$('tabList').onclick = () => setView('list'); $('tabMap').onclick = () => setView('map');
const sync = () => { if (!phone.matches) document.body.dataset.view = 'both'; else if (document.body.dataset.view === 'both') setView('list'); resize(); };
phone.addEventListener('change', sync);
// the tab a person tapped a row on: on a phone a row opens the panel over the list; the map tab shows the map

// ---- go
window.mapView = {draw, zoomAt, fitAll, view: Z};  // for timing the drawing by hand
focusSet(); renderList(); sync();
let needFit = false;
function fitInitial() { if (mode === 'near' && changed.length) fitChanges(); else fitAll(); }
requestAnimationFrame(() => { resize(); if (cv.getBoundingClientRect().width < 10) needFit = true; else fitInitial(); });
const hash = decodeURIComponent((location.hash || '').slice(1));
if (hash) { const i = S.findIndex(s => s.k === hash); if (i >= 0) setTimeout(() => select(i, true), 60); }
else if (D.hasBase && changed.length && !phone.matches) { /* open on the list; nothing selected */ }
})();
</script>
</body>
</html>
"""#
}
