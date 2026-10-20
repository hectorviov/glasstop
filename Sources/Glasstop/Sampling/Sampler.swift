import Foundation
import Observation

/// Samples everything on background queues and publishes results on the main thread.
/// Nothing here ever blocks the UI; if a reader hangs, the header shows "stalled".
@Observable
final class Sampler {
    // MARK: Config
    static let interval: TimeInterval = 0.5
    static let historyCapacity = 240              // 2 min at 0.5 s
    static let processEveryNTicks = 2             // 1 s
    static let gpuEveryNTicks = 2                 // 1 s
    static let temperatureStaleAfter: TimeInterval = 10

    // MARK: Published state (mutated on main only)
    let system: SystemInfo
    private(set) var cpuTotal: Double = 0
    private(set) var perCore: [Double] = []
    private(set) var cpuHistory = RingBuffer<Double>(capacity: Sampler.historyCapacity)
    private(set) var perCoreHistory: [RingBuffer<Double>] = []
    private(set) var memory: MemoryReading?
    private(set) var memoryHistory = RingBuffer<Double>(capacity: Sampler.historyCapacity)
    private(set) var gpuUsage: Double?
    private(set) var gpuHistory = RingBuffer<Double>(capacity: Sampler.historyCapacity / Sampler.gpuEveryNTicks)
    private(set) var temperatures: [TempGroupReading] = []
    private(set) var cpuTempHistory = RingBuffer<Double>(capacity: Sampler.historyCapacity / 2)
    private(set) var lastTemperatureAt = Date.distantPast
    private(set) var processes: [ProcessRow] = []
    private(set) var loadAverage = LoadAverage(one: 0, five: 0, fifteen: 0)
    private(set) var lastSampleAt = Date.distantPast
    /// Slowest of the last few ticks (ticks alternate between cheap and process-sampling ones).
    private(set) var tickCost: TimeInterval = 0
    @ObservationIgnored private var recentDurations = RingBuffer<TimeInterval>(capacity: 4)

    var cpuTemperature: TempSummary? { TempSummary.combine(temperatures.filter(\.isCPU)) }

    func temperature(_ id: String) -> TempGroupReading? { temperatures.first { $0.id == id } }

    /// Temperature of a core group's cluster (falls back to the whole-CPU summary from HID).
    func temperature(for group: CoreGroup) -> Double? {
        if let type = group.clusterType, let t = temperature("cpu.\(type)") { return t.avg }
        return temperature("cpu")?.avg
    }

    // MARK: Background machinery (touched only on `queue`)
    @ObservationIgnored private let queue = DispatchQueue(label: "com.hectorviov.glasstop.sampler", qos: .utility)
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private let cpuReader = CPUReader()
    @ObservationIgnored private let memoryReader = MemoryReader()
    @ObservationIgnored private let processReader = ProcessReader()
    @ObservationIgnored private let gpuReader = GPUReader()
    @ObservationIgnored private let temperatureReader: TemperatureReader

    init() {
        let system = SystemInfo.read()
        self.system = system
        temperatureReader = TemperatureReader(coreGroups: system.coreGroups)
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // A DispatchSource timer coalesces missed fires: a slow tick never piles up.
        t.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        temperatureReader.start { [weak self] in self?.receiveTemperatures($0) }
    }

    /// Set by the window owner. While false, nothing is published to SwiftUI (no view
    /// updates at all); snapshots queue up (bounded) and are applied when visible again.
    @ObservationIgnored var isVisible = true {
        didSet { if isVisible && !oldValue { flushPending() } }
    }
    @ObservationIgnored private var pendingSnapshots: [Snapshot] = []
    @ObservationIgnored private var pendingTemperatures: [([TempGroupReading], Date)] = []

    func stop() {
        timer?.cancel()
        timer = nil
        temperatureReader.stop()
    }

    // MARK: Background tick

    private func tick() {
        let startNs = DispatchTime.now().uptimeNanoseconds
        tickCount &+= 1

        let cpu = cpuReader.sample()
        let memory = memoryReader.sample()
        let gpu = tickCount % Self.gpuEveryNTicks == 0 ? gpuReader.sample() : nil
        let procs = tickCount % Self.processEveryNTicks == 0 ? processReader.sample() : nil

        let duration = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9
        let snapshot = Snapshot(timestamp: Date(), duration: duration, cpu: cpu, memory: memory,
                                gpu: gpu, processes: procs, load: LoadAverage.read())

        DispatchQueue.main.async { [weak self] in self?.receive(snapshot) }
    }

    // MARK: Main-thread apply

    private func receive(_ s: Snapshot) {
        // Only the newest process list matters; dropping older ones keeps the queue small.
        if !pendingSnapshots.isEmpty, s.processes != nil {
            pendingSnapshots[pendingSnapshots.count - 1].processes = nil
        }
        pendingSnapshots.append(s)
        if pendingSnapshots.count > Self.historyCapacity {
            pendingSnapshots.removeFirst(pendingSnapshots.count - Self.historyCapacity)
        }
        if isVisible { flushPending() }
    }

    /// Temperatures arrive on their own schedule; they're applied together with the next
    /// sampler tick so the UI does one update (and one CA commit) per tick, not two.
    private func receiveTemperatures(_ readings: [TempGroupReading]) {
        pendingTemperatures.append((readings, Date()))
        if pendingTemperatures.count > cpuTempHistory.capacity {
            pendingTemperatures.removeFirst(pendingTemperatures.count - cpuTempHistory.capacity)
        }
    }

    private func flushPending() {
        for (readings, at) in pendingTemperatures { applyTemperatures(readings, at: at) }
        pendingTemperatures.removeAll(keepingCapacity: true)
        for s in pendingSnapshots { apply(s) }
        pendingSnapshots.removeAll(keepingCapacity: true)
    }

    private func apply(_ s: Snapshot) {
        if let c = s.cpu {
            cpuTotal = c.total
            perCore = c.perCore
            cpuHistory.append(c.total)

            var histories = perCoreHistory
            if histories.count != c.perCore.count {
                histories = c.perCore.map { _ in RingBuffer<Double>(capacity: Self.historyCapacity) }
            }
            for (i, v) in c.perCore.enumerated() { histories[i].append(v) }
            perCoreHistory = histories
        }
        if let m = s.memory {
            memory = m
            memoryHistory.append(m.usedPercent)
        }
        if let g = s.gpu {
            gpuUsage = g
            gpuHistory.append(g)
        }
        if let p = s.processes { processes = p }

        loadAverage = s.load
        lastSampleAt = s.timestamp
        recentDurations.append(s.duration)
        tickCost = recentDurations.values.max() ?? s.duration
    }

    private func applyTemperatures(_ readings: [TempGroupReading], at date: Date) {
        temperatures = readings
        lastTemperatureAt = date
        if let summary = TempSummary.combine(readings.filter(\.isCPU)) { cpuTempHistory.append(summary.avg) }
    }
}
