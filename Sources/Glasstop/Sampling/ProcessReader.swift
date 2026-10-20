import Darwin
import Foundation

/// Process list via libproc (same source as top/btop). One proc_pidinfo call per pid
/// for name/uid/cpu/threads, plus proc_pid_rusage for the memory footprint.
final class ProcessReader {
    /// Idle processes (< 0.1% CPU) re-read their footprint only every N samples.
    static let idleFootprintEveryNSamples = 5

    private struct Prev { let start: UInt64; let cpuNs: Double; let footprint: UInt64?; let footprintAge: Int }
    private struct PathEntry { let start: UInt64; let path: String }

    private var previous: [pid_t: Prev] = [:]
    private var pathCache: [pid_t: PathEntry] = [:]
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
        var nextPaths: [pid_t: PathEntry] = [:]
        nextPaths.reserveCapacity(n)

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

                let path = resolvePath(pid, start: start, into: &nextPaths)
                rows.append(ProcessRow(
                    pid: pid,
                    name: name(bsd: bsd, path: path),
                    path: path,
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
                let path = resolvePath(pid, start: UInt64(bsd.pbi_start_tvsec), into: &nextPaths)
                rows.append(ProcessRow(
                    pid: pid,
                    name: name(bsd: bsd, path: path),
                    path: path,
                    user: userName(bsd.pbi_uid),
                    threads: 0,
                    cpu: 0,
                    memory: 0,
                    accessible: false
                ))
            }
        }

        previous = nextPrev      // drops entries for exited processes
        pathCache = nextPaths
        return wallDelta > 0 ? rows : nil
    }

    // MARK: Helpers

    private func resolvePath(_ pid: pid_t, start: UInt64, into next: inout [pid_t: PathEntry]) -> String {
        if let cached = pathCache[pid], cached.start == start {
            next[pid] = cached
            return cached.path
        }
        let len = Int(proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)))
        let path = len > 0
            ? String(decoding: pathBuffer[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : ""
        next[pid] = PathEntry(start: start, path: path)
        return path
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
