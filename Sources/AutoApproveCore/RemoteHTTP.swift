import Foundation
import Network

public struct RemoteHTTPError: LocalizedError {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    public var errorDescription: String? { message }
}

/// A bounded, single-request HTTP connection. No cookies, CORS or socket-bridge passthrough.
public struct RemoteHTTPRequest {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data
    public var components: URLComponents { URLComponents(string: "http://localhost" + target)! }
    public var path: String { components.path }
    public func parameter(_ name: String) -> String? {
        // Browser URLSearchParams uses form encoding: '+' is a space, '%2B' is a literal plus.
        // Foundation's queryItems deliberately leaves '+' unchanged.
        for item in components.percentEncodedQuery?.split(separator: "&") ?? [] {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            if key == name, parts.count == 2 { return String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
        }
        return nil
    }
    public func json() throws -> JSONObject {
        guard headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
              let object = try JSONSerialization.jsonObject(with: body) as? JSONObject else {
            throw RemoteHTTPError(400, "JSON 형식의 요청이 필요합니다.")
        }
        return object
    }
    public static func parse(_ data: Data) throws -> RemoteHTTPRequest? {
        guard data.count <= 280_000 else { throw RemoteHTTPError(413, "요청이 너무 큽니다.") }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw RemoteHTTPError(431, "요청 헤더가 너무 큽니다.") }
            return nil
        }
        guard boundary.lowerBound <= 16_384, let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            throw RemoteHTTPError(400, "요청 헤더를 읽지 못했습니다.")
        }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(start[2])),
              start[1].hasPrefix("/"), !start[1].hasPrefix("//"), !start[1].contains("#"),
              URLComponents(string: "http://localhost" + start[1]) != nil else { throw RemoteHTTPError(400, "올바르지 않은 요청입니다.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw RemoteHTTPError(400, "올바르지 않은 헤더입니다.") }
            let key = line[..<colon].lowercased()
            guard !key.isEmpty, headers[key] == nil else { throw RemoteHTTPError(400, "중복된 요청 헤더입니다.") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw RemoteHTTPError(400, "이 전송 형식은 지원하지 않습니다.") }
        let length: Int
        if let supplied = headers["content-length"] {
            guard supplied.allSatisfy(\.isNumber), let value = Int(supplied), value <= 256_000 else { throw RemoteHTTPError(413, "올바르지 않은 요청 길이입니다.") }
            length = value
        } else { length = 0 }
        if start[0] == "POST", headers["content-length"] == nil { throw RemoteHTTPError(411, "요청 길이가 필요합니다.") }
        guard data.count >= boundary.upperBound + length else { return nil }
        guard data.count == boundary.upperBound + length else { throw RemoteHTTPError(400, "한 연결에는 한 요청만 보낼 수 있습니다.") }
        return RemoteHTTPRequest(method: String(start[0]), target: String(start[1]), headers: headers, body: data.subdata(in: boundary.upperBound..<data.count))
    }
    public func validateOrigin() throws {
        guard let host = headers["host"], let authority = URLComponents(string: "http://" + host),
              authority.user == nil, authority.password == nil, let hostname = authority.host,
              (RemoteNetworkAddress.isLocalHost(hostname) || ["approve", "approve."].contains(hostname.lowercased())),
              authority.path.isEmpty, authority.query == nil, authority.fragment == nil else {
            throw RemoteHTTPError(403, "같은 네트워크의 Mac 주소로 접속해주세요.")
        }
        if let origin = headers["origin"], origin.lowercased() != "http://" + host.lowercased() {
            throw RemoteHTTPError(403, "다른 웹사이트에서 보낸 요청은 처리할 수 없습니다.")
        }
        if let fetchSite = headers["sec-fetch-site"], !["same-origin", "none"].contains(fetchSite) {
            // A shared phone link and a newer Mac's page are top-level navigation.
            // Allow only the read-only entry document; API/subresource/iframe and
            // POST requests still require the exact page origin.
            guard method == "GET", ["/", "/index.html"].contains(path),
                  headers["sec-fetch-mode"] == "navigate", headers["sec-fetch-dest"] == "document" else {
                throw RemoteHTTPError(403, "AutoApprove 페이지에서 직접 요청해주세요.")
            }
        }
    }
}

public enum RemoteNetworkAddress {
    public static func isLocalHost(_ value: String) -> Bool {
        let host = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".local.") { return true }
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            return bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 169 && bytes[1] == 254)
        }
        if let address = IPv6Address(host.components(separatedBy: "%")[0]) {
            let bytes = Array(address.rawValue)
            if bytes.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255] {
                return isLocalHost(bytes.suffix(4).map(String.init).joined(separator: "."))
            }
            return address == IPv6Address("::1") || (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
        }
        return false
    }
    public static func endpoint(_ supplied: String) throws -> NWEndpoint {
        let value = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: value.contains("://") ? value : "http://" + value),
              url.scheme == "http", url.user == nil, url.password == nil, let host = url.host,
              isLocalHost(host), ["", "/"].contains(url.path), url.query == nil, url.fragment == nil,
              let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? 8765) ?? 0), port.rawValue > 0 else {
            throw RemoteHTTPError(400, "Mac에 표시된 사설 IP 또는 .local 주소와 포트를 입력해주세요.")
        }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }
}

