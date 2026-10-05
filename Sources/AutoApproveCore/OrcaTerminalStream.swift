import Foundation
import CoreFoundation
import Darwin

public struct OrcaTerminalTarget: Equatable, Sendable {
    public let handle: String
    public let runtimeID: String
    public let ptyID: String
    public let connected: Bool
    public init(handle: String, runtimeID: String, ptyID: String, connected: Bool) {
        self.handle = handle; self.runtimeID = runtimeID; self.ptyID = ptyID; self.connected = connected
    }
}

public struct OrcaTerminalSnapshot: Sendable {
    public let ansi: String
    public let columns: Int
    public let rows: Int
    public let sequence: Int64
    public let runtimeID: String
    public let ptyID: String
    public let incarnationID: String
    public let ownerPID: Int32
    public let observedAt: Date
    public let alternateScreen: Bool
    public init(ansi: String, columns: Int, rows: Int, sequence: Int64, runtimeID: String,
                ptyID: String, incarnationID: String, ownerPID: Int32, observedAt: Date, alternateScreen: Bool) {
        self.ansi = ansi; self.columns = columns; self.rows = rows; self.sequence = sequence
        self.runtimeID = runtimeID; self.ptyID = ptyID; self.incarnationID = incarnationID
        self.ownerPID = ownerPID
        self.observedAt = observedAt; self.alternateScreen = alternateScreen
    }
}

public enum OrcaTerminalStreamError: Error, LocalizedError {
    case unavailable(String)
    case capacity
    case timedOut
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "Orca 원본 터미널 화면을 읽을 수 없습니다. \(reason)"
        case .capacity: return "Orca 화면 읽기 한도에 도달했습니다. 잠시 후 다시 연결해주세요."
        case .timedOut: return "Orca 원본 터미널 화면을 기다리는 시간이 초과됐습니다."
        }
    }
}

/// Fresh, complete ANSI frames from an already running Orca daemon. This is not
/// a PTY consumer: it opens only an authenticated control socket and never
/// sends createOrAttach, stream hello, input, resize, detach or driver requests.
/// The existing bounded screen SSE/cache can share these snapshots across peers.
public final class OrcaTerminalStream: @unchecked Sendable {
    private let userDataURL: URL
    private let timeout: TimeInterval
    private let maximumConcurrentReads: Int
    private let lookup: (@Sendable (String) throws -> OrcaTerminalTarget)?
    private let lock = NSLock()
    private var activeReads = 0

    public init(userDataURL: URL? = nil, timeout: TimeInterval = 2, maximumConcurrentReads: Int = 4,
                lookup: (@Sendable (String) throws -> OrcaTerminalTarget)? = nil) {
        let override = ProcessInfo.processInfo.environment["ORCA_USER_DATA_PATH"].flatMap { $0.isEmpty ? nil : $0 }
        self.userDataURL = userDataURL ?? override.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/orca")
        self.timeout = timeout.isFinite ? min(30, max(0.05, timeout)) : 2
        self.maximumConcurrentReads = min(8, max(1, maximumConcurrentReads))
        self.lookup = lookup
    }

    public func snapshot(handle: String) async throws -> OrcaTerminalSnapshot {
        guard !handle.isEmpty, handle.utf8.count <= 256 else { throw OrcaTerminalStreamError.unavailable("터미널 핸들이 올바르지 않습니다.") }
        try Task.checkCancellation(); try admit(); defer { release() }
        let operation = OrcaSnapshotOperation(timeout: timeout)
        return try await withTaskCancellationHandler(operation: {
            let result = try await Task.detached(priority: .utility) { [self] in
                try read(handle: handle, operation: operation)
            }.value
            try Task.checkCancellation()
            return result
        }, onCancel: { operation.cancel() })
    }

    private func admit() throws {
        lock.lock(); defer { lock.unlock() }
        guard activeReads < maximumConcurrentReads else { throw OrcaTerminalStreamError.capacity }
        activeReads += 1
    }
    private func release() { lock.lock(); activeReads -= 1; lock.unlock() }

    private func target(_ handle: String, operation: OrcaSnapshotOperation) throws -> OrcaTerminalTarget {
        try operation.check()
        let value = try lookup?(handle) ?? runtimeTarget(handle, operation: operation)
        try operation.check()
        guard value.handle == handle, value.connected, !value.ptyID.isEmpty, !value.runtimeID.isEmpty else {
            throw OrcaTerminalStreamError.unavailable("선택한 원본 터미널이 종료됐거나 바뀌었습니다.")
        }
        return value
    }

