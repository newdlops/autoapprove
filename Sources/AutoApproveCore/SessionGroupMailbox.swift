import Foundation
import CSQLite
import Darwin

public struct SessionGroupMessage: Equatable {
    /// `notice` is AutoApprove's own one-off request to a member (for example, naming the members).
    public enum Kind: String { case question, reply, message, report, choiceQuestion, waitNotice, notice }
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

    public var isExpired: Bool { lastResult == "expired" }

    static let promptPrefix = "[AutoApprove 그룹 전달 "
    private static let directInputBytes = 4096

    /// Every kind is typed with its body, so one turn delivers it and the observed
    /// prompt commits it. No kind relies on an agent ACK followed by reminders.
    var deliversBody: Bool { true }

    /// A request the user sent with a button in AutoApprove. It is the user's own input, typed for them,
    /// so it carries no relay header; agents rightly refuse to take a relayed notice as the user's word.
    static let userButtonSourcePrefix = "userButton:"
    private static let userButtonMarker = " (AutoApprove 요청 ID "
    public var isNicknameRequest: Bool {
        kind == .notice && (sourceKey?.hasPrefix("userButton:rename:") == true || text.hasPrefix("[AutoApprove 닉네임 요청]"))
    }
    var isUserButtonInput: Bool { kind == .notice && sourceKey?.hasPrefix(Self.userButtonSourcePrefix) == true }

    package func terminalPrompt(senderTitle: String, recipientAgent: AgentKind? = nil) -> String {
        func fitsComposer(_ prompt: String) -> Bool {
            recipientAgent != .claude || prompt.utf16.count <= 500
        }
        if isUserButtonInput {
            let prompt = SessionGroupOrchestration.oneLine(text) + Self.userButtonMarker + id.uuidString + ")"
            if fitsComposer(prompt) { return prompt }
            let lead = String(text.prefix(while: { $0 != "." }).prefix(120))
            return lead + ". 요청 전문을 읽고 처리해 줘. " + referenceText + Self.userButtonMarker + id.uuidString + ")"
        }
        let heading = Self.promptPrefix + id.uuidString + "] "
        let context: String
        if kind == .notice {
            context = heading + "AutoApprove 알림 · notice · groupID " + groupID.uuidString +
                " · get_group_messages(groupID, messageID: " + id.uuidString + ", includeAcknowledged: true)로 원문 확인 가능 · 본문 · "
        } else {
            let sender = String(SessionGroupOrchestration.oneLine(senderTitle).prefix(100))
            context = heading + sender + " · " + kind.rawValue + " · groupID " + groupID.uuidString +
                " · senderMemberID " + senderID.uuidString + " · 그룹 메시지 본문 · "
        }
        let body: String
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
           let encoded = try? JSONEncoder().encode(text) {
            body = "JSON 문자열 · " + String(decoding: encoded, as: UTF8.self)
        } else {
            body = text
        }
        let direct = context + body
        if direct.utf8.count <= Self.directInputBytes && fitsComposer(direct) { return direct }
        let reference = context + referenceText
        if fitsComposer(reference) { return reference }
        return heading + kind.rawValue + " · senderMemberID " + senderID.uuidString + " · 본문 · " + referenceText
    }

    private var referenceText: String {
        "원문 " + String(text.utf8.count) + "바이트 · get_group_messages(groupID: " +
            groupID.uuidString + ", messageID: " + id.uuidString + ", includeAcknowledged: true)"
    }

    func isReferencePrompt(_ prompt: String) -> Bool {
        prompt.hasSuffix(" · 그룹 메시지 본문 · " + referenceText) || prompt.hasSuffix(" · 본문 · " + referenceText) ||
            (isUserButtonInput && prompt.hasSuffix(referenceText + Self.userButtonMarker + id.uuidString + ")"))
    }

