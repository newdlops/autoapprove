import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testClaudeCompletionLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-completion-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        func hook(_ event: String, extra: JSONObject = [:]) {
            var payload: JSONObject = ["session_id": "main", "requestID": UUID().uuidString, "hook_event_name": event, "cwd": "/tmp/project"]
            payload.merge(extra) { _, new in new }
            _ = engine.handleHook(payload)
        }
        hook("SessionStart")
        hook("Notification", extra: ["notification_type": "idle_prompt"])
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty, "Existing idle sessions must not announce completion")
        hook("UserPromptSubmit")
        hook("PostToolUse")
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty, "A finished tool is not a finished agent turn")
        hook("Stop", extra: ["last_assistant_message": "변경과 검증을 마쳤습니다.", "background_tasks": [], "session_crons": []])
        let first = AttentionRequest.completions(engine.snapshot)
        try expectEqual(first.count, 1)
        try expectEqual(first[0].kind, .completion)
        try expectEqual(first[0].title, "project · 작업 완료")
        try expectEqual(first[0].summary, "변경과 검증을 마쳤습니다.")
        hook("Stop")
        hook("Notification", extra: ["notification_type": "idle_prompt"])
        try expectEqual(AttentionRequest.completions(engine.snapshot), first, "Duplicate Stop and reminders must keep one notification ID")
        try engine.setPaused(true)
        try expectEqual(AttentionRequest.completions(engine.snapshot), first, "Automatic approval pause does not disable completion notifications")
        hook("UserPromptSubmit")
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty, "New work clears a pending or delivered completion")
        hook("SubagentStop")
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty, "Child completion cannot complete the root")
        hook("Stop", extra: ["stop_hook_active": true])
        try expectEqual(AttentionRequest.completions(engine.snapshot).count, 1, "A final Stop after an earlier continuation may finish")
        try expect(AttentionRequest.completions(engine.snapshot)[0].id != first[0].id)
        hook("SessionEnd")
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty)
    }

    func testClaudeIncompleteStopDoesNotNotify() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-incomplete-stop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        func hook(_ event: String, extra: JSONObject = [:]) {
            var payload: JSONObject = ["session_id": "main", "requestID": UUID().uuidString, "hook_event_name": event]
            payload.merge(extra) { _, new in new }; _ = engine.handleHook(payload)
        }
        hook("UserPromptSubmit")
        for extra: JSONObject in [["background_tasks": [["id": "child", "status": "running"]]], ["session_crons": [["id": "wakeup"]]]] {
            hook("Stop", extra: extra)
            try expect(AttentionRequest.completions(engine.snapshot).isEmpty)
            try expectEqual(engine.snapshot.sessions[0].phase, .idle)
            try expect(engine.snapshot.sessions[0].isMonitoring)
        }
        hook("PreToolUse", extra: ["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "어느 작업?", "options": [["label": "하나"], ["label": "둘"], ["label": "셋"]]]]]])
        hook("Stop")
        try expectEqual(engine.snapshot.sessions[0].phase, .input, "Stop must not erase an unresolved question")
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty)
        hook("PostToolUse")
        hook("Stop", extra: ["background_tasks": [], "session_crons": []])
        try expectEqual(AttentionRequest.completions(engine.snapshot).count, 1)
    }

    func testCodexCompletionBaselineAndOutcomes() throws {
        let start = Date(timeIntervalSince1970: 1_000), session = "process:1:start"
        var tracker = CodexCompletionTracker(at: start)
        func state(_ id: String, _ status: String, thread: String = "root", completed: Date? = start) -> CodexTurnState {
            CodexTurnState(threadID: thread, turnID: id, status: status, completedAt: completed)
        }
        try expectNil(tracker.observe(state("old", "completed"), sessionID: session, at: start))
        let done = tracker.observe(state("new", "completed"), sessionID: session, at: start)
        try expectNotNil(done, "A short turn can start and finish between polls")
        try expectNil(tracker.observe(state("new", "completed"), sessionID: session, at: start))
        try expectNil(tracker.observe(state("next", "inProgress", completed: nil), sessionID: session, at: start))
        try expectNotNil(tracker.observe(state("next", "completed"), sessionID: session, at: start))
        for status in ["interrupted", "failed", "unknown"] {
            try expectNil(tracker.observe(state(status, status), sessionID: session, at: start))
        }
        try expectNil(tracker.observe(state("history", "completed", completed: start.addingTimeInterval(-60)), sessionID: session, at: start))
        try expectNil(tracker.observe(state("other", "completed", thread: "different-root"), sessionID: session, at: start))
        tracker.retain(sessionIDs: [])
        try expect(tracker.observe(state("old", "completed"), sessionID: session, at: start) == nil, "Reconnected sessions must establish a new baseline")
        var empty = CodexCompletionTracker(at: start)
        try expectNil(empty.observe(CodexTurnState(threadID: "empty"), sessionID: session, at: start))
        try expectNotNil(empty.observe(state("first", "completed", thread: "empty"), sessionID: session, at: start))
    }

    func testCodexCompletionEngineAndRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-completion-engine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        var session = AgentSession(id: "process:42:start", agent: .codex, pid: 42, started: "start", tty: "/dev/test", cwd: "/tmp/project", terminal: .terminal)
        session.phase = .working
        engine.updateDiscovery([session], records: [])
        let question = QueuedQuestion(id: "q", threadID: "root", title: "질문")
        let running = CodexTurnState(threadID: "root", turnID: "turn", status: "inProgress")
        let completed = CodexTurnState(threadID: "root", turnID: "turn", status: "completed", completedAt: Date(), summary: "최종 응답")
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: [question], turn: running)])
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty)
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: [question], turn: completed)])
        try expectEqual(AttentionRequest.completions(engine.snapshot).count, 1)
        try expectEqual(engine.snapshot.attentionCount, 1, "Completion is separate from pending questions")
        engine.updateCodexQuestions([.init(sessionID: session.id, error: "read failure")])
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty)
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: [question], turn: completed)])
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty, "Recovery must not replay the same completion")
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: [question], completionError: "unsupported turns")])
        try expectEqual(engine.snapshot.sessions[0].questions, [question], "Completion errors must not break question collection")
        try expectEqual(engine.snapshot.sessions[0].completionError, "unsupported turns")
        engine.updateDiscovery([], records: [])
        engine.updateCodexQuestions([.init(sessionID: session.id, turn: completed)])
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty, "Late history must not revive an exited process")
    }

    func testCodexCompletionReadOnlyHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-turn-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("history.sqlite").path
        func sql(_ value: String) throws {
            let result = try CommandRunner.run("/usr/bin/sqlite3", [db, value]); try expectEqual(result.status, 0, result.error)
        }
        try sql("CREATE TABLE thread_turns (thread_id TEXT, turn_id TEXT, status TEXT, completed_at INTEGER, rollout_ordinal INTEGER, final_agent_item_id TEXT); CREATE TABLE thread_items (thread_id TEXT, turn_id TEXT, item_id TEXT, item_json TEXT);")
        let location = CodexThreadLocation(threadID: "root", database: db)
        try expectNil(try CodexTurnReader.read(location).turnID)
        try sql("INSERT INTO thread_turns VALUES ('root','one','completed',1000,1,'answer'); INSERT INTO thread_items VALUES ('root','one','answer','{\"type\":\"agentMessage\",\"text\":\"검증 완료\"}'); INSERT INTO thread_turns VALUES ('child','two','completed',1001,9,'answer'); INSERT INTO thread_items VALUES ('child','two','answer','{\"type\":\"agentMessage\",\"text\":\"하위 작업\"}');")
        let completed = try CodexTurnReader.read(location)
        try expectEqual(completed.turnID, "one"); try expectEqual(completed.summary, "검증 완료")
        try expectEqual(completed.completedAt, Date(timeIntervalSince1970: 1000))
        try sql("INSERT INTO thread_turns VALUES ('root','next','inProgress',NULL,10,NULL);")
        try expectEqual(try CodexTurnReader.read(location).status, "inProgress", "Use latest turn, not latest successful turn")
        try expectNil(try CodexTurnReader.read(location).completedAt)
        let missing = directory.appendingPathComponent("missing.sqlite").path
        try expectThrows(CodexTurnReader.read(.init(threadID: "root", database: missing)))
        try expectFalse(FileManager.default.fileExists(atPath: missing))
        try sql("DROP TABLE thread_turns;")
        try expectThrows(CodexTurnReader.read(location))
    }
}
