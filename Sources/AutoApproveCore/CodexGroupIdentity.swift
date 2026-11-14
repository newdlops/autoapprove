import Foundation

/// Codex supplies these fields outside the model's tool arguments on every MCP call.
/// Do not use the shared daemon's PID as the identity of an attached terminal.
public enum CodexGroupIdentity {
    public static func conversationID(in message: JSONObject) throws -> String? {
        guard let params = message["params"] as? JSONObject,
              let meta = params["_meta"] as? JSONObject else { return nil }
        let turn = meta["x-codex-turn-metadata"] as? JSONObject ?? [:]
        let values = [meta["threadId"], turn["thread_id"], turn["session_id"]].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        let ids = values.compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) }
        guard ids.count == values.count, Set(ids).count == 1, let id = ids.first else {
            throw AppError.message("Codex 호출의 대화 식별 정보가 서로 다릅니다. MCP 연결을 다시 확인해주세요.")
        }
        return id.uuidString.lowercased()
    }

    public static func home(environment: [String: String]?) -> String? {
        guard let environment else { return nil }
        let path = environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Follow /new and process restarts only with a unique, freshly observed Codex identity.
    /// Claude members are deliberately returned byte-for-byte unchanged.
    public static func refreshed(_ groups: [SessionGroup], live: [SessionGroupLiveSession]) -> [SessionGroup] {
        groups.map { group in
            var result = group
            for index in group.members.indices {
                let member = group.members[index]
                guard member.agent == .codex else { continue }
                let candidates = live.filter {
                    $0.session.agent == .codex && $0.session.phase != .ended && $0.session.cwd == member.cwd &&
                    $0.conversationID.flatMap(UUID.init(uuidString:)) != nil && $0.providerHome != nil &&
                    (member.providerHome == nil || member.providerHome == $0.providerHome) &&
                    (member.runtimeID == $0.id || (!member.conversationID.isEmpty &&
                        UUID(uuidString: member.conversationID) == $0.conversationID.flatMap(UUID.init(uuidString:))))
                }
                guard candidates.count == 1, let current = candidates.first,
                      let uuid = current.conversationID.flatMap(UUID.init(uuidString:)),
                      live.filter({ $0.session.agent == .codex && $0.providerHome == current.providerHome &&
                          $0.conversationID.flatMap(UUID.init(uuidString:)) == uuid }).count == 1,
                      !group.members.contains(where: { $0.id != member.id && $0.agent == .codex &&
                          ($0.runtimeID == current.id || ($0.providerHome == current.providerHome && UUID(uuidString: $0.conversationID) == uuid)) }) else { continue }
                result.members[index].conversationID = uuid.uuidString.lowercased()
                result.members[index].providerHome = current.providerHome
                result.members[index].runtimeID = current.id
            }
            return result
        }
    }
}
