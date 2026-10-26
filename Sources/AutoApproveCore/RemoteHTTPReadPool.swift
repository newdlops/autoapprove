import Foundation
import Network

/// Only verified, finite GET transports are retained. Values/permissions are
/// never cached here: every request has a new decoder and exact node header.
final class RemoteHTTPReadPool: @unchecked Sendable {
    private struct Key: Hashable { let endpoint: NWEndpoint; let node: String; let route: [RemoteLANInterface] }
    private struct Idle {
        let channel: RemoteHTTPReadConnection
        let until: TimeInterval
    }
    private let lock = NSLock()
    private var idle: [Key:Idle] = [:]
    private var epoch = UUID()
    private var expiry: (id: UUID, task: DispatchWorkItem)?
    private let expiryQueue = DispatchQueue(label:"autoapprove.web.peer-idle")

    func read(endpoint: NWEndpoint, path: String, expectedNodeID: String, timeout: TimeInterval? = nil,
              entityTag: String? = nil, retryReads: Bool = true, wait: Int = 0) async throws -> RemoteHTTPResponse {
        try Task.checkCancellation()
        guard UUID(uuidString:expectedNodeID) != nil, path.hasPrefix("/"), !path.contains("\r"), !path.contains("\n"),
              entityTag == nil || path == "/api/inventory" && entityTag!.count <= 128 && !entityTag!.contains("\r") && !entityTag!.contains("\n") else {
            throw RemoteHTTPError(400,"Mac 읽기 요청이 올바르지 않습니다.")
        }
        let interfaces = RemoteLAN.interfaces()
        // Re-evaluate the physical route even when a socket is available. A VPN
        // or interface/address change cannot borrow a different route's socket.
        let parameters = try RemoteLAN.tcpParameters(to:endpoint,interfaces:interfaces)
        let route = Self.routeKey(interfaces)
        let key = Key(endpoint:endpoint,node:expectedNodeID,route:route)
        let (channel,reused) = take(key,parameters:parameters)
        let duration = timeout ?? (path == "/api/state" ? 4 : 15)
        let started = ProcessInfo.processInfo.systemUptime
        let validator = entityTag.map { "If-None-Match: \($0)\r\n" } ?? ""
        let preference = path == "/api/inventory" && wait > 0 ? "Prefer: wait=\(min(6,wait))\r\n" : ""
        let request = Data("GET \(path) HTTP/1.1\r\nHost: autoapprove.local\r\nX-AutoApprove-Node: \(expectedNodeID)\r\n\(validator)\(preference)Accept-Encoding: gzip\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n".utf8)
        do {
            let response = try await channel.read(request,expectedNodeID:expectedNodeID,timeout:retryReads ? duration/2 : duration)
            try Task.checkCancellation(); return response
        } catch {
            // A decoded bad response may still be tried on the existing
            // alternate route, but must never be replayed on this same socket.
            if let response = error as? RemoteHTTPReadResponseFailure { throw response.underlying }
            let timedOut = (error as? RemoteHTTPError)?.status == 504
            guard RemoteReadRecovery.isTransient(error), reused || retryReads && timedOut else { throw error }
            try Task.checkCancellation()
            let remaining = duration-(ProcessInfo.processInfo.systemUptime-started)
            guard remaining > 0 else { throw error }
            // One fresh fallback within the original budget, for GET only.
            // POST and SSE do not enter this type or acquire these sockets.
            return try await RemoteHTTPExchange(endpoint:endpoint,path:path,method:"GET",body:Data(),
                expectedNodeID:expectedNodeID,timeout:remaining,entityTag:entityTag,retryReads:false,wait:wait).run()
        }
    }
    /// A route is the complete multiset of physical interface values. Usually
    /// RemoteLAN's snapshot is already canonical,so share its immutable storage.
    /// Mask ties and arbitrary input ordering retain a complete canonical sort.
    static func routeKey(_ interfaces: [RemoteLANInterface]) -> [RemoteLANInterface] {
        guard interfaces.count > 1 else { return interfaces }
        for index in 1..<interfaces.count {
            if routePrecedes(interfaces[index],interfaces[index - 1]) {
                return interfaces.sorted(by: routePrecedes)
            }
        }
        return interfaces
    }
    private static func routeRank(_ kind: RemoteLANInterface.Kind) -> Int {
        switch kind { case .wifi: return 0; case .ethernet: return 1 }
    }
    private static func routePrecedes(_ left: RemoteLANInterface, _ right: RemoteLANInterface) -> Bool {
        (routeRank(left.kind),left.name,left.address,left.netmask)
            < (routeRank(right.kind),right.name,right.address,right.netmask)
    }
    private func take(_ key: Key, parameters: NWParameters) -> (RemoteHTTPReadConnection,Bool) {
        lock.lock()
        let saved = idle.removeValue(forKey:key), token = epoch
        lock.unlock()
        if let saved, ProcessInfo.processInfo.systemUptime < saved.until { return (saved.channel,true) }
        saved?.channel.cancel()
        let channel = RemoteHTTPReadConnection(endpoint:key.endpoint,parameters:parameters)
        channel.onIdle = { [weak self] channel in self?.retain(channel,key:key,epoch:token) ?? false }
        channel.onClose = { [weak self, weak channel] in
            guard let channel else { return }; self?.discard(channel,key:key)
        }
        return (channel,false)
    }
    private func retain(_ channel: RemoteHTTPReadConnection, key: Key, epoch token: UUID) -> Bool {
        let until = ProcessInfo.processInfo.systemUptime+4
        lock.lock()
        guard epoch == token else { lock.unlock(); return false }
        var retired = [Idle]()
        if let previous = idle.removeValue(forKey:key) { retired.append(previous) }
        if idle.count >= 4, let oldest = idle.min(by:{$0.value.until < $1.value.until})?.key,
           let previous = idle.removeValue(forKey:oldest) { retired.append(previous) }
        idle[key] = Idle(channel:channel,until:until)
        armExpiry()
        lock.unlock()
        for previous in retired { previous.channel.cancel() }
        return true
    }
    /// One expiration wakeup for the entire pool, not one cancelled timer per
    /// request. A checkout removes its entry before expiry can retire it.
    private func armExpiry() {
        guard expiry == nil, let until = idle.values.map(\.until).min() else { return }
        let id = UUID(), task = DispatchWorkItem { [weak self] in self?.expire(id) }
        expiry = (id,task)
        expiryQueue.asyncAfter(deadline:.now()+max(0,until-ProcessInfo.processInfo.systemUptime),execute:task)
    }
    private func expire(_ id: UUID) {
        lock.lock()
        guard expiry?.id == id else { lock.unlock(); return }
        expiry = nil
        let now = ProcessInfo.processInfo.systemUptime
        let expired = idle.filter { $0.value.until <= now }
        for key in expired.keys { idle.removeValue(forKey:key) }
        armExpiry(); lock.unlock()
        for value in expired.values { value.channel.cancel() }
    }
    private func discard(_ channel: RemoteHTTPReadConnection, key: Key) {
        lock.lock()
        if idle[key]?.channel === channel { idle.removeValue(forKey:key) }
        lock.unlock()
    }
    func removeAll() {
        lock.lock(); epoch = UUID(); let previous = Array(idle.values); idle.removeAll()
        expiry?.task.cancel(); expiry = nil; lock.unlock()
        for value in previous { value.channel.cancel() }
    }
    deinit { expiry?.task.cancel(); for value in idle.values { value.channel.cancel() } }
}

