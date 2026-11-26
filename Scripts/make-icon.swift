// Draws the Troy app icon and writes an .icns file.
// Usage: swift Scripts/make-icon.swift <output.icns> [<output-1024.png>]
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns> [<1024.png>]\n".utf8))
    exit(2)
}
let icnsPath = args[1]
let pngPath: String? = args.count >= 3 ? args[2] : nil

/// Draws the icon into a square bitmap of `px` pixels.
func render(px: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high

    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(
            colorSpace: cs,
            components: [
                CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
                CGFloat(hex & 255) / 255, a,
            ])!
    }

    // Standard macOS grid: 824 tile centred in a 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.setFillColor(color(0x2A2370))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient tile: deep indigo (bottom) to violet (top).
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let grad = CGGradient(
        colorsSpace: cs, colors: [color(0x1E1B5E), color(0x4B2FA8), color(0x7C4DDB)] as CFArray,
        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(
        grad, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
    // Faint top sheen.
    let sheen = CGGradient(
        colorsSpace: cs, colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        sheen, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY + 60), options: [])
    ctx.restoreGState()

    // Thin inner edge highlight.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setStrokeColor(color(0xFFFFFF, 0.18))
    ctx.setLineWidth(3)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()

    // Graph glyph: four nodes, one large, slightly asymmetric.
    // (x, y, radius); y grows upward in this context.
    let big = CGPoint(x: 470, y: 560)
    let n1 = CGPoint(x: 700, y: 700)
    let n2 = CGPoint(x: 735, y: 430)
    let n3 = CGPoint(x: 360, y: 335)
    let rBig: CGFloat = 105
    let rSmall: CGFloat = 58
    let edges: [(CGPoint, CGPoint)] = [(big, n1), (big, n2), (big, n3), (n1, n2)]

    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0xFFFFFF, 0.92))
    ctx.setLineWidth(34)
    for (a, b) in edges {
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.strokePath()
    }
    ctx.setFillColor(color(0xFFFFFF))
    for (p, r) in [(big, rBig), (n1, rSmall), (n2, rSmall + 6), (n3, rSmall - 6)] {
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
    // Hollow centre in the large node gives it a ring look that survives at 16 px.
    ctx.setFillColor(color(0x4B2FA8))
    let hole: CGFloat = 38
    ctx.fillEllipse(in: CGRect(x: big.x - hole, y: big.y - hole, width: 2 * hole, height: 2 * hole))

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to path: String) throws {
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: img.width, height: img.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let work = NSTemporaryDirectory() + "troy-icon-\(ProcessInfo.processInfo.processIdentifier)"
let iconset = work + "/Troy.iconset"
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(atPath: work) }

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try writePNG(render(px: px), to: "\(iconset)/\(name).png")
}
if let pngPath { try writePNG(render(px: 1024), to: pngPath) }

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", icnsPath]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(icnsPath)")
