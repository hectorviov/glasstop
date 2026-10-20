import Darwin
import Foundation
import SystemConfiguration

/// One network interface that is up and has carried traffic.
struct NetworkInterface: Identifiable, Hashable {
    var id: String { bsdName }
    let bsdName: String             // "en0"
    let displayName: String?        // "Wi-Fi", "Thunderbolt Ethernet Slot 1" (SystemConfiguration)
    var isPhysical: Bool { bsdName.hasPrefix("en") }

    var label: String { displayName.map { "\($0) (\(bsdName))" } ?? bsdName }
}

struct NetworkReading {
    var rxPerSecond: Double         // bytes/s for the measured interface(s)
    var txPerSecond: Double
    var rxTotal: UInt64             // since boot
    var txTotal: UInt64
    var measured: [String]          // BSD names included in the numbers, e.g. ["en0", "en8"]
    var available: [NetworkInterface]   // everything that can be picked
}

/// Interface byte counters from the interface MIB (sysctl IFMIB_IFDATA → `ifmibdata`, 64-bit,
/// ~3 µs per interface). NET_RT_IFLIST2's `if_data64` byte counters come back truncated to
/// 32 bits on macOS 27 (packets match netstat, bytes wrap at 4 GB), so they aren't used.
///
/// By default measures all physical interfaces (`en*`: Wi-Fi, Ethernet, Thunderbolt Ethernet);
/// VPN tunnels (utun*) and bridges would count the same traffic twice. `selected` narrows it to
/// one interface (any active one, tunnels included).
final class NetworkReader {
    static let namesRefreshEvery: TimeInterval = 60

    /// nil = all physical interfaces. Set on the sampler queue.
    var selected: String? {
        didSet { if selected != oldValue { previous = nil } }   // new baseline, no fake spike
    }

    private var previous: (rx: UInt64, tx: UInt64, atNs: UInt64)?
    private var displayNames: [String: String] = [:]
    private var namesRefreshedNs: UInt64 = 0

    /// Returns nil on the first call (rates need two samples).
    func sample() -> NetworkReading? {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var countMib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        guard sysctl(&countMib, 5, &count, &size, nil, 0) == 0, count > 0 else { return nil }

        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if namesRefreshedNs == 0 || Double(now - namesRefreshedNs) / 1e9 >= Self.namesRefreshEvery {
            refreshDisplayNames()
            namesRefreshedNs = now
        }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var measured: [String] = []
        var available: [NetworkInterface] = []
        var data = ifmibdata()
        for index in 1...count {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
            size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, 6, &data, &size, nil, 0) == 0 else { continue }
            let flags = Int32(truncatingIfNeeded: data.ifmd_flags)   // unsigned; high bits are set on some interfaces
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = stringFromCTuple(data.ifmd_name)
            let ibytes = data.ifmd_data.ifi_ibytes, obytes = data.ifmd_data.ifi_obytes
            guard ibytes > 0 || obytes > 0 else { continue }          // never used: not worth listing
            available.append(NetworkInterface(bsdName: name, displayName: displayNames[name]))

            let include = selected.map { $0 == name } ?? name.hasPrefix("en")
            guard include else { continue }
            rx &+= ibytes
            tx &+= obytes
            measured.append(name)
        }

        defer { previous = (rx, tx, now) }
        guard let prev = previous, now > prev.atNs else { return nil }
        let seconds = Double(now - prev.atNs) / 1e9
        // Counters reset when an interface goes away: treat a decrease as zero, not a huge spike.
        let drx = rx >= prev.rx ? Double(rx - prev.rx) : 0
        let dtx = tx >= prev.tx ? Double(tx - prev.tx) : 0
        // Physical interfaces first, then by name.
        available.sort { ($0.isPhysical ? 0 : 1, $0.bsdName) < ($1.isPhysical ? 0 : 1, $1.bsdName) }
        return NetworkReading(rxPerSecond: drx / seconds, txPerSecond: dtx / seconds,
                              rxTotal: rx, txTotal: tx, measured: measured, available: available)
    }

    /// Wake/interface changes: start a fresh baseline.
    func reset() {
        previous = nil
        namesRefreshedNs = 0
    }

    /// "en0" → "Wi-Fi" etc. from SystemConfiguration (only physical/configured interfaces have one).
    private func refreshDisplayNames() {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        var names: [String: String] = [:]
        for interface in interfaces {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
            names[bsd] = display
        }
        displayNames = names
    }
}
