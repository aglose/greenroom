// Renders Resources/AppIcon.svg and writes Resources/AppIcon.icns and plugin/icon.png:
// `swift scripts/make-icon.swift` from the repository root.
// A phone on stage in a beam of light, connected from the wings to a terminal. WebKit draws the SVG, because
// NSImage's SVG support leaves out the blur filters the beam and the glow need.
// `--debug`: the debug build's icon, the same on an orange stage, written to Resources/AppIcon-debug.icns
// (scripts/bundle.sh --variant debug).
import AppKit
import WebKit

let debug = CommandLine.arguments.contains("--debug")
let name = debug ? "AppIcon-debug" : "AppIcon"
var svg = try String(contentsOfFile: "Resources/AppIcon.svg", encoding: .utf8)
if debug {
    // The backdrop, the stage floor and its boards, from green to orange.
    for (green, orange) in [("#0e2c21", "#c8601a"), ("#030f09", "#5c2a08"), ("#0b1d16", "#4a2206"), ("#132b21", "#6e3510")] {
        svg = svg.replacingOccurrences(of: green, with: orange)
    }
}

@MainActor final class Renderer: NSObject, WKNavigationDelegate {
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    var loaded: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = self
    }

    func load() async {
        let html = "<html><body style='margin:0;background:transparent'>\(svg.replacingOccurrences(of: "width=\"1024\" height=\"1024\"", with: "width=\"1024\" height=\"1024\" style=\"display:block\""))</body></html>"
        await withCheckedContinuation { loaded = $0; view.loadHTMLString(html, baseURL: nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in loaded?.resume(); loaded = nil }
    }

    /// The icon at `pixels` square, as PNG data.
    func png(_ pixels: Int) async throws -> Data {
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        config.snapshotWidth = NSNumber(value: Double(pixels) / (NSScreen.main?.backingScaleFactor ?? 2))
        let image = try await view.takeSnapshot(configuration: config)
        // Redraw at exactly `pixels` so the result does not depend on the screen's scale.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}

@MainActor func run() async throws {
    let renderer = Renderer()
    await renderer.load()

    let out = URL(fileURLWithPath: "build/\(name).iconset")
    try? FileManager.default.removeItem(at: out)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let file = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try await renderer.png(points * scale).write(to: out.appendingPathComponent(file))
    }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", out.path, "-o", "Resources/\(name).icns"]
    try p.run(); p.waitUntilExit()
    print(p.terminationStatus == 0 ? "wrote Resources/\(name).icns" : "iconutil failed")

    // The Claude Code plugin's icon (plugin.json "icon"), for the plugin directory.
    if !debug {
        try await renderer.png(512).write(to: URL(fileURLWithPath: "plugin/icon.png"))
        print("wrote plugin/icon.png")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    do { try await run(); exit(0) } catch { print("make-icon failed: \(error)"); exit(1) }
}
app.run()
