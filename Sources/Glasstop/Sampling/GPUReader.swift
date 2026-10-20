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
