import Foundation
import Network
import Darwin

typealias RemoteHTTPStreamCompletion = @Sendable (Result<Data?, Error>) -> Void

/// A body source has at most one pending read. The HTTP connection requests its
/// next chunk only after Network.framework has processed the previous send.
protocol RemoteHTTPBodyStream: AnyObject, Sendable {
    var needsHeartbeat: Bool { get }
    func next(_ completion: @escaping RemoteHTTPStreamCompletion)
    func cancel()
}

enum RemoteServerEvent {
    static func output(_ value: ManagedPTYOutput, wire: RemoteTerminalWireEncoder? = nil) throws -> Data {
        if let wire { return try wire.encode(value,event:2) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = try encoder.encode(value)
        guard json.count <= 2_000_000 else { throw RemoteHTTPError(502, "터미널 화면이 너무 큽니다. 터미널 크기를 줄여 다시 연결해주세요.") }
        return Data("event: output\nid: \(value.offset)\ndata: ".utf8) + json + Data("\n\n".utf8)
    }
    static func failure(_ error: Error, binary: Bool = false, wireVersion: Int = 2) -> Data {
        let status = (error as? RemoteHTTPError)?.status
        let retryable = error is NWError || status == 503 || status == 504
        if binary {
            struct Failure: Encodable { let error: String, retryable: Bool }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            let wire = RemoteTerminalWireEncoder(jsonEncoder:encoder,version:wireVersion)
            if let data = try? wire.encode(Failure(error:error.localizedDescription,retryable:retryable),event:3) { return data }
            // This constant is a complete JSON-fallback binary frame.
            let json = Data("{\"error\":\"Stream failed\",\"retryable\":false}".utf8)
            return Data([65,65,UInt8(wireVersion),131,UInt8(json.count)]) + json
        }
        let json = (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription, "retryable": retryable])) ?? Data("{\"error\":\"Stream failed\"}".utf8)
        return Data("event: failure\ndata: ".utf8) + json + Data("\n\n".utf8)
    }
}

/// PTY read events push a single coalesced wakeup. A slow subscriber stores no
/// byte queue: its cursor resumes from the PTY's bounded history, or a snapshot.
final class RemotePTYBodyStream: RemoteHTTPBodyStream, @unchecked Sendable {
    let needsHeartbeat = true
    private struct Controls: Equatable {
        let columns: Int
        let rows: Int
        let canInput: Bool
        let exitCode: Int?
        init(_ output: ManagedPTYOutput) {
            columns = output.columns; rows = output.rows
            canInput = output.canInput; exitCode = output.exitCode
        }
    }
    private let terminal: ManagedPTY
    private let wireEncoder: RemoteTerminalWireEncoder?
    private let client: String?
    private let queue = DispatchQueue(label: "autoapprove.web.pty-stream")
    private let wakeLock = NSLock()
    private var wakeQueued = false
    private var observer: UUID?
    // All remaining state is confined to queue.
    private var offset: Int
    private var initialOutput: ManagedPTYOutput?
    private var controls: Controls
    private var waiter: (@Sendable (Result<ManagedPTYOutput?, Error>) -> Void)?
    private var deadline: DispatchWorkItem?
    private var ended: Bool
    private var cancelled = false

    init(terminal: ManagedPTY, offset: Int?, client: String?, emitInitial: Bool = true, binary: Bool = false, wireVersion: Int = 2) throws {
        let initial = try terminal.read(after: offset, client: client)
        self.terminal = terminal; self.client = client; self.offset = initial.offset
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let wire = binary ? RemoteTerminalWireEncoder(jsonEncoder:encoder,version:wireVersion) : nil
        wireEncoder = wire
        _ = try RemoteServerEvent.output(initial,wire:wire) // Validate before stream headers.
        initialOutput = emitInitial || !initial.data.isEmpty || initial.exitCode != nil ? initial : nil
        controls = Controls(initial); ended = initial.exitCode != nil
        observer = terminal.observeOutput { [weak self] in self?.wake() }
    }
    deinit { if let observer { terminal.removeOutputObserver(observer) } }

