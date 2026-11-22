import Foundation
import CSQLite
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif

extension ApprovalTests {
    func testAgyTranscriptModelRecovery() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let logs = root.appendingPathComponent("antigravity-cli/brain/" + id + "/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("transcript.jsonl")
        let session = AgentSession(id: "fixture", agent: .agy, pid: 1, started: "fixture", tty: "/dev/fixture", cwd: "/project", terminal: .terminal)
        var live = SessionGroupLiveSession(session: session, conversationID: id.uppercased(), providerHome: root.appendingPathComponent("config").path)
        let reader = SessionGroupModelSettingsReader()
        let first = #"{"source":"MODEL","type":"PLANNER_RESPONSE","model":"gemini-4-neon-medium"}"#
        let user = #"{"source":"USER_EXPLICIT","type":"USER_INPUT","model":"wrong"}"#
        try (first + "\n" + user + "\n").write(to: file, atomically: true, encoding: .utf8)
        try expectEqual(reader.read(live)?.reasoningEffort, "medium")
        try first.replacingOccurrences(of: "medium", with: "high").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        try expectEqual(reader.read(live)?.model, "gemini-4-neon-high")
        try expectEqual(reader.read(live)?.source, "agy_transcript")
        live.conversationID = UUID().uuidString
        try expectNil(reader.read(live))
    }

