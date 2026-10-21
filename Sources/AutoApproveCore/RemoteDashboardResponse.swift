import Foundation
import CryptoKit

private let responseHexDigits = Array("0123456789abcdef".utf8)

private func responseDigest(_ data: Data) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(64)
    for value in SHA256.hash(data: data) {
        bytes.append(responseHexDigits[Int(value >> 4)])
        bytes.append(responseHexDigits[Int(value & 0x0f)])
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// The reachable model fields are value snapshots (including COW arrays and
/// strings), with no engine or UI references. A request never mutates this copy.
struct RemoteDashboardEncodingSnapshot: @unchecked Sendable {
    let value: RemoteDashboard
}

private let dashboardCanonicalDateSuffix = Data(#","updatedAt":"1970-01-01T00:00:00Z"}"#.utf8)
private let dashboardObservationDateMember = Data(#","updatedAt":"#.utf8)

/// Retained only by an active encoding and its interested HTTP requests.
/// The primary body is complete before publication. Ordinary results contain
/// no session projection or engine reference.
struct RemoteDashboardEncodedContent: Sendable {
    fileprivate let body: Data
    fileprivate let observedAt: Date
    fileprivate let dateSuffixCount: Int?
    let entityTag: String
    fileprivate let fallback: RemoteDashboardEncodingSnapshot?
    fileprivate func response(ifNoneMatch: String?, observedAt: Date, encoder: JSONEncoder) throws -> RemoteHTTPResponse {
        var response: RemoteHTTPResponse
        if RemoteDashboard.matches(ifNoneMatch, entityTag: entityTag) {
            response = RemoteHTTPResponse(status: 304, body: Data())
        } else if observedAt == self.observedAt {
            response = RemoteHTTPResponse(body: body)
        } else if let dateSuffixCount {
            var body = body
            body.removeLast(dateSuffixCount)
            body.append(dashboardObservationDateMember)
            body.append(try encoder.encode(observedAt)); body.append(125)
            response = RemoteHTTPResponse(body: body)
        } else if let fallback {
            var value = fallback.value; value.updatedAt = observedAt
            response = try .json(value)
        } else { throw RemoteHTTPError(500, "목록의 관찰 시각을 구성하지 못했습니다.") }
        response.entityTag = entityTag; response.observedAt = observedAt
        return response
    }
}

final class RemoteDashboardEncodingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { if isCancelled() { throw CancellationError() } }
    func whileActive(_ operation: () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        operation()
    }
}

/// A completed body belongs only to the active HTTP leases. The worker resumes
/// their continuations directly, without an intermediate producer Task/hop.
final class RemoteDashboardEncodingPromise: @unchecked Sendable {
    private struct Waiter {
        let cancellation: RemoteDashboardEncodingCancellation
        var continuation: CheckedContinuation<RemoteDashboardEncodedContent, Error>?
    }
    private let lock = NSLock()
    private var result: Result<RemoteDashboardEncodedContent, Error>?
    private var waiters: [UUID: Waiter] = [:]

    @discardableResult func reserve(_ id: UUID, cancellation: RemoteDashboardEncodingCancellation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if case .failure? = result { return false }
        if result == nil { waiters[id] = Waiter(cancellation: cancellation) }
        return true
    }
    func subscribe(_ id: UUID, cancellation: RemoteDashboardEncodingCancellation,
                   continuation: CheckedContinuation<RemoteDashboardEncodedContent, Error>) {
        lock.lock()
        if cancellation.isCancelled() { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        if let result { lock.unlock(); continuation.resume(with: result); return }
        guard var waiter = waiters[id] else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        waiter.continuation = continuation; waiters[id] = waiter
        lock.unlock()
    }
    func finish(_ result: Result<RemoteDashboardEncodedContent, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let pending = waiters; waiters.removeAll()
        lock.unlock()
        for waiter in pending.values {
            guard let continuation = waiter.continuation else { continue }
            if waiter.cancellation.isCancelled() { continuation.resume(throwing: CancellationError()) }
            else { continuation.resume(with: result) }
        }
    }
    func cancel(_ id: UUID) {
        lock.lock(); let waiter = waiters.removeValue(forKey: id); lock.unlock()
        waiter?.continuation?.resume(throwing: CancellationError())
    }
    func release(_ id: UUID) {
        lock.lock(); waiters.removeValue(forKey: id); lock.unlock()
    }
    func checkInterest() throws {
        lock.lock()
        if waiters.values.contains(where: { !$0.cancellation.isCancelled() }) { lock.unlock(); return }
        // Commit abandonment under the admission lock. A caller arriving now
        // must start fresh rather than join work already rejected by the worker.
        if result == nil { result = .failure(CancellationError()) }
        let pending = waiters; waiters.removeAll(); lock.unlock()
        for waiter in pending.values { waiter.continuation?.resume(throwing: CancellationError()) }
        throw CancellationError()
    }
}

@MainActor enum RemoteDashboardObservationEncoder {
    private static let encoder = RemoteDashboard.responseEncoder()
    static func response(_ content: RemoteDashboardEncodedContent, ifNoneMatch: String?, observedAt: Date) throws -> RemoteHTTPResponse {
        try content.response(ifNoneMatch: ifNoneMatch, observedAt: observedAt, encoder: encoder)
    }
}

/// The encoder is touched on this serial queue only. Request cancellation has
/// its own small lock; no lock spans serialization or waits for a worker.
final class RemoteDashboardResponseEncoder: @unchecked Sendable {
    static let shared = RemoteDashboardResponseEncoder()
    private let queue = DispatchQueue(label: "autoapprove.dashboard.encoding", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let encoder = RemoteDashboard.responseEncoder()

    func enqueue(_ snapshot: RemoteDashboardEncodingSnapshot, cancellation: RemoteDashboardEncodingCancellation,
                 promise: RemoteDashboardEncodingPromise) {
        queue.async { [self] in
            let result = Result { () throws -> RemoteDashboardEncodedContent in
                try cancellation.check()
                try promise.checkInterest()
                let content = try autoreleasepool { try snapshot.value.encodedContent(encoder: encoder) }
                try cancellation.check()
                try promise.checkInterest()
                return content
            }
            promise.finish(result)
        }
    }
}

extension RemoteDashboard {
    fileprivate static func responseEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
    static func matches(_ ifNoneMatch: String?, entityTag: String) -> Bool {
        ifNoneMatch?.split(separator: ",").contains { candidate in
            let value = candidate.trimmingCharacters(in: .whitespaces)
            return value == "*" || value == entityTag || value == String(entityTag.dropFirst(2))
        } ?? false
    }

    /// Revalidate a newly read inventory, never a time-based server cache. Only
    /// the response's observation time is excluded; every session/control,
    /// peer failure, release and gateway identity participates in the validator.
    public func response(ifNoneMatch: String?) throws -> RemoteHTTPResponse {
        let encoder = Self.responseEncoder()
        return try encodedContent(encoder: encoder).response(ifNoneMatch: ifNoneMatch, observedAt: updatedAt, encoder: encoder)
    }
    fileprivate func encodedContent(encoder: JSONEncoder) throws -> RemoteDashboardEncodedContent {
        var comparable = self
        comparable.updatedAt = Date(timeIntervalSince1970: 0)
        var encoded = try encoder.encode(comparable)
        let digest = responseDigest(encoded)
        // updatedAt changes independently of content: use a weak validator.
        let tag = "W/\"\(digest)\""
        if encoded.suffix(dashboardCanonicalDateSuffix.count) == dashboardCanonicalDateSuffix {
            // Patch while this local still uniquely owns the buffer. The first
            // HTTP consumer can return it directly, without a body-sized COW
            // copy or a date encoder call on the service actor.
            let date = try encoder.encode(updatedAt)
            encoded.removeLast(dashboardCanonicalDateSuffix.count)
            encoded.append(dashboardObservationDateMember)
            encoded.append(date); encoded.append(125)
            return RemoteDashboardEncodedContent(body: encoded, observedAt: updatedAt,
                dateSuffixCount: dashboardObservationDateMember.count + date.count + 1, entityTag: tag, fallback: nil)
        }
        // An unexpected schema/encoder layout keeps the full-JSON path.
        return RemoteDashboardEncodedContent(body: try encoder.encode(self), observedAt: updatedAt,
            dateSuffixCount: nil, entityTag: tag, fallback: RemoteDashboardEncodingSnapshot(value: self))
    }
}

extension RemoteNodeState {
    public func response(ifNoneMatch: String?) throws -> RemoteHTTPResponse {
        try encodedInventory().validatingInventory(ifNoneMatch:ifNoneMatch,acceptsGzip:false)
    }
    /// Select the actual representation before assigning its strong validator.
    /// Compression and hashing run away from the engine/UI actor; only the
    /// already-encoded, immutable response crosses the task boundary.
    public func response(ifNoneMatch: String?, acceptsGzip: Bool) async throws -> RemoteHTTPResponse {
        try Task.checkCancellation()
        let encoded = try encodedInventory()
        let work = Task.detached(priority:.userInitiated) {
            try Task.checkCancellation()
            let response = encoded.validatingInventory(ifNoneMatch:ifNoneMatch,acceptsGzip:acceptsGzip)
            try Task.checkCancellation()
            return response
        }
        return try await withTaskCancellationHandler {
            let response = try await work.value
            try Task.checkCancellation()
            return response
        } onCancel: { work.cancel() }
    }
    private func encodedInventory() throws -> RemoteHTTPResponse {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var response = RemoteHTTPResponse(body:try encoder.encode(self))
        response.nodeID = id
        return response
    }
}

extension RemoteHTTPResponse {
    fileprivate func validatingInventory(ifNoneMatch: String?, acceptsGzip: Bool) -> Self {
        var response = preparingTransfer(method:"GET",acceptsGzip:acceptsGzip)
        // Identity and gzip have distinct strong ETags. Hash the selected wire
        // bytes, so a change of encoding cannot produce an incorrect 304.
        let digest = responseDigest(response.body)
        let tag = "\"\(digest)\""
        let matches = ifNoneMatch?.split(separator:",").contains {
            let value = $0.trimmingCharacters(in:.whitespaces)
            return value == "*" || value == tag || value == "W/"+tag
        } ?? false
        response.entityTag = tag
        if matches {
            response.status = 304; response.body = Data(); response.contentEncoding = nil
        }
        return response
    }
}
