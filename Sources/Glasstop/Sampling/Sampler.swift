import Foundation
import Observation

/// Samples everything on background queues and publishes results on the main thread.
/// Nothing here ever blocks the UI; if a reader hangs, the header shows "stalled".
@Observable
final class Sampler {
    // MARK: Config
    static let temperatureStaleAfter: TimeInterval = 10

    /// Current cadence (Settings window). Change with `apply(_:)`.
    private(set) var settings: SamplerSettings
    var interval: TimeInterval { settings.interval }
    var historyCapacity: Int { settings.historyCapacity }
    var temperatureHistoryCapacity: Int {
        min(max(Int(Double(settings.historySeconds) / TemperatureReader.interval), 2), SamplerSettings.maxHistoryPoints)
    }

    // MARK: Published state (mutated on main only)
    let system: SystemInfo
    private(set) var cpuTotal: Double = 0
    private(set) var perCore: [Double] = []
    private(set) var cpuHistory: RingBuffer<Double>
    private(set) var perCoreHistory: [RingBuffer<Double>] = []
    private(set) var memory: MemoryReading?
    private(set) var memoryHistory: RingBuffer<Double>
    private(set) var gpuUsage: Double?
    /// Same time axis as `cpuHistory` (sampled every tick), for the mirrored CPU/GPU graph.
    private(set) var gpuHistory: RingBuffer<Double>
    private(set) var temperatures: [TempGroupReading] = []
    private(set) var cpuTempHistory: RingBuffer<Double>
    private(set) var lastTemperatureAt = Date.distantPast
    private(set) var processes: [ProcessRow] = []
    private(set) var loadAverage = LoadAverage(one: 0, five: 0, fifteen: 0)
    private(set) var lastSampleAt = Date.distantPast
    /// Slowest of the last few ticks (ticks alternate between cheap and process-sampling ones).
    private(set) var tickCost: TimeInterval = 0
    /// Gaps between delivered samples longer than the stall threshold (sampler or main thread
    /// stuck). Measured in uptime, which doesn't advance during system sleep.
    @ObservationIgnored private(set) var stallCount = 0
    @ObservationIgnored private var lastReceiveUptimeNs: UInt64 = 0
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
    @ObservationIgnored private var processEveryNTicks: Int     // queue-side copy of the cadence
    @ObservationIgnored private let cpuReader = CPUReader()
    @ObservationIgnored private let memoryReader = MemoryReader()
    @ObservationIgnored private let processReader = ProcessReader()
    @ObservationIgnored private let gpuReader = GPUReader()
    @ObservationIgnored private let temperatureReader: TemperatureReader

    init(settings: SamplerSettings = .load()) {
        let system = SystemInfo.read()
        self.system = system
        self.settings = settings
        processEveryNTicks = settings.processEveryNTicks
        cpuHistory = RingBuffer(capacity: settings.historyCapacity)
        memoryHistory = RingBuffer(capacity: settings.historyCapacity)
        gpuHistory = RingBuffer(capacity: settings.historyCapacity)
        cpuTempHistory = RingBuffer(capacity: 2)
        temperatureReader = TemperatureReader(coreGroups: system.coreGroups)
        cpuTempHistory = RingBuffer(capacity: temperatureHistoryCapacity)
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { [weak self] in self?.tick() }
        schedule(t, interval: settings.interval, startNow: true)
        t.resume()
        timer = t
        temperatureReader.start { [weak self] in self?.receiveTemperatures($0) }
    }

    /// A DispatchSource timer coalesces missed fires: a slow tick never piles up.
    private func schedule(_ t: DispatchSourceTimer, interval: TimeInterval, startNow: Bool) {
        let leeway = DispatchTimeInterval.milliseconds(max(10, Int(interval * 100)))   // 10%
        t.schedule(deadline: startNow ? .now() : .now() + interval, repeating: interval, leeway: leeway)
    }

    /// Main thread. Applies a new cadence live: buffers keep their newest points.
    func apply(_ new: SamplerSettings) {
        guard new != settings else { return }
        settings = new
        cpuHistory = cpuHistory.resized(to: new.historyCapacity)
        memoryHistory = memoryHistory.resized(to: new.historyCapacity)
        gpuHistory = gpuHistory.resized(to: new.historyCapacity)
        perCoreHistory = perCoreHistory.map { $0.resized(to: new.historyCapacity) }
        cpuTempHistory = cpuTempHistory.resized(to: temperatureHistoryCapacity)
        lastReceiveUptimeNs = 0            // a slower interval is not a stall
        let processEvery = new.processEveryNTicks
        queue.async { [weak self] in
            guard let self else { return }
            self.processEveryNTicks = processEvery
            if let timer = self.timer { self.schedule(timer, interval: new.interval, startNow: false) }
        }
    }

    /// Set by the window owner. While false, nothing is published to SwiftUI (no view
    /// updates at all); snapshots queue up (bounded) and are applied when visible again.
    @ObservationIgnored var isVisible = true {
        didSet { if isVisible && !oldValue { flushPending() } }
    }
    /// Called on main for every tick, visible or not (drives the menu bar CPU %).
    @ObservationIgnored var onTick: ((Snapshot) -> Void)?
    @ObservationIgnored private var pendingSnapshots: [Snapshot] = []
    @ObservationIgnored private var pendingTemperatures: [([TempGroupReading], Date)] = []

    func stop() {
        timer?.cancel()
        timer = nil
        temperatureReader.stop()
    }

    /// After wake from sleep: new baselines, and sensors are re-discovered (IOKit services
    /// can be torn down across sleep).
    func resetAfterWake() {
        queue.async { [weak self] in
            self?.cpuReader.reset()
            self?.processReader.reset()
        }
        temperatureReader.reset()
        lastReceiveUptimeNs = 0
    }

    // MARK: Background tick

    private func tick() {
        let startNs = DispatchTime.now().uptimeNanoseconds
        tickCount &+= 1

        let cpu = cpuReader.sample()
        let memory = memoryReader.sample()
        let gpu = gpuReader.sample()        // ~0.2 ms: every tick, so it shares the CPU graph's time axis
        let procs = tickCount % processEveryNTicks == 0 ? processReader.sample() : nil

        let duration = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e9
        let snapshot = Snapshot(timestamp: Date(), duration: duration, cpu: cpu, memory: memory,
                                gpu: gpu, processes: procs, load: LoadAverage.read())

        DispatchQueue.main.async { [weak self] in self?.receive(snapshot) }
    }

    // MARK: Main-thread apply

    private func receive(_ s: Snapshot) {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if lastReceiveUptimeNs != 0 {
            let gap = Double(nowNs - lastReceiveUptimeNs) / 1e9
            if gap > max(2, interval * 3) {
                stallCount += 1
                NSLog("Glasstop: sampler stall %.1f s (total %d)", gap, stallCount)
            }
        }
        lastReceiveUptimeNs = nowNs
        onTick?(s)
        // Only the newest process list matters; dropping older ones keeps the queue small.
        if !pendingSnapshots.isEmpty, s.processes != nil {
            pendingSnapshots[pendingSnapshots.count - 1].processes = nil
        }
        pendingSnapshots.append(s)
        if pendingSnapshots.count > historyCapacity {
            pendingSnapshots.removeFirst(pendingSnapshots.count - historyCapacity)
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
                histories = c.perCore.map { _ in RingBuffer<Double>(capacity: historyCapacity) }
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
