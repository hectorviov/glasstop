import AppKit
import QuartzCore
import SwiftUI

// Graphs and meters are vector layers (CAShapeLayer masks over CAGradientLayers) rendered by
// the render server: the app only builds a path per update, with no rasterization and no
// backing store. SwiftUI's Canvas cost ~160 MB of GPU surfaces for these ~24 small graphs, and
// CoreGraphics-drawn layer-backed NSViews still ~90 MB.

/// History graph, right-aligned so new data enters on the right. Fill and line use a vertical
/// gradient, so taller peaks get warmer colors (like btop).
struct HistoryGraph: NSViewRepresentable {
    let values: [Double]
    let capacity: Int
    var range: ClosedRange<Double> = 0...100
    var gradient: Gradient = Palette.loadGradient
    var showsGrid = true
    var lineWidth: CGFloat = 1.3

    func makeNSView(context: Context) -> GraphLayerView { GraphLayerView() }

    func updateNSView(_ view: GraphLayerView, context: Context) {
        view.configure(values: values, capacity: capacity, range: range, gradient: gradient,
                       showsGrid: showsGrid, lineWidth: lineWidth)
    }
}

/// Horizontal meter: track plus a fill that reveals a full-width gradient up to `fraction`.
struct MeterBar: View {
    let fraction: Double
    var gradient: Gradient = Palette.loadGradient

    var body: some View {
        MeterRepresentable(fraction: fraction, gradient: gradient).frame(height: 6)
    }
}

private struct MeterRepresentable: NSViewRepresentable {
    let fraction: Double
    let gradient: Gradient

    func makeNSView(context: Context) -> MeterLayerView { MeterLayerView() }

    func updateNSView(_ view: MeterLayerView, context: Context) {
        view.configure(fraction: fraction, gradient: gradient)
    }
}

// MARK: Layer-hosting views

