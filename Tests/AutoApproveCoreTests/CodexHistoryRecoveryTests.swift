import Foundation
import CSQLite
import AutoApproveCore

private final class HistoryFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-history-recovery-" + UUID().uuidString)
    var writer: OpaquePointer?
    var location: CodexThreadLocation { .init(threadID: "root", database: directory.appendingPathComponent("history.sqlite").path) }
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try expectEqual(sqlite3_open(location.database, &writer), SQLITE_OK)
        try sql("""
            PRAGMA journal_mode=DELETE;
            CREATE TABLE thread_history_projection_state(thread_id TEXT, next_rollout_ordinal INTEGER);
            CREATE TABLE thread_items(thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER, item_type TEXT, updated_at_ordinal INTEGER, item_json TEXT);
            CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, completed_at INTEGER, rollout_ordinal INTEGER, final_agent_item_id TEXT);
            INSERT INTO thread_history_projection_state VALUES('root',2);
            INSERT INTO thread_items VALUES('root','turn','q1',1,'agentMessage',1,'{"type":"agentMessage","id":"q1","delivery":"async","questions":[{"title":"첫 질문"}]}');
            INSERT INTO thread_turns VALUES('root','turn','inProgress',NULL,1,NULL);
            """)
    }
    deinit { sqlite3_close(writer); try? FileManager.default.removeItem(at: directory) }
    func sql(_ text: String) throws {
        let result = sqlite3_exec(writer, text, nil, nil, nil)
        try expectEqual(result, SQLITE_OK, String(cString: sqlite3_errmsg(writer)))
    }
    func readError<T>(_ operation: () throws -> T) throws -> CodexHistoryReadError {
        do { _ = try operation() }
        catch let error as CodexHistoryReadError { return error }
        throw AppError.message("Expected a classified Codex history error")
    }
}

