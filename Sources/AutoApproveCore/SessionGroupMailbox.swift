import Foundation
import CSQLite
import Darwin

public struct SessionGroupMessage: Equatable {
    public enum Kind: String { case question, reply, message, report, choiceQuestion, waitNotice }
    public var sequence: Int64
    public var id: UUID
    public var groupID: UUID
    public var senderID: UUID
    public var recipientID: UUID
    public var kind: Kind
    public var text: String
    public var createdAt: Date
    public var acknowledgedAt: Date?
    public var attempts: Int
    public var nextAttemptAt: Date
    public var lastResult: String?
    public var lastError: String?
    public var sourceKey: String?
    var containsOriginalReport = false

    static let promptPrefix = "[AutoApprove 그룹 전달 "
    private static let directInputBytes = 4096

    var deliversBody: Bool { [.question, .reply, .message, .waitNotice].contains(kind) || containsOriginalReport }

    func terminalPrompt(senderTitle: String) -> String {
        let heading = Self.promptPrefix + id.uuidString + "] "
        let sender = String(SessionGroupOrchestration.oneLine(senderTitle).prefix(100))
        let context = heading + sender + " · " + kind.rawValue + " · 그룹 메시지 본문 · "
        // Some native terminals can only submit one line. JSON escaping
        // preserves every line boundary without creating another keystroke.
        let body: String
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
           let encoded = try? JSONEncoder().encode(text) {
            body = "JSON 문자열 · " + String(decoding: encoded, as: UTF8.self)
        } else {
            body = text
        }
        if (context + body).utf8.count <= Self.directInputBytes { return context + body }
        return context + referenceText
    }

    private var referenceText: String {
        "원문 " + String(text.utf8.count) + "바이트 · get_group_messages(groupID: " +
            groupID.uuidString + ", messageID: " + id.uuidString + ", includeAcknowledged: true)"
    }

    func isReferencePrompt(_ prompt: String) -> Bool { prompt.hasSuffix(" · 그룹 메시지 본문 · " + referenceText) }

    static func terminalMessageID(_ prompt: String) -> UUID? {
        guard prompt.hasPrefix(promptPrefix),
              let end = prompt.firstIndex(of: "]") else { return nil }
        return UUID(uuidString: String(prompt[prompt.index(prompt.startIndex, offsetBy: promptPrefix.count)..<end]))
    }

    public var json: JSONObject {
        let date = ISO8601DateFormatter()
        var value: JSONObject = ["messageID": id.uuidString, "sequence": sequence, "groupID": groupID.uuidString,
                "senderMemberID": senderID.uuidString, "memberID": recipientID.uuidString, "kind": kind.rawValue,
                "text": text, "createdAt": date.string(from: createdAt),
                "state": acknowledgedAt == nil ? "pending" : "acknowledged",
                "acknowledged": acknowledgedAt != nil,
                "acknowledgedAt": acknowledgedAt.map(date.string(from:)) as Any? ?? NSNull(),
                "notificationAttempts": attempts, "lastNotificationResult": lastResult as Any? ?? NSNull(),
                "lastError": lastError as Any? ?? NSNull()]
        if lastResult == "superseded", acknowledgedAt == nil { value["state"] = "superseded" }
        if let key = sourceKey, key.hasPrefix("answer:") { value["inReplyTo"] = String(key.dropFirst(7)) }
        if kind == .question { value["replyWith"] = ["inReplyTo": id.uuidString] }
        if sourceKey?.hasPrefix("decision:") == true { value["blocksProgress"] = true }
        return value
    }
}

public struct SessionGroupConversation: Identifiable, Equatable {
    public let question: SessionGroupMessage
    public let answer: SessionGroupMessage?
    public let waitExpired: Bool
    public var id: UUID { question.id }
}

public struct SessionGroupConversationPage: Equatable {
    public let conversations: [SessionGroupConversation]
    public let messages: [SessionGroupMessage]
    public let hasMore: Bool
}

