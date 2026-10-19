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
    var finalAgentItemID: String?
    var finalItemUpdatedAt: Int64?
    public init(threadID: String, turnID: String? = nil, status: String? = nil, completedAt: Date? = nil, summary: String? = nil) {
        self.threadID = threadID; self.turnID = turnID; self.status = status
        self.completedAt = completedAt; self.summary = summary; finalAgentItemID = nil; finalItemUpdatedAt = nil
    }
}

/// Per-session prepared statements for the completion poll. The containing
/// reader serializes access and the database cache owns the connection lifetime.
final class CodexTurnStatementCache {
    private var database: OpaquePointer?
    private var turnStatement: OpaquePointer?
    private var itemStatement: OpaquePointer?
#if DEBUG
    private(set) var debugPrepareCount = 0
#endif

    deinit { clear() }

    private func clear() {
        if let turnStatement { sqlite3_finalize(turnStatement) }
        if let itemStatement { sqlite3_finalize(itemStatement) }
        turnStatement = nil; itemStatement = nil; database = nil
    }

    func invalidate() { clear() }

    /// Release old statements before exposing either slot as `inout`. Clearing
    /// the cache from inside `prepare(_:slot:)` overlaps exclusive access to
    /// that stored property and traps with Swift's runtime exclusivity checks.
    private func prepareDatabase(_ db: OpaquePointer) {
        guard database != db else { return }
        clear()
        database = db
    }

    private func prepare(_ sql: String, slot: inout OpaquePointer?, db: OpaquePointer,
                         location: CodexThreadLocation) throws -> OpaquePointer {
        if slot == nil {
            var value: OpaquePointer?
            let result = sqlite3_prepare_v2(db, sql, -1, &value, nil)
            guard result == SQLITE_OK, let value else {
                throw CodexHistoryAccess.failure(db, subject: "작업 완료", result: result)
            }
            slot = value
#if DEBUG
            debugPrepareCount += 1
#endif
        } else if let value = slot {
            sqlite3_reset(value); sqlite3_clear_bindings(value)
        }
        guard let value = slot else { throw CodexHistoryReadError(.invalidData, subject: "작업 완료") }
        sqlite3_bind_text(value, 1, location.threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return value
    }

    func turn(db: OpaquePointer, location: CodexThreadLocation) throws -> OpaquePointer {
        prepareDatabase(db)
        return try prepare(CodexTurnReader.turnSQL, slot: &turnStatement, db: db, location: location)
    }

    func item(db: OpaquePointer, location: CodexThreadLocation, turnID: String,
              itemID: String) throws -> OpaquePointer {
        prepareDatabase(db)
        let statement = try prepare(CodexTurnReader.itemSQL, slot: &itemStatement, db: db, location: location)
        sqlite3_bind_text(statement, 2, turnID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 3, itemID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return statement
    }
}

public enum CodexTurnReader {
    static let turnSQL = """
        SELECT t.turn_id, t.status, t.completed_at, t.final_agent_item_id, i.updated_at_ordinal
        FROM thread_turns t LEFT JOIN thread_items i
          ON i.thread_id = t.thread_id AND i.turn_id = t.turn_id AND i.item_id = t.final_agent_item_id
        WHERE t.thread_id = ? ORDER BY t.rollout_ordinal DESC LIMIT 1
        """
    static let itemSQL = "SELECT item_json FROM thread_items WHERE thread_id = ? AND turn_id = ? AND item_id = ? LIMIT 1"

    public static func read(_ location: CodexThreadLocation) throws -> CodexTurnState {
        let db = try CodexHistoryAccess.open(location.database, subject: "작업 완료")
        defer { sqlite3_close_v2(db) }
        return try read(location, database: db)
    }

    static func read(_ location: CodexThreadLocation, database db: OpaquePointer, previous: CodexTurnState? = nil,
                     statements: CodexTurnStatementCache? = nil) throws -> CodexTurnState {
        let statement: OpaquePointer
        if let statements { statement = try statements.turn(db: db, location: location) }
        else {
            var prepared: OpaquePointer?
            let result = sqlite3_prepare_v2(db, turnSQL, -1, &prepared, nil)
            guard result == SQLITE_OK, let prepared else { throw CodexHistoryAccess.failure(db, subject: "작업 완료", result: result) }
            statement = prepared
            sqlite3_bind_text(statement, 1, location.threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        defer {
            sqlite3_reset(statement)
            if statements == nil { sqlite3_finalize(statement) }
        }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return CodexTurnState(threadID: location.threadID) }
        guard result == SQLITE_ROW else { throw CodexHistoryAccess.failure(db, subject: "작업 완료", result: result) }
        guard let rawID = sqlite3_column_text(statement, 0), let rawStatus = sqlite3_column_text(statement, 1) else {
            throw CodexHistoryReadError(.invalidData, subject: "작업 완료")
        }
        let turnID = String(cString: rawID), status = String(cString: rawStatus)
        let completedAt = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        let finalItemID = sqlite3_column_text(statement, 3).map { String(cString: $0) }
        let finalItemUpdatedAt = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 4)
        if let previous, previous.threadID == location.threadID, previous.turnID == turnID,
           previous.status == status, previous.completedAt == completedAt, previous.finalAgentItemID == finalItemID,
           previous.finalItemUpdatedAt == finalItemUpdatedAt {
            return previous
        }
        sqlite3_reset(statement)
        var summary: String?
        if let finalItemID {
            let itemStatement: OpaquePointer
            if let statements { itemStatement = try statements.item(db: db, location: location, turnID: turnID, itemID: finalItemID) }
            else {
                var prepared: OpaquePointer?
                let result = sqlite3_prepare_v2(db, itemSQL, -1, &prepared, nil)
                guard result == SQLITE_OK, let prepared else { throw CodexHistoryAccess.failure(db, subject: "작업 완료", result: result) }
                itemStatement = prepared
                sqlite3_bind_text(itemStatement, 1, location.threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(itemStatement, 2, turnID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(itemStatement, 3, finalItemID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            defer {
                sqlite3_reset(itemStatement)
                if statements == nil { sqlite3_finalize(itemStatement) }
            }
            let itemResult = sqlite3_step(itemStatement)
            guard itemResult == SQLITE_ROW || itemResult == SQLITE_DONE else {
                throw CodexHistoryAccess.failure(db, subject: "작업 완료", result: itemResult)
            }
            if itemResult == SQLITE_ROW, let rawJSON = sqlite3_column_text(itemStatement, 0) {
                let item: JSONObject? = autoreleasepool {
                    let data = Data(bytes: rawJSON, count: Int(sqlite3_column_bytes(itemStatement, 0)))
                    return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
                }
                if item?["type"] as? String == "agentMessage" { summary = item?["text"] as? String }
            }
        }
        var state = CodexTurnState(threadID: location.threadID, turnID: turnID, status: status,
            completedAt: completedAt, summary: summary)
        state.finalAgentItemID = finalItemID
        state.finalItemUpdatedAt = finalItemUpdatedAt
        return state
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
