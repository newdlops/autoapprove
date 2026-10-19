import Foundation
import Darwin
import TerminalInputSupport

/// Fresh paths from a same-user process's live descriptors, in unspecified
/// order. Never opens its files, caches descriptor numbers, changes the target
/// or launches a command.
public enum ProcessOpenFiles {
    public static func paths(pid: Int32, expectedStart: String? = nil, limit: Int = 4096, timeout: TimeInterval = 4) throws -> [String] {
        try readPaths(pid: pid, expectedStart: expectedStart, limit: limit, timeout: timeout, selection: .all)
    }

    /// The history reader needs only the live rollout selected by this CLI.
    /// Filter the kernel path bytes before allocating Swift strings for the
    /// process's unrelated open files.
    public static func codexRolloutPaths(pid: Int32, expectedStart: String? = nil, limit: Int = 4096, timeout: TimeInterval = 4) throws -> [String] {
        try readPaths(pid: pid, expectedStart: expectedStart, limit: limit, timeout: timeout, selection: .codexRollouts)
    }

    /// Reply routing needs the open Codex database locations, not every file
    /// descriptor owned by the CLI.
    public static func codexMetadataPaths(pid: Int32, expectedStart: String? = nil, limit: Int = 4096, timeout: TimeInterval = 4) throws -> [String] {
        try readPaths(pid: pid, expectedStart: expectedStart, limit: limit, timeout: timeout, selection: .codexMetadata)
    }

    private enum Selection { case all, codexRollouts, codexMetadata }

    private static func readPaths(pid: Int32, expectedStart: String?, limit: Int, timeout: TimeInterval,
                                  selection: Selection) throws -> [String] {
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
            if count != size, Self.isTransientDescriptorPathError(error) { continue }
            guard count == size else { throw failure(error) }
            let path = withUnsafeBytes(of:value.pvip.vip_path) { bytes -> String? in
                guard let end = bytes.firstIndex(of:0) else { return nil }
                let rawPath = bytes[..<end]
                guard rawPath.first == 47, shouldKeep(rawPath, selection: selection) else { return nil }
                return String(bytes:rawPath,encoding:.utf8)
            }
            if let path { paths.insert(path) }
        }
        guard identity.sameProcess(as:try TTYInputIdentity.capture(pid:pid)) else { throw POSIXError(.ESTALE) }
        try check()
        return Array(paths)
    }

    private static func shouldKeep<C: BidirectionalCollection>(_ path: C, selection: Selection) -> Bool where C.Element == UInt8 {
        let isAll: Bool
        if case .all = selection { isAll = true } else { isAll = false }
        guard !isAll else { return true }
        guard let slash = path.lastIndex(of: 47) else { return false }
        let name = path[path.index(after: slash)..<path.endIndex]
        switch selection {
        case .all: return true
        case .codexRollouts:
            return name.starts(with: "rollout-".utf8) && name.suffix(6).elementsEqual(".jsonl".utf8)
        case .codexMetadata:
            return name.elementsEqual("state_5.sqlite".utf8) ||
                name.elementsEqual("thread_history_1.sqlite".utf8) ||
                name.elementsEqual("queue_1.sqlite".utf8) ||
                name.elementsEqual("logs_2.sqlite".utf8) ||
                (name.starts(with: "rollout-".utf8) && name.suffix(6).elementsEqual(".jsonl".utf8))
        }
    }

    static func isTransientDescriptorPathError(_ code: Int32) -> Bool {
        // Descriptor closure races and stale network filesystem handles affect
        // only that path. The final process-lifetime check still rejects a PID
        // replacement; callers fail closed if the omitted path was required.
        code == EBADF || code == ENOENT || code == ESTALE
    }

    private static func failure(_ code: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO) }
}