    func testGroupModelSettingsUseExactConversationAndFreshMetadata() throws {
        let home = URL(fileURLWithPath: "/private/tmp/aa-group-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        var db: OpaquePointer?
        try expectEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        func sql(_ text: String) throws { try expectEqual(sqlite3_exec(db, text, nil, nil, nil), SQLITE_OK) }
        try sql("CREATE TABLE threads(id TEXT PRIMARY KEY, model TEXT, reasoning_effort TEXT, updated_at INTEGER)")
        try sql("INSERT INTO threads VALUES('\(id)','gpt-6.1-sol','xhigh',1794900000),('\(other)','other-model','low',1794900000)")
        let session = AgentSession(id: "fixture", agent: .codex, pid: 42, started: "fixture", tty: "/dev/fixture", cwd: "/project", terminal: .unknown)
        var live = SessionGroupLiveSession(session: session, conversationID: id.uppercased(), providerHome: home.path)
        let reader = SessionGroupModelSettingsReader()
        let first = reader.read(live)
        try expectEqual(first?.model, "gpt-6.1-sol"); try expectEqual(first?.reasoningEffort, "xhigh")
        try expectEqual(first?.source, "codex_session_metadata")
        try expectEqual(first?.recordedAt, Date(timeIntervalSince1970: 1794900000))
        try sql("UPDATE threads SET model='gpt-6-astra',reasoning_effort='high' WHERE id='\(id)'")
        try expectEqual(reader.read(live)?.model, "gpt-6-astra"); try expectEqual(reader.read(live)?.reasoningEffort, "high")
        live.conversationID = UUID().uuidString; try expectNil(reader.read(live))
        live.conversationID = id; live.providerHome = nil; try expectNil(reader.read(live))
        try expectNil(SessionGroupModelSettings(model: "not a model\n", reasoningEffort: nil, source: "fixture").model)
    }

    func testClaudeGroupMetadataAndCompletionStayConversationBound() throws {
        let home = URL(fileURLWithPath: "/private/tmp/aa-claude-model-" + UUID().uuidString)
        let project = home.appendingPathComponent("projects/-fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString.lowercased(), item = UUID().uuidString
        let log = project.appendingPathComponent(id + ".jsonl")
        let ended = Date().addingTimeInterval(-10)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var row: JSONObject = ["type": "assistant", "sessionId": id, "uuid": item, "timestamp": formatter.string(from: ended),
            "isSidechain": false, "requestedModel": "alias", "effort": "medium", "perTurnEffort": "xhigh",
            "message": ["model": "claude-opus-5-5", "stop_reason": "end_turn", "content": [["type": "thinking", "thinking": "private reasoning"], ["type": "text", "text": "Fixture final result"]]]]
        func encoded(_ value: JSONObject) throws -> Data { var data = try JSONSerialization.data(withJSONObject: value); data.append(10); return data }
        func save(_ value: JSONObject, suffix: Data = Data()) throws { var data = try encoded(value); data.append(suffix); try data.write(to: log, options: .atomic) }
        let session = AgentSession(id: "fixture", agent: .claude, pid: 43, started: "fixture", tty: "/dev/fixture", cwd: "/fixture/project", terminal: .unknown)
        var live = SessionGroupLiveSession(session: session, conversationID: id, providerHome: home.path)
        let reader = SessionGroupModelSettingsReader()
        try save(row)
        try expectEqual(reader.read(live)?.model, "claude-opus-5-5")
        try expectEqual(reader.read(live)?.reasoningEffort, "xhigh")
        try expectEqual(reader.completion(live, after: ended.addingTimeInterval(-1))?.summary, "Fixture final result")
        try expectNil(reader.completion(live, after: ended.addingTimeInterval(1)))
        let prompt: JSONObject = ["type": "user", "sessionId": id, "timestamp": formatter.string(from: ended.addingTimeInterval(-0.5)),
            "message": ["role": "user", "content": "Owned original task"]]
        var bound = try encoded(prompt); bound.append(try encoded(row)); try bound.write(to: log, options: .atomic)
        try expectEqual(reader.completion(live, after: ended.addingTimeInterval(-1), task: "Owned original task")?.summary, "Fixture final result")
        try expectNil(reader.completion(live, after: ended.addingTimeInterval(-1), task: "An unrelated assignment"))
        let key = UUID()
        let groupPrompt = "[AutoApprove 그룹 전달 " + key.uuidString + "] exact"
        var submitted = prompt
        submitted["message"] = ["role": "user", "content": groupPrompt]
        var recovered = try encoded(submitted)
        recovered.append(try encoded(row))
        try recovered.write(to: log, options: .atomic)
        recovered.append(try encoded(prompt))
        try recovered.write(to: log, options: .atomic)
        try expectEqual(reader.groupTurns(live)[key]?.response.summary, "Fixture final result")
        var replayed = try encoded(submitted)
        replayed.append(recovered)
        try replayed.write(to: log, options: .atomic)
        try expectNil(reader.groupTurns(live)[key])
        try save(row)
        try expectNil(reader.completion(live, after: ended.addingTimeInterval(-1), task: "Owned original task"))
        var foreign = row; foreign["sessionId"] = UUID().uuidString
        try save(row, suffix: encoded(foreign))
        try expectEqual(reader.read(live)?.model, "claude-opus-5-5")
        var sidechain = row; sidechain["isSidechain"] = true
        try save(row, suffix: encoded(sidechain))
        try expectEqual(reader.completion(live, after: ended.addingTimeInterval(-1))?.summary, "Fixture final result")
        try save(row, suffix: Data("{\"type\":\"user\"".utf8))
        try expectNil(reader.completion(live, after: ended.addingTimeInterval(-1)))
        try save(row, suffix: encoded(["type": "user", "sessionId": id, "message": ["role": "user"]]))
        try expectNil(reader.completion(live, after: ended.addingTimeInterval(-1)))
        row["message"] = ["model": "claude-sonnet-5-5", "stop_reason": "tool_use", "content": [["type": "text", "text": "Still working"]]]
        row["perTurnEffort"] = "high"; try save(row)
        try expectEqual(reader.read(live)?.model, "claude-sonnet-5-5"); try expectEqual(reader.read(live)?.reasoningEffort, "high")
        try expectNil(reader.completion(live, after: ended.addingTimeInterval(-1)))
        live.conversationID = UUID().uuidString; try expectNil(reader.read(live))
    }
}