    private func runtimeTarget(_ handle: String, operation: OrcaSnapshotOperation) throws -> OrcaTerminalTarget {
        let metadata = try OrcaJSON.file(userDataURL.appendingPathComponent("orca-runtime.json"), limit: 1_048_576)
        let transports = metadata["transports"] as? [[String: Any]] ?? (metadata["transport"] as? [String: Any]).map { [$0] } ?? []
        guard let endpoint = transports.first(where: { $0["kind"] as? String == "unix" })?["endpoint"] as? String,
              let token = metadata["authToken"] as? String, !token.isEmpty, token.utf8.count <= 65_536,
              let runtimeID = metadata["runtimeId"] as? String, !runtimeID.isEmpty else {
            throw OrcaTerminalStreamError.unavailable("호환되는 로컬 런타임 연결이 없습니다.")
        }
        let connection = try OrcaLineConnection(path: endpoint, operation: operation, frameLimit: 1_048_576)
        defer { connection.close() }
        let id = UUID().uuidString
        try connection.send(["id": id, "authToken": token, "method": "terminal.show", "params": ["terminal": handle]])
        var reply = try connection.receive()
        while reply["_keepalive"] as? Bool == true { reply = try connection.receive() }
        guard reply["id"] as? String == id, reply["ok"] as? Bool == true,
              (reply["_meta"] as? [String: Any])?["runtimeId"] as? String == runtimeID,
              let terminal = (reply["result"] as? [String: Any])?["terminal"] as? [String: Any],
              let resolved = terminal["handle"] as? String, let ptyID = terminal["ptyId"] as? String,
              let connected = terminal["connected"] as? Bool else {
            throw OrcaTerminalStreamError.unavailable("런타임이 선택한 터미널의 현재 식별자를 확인하지 못했습니다.")
        }
        return OrcaTerminalTarget(handle: resolved, runtimeID: runtimeID, ptyID: ptyID, connected: connected)
    }

    private struct Session: Equatable {
        let incarnationID: String
        let pid: Int32
        let handle: String?
    }

    private func session(_ reply: [String: Any], target: OrcaTerminalTarget) throws -> Session? {
        guard let sessions = reply["sessions"] as? [[String: Any]], sessions.count <= 4096 else {
            throw OrcaTerminalStreamError.unavailable("데몬 세션 목록을 확인하지 못했습니다.")
        }
        let matches = sessions.filter { $0["sessionId"] as? String == target.ptyID && $0["isAlive"] as? Bool == true }
        guard matches.count <= 1 else { throw OrcaTerminalStreamError.unavailable("데몬 세션 식별자가 중복됐습니다.") }
        guard let value = matches.first else { return nil }
        guard let incarnation = value["incarnationId"] as? String, !incarnation.isEmpty,
              let number = OrcaJSON.integer(value["pid"]), let pid = Int32(exactly: number), pid > 0,
              value["terminalHandle"] == nil || value["terminalHandle"] as? String == target.handle else {
            throw OrcaTerminalStreamError.unavailable("데몬의 원본 터미널 식별자가 바뀌었습니다.")
        }
        return Session(incarnationID: incarnation, pid: pid, handle: value["terminalHandle"] as? String)
    }

