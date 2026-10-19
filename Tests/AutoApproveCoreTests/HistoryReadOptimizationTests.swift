import Foundation
import Darwin
import CSQLite
import TerminalInputSupport
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif

private final class HistoryReadFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-history-read-" + UUID().uuidString)
    let filename: String
    var db: OpaquePointer?
    var path: String { root.appendingPathComponent(filename).path }
    init(filename: String = "history.sqlite") throws {
        self.filename = filename
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw AppError.message("Fixture database unavailable") }
        try sql("CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_ordinal INTEGER); CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,completed_at INTEGER,rollout_ordinal INTEGER,final_agent_item_id TEXT); CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,rollout_ordinal INTEGER,item_type TEXT NOT NULL,updated_at_ordinal INTEGER,item_json TEXT NOT NULL,turn_id TEXT); CREATE INDEX idx_thread_items_page ON thread_items(thread_id,rollout_ordinal); CREATE INDEX idx_thread_items_updated_page ON thread_items(thread_id,updated_at_ordinal); INSERT INTO thread_history_projection_state VALUES('root',2),('other',2);")
    }
    deinit { sqlite3_close(db); try? FileManager.default.removeItem(at: root) }
    func sql(_ sql: String) throws { try expectEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK) }
    func question(_ title: String, thread: String = "root", ordinal: Int = 1) throws {
        let json: JSONObject = ["type":"agentMessage","id":"q-\(ordinal)","delivery":"async","questions":[["title":title,"options":["First","Second"]]]]
        let value = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        try sql("INSERT INTO thread_items(thread_id,item_id,rollout_ordinal,item_type,updated_at_ordinal,item_json) VALUES('\(thread)','q-\(ordinal)',\(ordinal),'agentMessage',\(ordinal),'\(value)');")
    }
}

extension ApprovalTests {
#if DEBUG
    func testCodexHistoryConnectionsAreReusedAndBounded() throws {
        let firstFixture = try HistoryReadFixture()
        let secondFixture = try HistoryReadFixture(filename: "second.sqlite")
        let cache = CodexHistoryConnectionCache(capacity: 1)
        let first = try cache.open(firstFixture.path, subject: "질문")
        let reused = try cache.open(firstFixture.path, subject: "질문")
        try expectEqual(first, reused, "Repeated polls reuse the same read-only SQLite connection")
        try expectEqual(cache.connectionCount, 1)
        _ = try cache.open(secondFixture.path, subject: "질문")
        try expectEqual(cache.connectionCount, 1, "The connection cache stays within its configured bound")
        cache.retain(paths: [])
        try expectEqual(cache.connectionCount, 0, "Inactive database connections are released")
    }

    func testUnchangedDatabaseVersionSkipsSessionHistoryQueriesAndExternalCommitInvalidatesIt() throws {
        let fixture = try HistoryReadFixture(), cache = CodexHistoryConnectionCache(capacity: 1)
        try fixture.question("Choose", ordinal: 1)
        let location = CodexThreadLocation(threadID: "root", database: fixture.path)
        let connection = try cache.open(fixture.path, subject: "질문")
        let firstVersion = try cache.dataVersion(connection)
        let reader = CodexSessionHistoryReader()
        let first = reader.read(sessionID: "session", location: location, database: connection, dataVersion: firstVersion)
        try expectEqual(first.questions?.first?.title, "Choose")

        let unchangedVersion = try cache.dataVersion(connection)
        try expectEqual(unchangedVersion, firstVersion, "An unchanged database keeps its connection-local data version")
        let unchanged = reader.read(sessionID: "session", location: location, database: connection, dataVersion: unchangedVersion)
        try expectEqual(unchanged.questions?.first?.title, "Choose")
        try expectEqual(reader.debugDataVersionSkipCount, 1, "The cached question and completion projections avoid unchanged DB reads")

        try fixture.sql("INSERT INTO thread_items(thread_id,item_id,rollout_ordinal,item_type,updated_at_ordinal,item_json) VALUES('root','user-2',2,'userMessage',2,'{\"type\":\"userMessage\",\"content\":[{\"type\":\"text\",\"text\":\"ordinary\"}]}'); UPDATE thread_history_projection_state SET next_rollout_ordinal=3 WHERE thread_id='root';")
        let changedVersion = try cache.dataVersion(connection)
        try expect(changedVersion != unchangedVersion, "A commit from another SQLite connection changes data_version")
        let changed = reader.read(sessionID: "session", location: location, database: connection, dataVersion: changedVersion)
        try expectEqual(changed.questions?.first?.hasLaterUserMessage, true, "A database commit invalidates the cached session projection")
        try expectEqual(reader.debugDataVersionSkipCount, 1, "Changed databases must take the incremental query path")
    }

