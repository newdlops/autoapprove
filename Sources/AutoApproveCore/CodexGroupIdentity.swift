import Foundation

public enum CodexGroupIdentity {
    private static func agreedUUID(_ fields: [Any?]) throws -> UUID? {
        let values = fields.compactMap { $0 }
        guard !values.isEmpty else { return nil }
        let ids = values.compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) }
        guard ids.count == values.count, Set(ids).count == 1 else {
            throw AppError.message("Codex 호출의 대화 식별 정보가 서로 다릅니다. MCP 연결을 다시 확인해주세요.")
        }
        return ids.first
    }

    public static func conversationID(in message: JSONObject, environment: [String: String] = [:]) throws -> String? {
        let meta = (message["params"] as? JSONObject)?["_meta"] as? JSONObject ?? [:]
        let turn = turnMetadata(message)
        if isSubagentCall(message) {
            guard let id = try agreedUUID([meta["threadId"], turn["thread_id"]]) else {
                throw AppError.message("Codex 서브에이전트의 호출 대화 ID를 확인하지 못했습니다.")
            }
            return id.uuidString.lowercased()
        }
        let id = try agreedUUID([meta["threadId"], turn["thread_id"], turn["session_id"]])
        return (id ?? environment["CODEX_THREAD_ID"].flatMap(UUID.init(uuidString:)))?.uuidString.lowercased()
    }

    static func subagentParents(in message: JSONObject) throws -> (session: UUID?, parent: UUID?) {
        let meta = (message["params"] as? JSONObject)?["_meta"] as? JSONObject ?? [:]
        let turn = turnMetadata(message)
        return (try agreedUUID([meta["sessionId"], turn["session_id"]]), try agreedUUID([turn["parent_thread_id"]]))
    }

    public static func home(environment: [String: String]?) -> String? {
        guard let environment else { return nil }
        let path = environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func turnMetadata(_ message: JSONObject) -> JSONObject {
        let params = message["params"] as? JSONObject
        let meta = params?["_meta"] as? JSONObject
        return meta?["x-codex-turn-metadata"] as? JSONObject ?? [:]
    }

    static func isSubagentCall(_ message: JSONObject) -> Bool {
        let turn = turnMetadata(message)
        return turn["parent_thread_id"] is String || turn["subagent_kind"] is String || turn["thread_source"] as? String == "subagent"
    }

    package static func allowsTerminalAttribution(_ message: JSONObject) -> Bool {
        let turn = turnMetadata(message)
        return !isSubagentCall(message) && ["parent_thread_id", "subagent_kind"].allSatisfy { turn[$0] == nil || turn[$0] is NSNull } &&
            (turn["thread_source"] == nil || turn["thread_source"] is NSNull || turn["thread_source"] as? String == "user")
    }

    public static func refreshed(_ groups: [SessionGroup], live: [SessionGroupLiveSession]) -> [SessionGroup] {
        groups.map { saved in
            let group = SessionGroupMatching.followingTerminals(saved, live: live, agents: [.codex])
            var result = group
            for index in group.members.indices {
                let member = group.members[index]
                guard member.agent == .codex else { continue }
                if let endpoint = live.first(where: { $0.id == member.runtimeID && $0.session.agent == .codex && $0.session.cwd == member.cwd }),
                   let shell = endpoint.tabShell,
                   SessionGroupMatching.permitsIdentityRefresh(member, candidate: endpoint, conversation: endpoint.conversationID.flatMap(UUID.init(uuidString:)), live: live) {
                    result.members[index].tabShell = shell
                }
                let candidates = live.filter {
                    $0.session.agent == .codex && $0.session.phase != .ended &&
                    $0.conversationID.flatMap(UUID.init(uuidString:)) != nil && $0.providerHome != nil &&
                    (member.providerHome == nil || member.providerHome == $0.providerHome) &&
                    ((member.runtimeID == $0.id && $0.session.cwd == member.cwd) || (!member.conversationID.isEmpty &&
                        UUID(uuidString: member.conversationID) == $0.conversationID.flatMap(UUID.init(uuidString:))))
                }
                guard candidates.count == 1, let current = candidates.first,
                      let uuid = current.conversationID.flatMap(UUID.init(uuidString:)),
                      SessionGroupMatching.permitsIdentityRefresh(member, candidate: current, conversation: uuid, live: live),
                      live.filter({ $0.session.agent == .codex && $0.providerHome == current.providerHome &&
                          $0.conversationID.flatMap(UUID.init(uuidString:)) == uuid }).count == 1,
                      !group.members.contains(where: { $0.id != member.id && $0.agent == .codex &&
                          ($0.runtimeID == current.id || ($0.providerHome == current.providerHome && UUID(uuidString: $0.conversationID) == uuid)) }) else { continue }
                result.members[index].conversationID = uuid.uuidString.lowercased()
                result.members[index].providerHome = current.providerHome
                if current.tabShell != nil || member.runtimeID != current.id { result.members[index].tabShell = current.tabShell }
                result.members[index].cwd = current.session.cwd
                result.members[index].runtimeID = current.id
            }
            return result
        }
    }
}
