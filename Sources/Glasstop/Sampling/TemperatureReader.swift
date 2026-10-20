import CSensors
import Foundation

/// Temperatures, sampled on their own serial queue so a slow or hung IOKit call can never
/// stall CPU/memory sampling (a likely cause of btop's freezes).
///
/// Primary source: SMC float keys, grouped by family. Verified on M5 Pro with load tests:
/// `T` + lowercase cluster type per CPU cluster (Tp = "P"/Super, Tm = "M"/Performance,
/// Te = E-cores on older chips), Tg = GPU, TB<n>T = battery. Every key costs ~0.15 ms, so
/// they are read round-robin, `keysPerCycle` per cycle (each key refreshes every ~4 s).
///
/// Fallback: HID "PMU tdie" sensors (~0.75 ms each), read every few cycles.
final class TemperatureReader {
    static let interval: TimeInterval = 1
    static let keysPerCycle = 24
    static let hidEveryNCycles = 3
    static let hidRediscoverEveryNCycles = 60

    private struct Group {
        let id: String
        let name: String
        let isCPU: Bool
        let indices: [Int]     // into keys/values
    }

    private let queue = DispatchQueue(label: "com.hectorviov.glasstop.temperature", qos: .utility)
    private let coreGroups: [CoreGroup]
    private var timer: DispatchSourceTimer?

    // Everything below is touched only on `queue`.
    private var publish: (([TempGroupReading]) -> Void)?
    private var cycle = 0
    private var mode = Mode.undecided
    private var keys: [UInt32] = []
    private var values: [Float] = []
    private var groups: [Group] = []
    private var order: [Int] = []      // round-robin read order, interleaved across groups
    private var cursor = 0
    private var hidBuffer = [MPSensorReading](repeating: MPSensorReading(), count: 128)

    private enum Mode { case undecided, smc, hid }

    init(coreGroups: [CoreGroup]) {
        self.coreGroups = coreGroups
    }

    /// `publish` is called on the main thread after every cycle.
    func start(publish: @escaping ([TempGroupReading]) -> Void) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        queue.async { self.publish = publish }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Re-discovers sensors on the next cycle (e.g. after wake from sleep).
    func reset() {
        queue.async { [self] in
            mode = .undecided
            mp_smc_close()
            mp_temperature_reset()
        }
    }

    // MARK: Cycle (on `queue`)

    private func tick() {
        cycle &+= 1
        if mode == .undecided { setUp() }

        let readings: [TempGroupReading]
        switch mode {
        case .smc:
            readings = readSMCSlice()
        case .hid:
            if cycle % Self.hidRediscoverEveryNCycles == 0 { mp_temperature_reset() }
            guard cycle % Self.hidEveryNCycles == 1 else { return }
            readings = readHID()
        case .undecided:
            return
        }
        guard let publish else { return }
        DispatchQueue.main.async { publish(readings) }
    }

    private func setUp() {
        if mp_smc_open() != 0 {
            var all = [UInt32](repeating: 0, count: 2048)
            let n = Int(mp_smc_temperature_keys(&all, Int32(all.count)))
            configureSMC(Array(all.prefix(max(n, 0))))
            if !groups.isEmpty, groups.contains(where: \.isCPU) {
                mode = .smc
                return
            }
            mp_smc_close()
        }
        mode = .hid
    }

    // MARK: SMC

