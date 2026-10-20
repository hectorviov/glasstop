import SwiftUI

/// btop-style CPU box: total history on the left, per-core list grouped by perf level on the right.
struct CPUPanel: View {
    @Environment(Sampler.self) private var sampler

    static let coreListWidth: CGFloat = 380
    static let spacing: CGFloat = 14

    var body: some View {
        Panel(title: "cpu", tint: .green, trailing: uptimeText) {
            // The core list sets the box height; the graph fills exactly that height as a
            // background. (An "equal-height columns" .fixedSize layout gave the graph's layer
            // an enormous backing store: ~90 MB of GPU memory.)
            CoreList()
                .frame(width: Self.coreListWidth)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(alignment: .leading) {
                    VStack(alignment: .leading, spacing: 4) {
                        TotalsGraph()
                        HStack {
                            Spacer()
                            Text(String(format: "load %.2f  %.2f  %.2f",
                                        sampler.loadAverage.one, sampler.loadAverage.five, sampler.loadAverage.fifteen))
                        }
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, Self.coreListWidth + Self.spacing)
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

/// btop's mirrored totals graph: CPU grows up from the middle line, GPU hangs down from it.
private struct TotalsGraph: View {
    @Environment(Sampler.self) private var sampler
    private static let cpuShare: CGFloat = 0.58

    var body: some View {
        if sampler.gpuUsage == nil {
            cpuGraph   // no accelerator stats: CPU only
        } else {
            GeometryReader { geo in
                let labelHeight: CGFloat = 16
                let graphs = max(geo.size.height - labelHeight, 0)
                VStack(spacing: 0) {
                    cpuGraph.frame(height: graphs * Self.cpuShare)
                    HStack(spacing: 6) {
                        Text(String(format: "▲ cpu %.1f%%", sampler.cpuTotal))
                        Spacer()
                        Text(String(format: "▼ gpu %.0f%%", sampler.gpuUsage ?? 0))
                    }
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(height: labelHeight)
                    HistoryGraph(values: sampler.gpuHistory.values, capacity: sampler.historyCapacity,
                                 showsGrid: false, inverted: true, interval: sampler.interval,
                                 format: { String(format: "GPU %.0f%%", $0) })
                        .frame(height: graphs * (1 - Self.cpuShare))
                }
            }
        }
    }

    private var cpuGraph: some View {
        HistoryGraph(values: sampler.cpuHistory.values, capacity: sampler.historyCapacity,
                     interval: sampler.interval, format: { String(format: "CPU %.1f%%", $0) })
    }
}

private struct CoreList: View {
    @Environment(Sampler.self) private var sampler

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SummaryRow(label: "CPU", percent: sampler.cpuTotal, temp: sampler.cpuTemperature?.avg,
                       tempHelp: sampler.cpuTemperature.map { String(format: "avg %.1f°C · max %.1f°C · %d sensors", $0.avg, $0.max, $0.sensorCount) })
                .font(.system(size: 11, weight: .semibold))

            ForEach(sampler.system.coreGroups) { group in
                GroupHeader(group: group, percent: average(group.cpus), temp: sampler.temperature(for: group))
                    .padding(.top, 3)
                // Plain Grid: with 18 cells a lazy container buys nothing.
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                    ForEach(Array(stride(from: 0, to: group.cpus.count, by: 2)), id: \.self) { i in
                        GridRow {
                            coreRow(group.cpus[i], group: group)
                            if i + 1 < group.cpus.count { coreRow(group.cpus[i + 1], group: group) }
                        }
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

    private func coreRow(_ cpu: Int, group: CoreGroup) -> CoreRow {
        let points = CoreRow.points(interval: sampler.interval)
        return CoreRow(index: cpu,
                       value: cpu < sampler.perCore.count ? sampler.perCore[cpu] : 0,
                       history: cpu < sampler.perCoreHistory.count
                           ? Array(sampler.perCoreHistory[cpu].values.suffix(points)) : [],
                       points: points,
                       tint: Palette.groupTint(group.id))
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
                .foregroundStyle(Palette.groupTint(group.id))
                .fixedSize()
            Rectangle().fill(Palette.groupTint(group.id).opacity(0.25)).frame(height: 1)
            Numeric(text: String(format: "%.0f%%", percent), width: 36, color: loadColor(percent))
            Numeric(text: formatTemp(temp), width: 40, color: temp.map(Palette.heat) ?? .secondary)
        }
        .font(.system(size: 10.5, weight: .medium))
    }
}

/// "C12 ▁▂▃▅ 30%"
private struct CoreRow: View {
    /// Sparklines show the last 30 s.
    static func points(interval: TimeInterval) -> Int { max(Int((30 / interval).rounded()), 2) }

    let index: Int
    let value: Double
    let history: [Double]
    let points: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text("C\(index)")
                .foregroundStyle(tint.opacity(0.85))
                .frame(width: 26, alignment: .leading)
            HistoryGraph(values: history, capacity: points, showsGrid: false, lineWidth: 1)
                .frame(height: 13)
            Numeric(text: String(format: "%.0f%%", value), width: 32, color: loadColor(value))
        }
        .monospacedDigit()
    }
}