    func next(_ completion: @escaping RemoteHTTPStreamCompletion) {
        queue.async {
            guard !self.cancelled else { completion(.success(nil)); return }
            guard self.waiter == nil else { completion(.failure(RemoteHTTPError(500, "중복된 터미널 출력 요청입니다."))); return }
            self.waiter = { result in
                do { completion(.success(try result.get().map { try RemoteServerEvent.output($0,wire:self.wireEncoder) })) }
                catch { completion(.failure(error)) }
            }
            self.deliver()
        }
    }
    /// Compatibility JSON reads wait for an actual PTY/control event or one
    /// bounded timeout, rather than inspecting the terminal every 25ms.
    func readUpdate(timeout: TimeInterval) async throws -> ManagedPTYOutput {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ManagedPTYOutput, Error>) in
                queue.async {
                    guard !self.cancelled, self.waiter == nil else { continuation.resume(throwing: CancellationError()); return }
                    self.waiter = { result in
                        do {
                            guard let output = try result.get() else { throw CancellationError() }
                            continuation.resume(returning: output)
                        } catch { continuation.resume(throwing: error) }
                    }
                    let deadline = DispatchWorkItem { [weak self] in
                        guard let self, self.waiter != nil else { return }
                        do { self.finish(.success(try self.terminal.read(after: self.offset, client: self.client))) }
                        catch { self.finish(.failure(error)) }
                    }
                    self.deadline = deadline
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
                    self.deliver()
                }
            }
        } onCancel: { self.cancel() }
    }
    private func wake() {
        wakeLock.lock()
        guard !wakeQueued else { wakeLock.unlock(); return }
        wakeQueued = true; wakeLock.unlock()
        queue.async {
            self.wakeLock.lock(); self.wakeQueued = false; self.wakeLock.unlock()
            self.deliver()
        }
    }
    private func deliver() {
        guard !cancelled, waiter != nil else { return }
        if let output = initialOutput {
            initialOutput = nil; finish(.success(output)); return
        }
        if ended { finish(.success(nil)); return }
        do {
            let update = try terminal.read(after: offset, client: client)
            let nextControls = Controls(update)
            guard !update.data.isEmpty || update.reset || controls != nextControls else { return }
            offset = update.offset; controls = nextControls; ended = update.exitCode != nil
            finish(.success(update))
        } catch { finish(.failure(error)) }
    }
    private func finish(_ result: Result<ManagedPTYOutput?, Error>) {
        deadline?.cancel(); deadline = nil
        let completion = waiter; waiter = nil; completion?(result)
    }
    func cancel() {
        queue.async {
            guard !self.cancelled else { return }; self.cancelled = true
            if let observer = self.observer { self.terminal.removeOutputObserver(observer); self.observer = nil }
            self.initialOutput = nil; self.finish(.success(nil))
        }
    }
}

/// A gateway keeps one live LAN connection to the owning Mac. It assembles one
/// batch of complete SSE events per downstream send, so fragmentation or failure
/// cannot splice a gateway error into the middle of an upstream JSON line.
struct RemotePeerStreamOpening: Sendable {
    let data: Data, binary: Bool
    var wireVersion: Int = 2
}

