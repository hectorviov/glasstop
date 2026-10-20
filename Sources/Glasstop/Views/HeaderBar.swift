import SwiftUI

/// Sits in the (transparent) titlebar row, right of the traffic lights.
struct HeaderBar: View {
    static let height: CGFloat = 28
    static let trafficLightsWidth: CGFloat = 72

    @Environment(Sampler.self) private var sampler
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            Text(sampler.system.chipName).font(.system(size: 13, weight: .semibold))
            Text(sampler.system.topologyDescription).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            StaleBadge()
            Button {
                appState.setAlwaysOnTop(!appState.alwaysOnTop)
            } label: {
                Image(systemName: appState.alwaysOnTop ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help("Keep on top (⌘T)")
        }
        .padding(.leading, Self.trafficLightsWidth)
        .frame(height: Self.height)
        .background(WindowDragArea())
    }
}

/// Empty space that drags the window (the titlebar is covered by SwiftUI content).
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// Green dot + sample cost normally; turns red if no sample arrived for >2 s
/// (the exact failure mode btop has).
struct StaleBadge: View {
    @Environment(Sampler.self) private var sampler

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = context.date.timeIntervalSince(sampler.lastSampleAt)
            let stale = age > max(2, sampler.interval * 3)
            HStack(spacing: 4) {
                Circle().fill(stale ? Color.red : Color.green).frame(width: 7, height: 7)
                Text(stale ? String(format: "stalled %.0fs", min(age, 9999))
                           : String(format: "%.1f ms", sampler.tickCost * 1000))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("Cost of the slowest recent sampler tick (temperatures run separately)")
        }
    }
}
