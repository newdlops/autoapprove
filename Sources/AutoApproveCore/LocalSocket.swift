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
    init(fd: Int32) { self.fd = fd; configureSocket(fd, timeout: 20) }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }; closed = true
        Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd)
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
            guard buffer.count < 2_000_000 else { return nil }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}

public final class SocketServer: @unchecked Sendable {
    private var fd: Int32 = -1
    private let path: String
    private let handler: (JSONObject, SocketConnection) -> Void
    private let disconnected: (String) -> Void
    private let lock = NSLock()
    private var peers: [String: SocketConnection] = [:]
    public init(path: String, handler: @escaping (JSONObject, SocketConnection) -> Void, disconnected: @escaping (String) -> Void) {
        self.path = path; self.handler = handler; self.disconnected = disconnected
    }
    public func start() throws {
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
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { Darwin.close(fd); fd = -1; throw AppError.message("로컬 연결 수신에 실패했습니다.") }
        let listener = fd
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self {
                let client = Darwin.accept(listener, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { Darwin.close(client); continue }
                let peer = SocketConnection(fd: client)
                self.lock.lock(); self.peers[peer.id] = peer; self.lock.unlock()
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    while let message = peer.receive() { self?.handler(message, peer) }
                    peer.close()
                    self?.lock.lock(); self?.peers.removeValue(forKey: peer.id); self?.lock.unlock()
                    self?.disconnected(peer.id)
                }
            }
        }
    }
    public func stop() {
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1
        lock.lock(); let connections = Array(peers.values); peers.removeAll(); lock.unlock()
        connections.forEach { $0.close() }; unlink(path)
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
