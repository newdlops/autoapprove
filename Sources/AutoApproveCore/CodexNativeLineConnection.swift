import Foundation
import Darwin
import CNativePeer

/// A private native control connection. Calls serialize on one owned descriptor;
/// use from a utility task, never the main actor. No JSON can create its peer witness.
final class CodexNativeLineConnection {
    let peer: CodexNativeKernelPeer
    private let lock = NSLock()
    private var fd: Int32
    static var deadline: UInt64 { DispatchTime.now().uptimeNanoseconds + 2_000_000_000 }
    private static var failure: AppError {
        .message("Codex 로컬 제어 소켓의 소유권 또는 제한된 응답을 확인하지 못했습니다.")
    }
    init(path: String, deadline: UInt64 = CodexNativeLineConnection.deadline) throws {
        let opened = try Self.open(path: path, deadline: deadline)
        fd = opened.0; peer = opened.1
    }
    deinit { close() }
    func close() {
        lock.lock(); defer { lock.unlock() }
        closeUnlocked()
    }
    private func closeUnlocked() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
    private static func socketInfo(_ path: String) throws -> stat {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 100 else { throw failure }
        var parent = stat(), info = stat()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(directory, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_uid == getuid(), parent.st_mode & 0o077 == 0,
              lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw failure }
        return info
    }
    private static func wait(_ fd: Int32, _ events: Int16, deadline: UInt64) throws {
        while true {
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw failure }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(max(1, min((deadline - now) / 1_000_000, 100)))
            let result = Darwin.poll(&item, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw failure }
            if result == 0 { continue }
            guard item.revents & events != 0, item.revents & Int16(POLLNVAL) == 0 else { throw failure }
            return
        }
    }
    private static func open(path: String, deadline: UInt64) throws -> (Int32, CodexNativeKernelPeer) {
        try Task.checkCancellation()
        let before = try socketInfo(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure }
        var transferred = false
        defer { if !transferred { Darwin.close(fd) } }
        var one: Int32 = 1
        let descriptorFlags = fcntl(fd, F_GETFD), statusFlags = fcntl(fd, F_GETFL)
        guard descriptorFlags >= 0, statusFlags >= 0,
              fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0
        else { throw failure }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw failure }
            try wait(fd, Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw failure }
        }
        let peer = try CodexNativeKernelPeer.connectedSocket(fd)
        let after = try socketInfo(path)
        guard peer.identity.effectiveUid == getuid(), before.st_dev == after.st_dev,
              before.st_ino == after.st_ino else { throw failure }
        transferred = true
        return (fd, peer)
    }
    func exchange(_ request: Data, deadline: UInt64 = CodexNativeLineConnection.deadline) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        do {
            try sendUnlocked(request,deadline:deadline)
            return try readUnlocked(deadline:deadline)
        } catch {closeUnlocked();throw error}
    }
    /// A ready acknowledgment prevents a buffered line read from consuming the
    /// descriptor's tagged byte. The whole handshake has one deadline.
    func exchangeDescriptor(_ request:Data,descriptor:CodexMigrationLockDescriptor,
                            validateReady:(Data)throws->Void,deadline:UInt64=CodexNativeLineConnection.deadline)throws->Data {
        lock.lock();defer{lock.unlock()}
        do {
            try sendUnlocked(request,deadline:deadline)
            try validateReady(readUnlocked(deadline:deadline))
            try descriptor.withDescriptor { transferred in
                while true {
                    try Self.wait(fd,Int16(POLLOUT),deadline:deadline)
                    let result=aa_native_send_descriptor(fd,transferred)
                    if result==EINTR || result==EAGAIN || result==EWOULDBLOCK {continue}
                    guard result==0 else{throw Self.failure}
                    break
                }
            }
            return try readUnlocked(deadline:deadline)
        } catch {closeUnlocked();throw error}
    }
    private func sendUnlocked(_ request:Data,deadline:UInt64)throws {
            guard fd >= 0, (1...24_576).contains(request.count), !request.contains(10) else { throw Self.failure }
            var framed = request; framed.append(10)
            try framed.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try Self.wait(fd, Int16(POLLOUT), deadline: deadline)
                    let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                    if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                    guard count > 0 else { throw Self.failure }
                    offset += count
                }
            }
    }
    private func readUnlocked(deadline:UInt64)throws->Data {
            let maximumBody = 1_048_576
            var data = Data()
            while true {
                try Self.wait(fd, Int16(POLLIN), deadline: deadline)
                var bytes = [UInt8](repeating: 0, count: min(8192, maximumBody + 1 - data.count))
                guard !bytes.isEmpty else { throw Self.failure }
                let count = Darwin.recv(fd, &bytes, bytes.count, 0)
                if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                guard count > 0 else { throw Self.failure }
                data.append(contentsOf: bytes.prefix(count))
                if let end = data.firstIndex(of: 10) {
                    guard end == data.count - 1, end > 0, end <= maximumBody else { throw Self.failure }
                    return Data(data.prefix(upTo: end))
                }
                guard data.count <= maximumBody else { throw Self.failure }
            }
    }
}
