import Foundation
import CryptoKit

extension RemoteDashboard {
    /// Revalidate a newly read inventory, never a time-based server cache. Only
    /// the response's observation time is excluded; every session/control,
    /// peer failure, release and gateway identity participates in the validator.
    public func response(ifNoneMatch: String?) throws -> RemoteHTTPResponse {
        var comparable = self
        comparable.updatedAt = Date(timeIntervalSince1970: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(comparable))
            .map { String(format: "%02x", $0) }.joined()
        // updatedAt changes independently of content: use a weak validator.
        let tag = "W/\"\(digest)\""
        let matches = ifNoneMatch?.split(separator: ",").contains { candidate in
            let value = candidate.trimmingCharacters(in: .whitespaces)
            return value == "*" || value == tag || value == String(tag.dropFirst(2))
        } ?? false
        var response: RemoteHTTPResponse
        if matches { response = RemoteHTTPResponse(status: 304, body: Data()) }
        else { response = try .json(self) }
        response.entityTag = tag
        response.observedAt = updatedAt
        return response
    }
}
