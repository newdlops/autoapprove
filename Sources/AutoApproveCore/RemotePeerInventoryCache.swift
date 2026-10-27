import Foundation
import Network

extension AgentSession {
    /// The web only uses notices for unread system-change warnings. Native
    /// inbox/history and /api/state retain every original notice unchanged.
    var webInventory: Self {
        var value = self
        let warnings = notices?.filter { $0.isSystemSafety == true && !$0.isRead } ?? []
        value.notices = warnings.isEmpty ? nil : warnings
        value.backgroundSessions = backgroundSessions?.map(\.webInventory)
        value.queuedQuestions = queuedQuestions?.map { question in
            var question = question
            question.cleanupToken = question.isPastForCleanup ? question.cleanupIdentity(sessionID:id) : nil
            return question
        }
        return value
    }
}

/// Retained data is never returned on a timeout: only a fresh, identity-pinned
/// 304 can reuse it. Route changes, failures and oversized states force 200.
@MainActor public final class RemotePeerInventoryCache {
    private struct Entry {
        let endpoint: NWEndpoint
        let tag: String
        let state: RemoteNodeState
        let bytes: Int
        var used: Date
    }
    private var entries: [String:Entry] = [:]
    public var count: Int { entries.count }
    public var retainedBytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }
    public init() {}
    private static func validTag(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.range(of: #"^(?:W/)?\"[a-f0-9]{64}\"$"#, options: .regularExpression) != nil
    }
    public func requestTag(for id: String, endpoint: NWEndpoint, at now: Date = Date()) -> String? {
        guard let entry = entries[id], entry.endpoint == endpoint, (0..<300).contains(now.timeIntervalSince(entry.used)) else {
            entries.removeValue(forKey:id); return nil
        }
        return entry.tag
    }
    public func resolve(_ response: RemoteHTTPResponse, requestedTag: String?, id: String, endpoint: NWEndpoint, at now: Date = Date()) throws -> RemoteNodeState {
        if response.status == 304 {
            guard let requestedTag, let entry = entries[id], entry.endpoint == endpoint,
                  entry.tag == requestedTag, response.entityTag == requestedTag, response.nodeID == id,
                  response.body.isEmpty, (0..<300).contains(now.timeIntervalSince(entry.used)) else {
                remove(id)
                throw RemoteHTTPError(502,"Mac의 목록 갱신 응답과 원본 식별을 확인하지 못했습니다. 다시 연결해주세요.",diagnostics:["failureKind":"identity"])
            }
            entries[id]?.used = now
            return entry.state
        }
        guard response.status == 200 else { remove(id); throw RemoteHTTPError(response.status,"Mac의 세션 목록을 확인하지 못했습니다.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let state: RemoteNodeState
        do { state = try decoder.decode(RemoteNodeState.self,from:response.body) }
        catch { remove(id); throw error }
        guard state.id == id, response.nodeID == nil || response.nodeID == id else {
            remove(id); throw RemoteHTTPError(502,"Mac의 연결 정보가 바뀌었습니다. 주소를 다시 추가해주세요.",diagnostics:["failureKind":"identity"])
        }
        remove(id)
        if Self.validTag(response.entityTag), response.body.count <= 1_048_576 {
            while entries.count >= 32 || retainedBytes + response.body.count > 4_194_304 {
                guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key else { break }
                remove(oldest)
            }
            entries[id] = Entry(endpoint:endpoint,tag:response.entityTag!,state:state,bytes:response.body.count,used:now)
        }
        return state
    }
    public func remove(_ id: String) { entries.removeValue(forKey:id) }
    public func removeAll() { entries.removeAll() }
    public func prune(liveIDs: Set<String>, at now: Date = Date()) {
        for (id,entry) in entries where !liveIDs.contains(id) || !(0..<300).contains(now.timeIntervalSince(entry.used)) { remove(id) }
    }
}
