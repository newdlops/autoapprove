import Foundation
import Darwin
import CryptoKit

public struct CodexQueuedInput: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var attachments: Int
    public init(id: String, text: String, attachments: Int = 0) {
        self.id = id; self.text = text; self.attachments = attachments
    }
}

public struct RemoteCodexQueue: Codable, Sendable {
    public var sessionID: String
    public var threadID: String
    public var items: [CodexQueuedInput]
}
public struct CodexQueueConversation: Codable, Sendable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}
public struct RemoteCodexConversations: Codable, Sendable {
    public var sessionID: String
    public var items: [CodexQueueConversation]
}
public struct CodexQueueDeletion: Sendable {
    public var removed: [String]
    public var error: String?
    public init(removed: [String], error: String? = nil) { self.removed = removed; self.error = error }
}

/// The existing daemon owns this queue. Never edit its database, resume a thread,
/// start a daemon or interrupt a turn to manage pending follow-up inputs.
public struct CodexQueueTransport: Sendable {
    public static func enqueue(_ target: CodexReplyTarget, message: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            guard UUID(uuidString: target.threadID) != nil, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.utf8.count <= 65_536, !message.contains("\0") else {
                throw AppError.message("Codex 대화와 메시지를 다시 확인해주세요.")
            }
            let connection = try CodexQueueConnection(home: target.home)
            let clientID = UUID().uuidString
            let result = try connection.request("thread/queue/add", ["threadId": target.threadID,
                "clientUserMessageId": clientID, "input": [["type": "text", "text": message]]])
            guard let submission = result["queuedSubmission"] as? JSONObject,
                  let id = submission["id"] as? String, UUID(uuidString: id) != nil,
                  let receiptID = submission["clientUserMessageId"] as? String, UUID(uuidString: receiptID) == UUID(uuidString: clientID),
                  let input = submission["input"] as? [JSONObject], input.count == 1,
                  input[0]["type"] as? String == "text", input[0]["text"] as? String == message else {
                throw AppError.message("Codex의 접수 결과를 확인하지 못했습니다. 중복 전송을 피하려면 메시지 대기열을 확인해주세요.")
            }
            return id
        }.value
    }
    public var list: @Sendable (CodexReplyTarget) async throws -> [CodexQueuedInput]
    public var delete: @Sendable (CodexReplyTarget, [String]) async throws -> CodexQueueDeletion
    public var conversations: @Sendable (CodexReplyTarget, String) async throws -> [CodexQueueConversation]
    public var validate: @Sendable (CodexReplyTarget, String) async throws -> Void
    public init(list: @escaping @Sendable (CodexReplyTarget) async throws -> [CodexQueuedInput],
                delete: @escaping @Sendable (CodexReplyTarget, [String]) async throws -> CodexQueueDeletion,
                conversations: @escaping @Sendable (CodexReplyTarget, String) async throws -> [CodexQueueConversation] = { _, _ in throw AppError.message("Codex 대화 목록을 지원하지 않습니다.") },
                validate: @escaping @Sendable (CodexReplyTarget, String) async throws -> Void = { _, _ in }) {
        self.list = list; self.delete = delete
        self.conversations = conversations; self.validate = validate
    }
    public static let live = CodexQueueTransport(list: { target in
        try await Task.detached(priority: .utility) {
            let connection = try CodexQueueConnection(home: target.home)
            var result: [CodexQueuedInput] = [], cursor: String?, cursors = Set<String>(), textBudget = 200_000
            repeat {
                var params: JSONObject = ["threadId": target.threadID, "limit": 100]
                if let cursor { params["cursor"] = cursor }
                let page = try connection.request("thread/queue/list", params)
                guard let rows = page["data"] as? [JSONObject], rows.count <= 100 else {
                    throw AppError.message("Codex 대기 입력 목록을 확인하지 못했습니다.")
                }
                for row in rows {
                    guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                          let input = row["input"] as? [JSONObject], input.count <= 100 else {
                        throw AppError.message("Codex 대기 입력 형식을 확인하지 못했습니다.")
                    }
                    let texts = input.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                    let full = texts.joined(separator: "\n"), preview = String(full.prefix(min(4000,textBudget)))
                    textBudget -= preview.count
                    result.append(CodexQueuedInput(id: id, text: preview + (preview.count < full.count ? "…" : ""), attachments: input.count - texts.count))
                }
                cursor = page["nextCursor"] as? String
                guard result.count <= 1000, cursor == nil || cursors.insert(cursor!).inserted else {
                    throw AppError.message("Codex 대기 입력이 너무 많습니다. Mac에서 목록을 정리해주세요.")
                }
            } while cursor != nil
            return result
        }.value
    }, delete: { target, ids in
        try await Task.detached(priority: .utility) {
            let connection = try CodexQueueConnection(home: target.home)
            var removed: [String] = []
            do {
                for id in ids {
                    let result = try connection.request("thread/queue/delete", ["threadId": target.threadID, "queuedSubmissionId": id])
                    guard let deleted = result["deleted"] as? Bool else { throw AppError.message("Codex 대기 입력 삭제 결과를 확인하지 못했습니다.") }
                    if deleted { removed.append(id) }
                }
                return CodexQueueDeletion(removed: removed)
            } catch {
                return CodexQueueDeletion(removed: removed, error: error.localizedDescription)
            }
        }.value
    }, conversations: { target, cwd in
        try await Task.detached(priority: .utility) {
            let result = try CodexQueueConnection(home: target.home).request("thread/list", ["cwd": cwd, "limit": 100, "useStateDbOnly": true])
            guard let rows = result["data"] as? [JSONObject], rows.count <= 100 else { throw AppError.message("Codex 대화 목록을 읽지 못했습니다.") }
            return rows.compactMap { row in
                guard let id = row["id"] as? String, UUID(uuidString: id) != nil, isLoadedRoot(row, cwd: cwd) else { return nil }
                let title = (row["name"] as? String ?? row["preview"] as? String ?? "Codex 대화").components(separatedBy: .newlines).first ?? "Codex 대화"
                return CodexQueueConversation(id: id, title: String(title.prefix(180)))
            }
        }.value
    }, validate: { target, cwd in
        try await Task.detached(priority: .utility) {
            let result = try CodexQueueConnection(home: target.home).request("thread/read", ["threadId": target.threadID, "includeTurns": false])
            guard let row = result["thread"] as? JSONObject, row["id"] as? String == target.threadID, isLoadedRoot(row, cwd: cwd) else {
                throw RemoteHTTPError(409, "선택한 Codex 대화가 종료됐거나 폴더가 바뀌었습니다. 대화를 다시 선택해주세요.")
            }
        }.value
    })
    private static func isLoadedRoot(_ row: JSONObject, cwd: String) -> Bool {
        guard let path = row["cwd"] as? String, URL(fileURLWithPath: path).resolvingSymlinksInPath().path == URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path,
              let status = (row["status"] as? JSONObject)?["type"] as? String, ["active", "idle", "systemError"].contains(status), row["source"] is String,
              row["parentThreadId"] == nil || row["parentThreadId"] is NSNull else { return false }
        return true
    }
}

