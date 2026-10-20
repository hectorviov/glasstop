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

// MARK: Panel

/// btop-style box: a rounded border with the title (and optional trailing text) set into it.
struct Panel<Content: View, Accessory: View>: View {
    let title: String
    var tint: Color = .secondary
    var trailing: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    private let background = Color(nsColor: .windowBackgroundColor)

    var body: some View {
        content()
            .padding(EdgeInsets(top: 14, leading: 10, bottom: 10, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.025)))
                    .opacity(UserDefaults.standard.string(forKey: "hide")?.contains("panelbg") == true ? 0 : 1) // TEMP
            )
            .overlay(alignment: .top) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 5)
                        .background(background)
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
                    .background(background)
                }
                .padding(.horizontal, 10)
                .offset(y: -8)
            }
            .padding(.top, 8)
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