private struct RemoteHTTPReadResponseFailure: Error { let underlying: Error }

/// One request at a time on its own serial queue. An idle receive observes FIN
/// immediately; unexpected unsolicited bytes retire the socket. There is never
/// HTTP pipelining, a saved response, or a queue of application requests.
private final class RemoteHTTPReadConnection: @unchecked Sendable {
    private struct Read {
        let id: UUID
        let bytes: Data
        let decoder: RemotePeerResponseDecoder
        let continuation: CheckedContinuation<RemoteHTTPResponse,Error>
    }
    private let connection: NWConnection
    private let queue = DispatchQueue(label:"autoapprove.web.peer-read")
    private var pending: Read?
    private var deadline: DispatchWorkItem?
    private var started = false, ready = false, sent = false, receiving = false, closed = false
    private var requests = 0
    private var cancelledReads: Set<UUID> = []
    var onIdle: ((RemoteHTTPReadConnection) -> Bool)?
    var onClose: (() -> Void)?
    init(endpoint: NWEndpoint, parameters: NWParameters) { connection = NWConnection(to:endpoint,using:parameters) }
    deinit { connection.cancel() }

    func read(_ bytes: Data, expectedNodeID: String, timeout: TimeInterval) async throws -> RemoteHTTPResponse {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.cancelledReads.remove(id) == nil else { continuation.resume(throwing:CancellationError()); return }
                    guard !self.closed else { continuation.resume(throwing:RemoteHTTPError(503,"Mac의 읽기 연결을 다시 확인합니다.")); return }
                    guard self.pending == nil else { continuation.resume(throwing:RemoteHTTPError(500,"중복된 Mac 읽기 요청입니다.")); return }
                    self.pending = Read(id:id,bytes:bytes,decoder:RemotePeerResponseDecoder(expectedNodeID:expectedNodeID,acceptsGzip:true),continuation:continuation)
                    self.sent = false; self.requests += 1
                    let deadline = DispatchWorkItem { [weak self] in
                        guard let self, self.pending?.id == id else { return }
                        self.close(RemoteHTTPError(504,"Mac의 읽기 응답을 기다리다 시간이 지났습니다."))
                    }
                    self.deadline = deadline; self.queue.asyncAfter(deadline:.now()+max(0.001,timeout),execute:deadline)
                    if !self.started { self.start() }
                    else if self.ready { self.send() }
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelledReads.insert(id)
                if self.pending?.id == id { self.close(CancellationError()) }
            }
        }
    }
    private func start() {
        started = true
        connection.pathUpdateHandler = { [weak self] path in
            guard let self, let error = RemoteLAN.localNetworkError(path) else { return }; self.close(error)
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.ready = true; self.send(); self.receive()
            case .waiting:
                if let error = RemoteLAN.localNetworkError(self.connection.currentPath) { self.close(error) }
            case .failed(let error): self.close(RemoteLAN.localNetworkError(self.connection.currentPath) ?? error)
            case .cancelled: self.close(CancellationError())
            default: break
            }
        }
        connection.start(queue:queue)
    }
    private func send() {
        guard !closed, !sent, let read = pending else { return }; sent = true
        connection.send(content:read.bytes,completion:.contentProcessed { [weak self] error in
            guard let self, self.pending?.id == read.id else { return }; if let error { self.close(error) }
        })
    }
    private func receive() {
        guard !closed, !receiving else { return }; receiving = true
        connection.receive(minimumIncompleteLength:1,maximumLength:64_000) { [weak self] data, _, ended, error in
            guard let self, !self.closed else { return }; self.receiving = false
            if let data, !data.isEmpty {
                do {
                    guard let read = self.pending, self.sent else { throw RemoteHTTPError(502,"Mac이 요청하지 않은 응답을 보냈습니다.",diagnostics:["failureKind":"protocol"]) }
                    if let response = try read.decoder.append(data) {
                        self.pending = nil; self.deadline?.cancel(); self.deadline = nil
                        if !ended, error == nil, read.decoder.allowsConnectionReuse, self.requests < 32,
                           self.onIdle?(self) == true { self.receive() }
                        else { self.close() }
                        read.continuation.resume(returning:response); return
                    }
                } catch { self.close(RemoteHTTPReadResponseFailure(underlying:error)); return }
            }
            if let error { self.close(error); return }
            if ended { self.close(RemoteHTTPError(503,"Mac의 읽기 연결이 닫혔습니다. 같은 Mac을 다시 확인합니다.")); return }
            self.receive()
        }
    }
    private func close(_ error: Error = CancellationError()) {
        guard !closed else { return }; closed = true
        deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil; connection.pathUpdateHandler = nil; connection.cancel()
        let read = pending; pending = nil; onClose?(); onClose = nil; onIdle = nil
        read?.continuation.resume(throwing:error)
    }
    func cancel() { queue.async { self.close() } }
}
