import SwiftUI

// MARK: Mirrored graph

/// btop's mirrored graph: one series grows up from the middle line, the other hangs down from
/// it, with a label row between them (CPU/GPU, download/upload, read/write).
struct MirroredGraph: View {
    let up: [Double]
    let down: [Double]
    let capacity: Int
    let interval: TimeInterval
    var upRange: ClosedRange<Double> = 0...100
    var downRange: ClosedRange<Double> = 0...100
    var upGradient: Gradient = Palette.loadGradient
    var downGradient: Gradient = Palette.loadGradient
    let upLabel: String
    let downLabel: String
    var upShare: CGFloat = 0.5
    var upFormat: ((Double) -> String)? = nil
    var downFormat: ((Double) -> String)? = nil

    private static let labelHeight: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            let graphs = max(geo.size.height - Self.labelHeight, 0)
            VStack(spacing: 0) {
                HistoryGraph(values: up, capacity: capacity, range: upRange, gradient: upGradient,
                             interval: interval, format: upFormat)
                    .frame(height: graphs * upShare)
                HStack(spacing: 6) {
                    Text("▲ " + upLabel)
                    Spacer(minLength: 4)
                    Text("▼ " + downLabel)
                }
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: Self.labelHeight)
                HistoryGraph(values: down, capacity: capacity, range: downRange, gradient: downGradient,
                             showsGrid: false, inverted: true, interval: interval, format: downFormat)
                    .frame(height: graphs * (1 - upShare))
            }
        }
    }
}

// MARK: Formatting

private let rateFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file              // decimal: 1 MB = 1,000,000 bytes, like network tools
    f.allowsNonnumericFormatting = false
    return f
}()

func formatRate(_ bytesPerSecond: Double) -> String {
    // ByteCountFormatter says "339 bytes"; keep it as compact as the other units.
    bytesPerSecond < 1000 ? "\(Int(bytesPerSecond)) B/s"
                          : rateFormatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
}

/// Compact decimal size for narrow columns: "640 GB", "60.8 GB", "4.2 MB".
func formatDecimalBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1000, unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    return value >= 100 || unit == 0 ? String(format: "%.0f %@", value, units[unit])
                                     : String(format: "%.1f %@", value, units[unit])
}

/// Shared auto-scale for a pair of rate histories: the next 1/2/5 × 10ⁿ above the peak
/// (at least 10 KB/s, so an idle link doesn't amplify noise).
func niceRateCeiling(_ a: [Double], _ b: [Double]) -> Double {
    let peak = max(a.max() ?? 0, b.max() ?? 0, 10_000)
    let magnitude = pow(10, floor(log10(peak)))
    for step in [1.0, 2.0, 5.0, 10.0] where step * magnitude >= peak { return step * magnitude }
    return 10 * magnitude
}

private func fadeGradient(_ color: Color) -> Gradient { Gradient(colors: [color.opacity(0.55), color]) }

/// Small "scale" tag in the corner of an auto-scaled graph, like btop's.
private struct ScaleTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9.5).monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.leading, 2)
            .allowsHitTesting(false)
    }
}

// MARK: Network

struct NetworkPanel: View {
    @Environment(Sampler.self) private var sampler

    var body: some View {
        let net = sampler.network
        Panel(title: "net", tint: .teal) {
            InterfacePicker()
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                RateRow(symbol: "arrow.down", label: "Download", rate: net?.rxPerSecond,
                        total: net?.rxTotal, color: .teal)
                RateRow(symbol: "arrow.up", label: "Upload", rate: net?.txPerSecond,
                        total: net?.txTotal, color: .indigo)
                let rx = sampler.netRxHistory.values, tx = sampler.netTxHistory.values
                let ceiling = niceRateCeiling(rx, tx)
                MirroredGraph(up: rx, down: tx, capacity: sampler.historyCapacity, interval: sampler.interval,
                              upRange: 0...ceiling, downRange: 0...ceiling,
                              upGradient: fadeGradient(.teal), downGradient: fadeGradient(.indigo),
                              upLabel: "down", downLabel: "up",
                              upFormat: { "↓ " + formatRate($0) }, downFormat: { "↑ " + formatRate($0) })
                    .sidePanelGraph(minHeight: 50)
                    .overlay(alignment: .topLeading) { ScaleTag(text: formatRate(ceiling)) }
                    .padding(.top, 2)
            }
            .font(.system(size: 11))
        }
    }
}

