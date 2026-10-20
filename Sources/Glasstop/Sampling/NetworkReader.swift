import Darwin
import Foundation

struct NetworkReading {
    var rxPerSecond: Double         // bytes/s, summed over the measured interfaces
    var txPerSecond: Double
    var rxTotal: UInt64             // since boot
    var txTotal: UInt64
    var interfaces: [String]        // measured interfaces with traffic, e.g. ["en0"]
}

/// Interface byte counters from the interface MIB (sysctl IFMIB_IFDATA → `ifmibdata`, 64-bit,
/// ~3 µs per interface). NET_RT_IFLIST2's `if_data64` byte counters come back truncated to
/// 32 bits on macOS 27 (packets match netstat, bytes wrap at 4 GB), so they aren't used.
/// Measures physical interfaces (`en*`: Wi-Fi, Ethernet, Thunderbolt Ethernet); VPN tunnels
/// (utun*) and bridges would count the same traffic twice.
final class NetworkReader {
    private var previous: (rx: UInt64, tx: UInt64, atNs: UInt64)?

    /// Returns nil on the first call (rates need two samples).
    func sample() -> NetworkReading? {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var countMib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        guard sysctl(&countMib, 5, &count, &size, nil, 0) == 0, count > 0 else { return nil }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var active: [String] = []
        var data = ifmibdata()
        for index in 1...count {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
            size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, 6, &data, &size, nil, 0) == 0 else { continue }
            let flags = Int32(truncatingIfNeeded: data.ifmd_flags)   // unsigned; high bits are set on some interfaces
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = stringFromCTuple(data.ifmd_name)
            guard name.hasPrefix("en") else { continue }
            rx &+= data.ifmd_data.ifi_ibytes
            tx &+= data.ifmd_data.ifi_obytes
            if data.ifmd_data.ifi_ibytes > 0 || data.ifmd_data.ifi_obytes > 0 { active.append(name) }
        }

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { previous = (rx, tx, now) }
        guard let prev = previous, now > prev.atNs else { return nil }
        let seconds = Double(now - prev.atNs) / 1e9
        // Counters reset when an interface goes away: treat a decrease as zero, not a huge spike.
        let drx = rx >= prev.rx ? Double(rx - prev.rx) : 0
        let dtx = tx >= prev.tx ? Double(tx - prev.tx) : 0
        return NetworkReading(rxPerSecond: drx / seconds, txPerSecond: dtx / seconds,
                              rxTotal: rx, txTotal: tx, interfaces: active)
    }

    /// Wake/interface changes: start a fresh baseline.
    func reset() { previous = nil }
}
