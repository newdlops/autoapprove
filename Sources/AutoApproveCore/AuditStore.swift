import Foundation
import CSQLite

public final class AuditStore {
    private var db: OpaquePointer?
    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw AppError.message("승인 기록 데이터베이스를 열지 못했습니다.") }
        sqlite3_busy_timeout(db, 250)
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, date REAL NOT NULL, json TEXT NOT NULL); CREATE INDEX IF NOT EXISTS events_date ON events(date DESC, id DESC); CREATE TABLE IF NOT EXISTS claude_hooks (id TEXT PRIMARY KEY, logical_id TEXT, expires REAL NOT NULL, json TEXT NOT NULL); CREATE INDEX IF NOT EXISTS claude_hooks_logical ON claude_hooks(logical_id);")
        }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AppError.message("설정 또는 승인 기록 저장에 실패했습니다.") }
    }
    private func bind(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    public func value(_ key: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM settings WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        bind(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }
    public func set(_ key: String, _ value: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO settings VALUES (?, ?)", -1, &statement, nil) == SQLITE_OK else { throw AppError.message("설정을 저장하지 못했습니다.") }
        bind(key, to: statement, at: 1); bind(value, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError.message("설정을 저장하지 못했습니다.") }
    }
    public func setValues(_ values: [String: String]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for (key, value) in values { try set(key, value) }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func append(_ event: AuditEvent) throws {
        let data = try JSONEncoder().encode(event)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT INTO events VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET json=excluded.json", -1, &statement, nil) == SQLITE_OK else { throw AppError.message("승인 내역을 저장하지 못했습니다.") }
        bind(event.id, to: statement, at: 1); sqlite3_bind_double(statement, 2, event.date.timeIntervalSince1970)
        bind(String(decoding: data, as: UTF8.self), to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError.message("승인 내역을 저장하지 못했습니다.") }
    }
    func claudeHook(id: String? = nil, logicalID: String? = nil) throws -> ClaudeHookReceipt? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let column = id != nil ? "id" : "logical_id"
        guard sqlite3_prepare_v2(db, "SELECT json FROM claude_hooks WHERE \(column) = ? ORDER BY expires DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw AppError.message("Claude 응답 기록을 읽지 못했습니다.")
        }
        bind(id ?? logicalID ?? "", to: statement, at: 1)
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw AppError.message("Claude 응답 기록을 읽지 못했습니다.") }
        return try JSONDecoder().decode(ClaudeHookReceipt.self, from: Data(String(cString: value).utf8))
    }
    /// The decision and its audit commit together before either is exposed to the helper.
    func saveClaudeHook(_ receipt: ClaudeHookReceipt) throws {
        let json = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        try execute("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO claude_hooks VALUES (?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { throw AppError.message("Claude 응답을 저장하지 못했습니다.") }
            bind(receipt.id, to: statement, at: 1)
            if let logicalID = receipt.logicalID { bind(logicalID, to: statement, at: 2) } else { sqlite3_bind_null(statement, 2) }
            sqlite3_bind_double(statement, 3, receipt.expiresAt.timeIntervalSince1970)
            bind(json, to: statement, at: 4)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw AppError.message("Claude 응답을 저장하지 못했습니다.") }
            if let audit = receipt.audit { try append(audit) }
            try execute("DELETE FROM claude_hooks WHERE expires < \(Date().addingTimeInterval(-60).timeIntervalSince1970)")
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func recent(limit: Int = 200) -> [AuditEvent] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT json FROM events ORDER BY date DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var events: [AuditEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0), let event = try? JSONDecoder().decode(AuditEvent.self, from: Data(String(cString: text).utf8)) { events.append(event) }
        }
        return events
    }

    public func history(search: String = "", result: AuditResult? = nil, through: Date = Date(), offset: Int = 0, limit: Int = 100) throws -> AuditPage {
        var conditions = ["date <= ?"]
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let fields = ["summary", "request", "answer", "outcome", "source", "tool", "sessionID", "context.cwd", "context.agent", "context.tty", "context.pid"]
            conditions.append("(" + fields.map { "COALESCE(json_extract(json, '$.\($0)'), '') LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")")
        }
        if let result {
            let outcome = "json_extract(json, '$.outcome')"
            switch result {
            case .delivered: conditions.append("\(outcome) IN ('승인 전달', '승인 입력 전달', '질문 응답 전달')")
            case .manual: conditions.append("\(outcome) = '터미널에서 확인'")
            case .queued: conditions.append("\(outcome) = '답변 대기열 등록'")
            case .review: conditions.append("\(outcome) NOT IN ('승인 전달', '승인 입력 전달', '질문 응답 전달', '터미널에서 확인', '답변 대기열 등록')")
            }
        }
        let predicate = conditions.joined(separator: " AND ")
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        func prepare(_ sql: String) throws -> OpaquePointer? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw AppError.message("저장된 승인 내역을 읽지 못했습니다.") }
            sqlite3_bind_double(statement, 1, through.timeIntervalSince1970)
            if !query.isEmpty { for index in 2...11 { bind("%\(escaped)%", to: statement, at: Int32(index)) } }
            return statement
        }
        let count = try prepare("SELECT COUNT(*) FROM events WHERE \(predicate)")
        defer { sqlite3_finalize(count) }
        guard sqlite3_step(count) == SQLITE_ROW else { throw AppError.message("저장된 승인 내역을 읽지 못했습니다.") }
        let total = Int(sqlite3_column_int64(count, 0))
        let statement = try prepare("SELECT json FROM events WHERE \(predicate) ORDER BY date DESC, id DESC LIMIT \(max(1, min(limit, 200))) OFFSET \(max(0, offset))")
        defer { sqlite3_finalize(statement) }
        var events: [AuditEvent] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { throw AppError.message("승인 내역에 읽을 수 없는 데이터가 있습니다.") }
            events.append(try JSONDecoder().decode(AuditEvent.self, from: Data(String(cString: text).utf8)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw AppError.message("저장된 승인 내역을 읽지 못했습니다.") }
        return AuditPage(events: events, total: total)
    }
}