/// A layer-hosting NSView (we own the layer tree; AppKit never draws into it).
class LayerHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks/tooltips go to SwiftUI

    override func layout() {
        super.layout()
        withoutAnimation { relayout() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withoutAnimation { updateColors() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        layer?.sublayers?.forEach { setScale($0, scale) }
    }

    /// Subclasses: rebuild paths for the current bounds.
    func relayout() {}
    /// Subclasses: resolve appearance-dependent colors.
    func updateColors() {}

    func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Resolves a dynamic NSColor (e.g. labelColor) for this view's appearance.
    func resolved(_ color: NSColor) -> CGColor {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }

    private func setScale(_ layer: CALayer, _ scale: CGFloat) {
        layer.contentsScale = scale
        layer.sublayers?.forEach { setScale($0, scale) }
        if let mask = layer.mask { setScale(mask, scale) }
    }
}

/// A gradient layer whose visible area is a shape (fill or stroke).
private final class GradientShape {
    let gradient = CAGradientLayer()
    let shape = CAShapeLayer()

    init(stroke: Bool) {
        shape.fillColor = stroke ? nil : NSColor.black.cgColor
        shape.strokeColor = stroke ? NSColor.black.cgColor : nil
        shape.lineJoin = .round
        gradient.mask = shape
    }

    func setColors(_ g: Gradient) {
        gradient.colors = g.stops.map { NSColor($0.color).cgColor }
        gradient.locations = g.stops.map { NSNumber(value: Double($0.location)) }
    }

    func setFrame(_ rect: CGRect) {
        gradient.frame = rect
        shape.frame = CGRect(origin: .zero, size: rect.size)
    }
}

final class GraphLayerView: LayerHostView {
    private var values: [Double] = []
    private var capacity = 2
    private var range: ClosedRange<Double> = 0...100
    private var gradient = Palette.loadGradient
    private var showsGrid = true
    private var lineWidth: CGFloat = 1.3

    private let grid = CAShapeLayer()
    private let fill = GradientShape(stroke: false)
    private let line = GradientShape(stroke: true)

    override init(frame: NSRect) {
        super.init(frame: frame)
        grid.fillColor = nil
        grid.lineWidth = 1
        fill.gradient.opacity = 0.35
        for g in [fill.gradient, line.gradient] {
            // Layer coordinates are y-up here: bottom of the graph = low values = start.
            g.startPoint = CGPoint(x: 0.5, y: 0)
            g.endPoint = CGPoint(x: 0.5, y: 1)
        }
        layer?.addSublayer(grid)
        layer?.addSublayer(fill.gradient)
        layer?.addSublayer(line.gradient)
        fill.setColors(gradient)
        line.setColors(gradient)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(values: [Double], capacity: Int, range: ClosedRange<Double>, gradient: Gradient,
                   showsGrid: Bool, lineWidth: CGFloat) {
        guard values != self.values || capacity != self.capacity || range != self.range
                || gradient != self.gradient || showsGrid != self.showsGrid || lineWidth != self.lineWidth
        else { return }
        withoutAnimation {
            if gradient != self.gradient {
                fill.setColors(gradient)
                line.setColors(gradient)
            }
            self.values = values
            self.capacity = capacity
            self.range = range
            self.gradient = gradient
            self.showsGrid = showsGrid
            self.lineWidth = lineWidth
            relayout()
        }
    }

    override func updateColors() {
        grid.strokeColor = resolved(NSColor.labelColor.withAlphaComponent(0.07))
    }

    override func relayout() {
        let size = bounds.size
        fill.setFrame(bounds)
        line.setFrame(bounds)
        grid.frame = bounds

        if showsGrid {
            let path = CGMutablePath()
            for f in [0.25, 0.5, 0.75] {
                let y = (size.height * f).rounded() + 0.5
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            grid.path = path
        } else {
            grid.path = nil
        }

        guard values.count > 1, capacity > 1, size.width > 0, size.height > 0 else {
            fill.shape.path = nil
            line.shape.path = nil
            return
        }
        let step = size.width / CGFloat(capacity - 1)
        let offset = CGFloat(capacity - values.count)
        let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
        let usable = size.height - lineWidth

        let path = CGMutablePath()
        for (i, raw) in values.enumerated() {
            let v = (min(max(raw, range.lowerBound), range.upperBound) - range.lowerBound) / span
            let point = CGPoint(x: (offset + CGFloat(i)) * step, y: lineWidth / 2 + usable * CGFloat(v))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        let area = path.mutableCopy()!
        area.addLine(to: CGPoint(x: (offset + CGFloat(values.count - 1)) * step, y: 0))
        area.addLine(to: CGPoint(x: offset * step, y: 0))
        area.closeSubpath()

        line.shape.lineWidth = lineWidth
        line.shape.path = path
        fill.shape.path = area
    }
}

final class MeterLayerView: LayerHostView {
    private var fraction = 0.0
    private var gradient = Palette.loadGradient
    private let track = CAShapeLayer()
    private let bar = GradientShape(stroke: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.gradient.startPoint = CGPoint(x: 0, y: 0.5)
        bar.gradient.endPoint = CGPoint(x: 1, y: 0.5)
        bar.setColors(gradient)
        layer?.addSublayer(track)
        layer?.addSublayer(bar.gradient)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(fraction: Double, gradient: Gradient) {
        // Quantize to half a percent: invisible difference, far fewer updates.
        let f = (min(max(fraction.isFinite ? fraction : 0, 0), 1) * 200).rounded() / 200
        guard f != self.fraction || gradient != self.gradient else { return }
        withoutAnimation {
            if gradient != self.gradient { bar.setColors(gradient) }
            self.fraction = f
            self.gradient = gradient
            relayout()
        }
    }

    override func updateColors() {
        track.fillColor = resolved(NSColor.labelColor.withAlphaComponent(0.09))
    }

    override func relayout() {
        let rect = bounds
        let radius = rect.height / 2
        track.frame = rect
        track.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        bar.setFrame(rect)
        guard fraction > 0, rect.width > 0 else { bar.shape.path = nil; return }
        let filled = CGRect(x: 0, y: 0, width: max(rect.height, rect.width * fraction), height: rect.height)
        bar.shape.path = CGPath(roundedRect: filled, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
