import Foundation

struct CPUReading {
    var total: Double          // 0...100
    var perCore: [Double]      // 0...100, index = logical CPU
}

struct MemoryReading {
    var total: UInt64
    var used: UInt64           // app + wired + compressed (≈ Activity Monitor "Memory Used")
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var free: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64

    var usedPercent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }
    var available: UInt64 { total > used ? total - used : 0 }
}

/// Summary of one family of temperature sensors (e.g. all Super-core sensors).
struct TempGroupReading: Identifiable {
    let id: String             // stable key: "cpu.P", "cpu.M", "gpu", "battery", ...
    let name: String
    let isCPU: Bool
    let avg: Double
    let max: Double
    let sensorCount: Int
}

struct TempSummary {
    let avg: Double
    let max: Double
    let sensorCount: Int

    /// Sensor-count-weighted combination of several groups.
    static func combine(_ groups: [TempGroupReading]) -> TempSummary? {
        let n = groups.reduce(0) { $0 + $1.sensorCount }
        guard n > 0, let maxValue = groups.map(\.max).max() else { return nil }
        let avg = groups.reduce(0) { $0 + $1.avg * Double($1.sensorCount) } / Double(n)
        return TempSummary(avg: avg, max: maxValue, sensorCount: n)
    }
}

struct ProcessRow: Identifiable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let start: UInt64          // start time (s since epoch): pid + start identifies a process
    let name: String
    let path: String
    let user: String
    let threads: Int
    let cpu: Double            // % of one core (can exceed 100, like top)
    let memory: UInt64         // phys footprint (falls back to resident size)
    var gpu: Double = 0        // % of the GPU (available for every user's processes)
    let accessible: Bool       // false = owned by another user; no cpu/mem data

    var id: pid_t { pid }
}

struct LoadAverage {
    var one: Double
    var five: Double
    var fifteen: Double

    static func read() -> LoadAverage {
        var l = [Double](repeating: 0, count: 3)
        _ = getloadavg(&l, 3)
        return LoadAverage(one: l[0], five: l[1], fifteen: l[2])
    }
}

/// A set of logical CPUs of the same kind (one perf level), e.g. "Super ×6".
struct CoreGroup: Identifiable {
    let id: Int                // 0 = fastest
    let name: String           // from hw.perflevelN.name: "Super", "Performance", "Efficiency"...
    let clusterType: Character? // IODeviceTree cluster-type: "P", "M", "E"
    let cpus: [Int]            // logical CPU indices, ascending
}

struct SystemInfo {
    let chipName: String
    let coreCount: Int
    let coreGroups: [CoreGroup]
    let totalMemory: UInt64
    let bootTime: Date?

    var topologyDescription: String {
        var parts = ["\(coreCount) cores"]
        if coreGroups.count > 1 { parts += coreGroups.map { "\($0.name) ×\($0.cpus.count)" } }
        parts.append(formatBytes(totalMemory))
        return parts.joined(separator: " · ")
    }

    static func read() -> SystemInfo {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Mac"
        let cores = sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        return SystemInfo(chipName: chip, coreCount: cores,
                          coreGroups: Topology.coreGroups(logicalCPUs: cores),
                          totalMemory: ProcessInfo.processInfo.physicalMemory,
                          bootTime: sysctlBootTime())
    }
}

/// Everything one sampler tick produced. Optional fields = not sampled this tick.
struct Snapshot {
    var timestamp: Date
    var duration: TimeInterval
    var cpu: CPUReading?
    var memory: MemoryReading?
    var gpu: Double?
    var network: NetworkReading?
    var diskIO: DiskIOReading?
    var volumes: [VolumeUsage]?
    var processes: [ProcessRow]?
    var load: LoadAverage
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
}
