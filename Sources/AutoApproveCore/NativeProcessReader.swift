import Foundation
import Darwin

/// Read-only, fresh kernel metadata. No process, environment or executable-path
/// cache crosses reads; callers still verify the original before sending input.
enum NativeProcessReader {
    static func read(pid: Int32? = nil) throws -> [ProcessRecord] {
        try autoreleasepool { try records(pid: pid) }
    }
    private static func records(pid: Int32?) throws -> [ProcessRecord] {
        let entries = try snapshot(pid: pid)
        guard !entries.isEmpty else { return [] }
        let argumentsLimit = try argumentLimit()
        var arguments = [UInt8](repeating: 0, count: argumentsLimit)
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        var dates: [Int64: String] = [:], devices: [dev_t: String] = [:]
        return try entries.compactMap { entry -> ProcessRecord? in
            try Task.checkCancellation()
            let process = entry.kp_proc, extra = entry.kp_eproc
            let executable = launchName(entry, buffer: &arguments, path: &path)
            var parent = extra.e_ppid, group = extra.e_pgid, foreground = extra.e_tpgid, device = extra.e_tdev
            if process.p_pid > 0 {
                var latest = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                errno = 0
                let count = proc_pidinfo(process.p_pid, PROC_PIDTBSDINFO, 0, &latest, size), error = errno
                if count == size {
                    // PID reuse while reading arguments must not combine a new
                    // program with the old process's start/TTY identity.
                    guard latest.pbi_pid == UInt32(process.p_pid),
                          latest.pbi_start_tvsec == UInt64(process.p_un.__p_starttime.tv_sec),
                          latest.pbi_start_tvusec == UInt64(process.p_un.__p_starttime.tv_usec) else { return nil }
                    parent = Int32(bitPattern: latest.pbi_ppid); group = Int32(bitPattern: latest.pbi_pgid)
                    foreground = Int32(bitPattern: latest.e_tpgid); device = Int32(bitPattern: latest.e_tdev)
                } else if (count == 0 && error == 0) || error == ESRCH || error == ENOENT { return nil }
                else if error != EPERM && error != EACCES { throw failure(error) }
                // A restricted system process keeps only its kernel snapshot;
                // this never confers input permission or requests more access.
            }
            let seconds = Int64(process.p_un.__p_starttime.tv_sec)
            let started: String
            if let value = dates[seconds] { started = value }
            else { started = formatter.string(from: Date(timeIntervalSince1970: Double(seconds))); dates[seconds] = started }
            let tty: String
            if let value = devices[device] { tty = value }
            else {
                tty = NativeTerminalDevice.name(device)
                devices[device] = tty
            }
            return ProcessRecord(pid: process.p_pid, parent: parent, tty: tty, processGroup: group,
                                 foregroundGroup: foreground, started: started, executable: executable)
        }
    }

    private static func snapshot(pid: Int32?) throws -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, pid == nil ? KERN_PROC_ALL : KERN_PROC_PID, pid ?? 0]
        let stride = MemoryLayout<kinfo_proc>.stride, maximum = 32 * 1024 * 1024
        for _ in 0..<3 {
            try Task.checkCancellation()
            var length = 0
            guard sysctl(&mib, 4, nil, &length, nil, 0) == 0 else { throw failure(errno) }
            guard length <= maximum, length % stride == 0 else { throw POSIXError(.EOVERFLOW) }
            let capacity = min(maximum / stride, length / stride + 64)
            var values = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            length = capacity * stride
            errno = 0
            let status = values.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &length, nil, 0) }, error = errno
            // A process table can grow between the size and data queries. Never
            // publish a partial list as authoritative session termination.
            if status != 0 && error == ENOMEM { continue }
            guard status == 0, length <= capacity * stride, length % stride == 0 else { throw failure(error) }
            let result = Array(values.prefix(length / stride))
            guard pid != nil || result.contains(where: { $0.kp_proc.p_pid == getpid() }) else { throw POSIXError(.EIO) }
            return pid.map { selected in result.filter { $0.kp_proc.p_pid == selected } } ?? result
        }
        throw POSIXError(.EOVERFLOW)
    }

    private static func argumentLimit() throws -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX], limit: Int32 = 0, size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &limit, &size, nil, 0) == 0, limit > 4, limit <= 4 * 1024 * 1024 else { throw POSIXError(.EIO) }
        return Int(limit)
    }

    private static func launchName(_ entry: kinfo_proc, buffer: inout [UInt8], path: inout [UInt8]) -> String {
        let process = entry.kp_proc
        if process.p_stat == SZOMB { return "<defunct>" }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, process.p_pid], count = buffer.count
        let status = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &count, nil, 0) }
        if status == 0, count > 4, count <= buffer.count {
            // Read only argv[0]. Arguments and environment are neither decoded
            // nor retained, logged or sent to any client.
            var index = MemoryLayout<Int32>.size
            while index < count && buffer[index] != 0 { index += 1 }
            while index < count && buffer[index] == 0 { index += 1 }
            let begin = index
            while index < count && buffer[index] != 0 { index += 1 }
            if index > begin, index < count { return String(decoding: buffer[begin..<index], as: UTF8.self).trimmingCharacters(in: .whitespaces) }
        }
        // ps has privileges unavailable to this app for some system argv[0]
        // values. Use an accessible executable path, then its short kernel name.
        // System paths can be canonical rather than their launch-time aliases.
        if proc_pidpath(process.p_pid, &path, UInt32(path.count)) > 0, let end = path.firstIndex(of: 0), end > 0 {
            return String(decoding: path[..<end], as: UTF8.self)
        }
        let name = withUnsafeBytes(of: process.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return "(\(name))"
    }
    private static func failure(_ error: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
}
