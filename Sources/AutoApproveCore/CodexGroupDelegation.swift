import CSQLite
import Foundation

enum CodexGroupDelegation {
    static let source = "codex_subagent_metadata"
    static let memberTools: Set<String> = [
        "get_session_groups", "get_group_status", "get_group_messages", "ack_group_messages",
        "send_group_message", "ask_group_question", "reply_group_question", "wait_group_dependencies", "update_group_wait"
    ]
    static let tools = memberTools.union([
        "get_group_topology", "get_group_member_terminal", "get_group_member_goal", "watch_group_events",
        "explain_group_delivery", "list_group_background_jobs", "get_group_clear_status", "assign_group_task", "assign_group_tasks"
    ])

    struct Caller: Equatable {
        let threadID: UUID
        let requiresLeader: Bool
    }

    struct Ancestry {
        let root: UUID
        let parent: UUID

        func matches(_ object: JSONObject, child: UUID) -> Bool {
            if let claim = object["codexCallerSessionID"] {
                guard let id = (claim as? String).flatMap(UUID.init(uuidString:)), id == root || id == parent || id == child else { return false }
            }
            if let claim = object["codexCallerParentID"] {
                return (claim as? String).flatMap(UUID.init(uuidString:)) == parent
            }
            return true
        }
    }

    enum Lineage {
        case independent
        case child(Ancestry?)
    }

    static func lineage(of child: UUID, home: String) async -> Lineage {
        await Task.detached(priority: .utility) { read(child, home: home) }.value
    }

    private static func read(_ child: UUID, home: String) -> Lineage {
        let database = URL(fileURLWithPath: home).appendingPathComponent("state_5.sqlite").path
        guard let db = try? CodexHistoryAccess.open(database, subject: "서브에이전트 연결") else { return .independent }
        defer { sqlite3_close_v2(db) }
        let sql = """
        WITH RECURSIVE ancestors(id, depth) AS (
            SELECT ?1, 0
            UNION ALL
            SELECT edge.parent_thread_id, a.depth + 1
            FROM ancestors a
            JOIN threads t ON t.id = a.id
            JOIN thread_spawn_edges edge ON edge.child_thread_id = t.id
            WHERE a.depth < 64 AND t.archived = 0 AND t.thread_source = 'subagent'
              AND edge.status = 'open' AND edge.parent_thread_id =
                  CASE WHEN json_valid(t.source) THEN json_extract(t.source, '$.subagent.thread_spawn.parent_thread_id') END
        )
        SELECT (
            SELECT a.id FROM ancestors a JOIN threads t ON t.id = a.id
            WHERE a.depth > 0 AND t.archived = 0
              AND (t.thread_source = 'user' OR (t.thread_source IS NULL AND t.source IN
                  ('cli', 'vscode', '{"custom":"atlas"}', '{"custom":"chatgpt"}')))
              AND NOT EXISTS (SELECT 1 FROM thread_spawn_edges WHERE child_thread_id = t.id)
        ), (SELECT id FROM ancestors WHERE depth = 1)
        WHERE EXISTS (SELECT 1 FROM threads WHERE id = ?1 AND thread_source = 'subagent')
           OR EXISTS (SELECT 1 FROM thread_spawn_edges WHERE child_thread_id = ?1)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return .independent }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, child.uuidString.lowercased(), -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return .independent }
        guard let root = sqlite3_column_text(statement, 0).flatMap({ UUID(uuidString: String(cString: $0)) }),
              let parent = sqlite3_column_text(statement, 1).flatMap({ UUID(uuidString: String(cString: $0)) }) else { return .child(nil) }
        return .child(Ancestry(root: root, parent: parent))
    }

    static func request(_ object: JSONObject) async throws -> JSONObject {
        guard let origin = object["codexCallerSource"] as? String,
              origin == source || origin == "codex_mcp_metadata" else { return object }
        guard object["agentKind"] as? String == "codex", let child = (object["codexCallerConversationID"] as? String).flatMap(UUID.init(uuidString:)),
              let home = object["codexCallerHome"] as? String, home.hasPrefix("/"),
              !home.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            if origin == source { throw RemoteHTTPError(403, "서브에이전트의 호출 대화와 Codex 계정을 확인해주세요.") }
            return object
        }
        switch await lineage(of: child, home: home) {
        case .independent where origin != source: return object
        case .child(let ancestry?) where ancestry.matches(object, child: child):
            guard let tool = object["tool"] as? String, tools.contains(tool) else {
                throw RemoteHTTPError(403, "이 작업은 해당 권한을 가진 구성원 본인의 MCP 연결에서 실행해주세요.")
            }
            var request = object
            request["codexCallerSource"] = source
            request.removeValue(forKey: "codexCallerRuntimeID")
            return request
        default:
            throw RemoteHTTPError(403, "Codex에서 서브에이전트와 원래 구성원의 활성 대화 연결을 확인하지 못했습니다.")
        }
    }
}