    func testCodexHistoryConnectionCacheReopensReplacedDatabase() throws {
        let fixture = try HistoryReadFixture()
        let cache = CodexHistoryConnectionCache(capacity: 1)
        _ = try cache.open(fixture.path, subject: "질문")
        let oldIdentity = try CodexHistoryAccess.fileIdentity(fixture.path, subject: "질문")

        let replacement = fixture.root.appendingPathComponent("replacement.sqlite")
        var replacementDB: OpaquePointer?
        try expectEqual(sqlite3_open(replacement.path, &replacementDB), SQLITE_OK)
        defer { sqlite3_close(replacementDB) }
        try expectEqual(sqlite3_exec(replacementDB, "CREATE TABLE replacement(value INTEGER); INSERT INTO replacement VALUES(7)", nil, nil, nil), SQLITE_OK)

        let backup = fixture.root.appendingPathComponent("old.sqlite")
        try FileManager.default.moveItem(atPath: fixture.path, toPath: backup.path)
        try FileManager.default.moveItem(at: replacement, to: URL(fileURLWithPath: fixture.path))
        let newIdentity = try CodexHistoryAccess.fileIdentity(fixture.path, subject: "질문")
        try expect(oldIdentity != newIdentity, "Replacing a database path changes the tracked file identity")

        let reopened = try cache.open(fixture.path, subject: "질문")
        var statement: OpaquePointer?
        try expectEqual(sqlite3_prepare_v2(reopened, "SELECT value FROM replacement", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement); cache.closeAll() }
        try expectEqual(sqlite3_step(statement), SQLITE_ROW, "The cache must point at the replacement database")
        try expectEqual(sqlite3_column_int(statement, 0), 7)
    }

    func testSessionHistoryProjectionRebuildsWhenDatabaseFileIsReplaced() throws {
        let fixture = try HistoryReadFixture()
        try fixture.question("Original")
        let location = CodexThreadLocation(threadID: "root", database: fixture.path)
        let cache = CodexHistoryConnectionCache(capacity: 1)
        let reader = CodexSessionHistoryReader()
        let original = try cache.open(fixture.path, subject: "질문")
        let originalVersion = try cache.dataVersion(original)
        try expectEqual(reader.read(sessionID: "session", location: location, database: original,
            dataVersion: originalVersion, databaseIdentity: cache.identity(for: fixture.path))
            .questions?.first?.title, "Original")

        let replacement = fixture.root.appendingPathComponent("replacement-history.sqlite")
        var replacementDB: OpaquePointer?
        try expectEqual(sqlite3_open(replacement.path, &replacementDB), SQLITE_OK)
        let replacementJSON = "{\"type\":\"agentMessage\",\"id\":\"q-1\",\"delivery\":\"async\",\"questions\":[{\"title\":\"Replacement\"}]}"
        let create = """
            CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_ordinal INTEGER);
            CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,completed_at INTEGER,rollout_ordinal INTEGER,final_agent_item_id TEXT);
            CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,rollout_ordinal INTEGER,item_type TEXT NOT NULL,updated_at_ordinal INTEGER,item_json TEXT NOT NULL,turn_id TEXT);
            CREATE INDEX idx_thread_items_page ON thread_items(thread_id,rollout_ordinal);
            CREATE INDEX idx_thread_items_updated_page ON thread_items(thread_id,updated_at_ordinal);
            INSERT INTO thread_history_projection_state VALUES('root',2);
            INSERT INTO thread_items(thread_id,item_id,rollout_ordinal,item_type,updated_at_ordinal,item_json) VALUES('root','q-1',1,'agentMessage',1,'\(replacementJSON)');
            """
        try expectEqual(sqlite3_exec(replacementDB, create, nil, nil, nil), SQLITE_OK)
        try expectEqual(sqlite3_close(replacementDB), SQLITE_OK)
        replacementDB = nil

        let backup = fixture.root.appendingPathComponent("original-history.sqlite")
        try FileManager.default.moveItem(atPath: fixture.path, toPath: backup.path)
        try FileManager.default.moveItem(at: replacement, to: URL(fileURLWithPath: fixture.path))
        let reopened = try cache.open(fixture.path, subject: "질문")
        let reopenedVersion = try cache.dataVersion(reopened)
        try expectEqual(reopenedVersion, originalVersion, "A replacement can start with the same SQLite data_version")
        try expectEqual(reader.read(sessionID: "session", location: location, database: reopened,
            dataVersion: reopenedVersion, databaseIdentity: cache.identity(for: fixture.path))
            .questions?.first?.title, "Replacement", "A replaced history must not reuse the old question projection")
        cache.closeAll()
    }

