// Draws the app icon and writes Resources/AppIcon.icns: `swift scripts/make-icon.swift` from the repository root.
// The green room's door, ajar, with a star on it and the room's green light spilling out onto the floor. No phone in
// it: Greenroom runs whatever app it is given. Colours are the app's own (Design.swift): a graphite stage and its
// green accent. Drawn on a 1024-unit grid; every size is rendered from the same paths.
// `swift scripts/make-icon.swift --png FILE` writes one 1024 px picture instead, for looking at.
import AppKit

func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

/// A soft light: full colour at the centre fading to nothing at `radius`, with no edge (NSGradient's radial fill stops
/// at its path's edge, which showed as a disc).
func glow(_ center: NSPoint, _ radius: CGFloat, _ color: NSColor, squash: CGFloat = 1) {
    guard let ctx = NSGraphicsContext.current?.cgContext,
          let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                             colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) else { return }
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y); ctx.scaleBy(x: 1, y: squash)
    ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
    ctx.restoreGState()
}

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let t = NSAffineTransform(); t.scale(by: size / 1024); t.concat()

    let accent = c(0x3DD68C), light = c(0xB4F7D2), lowLight = c(0x1B9A60)

    // The plate: Apple's icon grid, 824 inside 1024, graphite with a faint top light, a hairline rim, a drop shadow.
    let plateRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    c(0x101215).setFill(); plate.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [c(0x2B2F36), c(0x121418)])!.draw(in: plate, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    let door = NSRect(x: 338, y: 250, width: 360, height: 540)   // the doorway
    // The room's light: a soft glow round the doorway and a spill on the floor, widening towards the viewer.
    glow(NSPoint(x: door.midX, y: door.midY), 360, accent.withAlphaComponent(0.34), squash: 1.15)
    let spill = NSBezierPath()
    spill.move(to: NSPoint(x: door.minX + 118, y: door.minY)); spill.line(to: NSPoint(x: door.maxX, y: door.minY))
    spill.line(to: NSPoint(x: 940, y: 90)); spill.line(to: NSPoint(x: 330, y: 90)); spill.close()
    NSGradient(colors: [accent.withAlphaComponent(0.62), accent.withAlphaComponent(0)])!.draw(in: spill, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The frame (casing) round the doorway, then the lit room inside it.
    let casing = NSBezierPath(roundedRect: door.insetBy(dx: -22, dy: -22), xRadius: 34, yRadius: 34)
    NSGradient(colors: [c(0x3A3F47), c(0x1C1F24)])!.draw(in: casing, angle: -90)
    let opening = NSBezierPath(roundedRect: door, xRadius: 16, yRadius: 16)
    NSGradient(colors: [light, accent, lowLight])!.draw(in: opening, angle: -90)

    // The door, swung in on its left hinges: its far edge shorter (perspective), lit along the edge by the room.
    let edgeX = door.minX + 132
    let slab = NSBezierPath()
    slab.move(to: NSPoint(x: door.minX, y: door.minY)); slab.line(to: NSPoint(x: edgeX, y: door.minY + 40))
    slab.line(to: NSPoint(x: edgeX, y: door.maxY - 40)); slab.line(to: NSPoint(x: door.minX, y: door.maxY)); slab.close()
    NSGradient(colors: [c(0x353A42), c(0x1A1D22)])!.draw(in: slab, angle: 0)
    let edge = NSBezierPath(); edge.lineWidth = 9
    edge.move(to: NSPoint(x: edgeX, y: door.minY + 40)); edge.line(to: NSPoint(x: edgeX, y: door.maxY - 40))
    light.withAlphaComponent(0.85).setStroke(); edge.stroke()
    // A handle near the free edge.
    c(0xC9CDD3).setFill()
    NSBezierPath(roundedRect: NSRect(x: edgeX - 34, y: door.midY - 20, width: 20, height: 40), xRadius: 10, yRadius: 10).fill()

    // The star, large enough to stay a star at 32 px, with a little warm glow.
    let sc = NSPoint(x: door.minX + 64, y: door.maxY - 150)
    NSGraphicsContext.saveGraphicsState(); slab.addClip()
    glow(sc, 70, c(0xFFD27A, 0.40))
    NSGraphicsContext.restoreGraphicsState()
    let star = NSBezierPath()
    for k in 0..<10 {
        let r: CGFloat = k % 2 == 0 ? 46 : 19, a = CGFloat.pi / 2 + CGFloat(k) * .pi / 5
        let p = NSPoint(x: sc.x + r * cos(a), y: sc.y + r * sin(a))
        k == 0 ? star.move(to: p) : star.line(to: p)
    }
    star.close()
    NSGradient(colors: [c(0xFFE7A8), c(0xF5B940)])!.draw(in: star, angle: -90)

    // The plate's rim last, over everything.
    let rim = NSBezierPath(roundedRect: plateRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    rim.lineWidth = 3; NSColor(white: 1, alpha: 0.10).setStroke(); rim.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--png" {
    try draw(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

let out = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try draw(CGFloat(points * scale)).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", out.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
