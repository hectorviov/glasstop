import Darwin

/// Sends a signal after re-checking that the pid still belongs to the same process
/// (pid + start time), so a pid reused since the row was sampled is never hit.
enum ProcessSignal {
    enum Result: Equatable {
        case sent
        case gone                  // exited, or the pid now belongs to another process
        case failed(String)        // e.g. "Operation not permitted"
    }

    static func send(_ signal: Int32, to process: ProcessRow) -> Result {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process.pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              UInt64(info.pbi_start_tvsec) == process.start else {
            return .gone
        }
        return kill(process.pid, signal) == 0 ? .sent : .failed(String(cString: strerror(errno)))
    }
}