/// Durable local inbox. Terminal notifications are hints; only the recipient's ACK completes a message.
/// Receipts retain their IDs, including after acknowledgement, so a repeated request cannot create a second message.
public final class SessionGroupMailbox {
    private var db: OpaquePointer?
    private let maximumPending: Int
    private let columns = "sequence,id,group_id,sender_id,recipient_id,kind,body,created,acknowledged,attempts,next_attempt,last_result,last_error,source_key,EXISTS(SELECT 1 FROM group_original_reports o WHERE o.message_id=messages.id)"

    public init(directory: URL, maximumPending: Int = 1000) throws {
        self.maximumPending = maximumPending
        try AppPaths(directory: directory).prepare()
        // macOS exposes legitimate /var and /tmp aliases. Resolve the parent, while
        // still refusing a symlink at the database itself (including SQLite's open).
        // Foundation canonicalizes /private/var back to /var on macOS; SQLite's
        // NOFOLLOW rejects that alias too. realpath supplies the physical parent.
        guard let parent = realpath(directory.path, nil) else { throw AppError.message("그룹 수신함 폴더를 확인하지 못했습니다.") }
        let path = String(cString: parent) + "/group-messages.sqlite"
        free(parent)
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AppError.message("그룹 수신함 파일을 열지 못했습니다.") }
        var info = stat()
        let valid = fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
        if valid { _ = fchmod(fd, 0o600) }
        close(fd)
        guard valid else { throw AppError.message("그룹 수신함 파일의 소유자와 형식을 확인해주세요.") }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            let reason = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db); db = nil; throw AppError.message("그룹 수신함을 열지 못했습니다: \(reason)")
        }
        do {
            sqlite3_busy_timeout(db, 1000)
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; CREATE TABLE IF NOT EXISTS messages (sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,group_id TEXT NOT NULL,sender_id TEXT NOT NULL,recipient_id TEXT NOT NULL,kind TEXT NOT NULL,body TEXT NOT NULL,created REAL NOT NULL,acknowledged REAL,attempts INTEGER NOT NULL DEFAULT 0,next_attempt REAL NOT NULL DEFAULT 0,last_result TEXT,last_error TEXT,source_key TEXT UNIQUE); CREATE INDEX IF NOT EXISTS message_inbox ON messages(group_id,recipient_id,acknowledged,sequence); CREATE INDEX IF NOT EXISTS message_outbox ON messages(group_id,sender_id,sequence);")
            try execute("""
                CREATE TABLE IF NOT EXISTS group_submissions (
                    message_id TEXT PRIMARY KEY, conversation TEXT NOT NULL, prompt TEXT NOT NULL, submitted REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS group_observed_turns (
                    message_id TEXT PRIMARY KEY, turn TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS group_original_reports (message_id TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS group_prompt_receipts (
                    message_id TEXT PRIMARY KEY, at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS group_batch_sources (
                    notice_key TEXT NOT NULL, source_key TEXT NOT NULL,
                    PRIMARY KEY(notice_key,source_key)
                );
                CREATE INDEX IF NOT EXISTS group_batch_source ON group_batch_sources(source_key);
                CREATE TABLE IF NOT EXISTS group_waits (
                  id TEXT PRIMARY KEY, group_id TEXT NOT NULL, owner_task TEXT NOT NULL,
                  request TEXT NOT NULL, state TEXT NOT NULL, deadline REAL NOT NULL,
                  external_ready INTEGER NOT NULL DEFAULT 0, detail TEXT NOT NULL DEFAULT '');
                CREATE INDEX IF NOT EXISTS wait_deadlines ON group_waits(state,deadline);
                CREATE INDEX IF NOT EXISTS wait_group ON group_waits(group_id,state);
                CREATE INDEX IF NOT EXISTS wait_task ON group_waits(owner_task);
                """)
            for suffix in ["-wal", "-shm"] { _ = chmod(path + suffix, 0o600) }
            guard try scalar("PRAGMA synchronous") == 2, try scalar("PRAGMA fullfsync") == 1 else {
                throw AppError.message("그룹 수신함의 디스크 저장 설정을 확인하지 못했습니다.")
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw AppError.message("그룹 수신함을 읽거나 저장하지 못했습니다. 기존 메시지는 유지합니다.") }
        for (index, text) in values.enumerated() {
            guard sqlite3_bind_text(value, Int32(index + 1), text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else {
                sqlite3_finalize(value); throw AppError.message("그룹 메시지를 저장하지 못했습니다.")
            }
        }
        return value
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AppError.message("그룹 수신함을 저장하지 못했습니다. 접수 완료로 처리하지 않습니다.") }
    }
    func update(_ sql: String, _ values: [String]) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw AppError.message("그룹 수신함 변경을 저장하지 못했습니다.") }
    }
    private func scalar(_ sql: String, _ values: [String] = []) throws -> Int {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw AppError.message("그룹 수신함 상태를 읽지 못했습니다.") }
        return Int(sqlite3_column_int64(s, 0))
    }
    private func rows(_ suffix: String, _ values: [String] = []) throws -> [SessionGroupMessage] {
        let s = try statement("SELECT " + columns + " FROM messages " + suffix, values); defer { sqlite3_finalize(s) }
        func text(_ index: Int32) -> String? { sqlite3_column_text(s, index).map { String(cString: $0) } }
        var result: [SessionGroupMessage] = []
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let id = text(1).flatMap(UUID.init(uuidString:)),
                  let group = text(2).flatMap(UUID.init(uuidString:)), let sender = text(3).flatMap(UUID.init(uuidString:)),
                  let recipient = text(4).flatMap(UUID.init(uuidString:)), let kind = text(5).flatMap(SessionGroupMessage.Kind.init(rawValue:)),
                  let body = text(6) else { throw AppError.message("그룹 수신함 기록을 해석하지 못했습니다. 기존 데이터를 유지합니다.") }
            result.append(.init(sequence: sqlite3_column_int64(s, 0), id: id, groupID: group, senderID: sender, recipientID: recipient,
                kind: kind, text: body, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)),
                acknowledgedAt: sqlite3_column_type(s, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 8)),
                attempts: Int(sqlite3_column_int64(s, 9)), nextAttemptAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 10)),
                lastResult: text(11), lastError: text(12), sourceKey: text(13), containsOriginalReport: sqlite3_column_int(s, 14) != 0))
        }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    public func message(_ id: UUID) throws -> SessionGroupMessage? { try rows("WHERE id=?", [id.uuidString]).first }
    public func message(sourceKey: String) throws -> SessionGroupMessage? { try rows("WHERE source_key=?", [sourceKey]).first }
    public var pendingCount: Int { get throws { try scalar("SELECT count(*) FROM messages WHERE acknowledged IS NULL AND last_result IS NOT 'superseded'") } }

    public func enqueue(id: UUID? = nil, groupID: UUID, senderID: UUID, recipientID: UUID, kind: SessionGroupMessage.Kind,
                        text: String, sourceKey: String? = nil, at date: Date = Date(), originalReport: Bool = false) throws -> SessionGroupMessage {
        try transaction {
            let message = try insertMessage(id: id, groupID: groupID, senderID: senderID, recipientID: recipientID,
                                            kind: kind, text: text, sourceKey: sourceKey, at: date, originalReport: originalReport)
            if originalReport, kind == .report, message.text == text {
                try update("INSERT OR IGNORE INTO group_original_reports(message_id) VALUES(?)", [message.id.uuidString])
                return try self.message(message.id) ?? message
            }
            return message
        }
    }

    func insertMessage(id: UUID? = nil, groupID: UUID, senderID: UUID, recipientID: UUID, kind: SessionGroupMessage.Kind,
                       text: String, sourceKey: String? = nil, at date: Date = Date(), originalReport: Bool = false) throws -> SessionGroupMessage {
        guard !text.isEmpty, text.count <= ((originalReport || [.reply, .waitNotice].contains(kind)) ? Int.max : kind == .report || kind == .choiceQuestion ? 16000 : SessionGroupOrchestration.maximumTaskLength), !text.contains("\0"), (senderID != recipientID || kind == .waitNotice) else {
            throw RemoteHTTPError(400, "그룹 메시지 내용과 대상을 확인해주세요.")
        }
        if let sourceKey, let previous = try message(sourceKey: sourceKey) {
            guard previous.groupID == groupID, previous.senderID == senderID, previous.recipientID == recipientID, previous.kind == kind else { throw RemoteHTTPError(409, "그룹 보고의 원래 대상을 확인해주세요.") }
            return previous
        }
        if let id, let previous = try message(id) {
            guard previous.groupID == groupID, previous.senderID == senderID, previous.recipientID == recipientID,
                  previous.kind == kind, previous.text == text, previous.sourceKey == sourceKey else { throw RemoteHTTPError(409, "같은 messageID의 내용이나 대상이 다릅니다. 새 메시지에만 새 ID를 사용하세요.") }
            return previous
        }
        // Older clients omit messageID. Collapse only identical, still-unacknowledged messages.
        if id == nil, sourceKey == nil, let previous = try rows("WHERE group_id=? AND sender_id=? AND recipient_id=? AND kind=? AND body=? AND source_key IS NULL AND acknowledged IS NULL ORDER BY sequence LIMIT 1",
            [groupID.uuidString, senderID.uuidString, recipientID.uuidString, kind.rawValue, text]).first { return previous }
        guard try kind == .waitNotice || pendingCount < maximumPending else { throw RemoteHTTPError(409, "미확인 그룹 메시지가 너무 많아 새 메시지를 접수하지 않았습니다. 기존 메시지를 수신 확인한 뒤 다시 보내세요.") }
        let key = id ?? UUID()
        try update("INSERT INTO messages(id,group_id,sender_id,recipient_id,kind,body,created,source_key) VALUES(?,?,?,?,?,?,?,NULLIF(?,''))",
                   [key.uuidString, groupID.uuidString, senderID.uuidString, recipientID.uuidString, kind.rawValue, text, String(date.timeIntervalSince1970), sourceKey ?? ""])
        guard let result = try message(key) else { throw AppError.message("저장된 그룹 메시지를 확인하지 못했습니다.") }
        return result
    }
    public func list(groupID: UUID, memberID: UUID, outbox: Bool = false, includeAcknowledged: Bool = false,
                     after: Int64 = 0, limit: Int = 50) throws -> [SessionGroupMessage] {
        try rows("WHERE group_id=? AND " + (outbox ? "sender_id" : "recipient_id") + "=? AND sequence>?" +
                 (includeAcknowledged ? "" : " AND acknowledged IS NULL AND last_result IS NOT 'superseded'") + " ORDER BY sequence LIMIT ?",
                 [groupID.uuidString, memberID.uuidString, String(after), String(max(1, min(limit, 101)))])
    }

    /// Questions retain their identity after delivery, so an observed prompt
    /// or an ACK cannot by itself remove an unanswered edge from the graph.
    public func conversations(groupID: UUID) throws -> SessionGroupConversationPage {
        let questions = """
            SELECT id FROM messages q WHERE q.group_id=? AND q.kind='question'
              AND q.last_result IS NOT 'superseded'
            ORDER BY EXISTS(SELECT 1 FROM messages a WHERE a.source_key='answer:' || q.id),
                     q.sequence DESC LIMIT 301
            """
        let rows = try rows("""
            WHERE group_id=? AND (id IN (\(questions)) OR source_key IN
                (SELECT 'answer:' || id FROM (\(questions))))
            ORDER BY sequence DESC
            """, Array(repeating: groupID.uuidString, count: 3))
        let answers = Dictionary(uniqueKeysWithValues: rows.filter { $0.kind == .reply }.compactMap { row in
            row.sourceKey.map { ($0, row) }
        })
        let expired = try expiredConversationQuestions(groupID)
        let projected = rows.filter { $0.kind == .question }.map { question in
            let answer = answers["answer:" + question.id.uuidString].flatMap { reply in
                reply.senderID == question.recipientID && reply.recipientID == question.senderID ? reply : nil
            }
            return SessionGroupConversation(question: question, answer: answer,
                                             waitExpired: answer == nil && expired.contains(question.id))
        }
        let ordered = projected.filter { $0.answer == nil } + projected.filter { $0.answer != nil }
        let messages = try self.rows("""
            WHERE group_id=? AND last_result IS NOT 'superseded' AND
              (kind IN ('message','report','choiceQuestion') OR
               (kind='reply' AND (source_key IS NULL OR source_key NOT LIKE 'answer:%')))
            ORDER BY sequence DESC LIMIT 151
            """, [groupID.uuidString])
        return .init(conversations: Array(ordered.prefix(300)), messages: Array(messages.prefix(150)),
                     hasMore: ordered.count > 300 || messages.count > 150)
    }
    // Results owned by a compound wait are sent in its single ready message.
    // Results remain individually readable in their original inbox.
    private static let notificationFilter = """
        m.acknowledged IS NULL
        AND (m.last_result IS NULL OR m.last_result NOT IN
            ('superseded','direct_attempting','direct_submitted','direct_unknown','late','batched'))
        AND NOT EXISTS (
            SELECT 1 FROM group_waits w
            WHERE w.group_id=m.group_id AND w.state IN ('waiting','ready','expired')
              AND json_extract(w.request,'$.member')=m.recipient_id
              AND (json_array_length(w.request,'$.questions')<>1
                   OR json_array_length(w.request,'$.tasks')>0 OR json_extract(w.request,'$.external')=1)
              AND (m.source_key IN (SELECT 'answer:' || value FROM json_each(w.request,'$.questions'))
                OR m.source_key IN (SELECT 'report:' || value FROM json_each(w.request,'$.tasks')))
        )
        """

    public func heads() throws -> [SessionGroupMessage] {
        try rows("""
            WHERE sequence IN (
                SELECT sequence FROM (
                    SELECT m.sequence, row_number() OVER (PARTITION BY m.group_id,m.recipient_id
                        ORDER BY CASE WHEN m.source_key LIKE 'decision:%' OR m.kind='waitNotice' THEN 0 ELSE 1 END,m.sequence) AS position
                    FROM messages m WHERE \(Self.notificationFilter)
                ) WHERE position=1
            ) ORDER BY sequence
            """)
    }

    var hasNotificationWork: Bool {
        get throws { try scalar("SELECT EXISTS(SELECT 1 FROM messages m WHERE " + Self.notificationFilter + ")") != 0 }
    }

    func recordSubmission(_ id: UUID, conversation: String, prompt: String, at date: Date = Date()) throws {
        try update("""
            INSERT INTO group_submissions(message_id,conversation,prompt,submitted)
            VALUES(?,?,?,?) ON CONFLICT(message_id) DO UPDATE SET
            conversation=excluded.conversation,prompt=excluded.prompt,submitted=excluded.submitted
            """, [id.uuidString, conversation.lowercased(), prompt, String(date.timeIntervalSince1970)])
    }

    func confirmedPrompt(_ id: UUID, conversation: String, prompt: String) throws -> Bool {
        let query = try statement("SELECT prompt FROM group_submissions WHERE message_id=? AND conversation=?",
                                  [id.uuidString, conversation.lowercased()])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, let stored = sqlite3_column_text(query, 0) else { return false }
        return String(cString: stored) == prompt
    }

    func claimTurn(_ id: UUID, turn: String) throws -> Bool {
        try update("INSERT OR IGNORE INTO group_observed_turns(message_id,turn) VALUES(?,?)", [id.uuidString, turn])
        return try scalar("SELECT EXISTS(SELECT 1 FROM group_observed_turns WHERE message_id=? AND turn=?)",
                          [id.uuidString, turn]) != 0
    }

    func notePromptReceipt(_ id: UUID, at date: Date = Date()) throws {
        try update("INSERT OR IGNORE INTO group_prompt_receipts(message_id,at) VALUES(?,?)",
                   [id.uuidString, String(date.timeIntervalSince1970)])
    }

    func recoverableClaudeQuestions() throws -> [SessionGroupMessage] {
        try rows("""
            WHERE kind='question' AND EXISTS(SELECT 1 FROM group_submissions s WHERE s.message_id=messages.id)
              AND NOT EXISTS(SELECT 1 FROM messages answer WHERE answer.source_key='answer:' || messages.id)
            ORDER BY sequence DESC LIMIT 64
            """)
    }

    func recoveryTurn(_ id: UUID, promptAt: Date, fallback: String) throws -> String? {
        let query = try statement("""
            SELECT s.submitted,t.turn,r.at FROM group_submissions s
            LEFT JOIN group_observed_turns t ON t.message_id=s.message_id
            LEFT JOIN group_prompt_receipts r ON r.message_id=s.message_id
            WHERE s.message_id=?
            """, [id.uuidString])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { return nil }
        let timestamp = promptAt.timeIntervalSince1970
        guard timestamp >= sqlite3_column_double(query, 0) else { return nil }
        guard let raw = sqlite3_column_text(query, 1) else { return fallback }
        let turn = String(cString: raw)
        guard turn.hasPrefix("claude:"), sqlite3_column_type(query, 2) != SQLITE_NULL else { return nil }
        // A prompt already observed by the hook must be the same transcript
        // submission, not a much later copy of the same message.
        guard abs(sqlite3_column_double(query, 2) - timestamp) <= 2 else { return nil }
        return turn
    }

    func batchSources(_ notice: SessionGroupMessage) throws -> [SessionGroupMessage] {
        guard notice.kind == .waitNotice, let key = notice.sourceKey else { return [] }
        return try rows("""
            WHERE group_id=? AND recipient_id=? AND acknowledged IS NULL AND
                  source_key IN (SELECT source_key FROM group_batch_sources WHERE notice_key=?)
            """, [notice.groupID.uuidString, notice.recipientID.uuidString, key])
    }

    func acknowledgedBatchContains(_ message: SessionGroupMessage) throws -> Bool {
        guard let key = message.sourceKey else { return false }
        return try scalar("""
            SELECT EXISTS(SELECT 1 FROM group_batch_sources b JOIN messages n ON n.source_key=b.notice_key
                          WHERE b.source_key=? AND n.group_id=? AND n.recipient_id=? AND n.acknowledged IS NOT NULL)
            """, [key, message.groupID.uuidString, message.recipientID.uuidString]) != 0
    }

    func confirmDelivery(_ message: SessionGroupMessage, at date: Date = Date()) throws {
        try update("UPDATE messages SET acknowledged=?,last_result='observed',last_error=NULL WHERE id=? AND acknowledged IS NULL",
                   [String(date.timeIntervalSince1970), message.id.uuidString])
    }

    public func noteAttempt(_ id: UUID, result: String, error: String? = nil, retryAt: Date, increment: Bool = false) throws {
        try update("UPDATE messages SET attempts=attempts+?,next_attempt=?,last_result=?,last_error=? WHERE id=? AND acknowledged IS NULL AND last_result IS NOT 'batched'",
                   [increment ? "1" : "0", String(retryAt.timeIntervalSince1970), result, String((error ?? "").prefix(500)), id.uuidString])
    }
    public func acknowledge(_ ids: [UUID], groupID: UUID, recipientID: UUID, at date: Date = Date()) throws {
        guard !ids.isEmpty, ids.count <= 50, Set(ids).count == ids.count else { throw RemoteHTTPError(400, "수신 확인할 메시지 ID 1~50개를 중복 없이 지정해주세요.") }
        try transaction {
            for id in ids {
                guard let message = try message(id), message.groupID == groupID, message.recipientID == recipientID else {
                    throw RemoteHTTPError(403, "자기 수신함의 메시지만 수신 확인할 수 있습니다.")
                }
            }
            for id in ids { try update("UPDATE messages SET acknowledged=? WHERE id=? AND acknowledged IS NULL", [String(date.timeIntervalSince1970), id.uuidString]) }
        }
    }
}