    private func read(handle: String, operation: OrcaSnapshotOperation) throws -> OrcaTerminalSnapshot {
        let before = try target(handle, operation: operation)
        let directory = userDataURL.appendingPathComponent("daemon")
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch { throw OrcaTerminalStreamError.unavailable("실행 중인 PTY 데몬이 없습니다.") }
        let versions = names.compactMap { name -> Int? in
            guard name.hasPrefix("daemon-v"), name.hasSuffix(".sock"),
                  let version = Int(name.dropFirst(8).dropLast(5)), (32...36).contains(version) else { return nil }
            return version
        }.sorted(by: >)
        guard !versions.isEmpty, versions.count <= 8 else { throw OrcaTerminalStreamError.unavailable("호환되는 기존 PTY 데몬이 없습니다.") }

        var selected: (OrcaLineConnection, Session)?
        defer { selected?.0.close() }
        for version in versions {
            try operation.check()
            let base = directory.appendingPathComponent("daemon-v\(version)")
            // Orca removes PID/token records on shutdown while a published
            // legacy socket inode can remain. Such artifacts are not sources.
            guard let identityData = try OrcaJSON.existingFileData(URL(fileURLWithPath: base.path + ".pid"), limit: 65_536),
                  let tokenData = try OrcaJSON.existingFileData(URL(fileURLWithPath: base.path + ".token"), limit: 65_536) else { continue }
            let identity = try OrcaJSON.object(identityData)
            guard let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                throw OrcaTerminalStreamError.unavailable("데몬 인증 정보를 읽을 수 없습니다.")
            }
            let connection: OrcaLineConnection
            do { connection = try OrcaLineConnection(path: base.path + ".sock", operation: operation, frameLimit: 4_194_304) }
            catch is OrcaAbsentSocket { try operation.check(); continue }
            do {
                try connection.send(["type": "hello", "version": version, "token": token,
                                     "clientId": UUID().uuidString, "role": "control"])
                let hello = try connection.receive()
                guard hello["type"] as? String == "hello", hello["ok"] as? Bool == true,
                      let actual = hello["daemonIdentity"] as? [String: Any],
                      OrcaJSON.integer(actual["pid"]) == OrcaJSON.integer(identity["pid"]),
                      let pid = OrcaJSON.integer(actual["pid"]), pid > 0,
                      let nonce = actual["launchNonce"] as? String, !nonce.isEmpty, nonce == identity["launchNonce"] as? String,
                      let startedAt = actual["startedAtMs"] as? Double, startedAt > 0,
                      startedAt == identity["startedAtMs"] as? Double else {
                    throw OrcaTerminalStreamError.unavailable("읽기 도중 데몬 실행 정보가 바뀌었습니다.")
                }
                if let found = try session(connection.request("listSessions"), target: before) {
                    guard selected == nil else { throw OrcaTerminalStreamError.unavailable("같은 터미널을 가진 데몬이 여러 개입니다.") }
                    selected = (connection, found)
                } else { connection.close() }
            } catch { connection.close(); throw error }
        }
        try operation.check()
        guard let (connection, original) = selected else { throw OrcaTerminalStreamError.unavailable("기존 PTY의 현재 화면을 제공하는 데몬이 없습니다.") }
        let response = try connection.request("getSnapshot", payload: ["sessionId": before.ptyID, "scrollbackRows": 0])
        guard let snapshot = response["snapshot"] as? [String: Any],
              let screen = snapshot["snapshotAnsi"] as? String, let restore = snapshot["rehydrateSequences"] as? String,
              let cols = OrcaJSON.integer(snapshot["cols"]), (1...1000).contains(cols),
              let rows = OrcaJSON.integer(snapshot["rows"]), (1...500).contains(rows),
              let sequence = OrcaJSON.integer(snapshot["outputSequence"]), sequence >= 0,
              let alternate = (snapshot["modes"] as? [String: Any])?["alternateScreen"] as? Bool,
              screen.utf8.count + restore.utf8.count <= 4_194_304 else {
            throw OrcaTerminalStreamError.unavailable("현재 ANSI 화면이 없거나 데몬 버전이 호환되지 않습니다.")
        }
        guard try session(connection.request("listSessions"), target: before) == original,
              try target(handle, operation: operation) == before else {
            throw OrcaTerminalStreamError.unavailable("화면을 읽는 동안 원본 터미널이 종료됐거나 바뀌었습니다.")
        }
        try operation.check()
        return OrcaTerminalSnapshot(ansi: restore + screen, columns: Int(cols), rows: Int(rows), sequence: sequence,
                                    runtimeID: before.runtimeID, ptyID: before.ptyID, incarnationID: original.incarnationID,
                                    ownerPID: original.pid, observedAt: Date(), alternateScreen: alternate)
    }
}

private enum OrcaJSON {
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value, abs(value) <= 9_007_199_254_740_991 else { return nil }
        return number.int64Value
    }
    static func fileData(_ url: URL, limit: Int) throws -> Data {
        guard let data = try existingFileData(url, limit: limit) else {
            throw OrcaTerminalStreamError.unavailable("로컬 데몬 연결 정보가 없습니다.")
        }
        return data
    }
    static func existingFileData(_ url: URL, limit: Int) throws -> Data? {
        do {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            var data = Data()
            while data.count <= limit {
                guard let part = try file.read(upToCount: min(16_384, limit + 1 - data.count)), !part.isEmpty else { return data }
                data.append(part)
            }
        } catch let error as NSError {
            if (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) ||
                (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) { return nil }
            throw OrcaTerminalStreamError.unavailable("로컬 데몬 연결 정보를 읽을 수 없습니다.")
        }
        throw OrcaTerminalStreamError.unavailable("로컬 데몬 연결 정보가 너무 큽니다.")
    }
    static func file(_ url: URL, limit: Int) throws -> [String: Any] { try object(fileData(url, limit: limit)) }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OrcaTerminalStreamError.unavailable("로컬 연결 응답이 올바르지 않습니다.")
        }
        return value
    }
}

private struct OrcaAbsentSocket: Error, LocalizedError {
    var errorDescription: String? { "Orca의 기존 로컬 데몬 소켓이 없거나 연결을 거부했습니다." }
}

