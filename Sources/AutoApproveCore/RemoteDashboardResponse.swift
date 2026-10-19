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

extension RemoteDashboard {
    static func matches(_ ifNoneMatch: String?, entityTag: String) -> Bool {
        ifNoneMatch?.split(separator: ",").contains { candidate in
            let value = candidate.trimmingCharacters(in: .whitespaces)
            return value == "*" || value == entityTag || value == String(entityTag.dropFirst(2))
        } ?? false
    }

    private static let canonicalDateSuffix = Data(#","updatedAt":"1970-01-01T00:00:00Z"}"#.utf8)
    private static let observationDateMember = Data(#","updatedAt":"#.utf8)
    /// Revalidate a newly read inventory, never a time-based server cache. Only
    /// the response's observation time is excluded; every session/control,
    /// peer failure, release and gateway identity participates in the validator.
    public func response(ifNoneMatch: String?) throws -> RemoteHTTPResponse {
        var comparable = self
        comparable.updatedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var encoded = try encoder.encode(comparable)
        let digest = responseDigest(encoded)
        // updatedAt changes independently of content: use a weak validator.
        let tag = "W/\"\(digest)\""
        let matches = Self.matches(ifNoneMatch,entityTag:tag)
        var response: RemoteHTTPResponse
        if matches { response = RemoteHTTPResponse(status: 304, body: Data()) }
        else if encoded.suffix(Self.canonicalDateSuffix.count) == Self.canonicalDateSuffix {
            // sortedKeys puts this root member last. Reuse the encoded content
            // rather than traverse every node/session a second time. Validate
            // the exact suffix; future schema/encoder changes fall back safely.
            encoded.removeLast(Self.canonicalDateSuffix.count)
            encoded.append(Self.observationDateMember)
            encoded.append(try encoder.encode(updatedAt)); encoded.append(125)
            response = RemoteHTTPResponse(body: encoded)
        } else { response = try .json(self) }
        response.entityTag = tag
        response.observedAt = updatedAt
        return response
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