    static func terminalMessageID(_ prompt: String) -> UUID? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(")"), let marker = trimmed.range(of: userButtonMarker, options: .backwards) {
            return UUID(uuidString: String(trimmed[marker.upperBound..<trimmed.index(before: trimmed.endIndex)]))
        }
        guard prompt.hasPrefix(promptPrefix),
              let end = prompt.firstIndex(of: "]") else { return nil }
        return UUID(uuidString: String(prompt[prompt.index(prompt.startIndex, offsetBy: promptPrefix.count)..<end]))
    }

    func preview(outbox: Bool) -> JSONObject {
        let line = SessionGroupOrchestration.oneLine(text)
        var snippet = "", bytes = 0
        for character in line {
            let size = character.utf8.count
            guard bytes + size <= 120 else { break }
            snippet.append(character)
            bytes += size
        }
        let full = json
        var result: JSONObject = ["messageID": id.uuidString, "sequence": sequence, "kind": kind.rawValue,
            "textBytes": text.utf8.count, "preview": snippet, "truncated": bytes < line.utf8.count,
            outbox ? "memberID" : "senderMemberID": (outbox ? recipientID : senderID).uuidString]
        for key in ["state", "inReplyTo", "blocksProgress"] { result[key] = full[key] }
        if lastError != nil { result["hasDeliveryError"] = true }
        return result
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
        if lastResult == "superseded", lastError == "cancelledBySender" { value["state"] = "cancelled" }
        if lastResult == "superseded", let reason = lastError, reason.hasPrefix("supersededBy=") {
            value["supersededBy"] = String(reason.dropFirst("supersededBy=".count))
        }
        if lastResult == "answered" { value["state"] = "answered" }
        if isExpired { value["state"] = "expired" }
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
                CREATE INDEX IF NOT EXISTS message_pending_age ON messages(created) WHERE \(Self.pendingFilter);
                CREATE TABLE IF NOT EXISTS group_events (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT, gid TEXT NOT NULL, member TEXT NOT NULL,
                    ref TEXT NOT NULL, kind TEXT NOT NULL, at REAL NOT NULL, age INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(gid,ref,kind));
                CREATE INDEX IF NOT EXISTS group_events_page ON group_events(gid,seq);
                CREATE TABLE IF NOT EXISTS group_delivery_observations (mid TEXT PRIMARY KEY, at REAL NOT NULL);
                CREATE TRIGGER IF NOT EXISTS group_delivery_time AFTER UPDATE OF last_result,last_error,acknowledged ON messages
                WHEN NEW.last_result IS NOT OLD.last_result OR NEW.last_error IS NOT OLD.last_error OR NEW.acknowledged IS NOT OLD.acknowledged
                BEGIN
                    INSERT OR REPLACE INTO group_delivery_observations(mid,at) VALUES(NEW.id,strftime('%s','now'));
                END;
                CREATE TRIGGER IF NOT EXISTS group_delivery_event AFTER UPDATE OF last_result,acknowledged ON messages
                WHEN (NEW.acknowledged IS NOT OLD.acknowledged OR NEW.last_result IS NOT OLD.last_result)
                    AND (NEW.acknowledged IS NOT NULL OR NEW.last_result IN ('direct_submitted','direct_unknown','undelivered','superseded'))
                BEGIN
                    INSERT OR IGNORE INTO group_events(gid,member,ref,kind,at,age)
                    VALUES(NEW.group_id,NEW.recipient_id,NEW.id,
                        CASE WHEN NEW.acknowledged IS NOT NULL THEN 'acknowledged' ELSE NEW.last_result END,
                        strftime('%s','now'),max(0,CAST(strftime('%s','now')-NEW.created AS INTEGER)));
                END;
                CREATE TABLE IF NOT EXISTS group_submissions (
                    message_id TEXT PRIMARY KEY, conversation TEXT NOT NULL, prompt TEXT NOT NULL, submitted REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS group_submit_enters (message_id TEXT PRIMARY KEY, submitted REAL NOT NULL);
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
            try execute("""
                UPDATE messages AS q SET last_result='answered',last_error=NULL
                WHERE kind='question' AND \(Self.pendingFilter)
                  AND EXISTS(SELECT 1 FROM messages a WHERE a.source_key='answer:' || q.id
                    AND a.kind='reply' AND a.group_id=q.group_id AND a.sender_id=q.recipient_id AND a.recipient_id=q.sender_id);
                """)
            for suffix in ["-wal", "-shm"] { _ = chmod(path + suffix, 0o600) }
            guard try scalar("PRAGMA synchronous") == 2, try scalar("PRAGMA fullfsync") == 1 else {
                throw AppError.message("그룹 수신함의 디스크 저장 설정을 확인하지 못했습니다.")
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    /// Changes whenever another connection commits. A reader polls it to reload only after a real write.
    public var dataVersion: Int { get throws { try scalar("PRAGMA data_version") } }
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
    private static let pendingFilter = "acknowledged IS NULL AND last_result IS NOT 'answered' AND last_result IS NOT 'superseded' AND last_result IS NOT 'expired'"

    var hasAbsentSenders: Bool { get throws {
        try scalar("SELECT EXISTS(SELECT 1 FROM messages WHERE acknowledged IS NULL AND last_result='sender_absent')") != 0
    } }

    package func reconcileSenders(group: UUID, members: Set<UUID>) throws {
        let ids = String(decoding: try JSONEncoder().encode(members), as: UTF8.self)
        try transaction {
            try update("""
                UPDATE messages SET last_result='superseded',last_error=NULL,source_key='retired:' || source_key || ':' || id
                WHERE group_id=? AND kind='notice' AND acknowledged IS NULL
                  AND (last_result IS NULL OR last_result IN ('not_started','redeliver','sender_absent'))
                  AND ((source_key LIKE 'followup:%' AND sender_id NOT IN (SELECT value FROM json_each(?)))
                    OR ((source_key LIKE 'stalled:%' OR source_key LIKE 'uncertain:%') AND EXISTS (
                        SELECT 1 FROM messages original WHERE original.id=substr(messages.source_key,instr(messages.source_key,':')+1)
                          AND original.group_id=messages.group_id AND (original.acknowledged IS NOT NULL
                            OR original.last_result IN ('expired','answered','superseded')))))
                """, [group.uuidString, ids])
            try update("""
                UPDATE messages SET last_result='sender_absent',last_error='보낸 구성원이 그룹에 없어 전달을 보류했습니다.'
                WHERE group_id=? AND acknowledged IS NULL AND (last_result IS NULL OR last_result IN ('not_started','redeliver'))
                  AND sender_id NOT IN (SELECT value FROM json_each(?)) AND recipient_id IN (SELECT value FROM json_each(?))
                """, [group.uuidString, ids, ids])
            try update("""
                UPDATE messages SET last_result=NULL,last_error=NULL,next_attempt=0
                WHERE group_id=? AND acknowledged IS NULL AND last_result='sender_absent'
                  AND sender_id IN (SELECT value FROM json_each(?)) AND recipient_id IN (SELECT value FROM json_each(?))
                """, [group.uuidString, ids, ids])
        }
    }

    public var pendingCount: Int { get throws { try scalar("SELECT count(*) FROM messages WHERE " + Self.pendingFilter) } }

    package func nextExpiration(ttl: TimeInterval) throws -> Date? {
        let query = try statement("SELECT min(created) FROM messages WHERE " + Self.pendingFilter)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw AppError.message("그룹 메시지의 만료 시각을 읽지 못했습니다.") }
        guard sqlite3_column_type(query, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(query, 0) + ttl)
    }

    package func expireUnconfirmed(createdThrough cutoff: Date) throws {
        try update("UPDATE messages SET last_result='expired',last_error=NULL WHERE " + Self.pendingFilter + " AND created<=?",
                   [String(cutoff.timeIntervalSince1970)])
    }

    // MARK: Delivery receipts
    // The mailbox is a per-recipient log. A typed message is committed when its prompt is
    // observed in the recipient's conversation (or the recipient ACKs it). Until then it
    // stays "submitted"; it is typed again only after the engine finds proof that the
    // earlier typing never reached the model. Repeated loss moves it to "undelivered".

    private static let awaitingReceipt = "acknowledged IS NULL AND last_result IN ('direct_attempting','direct_submitted','direct_unknown')"

    var hasPendingReceipts: Bool { get throws { try scalar("SELECT EXISTS(SELECT 1 FROM messages WHERE " + Self.awaitingReceipt + ")") != 0 } }

    func overdueReceipts(at date: Date = Date()) throws -> [SessionGroupMessage] {
        try rows("WHERE " + Self.awaitingReceipt + " AND next_attempt<=? ORDER BY sequence", [String(date.timeIntervalSince1970)])
    }

    /// Proof of loss: queue the same message (same ID) for one more typing, or park it.
    func requeueLostSubmission(_ id: UUID, attemptLimit: Int, at date: Date = Date()) throws -> Bool {
        guard let message = try message(id), message.acknowledgedAt == nil,
              ["direct_attempting", "direct_submitted", "direct_unknown"].contains(message.lastResult ?? "") else { return false }
        let parked = message.attempts >= attemptLimit
        try update("UPDATE messages SET last_result=?,next_attempt=?,last_error=? WHERE id=? AND acknowledged IS NULL",
                   [parked ? "undelivered" : "redeliver", String(date.timeIntervalSince1970),
                    parked ? "입력한 메시지가 \(message.attempts)번 모두 대화에 들어가지 않아 자동 입력을 멈췄습니다." : "이전 입력이 대화에 들어가지 않아 다시 입력합니다.",
                    id.uuidString])
        return !parked
    }

    package func stalledForSenders(createdBefore date: Date, uncertainBefore: Date) throws -> [SessionGroupMessage] {
        try rows("""
            WHERE acknowledged IS NULL AND kind IN ('question','reply','message') AND sender_id<>recipient_id
              AND (((last_result IS NULL OR last_result IN ('not_started','undelivered')) AND created<=?)
                OR (last_result='direct_unknown' AND coalesce((SELECT submitted FROM group_submissions
                    WHERE message_id=messages.id),created)<=CAST(? AS REAL)))
              AND NOT EXISTS(SELECT 1 FROM messages n WHERE n.source_key=
                  (CASE WHEN messages.last_result='direct_unknown' THEN 'uncertain:' ELSE 'stalled:' END) || messages.id)
            ORDER BY sequence LIMIT 50
            """, [String(date.timeIntervalSince1970), String(uncertainBefore.timeIntervalSince1970)])
    }

    /// Messages still queued or awaiting a receipt whose recipient is not a member of the group any more
    /// (or whose group is gone). `members` maps each existing group to its current member IDs.
    func queuedForMissingRecipients(members: [UUID: Set<UUID>]) throws -> [SessionGroupMessage] {
        try rows("""
            WHERE acknowledged IS NULL
              AND (last_result IS NULL OR last_result NOT IN ('answered','superseded','batched','undelivered','expired'))
            ORDER BY sequence
            """).filter { members[$0.groupID]?.contains($0.recipientID) != true }
    }

    /// Takes a message out of the delivery queue and keeps it in the mailbox, readable as before.
    func park(_ id: UUID, reason: String) throws {
        try update("UPDATE messages SET last_result='undelivered',last_error=? WHERE id=? AND acknowledged IS NULL AND last_result IS NOT 'expired'",
                   [String(reason.prefix(500)), id.uuidString])
    }

    func submittedAt(_ id: UUID) throws -> Date? {
        let query = try statement("SELECT submitted FROM group_submissions WHERE message_id=?", [id.uuidString])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_type(query, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(query, 0))
    }

    /// No proof either way yet (the recipient is busy or its composer has text): look again later.
    func deferReceipt(_ id: UUID, until date: Date) throws {
        try update("UPDATE messages SET next_attempt=? WHERE id=? AND " + Self.awaitingReceipt, [String(date.timeIntervalSince1970), id.uuidString])
    }

    func enqueueNicknameRequest(group: UUID, recipient: UUID, scope: String, text: String, replacesAll: Bool) throws {
        let prefix = "userButton:rename:"
        let queued = "group_id=? AND recipient_id=? AND kind='notice' AND acknowledged IS NULL AND (last_result IS NULL OR last_result IN ('not_started','redeliver')) AND source_key LIKE ?"
        let base = [group.uuidString, recipient.uuidString]
        let pattern = prefix + (replacesAll ? "%" : scope + ":%")
        try update("UPDATE messages SET last_result='superseded',last_error=NULL WHERE " + queued, base + [pattern])
        if replacesAll {
            try update("UPDATE messages SET last_result='superseded',last_error=NULL WHERE group_id=? AND recipient_id=? AND kind='notice' AND acknowledged IS NULL AND (last_result IS NULL OR last_result IN ('not_started','redeliver')) AND source_key IS NULL AND body LIKE '[AutoApprove 닉네임 요청]%'", base)
        }
        _ = try insertMessage(id: nil, groupID: group, senderID: recipient, recipientID: recipient,
            kind: .notice, text: text, sourceKey: prefix + scope + ":" + UUID().uuidString)
    }

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
        guard !text.isEmpty, text.count <= ((originalReport || [.reply, .waitNotice].contains(kind)) ? Int.max : kind == .report || kind == .choiceQuestion ? 16000 : SessionGroupOrchestration.maximumTaskLength), !text.contains("\0"), (senderID != recipientID || kind == .waitNotice || kind == .notice) else {
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
        if id == nil, sourceKey == nil, let previous = try rows("WHERE group_id=? AND sender_id=? AND recipient_id=? AND kind=? AND body=? AND source_key IS NULL AND \(Self.pendingFilter) ORDER BY sequence LIMIT 1",
            [groupID.uuidString, senderID.uuidString, recipientID.uuidString, kind.rawValue, text]).first { return previous }
        guard try kind == .waitNotice || kind == .notice || pendingCount < maximumPending else { throw RemoteHTTPError(409, "미확인 그룹 메시지가 너무 많아 새 메시지를 접수하지 않았습니다. 기존 메시지를 수신 확인한 뒤 다시 보내세요.") }
        let key = id ?? UUID()
        try update("INSERT INTO messages(id,group_id,sender_id,recipient_id,kind,body,created,source_key) VALUES(?,?,?,?,?,?,?,NULLIF(?,''))",
                   [key.uuidString, groupID.uuidString, senderID.uuidString, recipientID.uuidString, kind.rawValue, text, String(date.timeIntervalSince1970), sourceKey ?? ""])
        guard let result = try message(key) else { throw AppError.message("저장된 그룹 메시지를 확인하지 못했습니다.") }
        return result
    }
    func recordHeldEvents() throws {
        try update("""
            INSERT OR IGNORE INTO group_events(gid,member,ref,kind,at,age)
            SELECT group_id,recipient_id,id,'deliveryHeld',strftime('%s','now'),CAST(strftime('%s','now')-created AS INTEGER)
            FROM messages WHERE acknowledged IS NULL AND last_result IN ('not_started','undelivered','sender_absent')
              AND created<=strftime('%s','now')-300
            """, [])
    }

    func taskEvent(_ task: SessionGroupAssignment, kind: String) throws {
        try update("INSERT OR IGNORE INTO group_events(gid,member,ref,kind,at,age) VALUES(?,?,?,?,?,?)",
            [task.groupID.uuidString, task.workerMemberID.uuidString, task.id.uuidString, kind,
             String(Date().timeIntervalSince1970), String(max(0, Int(Date().timeIntervalSince(task.sentAt))))])
    }

    package func events(group: UUID, after cursor: Int) throws -> [JSONObject] {
        let q = try statement("SELECT seq,member,ref,kind,at,age FROM group_events WHERE gid=? AND seq>? ORDER BY seq LIMIT 51", [group.uuidString, String(cursor)])
        defer { sqlite3_finalize(q) }
        var page: [JSONObject] = []
        while true {
            switch sqlite3_step(q) {
            case SQLITE_ROW:
                page.append(["cursor": Int(sqlite3_column_int64(q, 0)), "memberID": String(cString: sqlite3_column_text(q, 1)),
                    "referenceID": String(cString: sqlite3_column_text(q, 2)), "event": String(cString: sqlite3_column_text(q, 3)),
                    "observedAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: sqlite3_column_double(q, 4))),
                    "elapsedSeconds": Int(sqlite3_column_int64(q, 5))])
            case SQLITE_DONE: return page
            default: throw AppError.message("그룹 이벤트를 읽지 못했습니다.")
            }
        }
    }

    func deliveryExplanation(_ m: SessionGroupMessage) throws -> JSONObject {
        let q = try statement("SELECT at FROM group_delivery_observations WHERE mid=?", [m.id.uuidString])
        defer { sqlite3_finalize(q) }
        let last = sqlite3_step(q) == SQLITE_ROW ? Date(timeIntervalSince1970: sqlite3_column_double(q, 0)) : m.lastResult == nil ? m.createdAt : nil
        let stage: String, next: String
        if m.acknowledgedAt != nil { stage = "acknowledged"; next = "none" }
        else {
            switch m.lastResult {
            case "direct_unknown", "direct_attempting": stage = "submissionUnknown"; next = "inspectTerminal"
            case "direct_submitted": stage = "enterSent"; next = "awaitReceipt"
            case "not_started", "undelivered", "sender_absent": stage = "held"; next = "inspectHold"
            case "batched": stage = "batched"; next = "awaitReceipt"
            case "superseded", "answered", "expired": stage = m.json["state"] as? String ?? "retired"; next = "none"
            default: stage = "queued"; next = "awaitDelivery"
            }
        }
        var result: JSONObject = ["messageID": m.id.uuidString, "memberID": m.recipientID.uuidString, "stage": stage,
            "nextAction": next, "evidence": m.lastResult ?? "mailbox", "attempts": m.attempts,
            "observedAt": (m.acknowledgedAt ?? last).map(ISO8601DateFormatter().string(from:)) as Any? ?? NSNull()]
        result["reason"] = m.lastError
        return result
    }

    func retireQueued(_ ids: [UUID], group: UUID, sender: UUID, recipient: UUID, replacement: UUID?) throws {
        let reason = replacement.map { "supersededBy=" + $0.uuidString } ?? "cancelledBySender"
        for id in ids {
            guard let row = try message(id), row.groupID == group, row.senderID == sender, row.recipientID == recipient,
                  row.kind == .message, row.acknowledgedAt == nil, id != replacement else {
                throw RemoteHTTPError(409, "같은 수신자에게 보낸 대기 중 일반 메시지만 취소하거나 대체할 수 있습니다.")
            }
            if row.lastResult == "superseded", row.lastError == reason { continue }
            guard [nil, "not_started"].contains(row.lastResult), try submittedAt(id) == nil else {
                throw RemoteHTTPError(409, "메시지 " + id.uuidString + "의 전달이 이미 시작됐거나 종료되었습니다.")
            }
            try update("UPDATE messages SET last_result='superseded',last_error=? WHERE id=?", [reason, id.uuidString])
        }
    }

    public func list(groupID: UUID, memberID: UUID, outbox: Bool = false, includeAcknowledged: Bool = false,
                     after: Int64 = 0, limit: Int = 50) throws -> [SessionGroupMessage] {
        try rows("WHERE group_id=? AND " + (outbox ? "sender_id" : "recipient_id") + "=? AND sequence>?" +
                 (includeAcknowledged ? "" : " AND " + Self.pendingFilter) + " ORDER BY sequence LIMIT ?",
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
                                             waitExpired: answer == nil && (question.isExpired || expired.contains(question.id)))
        }
        let ordered = projected.filter { $0.answer == nil } + projected.filter { $0.answer != nil }
        let messages = try self.rows("""
            WHERE group_id=? AND last_result IS NOT 'superseded' AND
              (kind IN ('message','report','choiceQuestion') OR (kind='notice' AND (source_key LIKE 'userButton:rename:%' OR body LIKE '[AutoApprove 닉네임 요청]%')) OR
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
            ('sender_absent','answered','superseded','expired','direct_attempting','direct_submitted','direct_unknown','late','batched','undelivered'))
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

    private static let notificationOrder = "CASE WHEN m.source_key LIKE 'userButton:rename:%' THEN -3 WHEN m.source_key LIKE 'userButton:questionPriority:%' THEN -2 WHEN (m.kind='notice' AND m.body LIKE '[AutoApprove 닉네임 요청]%') THEN -1 WHEN m.source_key LIKE 'decision:%' OR m.kind='waitNotice' THEN 0 ELSE 1 END,CASE WHEN m.source_key LIKE 'userButton:rename:%' THEN -m.sequence ELSE m.sequence END"

    public struct InboxOperation: Equatable, Sendable {
        public let unacknowledgedCount: Int
        public let lastAcknowledgedAt: Date?
        public let firstPendingAt: Date?
        public let hasNotificationHead: Bool
        public let headDidNotStart: Bool
        public let lastDeliveryFailure: String?
        /// A message parked after repeated lost typings; it has left the delivery queue.
        public var hasParkedMessage = false
        public var queuedCount = 0
    }

    /// Measure the whole inbox without materializing conversation bodies. The
    /// head uses the same eligibility and priority as the delivery worker.
    public func inboxOperations(groupID: UUID) throws -> [UUID: InboxOperation] {
        let query = try statement("""
            WITH inbox AS (
                SELECT recipient_id, sum(acknowledged IS NULL) AS pending, max(acknowledged) AS last_ack,
                       sum(acknowledged IS NULL AND (last_result IS NULL OR last_result IN ('not_started','redeliver','undelivered'))) AS queued,
                       min(CASE WHEN acknowledged IS NULL THEN created END) AS first_pending,
                       max(CASE WHEN acknowledged IS NULL AND last_result='undelivered' THEN last_error END) AS parked
                FROM messages
                WHERE group_id=? AND kind NOT IN ('waitNotice','notice') AND last_result IS NOT 'answered' AND last_result IS NOT 'superseded' AND last_result IS NOT 'expired'
                GROUP BY recipient_id
            ), heads AS (
                SELECT m.recipient_id, m.last_result, m.last_error,
                       row_number() OVER (PARTITION BY m.recipient_id ORDER BY \(Self.notificationOrder)) AS position
                FROM messages m WHERE m.group_id=? AND \(Self.notificationFilter)
            )
            SELECT inbox.recipient_id, pending, last_ack, first_pending, heads.position, heads.last_result, heads.last_error, inbox.parked, inbox.queued
            FROM inbox LEFT JOIN heads ON heads.recipient_id=inbox.recipient_id AND heads.position=1
            """, [groupID.uuidString, groupID.uuidString])
        defer { sqlite3_finalize(query) }
        func date(_ column: Int32) -> Date? {
            sqlite3_column_type(query, column) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(query, column))
        }
        func string(_ column: Int32) -> String? { sqlite3_column_text(query, column).map { String(cString: $0) } }
        var values: [UUID: InboxOperation] = [:]
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW, let id = string(0).flatMap(UUID.init(uuidString:)) else {
                throw AppError.message("그룹 수신함의 상태를 읽지 못했습니다.")
            }
            // A parked message (typed repeatedly, never observed) blocks delivery just like one that cannot start.
            let parked = string(7)
            let blocked = string(5) == "not_started" || parked != nil
            values[id] = InboxOperation(unacknowledgedCount: Int(sqlite3_column_int64(query, 1)),
                                        lastAcknowledgedAt: date(2), firstPendingAt: date(3),
                                        hasNotificationHead: sqlite3_column_int(query, 4) == 1,
                                        headDidNotStart: blocked, lastDeliveryFailure: blocked ? (string(5) == "not_started" ? string(6) : parked) : nil,
                                        hasParkedMessage: parked != nil, queuedCount: Int(sqlite3_column_int64(query, 8)))
        }
    }

    public func heads() throws -> [SessionGroupMessage] {
        try rows("""
            WHERE sequence IN (
                SELECT sequence FROM (
                    SELECT m.sequence, row_number() OVER (PARTITION BY m.group_id,m.recipient_id
                        ORDER BY \(Self.notificationOrder)) AS position
                    FROM messages m WHERE \(Self.notificationFilter)
                ) WHERE position=1
            ) ORDER BY CASE WHEN source_key LIKE 'userButton:rename:%' THEN -sequence ELSE sequence END
            """)
    }

    var hasNotificationWork: Bool {
        get throws { try scalar("SELECT EXISTS(SELECT 1 FROM messages m WHERE " + Self.notificationFilter + ")") != 0 }
    }

    package func recordSubmission(_ id: UUID, conversation: String, prompt: String, at date: Date = Date()) throws {
        try update("""
            INSERT INTO group_submissions(message_id,conversation,prompt,submitted)
            VALUES(?,?,?,?) ON CONFLICT(message_id) DO UPDATE SET
            conversation=excluded.conversation,prompt=excluded.prompt,submitted=excluded.submitted
            """, [id.uuidString, conversation.lowercased(), prompt, String(date.timeIntervalSince1970)])
    }

    func pendingEnterPrompt(_ id: UUID, conversation: String) throws -> String? {
        let query = try statement("""
            SELECT s.prompt FROM group_submissions s JOIN messages m ON m.id=s.message_id
            WHERE s.message_id=? AND s.conversation=? AND m.acknowledged IS NULL
            AND NOT EXISTS (SELECT 1 FROM group_submit_enters e WHERE e.message_id=s.message_id AND e.submitted=s.submitted)
            """, [id.uuidString, conversation.lowercased()])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, let value = sqlite3_column_text(query, 0) else { return nil }
        return String(cString: value)
    }

    func claimSubmitEnter(_ id: UUID, conversation: String, prompt: String, manualQuestion: Bool) throws -> Bool {
        try update("""
            INSERT INTO group_submit_enters(message_id,submitted)
            SELECT s.message_id,s.submitted FROM group_submissions s JOIN messages m ON m.id=s.message_id
            WHERE s.message_id=? AND s.conversation=? AND s.prompt=?
            AND (m.acknowledged IS NULL OR (?='1' AND m.kind='question' AND m.last_result='direct_attempting'))
            ON CONFLICT(message_id) DO UPDATE SET submitted=excluded.submitted WHERE submitted<>excluded.submitted
            """, [id.uuidString, conversation.lowercased(), prompt, manualQuestion ? "1" : "0"])
        return sqlite3_changes(db) == 1
    }

    func releaseSubmitEnter(_ id: UUID, conversation: String, prompt: String) throws {
        try update("""
            DELETE FROM group_submit_enters WHERE message_id=? AND submitted=(
                SELECT submitted FROM group_submissions WHERE message_id=? AND conversation=? AND prompt=?)
            """, [id.uuidString, id.uuidString, conversation.lowercased(), prompt])
    }

    func submissionPrompt(_ id: UUID, conversation: String) throws -> String? {
        let q = try statement("SELECT prompt FROM group_submissions WHERE message_id=? AND conversation=?", [id.uuidString,conversation.lowercased()])
        defer { sqlite3_finalize(q) }
        guard sqlite3_step(q) == SQLITE_ROW, let value = sqlite3_column_text(q, 0) else { return nil }
        return String(cString:value)
    }

    func confirmedPrompt(_ id: UUID, conversation: String, prompt: String) throws -> Bool {
        let query = try statement("""
            SELECT s.prompt, EXISTS(SELECT 1 FROM group_submit_enters e WHERE e.message_id=s.message_id AND e.submitted=s.submitted)
            FROM group_submissions s WHERE s.message_id=? AND s.conversation=?
            """,
                                  [id.uuidString, conversation.lowercased()])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, let stored = sqlite3_column_text(query, 0) else { return false }
        let expected = String(cString: stored)
        if prompt == expected { return true }
        guard sqlite3_column_int(query, 1) != 0 else { return false }
        return ClaudeComposerReadiness.submitLineEndings.contains { prompt == expected + $0 }
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

    func outstandingQuestions() throws -> [SessionGroupMessage] {
        try rows("""
            WHERE kind='question' AND last_result IS NOT 'superseded' AND last_result IS NOT 'expired'
              AND NOT EXISTS(SELECT 1 FROM messages answer WHERE answer.source_key='answer:' || messages.id)
            ORDER BY sequence
            """)
    }

    package func pendingReplies(group: UUID, member: UUID, senders: [UUID], after: Int64 = 0, limit: Int = 51) throws -> [SessionGroupMessage] {
        try rows("""
            WHERE group_id=? AND recipient_id=? AND sequence>? AND kind='question' AND sender_id IN (SELECT value FROM json_each(?))
              AND last_result IS NOT 'superseded' AND last_result IS NOT 'expired'
              AND NOT EXISTS(SELECT 1 FROM messages a WHERE a.source_key='answer:' || messages.id)
              AND NOT EXISTS(SELECT 1 FROM group_waits w WHERE w.group_id=messages.group_id
                  AND json_extract(w.request,'$.decision')=messages.id AND w.state IN ('waiting','ready','expired'))
              AND (NOT EXISTS(SELECT 1 FROM group_waits w,json_each(w.request,'$.questions') q
                       WHERE w.group_id=messages.group_id AND w.state='expired' AND q.value=messages.id)
                   OR EXISTS(SELECT 1 FROM group_waits w,json_each(w.request,'$.questions') q
                       WHERE w.group_id=messages.group_id AND w.state='waiting' AND q.value=messages.id))
            ORDER BY sequence LIMIT ?
            """, [group.uuidString, member.uuidString, String(after), String(decoding: try JSONEncoder().encode(senders), as: UTF8.self), String(limit)])
    }

    static let priorityPrefix = "userButton:questionPriority:"

    func requestPriorityReplies(group: UUID, member: UUID, conversation: UUID, senders: [UUID]) throws -> (SessionGroupMessage, Bool) {
        try transaction {
            let questions = try pendingReplies(group: group, member: member, senders: senders, limit: -1)
            guard let last = questions.last else { throw AppError.message("지금 회신할 미응답 질문이 없습니다.") }
            let prefix = Self.priorityPrefix + conversation.uuidString + ":"
            if let previous = try rows("WHERE group_id=? AND recipient_id=? AND source_key LIKE ? AND " + Self.pendingFilter + " ORDER BY sequence DESC LIMIT 1",
                [group.uuidString, member.uuidString, prefix + "%"]).first { return (previous, false) }
            let text = "진행 중인 작업과 진행 지점을 보존하고 잠시 보류해 줘. 그룹 " + group.uuidString +
                "에서 get_group_messages(groupID, unansweredOnly: true)로 받은 질문을 오래된 순서대로 확인해 줘. " +
                "sequence " + String(last.sequence) + "까지 각 질문의 senderMemberID에 reply_group_question으로 답하고 inReplyTo에 원래 messageID를 지정해 줘. " +
                "hasMore이면 nextAfterSequence로 다음 페이지를 읽어 줘. 답변을 마치면 이 대화에서 보류했던 작업을 이어서 진행해 줘."
            let message = try insertMessage(id: nil, groupID: group, senderID: member, recipientID: member, kind: .notice,
                text: text, sourceKey: prefix + UUID().uuidString)
            return (message, true)
        }
    }

    package func remindIfDue(_ question: SessionGroupMessage, before cutoff: Date) throws -> Bool {
        try transaction {
            guard let current = try unansweredQuestion(question.id, in: question.groupID),
                  let received = current.acknowledgedAt, received <= cutoff,
                  try canAutomaticallyAnswer(question.id),
                  try !expiredConversationQuestions(question.groupID).contains(question.id),
                  try message(sourceKey: "followup:" + question.id.uuidString) == nil,
                  try scalar("""
                    SELECT EXISTS(SELECT 1 FROM messages WHERE group_id=? AND recipient_id=?
                        AND source_key LIKE 'followup:%' AND last_result IS NOT 'sender_absent' AND (created>? OR (\(Self.pendingFilter))))
                    """, [question.groupID.uuidString, question.recipientID.uuidString, String(cutoff.timeIntervalSince1970)]) == 0 else { return false }
            _ = try insertMessage(id: nil, groupID: question.groupID, senderID: question.senderID,
                recipientID: question.recipientID, kind: .notice,
                text: "이전에 수신한 질문에 답변이 필요합니다. get_group_messages에서 원래 질문 " + question.id.uuidString +
                    "의 본문을 확인하고 해당 ID를 inReplyTo로 지정해 답해주세요.",
                sourceKey: "followup:" + question.id.uuidString)
            return true
        }
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
            WHERE group_id=? AND recipient_id=? AND acknowledged IS NULL AND last_result IS NOT 'expired' AND
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
        try update("UPDATE messages SET acknowledged=?,last_result='observed',last_error=NULL WHERE id=? AND acknowledged IS NULL AND last_result IS NOT 'expired'",
                   [String(date.timeIntervalSince1970), message.id.uuidString])
    }

    public func noteAttempt(_ id: UUID, result: String, error: String? = nil, retryAt: Date, increment: Bool = false) throws {
        try noteAttempt(id, result: result, error: error, retryAt: retryAt, increment: increment ? 1 : 0)
    }

    /// `attempts` counts typings. A try that stopped before typing passes -1 to undo its count.
    public func noteAttempt(_ id: UUID, result: String, error: String? = nil, retryAt: Date, increment: Int) throws {
        try update("UPDATE messages SET attempts=max(0,attempts+?),next_attempt=?,last_result=?,last_error=? WHERE id=? AND acknowledged IS NULL AND last_result IS NOT 'answered' AND last_result IS NOT 'superseded' AND last_result IS NOT 'batched' AND last_result IS NOT 'expired'",
                   [String(increment), String(retryAt.timeIntervalSince1970), result, String((error ?? "").prefix(500)), id.uuidString])
    }

    func unansweredQuestion(_ id: UUID, in groupID: UUID) throws -> SessionGroupMessage? {
        try rows("""
            WHERE id=? AND group_id=? AND kind='question' AND last_result IS NOT 'superseded' AND last_result IS NOT 'expired'
              AND NOT EXISTS(SELECT 1 FROM messages answer WHERE answer.source_key='answer:' || messages.id)
            """, [id.uuidString, groupID.uuidString]).first
    }

    func noteManualQuestionAttempt(_ id: UUID, result: String?, error: String? = nil, retryAt: Date, starting: Bool = false) throws {
        try update("""
            UPDATE messages SET attempts=attempts+?, next_attempt=?, last_result=NULLIF(?,''), last_error=NULLIF(?,'')
            WHERE id=? AND kind='question' AND \(starting ? "last_result IS NOT 'superseded' AND last_result IS NOT 'expired'" : "last_result='direct_attempting'")
            """, [starting ? "1" : "0", String(retryAt.timeIntervalSince1970), result ?? "",
                  String((error ?? "").prefix(500)), id.uuidString])
    }
    public func acknowledge(_ ids: [UUID], groupID: UUID, recipientID: UUID, at date: Date = Date()) throws {
        guard !ids.isEmpty, ids.count <= 50, Set(ids).count == ids.count else { throw RemoteHTTPError(400, "수신 확인할 메시지 ID 1~50개를 중복 없이 지정해주세요.") }
        try transaction {
            for id in ids {
                guard let message = try message(id), message.groupID == groupID, message.recipientID == recipientID else {
                    throw RemoteHTTPError(403, "자기 수신함의 메시지만 수신 확인할 수 있습니다.")
                }
                guard !message.isExpired else { throw RemoteHTTPError(409, "만료된 메시지는 수신 확인할 수 없습니다.") }
            }
            for id in ids { try update("UPDATE messages SET acknowledged=? WHERE id=? AND acknowledged IS NULL", [String(date.timeIntervalSince1970), id.uuidString]) }
        }
    }
}