final class RemotePTYPeerBodyStream: RemoteHTTPBodyStream, @unchecked Sendable {
    // Upstream comments are already relayed. Inserting a gateway heartbeat
    // between arbitrary TCP fragments could split the upstream JSON data line.
    let needsHeartbeat = false
    private let connection: NWConnection
    private let request: Data
    private let expectedNodeID: String
    private let openingTimeout: TimeInterval
    private let allowsBinary: Bool
    private let maximumWireVersion: Int
    private var binary = false
    private var wireVersion = 2
    private let queue = DispatchQueue(label: "autoapprove.web.pty-peer-stream")
    private var opening: CheckedContinuation<RemotePeerStreamOpening, Error>?
    private var deadline: DispatchWorkItem?
    private var buffer = Data()
    private var waiter: RemoteHTTPStreamCompletion?
    private var opened = false
    private var started = false
    private var cancelled = false
    private var receiving = false
    private var ended = false
    private var failure: Error?
    private var gzip: RemoteGzipDecoder?
    private var compressedSinceEvent = 0
    private static let eventLimit = 2_000_128
    private var searchedBytes = 0

    init(endpoint: NWEndpoint, path: String, expectedNodeID: String, timeout: TimeInterval = 15, allowsBinary: Bool = false, maximumWireVersion: Int = 2) throws {
        guard !expectedNodeID.contains("\r"), !expectedNodeID.contains("\n") else { throw RemoteHTTPError(502, "Mac의 연결 ID가 올바르지 않습니다.") }
        connection = NWConnection(to: endpoint, using: try RemoteLAN.tcpParameters(to: endpoint, interfaces: RemoteLAN.interfaces()))
        self.expectedNodeID = expectedNodeID
        openingTimeout = max(0.05, timeout)
        self.allowsBinary = allowsBinary
        self.maximumWireVersion = maximumWireVersion
        let types = maximumWireVersion == 3 ? RemoteTerminalWire.compactContentType + ", " + RemoteTerminalWire.contentType : RemoteTerminalWire.contentType
        let accept = allowsBinary ? types + ", text/event-stream" : "text/event-stream"
        request = Data("GET \(path) HTTP/1.1\r\nHost: autoapprove.local\r\nX-AutoApprove-Node: \(expectedNodeID)\r\nAccept: \(accept)\r\nAccept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }
    deinit { connection.cancel() }

    /// Return only whole events already received with the authenticated
    /// headers. Never delay opening for another packet or retain this batch.
    func open() async throws -> Data {
        try await openContent().data
    }
    func openContent() async throws -> RemotePeerStreamOpening {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemotePeerStreamOpening, Error>) in
                queue.async {
                    guard !self.cancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.opening = continuation
                    self.connection.pathUpdateHandler = { [weak self] path in
                        guard let self, !self.cancelled, let error = RemoteLAN.localNetworkError(path) else { return }
                        self.fail(error)
                    }
                    self.connection.stateUpdateHandler = { [weak self] state in
                        guard let self, !self.cancelled else { return }
                        switch state {
                        case .ready where !self.started:
                            self.started = true
                            self.connection.send(content: self.request, completion: .contentProcessed { [weak self] error in
                                guard let self, !self.cancelled else { return }
                                if let error { self.fail(error) } else { self.receiveHeaders() }
                            })
                        case .waiting:
                            if let error = RemoteLAN.localNetworkError(self.connection.currentPath) { self.fail(error) }
                        case .failed(let error): self.fail(RemoteLAN.localNetworkError(self.connection.currentPath) ?? error)
                        default: break
                        }
                    }
                    let deadline = DispatchWorkItem { [weak self] in
                        guard let self, !self.opened, !self.cancelled else { return }
                        self.fail(RemoteHTTPError(504, "Mac의 터미널 연결을 기다리다 시간이 지났습니다. 다시 연결해주세요."))
                    }
                    self.deadline = deadline
                    self.queue.asyncAfter(deadline: .now() + self.openingTimeout, execute: deadline)
                    self.connection.start(queue: self.queue)
                }
            }
        } onCancel: { self.cancel() }
    }
    private func receiveHeaders() {
        guard !cancelled else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, ended, error in
            guard let self, !self.cancelled else { return }
            if let data { self.buffer.append(data) }
            do {
                if let boundary = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    guard boundary.lowerBound <= 16_384, let head = String(data: self.buffer[..<boundary.lowerBound], encoding: .utf8) else { throw RemoteHTTPError(502, "Mac의 응답 헤더가 올바르지 않습니다.") }
                    let lines = head.components(separatedBy: "\r\n")
                    guard let status = lines.first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw RemoteHTTPError(502, "Mac의 응답 상태를 읽지 못했습니다.") }
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        guard let colon = line.firstIndex(of: ":") else { throw RemoteHTTPError(502, "Mac의 응답 헤더가 올바르지 않습니다.") }
                        let key = line[..<colon].lowercased()
                        guard headers[key] == nil else { throw RemoteHTTPError(502, "Mac의 응답 헤더가 중복되었습니다.") }
                        headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                    if status == 200 {
                        let encoding = headers["content-encoding"]?.lowercased()
                        let type = headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
                        let version = RemoteTerminalWire.version(for:type)
                        guard type == "text/event-stream" || self.allowsBinary && version != nil && version! <= self.maximumWireVersion,
                              headers["transfer-encoding"] == nil,
                              encoding == nil || encoding == "identity" || encoding == "gzip",
                              headers["x-autoapprove-node"] == self.expectedNodeID else { throw RemoteHTTPError(502, "Mac의 터미널 연결 정보가 바뀌었습니다. 주소를 다시 추가해주세요.", diagnostics: ["failureKind":"identity"]) }
                        self.binary = version != nil; self.wireVersion = version ?? 2
                        let body = self.buffer.subdata(in: boundary.upperBound..<self.buffer.count)
                        self.buffer = Data()
                        if encoding == "gzip" {
                            let decoder = try RemoteGzipDecoder(); try decoder.append(body)
                            self.gzip = decoder; self.compressedSinceEvent = body.count
                        } else { self.buffer = body }
                        self.opened = true; self.ended = ended; self.failure = error
                        self.deadline?.cancel(); self.deadline = nil
                        let continuation = self.opening; self.opening = nil
                        let initial: Data
                        do { initial = try self.bufferedEvents() ?? Data() }
                        catch {
                            // Header authentication succeeded. Body corruption
                            // remains a stream failure after HTTP 200, just as
                            // when the same bytes arrive in a later packet.
                            self.fail(error); initial = Data()
                        }
                        continuation?.resume(returning:RemotePeerStreamOpening(data:initial,binary:self.binary,wireVersion:self.wireVersion)); return
                    }
                    guard let length = headers["content-length"].flatMap(Int.init), (0...256_000).contains(length) else { throw RemoteHTTPError(502, "Mac의 오류 응답이 올바르지 않습니다.") }
                    if self.buffer.count >= boundary.upperBound + length {
                        let body = self.buffer.subdata(in: boundary.upperBound..<boundary.upperBound + length)
                        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                        throw RemoteHTTPError((400...599).contains(status) ? status : 502, object?["error"] as? String ?? "Mac에서 터미널 연결을 거절했습니다.")
                    }
                } else if self.buffer.count > 16_384 { throw RemoteHTTPError(502, "Mac의 응답 헤더가 너무 큽니다.") }
                guard self.buffer.count <= 280_000 else { throw RemoteHTTPError(502, "Mac의 응답이 너무 큽니다.") }
                if let error { throw error }
                if ended { throw RemoteHTTPError(502, "Mac이 터미널 연결을 닫았습니다. 다시 연결해주세요.") }
                self.receiveHeaders()
            } catch { self.fail(error) }
        }
    }
    func next(_ completion: @escaping RemoteHTTPStreamCompletion) {
        queue.async {
            guard !self.cancelled else { completion(.success(nil)); return }
            guard self.opened, self.waiter == nil else { completion(.failure(RemoteHTTPError(500, "Mac의 터미널 출력 연결을 확인해주세요."))); return }
            self.waiter = completion; self.deliver()
            if self.waiter != nil, self.deadline == nil {
                // Starts only while a downstream reader is asking for an
                // event. Backpressure never consumes this idle/partial-event
                // budget, and trickled bytes cannot keep an event open forever.
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.waiter != nil else { return }
                    self.fail(RemoteHTTPError(504,"Mac의 터미널 출력이 멈춰 다시 연결합니다.",diagnostics:["failureKind":"streamTimeout"]))
                }
                self.deadline = timeout; self.queue.asyncAfter(deadline:.now()+35,execute:timeout)
            }
        }
    }
    private func deliver() {
        guard !cancelled, let completion = waiter else { return }
        do {
          while true {
            if let data = try bufferedEvents() {
                deadline?.cancel(); deadline = nil
                waiter = nil; completion(.success(data)); return
            }
            if ended {
                if let gzip { try gzip.finish() }
                let incomplete = !buffer.isEmpty; buffer = Data(); searchedBytes = 0; waiter = nil
                deadline?.cancel(); deadline = nil
                if let failure { completion(.failure(failure)) }
                else if incomplete { completion(.failure(RemoteHTTPError(503,"Mac의 터미널 출력이 전송 중 끊겼습니다. 다시 연결해주세요."))) }
                else { completion(.success(nil)) }
                return
            }
            guard !receiving else { return }; receiving = true
            connection.receive(minimumIncompleteLength:1,maximumLength:gzip == nil ? min(65_536,Self.eventLimit-buffer.count) : 65_536) { [weak self] data, _, ended, error in
                guard let self, !self.cancelled else { return }; self.receiving = false
                do {
                    if let data, !data.isEmpty {
                        if let gzip = self.gzip {
                            self.compressedSinceEvent += data.count
                            guard self.compressedSinceEvent <= 2_200_000 else { throw RemoteHTTPError(502,"Mac의 압축 출력 이벤트가 너무 큽니다.") }
                            try gzip.append(data)
                        } else { self.buffer.append(data) }
                    }
                    if let error { self.failure = error; self.ended = true }
                    if ended { self.ended = true }
                    self.deliver()
                } catch { self.fail(error) }
            }
            return
          }
        } catch { fail(error) }
    }
    /// Search only inspected-byte overlap and new bytes. memchr never scans
    /// the last byte by itself; its successor is always inside this borrow.
    private func eventBoundary() throws -> Range<Data.Index>? {
        if binary { return try binaryBoundary() }
        let start = buffer.startIndex, offset = searchedBytes
        return buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress, bytes.count-offset >= 2 else { return nil }
            var index = offset
            while index < bytes.count-1 {
                guard let found = memchr(base.advanced(by:index),10,bytes.count-index-1) else { return nil }
                let position = base.distance(to:UnsafeRawPointer(found))
                if bytes[position+1] == 10 {
                    // Coalesce only complete events already in this borrow.
                    // Never read or wait to fill a batch. A first event larger
                    // than64KiB keeps its existing individual event limit.
                    var end = position+2, next = end
                    let limit = min(bytes.count,min(65_536,Self.eventLimit))
                    while next < limit-1 {
                        guard let found = memchr(base.advanced(by:next),10,limit-next-1) else { break }
                        let position = base.distance(to:UnsafeRawPointer(found))
                        if bytes[position+1] == 10 { end = position+2; next = end }
                        else { next = position+1 }
                    }
                    return (start+end-2)..<(start+end)
                }
                index = position+1
            }
            return nil
        }
    }
    /// Envelope headers have at most ten varint bytes. Incomplete payloads need
    /// no body scan; only complete, bounded frames enter a downstream batch.
    private func binaryBoundary() throws -> Range<Data.Index>? {
        let start = buffer.startIndex
        return try buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func endAt(_ offset: Int) throws -> Int? {
                let available = bytes.count-offset
                for index in 0..<min(3,available) {
                    guard bytes[offset+index] == (index == 2 ? UInt8(wireVersion) : 65) else { throw RemoteHTTPError(502,"Mac의 터미널 전송 버전이 다릅니다.") }
                }
                guard available >= 4 else { return nil }
                let mode = bytes[offset+3]
                guard mode < 5 || (128...131).contains(mode) else { throw RemoteHTTPError(502,"Mac의 터미널 이벤트가 올바르지 않습니다.") }
                var length: UInt64 = 0
                for index in 0..<10 {
                    guard available > 4+index else { return nil }
                    let byte = bytes[offset+4+index]
                    guard index < 9 || byte <= 1 else { throw RemoteHTTPError(502,"Mac의 터미널 길이가 올바르지 않습니다.") }
                    length |= UInt64(byte & 127) << (index*7)
                    if byte & 128 == 0 {
                        guard index == 0 || byte != 0, length <= RemoteTerminalWire.byteLimit,
                              mode != 4 || length == 0 else { throw RemoteHTTPError(502,"Mac의 터미널 프레임이 너무 크거나 올바르지 않습니다.") }
                        let end = offset+5+index+Int(length)
                        return end <= bytes.count ? end : nil
                    }
                }
                throw RemoteHTTPError(502,"Mac의 터미널 헤더가 너무 깁니다.")
            }
            guard var end = try endAt(0) else { return nil }
            let limit = min(bytes.count,65_536)
            while end < limit {
                // Deliver an already complete prefix before reporting corrupt
                // data that follows it, as for a later fragmented packet.
                do { guard let next = try endAt(end), next <= limit else { break };end = next }
                catch { break }
            }
            return (start+end-1)..<(start+end)
        }
    }
    private func bufferedEvents() throws -> Data? {
        while true {
            // The final inspected newline may pair with the next fragment.
            // Previously inspected screen bytes need no further search.
            if let boundary = try eventBoundary() {
                let length = boundary.upperBound-buffer.startIndex
                guard length <= Self.eventLimit else { throw RemoteHTTPError(502,"Mac의 터미널 출력 이벤트가 너무 큽니다.") }
                let data = buffer.subdata(in:buffer.startIndex..<boundary.upperBound)
                // Keep a view until an empty tail releases storage, or a
                // consumed prefix can pay for one bounded compaction. Data's
                // nonzero startIndex tracks that prefix across later appends.
                if boundary.upperBound == buffer.endIndex {
                    buffer = Data()
                } else if boundary.upperBound >= 65_536,
                          boundary.upperBound >= buffer.endIndex-boundary.upperBound {
                    buffer = buffer.subdata(in:boundary.upperBound..<buffer.endIndex)
                } else {
                    buffer = buffer[boundary.upperBound...]
                }
                searchedBytes = 0; compressedSinceEvent = 0
                return data
            }
            searchedBytes = max(0,buffer.count-1)
            guard buffer.count < Self.eventLimit else { throw RemoteHTTPError(502,"Mac의 터미널 출력 이벤트가 너무 큽니다.") }
            guard let gzip, !gzip.needsInput, !gzip.ended else { return nil }
            buffer.append(try gzip.read(maximum:min(32_768,Self.eventLimit-buffer.count)))
        }
    }
    private func fail(_ error: Error) {
        guard !cancelled else { return }
        deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil; connection.pathUpdateHandler = nil
        if let continuation = opening {
            opening = nil; continuation.resume(throwing: error); cancelNow()
        } else {
            failure = error; ended = true; buffer = Data(); searchedBytes = 0; gzip = nil
            connection.cancel()
            deliver()
        }
    }
    func cancel() { queue.async { self.cancelNow() } }
    private func cancelNow() {
        guard !cancelled else { return }; cancelled = true
        deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil; connection.pathUpdateHandler = nil; connection.cancel(); buffer = Data(); searchedBytes = 0; gzip = nil
        let continuation = opening; opening = nil; continuation?.resume(throwing: CancellationError())
        let completion = waiter; waiter = nil; completion?(.success(nil))
    }
}
