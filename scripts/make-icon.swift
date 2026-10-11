// Renders the iClear app icon (original artwork: a gauge arc and two pause bars on a
// blue-teal tile) into an .iconset and builds AppIcon.icns with iconutil.
// Usage: swift scripts/make-icon.swift [output directory]   (default: packaging)
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packaging")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)
    // Tile: the macOS icon grid leaves about 10% margin; corner radius about 22% of the tile.
    let tile = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let path = CGPath(roundedRect: tile, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        NSColor(red: 0.10, green: 0.36, blue: 0.62, alpha: 1).cgColor, NSColor(red: 0.16, green: 0.67, blue: 0.62, alpha: 1).cgColor,
    ]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    ctx.restoreGState()
    // Gauge arc: three quarters of a circle, open at the bottom.
    let c = CGPoint(x: s / 2, y: s / 2)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(s * 0.055)
    ctx.setLineCap(.round)
    ctx.addArc(center: c, radius: s * 0.24, startAngle: .pi * 1.35, endAngle: -.pi * 0.35, clockwise: true)
    ctx.strokePath()
    // Two pause bars inside the arc.
    ctx.setFillColor(NSColor.white.cgColor)
    for dx in [-0.065, 0.065] {
        let bar = CGRect(x: s * (0.5 + dx) - s * 0.03, y: s * 0.40, width: s * 0.06, height: s * 0.20)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil))
        ctx.fillPath()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(out.appendingPathComponent("AppIcon.icns").path)")