/// Codex's user-owned Unix control socket carries RFC 6455 WebSocket JSON-RPC.
/// All blocking I/O runs off the main actor and is bounded by one deadline.
private final class CodexQueueConnection {
    private var fd: Int32 = -1
    private let deadline = Date().addingTimeInterval(8)
    private var sequence = 0
    init(home: String) throws {
        let entry = URL(fileURLWithPath: home).appendingPathComponent("app-server-control/app-server-control.sock")
        var link = stat()
        guard lstat(entry.path, &link) == 0, link.st_uid == getuid(),
              (link.st_mode & S_IFMT) == S_IFSOCK || (link.st_mode & S_IFMT) == S_IFLNK else {
            throw AppError.message("실행 중인 Codex의 로컬 서버를 찾지 못했습니다. Mac에서 Codex 연결을 확인해주세요.")
        }
        // Codex publishes a user-owned link to its socket in a private temporary directory.
        let path = entry.resolvingSymlinksInPath().path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw AppError.message("실행 중인 Codex의 로컬 서버를 찾지 못했습니다. Mac에서 Codex 연결을 확인해주세요.")
        }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AppError.message("Codex 서버 경로가 너무 깁니다.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError.message("Codex 서버 연결을 만들지 못했습니다.") }
        do {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw AppError.message("Codex 서버 연결을 설정하지 못했습니다.") }
            let status = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            } }
            if status != 0 {
                guard errno == EINPROGRESS else { throw AppError.message("Codex 서버에 연결하지 못했습니다.") }
                try wait(POLLOUT)
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw AppError.message("Codex 서버에 연결하지 못했습니다.") }
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw AppError.message("Codex 서버의 사용자를 확인하지 못했습니다.") }
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            try write(Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8))
            var head = Data()
            while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
                guard head.count < 16_384 else { throw AppError.message("Codex 서버 응답이 너무 큽니다.") }
                head.append(try read(1))
            }
            let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") { headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            guard lines.first?.split(separator: " ").dropFirst().first == "101", headers["upgrade"]?.lowercased() == "websocket",
                  headers["sec-websocket-accept"] == accept else { throw AppError.message("Codex 대기열 서버의 연결 형식을 지원하지 않습니다.") }
            _ = try request("initialize", ["clientInfo": ["name": "autoapprove", "version": RemoteWebVersion.current?.version ?? "0.2.62"], "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized"])
        } catch { Darwin.close(fd); fd = -1; throw error }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func request(_ method: String, _ params: JSONObject) throws -> JSONObject {
        sequence += 1; let id = sequence
        try send(["id": id, "method": method, "params": params])
        while true {
            guard let object = try JSONSerialization.jsonObject(with: message()) as? JSONObject else { throw AppError.message("Codex 응답을 읽지 못했습니다.") }
            if let incoming = object["id"], object["method"] != nil {
                // Unrelated permission requests must stay with the original client.
                try send(["id": incoming, "error": ["code": -32601, "message": "Unsupported request"]]); continue
            }
            guard object["id"] as? Int == id else { continue }
            if let error = object["error"] as? JSONObject {
                if error["code"] as? Int == -32601 { throw AppError.message("이 Codex 버전은 대기열 제어를 지원하지 않습니다. Codex를 업데이트해주세요.") }
                throw AppError.message("Codex 대기열 요청에 실패했습니다. 목록을 다시 확인해주세요. (\(error["code"] as? Int ?? 0))")
            }
            guard let result = object["result"] as? JSONObject else { throw AppError.message("Codex 대기열 응답을 확인하지 못했습니다.") }
            return result
        }
    }
    private func send(_ object: JSONObject) throws { try frame(1, JSONSerialization.data(withJSONObject: object)) }
    private func frame(_ opcode: UInt8, _ payload: Data) throws {
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        var data = Data([0x80 | opcode])
        if payload.count < 126 { data.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65_535 { data.append(0x80 | 126); data.append(UInt8(payload.count >> 8)); data.append(UInt8(payload.count & 255)) }
        else if payload.count <= 256_000 {
            data.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((UInt64(payload.count) >> shift) & 255)) }
        } else { throw AppError.message("Codex 대기열 요청이 너무 큽니다.") }
        data.append(contentsOf: mask); data.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(data)
    }
    private func message() throws -> Data {
        var result = Data(), started = false
        while true {
            let header = Array(try read(2)), opcode = header[0] & 15, final = header[0] & 0x80 != 0
            guard header[0] & 0x70 == 0, header[1] & 0x80 == 0 else { throw AppError.message("Codex 서버 프레임 형식이 올바르지 않습니다.") }
            var size = UInt64(header[1] & 127)
            if size == 126 { size = try read(2).reduce(0) { $0 << 8 | UInt64($1) } }
            else if size == 127 { size = try read(8).reduce(0) { $0 << 8 | UInt64($1) } }
            guard size <= 2_000_000, result.count + Int(size) <= 2_000_000 else { throw AppError.message("Codex 대기열 응답이 너무 큽니다.") }
            let payload = try read(Int(size))
            if opcode >= 8 {
                guard final, size <= 125 else { throw AppError.message("Codex 서버 제어 프레임이 올바르지 않습니다.") }
                if opcode == 9 { try frame(10, payload); continue }
                if opcode == 10 { continue }
                throw AppError.message("Codex 서버 연결이 끝났습니다. 목록을 다시 확인해주세요.")
            }
            guard opcode == 1 && !started || opcode == 0 && started else { throw AppError.message("Codex 응답 프레임을 읽지 못했습니다.") }
            started = true; result.append(payload)
            if final { return result }
        }
    }
    private func wait(_ events: Int32) throws {
        var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, !Task.isCancelled else { throw AppError.message("Codex 대기열 응답 시간이 초과되었습니다. 목록을 다시 확인해주세요.") }
            let status = Darwin.poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
            if status < 0 && errno == EINTR { continue }
            guard status > 0, descriptor.revents & Int16(events) != 0 else { throw AppError.message("Codex 서버 응답을 받지 못했습니다. 목록을 다시 확인해주세요.") }
            return
        }
    }
    private func read(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            try wait(POLLIN)
            var bytes = [UInt8](repeating: 0, count: min(65_536, count - result.count))
            let size = Darwin.recv(fd, &bytes, bytes.count, 0)
            if size < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard size > 0 else { throw AppError.message("Codex 서버 연결이 끝났습니다.") }
            result.append(contentsOf: bytes.prefix(size))
        }
        return result
    }
    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(POLLOUT)
                let size = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if size < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard size > 0 else { throw AppError.message("Codex 대기열 요청을 보내지 못했습니다.") }
                offset += size
            }
        }
    }
}
