import Foundation
import Network

public struct RemoteHTTPError: LocalizedError {
    public let status: Int
    public let message: String
    public let diagnostics: [String: String]?
    public init(_ status: Int, _ message: String, diagnostics: [String: String]? = nil) { self.status = status; self.message = message; self.diagnostics = diagnostics }
    public var errorDescription: String? { message }
}

enum RemoteReadRecovery {
    static func isTransient(_ error: Error) -> Bool {
        guard !(error is CancellationError), !Task.isCancelled else { return false }
        if error is NWError { return true }
        guard let value = error as? RemoteHTTPError, value.diagnostics?["failureKind"] != "identity",
              value.diagnostics?["failureKind"] != "protocol" else { return false }
        return [502,503,504].contains(value.status)
    }
}

/// One bounded HTTP message. No cookies, CORS or socket-bridge passthrough.
public struct RemoteHTTPRequest {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data
    /// Supplied by the accepted socket, never by a browser header.
    public var clientAddress: String? = nil
    // Parsed from this message, never inherited from a previous request.
    var allowsConnectionReuse = false
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
        var request = RemoteHTTPRequest(method: String(start[0]), target: String(start[1]), headers: headers, body: data.subdata(in: boundary.upperBound..<data.count))
        let options = headers["connection"]?.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces).lowercased() } ?? []
        request.allowsConnectionReuse = start[2] == "HTTP/1.1" && start[0] == "GET" && length == 0
            && !options.contains("close") && headers["upgrade"] == nil
        return request
    }
    public func validateOrigin() throws {
        guard let host = headers["host"], let authority = URLComponents(string: "http://" + host),
              authority.user == nil, authority.password == nil, let hostname = authority.host,
              (RemoteNetworkAddress.isLocalHost(hostname) || ["approve", "approve.", "autoapprove", "autoapprove."].contains(hostname.lowercased())),
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
        if let address = RemoteLAN.canonicalIPv4(value) {
            let first = address >> 24, second = (address >> 16) & 255
            return first == 10 || first == 127 || (first == 192 && second == 168)
                || (first == 172 && (16...31).contains(second)) || (first == 169 && second == 254)
        }
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

public struct RemoteHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String
    public var location: String?
    public var styleNonce: String?
    public var entityTag: String?
    public var observedAt: Date?
    var contentEncoding: String?
    private var variesEncoding = false
    var stream: RemoteHTTPBodyStream?
    public var nodeID: String?
    public init(status: Int = 200, body: Data, contentType: String = "application/json; charset=utf-8", location: String? = nil) {
        self.status = status; self.body = body; self.contentType = contentType; self.location = location
    }
    public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> Self {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return Self(status: status, body: try encoder.encode(value))
    }
    public static func terminalJSON<T: Encodable>(_ value: T) throws -> Self {
        let response = try json(value)
        guard response.body.count <= 2_000_000 else {
            throw RemoteHTTPError(502,"원본 터미널 화면이 너무 큽니다. Mac에서 창 크기를 줄여주세요.")
        }
        return response
    }
    public static func object(_ value: JSONObject, status: Int = 200) throws -> Self {
        Self(status: status, body: try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]))
    }
    public static func error(_ error: Error) -> Self {
        let status = (error as? RemoteHTTPError)?.status ?? 409
        var value: JSONObject = ["error": error.localizedDescription]
        if let diagnostics = (error as? RemoteHTTPError)?.diagnostics { value["diagnostics"] = diagnostics }
        return (try? object(value, status: status)) ?? Self(status: 500, body: Data())
    }
    static func eventStream(_ stream: RemoteHTTPBodyStream, nodeID: String, initialData: Data = Data(), binary: Bool = false, wireVersion: Int = 2) -> Self {
        var response = Self(body: initialData, contentType: binary ? RemoteTerminalWire.contentType(for:wireVersion) : "text/event-stream; charset=utf-8")
        response.stream = stream; response.nodeID = nodeID; return response
    }
    /// Short reads and shipped web assets benefit from a complete gzip member.
    /// Already assigned strong validators stay byte-identical. Inventory selects
    /// its representation before assigning one. Native/legacy clients negotiate
    /// gzip explicitly; no user data is cached here.
    func preparingTransfer(method: String, acceptsGzip: Bool) -> Self {
        let type = contentType.split(separator:";").first?.lowercased() ?? ""
        guard method == "GET", status == 200, stream == nil, contentEncoding == nil,
              (1024...2_100_000).contains(body.count),
              ["application/json","application/javascript","text/javascript","text/html","text/css","image/svg+xml"].contains(type),
              entityTag == nil || entityTag!.hasPrefix("W/") else { return self }
        var response = self; response.variesEncoding = true
        if acceptsGzip, let encoder = try? RemoteGzipEncoder(level:6),
           let encoded = try? encoder.encode(body,final:true), encoded.count + 32 < body.count {
            response.body = encoded; response.contentEncoding = "gzip"
        }
        return response
    }
    var wire: Data { wire(reuse:false) }
    func wire(reuse: Bool) -> Data {
        let reason = status == 200 ? "OK" : status == 302 ? "Found" : status == 304 ? "Not Modified" : "Error"
        let redirect = location.flatMap { $0.contains("\r") || $0.contains("\n") ? nil : "Location: \($0)\r\n" } ?? ""
        let style = styleNonce.flatMap { value in value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) ? " 'nonce-\(value)'" : nil } ?? ""
        let length = stream == nil && status != 304 ? "Content-Length: \(body.count)\r\n" : ""
        let identity = nodeID.flatMap { $0.contains("\r") || $0.contains("\n") ? nil : "X-AutoApprove-Node: \($0)\r\n" } ?? ""
        let validator = entityTag.flatMap { $0.contains("\r") || $0.contains("\n") ? nil : "ETag: \($0)\r\n" } ?? ""
        let observation = observedAt.map { "X-AutoApprove-Observed-At: \($0.ISO8601Format())\r\n" } ?? ""
        let encoding = contentEncoding == "gzip" ? "Content-Encoding: gzip\r\n" : ""
        let vary = stream != nil || variesEncoding ? "Vary: Accept-Encoding\r\n" : ""
        let persistence = reuse ? "Connection: keep-alive\r\nKeep-Alive: timeout=5\r\n" : "Connection: close\r\n"
        let headers = "HTTP/1.1 \(status) \(reason)\r\n\(redirect)Content-Type: \(contentType)\r\n\(length)\(identity)\(validator)\(observation)\(encoding)\(vary)\(persistence)Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'\(style); img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n"
        return Data(headers.utf8) + body
    }
}