/// Dropdown in the net panel's title: all Wi-Fi/Ethernet adapters, or one interface.
private struct InterfacePicker: View {
    @Environment(Sampler.self) private var sampler

    var body: some View {
        let net = sampler.network
        let selected = sampler.networkInterface
        var options = net?.available ?? []
        // Keep a picked interface listed even while it's down, so you can switch back.
        if let selected, !options.contains(where: { $0.bsdName == selected }) {
            options.append(NetworkInterface(bsdName: selected, displayName: nil))
        }
        let current = selected.map { name in options.first { $0.bsdName == name }?.displayName ?? name }
            ?? "All" + (net.map { $0.measured.isEmpty ? "" : " (\($0.measured.joined(separator: " ")))" } ?? "")

        return Menu {
            Picker("Interface", selection: Binding(get: { selected },
                                                   set: { sampler.selectNetworkInterface($0) })) {
                Text("All Wi-Fi & Ethernet").tag(String?.none)
                let physical = options.filter(\.isPhysical), other = options.filter { !$0.isPhysical }
                if !physical.isEmpty {
                    Section("Adapters") {
                        ForEach(physical) { Text($0.label).tag(Optional($0.bsdName)) }
                    }
                }
                if !other.isEmpty {
                    Section("Other (VPN, bridges…)") {
                        ForEach(other) { Text($0.label).tag(Optional($0.bsdName)) }
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(current)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Network interface to measure")
    }
}

private struct RateRow: View {
    let symbol: String
    let label: String
    let rate: Double?
    let total: UInt64?
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(rate.map(formatRate) ?? "—").monospacedDigit()
            Text(total.map { "Σ " + formatDecimalBytes($0) } ?? "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .help("Rate now · total since boot (Wi-Fi/Ethernet interfaces)")
    }
}

// MARK: Disks

struct DiskPanel: View {
    @Environment(Sampler.self) private var sampler

    var body: some View {
        let io = sampler.diskIO
        Panel(title: "disks", tint: .pink,
              trailing: io.map { "R \(formatRate($0.readPerSecond)) · W \(formatRate($0.writePerSecond))" }) {
            VStack(alignment: .leading, spacing: 5) {
                if sampler.volumes.isEmpty {
                    Text("—").foregroundStyle(.secondary)
                }
                ForEach(sampler.volumes) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(v.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text("\(formatDecimalBytes(v.used)) / \(formatDecimalBytes(v.total))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Numeric(text: String(format: "%.0f%%", v.usedFraction * 100), width: 32)
                        }
                        MeterBar(fraction: v.usedFraction, gradient: Palette.loadGradient)
                    }
                    .help(v.mountPoint)
                }
                let r = sampler.diskReadHistory.values, w = sampler.diskWriteHistory.values
                let ceiling = niceRateCeiling(r, w)
                MirroredGraph(up: r, down: w, capacity: sampler.historyCapacity, interval: sampler.interval,
                              upRange: 0...ceiling, downRange: 0...ceiling,
                              upGradient: fadeGradient(.pink), downGradient: fadeGradient(.orange),
                              upLabel: "read", downLabel: "write",
                              upFormat: { "R " + formatRate($0) }, downFormat: { "W " + formatRate($0) })
                    .sidePanelGraph(minHeight: 46)
                    .overlay(alignment: .topLeading) { ScaleTag(text: formatRate(ceiling)) }
                    .padding(.top, 2)
            }
            .font(.system(size: 11))
        }
    }
}
