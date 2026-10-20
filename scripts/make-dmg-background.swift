// Draws the DMG window background: a light frosted backdrop with the icon's green/amber
// glows, an arrow from the app icon to the Applications shortcut, and a caption.
// Writes <out>/background.png and background@2x.png (combined into a TIFF by make-dmg.sh).
//
// Usage: swift scripts/make-dmg-background.swift <out-dir>
// Layout must match scripts/dmg-settings.py: 640×400 window, icons centered at x 160 / 480, y 185.
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/dmg")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let width: CGFloat = 640, height: CGFloat = 400
let iconY: CGFloat = 185                      // Finder coordinates (top-left origin)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func render(scale: CGFloat) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)           // draw in points, bottom-left origin

    let bg = CGGradient(colorsSpace: space, colors: [color(0.97, 0.98, 0.99), color(0.90, 0.92, 0.95)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])

    func glow(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: CGColor) {
        let g = CGGradient(colorsSpace: space, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                               endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
    }
    glow(90, 360, 300, color(0.30, 0.80, 0.50, 0.22))
    glow(600, 30, 320, color(0.98, 0.62, 0.20, 0.20))
    glow(560, 380, 220, color(0.35, 0.55, 0.95, 0.14))

    // Arrow between the two icons (icons are 128 pt; leave room around them).
    let y = height - iconY
    let start = CGPoint(x: 250, y: y), end = CGPoint(x: 390, y: y)
    let ink = color(0.45, 0.48, 0.53)     // opaque: the shaft must not show through the head
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: start)
    ctx.addLine(to: CGPoint(x: end.x - 14, y: y))
    ctx.strokePath()
    ctx.setFillColor(ink)
    ctx.move(to: CGPoint(x: end.x + 8, y: y))
    ctx.addLine(to: CGPoint(x: end.x - 16, y: y + 15))
    ctx.addLine(to: CGPoint(x: end.x - 16, y: y - 15))
    ctx.closePath()
    ctx.fillPath()

    // Caption.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let caption = NSAttributedString(string: "Drag Glasstop to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.25, green: 0.27, blue: 0.31, alpha: 0.9),
        .paragraphStyle: paragraph,
    ])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    caption.draw(in: CGRect(x: 0, y: 62, width: width, height: 24))
    NSGraphicsContext.restoreGraphicsState()

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: width, height: height)   // 72 dpi at 1×, 144 dpi at 2×
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: outDir.appendingPathComponent("background.png"))
try render(scale: 2).write(to: outDir.appendingPathComponent("background@2x.png"))
print("Wrote \(outDir.path)/background.png, background@2x.png")
