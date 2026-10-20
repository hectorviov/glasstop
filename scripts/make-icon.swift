// Generates Resources/AppIcon.icns for Glasstop: a frosted glass pane floating over a dark tile
// lit by soft green and amber glows, with the app's btop-style mirrored graph etched into the
// glass (load rising in green above the midline, GPU hanging in amber below it).
// CoreGraphics + iconutil only.
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

/// Smooth path through points (Catmull-Rom → cubic Béziers).
func smoothPath(_ points: [CGPoint]) -> CGMutablePath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    path.move(to: first)
    for i in 0..<(points.count - 1) {
        let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Tile: macOS icon grid (824/1024 body, continuous-ish corners).
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035, color: color(0, 0, 0, 0.5))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0.06, 0.07, 0.10))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0.12, 0.14, 0.20), color(0.04, 0.05, 0.07)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // Soft lights behind the glass: they're what makes the pane read as frosted.
    func glow(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: CGColor) {
        let g = CGGradient(colorsSpace: space, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        let center = CGPoint(x: tile.minX + tile.width * cx, y: tile.minY + tile.height * cy)
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center,
                               endRadius: tile.width * r, options: [])
    }
    glow(0.28, 0.78, 0.55, color(0.22, 0.80, 0.48, 0.55))
    glow(0.80, 0.22, 0.55, color(0.98, 0.62, 0.20, 0.50))
    glow(0.85, 0.85, 0.35, color(0.30, 0.55, 0.95, 0.35))

    // The glass pane, slightly smaller than the tile, floating (shadow below it).
    let pane = tile.insetBy(dx: tile.width * 0.11, dy: tile.height * 0.15).offsetBy(dx: 0, dy: tile.height * 0.01)
    let paneRadius = pane.width * 0.12
    let panePath = CGPath(roundedRect: pane, cornerWidth: paneRadius, cornerHeight: paneRadius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.05, color: color(0, 0, 0, 0.45))
    ctx.addPath(panePath)
    ctx.setFillColor(color(1, 1, 1, 0.10))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(panePath)
    ctx.clip()
    // Frost: a milky vertical sheen, brighter at the top.
    let frost = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.22), color(1, 1, 1, 0.06)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(frost, start: CGPoint(x: 0, y: pane.maxY), end: CGPoint(x: 0, y: pane.minY), options: [])
    // Diagonal specular streak across the upper-left.
    ctx.saveGState()
    let streak = CGMutablePath()
    streak.move(to: CGPoint(x: pane.minX, y: pane.maxY - pane.height * 0.30))
    streak.addLine(to: CGPoint(x: pane.minX + pane.width * 0.42, y: pane.maxY))
    streak.addLine(to: CGPoint(x: pane.minX + pane.width * 0.62, y: pane.maxY))
    streak.addLine(to: CGPoint(x: pane.minX, y: pane.maxY - pane.height * 0.62))
    streak.closeSubpath()
    ctx.addPath(streak)
    ctx.setFillColor(color(1, 1, 1, 0.07))
    ctx.fillPath()
    ctx.restoreGState()

    // Mirrored graph inside the pane.
    let mid = pane.minY + pane.height * 0.47
    let graph = pane.insetBy(dx: pane.width * 0.07, dy: 0)
    let up: [CGFloat] = [0.18, 0.30, 0.22, 0.48, 0.36, 0.62, 0.86, 0.55, 0.40, 0.58, 0.44, 0.30]
    let down: [CGFloat] = [0.20, 0.26, 0.40, 0.30, 0.52, 0.34, 0.24, 0.42, 0.62, 0.38, 0.28, 0.22]
    let upHeight = pane.maxY - mid - pane.height * 0.10
    let downHeight = mid - pane.minY - pane.height * 0.10
    func points(_ values: [CGFloat], sign: CGFloat, height: CGFloat) -> [CGPoint] {
        values.enumerated().map { i, v in
            CGPoint(x: graph.minX + graph.width * CGFloat(i) / CGFloat(values.count - 1), y: mid + sign * v * height)
        }
    }
    func series(_ pts: [CGPoint], colors: [CGColor], from: CGFloat, to: CGFloat) {
        let line = smoothPath(pts)
        let area = line.mutableCopy()!
        area.addLine(to: CGPoint(x: graph.maxX, y: mid))
        area.addLine(to: CGPoint(x: graph.minX, y: mid))
        area.closeSubpath()
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
        ctx.saveGState()
        ctx.addPath(area)
        ctx.clip()
        ctx.setAlpha(0.38)
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: from), end: CGPoint(x: 0, y: to), options: [])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(line)
        ctx.setLineWidth(s * 0.022)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: from), end: CGPoint(x: 0, y: to), options: [])
        ctx.restoreGState()
    }
    series(points(up, sign: 1, height: upHeight),
           colors: [color(0.30, 0.82, 0.45), color(0.96, 0.80, 0.28)], from: mid, to: mid + upHeight)
    series(points(down, sign: -1, height: downHeight),
           colors: [color(0.98, 0.70, 0.25), color(0.95, 0.40, 0.25)], from: mid, to: mid - downHeight)
    // Midline.
    ctx.setStrokeColor(color(1, 1, 1, 0.35))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.move(to: CGPoint(x: graph.minX, y: mid))
    ctx.addLine(to: CGPoint(x: graph.maxX, y: mid))
    ctx.strokePath()
    ctx.restoreGState()

    // Glass edge: bright hairline on top, fainter around.
    ctx.saveGState()
    ctx.addPath(panePath)
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let edge = CGGradient(colorsSpace: space, colors: [color(1, 1, 1, 0.75), color(1, 1, 1, 0.15)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(edge, start: CGPoint(x: 0, y: pane.maxY), end: CGPoint(x: 0, y: pane.minY), options: [])
    ctx.restoreGState()

    ctx.restoreGState()   // tile clip

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: base * scale).write(to: iconset.appendingPathComponent(name))
    }
}
// Preview for review (not bundled).
try render(size: 1024).write(to: root.appendingPathComponent("build/icon-preview.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
