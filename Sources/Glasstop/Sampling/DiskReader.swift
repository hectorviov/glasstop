import Darwin
import Foundation
import IOKit

struct DiskIOReading {
    var readPerSecond: Double       // bytes/s, all block storage drivers
    var writePerSecond: Double
}

struct VolumeUsage: Identifiable, Equatable {
    var id: String { mountPoint }
    let name: String
    let mountPoint: String
    let total: UInt64
    let available: UInt64

    var used: UInt64 { total > available ? total - available : 0 }
    var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

/// Disk throughput from IOKit (`IOBlockStorageDriver` → "Statistics" → bytes read/written) and
/// volume usage from statfs. Only local, user-visible volumes are measured: a stalled network
/// mount can never block the sampler.
final class DiskReader {
    static let rediscoverEveryNSamples = 60
    static let maxVolumes = 6

    private var drivers: [io_registry_entry_t] = []
    private var samplesSinceDiscovery = Int.max
    private var previous: (read: UInt64, write: UInt64, atNs: UInt64)?
    private var volumeNames: [String: String] = [:]

    deinit { drivers.forEach { IOObjectRelease($0) } }

    // MARK: Throughput

    /// Returns nil on the first call (rates need two samples).
    func sampleIO() -> DiskIOReading? {
        if samplesSinceDiscovery >= Self.rediscoverEveryNSamples { discover() }   // disks come and go
        samplesSinceDiscovery += 1

        var read: UInt64 = 0, write: UInt64 = 0
        for driver in drivers {
            guard let stats = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSDictionary
            else { continue }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { previous = (read, write, now) }
        guard let prev = previous, now > prev.atNs else { return nil }
        let seconds = Double(now - prev.atNs) / 1e9
        // A disk detached since last time makes the sum drop: report zero, not garbage.
        let dr = read >= prev.read ? Double(read - prev.read) : 0
        let dw = write >= prev.write ? Double(write - prev.write) : 0
        return DiskIOReading(readPerSecond: dr / seconds, writePerSecond: dw / seconds)
    }

    func reset() {
        previous = nil
        samplesSinceDiscovery = Int.max
    }

    private func discover() {
        drivers.forEach { IOObjectRelease($0) }
        drivers = []
        samplesSinceDiscovery = 0
        previous = nil
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 { drivers.append(entry) }
    }

    // MARK: Volumes

    /// Local, browsable volumes ("/" plus /Volumes/*). getfsstat(MNT_NOWAIT) lists mounts without
    /// touching them; statfs is then called only on local ones.
    func volumes() -> [VolumeUsage] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // `statfs` is both a struct and a function in Darwin; spell the type out.
        var mounts = Array<Darwin.statfs>(repeating: Darwin.statfs(), count: Int(count) + 8)
        let got = Int(getfsstat(&mounts, Int32(mounts.count * MemoryLayout<Darwin.statfs>.stride), MNT_NOWAIT))
        guard got > 0 else { return [] }

        var result: [VolumeUsage] = []
        for mount in mounts.prefix(got) {
            let flags = UInt32(mount.f_flags)
            guard flags & UInt32(MNT_LOCAL) != 0, flags & UInt32(MNT_DONTBROWSE) == 0 else { continue }
            let path = stringFromCTuple(mount.f_mntonname)
            guard path == "/" || path.hasPrefix("/Volumes/") else { continue }

            var fresh = Darwin.statfs()
            guard statfs(path, &fresh) == 0 else { continue }
            let block = UInt64(fresh.f_bsize)
            result.append(VolumeUsage(name: displayName(path), mountPoint: path,
                                      total: UInt64(fresh.f_blocks) * block,
                                      available: UInt64(fresh.f_bavail) * block))
            if result.count >= Self.maxVolumes { break }
        }
        // Startup disk first, then by name.
        return result.sorted { ($0.mountPoint == "/" ? 0 : 1, $0.name) < ($1.mountPoint == "/" ? 0 : 1, $1.name) }
    }

    private func displayName(_ path: String) -> String {
        if let cached = volumeNames[path] { return cached }
        let name = FileManager.default.displayName(atPath: path)
        volumeNames[path] = name
        return name
    }
}
