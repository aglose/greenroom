// Renders the icon masters in Resources/Icons/masters/*.png onto Apple's macOS icon grid (824x824 continuous squircle
// inside 1024x1024) and writes:
//   - Resources/Icons/<id>.icns and Resources/Icons/<id>-debug.icns for each selectable icon
//   - Resources/AppIcon.icns and Resources/AppIcon-debug.icns (Studio Bay, the default)
//   - plugin/icon.png (512x512 Studio Bay for the Claude Code plugin)
// Run `swift scripts/make-icon.swift` from the repository root. Pass `--debug` to build only the debug icons.
import AppKit
import CoreImage
import QuartzCore

let icons = ["studio-bay", "liquid-glass", "spotlight"]
let defaultIcon = "studio-bay"
let onlyDebug = CommandLine.arguments.contains("--debug")
let variants: [Bool] = onlyDebug ? [true] : [false, true]
let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

/// Shifts the emerald green palette toward Variant.debugColor's warm amber-orange while leaving neutral greys intact.
func tintForDebug(_ image: CGImage) -> CGImage {
    let input = CIImage(cgImage: image)
    let hue = CIFilter(name: "CIHueAdjust", parameters: [
        kCIInputImageKey: input,
        kCIInputAngleKey: -2.02, // ~-116 deg: emerald (~148 deg) -> warm amber-orange (~32 deg)
    ])!.outputImage!
    let vib = CIFilter(name: "CIColorControls", parameters: [
        kCIInputImageKey: hue,
        kCIInputSaturationKey: 1.12,
    ])!.outputImage!
    return ciContext.createCGImage(vib, from: input.extent)!
}

/// Composites `source` onto Apple's 1024x1024 icon canvas with an 824x824 macOS continuous squircle, drop shadow, and rim.
func renderIcon(from url: URL, debug: Bool) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let raw = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot read \(url.path)"])
    }
    let artwork = debug ? tintForDebug(raw) : raw
    let size = 1024
    let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 185.4 // Apple macOS squircle radius (22.5% of 824)

    let root = CALayer()
    root.frame = CGRect(x: 0, y: 0, width: size, height: size)

    // Shadow layer (separate from clipped plate so shadow renders outside the squircle mask).
    let shadowLayer = CALayer()
    shadowLayer.frame = plateRect
    shadowLayer.cornerRadius = cornerRadius
    shadowLayer.cornerCurve = .continuous
    shadowLayer.backgroundColor = NSColor(srgbRed: 0.03, green: 0.05, blue: 0.04, alpha: 1).cgColor
    shadowLayer.shadowColor = NSColor.black.cgColor
    shadowLayer.shadowOpacity = 0.32
    shadowLayer.shadowRadius = 22
    shadowLayer.shadowOffset = CGSize(width: 0, height: -10)
    root.addSublayer(shadowLayer)

    // Clipped artwork plate.
    let plate = CALayer()
    plate.frame = plateRect
    plate.cornerRadius = cornerRadius
    plate.cornerCurve = .continuous
    plate.masksToBounds = true
    plate.contents = artwork
    plate.contentsGravity = .resizeAspectFill
    root.addSublayer(plate)

    // Subtle inner hairline border so dark icons stay crisp against dark Dock backgrounds.
    let borderLayer = CALayer()
    borderLayer.frame = plate.bounds
    borderLayer.cornerRadius = cornerRadius
    borderLayer.cornerCurve = .continuous
    borderLayer.borderWidth = 2.5
    borderLayer.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
    plate.addSublayer(borderLayer)

    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "failed to create CGContext"])
    }
    ctx.interpolationQuality = .high
    root.render(in: ctx)
    guard let rendered = ctx.makeImage() else {
        throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed to capture image"])
    }
    return rendered
}

func pngData(_ image: CGImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    ctx.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func writeICNS(_ image: CGImage, to destination: URL, scratchName: String) throws {
    let iconset = URL(fileURLWithPath: "build/\(scratchName).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }

    for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
        let file = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try pngData(image, pixels: points * scale).write(to: iconset.appendingPathComponent(file))
    }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw NSError(domain: "make-icon", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "iconutil failed for \(destination.path)"])
    }
}

try FileManager.default.createDirectory(atPath: "Resources/Icons", withIntermediateDirectories: true)

for id in icons {
    let master = URL(fileURLWithPath: "Resources/Icons/masters/\(id).png")
    for debug in variants {
        let suffix = debug ? "-debug" : ""
        let image = try renderIcon(from: master, debug: debug)
        let icnsURL = URL(fileURLWithPath: "Resources/Icons/\(id)\(suffix).icns")
        try writeICNS(image, to: icnsURL, scratchName: "\(id)\(suffix)")
        print("wrote \(icnsURL.path)")

        if id == defaultIcon {
            let appIconURL = URL(fileURLWithPath: "Resources/AppIcon\(suffix).icns")
            try? FileManager.default.removeItem(at: appIconURL)
            try FileManager.default.copyItem(at: icnsURL, to: appIconURL)
            print("wrote \(appIconURL.path)")
            if !debug {
                let pluginURL = URL(fileURLWithPath: "plugin/icon.png")
                try pngData(image, pixels: 512).write(to: pluginURL)
                print("wrote \(pluginURL.path)")
            }
        }
    }
}