    func testHistoryStatementsArePreparedOncePerReusedConnection() throws {
        let fixture = try HistoryReadFixture(), cache = CodexHistoryConnectionCache(capacity: 1)
        try fixture.question("Choose")
        let location = CodexThreadLocation(threadID: "root", database: fixture.path)
        let reader = CodexHistoryReader(), connection = try cache.open(fixture.path, subject: "질문")
        try expectEqual(try reader.read(location, database: connection).count, 1)
        try expectEqual(reader.debugPrepareCount, 2, "The initial history snapshot prepares the state and rebuild statements")
        try expectEqual(try reader.read(location, database: connection).count, 1)
        try expectEqual(reader.debugPrepareCount, 3, "The first incremental read prepares one reusable delta statement")
        try expectEqual(try reader.read(location, database: connection).count, 1)
        try expectEqual(reader.debugPrepareCount, 3, "Subsequent unchanged reads reuse all three prepared statements")
    }

    func testSessionHistoryReaderReleasesStatementsForInactiveDatabase() throws {
        let fixture = try HistoryReadFixture(), reader = CodexSessionHistoryReader()
        try fixture.question("Choose")
        let location = CodexThreadLocation(threadID: "root", database: fixture.path)
        try expectEqual(reader.read(sessionID: "session", location: location).questions?.count, 1)
        reader.releaseConnection(unlessRetained: [])
        try expectEqual(reader.read(sessionID: "session", location: location).questions?.count, 1,
            "Releasing inactive DB statements must leave the question projection ready to reopen")
    }
#endif

#if DEBUG
    func testOrdinaryCodexMessageProjectionDiscardsLongTextAndRetainsSplitQuotes() throws {
        let ordinary: JSONObject = ["type":"userMessage", "content":[["type":"text", "text":String(repeating:"ordinary message ", count:20_000)]]]
        try expectEqual(CodexQuestionHistory.compactProjection(ordinary), CodexQuestionProjection(kind: .userMessage(answers: [])))
        let quoted: JSONObject = ["type":"userMessage", "content":[
            ["type":"text", "text":" \n"], ["type":"text", "text":"> Choose a route?\n"], ["type":"text", "text":"Local" ]
        ]]
        try expectEqual(CodexQuestionHistory.compactProjection(quoted), CodexQuestionProjection(kind: .userMessage(answers: ["Choose a route?"])))
        try expectNil(CodexQuestionHistory.compactProjection(["type":"userMessage", "content":[["type":"text", "text":" \n\t"]]]))
    }
#endif

#if DEBUG
    func testIncrementalHistoryQueryUsesAppendAndRewriteIndexes() throws {
        let fixture = try HistoryReadFixture()
        var statement: OpaquePointer?
        let sql = "EXPLAIN QUERY PLAN " + CodexHistoryReader.incrementalQuery
        try expectEqual(sqlite3_prepare_v2(fixture.db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        for (index, value) in [(1, "root"), (3, "root")] {
            sqlite3_bind_text(statement, Int32(index), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_int64(statement, 2, 100)
        sqlite3_bind_int64(statement, 4, 100)
        sqlite3_bind_int64(statement, 5, 100)
        var plan: [String] = [], result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let detail = sqlite3_column_text(statement, 3) { plan.append(String(cString: detail)) }
            result = sqlite3_step(statement)
        }
        try expectEqual(result, SQLITE_DONE)
        try expect(plan.contains(where: { $0.contains("idx_thread_items_page") && $0.contains("rollout_ordinal>?") }),
            "Append lookup must seek to the rollout cursor instead of scanning the whole thread:\n" + plan.joined(separator: "\n"))
        try expect(plan.contains(where: { $0.contains("idx_thread_items_updated_page") && $0.contains("updated_at_ordinal>?") }),
            "Rewrite lookup must seek to the update cursor instead of scanning the whole thread:\n" + plan.joined(separator: "\n"))

        try fixture.sql("INSERT INTO thread_items(thread_id,item_id,rollout_ordinal,item_type,updated_at_ordinal,item_json) VALUES('root','both-cursors',100,'userMessage',100,'{\"type\":\"userMessage\",\"content\":[]}');")
        var queryValue: OpaquePointer?
        let prepared = CodexHistoryReader.incrementalQuery.withCString {
            sqlite3_prepare_v2(fixture.db, $0, -1, &queryValue, nil)
        }
        guard prepared == SQLITE_OK, let query = queryValue else { throw AppError.message("Incremental query unavailable") }
        defer { sqlite3_finalize(query) }
        for (index, value) in [(1, "root"), (3, "root")] {
            sqlite3_bind_text(query, Int32(index), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_int64(query, 2, 100); sqlite3_bind_int64(query, 4, 100); sqlite3_bind_int64(query, 5, 100)
        try expectEqual(sqlite3_step(query), SQLITE_ROW)
        guard let resultID = sqlite3_column_text(query, 0) else { throw AppError.message("Incremental query returned an empty ID") }
        try expectEqual(String(cString: resultID), "both-cursors")
        try expectEqual(sqlite3_step(query), SQLITE_DONE, "A new row covered by both cursors is returned once")
    }

    func testUnchangedHistoryQueryCostDoesNotScaleWithThreadRows() throws {
        let fixture = try HistoryReadFixture()
        let rowCount = 60_000
        try fixture.sql("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<\(rowCount)) INSERT INTO thread_items(thread_id,item_id,rollout_ordinal,item_type,updated_at_ordinal,item_json) SELECT 'root','sync-'||x,x,'agentMessage',x,'{\"type\":\"agentMessage\",\"delivery\":\"sync\",\"text\":\"synthetic\"}' FROM n; UPDATE thread_history_projection_state SET next_rollout_ordinal=\(rowCount + 1) WHERE thread_id='root';")
        let oldSQL = """
            SELECT item_id, rollout_ordinal, item_json FROM thread_items
            WHERE thread_id = ? AND (rollout_ordinal >= ? OR updated_at_ordinal >= ?)
              AND (item_type = 'userMessage' OR (item_type = 'agentMessage'
                AND json_extract(item_json, '$.delivery') = 'async'))
            ORDER BY rollout_ordinal
            """
        var oldStatement: OpaquePointer?, newStatement: OpaquePointer?
        try expectEqual(sqlite3_prepare_v2(fixture.db, oldSQL, -1, &oldStatement, nil), SQLITE_OK)
        try expectEqual(sqlite3_prepare_v2(fixture.db, CodexHistoryReader.incrementalQuery, -1, &newStatement, nil), SQLITE_OK)
        defer { sqlite3_finalize(oldStatement); sqlite3_finalize(newStatement) }

        func elapsed(_ statement: OpaquePointer, bind: () -> Void) throws -> UInt64 {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement); bind()
            let start = DispatchTime.now().uptimeNanoseconds
            var result = sqlite3_step(statement), rows = 0
            while result == SQLITE_ROW { rows += 1; result = sqlite3_step(statement) }
            let duration = DispatchTime.now().uptimeNanoseconds - start
            try expectEqual(result, SQLITE_DONE)
            try expectEqual(rows, 0, "An unchanged cursor must produce no deltas")
            return duration
        }
        func text(_ statement: OpaquePointer, _ index: Int32) {
            sqlite3_bind_text(statement, index, "root", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        func oldBind() { text(oldStatement!, 1); sqlite3_bind_int64(oldStatement!, 2, Int64(rowCount + 1)); sqlite3_bind_int64(oldStatement!, 3, Int64(rowCount + 1)) }
        func newBind() {
            text(newStatement!, 1); sqlite3_bind_int64(newStatement!, 2, Int64(rowCount + 1))
            text(newStatement!, 3); sqlite3_bind_int64(newStatement!, 4, Int64(rowCount + 1)); sqlite3_bind_int64(newStatement!, 5, Int64(rowCount + 1))
        }
        for _ in 0..<3 { _ = try elapsed(oldStatement!, bind: oldBind); _ = try elapsed(newStatement!, bind: newBind) }
        var oldSamples = [UInt64](), newSamples = [UInt64]()
        for _ in 0..<20 {
            oldSamples.append(try elapsed(oldStatement!, bind: oldBind))
            newSamples.append(try elapsed(newStatement!, bind: newBind))
        }
        oldSamples.sort(); newSamples.sort()
        print("METRIC unchanged-history-query rows=\(rowCount) old-median=\(oldSamples[10])ns indexed-delta-median=\(newSamples[10])ns")
        try expect(newSamples[10] < oldSamples[10], "An unchanged delta lookup should be faster than rescanning all prior thread rows")
    }

    func testIncrementalHistoryQueryOmitsSynchronousAgentBodies() throws {
        let fixture = try HistoryReadFixture()
        let body = "{\"type\":\"agentMessage\",\"delivery\":\"sync\",\"text\":\"\(String(repeating: "x", count: 65_536))\"}"
            .replacingOccurrences(of: "'", with: "''")
        try fixture.sql("INSERT INTO thread_items(thread_id,item_id,rollout_ordinal,item_type,updated_at_ordinal,item_json) VALUES('root','old-agent',1,'agentMessage',100,'\(body)');")
        var query: OpaquePointer?
        try expectEqual(sqlite3_prepare_v2(fixture.db, CodexHistoryReader.incrementalQuery, -1, &query, nil), SQLITE_OK)
        defer { sqlite3_finalize(query) }
        for (index, value) in [(1, "root"), (3, "root")] {
            sqlite3_bind_text(query, Int32(index), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_int64(query, 2, 100); sqlite3_bind_int64(query, 4, 100); sqlite3_bind_int64(query, 5, 100)
        try expectEqual(sqlite3_step(query), SQLITE_ROW)
        guard let itemID = sqlite3_column_text(query, 0), let itemType = sqlite3_column_text(query, 3) else {
            throw AppError.message("Updated agent row omitted its identity")
        }
        try expectEqual(String(cString: itemID), "old-agent")
        try expectEqual(String(cString: itemType), "agentMessage")
        try expectEqual(sqlite3_column_type(query, 2), SQLITE_NULL,
            "A synchronous agent rewrite only needs its ID to invalidate a cached question")
        try expectEqual(sqlite3_step(query), SQLITE_DONE)
    }

    func testHistoryCacheRetainsQuestionsNotOrdinaryMessagesAndReplaysOldEdits() throws {
        let fixture = try HistoryReadFixture(), reader = CodexHistoryReader()
        let location = CodexThreadLocation(threadID: "root", database: fixture.path)
        try fixture.question("Choose", ordinal: 1)
        try fixture.sql("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100) INSERT INTO thread_items(thread_id,item_id,rollout_ordinal,item_type,updated_at_ordinal,item_json) SELECT 'root','user-'||x,x+1,'userMessage',x+1,'{\"type\":\"userMessage\",\"content\":[{\"type\":\"text\",\"text\":\"ordinary\"}]}' FROM n; UPDATE thread_history_projection_state SET next_rollout_ordinal=102 WHERE thread_id='root';")

        let pending = try reader.read(location)
        try expectEqual(pending.first?.hasLaterUserMessage, true)
        try expectEqual(reader.cachedQuestionProjectionCount, 1, "One hundred ordinary messages are processed but not retained")

        try fixture.sql("UPDATE thread_items SET item_json='{\"type\":\"userMessage\",\"content\":[{\"type\":\"text\",\"text\":\"> Choose\\nAnswer\"}]}',updated_at_ordinal=102 WHERE item_id='user-1';")
        try expect(try reader.read(location).isEmpty, "An old user-message rewrite must replay the history and apply its quoted answer")
        try expectEqual(reader.cachedQuestionProjectionCount, 1, "The rebuilt cache still contains only the async question row")
    }

    func testRewriteFromAsyncQuestionToSynchronousAgentMessageClearsPendingQuestion() throws {
        let fixture = try HistoryReadFixture(), reader = CodexHistoryReader()
        let location = CodexThreadLocation(threadID: "root", database: fixture.path)
        try fixture.question("Choose", ordinal: 1)
        try expectEqual(try reader.read(location).count, 1)
        try fixture.sql("UPDATE thread_items SET item_json=replace(item_json,'async','sync'),updated_at_ordinal=2 WHERE item_id='q-1';")

        try expect(try reader.read(location).isEmpty,
            "An updated agent row must invalidate a cached question even after delivery changes from async")
    }
#endif

    func testCodexCollectorIsolatesFileFailuresAndFollowsCurrentRollout() async throws {
        let fixture = try HistoryReadFixture(filename:"thread_history_1.sqlite")
        try fixture.question("First live question");try fixture.question("Other live question",thread:"other")
        let day = fixture.root.appendingPathComponent("sessions/2026/10/15")
        try FileManager.default.createDirectory(at:day,withIntermediateDirectories:true)
        let file = day.appendingPathComponent("rollout-fixture.jsonl")
        let otherFile = day.appendingPathComponent("rollout-other.jsonl")
        func select(_ id: String, at url: URL) throws {
            var data = try JSONSerialization.data(withJSONObject:["type":"session_meta","payload":["source":"cli","id":id]])
            data.append(10);try data.write(to:url)
        }
        try select("root", at:file);try select("other", at:otherFile)
        let held = try FileHandle(forReadingFrom:file)
        defer { try? held.close() }
        let collector = CodexQuestionCollector(fileReader:{ session, timeout in
            if session.id == "failed" { throw POSIXError(.EPERM) }
            if session.id == "other" { return [otherFile.path] }
            return try ProcessOpenFiles.paths(pid:session.pid,expectedStart:session.started,timeout:timeout)
        })
        let start = try TTYInputIdentity.capture(pid:getpid()).processStart
        let good = AgentSession(id:"good",agent:.codex,pid:getpid(),started:start,tty:"/dev/fixture",cwd:fixture.root.path,terminal:.terminal)
        var other = good;other.id = "other"
        var failed = good;failed.id = "failed";failed.pid = 43
        var updates = await collector.collect([failed,good,other])
        try expectNotNil(updates.first(where:{$0.sessionID == failed.id})?.error)
        try expectNil(updates.first(where:{$0.sessionID == good.id})?.error)
        try expectEqual(updates.first(where:{$0.sessionID == good.id})?.questions?.first?.title,"First live question","One denied/closed process cannot hide another process's questions")
        try expectEqual(updates.first(where:{$0.sessionID == other.id})?.questions?.first?.title,"Other live question","Readers for separate threads can share one history connection")
        try select("other", at:file)
        updates = await collector.collect([good,other,failed])
        try expectEqual(updates.first(where:{$0.sessionID == good.id})?.threadID,"other")
        try expectEqual(updates.first(where:{$0.sessionID == good.id})?.questions?.first?.title,"Other live question","The same process path must resolve its current conversation every time")
    }

    func testCodexCollectorReleasesOversubscribedHistoryConnectionsBetweenBatches() async throws {
        let fixtures = try (0..<5).map { _ in try HistoryReadFixture(filename: "thread_history_1.sqlite") }
        var rolloutPaths: [String: String] = [:]
        var sessions: [AgentSession] = []
        for (index, fixture) in fixtures.enumerated() {
            try fixture.question("Question \(index)")
            let day = fixture.root.appendingPathComponent("sessions/2026/10/15")
            try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
            let rollout = day.appendingPathComponent("rollout-\(index).jsonl")
            var header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["source": "cli", "id": "root"]])
            header.append(10); try header.write(to: rollout)
            let id = "session-\(index)"
            rolloutPaths[id] = rollout.path
            sessions.append(AgentSession(id: id, agent: .codex, pid: Int32(9000 + index), started: "fixture-\(index)",
                tty: "/dev/fixture-\(index)", cwd: fixture.root.path, terminal: .terminal))
        }
        let immutableRolloutPaths = rolloutPaths
        let collector = CodexQuestionCollector(fileReader: { session, _ in immutableRolloutPaths[session.id].map { [$0] } ?? [] })
        for _ in 0..<2 {
            let updates = await collector.collect(sessions)
            try expectEqual(updates.filter { $0.error == nil && $0.questions?.count == 1 }.count, 5,
                "Five roots exceed the four-connection cache but each batch must still return its question")
        }
    }

    func testCodexCollectorRebuildsProjectionAfterHistoryFileReplacement() async throws {
        let fixture = try HistoryReadFixture(filename: "thread_history_1.sqlite")
        try fixture.question("Original")
        let day = fixture.root.appendingPathComponent("sessions/2026/10/15")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-fixture.jsonl")
        var header = try JSONSerialization.data(withJSONObject: ["type":"session_meta", "payload":["source":"cli", "id":"root"]])
        header.append(10); try header.write(to: rollout)
        let collector = CodexQuestionCollector(fileReader: { _, _ in [rollout.path] })
        let session = AgentSession(id:"session", agent:.codex, pid:42, started:"fixture", tty:"/dev/fixture", cwd:fixture.root.path, terminal:.terminal)
        let first = await collector.collect([session])
        try expectEqual(first.first?.questions?.first?.title, "Original", first.first?.error ?? "Initial collector read returned no question and no error")

        let replacement = fixture.root.appendingPathComponent("replacement.sqlite")
        try FileManager.default.copyItem(atPath: fixture.path, toPath: replacement.path)
        var database: OpaquePointer?
        try expectEqual(sqlite3_open(replacement.path, &database), SQLITE_OK)
        try expectEqual(sqlite3_exec(database, "UPDATE thread_items SET item_json=replace(item_json,'Original','Replacement') WHERE item_id='q-1'", nil, nil, nil), SQLITE_OK)
        try expectEqual(sqlite3_close(database), SQLITE_OK)
        database = nil
        try expectEqual(sqlite3_close(fixture.db), SQLITE_OK)
        fixture.db = nil
        let original = fixture.root.appendingPathComponent("original.sqlite")
        try FileManager.default.moveItem(atPath: fixture.path, toPath: original.path)
        try FileManager.default.moveItem(at: replacement, to: URL(fileURLWithPath: fixture.path))

        let second = await collector.collect([session])
        try expectEqual(second.first?.questions?.first?.title, "Replacement",
            "The collector must pass the replacement file identity even if SQLite data_version is unchanged")
    }

    func testRolloutHeaderStopsAtFirstLineAndKeepsByteLimit() throws {
        let header = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"fixture\",\"source\":\"cli\"}}".utf8)
        let bytes = header + Data([10]) + Data(repeating: 120, count: 2_097_152)
        var offset = 0, calls = 0
        let actual = try CodexThreadLocation.readMetadataLine { count in
            calls += 1; let end = min(offset + count, bytes.count)
            defer { offset = end }; return bytes.subdata(in: offset..<end)
        }
        try expectEqual(actual, header); try expectEqual(calls, 1); try expectEqual(offset, 4096)
        let unicode = Data((String(repeating: "한글😀", count: 900) + "\r\nignored").utf8)
        var position = 0
        let long = try CodexThreadLocation.readMetadataLine { count in
            let end = min(position + count, unicode.count)
            defer { position = end }; return unicode.subdata(in: position..<end)
        }
        try expectEqual(long, Data(unicode.prefix { $0 != 10 }), "A split UTF-8 character and CR are retained byte-for-byte")
        let limit = 1_048_576
        for newline in [limit - 1, limit] {
            let source = Data(repeating: 120, count: newline) + Data([10])
            var consumed = 0
            let line = try CodexThreadLocation.readMetadataLine { count in
                try expect(consumed + count <= limit)
                let end = min(consumed + count, source.count)
                defer { consumed = end }; return source.subdata(in: consumed..<end)
            }
            try expectEqual(line?.count, newline == limit - 1 ? limit - 1 : nil)
            try expectEqual(consumed, limit)
        }
        try expectNil(try CodexThreadLocation.readMetadataLine { _ in nil })
        try expectNil(try CodexThreadLocation.readMetadataLine { _ in Data() })
        try expectNil(try CodexThreadLocation.readMetadataLine { count in Data(repeating: 120, count: count + 1) })
        try expectThrows(try CodexThreadLocation.readMetadataLine { _ in throw AppError.message("fixture read failure") })
    }

    func testRolloutBindingReadsFreshLongMetadataAndRejectsIncompleteHeaders() throws {
        let fixture = try HistoryReadFixture(), day = fixture.root.appendingPathComponent("sessions/2026/10/15")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-fixture.jsonl")
        func write(_ id: String, newline: Bool = true) throws {
            var data = try JSONSerialization.data(withJSONObject: ["type":"session_meta","payload":["id":id,"source":"cli","extra":String(repeating:"한글",count:1500)]])
            if newline { data.append(10); data.append(Data(repeating: 120, count: 1_048_576)) }
            try data.write(to: file)
        }
        try write("first"); try expectEqual(try CodexThreadLocation.locate(paths: [file.path]).threadID, "first")
        try write("second"); try expectEqual(try CodexThreadLocation.locate(paths: [file.path]).threadID, "second", "Never reuse a previous thread identity")
        try write("incomplete", newline: false); try expectThrows(try CodexThreadLocation.locate(paths: [file.path]))
        try Data([0xff, 10]).write(to: file); try expectThrows(try CodexThreadLocation.locate(paths: [file.path]))
    }

    func testUnchangedHistoryStillChecksUpdatesResetsAndFailures() throws {
        let fixture = try HistoryReadFixture(), reader = CodexHistoryReader()
        let root = CodexThreadLocation(threadID: "root", database: fixture.path), other = CodexThreadLocation(threadID: "other", database: fixture.path)
        try fixture.question("First question"); try fixture.question("Other thread", thread: "other")
        var copy = try reader.read(root); copy[0].title = "Caller edit"
        for _ in 0..<3 { try expectEqual(try reader.read(root).first?.title, "First question") }
        try fixture.sql("UPDATE thread_items SET item_json=replace(item_json,'First question','Updated question'),updated_at_ordinal=2 WHERE thread_id='root'; UPDATE thread_history_projection_state SET next_rollout_ordinal=3 WHERE thread_id='root';")
        try expectEqual(try reader.read(root).first?.title, "Updated question", "An old row's update invalidates the projection")
        try fixture.sql("INSERT INTO thread_items(thread_id,item_id,rollout_ordinal,item_type,updated_at_ordinal,item_json) VALUES('root','answer',3,'userMessage',3,'{\"type\":\"userMessage\",\"content\":[{\"type\":\"text\",\"text\":\"> Updated question\\nFirst\"}]}'); UPDATE thread_history_projection_state SET next_rollout_ordinal=4 WHERE thread_id='root';")
        try expect(try reader.read(root).isEmpty)
        try expectEqual(try reader.read(other).first?.title, "Other thread")
        try expect(try reader.read(root).isEmpty, "A thread switch cannot reuse the other thread's questions")
        try fixture.sql("INSERT INTO thread_items(thread_id,item_id,rollout_ordinal,item_type,updated_at_ordinal,item_json) VALUES('root','q-4',4,'agentMessage',4,'invalid JSON'); UPDATE thread_history_projection_state SET next_rollout_ordinal=5 WHERE thread_id='root';")
        try expectThrows(try reader.read(root))
        try fixture.sql("DELETE FROM thread_items WHERE item_id='q-4';")
        try fixture.question("After recovery", ordinal: 4)
        try expectEqual(try reader.read(root).first?.title, "After recovery", "A failed delta must not advance the cursor or cached result")
        try fixture.sql("DELETE FROM thread_items WHERE thread_id='root'; UPDATE thread_history_projection_state SET next_rollout_ordinal=1 WHERE thread_id='root';")
        try fixture.question("After reset", ordinal: 0)
        try expectEqual(try reader.read(root).first?.title, "After reset")
        try fixture.sql("DROP TABLE thread_items;")
        try expectThrows(try reader.read(root))
    }

    func testSystemRiskLazyVariantsRetainWhitespaceUnicodeAndFreshSource() throws {
        for separator in ["", "\n", "\n  ", "\r\n", "\t", "\u{00a0}", "\u{2007}"] {
            let text = "cp fixture ~/Library/Lau" + separator + "nchAgents/com.fixture.plist"
            try expectEqual(SystemCommandRisk.detect(text)?.kind, .persistence, text)
        }
        for text in ["cp fixture ~/Library/LaunchAgents/a.plist", "cp fixture ~/ Library / LaunchAgents /a.plist",
            "python3 -c 'Path.home().joinpath(\"Library/LaunchAgents/a.plist\").write_text(payload)'",
            "cp fixture /Users/한글/Library/LaunchAgents/a.plist"] {
            try expectEqual(SystemCommandRisk.detect(text)?.kind, .persistence)
        }
        try expectNil(SystemCommandRisk.detect("cat ~/Library/LaunchAgents/a.plist"))
        try expectNil(SystemCommandRisk.detect("node tools/report.mjs --text '" + String(repeating: "한글 ordinary output ", count: 200) + "'"))
        let fixture = try HistoryReadFixture(), file = fixture.root.appendingPathComponent("install_fixture.py")
        let command = "python3 install_fixture.py --install"
        try "print('synthetic safe source')".write(to: file, atomically: true, encoding: .utf8)
        try expectNil(SystemCommandRisk.detect(command, cwd: fixture.root.path))
        try "Path.home().joinpath('Library/LaunchAgents/com.fixture.plist').write_text(payload)".write(to: file, atomically: true, encoding: .utf8)
        try expectEqual(SystemCommandRisk.detect(command, cwd: fixture.root.path)?.kind, .persistence)
        try "print('synthetic safe source')".write(to: file, atomically: true, encoding: .utf8)
        try expectNil(SystemCommandRisk.detect(command, cwd: fixture.root.path))
    }
}