// The listener queue owns every entry and callback. One timer serves all
// server connections; entries hold weak clients and are removed on close.
final class RemoteHTTPDeadlines: @unchecked Sendable {
    private struct Entry {
        weak var client: RemoteHTTPConnection?
        let expiration: UInt64
    }
    private let queue: DispatchQueue
    private var entries: [ObjectIdentifier:Entry] = [:]
    private var timer: DispatchSourceTimer?
    private var armedAt: UInt64 = 0
    private var firing = false, stopped = false
    init(queue: DispatchQueue) { self.queue = queue }
    deinit { timer?.setEventHandler {}; timer?.cancel() }
    func arm(_ client: RemoteHTTPConnection, at expiration: UInt64) {
        guard !stopped else { return }
        entries[ObjectIdentifier(client)] = Entry(client:client,expiration:expiration)
        if !firing { reschedule() }
    }
    func remove(_ client: RemoteHTTPConnection) {
        guard entries.removeValue(forKey:ObjectIdentifier(client)) != nil else { return }
        if !firing { reschedule() }
    }
    func stop() {
        stopped = true; entries.removeAll()
        timer?.setEventHandler {}; timer?.cancel(); timer = nil; armedAt = 0
    }
    private func reschedule() {
        guard !stopped else { return }
        guard !entries.isEmpty else {
            if armedAt != 0 { timer?.schedule(deadline:.distantFuture); armedAt = 0 }
            return
        }
        var next = UInt64.max
        for entry in entries.values { next = min(next,entry.expiration) }
        guard timer == nil || next != armedAt else { return }
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue:queue)
            timer = source
            source.setEventHandler { [weak self] in self?.fire() }
            source.schedule(deadline:DispatchTime(uptimeNanoseconds:next))
            source.resume()
        } else { timer?.schedule(deadline:DispatchTime(uptimeNanoseconds:next)) }
        armedAt = next
    }
    private func fire() {
        guard !stopped else { return }
        // An already queued event may follow a later reschedule. Clear the
        // checkpoint so even an early event rearms the current minimum.
        armedAt = 0; firing = true
        let now = DispatchTime.now().uptimeNanoseconds
        var due: [ObjectIdentifier] = []
        for (id,entry) in entries where entry.expiration <= now { due.append(id) }
        for id in due { entries.removeValue(forKey:id)?.client?.checkDeadline() }
        firing = false; reschedule()
    }
}

