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
public enum CodexQuestionHistory {
    public struct Item {
        public var ordinal: Int64
        public var json: JSONObject
        public init(ordinal: Int64, json: JSONObject) { self.ordinal = ordinal; self.json = json }
    }
    public static func pending(threadID: String, items: [Item]) -> [QueuedQuestion] {
        var pending: [QueuedQuestion] = []
        var seen = Set<String>()
        for row in items.sorted(by: { $0.ordinal < $1.ordinal }) {
            let item = row.json
            if item["type"] as? String == "agentMessage", item["delivery"] as? String == "async",
               let id = item["id"] as? String, !id.isEmpty, seen.insert(id).inserted,
               let questions = item["questions"] as? [JSONObject] {
                for (index, question) in questions.enumerated() {
                    guard let title = question["title"] as? String, !normalized(title).isEmpty else { continue }
                    pending.append(QueuedQuestion(id: "codex:\(threadID):\(id):\(index)", threadID: threadID,
                        title: title, options: question["options"] as? [String] ?? []))
                }
            } else if item["type"] as? String == "userMessage", let content = item["content"] as? [JSONObject] {
                let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                let quotes = answeredQuotes(text)
                if quotes.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    for index in pending.indices { pending[index].hasLaterUserMessage = true }
                }
                for quote in quotes {
                    let matches = pending.indices.filter { normalized(pending[$0].title) == quote }
                    // The transcript does not identify which copy was answered.
                    if matches.count == 1 { pending.remove(at: matches[0]) }
                }
            }
        }
        return pending
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
        var matches = Set<String>(), locations: [CodexThreadLocation] = []
        for path in Set(paths) {
            let url = URL(fileURLWithPath: path)
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
            let home = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            guard url.path.hasPrefix(home.appendingPathComponent("sessions/").path + "/") else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = try? handle.read(upToCount: 1_048_576)
            try? handle.close()
            guard let data, let newline = data.firstIndex(of: 10),
                  let row = try? JSONSerialization.jsonObject(with: data[..<newline]) as? JSONObject,
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
    private var cursor: Int64 = 0
    private var items: [String: CodexQuestionHistory.Item] = [:]
    private var location: CodexThreadLocation?
    public init() {}
    public func read(_ location: CodexThreadLocation) throws -> [QueuedQuestion] {
        let db = try CodexHistoryAccess.open(location.database, subject: "질문")
        defer { sqlite3_close(db) }
        let begin = sqlite3_exec(db, "BEGIN", nil, nil, nil)
        guard begin == SQLITE_OK else { throw CodexHistoryAccess.failure(db, subject: "질문", result: begin) }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        func prepare(_ sql: String) throws -> OpaquePointer? {
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            guard result == SQLITE_OK else { throw CodexHistoryAccess.failure(db, subject: "질문", result: result) }
            sqlite3_bind_text(statement, 1, location.threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            return statement
        }
        let state = try prepare("SELECT next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id = ?")
        defer { sqlite3_finalize(state) }
        let stateResult = sqlite3_step(state)
        if stateResult == SQLITE_DONE { throw CodexHistoryReadError(.notReady, subject: "질문") }
        guard stateResult == SQLITE_ROW else { throw CodexHistoryAccess.failure(db, subject: "질문", result: stateResult) }
        let next = sqlite3_column_int64(state, 0)
        let reset = self.location != location || next < cursor
        let from: Int64 = reset ? 0 : cursor
        var updated = reset ? [:] : items
        let statement = try prepare("""
            SELECT item_id, rollout_ordinal, item_json FROM thread_items
            WHERE thread_id = ? AND (rollout_ordinal >= ? OR updated_at_ordinal >= ?)
              AND (item_type = 'userMessage' OR (item_type = 'agentMessage' AND json_extract(item_json, '$.delivery') = 'async'))
            ORDER BY rollout_ordinal
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 2, from); sqlite3_bind_int64(statement, 3, from)
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let rawID = sqlite3_column_text(statement, 0), let raw = sqlite3_column_text(statement, 2),
                  let json = try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? JSONObject else {
                throw CodexHistoryReadError(.invalidData, subject: "질문")
            }
            updated[String(cString: rawID)] = CodexQuestionHistory.Item(ordinal: sqlite3_column_int64(statement, 1), json: json)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CodexHistoryAccess.failure(db, subject: "질문", result: status) }
        items = updated; cursor = next; self.location = location
        return CodexQuestionHistory.pending(threadID: location.threadID, items: Array(items.values))
    }
}

public actor CodexQuestionCollector {
    private var readers: [String: CodexSessionHistoryReader] = [:]
    public init() {}
    public func collect(_ sessions: [AgentSession]) -> [CodexQuestionUpdate] {
        let targets = sessions.filter { $0.agent == .codex && $0.phase != .ended }
        readers = readers.filter { key, _ in targets.contains { $0.id == key } }
        guard !targets.isEmpty else { return [] }
        let files: [Int32: [String]]
        do {
            let result = try CommandRunner.run("/usr/sbin/lsof", ["-nP", "-a", "-p", targets.map { String($0.pid) }.joined(separator: ","), "-Fpn"], timeout: 4)
            guard result.status == 0 || !result.output.isEmpty else { throw AppError.message("Codex 질문 기록 연결을 확인하지 못했습니다.") }
            files = CodexThreadLocation.openFiles(result.output)
        } catch { return targets.map { CodexQuestionUpdate(sessionID: $0.id, error: error.localizedDescription) } }
        return targets.map { session in
            do {
                let location = try CodexThreadLocation.locate(paths: files[session.pid] ?? [])
                let reader = readers[session.id] ?? CodexSessionHistoryReader()
                readers[session.id] = reader
                return reader.read(sessionID: session.id, location: location)
            } catch { return CodexQuestionUpdate(sessionID: session.id, error: error.localizedDescription) }
        }
    }
}