extension ApprovalTests {
    func testCodexHistoryContentionAndRecovery() throws {
        let fixture = try HistoryFixture(), reader = CodexSessionHistoryReader()
        let engine = try ApprovalEngine(paths: AppPaths(directory: fixture.directory.appendingPathComponent("app")))
        var session = AgentSession(id: "process:42:fixture", agent: .codex, pid: 42, started: "fixture", tty: "/dev/fixture", cwd: "/tmp/project", terminal: .terminal)
        session.phase = .working
        engine.updateDiscovery([session], records: [])
        engine.updateCodexQuestions([reader.read(sessionID: session.id, location: fixture.location)])
        let before = engine.snapshot.sessions[0]
        var attention = AttentionTracker()
        let initialAlerts = attention.update(engine.snapshot)
        try expectEqual(before.questions.map(\.title), ["첫 질문"])

        try fixture.sql("BEGIN EXCLUSIVE;")
        defer { try? fixture.sql("ROLLBACK;") }
        let questionError = try fixture.readError { try CodexHistoryReader().read(fixture.location) }
        let turnError = try fixture.readError { try CodexTurnReader.read(fixture.location) }
        try expectEqual(questionError.kind, .temporary)
        try expectEqual(turnError.kind, .temporary)
        try expectEqual(turnError.sqliteCode, SQLITE_BUSY)
        // A write pending behind the lock must appear after recovery; failed reads
        // must not advance the question cursor or erase the last known snapshot.
        try fixture.sql("""
            INSERT INTO thread_items VALUES('root','turn','q2',2,'agentMessage',2,'{"type":"agentMessage","id":"q2","delivery":"async","questions":[{"title":"둘째 질문"}]}');
            UPDATE thread_history_projection_state SET next_rollout_ordinal=3;
            UPDATE thread_turns SET status='completed', completed_at=\(Date().timeIntervalSince1970);
            """)
        for attempt in 1...3 {
            let update = reader.read(sessionID: session.id, location: fixture.location)
            try expectNil(update.questions); try expectNil(update.turn)
            try expect(update.completionReadPending)
            if attempt < 3 {
                try expectNil(update.error); try expectNil(update.completionError)
            } else {
                try expect(update.error?.contains("갱신 중") == true)
                try expect(update.completionError?.contains("갱신 중") == true)
                try expectFalse(update.completionError?.contains("지원하지") == true)
            }
            engine.updateCodexQuestions([update])
            try expectEqual(engine.snapshot.sessions[0].questions, before.questions)
            try expectEqual(engine.snapshot.sessions[0].codexQuestionsObservedAt, before.codexQuestionsObservedAt)
            try expectEqual(engine.snapshot.sessions[0].phase, .working)
            try expectEqual(attention.update(engine.snapshot), initialAlerts)
            try expect(AttentionRequest.completions(engine.snapshot).isEmpty)
        }
        try fixture.sql("COMMIT;")
        let recovered = reader.read(sessionID: session.id, location: fixture.location)
        try expectNil(recovered.error); try expectNil(recovered.completionError)
        try expectFalse(recovered.completionReadPending)
        engine.updateCodexQuestions([recovered])
        try expectEqual(engine.snapshot.sessions[0].questions.map(\.title), ["첫 질문", "둘째 질문"])
        try expectEqual(AttentionRequest.completions(engine.snapshot).count, 1)
        engine.updateCodexQuestions([reader.read(sessionID: session.id, location: fixture.location)])
        try expectEqual(AttentionRequest.completions(engine.snapshot).count, 1)

        try fixture.sql("BEGIN EXCLUSIVE;")
        let brieflyUnavailable = reader.read(sessionID: session.id, location: fixture.location)
        try expectNil(brieflyUnavailable.error); try expectNil(brieflyUnavailable.completionError)
        engine.updateCodexQuestions([brieflyUnavailable])
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty, "Unknown state cannot deliver a pending completion")
        try fixture.sql("ROLLBACK;")
        engine.updateCodexQuestions([reader.read(sessionID: session.id, location: fixture.location)])
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty, "Recovery must not replay an already observed completion")

        try fixture.sql("""
            INSERT INTO thread_items VALUES('root','turn','answer',3,'userMessage',3,'{"type":"userMessage","content":[{"type":"text","text":"> 첫 질문\\n답변\\n> 둘째 질문\\n답변"}]}');
            UPDATE thread_history_projection_state SET next_rollout_ordinal=4;
            """)
        engine.updateCodexQuestions([reader.read(sessionID: session.id, location: fixture.location)])
        try expect(engine.snapshot.sessions[0].questions.isEmpty, "A successful empty queue must replace the preserved snapshot")
    }

    func testCodexHistoryFailureClassification() throws {
        let fixture = try HistoryFixture()
        let missing = CodexThreadLocation(threadID: "root", database: fixture.directory.appendingPathComponent("missing.sqlite").path)
        try expectEqual(try fixture.readError { try CodexTurnReader.read(missing) }.kind, .unavailable)
        try expectFalse(FileManager.default.fileExists(atPath: missing.database))
        try fixture.sql("DELETE FROM thread_history_projection_state;")
        try expectEqual(try fixture.readError { try CodexHistoryReader().read(fixture.location) }.kind, .notReady)
        try fixture.sql("INSERT INTO thread_history_projection_state VALUES('root',3); UPDATE thread_items SET item_type='userMessage',item_json='invalid JSON';")
        let malformed = try fixture.readError { try CodexHistoryReader().read(fixture.location) }
        try expectFalse(malformed.kind == .unsupportedSchema)
        try expectFalse(malformed.kind == .temporary)
        try fixture.sql("DROP TABLE thread_items;")
        try expectEqual(try fixture.readError { try CodexHistoryReader().read(fixture.location) }.kind, .unsupportedSchema)
        try expectEqual(try fixture.readError { try CodexTurnReader.read(fixture.location) }.kind, .unsupportedSchema)
    }

    func testCodexQuestionAndCompletionErrorsStayIndependent() throws {
        let fixture = try HistoryFixture(), reader = CodexSessionHistoryReader()
        try fixture.sql("DROP TABLE thread_turns;")
        var update = reader.read(sessionID: "fixture", location: fixture.location)
        try expectEqual(update.questions?.count, 1)
        try expectNil(update.error)
        try expect(update.completionError?.contains("지원하지") == true, "A real schema mismatch is visible immediately")
        try fixture.sql("CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, completed_at INTEGER, rollout_ordinal INTEGER, final_agent_item_id TEXT); DELETE FROM thread_history_projection_state;")
        update = reader.read(sessionID: "fixture", location: fixture.location)
        try expectNil(update.questions); try expectNil(update.error)
        try expectNotNil(update.turn); try expectNil(update.completionError)
        try expectFalse(update.completionReadPending)
    }
}