// Connection state is confined to the listener's serial queue. Streams have
// one pending source read and one network send, with no unbounded byte queue.
final class RemoteHTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    var buffer = Data()
    var complete = false
    private var closed = false
    private var receiving = false
    private var reuseAfterSend = false
    private var completedRequests = 0
    let handler: @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse
    let onClose: () -> Void
    private let queue: DispatchQueue
    private var handlerTask: Task<Void, Never>?
    private let deadlines: RemoteHTTPDeadlines
    private var deadlineScheduled = false
    private var deadlineExpiresAt: UInt64 = 0
    private var sendExpiresAt: UInt64 = 0
    private var heartbeat: DispatchSourceTimer?
    private var stream: RemoteHTTPBodyStream?
    private var wireVersion: Int?
    private var gzip: RemoteGzipEncoder?
    private var nextPending = false
    private var pendingResult: Result<Data?, Error>?
    private var sending = false
    private var terminalWriteStarted: TimeInterval?
    init(_ connection: NWConnection, queue: DispatchQueue, deadlines: RemoteHTTPDeadlines, handler: @escaping @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse, onClose: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.deadlines = deadlines; self.handler = handler; self.onClose = onClose
    }
    func start() {
        queue.async {
            guard !self.closed else { return }
            self.connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.closeNow()
                default: break
                }
            }
            self.armDeadline(30)
            self.connection.start(queue: self.queue); self.receive()
        }
    }
    private func receive() {
        guard !closed, !receiving else { return }; receiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, ended, error in
            guard let self, !self.closed else { return }; self.receiving = false
            if ended || error != nil { self.closeNow(); return }
            if let data, !data.isEmpty {
                // Read disconnects while the handler/source is pending. Only a
                // reusable response already being sent may receive the next
                // message early; it is never dispatched before send completion.
                guard !self.complete || self.reuseAfterSend else { self.closeNow(); return }
                if self.buffer.isEmpty, !self.complete, self.completedRequests > 0 { self.armDeadline(30) }
                self.buffer.append(data)
            }
            guard !self.complete else {
                if self.buffer.count > 280_000 { self.closeNow() } else { self.receive() }
                return
            }
            self.readRequest(); self.receive()
        }
    }
    private func armDeadline(_ seconds: TimeInterval) {
        deadlineExpiresAt = (DispatchTime.now()+seconds).uptimeNanoseconds
        scheduleDeadline(at:sendExpiresAt == 0 ? deadlineExpiresAt : min(deadlineExpiresAt,sendExpiresAt))
    }
    private func scheduleDeadline(at expiration: UInt64) {
        deadlineScheduled = true; deadlines.arm(self,at:expiration)
    }
    fileprivate func checkDeadline() {
        deadlineScheduled = false
        guard !closed else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if deadlineExpiresAt != 0 && now >= deadlineExpiresAt
            || sendExpiresAt != 0 && now >= sendExpiresAt { closeNow(); return }
        let next = deadlineExpiresAt == 0 ? sendExpiresAt
            : sendExpiresAt == 0 ? deadlineExpiresAt : min(deadlineExpiresAt,sendExpiresAt)
        if next != 0 { scheduleDeadline(at:next) }
    }
    private func cancelDeadline() {
        if deadlineScheduled { deadlines.remove(self) }
        deadlineScheduled = false; deadlineExpiresAt = 0; sendExpiresAt = 0
    }
    private func readRequest() {
        guard !closed, !complete else { return }
        do {
            if var request = try RemoteHTTPRequest.parse(self.buffer) {
                if case .hostPort(let host, _) = self.connection.endpoint { request.clientAddress = String(describing:host) }
                self.complete = true
                self.completedRequests += 1; self.buffer = Data()
                let compressStream = RemoteGzipEncoder.accepts(request.headers["accept-encoding"])
                let allowsReuse = request.allowsConnectionReuse
                let method = request.method
                let measured = method == "GET" && ["/api/terminal","/api/terminal/stream"].contains(request.path)
                let queuedAt = RemoteTerminalPerformance.now
                self.handlerTask = Task { @MainActor in
                    if measured { RemoteTerminalPerformance.shared.observe(.mainQueue,elapsed:RemoteTerminalPerformance.now-queuedAt) }
                    let handled = await self.handler(request)
                    self.queue.async {
                        let preparationStart = RemoteTerminalPerformance.now
                        defer { if measured { RemoteTerminalPerformance.shared.observe(.transferPreparation,elapsed:RemoteTerminalPerformance.now-preparationStart,succeeded:handled.status < 400) } }
                        var response = handled
                        self.handlerTask = nil
                        guard !self.closed else { response.stream?.cancel(); return }
                        if let stream = response.stream {
                            if compressStream {
                                do {
                                    let encoder = try RemoteGzipEncoder()
                                    response.body = try encoder.encode(response.body)
                                    response.contentEncoding = "gzip"; self.gzip = encoder
                                } catch {
                                    stream.cancel(); self.send(RemoteHTTPResponse.error(error).wire,final:true); return
                                }
                            }
                            self.stream = stream
                            self.wireVersion = RemoteTerminalWire.version(for:response.contentType)
                            // The generic request deadline ends after a successful
                            // SSE handshake; an idle terminal remains connected.
                            // Reuse the shared checkpoint for the imminent first send.
                            self.deadlineExpiresAt = 0
                            if stream.needsHeartbeat {
                                let heartbeat = DispatchSource.makeTimerSource(queue: self.queue)
                                self.heartbeat = heartbeat
                                heartbeat.setEventHandler { [weak self] in
                                    guard let self, !self.closed, self.stream != nil, !self.sending,
                                          self.pendingResult == nil else { return }
                                    self.sendStream(self.wireVersion.map { RemoteTerminalWire.heartbeat(version:$0) } ?? Data(": keepalive\n\n".utf8))
                                }
                                heartbeat.schedule(deadline: .now() + 15, repeating: 15); heartbeat.resume()
                            }
                            let data = response.wire
                            if measured { self.terminalWriteStarted = RemoteTerminalPerformance.now }
                            self.send(data)
                        } else {
                            // No HTTP pipelining, handler parallelism or write
                            // replay. Every message repeats origin/node/source
                            // checks. Idle sockets are bounded by the existing
                            // 32 connection slots, five seconds and 32 reads.
                            self.reuseAfterSend = allowsReuse && self.completedRequests < 32
                                && (response.status == 200 || response.status == 304 && response.body.isEmpty)
                            let data = response.preparingTransfer(method:method,acceptsGzip:compressStream).wire(reuse:self.reuseAfterSend)
                            if measured { self.terminalWriteStarted = RemoteTerminalPerformance.now }
                            self.send(data,final:!self.reuseAfterSend)
                        }
                    }
                }
            }
        } catch {
            self.complete = true
            self.send(RemoteHTTPResponse.error(error).wire, final: true)
        }
    }
    private func send(_ data: Data, final: Bool = false) {
        guard !closed else { return }; sending = true
        if !final, stream != nil {
            // A disappeared reader must not hold a stream slot forever while
            // Network.framework waits for send-window space. No writes replay.
            armSendDeadline()
        }
        if final, deadlineExpiresAt == 0 {
            // SSE cancels the request deadline after its handshake. A final
            // error must still release its slot if the peer never disconnects.
            armDeadline(5)
        }
        // Finish the HTTP write side with FIN, then let the reader disconnect.
        // Cancelling immediately after contentProcessed can tear down the
        // connection while a peer is still receiving a large response.
        let terminalWrite = terminalWriteStarted; terminalWriteStarted = nil
        connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { [weak self] error in
            if let terminalWrite { RemoteTerminalPerformance.shared.observe(.initialWrite,elapsed:RemoteTerminalPerformance.now-terminalWrite,succeeded:error == nil) }
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }; self.sending = false
                self.sendExpiresAt = 0
                if error != nil { self.closeNow() }
                else if self.reuseAfterSend {
                    self.reuseAfterSend = false; self.complete = false
                    self.armDeadline(self.buffer.isEmpty ? 5 : 30)
                    self.readRequest(); self.receive()
                }
                else if !final { self.pumpStream() }
            }
        })
    }
    // One shared checkpoint serves request, idle/final and send windows. Writes
    // only advance their expiration;they do not allocate or rearm per frame.
    private func armSendDeadline() {
        sendExpiresAt = (DispatchTime.now()+30).uptimeNanoseconds
        if !deadlineScheduled { scheduleDeadline(at:sendExpiresAt) }
    }
    private func pumpStream() {
        guard !closed, !sending, let stream else { return }
        if let result = pendingResult {
            pendingResult = nil
            switch result {
            case .success(let data):
                if let data { sendStream(data) }
                else { self.stream = nil; sendStream(Data(),final:true) }
            case .failure(let error):
                stream.cancel(); self.stream = nil
                sendStream(RemoteServerEvent.failure(error,binary:wireVersion != nil,wireVersion:wireVersion ?? 2), final: true)
            }
            return
        }
        guard !nextPending else { return }; nextPending = true
        stream.next { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.nextPending = false; self.pendingResult = result; self.pumpStream()
            }
        }
    }
    private func sendStream(_ data: Data, final: Bool = false) {
        do { send(try gzip?.encode(data,final:final) ?? data,final:final) }
        catch { closeNow() } // Never splice uncompressed bytes into a gzip stream.
    }
    func close() { queue.async { self.closeNow() } }
    private func closeNow() {
        guard !closed else { return }; closed = true
        cancelDeadline(); heartbeat?.setEventHandler {}; heartbeat?.cancel(); heartbeat = nil
        handlerTask?.cancel(); handlerTask = nil
        stream?.cancel(); stream = nil; pendingResult = nil
        gzip = nil
        buffer = Data()
        connection.stateUpdateHandler = nil; connection.cancel(); onClose()
    }
}

