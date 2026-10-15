import Foundation
import Darwin
import TerminalInputSupport

/// Fresh paths from a same-user process's live descriptors. Never opens its
/// files, caches descriptor numbers, changes the target or launches a command.
public enum ProcessOpenFiles {
    public static func paths(pid: Int32, expectedStart: String? = nil, limit: Int = 4096, timeout: TimeInterval = 4) throws -> [String] {
        guard pid > 0, (1...4096).contains(limit), timeout.isFinite, (0...4).contains(timeout) else { throw POSIXError(.EINVAL) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func check() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw POSIXError(.ETIMEDOUT) }
        }
        try check()
        let identity = try TTYInputIdentity.capture(pid:pid)
        guard identity.uid == getuid(), identity.effectiveUID == getuid() else { throw POSIXError(.EACCES) }
        if let expectedStart, identity.processStart != expectedStart { throw POSIXError(.ESTALE) }
        let stride = MemoryLayout<proc_fdinfo>.stride, maximum = limit * stride
        var descriptors: [proc_fdinfo]?
        for _ in 0..<3 {
            try check()
            errno = 0
            let required = proc_pidinfo(pid,PROC_PIDLISTFDS,0,nil,0), queryError = errno
            guard required > 0 || required == 0 && queryError == 0 else { throw failure(queryError) }
            guard required % Int32(stride) == 0, Int(required) <= maximum else { throw POSIXError(.EOVERFLOW) }
            let capacity = min(maximum,Int(required) + 32 * stride)
            var values = [proc_fdinfo](repeating:proc_fdinfo(),count:capacity/stride)
            errno = 0
            let count = values.withUnsafeMutableBytes { proc_pidinfo(pid,PROC_PIDLISTFDS,0,$0.baseAddress,Int32($0.count)) }
            let readError = errno
            guard count > 0 || count == 0 && readError == 0 else { throw failure(readError) }
            guard Int(count) <= capacity, count % Int32(stride) == 0 else { throw POSIXError(.EIO) }
            // A full buffer may be a truncated, growing table. Re-read a bounded
            // size instead of treating an incomplete set as authoritative.
            if Int(count) == capacity { continue }
            descriptors = Array(values.prefix(Int(count)/stride)); break
        }
        guard let descriptors else { throw POSIXError(.EOVERFLOW) }
        var paths = Set<String>()
        for descriptor in descriptors where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            try check()
            var value = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout.size(ofValue:value))
            errno = 0
            let count = proc_pidfdinfo(pid,descriptor.proc_fd,PROC_PIDFDVNODEPATHINFO,&value,size), error = errno
            if count == 0, error == EBADF || error == ENOENT { continue } // Closed while reading; never reuse an old path.
            guard count == size else { throw failure(error) }
            let path = withUnsafeBytes(of:value.pvip.vip_path) { bytes -> String? in
                guard let end = bytes.firstIndex(of:0) else { return nil }
                return String(bytes:bytes[..<end],encoding:.utf8)
            }
            if let path, path.hasPrefix("/") { paths.insert(path) }
        }
        guard identity.sameProcess(as:try TTYInputIdentity.capture(pid:pid)) else { throw POSIXError(.ESTALE) }
        try check()
        return paths.sorted()
    }
    private static func failure(_ code: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO) }
}
