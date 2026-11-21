// Draws the app icon and writes Resources/AppIcon.icns: `swift scripts/make-icon.swift` from the repository root.
// A dressing-room mirror with its bulbs, where the mirror is a phone. `--debug`: the debug build's icon, the same on an
// orange plate, written to Resources/AppIcon-debug.icns (scripts/bundle.sh --variant debug).
import AppKit

let debug = CommandLine.arguments.contains("--debug")

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }

    // The plate: Apple's icon grid, 824 pt inside 1024 with a continuous-looking corner.
    let plate = NSRect(x: 100*s, y: 100*s, width: 824*s, height: 824*s)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 186*s, yRadius: 186*s)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24*s; shadow.shadowOffset = NSSize(width: 0, height: -10*s)
    NSGraphicsContext.saveGraphicsState(); shadow.set(); (debug ? c(92, 44, 10) : c(16, 68, 50)).setFill(); platePath.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: debug ? [c(246, 146, 48), c(204, 96, 22), c(132, 58, 12)] : [c(38, 140, 96), c(18, 84, 60), c(10, 52, 40)])!.draw(in: platePath, angle: -90)

    // The phone.
    let phone = NSRect(x: 357*s, y: 232*s, width: 310*s, height: 560*s)
    let phonePath = NSBezierPath(roundedRect: phone, xRadius: 58*s, yRadius: 58*s)
    c(8, 34, 27).setFill(); phonePath.fill()
    let screen = phone.insetBy(dx: 20*s, dy: 20*s)
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: 40*s, yRadius: 40*s)
    NSGradient(colors: [c(214, 255, 226), c(120, 226, 164)])!.draw(in: screenPath, angle: -90)
    c(8, 34, 27, 0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: 472*s, y: 724*s, width: 80*s, height: 22*s), xRadius: 11*s, yRadius: 11*s).fill()

    // The bulbs, five a side.
    for side in [CGFloat(248), CGFloat(776)] {
        for i in 0..<5 {
            let y = (300 + CGFloat(i) * 106) * s, x = side * s, r = 30 * s
            let glow = NSGradient(colors: [c(255, 236, 170, 0.55), c(255, 236, 170, 0)])!
            glow.draw(in: NSBezierPath(ovalIn: NSRect(x: x - 2.4*r, y: y - 2.4*r, width: 4.8*r, height: 4.8*r)), relativeCenterPosition: .zero)
            NSGradient(colors: [c(255, 252, 235), c(255, 220, 130)])!
                .draw(in: NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2*r, height: 2*r)), relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let name = debug ? "AppIcon-debug" : "AppIcon"
let out = URL(fileURLWithPath: "build/\(name).iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try draw(CGFloat(points * scale)).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", out.path, "-o", "Resources/\(name).icns"]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/\(name).icns" : "iconutil failed")
