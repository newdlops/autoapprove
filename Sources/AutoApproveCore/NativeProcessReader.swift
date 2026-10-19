import Foundation
import Darwin

/// Read-only, fresh kernel metadata. No process, environment or executable-path
/// cache crosses reads; callers still verify the original before sending input.
enum NativeProcessReader {
    private static let codexName = Array("codex".utf8)
    private static let claudeName = Array("claude".utf8)
    private static let nodeName = Array("node".utf8)
    static func read(pid: Int32? = nil) throws -> [ProcessRecord] {
        try autoreleasepool { try records(pid: pid, sessionsOnly: false) }
    }
    static func readSessions() throws -> [ProcessRecord] {
        try autoreleasepool { try records(pid: nil, sessionsOnly: true) }
    }
    private static func records(pid: Int32?, sessionsOnly: Bool) throws -> [ProcessRecord] {
        let entries = try snapshot(pid: pid)
        guard !entries.isEmpty else { return [] }
        // Complete and targeted reads promise the same launch name and start
        // identity as ps, including arbitrary managers, hosts and shell PIDs.
        // Only periodic session discovery may omit unrelated process details.
        var detailedPIDs = Set<Int32>()
        if sessionsOnly {
            var candidates: [Int32] = []
            for entry in entries where isAgentCandidate(entry) { candidates.append(entry.kp_proc.p_pid) }
            guard !candidates.isEmpty else { return [] }
            // Retain just PID -> parent for the ancestry walk, not another
            // copy of every large kernel process record.
            var byPID: [Int32: Int32] = [:]
            byPID.reserveCapacity(entries.count)
            for entry in entries where byPID[entry.kp_proc.p_pid] == nil {
                byPID[entry.kp_proc.p_pid] = Int32(entry.kp_eproc.e_ppid)
            }
            detailedPIDs.reserveCapacity(min(entries.count, candidates.count * 8))
            for candidate in candidates {
                var current = candidate
                // Process trees share long parent chains. The global set both
                // deduplicates detail reads and stops ancestry walks already
                // covered by an earlier candidate, avoiding one temporary Set
                // allocation per candidate process.
                for _ in 0..<60 where current > 0 && detailedPIDs.insert(current).inserted {
                    guard let parent = byPID[current] else { break }
                    current = parent
                }
            }
        }
        var arguments: [UInt8] = [], path: [UInt8] = []
        if !sessionsOnly || !detailedPIDs.isEmpty {
            arguments = [UInt8](repeating: 0, count: try argumentLimit())
            path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        }
        var formatter: DateFormatter?
        var dates: [Int64: String] = [:], devices: [dev_t: String] = [:]
        return try entries.compactMap { entry -> ProcessRecord? in
            try Task.checkCancellation()
            let process = entry.kp_proc, extra = entry.kp_eproc
            if sessionsOnly && !detailedPIDs.contains(process.p_pid) { return nil }
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
            else {
                let dateFormatter: DateFormatter
                if let formatter { dateFormatter = formatter }
                else {
                    let value = DateFormatter()
                    value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = .current
                    value.dateFormat = "EEE MMM d HH:mm:ss yyyy"
                    formatter = value; dateFormatter = value
                }
                let value = dateFormatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
                dates[seconds] = value
                started = value
            }
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

    private static func isAgentCandidate(_ entry: kinfo_proc) -> Bool {
        let process = entry.kp_proc
        // Inspect the fixed-size kernel name directly. Building a Swift String
        // (and lowercased copy) for every process on every discovery pass is
        // unnecessary; detailed argv/path data is fetched only for matches.
        if shortNameMatches(process, codexName) || shortNameMatches(process, claudeName) { return true }
        // Claude's versioned CLI can appear under its Node runtime name. Limit
        // this fallback to TTY processes; unrelated background Node services
        // do not need argv reads or ancestry enrichment.
        guard entry.kp_eproc.e_tdev != -1 else { return false }
        if shortNameMatches(process, nodeName) { return true }
        return withUnsafeBytes(of: process.p_comm) { bytes in
            guard let first = bytes.first else { return false }
            return (48...57).contains(first)
        }
    }

    private static func shortNameMatches(_ process: extern_proc, _ expected: [UInt8]) -> Bool {
        withUnsafeBytes(of: process.p_comm) { bytes in
            guard bytes.count > expected.count, bytes[expected.count] == 0 else { return false }
            for index in expected.indices {
                let value = bytes[index]
                let lowercase = (65...90).contains(value) ? value + 32 : value
                if lowercase != expected[index] { return false }
            }
            return true
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
            let count = length / stride
            values.removeLast(values.count - count)
            guard pid != nil || values.contains(where: { $0.kp_proc.p_pid == getpid() }) else { throw POSIXError(.EIO) }
            return pid.map { selected in values.filter { $0.kp_proc.p_pid == selected } } ?? values
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