/// Cancellation only shuts down registered descriptors. The worker closes them
/// under the same lock, so a cancellation cannot close a reused descriptor.
private final class OrcaSnapshotOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var descriptors = Set<Int32>()
    private let deadline: TimeInterval
    init(timeout: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + timeout }
    func check() throws {
        lock.lock(); let cancelled = cancelled; lock.unlock()
        if cancelled { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw OrcaTerminalStreamError.timedOut }
    }
    func register(_ fd: Int32) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { Darwin.close(fd); throw CancellationError() }
        descriptors.insert(fd)
    }
    func close(_ fd: Int32) { lock.lock(); descriptors.remove(fd); Darwin.close(fd); lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true
        for fd in descriptors { Darwin.shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }
    func wait(_ fd: Int32, events: Int16) throws {
        while true {
            try check()
            let remaining = max(1, Int32(min(50, (deadline - ProcessInfo.processInfo.systemUptime) * 1000)))
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, remaining)
            try check()
            if result > 0 { return }
            if result < 0 && errno != EINTR { throw OrcaTerminalStreamError.unavailable("로컬 데몬 연결이 끊어졌습니다.") }
        }
    }
}

private final class OrcaLineConnection {
    private let operation: OrcaSnapshotOperation
    private let fd: Int32
    private let frameLimit: Int
    private var buffer = Data()
    private var scannedBytes = 0
    private var closed = false
    init(path: String, operation: OrcaSnapshotOperation, frameLimit: Int) throws {
        self.operation = operation; self.frameLimit = frameLimit
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard path.hasPrefix("/"), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw OrcaTerminalStreamError.unavailable("로컬 소켓 경로가 올바르지 않습니다.")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OrcaTerminalStreamError.unavailable("로컬 읽기 연결을 만들지 못했습니다.") }
        try operation.register(fd)
        do {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw OrcaTerminalStreamError.unavailable("로컬 연결을 설정하지 못했습니다.") }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result < 0 {
                if errno == ENOENT || errno == ECONNREFUSED { throw OrcaAbsentSocket() }
                guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else { throw OrcaTerminalStreamError.unavailable("실행 중인 로컬 데몬에 연결할 수 없습니다.") }
                try operation.wait(fd, events: Int16(POLLOUT))
                var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw OrcaTerminalStreamError.unavailable("실행 중인 로컬 데몬에 연결할 수 없습니다.") }
                if error == ENOENT || error == ECONNREFUSED { throw OrcaAbsentSocket() }
                guard error == 0 else { throw OrcaTerminalStreamError.unavailable("실행 중인 로컬 데몬에 연결할 수 없습니다.") }
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw OrcaTerminalStreamError.unavailable("같은 사용자의 로컬 데몬 연결이 아닙니다.") }
            try operation.check()
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() { guard !closed else { return }; closed = true; operation.close(fd) }
    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        guard data.count <= 131_072 else { throw OrcaTerminalStreamError.unavailable("로컬 화면 요청이 너무 큽니다.") }
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                try operation.check()
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if count > 0 { sent += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { try operation.wait(fd, events: Int16(POLLOUT)); continue }
                try operation.check(); throw OrcaTerminalStreamError.unavailable("로컬 화면 요청을 보내지 못했습니다.")
            }
        }
    }
    func receive() throws -> [String: Any] {
        while true {
            try operation.check()
            let start = buffer.index(buffer.startIndex, offsetBy: scannedBytes)
            if let end = buffer[start...].firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end); scannedBytes = 0
                return try OrcaJSON.object(line)
            }
            scannedBytes = buffer.count
            guard buffer.count < frameLimit else { throw OrcaTerminalStreamError.unavailable("로컬 ANSI 화면 응답이 너무 큽니다.") }
            var bytes = [UInt8](repeating: 0, count: min(16_384, frameLimit + 1 - buffer.count))
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count > 0 { buffer.append(contentsOf: bytes.prefix(count)); continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { try operation.wait(fd, events: Int16(POLLIN)); continue }
            try operation.check(); throw OrcaTerminalStreamError.unavailable("현재 화면을 받기 전에 로컬 연결이 끊어졌습니다.")
        }
    }
    func request(_ type: String, payload: [String: Any]? = nil) throws -> [String: Any] {
        let id = UUID().uuidString
        var request: [String: Any] = ["id": id, "type": type]
        if let payload { request["payload"] = payload }
        try send(request)
        let reply = try receive()
        guard reply["id"] as? String == id, reply["ok"] as? Bool == true, let value = reply["payload"] as? [String: Any] else {
            throw OrcaTerminalStreamError.unavailable("데몬이 현재 원본 화면을 제공하지 못했습니다.")
        }
        return value
    }
}
