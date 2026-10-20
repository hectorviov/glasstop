import SwiftUI

/// btop-style memory box: one labeled meter per figure plus a used-% history.
struct MemoryPanel: View {
    @Environment(Sampler.self) private var sampler

    var body: some View {
        Panel(title: "mem", tint: .yellow, trailing: sampler.memory.map { "\(formatBytes($0.total)) total" }) {
            if let m = sampler.memory {
                VStack(alignment: .leading, spacing: 5) {
                    MemoryRow(label: "Used", bytes: m.used, total: m.total, gradient: Palette.loadGradient)
                    Text("App \(formatBytes(m.app)) · Wired \(formatBytes(m.wired)) · Compr. \(formatBytes(m.compressed))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    MemoryRow(label: "Available", bytes: m.available, total: m.total, gradient: tint(.green))
                    MemoryRow(label: "Cached", bytes: m.cached, total: m.total, gradient: tint(.blue))
                    MemoryRow(label: "Free", bytes: m.free, total: m.total, gradient: tint(.teal))
                    MemoryRow(label: "Swap", bytes: m.swapUsed, total: m.swapTotal, gradient: tint(.orange),
                              detail: m.swapTotal > 0 ? "of \(formatBytes(m.swapTotal))" : nil)
                    HistoryGraph(values: sampler.memoryHistory.values, capacity: sampler.historyCapacity,
                                 gradient: tint(.purple), interval: sampler.interval, format: { String(format: "%.1f%% used", $0) })
                        .frame(height: 34)
                        .padding(.top, 2)
                }
                .font(.system(size: 11))
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private func tint(_ color: Color) -> Gradient {
        Gradient(colors: [color.opacity(0.55), color])
    }
}

private struct MemoryRow: View {
    let label: String
    let bytes: UInt64
    let total: UInt64
    let gradient: Gradient
    var detail: String? = nil

    private var percent: Double { total == 0 ? 0 : Double(bytes) / Double(total) * 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                Spacer(minLength: 4)
                if let detail { Text(detail).foregroundStyle(.secondary) }
                Numeric(text: formatBytes(bytes), width: 68)
                Numeric(text: String(format: "%.0f%%", percent), width: 34, color: .secondary)
            }
            MeterBar(fraction: percent / 100, gradient: gradient)
        }
    }
}

/// Temperature groups (CPU clusters, GPU, battery) with heat-colored meters.
struct SensorsPanel: View {
    @Environment(Sampler.self) private var sampler

    var body: some View {
        Panel(title: "sensors", tint: .orange, trailing: trailing) {
            if sampler.temperatures.isEmpty {
                Text("no sensors").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(sampler.temperatures) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(t.name)
                                Spacer(minLength: 4)
                                Text(String(format: "max %.0f°", t.max)).foregroundStyle(.secondary)
                                Numeric(text: formatTemp(t.avg), width: 42, color: Palette.heat(t.avg))
                            }
                            .help("\(t.sensorCount) sensors")
                            MeterBar(fraction: Palette.heatFraction(t.avg), gradient: Palette.heatGradient)
                        }
                    }
                    HistoryGraph(values: sampler.cpuTempHistory.values, capacity: sampler.temperatureHistoryCapacity,
                                 range: Palette.heatRange, gradient: Palette.heatGradient,
                                 interval: TemperatureReader.interval, format: { String(format: "CPU %.1f°C", $0) })
                        .frame(height: 34)
                        .padding(.top, 2)
                        .help("CPU average temperature, last \(sampler.settings.historySeconds / 60) min")
                }
                .font(.system(size: 11).monospacedDigit())
            }
        }
    }

    private var trailing: String? {
        let age = Date().timeIntervalSince(sampler.lastTemperatureAt)
        return age > Sampler.temperatureStaleAfter && sampler.lastTemperatureAt != .distantPast
            ? String(format: "stale %.0fs", age) : nil
    }
}
