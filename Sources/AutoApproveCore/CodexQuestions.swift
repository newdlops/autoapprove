import Foundation
import CSQLite

public struct QuestionAutomation: Codable, Equatable {
    public enum Phase: String, Codable { case scheduled, paused, editing, cancelled, restored, duplicate, needsReview, unavailable }
    public var phase: Phase
    public var deadline: Date?
    public var answer: String?
    public init(phase: Phase, deadline: Date? = nil, answer: String? = nil) {
        self.phase = phase; self.deadline = deadline; self.answer = answer
    }
    public var canCancel: Bool { [.scheduled, .paused, .unavailable].contains(phase) }
}

public struct QueuedQuestion: Identifiable, Codable, Equatable {
    public var id: String
    public var threadID: String
    public var title: String
    public var options: [String]
    public var multiSelect: Bool? = nil
    public var reply: QuestionReply?
    public var automation: QuestionAutomation?
    /// A later unquoted message may already answer this question; keep it visible,
    /// but require a person to resolve it instead of guessing another answer.
    public var hasLaterUserMessage: Bool?
    public var needsAnswer: Bool { reply?.phase != .queued && reply?.phase != .sending }
    public var summary: String {
        ([title] + options.enumerated().map { "\($0.offset + 1). \($0.element)" }).joined(separator: "\n")
    }
    public init(id: String, threadID: String, title: String, options: [String] = []) {
        self.id = id; self.threadID = threadID; self.title = title; self.options = options
    }
    func isSameRequest(as other: QueuedQuestion) -> Bool {
        id == other.id && threadID == other.threadID && title == other.title && options == other.options
            && (multiSelect ?? false) == (other.multiSelect ?? false)
    }
    var titleIdentity: String {
        title.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public struct CodexQuestionUpdate {
    public var sessionID: String
    public var threadID: String?
    /// nil means the read did not succeed; [] is a successfully observed empty queue.
    public var questions: [QueuedQuestion]?
    public var error: String?
    public var turn: CodexTurnState?
    public var completionError: String?
    public var completionReadPending: Bool
    public init(sessionID: String, questions: [QueuedQuestion]? = [], error: String? = nil, turn: CodexTurnState? = nil, completionError: String? = nil, completionReadPending: Bool = false, threadID: String? = nil) {
        self.sessionID = sessionID; self.threadID = threadID; self.questions = questions; self.error = error
        self.turn = turn; self.completionError = completionError
        self.completionReadPending = completionReadPending
    }
}

/// The history projection exposes async questions, but no authoritative pending flag.
/// Resolve only a unique, exact quoted question followed by an answer. Ordinary input,
/// tool completion, compaction, and a new turn must not discard unanswered questions.
struct CodexQuestionProjection: Equatable {
    struct Question: Equatable { let title: String; let options: [String]; let multiSelect: Bool? }
    enum Kind: Equatable { case asynchronous(id: String, questions: [Question?]?); case userMessage(answers: [String]) }
    let kind: Kind
    var isAsynchronous: Bool { if case .asynchronous = kind { return true }; return false }
}

public enum CodexQuestionHistory {
    public struct Item {
        public var ordinal: Int64
        public var json: JSONObject
        public init(ordinal: Int64, json: JSONObject) { self.ordinal = ordinal; self.json = json }
    }
    /// Only question fields and quote matchers affect pending decisions. This
    /// private cache representation is never sent as user input or displayed.
    /// In particular, a long ordinary message needs only a nonempty-input flag.
    static func compactProjection(_ item: JSONObject) -> CodexQuestionProjection? {
        if item["type"] as? String == "agentMessage", item["delivery"] as? String == "async",
           let id = item["id"] as? String, !id.isEmpty {
            var questionsValue: [CodexQuestionProjection.Question?]?
            if let questions = item["questions"] as? [JSONObject] {
                // Preserve positions, including invalid questions: they are part
                // of the request ID. A missing array must still consume seenID.
                questionsValue = questions.map { question in
                    guard let title = question["title"] as? String, !normalized(title).isEmpty else { return nil }
                    return CodexQuestionProjection.Question(title: title, options: question["options"] as? [String] ?? [],
                        multiSelect: question["multiSelect"] as? Bool)
                }
            }
            return CodexQuestionProjection(kind: .asynchronous(id: id, questions: questionsValue))
        }
        guard item["type"] as? String == "userMessage", let content = item["content"] as? [JSONObject] else { return nil }
        var textParts: [String] = [], quotedAnswerCandidate = false
        for block in content where block["type"] as? String == "text" {
            guard let text = block["text"] as? String else { continue }
            if !quotedAnswerCandidate {
                guard let firstSignificant = text.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                    textParts.append(text); continue
                }
                // Most user input is ordinary text. Stop scanning as soon as
                // the leading non-whitespace scalar rules out an answer quote.
                guard firstSignificant.value == 62 else {
                    return CodexQuestionProjection(kind: .userMessage(answers: []))
                }
                quotedAnswerCandidate = true
            }
            textParts.append(text)
        }
        guard quotedAnswerCandidate else { return nil }
        // Only messages beginning with a quote need full text joining and analysis.
        let quotes = answeredQuotes(textParts.joined(separator: "\n"))
        // Retain only normalized question titles, never the answer or surrounding text.
        return CodexQuestionProjection(kind: .userMessage(answers: quotes))
    }
    public static func pending(threadID: String, items: [Item]) -> [QueuedQuestion] {
        let orderedItems = items.sorted(by: { $0.ordinal < $1.ordinal })
        var pending: [QueuedQuestion] = []
        var seen = Set<String>()
        for row in orderedItems { apply(row, threadID: threadID, pending: &pending, seen: &seen) }
        return pending
    }

    fileprivate static func apply(_ row: Item, threadID: String, pending: inout [QueuedQuestion], seen: inout Set<String>) {
        guard let projection = compactProjection(row.json) else { return }
        apply(projection, threadID: threadID, pending: &pending, seen: &seen)
    }

    fileprivate static func apply(_ projection: CodexQuestionProjection, threadID: String,
                                  pending: inout [QueuedQuestion], seen: inout Set<String>) {
        switch projection.kind {
        case let .asynchronous(id, questions):
            guard seen.insert(id).inserted, let questions else { return }
            for (index, question) in questions.enumerated() {
                guard let question else { continue }
                var pendingQuestion = QueuedQuestion(id: "codex:\(threadID):\(id):\(index)", threadID: threadID,
                    title: question.title, options: question.options)
                pendingQuestion.multiSelect = question.multiSelect
                pending.append(pendingQuestion)
            }
        case let .userMessage(answers):
            if answers.isEmpty {
                for index in pending.indices where pending[index].hasLaterUserMessage != true {
                    pending[index].hasLaterUserMessage = true
                }
            }
            for quote in answers {
                let matches = pending.indices.filter { normalized(pending[$0].title) == quote }
                // The transcript does not identify which copy was answered.
                if matches.count == 1 { pending.remove(at: matches[0]) }
            }
        }
    }
    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func answeredQuotes(_ text: String) -> [String] {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">") else { return [] }
        var quotes: [String] = [], block: [String] = [], answered = false
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") {
                if answered { quotes.append(normalized(block.joined(separator: "\n"))); block = []; answered = false }
                block.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if !line.isEmpty && !block.isEmpty { answered = true }
        }
        if answered { quotes.append(normalized(block.joined(separator: "\n"))) }
        return quotes
    }
}

