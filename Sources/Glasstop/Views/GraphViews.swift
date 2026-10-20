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
    /// Grows downward from the top edge (btop's mirrored GPU graph under the CPU one).
    var inverted = false
    /// Seconds between samples; with `format`, enables a hover marker showing the exact value.
    var interval: TimeInterval = SamplerSettings.default.interval
    var format: ((Double) -> String)? = nil

    func makeNSView(context: Context) -> GraphLayerView { GraphLayerView() }

    func updateNSView(_ view: GraphLayerView, context: Context) {
        view.hover = format.map { format in (interval, format) }
        view.configure(values: values, capacity: capacity, range: range, gradient: gradient,
                       showsGrid: showsGrid, lineWidth: lineWidth, inverted: inverted)
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
    private var inverted = false

    private let grid = CAShapeLayer()
    private let fill = GradientShape(stroke: false)
    private let line = GradientShape(stroke: true)

    /// (sample interval, value formatter). nil = no hover marker.
    var hover: (TimeInterval, (Double) -> String)? {
        didSet { if (hover == nil) != (oldValue == nil) { updateTrackingAreas() } }
    }
    private var hoverX: CGFloat?
    private let marker = CAShapeLayer()
    private let label = CATextLayer()
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

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
        marker.lineWidth = 1
        marker.isHidden = true
        label.font = Self.labelFont
        label.fontSize = Self.labelFont.pointSize
        label.cornerRadius = 4
        label.alignmentMode = .center
        label.isHidden = true
        layer?.addSublayer(marker)
        layer?.addSublayer(label)
        fill.setColors(gradient)
        line.setColors(gradient)
        updateColors()
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard hover != nil else { return }
        // .activeAlways: the panel floats over other apps, so Glasstop is usually inactive.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                              .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverX = convert(event.locationInWindow, from: nil).x
        withoutAnimation { updateHover() }
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        withoutAnimation { updateHover() }
    }

    private func updateHover() {
        guard let (interval, format) = hover, let x = hoverX, values.count > 1, capacity > 1,
              bounds.width > 0 else {
            marker.isHidden = true
            label.isHidden = true
            return
        }
        let step = bounds.width / CGFloat(capacity - 1)
        let offset = capacity - values.count
        let i = min(max(Int((x / step).rounded()) - offset, 0), values.count - 1)
        let px = CGFloat(i + offset) * step
        let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
        let v = (min(max(values[i], range.lowerBound), range.upperBound) - range.lowerBound) / span
        let py = y(forFraction: CGFloat(v))

        let path = CGMutablePath()
        path.move(to: CGPoint(x: px, y: 0))
        path.addLine(to: CGPoint(x: px, y: bounds.height))
        path.addEllipse(in: CGRect(x: px - 2.5, y: py - 2.5, width: 5, height: 5))
        marker.frame = bounds
        marker.path = path
        marker.isHidden = false

        let ago = Double(values.count - 1 - i) * interval
        let text = ago < 0.5 ? format(values[i]) : "\(format(values[i])) · \(Int(ago.rounded())) s ago"
        let size = (text as NSString).size(withAttributes: [.font: Self.labelFont])
        let w = ceil(size.width) + 10, h = ceil(size.height) + 4
        let lx = min(max(px - w / 2, 0), max(bounds.width - w, 0))
        let ly = py + 6 + h <= bounds.height ? py + 6 : max(py - 6 - h, 0)
        label.string = text
        label.frame = CGRect(x: lx, y: ly, width: w, height: h)
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.isHidden = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(values: [Double], capacity: Int, range: ClosedRange<Double>, gradient: Gradient,
                   showsGrid: Bool, lineWidth: CGFloat, inverted: Bool) {
        guard values != self.values || capacity != self.capacity || range != self.range
                || gradient != self.gradient || showsGrid != self.showsGrid || lineWidth != self.lineWidth
                || inverted != self.inverted
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
            if inverted != self.inverted {
                self.inverted = inverted
                // Low values sit at the baseline, so the gradient flips with the graph.
                for g in [fill.gradient, line.gradient] {
                    g.startPoint = CGPoint(x: 0.5, y: inverted ? 1 : 0)
                    g.endPoint = CGPoint(x: 0.5, y: inverted ? 0 : 1)
                }
            }
            relayout()
        }
    }

    /// Layer y (y-up) for a value fraction 0...1: up from the bottom, or down from the top
    /// when inverted.
    private func y(forFraction v: CGFloat) -> CGFloat {
        let usable = bounds.height - lineWidth
        return inverted ? bounds.height - lineWidth / 2 - usable * v : lineWidth / 2 + usable * v
    }

    override func updateColors() {
        grid.strokeColor = resolved(NSColor.labelColor.withAlphaComponent(0.07))
        marker.strokeColor = resolved(NSColor.labelColor.withAlphaComponent(0.45))
        marker.fillColor = resolved(NSColor.labelColor)
        label.foregroundColor = resolved(NSColor.labelColor)
        label.backgroundColor = resolved(NSColor.windowBackgroundColor.withAlphaComponent(0.92))
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

        let path = CGMutablePath()
        for (i, raw) in values.enumerated() {
            let v = (min(max(raw, range.lowerBound), range.upperBound) - range.lowerBound) / span
            let point = CGPoint(x: (offset + CGFloat(i)) * step, y: y(forFraction: CGFloat(v)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        let area = path.mutableCopy()!
        let baseline: CGFloat = inverted ? size.height : 0
        area.addLine(to: CGPoint(x: (offset + CGFloat(values.count - 1)) * step, y: baseline))
        area.addLine(to: CGPoint(x: offset * step, y: baseline))
        area.closeSubpath()

        line.shape.lineWidth = lineWidth
        line.shape.path = path
        fill.shape.path = area
        if hoverX != nil { updateHover() }
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
