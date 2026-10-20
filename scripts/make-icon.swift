// Generates Resources/AppIcon.icns: a dark rounded tile with a btop-style pulse line
// (green → yellow → red gradient) over faint grid lines. CoreGraphics + iconutil only.
//
// Usage: swift scripts/make-icon.swift   (from the repo root)
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Tile: macOS icon grid (824/1024 body, rounded ~185/1024), dark blue-gray gradient.
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: color(0, 0, 0, 0.45))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0.10, 0.11, 0.14))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [color(0.16, 0.18, 0.23), color(0.07, 0.08, 0.10)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // Grid lines.
    ctx.setStrokeColor(color(1, 1, 1, 0.07))
    ctx.setLineWidth(max(1, s / 256))
    for f in [0.3, 0.5, 0.7] {
        let y = tile.minY + tile.height * f
        ctx.move(to: CGPoint(x: tile.minX, y: y))
        ctx.addLine(to: CGPoint(x: tile.maxX, y: y))
    }
    ctx.strokePath()

    // Pulse line (heartbeat-like), stroked with a vertical load gradient.
    let pts: [(CGFloat, CGFloat)] = [
        (0.00, 0.40), (0.18, 0.40), (0.26, 0.47), (0.33, 0.33), (0.42, 0.80),
        (0.50, 0.22), (0.57, 0.52), (0.64, 0.44), (0.75, 0.47), (0.84, 0.43), (1.00, 0.45),
    ]
    let line = CGMutablePath()
    for (i, p) in pts.enumerated() {
        let point = CGPoint(x: tile.minX + tile.width * p.0, y: tile.minY + tile.height * p.1)
        if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
    }
    let load = CGGradient(colorsSpace: nil,
                          colors: [color(0.30, 0.78, 0.42), color(0.96, 0.78, 0.26), color(0.95, 0.32, 0.32)] as CFArray,
                          locations: [0.25, 0.55, 0.85])!
    let lineWidth = s * 0.045

    // Soft fill under the line.
    let area = line.mutableCopy()!
    area.addLine(to: CGPoint(x: tile.maxX, y: tile.minY))
    area.addLine(to: CGPoint(x: tile.minX, y: tile.minY))
    area.closeSubpath()
    ctx.saveGState()
    ctx.addPath(area)
    ctx.clip()
    ctx.setAlpha(0.22)
    ctx.drawLinearGradient(load, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
    ctx.restoreGState()

    // Glow + line.
    ctx.saveGState()
    ctx.addPath(line)
    ctx.setLineWidth(lineWidth)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(load, start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
    ctx.restoreGState()
    ctx.restoreGState()

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: base * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