public struct CodexThreadLocation: Equatable {
    public var threadID: String
    public var database: String
    public init(threadID: String, database: String) { self.threadID = threadID; self.database = database }

    /// Bind by the exact process's open root rollout, never by project or newest file.
    public static func locate(paths: [String]) throws -> CodexThreadLocation {
        var seenRolloutPaths = Set<String>(), matches = Set<String>(), locations: [CodexThreadLocation] = []
        for path in paths {
            guard path.hasSuffix(".jsonl"), let slash = path.lastIndex(of: "/"),
                  path[path.index(after: slash)...].hasPrefix("rollout-") else { continue }
            guard seenRolloutPaths.insert(path).inserted else { continue }
            let url = URL(fileURLWithPath: path)
            let home = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            guard url.path.hasPrefix(home.appendingPathComponent("sessions/").path + "/") else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = try? readMetadataLine { try handle.read(upToCount: $0) }
            try? handle.close()
            guard let data, let row = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
                  row["type"] as? String == "session_meta", let meta = row["payload"] as? JSONObject,
                  meta["source"] as? String == "cli", let id = meta["id"] as? String, !id.isEmpty else { continue }
            let db = home.appendingPathComponent("thread_history_1.sqlite").path
            if matches.insert(db + "\n" + id).inserted { locations.append(CodexThreadLocation(threadID: id, database: db)) }
        }
        guard locations.count == 1 else {
            throw AppError.message(locations.isEmpty ? "이 Codex 세션의 질문 기록을 찾지 못했습니다." : "여러 Codex 대화가 연결되어 질문 대기열을 확정할 수 없습니다.")
        }
        return locations[0]
    }

