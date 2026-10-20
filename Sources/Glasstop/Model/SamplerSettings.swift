import Foundation

/// User-adjustable sampling cadence (Settings window). Persisted in UserDefaults.
struct SamplerSettings: Equatable {
    var interval: TimeInterval          // CPU / memory / UI refresh
    var historySeconds: Int             // length of the history graphs
    var processInterval: TimeInterval   // process table refresh

    /// Refresh interval range and step (the header's − / + arrows, like btop's).
    static let intervalRange: ClosedRange<TimeInterval> = 0.1...5
    static let intervalStep: TimeInterval = 0.01
    static let historyLengths = [60, 120, 300, 600]
    static let processIntervals: [TimeInterval] = [0.5, 1, 2, 5]
    /// Upper bound on points per history buffer, whatever the combination (memory stays flat).
    static let maxHistoryPoints = 2400

    static let `default` = SamplerSettings(interval: 0.5, historySeconds: 120, processInterval: 1)

    var historyCapacity: Int { min(max(Int((Double(historySeconds) / interval).rounded()), 2), Self.maxHistoryPoints) }
    /// Processes are sampled on every Nth tick (never more often than the tick itself).
    var processEveryNTicks: Int { max(1, Int((processInterval / interval).rounded())) }

    /// Clamped to `intervalRange` and snapped to 10 ms (avoids 0.30000000000000004).
    static func normalized(_ interval: TimeInterval) -> TimeInterval {
        let clamped = min(max(interval, intervalRange.lowerBound), intervalRange.upperBound)
        return (clamped / intervalStep).rounded() * intervalStep
    }

    /// `steps` × 10 ms faster (negative) or slower (positive).
    func steppingInterval(by steps: Int) -> SamplerSettings {
        var s = self
        s.interval = Self.normalized(interval + Double(steps) * Self.intervalStep)
        return s
    }

    private enum Key {
        static let interval = "sampleInterval"
        static let history = "historySeconds"
        static let process = "processInterval"
    }

    static func load() -> SamplerSettings {
        let d = UserDefaults.standard
        var s = SamplerSettings.default
        if let v = d.object(forKey: Key.interval) as? Double, v.isFinite { s.interval = normalized(v) }
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
