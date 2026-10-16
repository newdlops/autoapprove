import Foundation
import Darwin
import AutoApproveCore

private final class RawLocalPeer {
    private var descriptor: Int32
    private var buffer = Data()
    init(path: String) throws {
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AppError.message("Fixture socket failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(); throw AppError.message("Fixture path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(); throw AppError.message("Fixture connect failed") }
        var timeout = timeval(tv_sec: 2, tv_usec: 0), one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw AppError.message("Fixture send failed") }
                offset += count
            }
        }
    }
    func write(_ object: JSONObject) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10); try write(data)
    }
    func read() throws -> JSONObject {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let data = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                return try JSONSerialization.jsonObject(with: data) as! JSONObject
            }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw AppError.message("Fixture response failed") }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
    func isClosed() -> Bool {
        var byte: UInt8 = 0
        let count = Darwin.recv(descriptor, &byte, 1, 0)
        return count == 0 || count < 0 && errno == ECONNRESET
    }
}

private final class SocketDisconnectProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func record(_ id: String) { lock.lock(); values[id, default: 0] += 1; lock.unlock() }
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return Array(values.values) }
}

extension ApprovalTests {
    func testLocalSocketFragmentedUnicodeAndBufferedOrdering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-socket-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("s").path
        let server = SocketServer(path: path, handler: { message, peer in peer.send(message) }, disconnected: { _ in })
        try server.start(); defer { server.stop() }
        let peer = try RawLocalPeer(path: path)
        let payload = "한글🙂\u{001b}[32m" + String(repeating: "output ", count: 16_000)
        var data = try JSONSerialization.data(withJSONObject: ["id": 1, "payload": payload]); data.append(10)
        let split = data.firstIndex(of: 0xf0)! + 1
        try peer.write(data.prefix(split)); usleep(10_000); try peer.write(data.dropFirst(split))
        try expectEqual(try peer.read()["payload"] as? String, payload)
        var lines = Data()
        for index in 0..<200 { lines.append(try JSONSerialization.data(withJSONObject: ["id": index])); lines.append(10) }
        try peer.write(lines)
        for index in 0..<200 { try expectEqual(try peer.read()["id"] as? Int, index, "Buffered lines must preserve order beyond one readiness turn") }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        try expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testLocalSocketMalformedOversizedAndBoundedPeers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-socket-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("s").path, probe = SocketDisconnectProbe()
        let server = SocketServer(path: path, maximumConnections: 2, handler: { message, peer in peer.send(message) }, disconnected: { probe.record($0) })
        try server.start(); defer { server.stop() }
        let first = try RawLocalPeer(path: path), second = try RawLocalPeer(path: path)
        try first.write(["id": 1]); _ = try first.read(); try second.write(["id": 2]); _ = try second.read()
        let rejected = try RawLocalPeer(path: path)
        try expect(rejected.isClosed(), "At capacity, reject promptly instead of retaining an unbounded peer")
        try first.write(Data("{\"id\":3}\ninvalid-json\n".utf8))
        try expectEqual(try first.read()["id"] as? Int, 3); try expect(first.isClosed())
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while probe.counts.count < 1, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let oversized = try RawLocalPeer(path: path)
        try? oversized.write(Data(repeating: 0x78, count: 2_100_000))
        try expect(oversized.isClosed(), "An unterminated oversized message must be bounded")
        try second.write(["id": 4]); try expectEqual(try second.read()["id"] as? Int, 4)
        second.close(); server.stop()
        let closedDeadline = ProcessInfo.processInfo.systemUptime + 2
        while probe.counts.count < 3, ProcessInfo.processInfo.systemUptime < closedDeadline { try await Task.sleep(for: .milliseconds(5)) }
        try expectEqual(probe.counts.count, 3); try expect(probe.counts.allSatisfy { $0 == 1 })
    }

    func testLocalSocketRestartAndPathOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-socket-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("s").path
        let server = SocketServer(path: path, handler: { message, peer in peer.send(["result": message]) }, disconnected: { _ in })
        defer { server.stop() }
        for index in 0..<20 {
            try server.start(); try expectThrows(try server.start())
            let result = try await Task.detached { try SocketClient.request(path: path, message: ["id": index]) }.value
            try expectEqual(result["id"] as? Int, index, "An old source must not close a reused descriptor")
            let duplicate = SocketServer(path: path, handler: { _, _ in }, disconnected: { _ in })
            try expectThrows(try duplicate.start()); duplicate.stop()
            try expect(FileManager.default.fileExists(atPath: path))
            server.stop()
        }
        let original = Data("keep this user file".utf8); try original.write(to: URL(fileURLWithPath: path))
        try expectThrows(try server.start()); server.stop()
        try expectEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
    }
}