    /// Read a fresh, newline-terminated header, retaining the existing 1-MiB
    /// bound. Chunking stops at the first line instead of fetching scrollback.
    /// The injected read is also used by the real FileHandle path above.
    public static func readMetadataLine(_ read: (Int) throws -> Data?) throws -> Data? {
        let limit = 1_048_576
        var line = Data()
        while line.count < limit {
            let count = min(4096, limit - line.count)
            guard let chunk = try read(count), !chunk.isEmpty, chunk.count <= count else { return nil }
            if let end = chunk.firstIndex(of: 10) {
                line.append(contentsOf: chunk[..<end])
                return line
            }
            line.append(chunk)
        }
        return nil
    }

    public static func openFiles(_ output: String) -> [Int32: [String]] {
        var paths: [Int32: [String]] = [:], pid: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
            else if let pid, line.hasPrefix("n/") { paths[pid, default: []].append(String(line.dropFirst())) }
        }
        return paths
    }
}

/// Read-only support for the installed Codex 0.155 history projection. A changed or
/// missing schema fails visibly; no daemon is started and no Codex state is written.
public final class CodexHistoryReader {
    private struct CachedItem {
        let ordinal: Int64
        let projection: CodexQuestionProjection
    }
    private struct Delta {
        let itemID: String?
        let item: CachedItem?
        let projection: CodexQuestionProjection?
    }
    /// Separate the append and rewrite cursors so SQLite can use both covering
    /// ordinal indexes. The former OR predicate fell back to a thread-only
    /// search on large histories, even when the delta was empty.
    static let incrementalQuery = """
        SELECT item_id, rollout_ordinal, item_json, item_type FROM thread_items INDEXED BY idx_thread_items_page
        WHERE thread_id = ? AND rollout_ordinal >= ?
          AND (item_type = 'userMessage' OR (item_type = 'agentMessage' AND json_extract(item_json, '$.delivery') = 'async'))
        UNION ALL
        SELECT item_id, rollout_ordinal,
               -- The ID invalidates an old async question; the body is not needed.
               CASE WHEN item_type = 'agentMessage' AND json_type(item_json, '$') = 'object'
                      AND json_extract(item_json, '$.delivery') IS NOT 'async'
                    THEN NULL ELSE item_json END,
               item_type
        FROM thread_items INDEXED BY idx_thread_items_updated_page
        WHERE thread_id = ? AND updated_at_ordinal >= ? AND rollout_ordinal < ?
          -- Include edited agent rows even when an async question was changed
          -- into a synchronous message; otherwise the old cached question can
          -- remain pending forever because the JSON filter hides its rewrite.
          AND item_type IN ('userMessage', 'agentMessage')
        ORDER BY rollout_ordinal
        """
    private static let rebuildQuery = """
        SELECT item_id, rollout_ordinal, item_json, item_type FROM thread_items INDEXED BY idx_thread_items_page
        WHERE thread_id = ?
          AND (item_type = 'userMessage' OR (item_type = 'agentMessage' AND json_extract(item_json, '$.delivery') = 'async'))
        ORDER BY rollout_ordinal
        """
    private var cursor: Int64 = 0
    // User-message projections are applied incrementally or during a rare
    // replay; only async question rows need to remain in this cache.
    private var items: [String: CachedItem] = [:]
    private var seenQuestionIDs = Set<String>()
    // Track all relevant rows even when an ordinary user message is not retained.
    private var maxOrdinal = Int64.min
    private var location: CodexThreadLocation?
    private var pending: [QueuedQuestion] = []
    private var preparedDatabase: OpaquePointer?
    private var stateStatement: OpaquePointer?
    private var incrementalStatement: OpaquePointer?
    private var rebuildStatement: OpaquePointer?
#if DEBUG
    private(set) var debugPrepareCount = 0
#endif
#if DEBUG
    var cachedQuestionProjectionCount: Int { items.count }
#endif
    public init() {}
    deinit { finalizePreparedStatements() }

