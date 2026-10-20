import Foundation

/// User-adjustable sampling cadence (Settings window). Persisted in UserDefaults.
struct SamplerSettings: Equatable {
    var interval: TimeInterval          // CPU / memory / UI refresh
    var historySeconds: Int             // length of the history graphs
    var processInterval: TimeInterval   // process table refresh

    static let intervals: [TimeInterval] = [0.25, 0.5, 1, 2]
    static let historyLengths = [60, 120, 300, 600]
    static let processIntervals: [TimeInterval] = [0.5, 1, 2, 5]
    /// Upper bound on points per history buffer, whatever the combination (memory stays flat).
    static let maxHistoryPoints = 2400

    static let `default` = SamplerSettings(interval: 0.5, historySeconds: 120, processInterval: 1)

    var historyCapacity: Int { min(max(Int((Double(historySeconds) / interval).rounded()), 2), Self.maxHistoryPoints) }
    /// Processes are sampled on every Nth tick (never more often than the tick itself).
    var processEveryNTicks: Int { max(1, Int((processInterval / interval).rounded())) }
    /// GPU utilization roughly once per second.
    var gpuEveryNTicks: Int { max(1, Int((1 / interval).rounded())) }

    private enum Key {
        static let interval = "sampleInterval"
        static let history = "historySeconds"
        static let process = "processInterval"
    }

    static func load() -> SamplerSettings {
        let d = UserDefaults.standard
        var s = SamplerSettings.default
        if let v = d.object(forKey: Key.interval) as? Double, intervals.contains(v) { s.interval = v }
        if let v = d.object(forKey: Key.history) as? Int, historyLengths.contains(v) { s.historySeconds = v }
        if let v = d.object(forKey: Key.process) as? Double, processIntervals.contains(v) { s.processInterval = v }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(interval, forKey: Key.interval)
        d.set(historySeconds, forKey: Key.history)
        d.set(processInterval, forKey: Key.process)
    }
}
