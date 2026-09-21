import Foundation
import CSQLite

public struct WorkCompletion: Codable, Equatable {
    public var id: String
    public var date: Date
    public var summary: String
    public init(id: String, date: Date = Date(), summary: String? = nil) {
        self.id = id; self.date = date
        let text = summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.summary = text.isEmpty ? "최종 응답을 마쳤습니다. 터미널에서 결과를 확인하세요." : String(text.prefix(600))
    }
}

/// The latest root turn, including an empty history. Only a transition observed
/// after the initial baseline may produce a completion notification.
public struct CodexTurnState: Equatable {
    public var threadID: String
    public var turnID: String?
    public var status: String?
    public var completedAt: Date?
    public var summary: String?
    public init(threadID: String, turnID: String? = nil, status: String? = nil, completedAt: Date? = nil, summary: String? = nil) {
        self.threadID = threadID; self.turnID = turnID; self.status = status
        self.completedAt = completedAt; self.summary = summary
    }
}

public enum CodexTurnReader {
    public static func read(_ location: CodexThreadLocation) throws -> CodexTurnState {
        let db = try CodexHistoryAccess.open(location.database, subject: "작업 완료")
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = """
            SELECT t.turn_id, t.status, t.completed_at, i.item_json
            FROM thread_turns t LEFT JOIN thread_items i
              ON i.thread_id = t.thread_id AND i.turn_id = t.turn_id AND i.item_id = t.final_agent_item_id
            WHERE t.thread_id = ? ORDER BY t.rollout_ordinal DESC LIMIT 1
            """
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else { throw CodexHistoryAccess.failure(db, subject: "작업 완료", result: prepared) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, location.threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return CodexTurnState(threadID: location.threadID) }
        guard result == SQLITE_ROW else { throw CodexHistoryAccess.failure(db, subject: "작업 완료", result: result) }
        guard let rawID = sqlite3_column_text(statement, 0), let rawStatus = sqlite3_column_text(statement, 1) else {
            throw CodexHistoryReadError(.invalidData, subject: "작업 완료")
        }
        var summary: String?
        if let rawJSON = sqlite3_column_text(statement, 3),
           let item = try? JSONSerialization.jsonObject(with: Data(String(cString: rawJSON).utf8)) as? JSONObject,
           item["type"] as? String == "agentMessage" {
            summary = item["text"] as? String
        }
        return CodexTurnState(threadID: location.threadID, turnID: String(cString: rawID), status: String(cString: rawStatus),
            completedAt: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), summary: summary)
    }
}

public struct CodexCompletionTracker {
    private var previous: [String: CodexTurnState] = [:]
    private let startedAt: Date
    public init(at date: Date = Date()) { startedAt = date }

    public mutating func observe(_ state: CodexTurnState, sessionID: String, at now: Date = Date()) -> WorkCompletion? {
        let last = previous.updateValue(state, forKey: sessionID)
        guard let last, last.threadID == state.threadID, let turnID = state.turnID,
              state.status == "completed", let completed = state.completedAt,
              completed >= startedAt.addingTimeInterval(-1), completed <= now.addingTimeInterval(5),
              last.turnID != turnID || last.status != "completed" else { return nil }
        return WorkCompletion(id: "codex:\(state.threadID):\(turnID)", date: completed, summary: state.summary)
    }

    public mutating func retain(sessionIDs: Set<String>) {
        previous = previous.filter { sessionIDs.contains($0.key) }
    }
}
