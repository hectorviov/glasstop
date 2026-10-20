import Darwin
import Foundation

/// Process list via libproc (same source as top/btop). One proc_pidinfo call per pid
/// for name/uid/cpu/threads, plus proc_pid_rusage for the memory footprint.
final class ProcessReader {
    /// Idle processes (< 0.1% CPU) re-read their footprint only every N samples.
    static let idleFootprintEveryNSamples = 5

    private struct Prev { let start: UInt64; let cpuNs: Double; let footprint: UInt64?; let footprintAge: Int }
    /// Name + path, cached per process identity. `comm` changes on exec(), so a process
    /// that execs gets its new name/path even though pid and start time stay the same.
    private struct Identity { let start: UInt64; let comm: (UInt64, UInt64); let name: String; let path: String }

    private var previous: [pid_t: Prev] = [:]
    private var identityCache: [pid_t: Identity] = [:]
    private var userCache: [uid_t: String] = [:]
    private var lastWallNs: UInt64 = 0
    private var pidBuffer = [pid_t](repeating: 0, count: 4096)
    private var pathBuffer = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE

    /// pti_total_user/system are in mach absolute time units (NOT ns on Apple Silicon).
    private let ticksToNs: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
    }()

    /// Returns nil on the first call: CPU % needs two samples, and publishing a table of
    /// zeros would flash a meaningless sort order.
    func sample() -> [ProcessRow]? {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let wallDelta = lastWallNs == 0 ? 0 : Double(now - lastWallNs)
        lastWallNs = now

        let needed = Int(proc_listallpids(nil, 0))
        if needed + 64 > pidBuffer.count {
            pidBuffer = [pid_t](repeating: 0, count: needed + 512)
        }
        let n = Int(proc_listallpids(&pidBuffer, Int32(pidBuffer.count * MemoryLayout<pid_t>.size)))
        guard n > 0 else { return wallDelta > 0 ? [] : nil }

        var rows: [ProcessRow] = []
        rows.reserveCapacity(n)
        var nextPrev: [pid_t: Prev] = [:]
        nextPrev.reserveCapacity(n)
        var nextIdentities: [pid_t: Identity] = [:]
        nextIdentities.reserveCapacity(n)

        for i in 0..<min(n, pidBuffer.count) {
            let pid = pidBuffer[i]
            if pid <= 0 { continue }

            var info = proc_taskallinfo()
            let infoSize = Int32(MemoryLayout<proc_taskallinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, infoSize) == infoSize {
                let bsd = info.pbsd
                let task = info.ptinfo
                let start = UInt64(bsd.pbi_start_tvsec)
                let cpuNs = Double(task.pti_total_user &+ task.pti_total_system) * ticksToNs

                var cpu = 0.0
                let prev = previous[pid].flatMap { $0.start == start ? $0 : nil }
                if wallDelta > 0, let prev {
                    cpu = max(0, (cpuNs - prev.cpuNs) / wallDelta * 100)
                }

                // proc_pid_rusage is a third syscall per pid; idle processes reuse their last value.
                var memory = prev?.footprint
                var age = (prev?.footprintAge ?? 0) + 1
                if memory == nil || cpu >= 0.1 || age >= Self.idleFootprintEveryNSamples {
                    memory = footprint(pid)
                    age = 0
                }
                nextPrev[pid] = Prev(start: start, cpuNs: cpuNs, footprint: memory, footprintAge: age)

                let id = identity(pid, bsd: bsd, into: &nextIdentities)
                rows.append(ProcessRow(
                    pid: pid,
                    name: id.name,
                    path: id.path,
                    user: userName(bsd.pbi_uid),
                    threads: Int(task.pti_threadnum),
                    cpu: cpu,
                    memory: memory ?? task.pti_resident_size,
                    accessible: true
                ))
            } else {
                // Other users' processes (root, _windowserver...) — no task info without privileges.
                var bsd = proc_bsdinfo()
                let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { continue }
                let id = identity(pid, bsd: bsd, into: &nextIdentities)
                rows.append(ProcessRow(
                    pid: pid,
                    name: id.name,
                    path: id.path,
                    user: userName(bsd.pbi_uid),
                    threads: 0,
                    cpu: 0,
                    memory: 0,
                    accessible: false
                ))
            }
        }

        previous = nextPrev      // drops entries for exited processes
        identityCache = nextIdentities
        return wallDelta > 0 ? rows : nil
    }

    // MARK: Helpers

    private func identity(_ pid: pid_t, bsd: proc_bsdinfo, into next: inout [pid_t: Identity]) -> Identity {
        let start = UInt64(bsd.pbi_start_tvsec)
        let comm = withUnsafeBytes(of: bsd.pbi_comm) {
            ($0.loadUnaligned(as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        if let cached = identityCache[pid], cached.start == start, cached.comm == comm {
            next[pid] = cached
            return cached
        }
        let len = Int(proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)))
        let path = len > 0
            ? String(decoding: pathBuffer[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : ""
        let id = Identity(start: start, comm: comm, name: name(bsd: bsd, path: path), path: path)
        next[pid] = id
        return id
    }

    private func name(bsd: proc_bsdinfo, path: String) -> String {
        let name = stringFromCTuple(bsd.pbi_name)
        if !name.isEmpty { return name }
        let comm = stringFromCTuple(bsd.pbi_comm)
        if !comm.isEmpty { return comm }
        return (path as NSString).lastPathComponent
    }

    private func userName(_ uid: uid_t) -> String {
        if let cached = userCache[uid] { return cached }
        var result = String(uid)
        if let pw = getpwuid(uid), let cname = pw.pointee.pw_name {
            result = String(cString: cname)
        }
        userCache[uid] = result
        return result
    }

    /// Physical footprint — what Activity Monitor shows in its Memory column.
    private func footprint(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage.ri_phys_footprint : nil
    }
}