/// Peer requests use resolved Bonjour endpoints directly, so the phone needs only its chosen Mac.
// All continuation and response-buffer accesses run on this exchange's serial queue.
final class RemoteHTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let timeout: TimeInterval
    private let retryRead: Bool
    private let expectedNodeID: String?
    private let acceptsGzip: Bool
    private let decoder: RemotePeerResponseDecoder
    private var continuation: CheckedContinuation<RemoteHTTPResponse, Error>?
    private var deadline: DispatchWorkItem?
    private var cancelled = false
    private var phase = "connecting"
    private var requestSent = false
    private let queue = DispatchQueue(label: "autoapprove.web.peer")
    convenience init(endpoint: NWEndpoint, path: String, method: String, body: Data, expectedNodeID: String? = nil, timeout: TimeInterval? = nil, entityTag: String? = nil, retryReads: Bool = true) throws {
        let identity = expectedNodeID.map { "X-AutoApprove-Node: \($0)\r\n" } ?? ""
        guard entityTag == nil || method == "GET" && body.isEmpty && path == "/api/inventory" && entityTag!.count <= 128 && !entityTag!.contains("\r") && !entityTag!.contains("\n") else { throw RemoteHTTPError(400,"목록 조회의 조건부 요청이 올바르지 않습니다.") }
        let validator = entityTag.map { "If-None-Match: \($0)\r\n" } ?? ""
        let acceptsGzip = method == "GET" && body.isEmpty
        let encoding = acceptsGzip ? "Accept-Encoding: gzip\r\n" : ""
        let request = Data("\(method) \(path) HTTP/1.1\r\nHost: autoapprove.local\r\n\(identity)\(validator)\(encoding)Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        let duration = timeout ?? (method == "GET" && path == "/api/state" ? 4 : 15)
        let retryRead = retryReads && method == "GET" && body.isEmpty
        try self.init(endpoint: endpoint, request: request, timeout: retryRead ? duration / 2 : duration, retryRead: retryRead, expectedNodeID:expectedNodeID, acceptsGzip:acceptsGzip)
    }
    private init(endpoint: NWEndpoint, request: Data, timeout: TimeInterval, retryRead: Bool, expectedNodeID: String?, acceptsGzip: Bool) throws {
        connection = NWConnection(to: endpoint, using: try RemoteLAN.tcpParameters(to: endpoint, interfaces: RemoteLAN.interfaces()))
        self.request = request; self.timeout = timeout; self.retryRead = retryRead
        self.expectedNodeID = expectedNodeID; self.acceptsGzip = acceptsGzip
        decoder = RemotePeerResponseDecoder(expectedNodeID:expectedNodeID,acceptsGzip:acceptsGzip)
    }
    func run() async throws -> RemoteHTTPResponse {
        do { let response = try await runOnce(); try Task.checkCancellation(); return response }
        catch let error as RemoteHTTPError where retryRead && error.status == 504 {
            try Task.checkCancellation()
            // Retry only an empty-body GET, once, within the original time
            // budget. Keep the exact path and node header. POST is never replayed.
            return try await RemoteHTTPExchange(endpoint: connection.endpoint, request: request,
                                                timeout: timeout, retryRead: false, expectedNodeID:expectedNodeID, acceptsGzip:acceptsGzip).runOnce()
        }
    }
    private func runOnce() async throws -> RemoteHTTPResponse {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
          try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.cancelled else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                self.connection.pathUpdateHandler = { [weak self] path in
                    guard let self, let error = RemoteLAN.localNetworkError(path) else { return }
                    self.finish(.failure(error))
                }
                self.connection.stateUpdateHandler = { state in
                    self.phase = String(describing: state)
                    switch state {
                    case .ready where !self.requestSent:
                        self.requestSent = true
                        self.connection.send(content: self.request, completion: .contentProcessed { error in
                            if let error { self.finish(.failure(error)) } else { self.phase = "waiting_headers"; self.receive() }
                        })
                    case .waiting:
                        if let error = RemoteLAN.localNetworkError(self.connection.currentPath) { self.finish(.failure(error)) }
                    case .failed(let error): self.finish(.failure(RemoteLAN.localNetworkError(self.connection.currentPath) ?? error))
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
                let deadline = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.finish(.failure(RemoteHTTPError(504, "Mac의 응답을 기다리다 시간이 지났습니다. 전송한 입력은 다시 보내지 말고 화면을 확인해주세요.", diagnostics: [
                        "phase": self.phase, "receivedBytes": String(self.decoder.receivedBytes), "expectedBytes": self.decoder.expectedBytes.map(String.init) ?? "unknown",
                        "endpoint": String(describing: self.connection.endpoint), "interfaces": self.connection.currentPath?.availableInterfaces.map(\.name).joined(separator: ",") ?? "unknown"
                    ])))
                }
                self.deadline = deadline
                self.queue.asyncAfter(deadline: .now() + self.timeout, execute: deadline)
            }
          }
        }, onCancel: {
            self.queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) }
        })
    }
    private func receive() {
        guard continuation != nil else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64_000) { data, _, ended, error in
            guard self.continuation != nil else { return }
            do {
                if let data, !data.isEmpty {
                    self.phase = "receiving"
                    if let response = try self.decoder.append(data) { self.finish(.success(response)); return }
                }
                if let error { throw error }
                if ended { try self.decoder.finish() }
                else { self.receive() }
            } catch {
                self.finish(.failure(error))
            }
        }
    }
    private func finish(_ result: Result<RemoteHTTPResponse, Error>) {
        guard let continuation else { return }; self.continuation = nil
        deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil; connection.pathUpdateHandler = nil; connection.cancel()
        continuation.resume(with: result)
    }
}
