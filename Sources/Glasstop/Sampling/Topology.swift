import Foundation
import IOKit

/// Maps logical CPUs to perf levels using the device tree (IODeviceTree:/cpus/cpuN has
/// "logical-cpu-id" and "cluster-type" = "P"/"M"/"E"). The CPU index order does NOT follow
/// hw.perflevelN: on M5 Pro, C0–C11 are the "M" (Performance) cores and C12–C17 the
/// "P" (Super) cores.
enum Topology {
    static func coreGroups(logicalCPUs: Int) -> [CoreGroup] {
        let types = clusterTypes()
        let levels = perfLevels()
        guard !types.isEmpty else {
            return [CoreGroup(id: 0, name: "CPU", clusterType: nil, cpus: Array(0..<logicalCPUs))]
        }

        var byType: [Character: [Int]] = [:]
        for (cpu, type) in types { byType[type, default: []].append(cpu) }
        // Fastest first, same order as hw.perflevel0, 1, ...
        let ordered = byType.keys.sorted { rank($0) > rank($1) }
        let namesMatch = levels.count == ordered.count
            && zip(levels, ordered).allSatisfy { $0.count == byType[$1]?.count }

        return ordered.enumerated().map { i, type in
            CoreGroup(id: i,
                      name: namesMatch ? levels[i].name : fallbackName(type),
                      clusterType: type,
                      cpus: byType[type]!.sorted())
        }
    }

    private static func rank(_ type: Character) -> Int {
        switch type {
        case "P": return 3
        case "M": return 2
        case "E": return 1
        default: return 0
        }
    }

    private static func fallbackName(_ type: Character) -> String {
        switch type {
        case "P": return "P-cores"
        case "M": return "M-cores"
        case "E": return "E-cores"
        default: return "\(type)-cores"
        }
    }

    private static func perfLevels() -> [(name: String, count: Int)] {
        let n = sysctlInt("hw.nperflevels") ?? 0
        return (0..<max(n, 0)).compactMap { i in
            guard let c = sysctlInt("hw.perflevel\(i).logicalcpu") else { return nil }
            return (sysctlString("hw.perflevel\(i).name") ?? "Level \(i)", c)
        }
    }

    /// logical CPU index → cluster type letter.
    private static func clusterTypes() -> [Int: Character] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [:] }
        defer { IOObjectRelease(cpus) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var result: [Int: Character] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let id = property(entry, "logical-cpu-id") as? NSNumber,
                  let type = property(entry, "cluster-type") as? Data,
                  let byte = type.first, byte != 0 else { continue }
            result[id.intValue] = Character(UnicodeScalar(byte))
        }
        return result
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
