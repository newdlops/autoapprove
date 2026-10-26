import Foundation
import Darwin
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
        let hint = 128 + comparable.nodes.reduce(0) { $0 + ($1.state?.sessions.count ?? 0) * 40 }
        var encoded = try responseCanonicalJSON(comparable, using:encoder, reserveHint:hint)
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
        var response = RemoteHTTPResponse(body:try responseCanonicalJSON(self, using:encoder, reserveHint:128 + sessions.count * 40))
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


// Foundation has legacy framework modes with different object-key ordering.
// Probe the actual formatter rather than assuming a particular macOS or SDK.
private func responseJSONCompatible(_ reference: JSONEncoder) -> Bool {
    guard reference.outputFormatting == [.sortedKeys, .withoutEscapingSlashes] else { return false }
    let codes = Array(0..<32) + [34, 47, 92, 0x2028, 0x2029]
    var controls = codes.map { String(UnicodeScalar($0)!) }.joined()
    controls += "한글🙂"
    let decomposed = "e" + String(UnicodeScalar(0x301)!)
    let probes = [
        ["a2":"two", "a11":"eleven", "A":"upper", "a":"lower", "text":controls],
        [decomposed:"decomposed", "z":"last"],
        ["é":"composed", "z":"last"]
    ]
    do {
        for probe in probes {
            if try reference.encode(probe) != TransientJSONEncoding.encode(probe, using:reference) { return false }
        }
        return true
    } catch { return false }
}
private let responseJSONFastCompatible: Bool = {
    let reference = JSONEncoder(); reference.dateEncodingStrategy = .iso8601
    reference.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return responseJSONCompatible(reference)
}()
private func responseCanonicalJSON<T: Encodable>(_ value: T, using reference: JSONEncoder,
                                                 reserveHint: Int, compatible: Bool = responseJSONFastCompatible) throws -> Data {
    if compatible { return try TransientJSONEncoding.encode(value, using:reference, reserveHint:reserveHint) }
    return try reference.encode(value)
}


// Intended only for pure response value snapshots. An unsupported attempt is
// released before Foundation revisits the value. No state survives one encode.
enum TransientJSONEncoding {
    private enum RetryFoundation: Error { case required }
    private static let nodeLimit = 25_000, byteLimit = 4_000_000, depthLimit = 128