public struct RemoteHTTPResponse {
    public var status: Int
    public var body: Data
    public var contentType: String
    public var location: String?
    public init(status: Int = 200, body: Data, contentType: String = "application/json; charset=utf-8", location: String? = nil) {
        self.status = status; self.body = body; self.contentType = contentType; self.location = location
    }
    public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> Self {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return Self(status: status, body: try encoder.encode(value))
    }
    public static func object(_ value: JSONObject, status: Int = 200) throws -> Self {
        Self(status: status, body: try JSONSerialization.data(withJSONObject: value))
    }
    public static func error(_ error: Error) -> Self {
        let status = (error as? RemoteHTTPError)?.status ?? 409
        return (try? object(["error": error.localizedDescription], status: status)) ?? Self(status: 500, body: Data())
    }
    var wire: Data {
        let reason = status == 200 ? "OK" : status == 302 ? "Found" : "Error"
        let redirect = location.flatMap { $0.contains("\r") || $0.contains("\n") ? nil : "Location: \($0)\r\n" } ?? ""
        let headers = "HTTP/1.1 \(status) \(reason)\r\n\(redirect)Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n"
        return Data(headers.utf8) + body
    }
}

// Buffer and completion state are confined to the listener's serial queue.
final class RemoteHTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    var buffer = Data()
    var complete = false
    let handler: @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse
    let onClose: () -> Void
    private let queue: DispatchQueue
    init(_ connection: NWConnection, queue: DispatchQueue, handler: @escaping @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse, onClose: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.handler = handler; self.onClose = onClose
    }
    func start() {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.close() }
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, ended, error in
            guard let self, !self.complete else { return }
            if let data { self.buffer.append(data) }
            do {
                if let request = try RemoteHTTPRequest.parse(self.buffer) {
                    self.complete = true
                    Task { @MainActor in
                        let response = await self.handler(request)
                        self.connection.send(content: response.wire, completion: .contentProcessed { _ in self.close() })
                    }
                } else if ended || error != nil { self.close() }
                else { self.receive() }
            } catch {
                self.complete = true
                self.connection.send(content: RemoteHTTPResponse.error(error).wire, completion: .contentProcessed { _ in self.close() })
            }
        }
    }
    func close() { connection.cancel(); onClose() }
}

/// Peer requests use resolved Bonjour endpoints directly, so the phone needs only its chosen Mac.
// All continuation and response-buffer accesses run on this exchange's serial queue.
final class RemoteHTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let timeout: TimeInterval
    private var buffer = Data()
    private var continuation: CheckedContinuation<RemoteHTTPResponse, Error>?
    private let queue = DispatchQueue(label: "autoapprove.web.peer")
    init(endpoint: NWEndpoint, path: String, method: String, body: Data, expectedNodeID: String? = nil, timeout: TimeInterval? = nil) throws {
        connection = NWConnection(to: endpoint, using: try RemoteLAN.tcpParameters(to: endpoint, interfaces: RemoteLAN.interfaces()))
        self.timeout = timeout ?? (method == "GET" && path == "/api/state" ? 4 : 15)
        let identity = expectedNodeID.map { "X-AutoApprove-Node: \($0)\r\n" } ?? ""
        request = Data("\(method) \(path) HTTP/1.1\r\nHost: autoapprove.local\r\n\(identity)Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
    }
    func run() async throws -> RemoteHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.connection.send(content: self.request, completion: .contentProcessed { error in
                            if let error { self.finish(.failure(error)) } else { self.receive() }
                        })
                    case .failed(let error): self.finish(.failure(error))
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + self.timeout) { self.finish(.failure(RemoteHTTPError(504, "Mac의 응답을 기다리다 시간이 지났습니다. 전송한 입력은 다시 보내지 말고 화면을 확인해주세요."))) }
            }
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64_000) { data, _, ended, error in
            if let data { self.buffer.append(data) }
            if self.buffer.count > 4_000_000 { self.finish(.failure(RemoteHTTPError(502, "Mac의 응답이 너무 큽니다."))); return }
            if let boundary = self.buffer.range(of: Data("\r\n\r\n".utf8)),
               let head = String(data: self.buffer[..<boundary.lowerBound], encoding: .utf8) {
                let lines = head.components(separatedBy: "\r\n")
                let length = lines.first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) }
                let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
                if let length, let status, length >= 0, length <= 4_000_000, self.buffer.count >= boundary.upperBound + length {
                    self.finish(.success(RemoteHTTPResponse(status: status, body: self.buffer.subdata(in: boundary.upperBound..<boundary.upperBound + length))))
                    return
                }
            }
            if let error { self.finish(.failure(error)) }
            else if ended { self.finish(.failure(RemoteHTTPError(502, "Mac과의 연결이 끊겼습니다. 상태를 새로고침해주세요."))) }
            else { self.receive() }
        }
    }
    private func finish(_ result: Result<RemoteHTTPResponse, Error>) {
        guard let continuation else { return }; self.continuation = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        continuation.resume(with: result)
    }
}