    private func finalizePreparedStatements() {
        if let stateStatement { sqlite3_finalize(stateStatement) }
        if let incrementalStatement { sqlite3_finalize(incrementalStatement) }
        if let rebuildStatement { sqlite3_finalize(rebuildStatement) }
        stateStatement = nil; incrementalStatement = nil; rebuildStatement = nil
        preparedDatabase = nil
    }

    func invalidatePreparedStatements() { finalizePreparedStatements() }

    func resetProjection() {
        finalizePreparedStatements()
        cursor = 0
        items.removeAll(keepingCapacity: false)
        seenQuestionIDs.removeAll(keepingCapacity: false)
        maxOrdinal = Int64.min
        location = nil
        pending.removeAll(keepingCapacity: false)
    }

    /// Change the statement owner before passing any stored statement slot as
    /// `inout`. Finalizing all slots from inside `prepare(_:slot:)` overlaps
    /// Swift's exclusive access to that slot and traps under runtime checks.
    private func prepareDatabase(_ database: OpaquePointer) {
        guard preparedDatabase != database else { return }
        finalizePreparedStatements()
        preparedDatabase = database
    }

    private func prepare(_ sql: String, slot: inout OpaquePointer?, database db: OpaquePointer,
                         threadID: String) throws -> OpaquePointer {
        if slot == nil {
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            guard result == SQLITE_OK, let statement else {
                throw CodexHistoryAccess.failure(db, subject: "질문", result: result)
            }
            slot = statement
#if DEBUG
            debugPrepareCount += 1
#endif
        } else if let statement = slot {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        guard let statement = slot else { throw CodexHistoryReadError(.invalidData, subject: "질문") }
        sqlite3_bind_text(statement, 1, threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return statement
    }

    public func read(_ location: CodexThreadLocation) throws -> [QueuedQuestion] {
        let db = try CodexHistoryAccess.open(location.database, subject: "질문")
        defer { sqlite3_close_v2(db) }
        return try read(location, database: db)
    }
    func read(_ location: CodexThreadLocation, database db: OpaquePointer) throws -> [QueuedQuestion] {
        let begin = sqlite3_exec(db, "BEGIN", nil, nil, nil)
        guard begin == SQLITE_OK else { throw CodexHistoryAccess.failure(db, subject: "질문", result: begin) }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        prepareDatabase(db)
        let state = try prepare("SELECT next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id = ?",
            slot: &stateStatement, database: db, threadID: location.threadID)
        defer { sqlite3_reset(state) }
        let stateResult = sqlite3_step(state)
        if stateResult == SQLITE_DONE { throw CodexHistoryReadError(.notReady, subject: "질문") }
        guard stateResult == SQLITE_ROW else { throw CodexHistoryAccess.failure(db, subject: "질문", result: stateResult) }
        let next = sqlite3_column_int64(state, 0)
        let reset = self.location != location || next < cursor
        let from: Int64 = reset ? 0 : cursor
        var resetItems: [String: CachedItem] = [:]
        var resetPending: [QueuedQuestion] = []
        var resetSeen = Set<String>()
        var deltas: [Delta] = []
        var nextMaxOrdinal = reset ? Int64.min : maxOrdinal
        var rebuild = false
        let statement: OpaquePointer
        if reset {
            statement = try prepare(Self.rebuildQuery, slot: &rebuildStatement, database: db, threadID: location.threadID)
        } else {
            statement = try prepare(Self.incrementalQuery, slot: &incrementalStatement, database: db, threadID: location.threadID)
        }
        defer { sqlite3_reset(statement) }
        if !reset {
            sqlite3_bind_int64(statement, 2, from)
            sqlite3_bind_text(statement, 3, location.threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(statement, 4, from)
            sqlite3_bind_int64(statement, 5, from)
        }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let (id, ordinal, value, omittedAgentMessage) = try autoreleasepool { () throws -> (String, Int64, CodexQuestionProjection?, Bool) in
                guard let rawID = sqlite3_column_text(statement, 0), let rawType = sqlite3_column_text(statement, 3) else {
                    throw CodexHistoryReadError(.invalidData, subject: "질문")
                }
                let itemType = String(cString: rawType)
                if sqlite3_column_type(statement, 2) == SQLITE_NULL, itemType == "agentMessage" {
                    // The SQL projection omits non-question agent bodies. The
                    // ID is enough to invalidate an earlier async question.
                    return (String(cString: rawID), sqlite3_column_int64(statement, 1), nil, true)
                }
                guard let raw = sqlite3_column_text(statement, 2) else {
                    throw CodexHistoryReadError(.invalidData, subject: "질문")
                }
                let bytes = Int(sqlite3_column_bytes(statement, 2))
                guard bytes > 0,
                      let json = try? JSONSerialization.jsonObject(with: Data(bytes: raw, count: bytes)) as? JSONObject else {
                    throw CodexHistoryReadError(.invalidData, subject: "질문")
                }
                return (String(cString: rawID), sqlite3_column_int64(statement, 1), CodexQuestionHistory.compactProjection(json), false)
            }
            let isNewTail = ordinal > nextMaxOrdinal
            nextMaxOrdinal = max(nextMaxOrdinal, ordinal)
            let previous = reset ? nil : items[id]
            if reset {
                if let value {
                    if value.isAsynchronous { resetItems[id] = CachedItem(ordinal: ordinal, projection: value) }
                    CodexQuestionHistory.apply(value, threadID: location.threadID, pending: &resetPending, seen: &resetSeen)
                }
            } else if omittedAgentMessage {
                if previous != nil { rebuild = true }
            } else if ordinal < from {
                // Ignore metadata-only rewrites of unchanged cached questions.
                // Old user messages are not cached, so their edits need replay.
                let unchangedQuestion: Bool
                if let value, value.isAsynchronous, let previous {
                    unchangedQuestion = previous.ordinal == ordinal && previous.projection == value
                } else { unchangedQuestion = false }
                if !unchangedQuestion { rebuild = true }
            } else if let value {
                if value.isAsynchronous {
                    let unchanged: Bool
                    if let previous { unchanged = previous.ordinal == ordinal && previous.projection == value }
                    else { unchanged = false }
                    if !unchanged {
                        if previous != nil || !isNewTail { rebuild = true }
                        else {
                            let item = CachedItem(ordinal: ordinal, projection: value)
                            deltas.append(Delta(itemID: id, item: item, projection: value))
                        }
                    }
                } else if previous != nil {
                    rebuild = true
                } else {
                    deltas.append(Delta(itemID: nil, item: nil, projection: value))
                }
            } else if previous != nil {
                rebuild = true
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CodexHistoryAccess.failure(db, subject: "질문", result: status) }

        if reset {
            items = resetItems; pending = resetPending; seenQuestionIDs = resetSeen
        } else if rebuild {
            let statement = try prepare(Self.rebuildQuery, slot: &rebuildStatement, database: db, threadID: location.threadID)
            defer { sqlite3_reset(statement) }
            var rebuiltItems: [String: CachedItem] = [:]
            var rebuiltPending: [QueuedQuestion] = []
            var rebuiltSeen = Set<String>()
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                let (id, ordinal, value) = try autoreleasepool { () throws -> (String, Int64, CodexQuestionProjection?) in
                    guard let rawID = sqlite3_column_text(statement, 0), let raw = sqlite3_column_text(statement, 2) else {
                        throw CodexHistoryReadError(.invalidData, subject: "질문")
                    }
                    let bytes = Int(sqlite3_column_bytes(statement, 2))
                    guard bytes > 0,
                          let json = try? JSONSerialization.jsonObject(with: Data(bytes: raw, count: bytes)) as? JSONObject else {
                        throw CodexHistoryReadError(.invalidData, subject: "질문")
                    }
                    return (String(cString: rawID), sqlite3_column_int64(statement, 1), CodexQuestionHistory.compactProjection(json))
                }
                if let value {
                    if value.isAsynchronous { rebuiltItems[id] = CachedItem(ordinal: ordinal, projection: value) }
                    CodexQuestionHistory.apply(value, threadID: location.threadID, pending: &rebuiltPending, seen: &rebuiltSeen)
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw CodexHistoryAccess.failure(db, subject: "질문", result: result) }
            items = rebuiltItems; pending = rebuiltPending; seenQuestionIDs = rebuiltSeen
        } else {
            for delta in deltas {
                if let id = delta.itemID, let item = delta.item { items[id] = item }
                if let projection = delta.projection {
                    CodexQuestionHistory.apply(projection, threadID: location.threadID, pending: &pending, seen: &seenQuestionIDs)
                }
            }
        }
        maxOrdinal = nextMaxOrdinal; cursor = next; self.location = location
        return pending
    }

}

public actor CodexQuestionCollector {
    private var readers: [String: CodexSessionHistoryReader] = [:]
    private let historyConnections = CodexHistoryConnectionCache(capacity: 4)
    private let fileReader: @Sendable (AgentSession, TimeInterval) throws -> [String]
    public init(fileReader: @escaping @Sendable (AgentSession, TimeInterval) throws -> [String] = {
        try ProcessOpenFiles.codexRolloutPaths(pid:$0.pid,expectedStart:$0.started,timeout:$1)
    }) { self.fileReader = fileReader }
    public func collect(_ sessions: [AgentSession]) -> [CodexQuestionUpdate] {
        let targets = sessions.filter { $0.agent == .codex && $0.phase != .ended }
        let liveIDs = Set(targets.map(\.id))
        readers = readers.filter { liveIDs.contains($0.key) }
        guard !targets.isEmpty else { historyConnections.closeAll(); return [] }
        // Share one bounded time budget across all process metadata reads.
        // Resolve exact open rollout paths before using the history connection.
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var locations = [String:CodexThreadLocation](), failures = [String:String]()
        for session in targets {
            do {
                let files = try fileReader(session,max(0,deadline-ProcessInfo.processInfo.systemUptime))
                locations[session.id] = try CodexThreadLocation.locate(paths:files)
            } catch { failures[session.id] = error.localizedDescription }
        }
        let activeDatabases = Set(locations.values.map(\.database))
        for reader in readers.values { reader.releaseConnection(unlessRetained: activeDatabases) }
        historyConnections.retain(paths: activeDatabases)
        let releaseOversubscribedConnections = activeDatabases.count > 4
        defer {
            if releaseOversubscribedConnections {
                // Per-session prepared statements pin SQLite handles. When
                // roots exceed the bounded connection cache, release them
                // after this serialized batch rather than retaining one
                // zombie connection per active session behind LRU eviction.
                for reader in readers.values { reader.releaseConnection(unlessRetained: []) }
                historyConnections.closeAll()
            }
        }
        var updates = [String:CodexQuestionUpdate]()
        for (id, error) in failures { updates[id] = CodexQuestionUpdate(sessionID:id,error:error) }
        let batches = Dictionary(grouping: locations, by: { $0.value.database })
        for (database, members) in batches {
            do {
                let connection = try historyConnections.open(database, subject: "질문")
                let dataVersion = try historyConnections.dataVersion(connection)
                for (id, location) in members {
                    let reader = readers[id] ?? CodexSessionHistoryReader()
                    readers[id] = reader
                    updates[id] = reader.read(sessionID:id, location:location, database:connection,
                        dataVersion:dataVersion, databaseIdentity:historyConnections.identity(for: database))
                }
            } catch {
                // Preserve each reader's independent error/recovery state if
                // the batch connection cannot be opened.
                for (id, location) in members {
                    let reader = readers[id] ?? CodexSessionHistoryReader()
                    readers[id] = reader
                    updates[id] = reader.read(sessionID:id, location:location)
                }
            }
        }
        return targets.map { updates[$0.id] ?? CodexQuestionUpdate(sessionID:$0.id, error:"Codex 질문 기록을 확인할 수 없습니다.") }
    }
}