    static func encode<T: Encodable>(_ value: T, using reference: JSONEncoder, reserveHint: Int = 64) throws -> Data {
        guard reference.outputFormatting == [.sortedKeys, .withoutEscapingSlashes], reference.userInfo.isEmpty else { return try reference.encode(value) }
        switch reference.dateEncodingStrategy { case .iso8601: break; default: return try reference.encode(value) }
        switch reference.dataEncodingStrategy { case .base64: break; default: return try reference.encode(value) }
        switch reference.keyEncodingStrategy { case .useDefaultKeys: break; default: return try reference.encode(value) }
        switch reference.nonConformingFloatEncodingStrategy { case .throw: break; default: return try reference.encode(value) }
        do { return try attempt(value, reference: reference, reserveHint: reserveHint) }
        catch is RetryFoundation { return try reference.encode(value) }
    }
    private static func attempt<T: Encodable>(_ value: T, reference: JSONEncoder, reserveHint: Int) throws -> Data {
        let arena = Arena(reference: reference, reserveHint: reserveHint)
        let root = arena.add()
        let encoder = Cursor(arena: arena, slot: root, parent: nil, key: nil)
        try encoder.put(value)
        if case .empty = arena.values[root] { throw RetryFoundation.required }
        let bytes = try Output(hint: arena.estimate)
        try arena.write(root, to: bytes, depth: 0)
        return bytes.takeData()
    }
    private final class ObjectValues { var fields: [(String, Int)] = []; var seenKeys: Set<String>? }
    private final class ArrayValues { var elements: [Int] = [] }
    private enum Atom {
        case empty, null, bool(Bool), string(String), number(String), raw(Data), object(ObjectValues), array(ArrayValues)
    }
    private struct PathKey: CodingKey {
        private let name: String?
        let intValue: Int?
        var stringValue: String { name ?? "Index \(intValue!)" }
        init(_ value: any CodingKey) { name = value.stringValue; intValue = value.intValue }
        init(stringValue: String) { name = stringValue; intValue = nil }
        // Most value snapshots never inspect codingPath. Keep the index value
        // until its descriptive string is actually requested.
        init(intValue: Int) { name = nil; self.intValue = intValue }
    }
    private final class Arena {
        var values: [Atom] = []
        var estimate = 0
        var unsupported = false
        let reference: JSONEncoder
        init(reference: JSONEncoder, reserveHint: Int) {
            self.reference = reference; values.reserveCapacity(min(nodeLimit, max(16, reserveHint)))
        }
        func add() -> Int {
            guard values.count < nodeLimit else { unsupported = true; return 0 }
            let id = values.count; values.append(.empty)
            return id
        }
        func check() throws { if unsupported || estimate > byteLimit { throw RetryFoundation.required } }
        func set(_ atom: Atom, at id: Int, estimated: Int) throws {
            try check(); values[id] = atom; estimate += estimated; try check()
        }
        func object(_ id: Int) -> ObjectValues {
            if case .object(let value) = values[id] { return value }
            if case .empty = values[id] {} else { unsupported = true }
            let value = ObjectValues(); values[id] = .object(value); estimate += 2; return value
        }
        func array(_ id: Int) -> ArrayValues {
            if case .array(let value) = values[id] { return value }
            if case .empty = values[id] {} else { unsupported = true }
            let value = ArrayValues(); values[id] = .array(value); estimate += 2; return value
        }
        func field(_ id: Int, key: String, reuse: Bool = false) -> Int {
            let object = object(id)
            if reuse, let old = object.fields.first(where: { $0.0 == key }) { return old.1 }
            var storedKey = key
            if !storedKey.isContiguousUTF8 {
                // UTF-8 conversion stays on this local copy. Invalid foreign
                // UTF-16 keeps Foundation's original complete-value path.
                let cocoa = storedKey as NSString
                var index = 0, valid = true
                while index < cocoa.length {
                    let unit = cocoa.character(at: index)
                    if (0xd800...0xdbff).contains(unit) {
                        guard index + 1 < cocoa.length, (0xdc00...0xdfff).contains(cocoa.character(at: index + 1)) else { valid = false; break }
                        index += 2
                    } else if (0xdc00...0xdfff).contains(unit) { valid = false; break }
                    else { index += 1 }
                }
                if valid { storedKey.makeContiguousUTF8() } else { unsupported = true }
            }
            if storedKey.utf8.contains(where: { $0 >= 128 }), object.seenKeys == nil {
                object.seenKeys = Set(object.fields.map { $0.0 })
            }
            if object.seenKeys != nil, !object.seenKeys!.insert(storedKey).inserted { unsupported = true }
            let child = add(); object.fields.append((storedKey, child)); estimate += storedKey.utf8.count + 4; return child
        }
        func element(_ id: Int) -> (Int, Int) {
            let array = array(id), index = array.elements.count, child = add()
            array.elements.append(child); estimate += 1; return (child, index)
        }
        func string(_ value: String, at id: Int) throws {
            if value.isContiguousUTF8 { try set(.string(value), at: id, estimated: value.utf8.count + 2) }
            else { try scalar(value, at: id) }
        }
        func scalar<T: Encodable>(_ value: T, at id: Int) throws {
            let bytes: Data
            do { bytes = try reference.encode(value) } catch { throw RetryFoundation.required }
            try set(.raw(bytes), at: id, estimated: bytes.count)
        }
        func number<T: BinaryInteger>(_ value: T, at id: Int) throws {
            let text = String(value); try set(.number(text), at: id, estimated: text.utf8.count)
        }
        /// Pure scalar values need no child Encoder or coding-path object.
        /// Compound Encodable values still receive their original full path.
        func primitive<T: Encodable>(_ value: T, at id: Int) throws -> Bool {
            if #available(macOS 15.0, *) {
                if T.self == Int128.self { try number(value as! Int128, at: id); return true }
                if T.self == UInt128.self { try number(value as! UInt128, at: id); return true }
            }
            if T.self == String.self { try string(value as! String, at: id) }
            else if T.self == Bool.self { try set(.bool(value as! Bool), at: id, estimated: 5) }
            else if T.self == Int.self { try number(value as! Int, at: id) }
            else if T.self == Int8.self { try number(value as! Int8, at: id) }
            else if T.self == Int16.self { try number(value as! Int16, at: id) }
            else if T.self == Int32.self { try number(value as! Int32, at: id) }
            else if T.self == Int64.self { try number(value as! Int64, at: id) }
            else if T.self == UInt.self { try number(value as! UInt, at: id) }
            else if T.self == UInt8.self { try number(value as! UInt8, at: id) }
            else if T.self == UInt16.self { try number(value as! UInt16, at: id) }
            else if T.self == UInt32.self { try number(value as! UInt32, at: id) }
            else if T.self == UInt64.self { try number(value as! UInt64, at: id) }
            else if T.self == Float.self || T.self == Double.self || T.self == Date.self || T.self == Data.self || T.self == URL.self || T.self == Decimal.self { try scalar(value, at: id) }
            else { return false }
            return true
        }
        func write(_ id: Int, to out: Output, depth: Int) throws {
            try check(); guard depth <= depthLimit else { throw RetryFoundation.required }
            switch values[id] {
            case .empty: try out.literal("{}")
            case .null: try out.literal("null")
            case .bool(let value): try out.literal(value ? "true" : "false")
            case .string(let value): try out.string(value)
            case .number(let value): try out.literal(value)
            case .raw(let data): try data.withUnsafeBytes { try out.append($0) }
            case .array(let box):
                try out.byte(91)
                for (index, child) in box.elements.enumerated() {
                    if index > 0 { try out.byte(44) }
                    try write(child, to: out, depth: depth + 1)
                }
                try out.byte(93)
            case .object(let box):
                box.fields.sort { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
                try out.byte(123)
                for (index, field) in box.fields.enumerated() {
                    if index > 0 {
                        guard box.fields[index - 1].0 != field.0 else { throw RetryFoundation.required }
                        try out.byte(44)
                    }
                    try out.string(field.0); try out.byte(58); try write(field.1, to: out, depth: depth + 1)
                }
                try out.byte(125)
            }
        }
    }
    private final class Output {
        private var pointer: UnsafeMutableRawPointer?
        private var capacity: Int
        private var count = 0
        init(hint: Int) throws {
            capacity = min(byteLimit, max(64, hint + hint / 16))
            pointer = malloc(capacity)
            guard pointer != nil else { throw RetryFoundation.required }
        }
        deinit { free(pointer) }
        private func reserve(_ additional: Int) throws {
            guard additional >= 0, additional <= byteLimit - count else { throw RetryFoundation.required }
            let wanted = count + additional
            if wanted > capacity {
                let next = min(byteLimit, max(wanted, capacity * 2))
                guard let resized = realloc(pointer, next) else { throw RetryFoundation.required }
                pointer = resized; capacity = next
            }
        }
        func byte(_ value: UInt8) throws {
            try reserve(1); pointer!.storeBytes(of: value, toByteOffset: count, as: UInt8.self); count += 1
        }
        func append(_ bytes: UnsafeRawBufferPointer) throws {
            try reserve(bytes.count)
            if !bytes.isEmpty { pointer!.advanced(by: count).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count); count += bytes.count }
        }
        func literal(_ value: String) throws {
            guard let _ = try value.utf8.withContiguousStorageIfAvailable({ try append(UnsafeRawBufferPointer($0)) }) else { throw RetryFoundation.required }
        }
        func string(_ value: String) throws {
            try byte(34)
            guard let _ = try value.utf8.withContiguousStorageIfAvailable({ bytes in
                var start = 0
                for index in bytes.indices {
                    let value = bytes[index]
                    guard value < 32 || value == 34 || value == 92 else { continue }
                    if index > start { try append(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[start..<index])) }
                    switch value {
                    case 8: try literal("\\b")
                    case 9: try literal("\\t")
                    case 10: try literal("\\n")
                    case 12: try literal("\\f")
                    case 13: try literal("\\r")
                    case 34: try literal("\\\"")
                    case 92: try literal("\\\\")
                    default:
                        try literal("\\u00")
                        try byte(value >> 4 < 10 ? 48 + (value >> 4) : 87 + (value >> 4))
                        try byte(value & 15 < 10 ? 48 + (value & 15) : 87 + (value & 15))
                    }
                    start = index + 1
                }
                if start < bytes.count { try append(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[start..<bytes.count])) }
            }) else { throw RetryFoundation.required }
            try byte(34)
        }
        func takeData() -> Data {
            let owned = pointer!; pointer = nil
            return Data(bytesNoCopy: owned, count: count, deallocator: .free)
        }
    }
    private final class Cursor: Encoder {
        let arena: Arena, slot: Int, parent: Cursor?, key: PathKey?
        let depth: Int
        var codingPath: [any CodingKey] { (parent?.codingPath ?? []) + (key.map { [$0 as any CodingKey] } ?? []) }
        var userInfo: [CodingUserInfoKey: Any] { [:] }
        init(arena: Arena, slot: Int, parent: Cursor?, key: PathKey?) {
            self.arena = arena; self.slot = slot; self.parent = parent; self.key = key; depth = (parent?.depth ?? -1) + 1
        }
        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
            _ = arena.object(slot); return KeyedEncodingContainer(Keyed<Key>(cursor: self))
        }
        func unkeyedContainer() -> any UnkeyedEncodingContainer { _ = arena.array(slot); return Unkeyed(cursor: self) }
        func singleValueContainer() -> any SingleValueEncodingContainer { Single(cursor: self) }
        func child(_ id: Int, key: PathKey) -> Cursor { Cursor(arena: arena, slot: id, parent: self, key: key) }
        func put<T: Encodable>(_ value: T) throws {
            try arena.check(); guard depth <= depthLimit else { throw RetryFoundation.required }
            if try arena.primitive(value, at: slot) { return }
            try value.encode(to: self)
        }
        func putChild<T: Encodable, Key: CodingKey>(_ value: T, at id: Int, key: Key) throws {
            try arena.check(); guard depth < depthLimit else { throw RetryFoundation.required }
            if try arena.primitive(value, at: id) { return }
            try value.encode(to: child(id, key: PathKey(key)))
        }
        func putElement<T: Encodable>(_ value: T, at id: Int, index: Int) throws {
            try arena.check(); guard depth < depthLimit else { throw RetryFoundation.required }
            if try arena.primitive(value, at: id) { return }
            try value.encode(to: child(id, key: PathKey(intValue: index)))
        }
        func number<T: BinaryInteger>(_ value: T) throws { try arena.number(value, at: slot) }
        func null() throws { try arena.set(.null, at: slot, estimated: 4) }
    }
    private struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let cursor: Cursor
        var codingPath: [any CodingKey] { cursor.codingPath }
        private func target(_ key: Key, reuse: Bool = false) -> Cursor { cursor.child(cursor.arena.field(cursor.slot, key: key.stringValue, reuse: reuse), key: PathKey(key)) }
        private func put<T: Encodable>(_ value: T, forKey key: Key) throws {
            let id = cursor.arena.field(cursor.slot, key: key.stringValue)
            try cursor.putChild(value, at: id, key: key)
        }
        private func integer<T: BinaryInteger>(_ value: T, forKey key: Key) throws {
            let id = cursor.arena.field(cursor.slot, key: key.stringValue)
            try cursor.arena.number(value, at: id)
        }
        mutating func encodeNil(forKey key: Key) throws {
            let id = cursor.arena.field(cursor.slot, key: key.stringValue)
            try cursor.arena.set(.null, at: id, estimated: 4)
        }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try put(value, forKey: key) }
        mutating func encode(_ value: Bool, forKey key: Key) throws { try put(value, forKey: key) }
        mutating func encode(_ value: String, forKey key: Key) throws { let id = cursor.arena.field(cursor.slot, key: key.stringValue); try cursor.arena.string(value, at: id) }
        mutating func encode(_ value: Double, forKey key: Key) throws { try put(value, forKey: key) }
        mutating func encode(_ value: Float, forKey key: Key) throws { try put(value, forKey: key) }
        mutating func encode(_ value: Int, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: Int8, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: Int16, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: Int32, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: Int64, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: UInt, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: UInt8, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: UInt16, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: UInt32, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func encode(_ value: UInt64, forKey key: Key) throws { try integer(value, forKey: key) }
        mutating func nestedContainer<Nested: CodingKey>(keyedBy type: Nested.Type, forKey key: Key) -> KeyedEncodingContainer<Nested> { target(key, reuse: true).container(keyedBy: type) }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer { target(key, reuse: true).unkeyedContainer() }
        mutating func superEncoder() -> any Encoder {
            let key = PathKey(stringValue: "super"); return cursor.child(cursor.arena.field(cursor.slot, key: key.stringValue, reuse: true), key: key)
        }
        mutating func superEncoder(forKey key: Key) -> any Encoder { target(key, reuse: true) }
    }
    private struct Unkeyed: UnkeyedEncodingContainer {
        let cursor: Cursor
        var codingPath: [any CodingKey] { cursor.codingPath }
        var count: Int { cursor.arena.array(cursor.slot).elements.count }
        private func target() -> Cursor { let (id, index) = cursor.arena.element(cursor.slot); return cursor.child(id, key: PathKey(intValue: index)) }
        private func put<T: Encodable>(_ value: T) throws {
            let (id, index) = cursor.arena.element(cursor.slot)
            try cursor.putElement(value, at: id, index: index)
        }
        private func integer<T: BinaryInteger>(_ value: T) throws {
            let (id, _) = cursor.arena.element(cursor.slot)
            try cursor.arena.number(value, at: id)
        }
        mutating func encodeNil() throws {
            let (id, _) = cursor.arena.element(cursor.slot)
            try cursor.arena.set(.null, at: id, estimated: 4)
        }
        mutating func encode<T: Encodable>(_ value: T) throws { try put(value) }
        mutating func encode(_ value: Bool) throws { try put(value) }
        mutating func encode(_ value: String) throws { let (id, _) = cursor.arena.element(cursor.slot); try cursor.arena.string(value, at: id) }
        mutating func encode(_ value: Double) throws { try put(value) }
        mutating func encode(_ value: Float) throws { try put(value) }
        mutating func encode(_ value: Int) throws { try integer(value) }
        mutating func encode(_ value: Int8) throws { try integer(value) }
        mutating func encode(_ value: Int16) throws { try integer(value) }
        mutating func encode(_ value: Int32) throws { try integer(value) }
        mutating func encode(_ value: Int64) throws { try integer(value) }
        mutating func encode(_ value: UInt) throws { try integer(value) }
        mutating func encode(_ value: UInt8) throws { try integer(value) }
        mutating func encode(_ value: UInt16) throws { try integer(value) }
        mutating func encode(_ value: UInt32) throws { try integer(value) }
        mutating func encode(_ value: UInt64) throws { try integer(value) }
        mutating func nestedContainer<Nested: CodingKey>(keyedBy type: Nested.Type) -> KeyedEncodingContainer<Nested> { target().container(keyedBy: type) }
        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { target().unkeyedContainer() }
        mutating func superEncoder() -> any Encoder { target() }
    }
    private struct Single: SingleValueEncodingContainer {
        let cursor: Cursor
        var codingPath: [any CodingKey] { cursor.codingPath }
        mutating func encodeNil() throws { try cursor.null() }
        mutating func encode<T: Encodable>(_ value: T) throws { try cursor.put(value) }
        mutating func encode(_ value: Bool) throws { try cursor.put(value) }
        mutating func encode(_ value: String) throws { try cursor.arena.string(value, at: cursor.slot) }
        mutating func encode(_ value: Double) throws { try cursor.put(value) }
        mutating func encode(_ value: Float) throws { try cursor.put(value) }
        mutating func encode(_ value: Int) throws { try cursor.number(value) }
        mutating func encode(_ value: Int8) throws { try cursor.number(value) }
        mutating func encode(_ value: Int16) throws { try cursor.number(value) }
        mutating func encode(_ value: Int32) throws { try cursor.number(value) }
        mutating func encode(_ value: Int64) throws { try cursor.number(value) }
        mutating func encode(_ value: UInt) throws { try cursor.number(value) }
        mutating func encode(_ value: UInt8) throws { try cursor.number(value) }
        mutating func encode(_ value: UInt16) throws { try cursor.number(value) }
        mutating func encode(_ value: UInt32) throws { try cursor.number(value) }
        mutating func encode(_ value: UInt64) throws { try cursor.number(value) }
    }
}
