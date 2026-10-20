import SwiftUI

/// btop-style CPU box: total history on the left, per-core list grouped by perf level on the right.
struct CPUPanel: View {
    @Environment(Sampler.self) private var sampler

    var body: some View {
        Panel(title: "cpu", tint: .green, trailing: uptimeText) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HistoryGraph(values: sampler.cpuHistory.values, capacity: Sampler.historyCapacity)
                    HStack {
                        Text(String(format: "total %.1f%%", sampler.cpuTotal))
                        Spacer()
                        Text(String(format: "load %.2f  %.2f  %.2f",
                                    sampler.loadAverage.one, sampler.loadAverage.five, sampler.loadAverage.fifteen))
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)

                CoreList()
                    .frame(width: 380)
            }
        }
    }

    private var uptimeText: String? {
        guard let boot = sampler.system.bootTime else { return nil }
        let s = Int(Date().timeIntervalSince(boot))
        let days = s / 86400, hours = s % 86400 / 3600, minutes = s % 3600 / 60
        return days > 0 ? String(format: "up %dd %02d:%02d", days, hours, minutes)
                        : String(format: "up %02d:%02d", hours, minutes)
    }
}

private struct CoreList: View {
    @Environment(Sampler.self) private var sampler
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SummaryRow(label: "CPU", percent: sampler.cpuTotal, temp: sampler.cpuTemperature?.avg,
                       tempHelp: sampler.cpuTemperature.map { String(format: "avg %.1f°C · max %.1f°C · %d sensors", $0.avg, $0.max, $0.sensorCount) })
                .font(.system(size: 11, weight: .semibold))

            ForEach(sampler.system.coreGroups) { group in
                GroupHeader(group: group, percent: average(group.cpus), temp: sampler.temperature(for: group))
                    .padding(.top, 3)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 2) {
                    ForEach(group.cpus, id: \.self) { cpu in
                        CoreRow(index: cpu,
                                value: cpu < sampler.perCore.count ? sampler.perCore[cpu] : 0,
                                history: cpu < sampler.perCoreHistory.count
                                    ? Array(sampler.perCoreHistory[cpu].values.suffix(CoreRow.points)) : [])
                    }
                }
            }

            if let gpu = sampler.gpuUsage {
                SummaryRow(label: "GPU", percent: gpu, temp: sampler.temperature("gpu")?.avg, tempHelp: nil)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.top, 4)
            }
        }
        .font(.system(size: 11))
    }

    private func average(_ cpus: [Int]) -> Double {
        let values = cpus.compactMap { $0 < sampler.perCore.count ? sampler.perCore[$0] : nil }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

/// "CPU [meter] 12%  45°C"
private struct SummaryRow: View {
    let label: String
    let percent: Double
    let temp: Double?
    let tempHelp: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 30, alignment: .leading)
            MeterBar(fraction: percent / 100)
            Numeric(text: String(format: "%.0f%%", percent), width: 36, color: loadColor(percent))
            Numeric(text: formatTemp(temp), width: 40, color: temp.map(Palette.heat) ?? .secondary)
                .help(tempHelp ?? "")
        }
    }
}

/// "Super ×6 ───────── avg 23%  58°C"
private struct GroupHeader: View {
    let group: CoreGroup
    let percent: Double
    let temp: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text("\(group.name) ×\(group.cpus.count)")
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            Numeric(text: String(format: "%.0f%%", percent), width: 36, color: loadColor(percent))
            Numeric(text: formatTemp(temp), width: 40, color: temp.map(Palette.heat) ?? .secondary)
        }
        .font(.system(size: 10.5, weight: .medium))
    }
}

/// "C12 ▁▂▃▅ 30%"
private struct CoreRow: View {
    static let points = 60     // last 30 s

    let index: Int
    let value: Double
    let history: [Double]

    var body: some View {
        HStack(spacing: 6) {
            Text("C\(index)")
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            HistoryGraph(values: history, capacity: Self.points, showsGrid: false, lineWidth: 1)
                .frame(height: 13)
            Numeric(text: String(format: "%.0f%%", value), width: 32, color: loadColor(value))
        }
        .monospacedDigit()
    }
}
