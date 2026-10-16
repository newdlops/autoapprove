import Foundation
import Darwin

public typealias JSONObject = [String: Any]

private func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AppError.message("앱 데이터 경로가 너무 깁니다.") }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}

private func configureSocket(_ fd: Int32, timeout: Int) {
    let descriptorFlags = fcntl(fd, F_GETFD)
    if descriptorFlags >= 0 { _ = fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    var time = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout.size(ofValue: time)))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout.size(ofValue: time)))
}

public final class SocketConnection: @unchecked Sendable {
    public let id = UUID().uuidString
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var buffer = Data()
    private var reader: DispatchSourceRead?
    private static let maximumMessageBytes = 2_000_000
    init(fd: Int32) { self.fd = fd; configureSocket(fd, timeout: 20) }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        Darwin.shutdown(fd, SHUT_RDWR)
        // A source must finish cancellation before its descriptor can be reused.
        if let reader { self.reader = nil; reader.cancel() }
        else { Darwin.close(fd) }
    }
    @discardableResult public func send(_ object: JSONObject) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(10)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        return data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }; sent += count
            }
            return true
        }
    }
    func receive() -> JSONObject? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let data = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
            }
            guard buffer.count < Self.maximumMessageBytes else { return nil }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    /// Long-lived bridge and hook waits share readiness notifications instead of
    /// occupying one blocking worker per connection. Writes retain their existing
    /// all-bytes-sent result; no approval or input is queued or replayed here.
    fileprivate func startReceiving(on queue: DispatchQueue,
                                    handler: @escaping (JSONObject, SocketConnection) -> Void,
                                    disconnected: @escaping (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, reader == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader = source
        source.setEventHandler { [weak self] in self?.readReady(on: queue, handler: handler) }
        let descriptor = fd, id = id
        source.setCancelHandler { Darwin.close(descriptor); disconnected(id) }
        source.resume()
    }

    private func readReady(on queue: DispatchQueue, handler: @escaping (JSONObject, SocketConnection) -> Void) {
        // Bound each turn so a noisy client cannot monopolize other connections.
        let batch = readBatch()
        for message in batch.messages {
            lock.lock(); let open = !closed; lock.unlock()
            guard open else { return }
            handler(message, self)
        }
        if batch.ended { close() }
        else if batch.buffered {
            // There may be complete lines left after the kernel buffer emptied.
            queue.async { [weak self] in self?.readReady(on: queue, handler: handler) }
        }
    }

    private func readBatch() -> (messages: [JSONObject], ended: Bool, buffered: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return ([], false, false) }
        var messages: [JSONObject] = [], received = 0
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 8192) { bytes in
            while messages.count < 64 {
                if let newline = buffer.firstIndex(of: 10) {
                    guard buffer.distance(from: buffer.startIndex, to: newline) <= Self.maximumMessageBytes,
                          let object = (try? JSONSerialization.jsonObject(with: buffer.prefix(upTo: newline))) as? JSONObject else {
                        return (messages, true, false)
                    }
                    buffer.removeSubrange(...newline); messages.append(object)
                    continue
                }
                guard buffer.count < Self.maximumMessageBytes else { return (messages, true, false) }
                guard received < 262_144 else { break }
                let count = Darwin.recv(fd, bytes.baseAddress, bytes.count, MSG_DONTWAIT)
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return (messages, false, false) }
                guard count > 0 else { return (messages, true, false) }
                buffer.append(bytes.baseAddress!, count: count); received += count
            }
            return (messages, false, buffer.contains(10))
        }
    }
    deinit { close() }
}

