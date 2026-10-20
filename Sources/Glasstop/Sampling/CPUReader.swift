import Darwin

/// Per-core and total CPU usage from host_processor_info tick deltas.
final class CPUReader {
    private struct Ticks { var user, system, idle, nice: UInt32 }

    private let host = mach_host_self()   // cached: mach_host_self() leaks a send right per call
    private var previous: [Ticks] = []

    /// Returns nil on the first call (needs two samples for a delta).
    func sample() -> CPUReading? {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoArray, &infoCount)
        guard kr == KERN_SUCCESS, let info = infoArray else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        var current: [Ticks] = []
        current.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let b = i * stride
            current.append(Ticks(
                user: UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])
            ))
        }

        let prev = previous
        previous = current
        guard prev.count == current.count else { return nil }

        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        var busySum: UInt64 = 0
        var allSum: UInt64 = 0
        for (now, before) in zip(current, prev) {
            // &- handles 32-bit tick counter wraparound.
            let busy = UInt64(now.user &- before.user)
                + UInt64(now.system &- before.system)
                + UInt64(now.nice &- before.nice)
            let all = busy + UInt64(now.idle &- before.idle)
            busySum += busy
            allSum += all
            perCore.append(all == 0 ? 0 : Double(busy) / Double(all) * 100)
        }
        let total = allSum == 0 ? 0 : Double(busySum) / Double(allSum) * 100
        return CPUReading(total: total, perCore: perCore)
    }
}
