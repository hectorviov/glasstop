import AppKit
import SwiftUI

// MARK: Palette

/// btop-style color scales: green → yellow → red for load, blue → green → yellow → red for heat.
enum Palette {
    private typealias RGB = (r: Double, g: Double, b: Double)
    private static let loadStops: [(Double, RGB)] = [
        (0.0, (0.30, 0.78, 0.42)),
        (0.5, (0.96, 0.78, 0.26)),
        (1.0, (0.95, 0.32, 0.32)),
    ]
    private static let heatStops: [(Double, RGB)] = [
        (0.0, (0.35, 0.62, 0.98)),
        (0.35, (0.30, 0.78, 0.42)),
        (0.65, (0.96, 0.78, 0.26)),
        (1.0, (0.95, 0.32, 0.32)),
    ]
    static let heatRange: ClosedRange<Double> = 25...105

    /// `percent` 0...100.
    static func load(_ percent: Double) -> Color { color(interpolate(loadStops, percent / 100)) }
    static func loadNS(_ percent: Double) -> NSColor { nsColor(interpolate(loadStops, percent / 100)) }
    static func heat(_ celsius: Double) -> Color { color(interpolate(heatStops, heatFraction(celsius))) }

    static let loadGradient = gradient(loadStops)
    static let heatGradient = gradient(heatStops)

    static func heatFraction(_ celsius: Double) -> Double {
        (celsius - heatRange.lowerBound) / (heatRange.upperBound - heatRange.lowerBound)
    }

    private static func interpolate(_ stops: [(Double, RGB)], _ x: Double) -> RGB {
        let x = min(max(x.isFinite ? x : 0, 0), 1)
        for i in 1..<stops.count where x <= stops[i].0 {
            let (x0, a) = stops[i - 1], (x1, b) = stops[i]
            let t = (x - x0) / (x1 - x0)
            return (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
        }
        return stops[stops.count - 1].1
    }

    private static func color(_ c: RGB) -> Color { Color(red: c.r, green: c.g, blue: c.b) }
    private static func nsColor(_ c: RGB) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }
    private static func gradient(_ stops: [(Double, RGB)]) -> Gradient {
        Gradient(stops: stops.map { .init(color: color($0.1), location: $0.0) })
    }
}

func loadColor(_ percent: Double) -> Color { Palette.load(percent) }

extension Palette {
    /// Accent per core group, fastest first (Super / Performance / Efficiency...).
    static func groupTint(_ index: Int) -> Color {
        let tints: [Color] = [
            Color(red: 0.98, green: 0.58, blue: 0.40),   // coral
            Color(red: 0.42, green: 0.74, blue: 0.98),   // sky
            Color(red: 0.55, green: 0.85, blue: 0.65),   // mint
        ]
        return tints[index % tints.count]
    }
}

// MARK: Panel

/// btop-style box: a rounded border with the title (and optional trailing text) set into gaps
/// in its top edge. The gaps are real (cut out of the stroke path), so the box works on a
/// translucent material background.
struct Panel<Content: View, Accessory: View>: View {
    let title: String
    var tint: Color = .secondary
    var trailing: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    @State private var titleWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    private static var inset: CGFloat { 10 }

    var body: some View {
        content()
            .padding(EdgeInsets(top: 14, leading: 10, bottom: 10, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                NotchedBorder(cornerRadius: 9, inset: Self.inset, leadingGap: titleWidth, trailingGap: trailingWidth)
                    .stroke(tint.opacity(0.4), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.03)))
            )
            .overlay(alignment: .top) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 5)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        accessory()
                        if let trailing {
                            Text(trailing)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 5)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
                }
                .padding(.horizontal, Self.inset)
                .offset(y: -8)
            }
            .padding(.top, 8)
    }
}

/// Rounded-rect outline with two gaps in the top edge, each `inset` from its side: one of
/// `leadingGap` points on the left and one of `trailingGap` points on the right (0 = none).
private struct NotchedBorder: Shape {
    let cornerRadius: CGFloat
    let inset: CGFloat
    let leadingGap: CGFloat
    let trailingGap: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(cornerRadius, r.width / 2, r.height / 2)
        var gaps: [Range<CGFloat>] = []
        if leadingGap > 0 { gaps.append((r.minX + inset)..<(r.minX + inset + leadingGap)) }
        if trailingGap > 0 { gaps.append(max(r.maxX - inset - trailingGap, r.minX)..<(r.maxX - inset)) }

        var p = Path()
        // Top edge, left to right, skipping the gaps.
        var x = r.minX + radius
        for gap in gaps.sorted(by: { $0.lowerBound < $1.lowerBound }) where gap.upperBound > x {
            if gap.lowerBound > x {
                p.move(to: CGPoint(x: x, y: r.minY))
                p.addLine(to: CGPoint(x: min(gap.lowerBound, r.maxX - radius), y: r.minY))
            }
            x = max(x, gap.upperBound)
        }
        p.move(to: CGPoint(x: min(x, r.maxX - radius), y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        // Around the rest of the box, back to the top-left corner.
        p.addArc(center: CGPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addArc(center: CGPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addArc(center: CGPoint(x: r.minX + radius, y: r.minY + radius), radius: radius,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        return p
    }
}

extension Panel where Accessory == EmptyView {
    init(title: String, tint: Color = .secondary, trailing: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, tint: tint, trailing: trailing, accessory: { EmptyView() }, content: content)
    }
}

/// Fixed-width numeric label so columns line up.
struct Numeric: View {
    let text: String
    var width: CGFloat = 40
    var color: Color = .primary

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(color)
            .frame(width: width, alignment: .trailing)
    }
}

func formatTemp(_ celsius: Double?) -> String {
    guard let celsius else { return "—" }
    return String(format: "%.0f°C", celsius)
}