    private func configureSMC(_ candidates: [UInt32]) {
        var families: [(id: String, name: String, isCPU: Bool, match: (String) -> Bool)] = []
        for group in coreGroups {
            guard let type = group.clusterType else { continue }
            let prefix = "T" + String(type).lowercased()
            families.append(("cpu.\(type)", "\(group.name) cores", true, { $0.hasPrefix(prefix) }))
        }
        families.append(("gpu", "GPU", false, { $0.hasPrefix("Tg") }))
        families.append(("battery", "Battery", false, { k in
            let c = Array(k)
            return c.count == 4 && c[0] == "T" && c[1] == "B" && c[2].isNumber && c[3] == "T"
        }))

        var picked: [(key: UInt32, family: Int)] = []
        for key in candidates {
            let name = fourCC(key)
            if let f = families.firstIndex(where: { $0.match(name) }) { picked.append((key, f)) }
        }

        // One full read to drop dead sensors (NaN, 0, nonsense).
        var probe = picked.map(\.key)
        var probeValues = [Float](repeating: .nan, count: probe.count)
        _ = mp_smc_read_floats(&probe, Int32(probe.count), &probeValues)

        keys = []
        values = []
        var indicesByFamily = [[Int]](repeating: [], count: families.count)
        for (i, entry) in picked.enumerated() where Self.plausible(probeValues[i]) {
            indicesByFamily[entry.family].append(keys.count)
            keys.append(entry.key)
            values.append(probeValues[i])
        }
        groups = families.indices.compactMap { f in
            let idx = indicesByFamily[f]
            guard !idx.isEmpty else { return nil }
            return Group(id: families[f].id, name: families[f].name, isCPU: families[f].isCPU, indices: idx)
        }
        // Interleave: position-within-group / group-size, so every slice samples every group.
        order = groups.flatMap { g in g.indices.enumerated().map { (Double($0.offset) / Double(g.indices.count), $0.element) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        cursor = 0
    }

    private func readSMCSlice() -> [TempGroupReading] {
        let count = min(Self.keysPerCycle, order.count)
        var slice = [UInt32](repeating: 0, count: count)
        var sliceIdx = [Int](repeating: 0, count: count)
        for i in 0..<count {
            sliceIdx[i] = order[(cursor + i) % order.count]
            slice[i] = keys[sliceIdx[i]]
        }
        cursor = order.isEmpty ? 0 : (cursor + count) % order.count

        var out = [Float](repeating: .nan, count: count)
        _ = mp_smc_read_floats(&slice, Int32(count), &out)
        for i in 0..<count where Self.plausible(out[i]) { values[sliceIdx[i]] = out[i] }

        return groups.compactMap { g in
            summarize(id: g.id, name: g.name, isCPU: g.isCPU, g.indices.lazy.map { Double(self.values[$0]) })
        }
    }

    // MARK: HID fallback

    private func readHID() -> [TempGroupReading] {
        let n = Int(mp_read_temperatures(&hidBuffer, Int32(hidBuffer.count)))
        var cpu: [Double] = [], battery: [Double] = [], ssd: [Double] = []
        for i in 0..<max(n, 0) {
            let r = hidBuffer[i]
            guard r.celsius > 0, r.celsius < 150 else { continue }
            let name = stringFromCTuple(r.name).lowercased()
            if name.contains("tdie") { cpu.append(r.celsius) }
            else if name.contains("battery") { battery.append(r.celsius) }
            else if name.contains("nand") { ssd.append(r.celsius) }
        }
        return [
            summarize(id: "cpu", name: "CPU", isCPU: true, cpu),
            summarize(id: "battery", name: "Battery", isCPU: false, battery),
            summarize(id: "ssd", name: "SSD", isCPU: false, ssd),
        ].compactMap { $0 }
    }

    // MARK: Helpers

    private func summarize<S: Sequence>(id: String, name: String, isCPU: Bool, _ samples: S) -> TempGroupReading?
    where S.Element == Double {
        var sum = 0.0, maxValue = -Double.infinity, n = 0
        for v in samples where v > 0 && v < 150 {
            sum += v
            maxValue = max(maxValue, v)
            n += 1
        }
        guard n > 0 else { return nil }
        return TempGroupReading(id: id, name: name, isCPU: isCPU, avg: sum / Double(n), max: maxValue, sensorCount: n)
    }

    private static func plausible(_ v: Float) -> Bool { v.isFinite && v > 1 && v < 150 }

    private func fourCC(_ key: UInt32) -> String {
        let bytes = [UInt8(key >> 24 & 0xff), UInt8(key >> 16 & 0xff), UInt8(key >> 8 & 0xff), UInt8(key & 0xff)]
        return String(decoding: bytes, as: UTF8.self)
    }
}
