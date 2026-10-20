import SwiftUI

struct HeaderBar: View {
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
    }
}

/// Green dot + sample cost normally; turns red if no sample arrived for >2 s
/// (the exact failure mode btop has).
struct StaleBadge: View {
    @Environment(Sampler.self) private var sampler

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = context.date.timeIntervalSince(sampler.lastSampleAt)
            let stale = age > 2
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