public final class SocketServer: @unchecked Sendable {
    private var fd: Int32 = -1
    private let path: String
    private let handler: (JSONObject, SocketConnection) -> Void
    private let disconnected: (String) -> Void
    private let queue = DispatchQueue(label: "autoapprove.local-socket", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var listener: DispatchSourceRead?
    private var peers: [String: SocketConnection] = [:]
    private let maximumConnections: Int
    public init(path: String, maximumConnections: Int = 256,
                handler: @escaping (JSONObject, SocketConnection) -> Void, disconnected: @escaping (String) -> Void) {
        self.path = path; self.handler = handler; self.disconnected = disconnected
        self.maximumConnections = max(1, min(maximumConnections, 1024))
        queue.setSpecific(key: queueKey, value: true)
    }
    public func start() throws {
        try onQueue { try startListener() }
    }
    private func onQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try operation() }
        return try queue.sync(execute: operation)
    }
    private func startListener() throws {
        guard listener == nil else { throw AppError.message("AutoApprove가 이미 실행 중입니다.") }
        var address = try socketAddress(path)
        if FileManager.default.fileExists(atPath: path) {
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            let existing = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            let probeError = errno
            Darwin.close(probe)
            if existing == 0 { throw AppError.message("AutoApprove가 이미 실행 중입니다.") }
            guard probeError == ECONNREFUSED || probeError == ENOENT else { throw AppError.message("기존 연결 소켓을 확인하지 못했습니다.") }
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else { throw AppError.message("연결 경로에 다른 파일이 있습니다.") }
            guard unlink(path) == 0 else { throw AppError.message("이전 연결 소켓을 정리하지 못했습니다.") }
        }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError.message("로컬 연결을 만들지 못했습니다.") }
        let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { Darwin.close(fd); fd = -1; throw AppError.message("로컬 연결을 열지 못했습니다: \(String(cString: strerror(errno)))") }
        guard chmod(path, 0o600) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd); fd = -1; unlink(path); throw AppError.message("로컬 연결 수신에 실패했습니다.")
        }
        let descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        listener = source
        source.setEventHandler { [weak self] in self?.acceptReady(descriptor) }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }
    private func acceptReady(_ descriptor: Int32) {
        guard descriptor == fd, listener != nil else { return }
        for _ in 0..<32 {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard peers.count < maximumConnections, getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(client); continue
            }
            // macOS does not require accepted sockets to inherit O_NONBLOCK.
            // Explicitly keep synchronous send() semantics on every platform.
            let flags = fcntl(client, F_GETFL)
            guard flags >= 0, fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0 else { Darwin.close(client); continue }
            let peer = SocketConnection(fd: client)
            peers[peer.id] = peer
            let disconnected = disconnected
            // A slow writer may wait in the existing synchronous handler. Keep
            // its serial work separate so it cannot stall healthy peers.
            let receiveQueue = DispatchQueue(label: "autoapprove.local-peer", qos: .utility)
            peer.startReceiving(on: receiveQueue, handler: handler, disconnected: { [weak self] id in
                guard let self else { disconnected(id); return }
                self.queue.async { [weak self] in
                    self?.peers.removeValue(forKey: id)
                    disconnected(id)
                }
            })
        }
    }
    public func stop() {
        onQueue {
            guard let listener else { return }
            self.listener = nil
            Darwin.shutdown(fd, SHUT_RDWR); listener.cancel(); fd = -1
            let connections = Array(peers.values); peers.removeAll()
            connections.forEach { $0.close() }; unlink(path)
        }
    }
    deinit { stop() }
}

public enum SocketClient {
    public static func request(path: String, message: JSONObject, timeout: Int = 3) throws -> JSONObject {
        var address = try socketAddress(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError.message("연결을 생성하지 못했습니다.") }
        let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw AppError.message("AutoApprove 앱을 먼저 실행해주세요.") }
        let connection = SocketConnection(fd: fd)
        configureSocket(fd, timeout: timeout)
        defer { connection.close() }
        guard connection.send(message), let response = connection.receive() else { throw AppError.message("AutoApprove가 응답하지 않았습니다.") }
        if let error = response["error"] as? String { throw AppError.message(error) }
        return response["result"] as? JSONObject ?? response
    }
}
