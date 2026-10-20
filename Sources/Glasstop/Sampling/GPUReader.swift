import Foundation
import IOKit

/// GPU utilization from the IOAccelerator's "PerformanceStatistics" (same number Activity
/// Monitor's GPU History uses). One registry property read per sample.
final class GPUReader {
    private var service: io_registry_entry_t = 0

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// 0...100, or nil if there's no accelerator or the key is missing.
    func sample() -> Double? {
        if service == 0 {
            service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
            guard service != 0 else { return nil }
        }
        guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSDictionary,
              let value = stats["Device Utilization %"] as? NSNumber else {
            IOObjectRelease(service)   // stale after a GPU restart; rediscover next time
            service = 0
            return nil
        }
        return min(max(value.doubleValue, 0), 100)
    }
}

/// Per-process GPU time, the source of Activity Monitor's "% GPU": each Metal client of the
/// accelerator (`AGXDeviceUserClient`) carries "IOUserClientCreator" ("pid 425, WindowServer")
/// and "AppUsage" entries with `accumulatedGPUTime` in ns. GPU % = Δ GPU time / Δ wall time,
/// summed over a process's clients. Readable for every user's processes (~1.4 ms for ~120
/// clients), so it runs at the process-list cadence.
final class GPUProcessReader {
    /// Last accumulated time per client (registry entry ID): a process opening or closing a
    /// client never produces a fake spike or a negative delta.
    private var previous: [UInt64: UInt64] = [:]
    private var lastWallNs: UInt64 = 0

    /// % of the GPU per pid (only pids with GPU time in this interval). Empty on the first call.
    func sample() -> [pid_t: Double] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let wall = lastWallNs == 0 ? 0 : Double(now - lastWallNs)
        lastWallNs = now

        var current: [UInt64: UInt64] = [:]
        current.reserveCapacity(previous.count + 16)
        var busyNs: [pid_t: Double] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &accelerators) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(accelerators) }
        while case let accelerator = IOIteratorNext(accelerators), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [NSDictionary], !usage.isEmpty,
                      let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                      let pid = Self.pid(fromCreator: creator) else { continue }
                var entryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(client, &entryID) == KERN_SUCCESS else { continue }
                var total: UInt64 = 0
                for entry in usage { total &+= (entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
                current[entryID] = total
                if wall > 0, let before = previous[entryID], total > before {
                    busyNs[pid, default: 0] += Double(total - before)
                }
            }
        }
        previous = current       // drops closed clients
        guard wall > 0 else { return [:] }
        return busyNs.mapValues { min($0 / wall * 100, 100) }
    }

    func reset() {
        previous = [:]
        lastWallNs = 0
    }

    /// "pid 425, WindowServer" → 425
    private static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid "), let comma = creator.firstIndex(of: ",") else { return nil }
        return pid_t(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma])
    }
}
