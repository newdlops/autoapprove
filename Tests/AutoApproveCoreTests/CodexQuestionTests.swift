import Foundation
import JavaScriptCore
import AutoApproveCore

extension ApprovalTests {
    private func asyncQuestion(_ id: String, _ title: String, ordinal: Int64, options: [String] = ["하나", "둘", "셋"]) -> CodexQuestionHistory.Item {
        .init(ordinal: ordinal, json: ["type": "agentMessage", "id": id, "delivery": "async", "questions": [["title": title, "options": options]]])
    }
    private func answer(_ text: String, ordinal: Int64) -> CodexQuestionHistory.Item {
        .init(ordinal: ordinal, json: ["type": "userMessage", "id": "user-\(ordinal)", "content": [["type": "text", "text": text]]])
    }
    func testCodexQuestionResolution() throws {
        let a = asyncQuestion("a", "어느 작업부터 할까요?", ordinal: 1)
        let b = asyncQuestion("b", "검증 범위를 정해주세요.", ordinal: 3)
        var rows = [a, answer("작업을 계속해줘", ordinal: 2), b]
        try expectEqual(CodexQuestionHistory.pending(threadID: "root", items: rows).count, 2)
        rows.append(answer("> 어느 작업부터 할까요?", ordinal: 4))
        rows.append(answer("예시: > 검증 범위를 정해주세요.\n전체", ordinal: 5))
        try expectEqual(CodexQuestionHistory.pending(threadID: "root", items: rows).count, 2, "A quote alone or embedded example cannot resolve a question")
        rows.append(answer("> 검증 범위를 정해주세요.\n\n전체", ordinal: 6))
        try expectEqual(CodexQuestionHistory.pending(threadID: "root", items: rows).map(\.title), ["어느 작업부터 할까요?"])
        rows.append(answer("> 어느 작업부터 할까요?\n\n첫 번째", ordinal: 7))
        try expect(CodexQuestionHistory.pending(threadID: "root", items: rows).isEmpty)
        rows.append(asyncQuestion("new", a.json["questions"].flatMap { ($0 as? [JSONObject])?.first?["title"] as? String }!, ordinal: 8))
        try expectEqual(CodexQuestionHistory.pending(threadID: "root", items: rows).count, 1)
        rows.append(asyncQuestion("duplicate-title", "어느 작업부터 할까요?", ordinal: 9))
        rows.append(answer("> 어느 작업부터 할까요?\n첫 번째", ordinal: 10))
        try expectEqual(CodexQuestionHistory.pending(threadID: "root", items: rows).count, 2, "Ambiguous identical titles must not erase either request")
        let bundle = CodexQuestionHistory.Item(ordinal: 1, json: ["type": "agentMessage", "id": "bundle", "delivery": "async", "questions": [["title": "첫 질문", "options": []], ["title": "둘째 질문", "options": ["예", "아니오"]]]])
        let partial = CodexQuestionHistory.pending(threadID: "root", items: [bundle, answer("> 첫 질문\n자유 입력", ordinal: 2)])
        try expectEqual(partial.count, 1); try expectEqual(partial[0].title, "둘째 질문")
    }

    func testCodexHistoryReadOnlyAndIncremental() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-codex-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appendingPathComponent("history.sqlite").path
        func sql(_ text: String) throws {
            let result = try CommandRunner.run("/usr/bin/sqlite3", [db, text])
            try expectEqual(result.status, 0, result.error)
        }
        func insert(_ item: CodexQuestionHistory.Item, thread: String = "root") throws {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: item.json), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
            let id = item.json["id"] as! String, type = item.json["type"] as! String
            try sql("INSERT INTO thread_items VALUES ('\(thread)','\(id)',\(item.ordinal),'\(type)',\(item.ordinal),'\(json)');")
        }
        try sql("CREATE TABLE thread_history_projection_state (thread_id TEXT PRIMARY KEY, next_rollout_ordinal INTEGER); CREATE TABLE thread_items (thread_id TEXT, item_id TEXT, rollout_ordinal INTEGER, item_type TEXT, updated_at_ordinal INTEGER, item_json TEXT); INSERT INTO thread_history_projection_state VALUES ('root',4);")
        try insert(asyncQuestion("a", "첫 질문", ordinal: 1))
        try insert(asyncQuestion("b", "둘째 질문", ordinal: 2))
        try insert(asyncQuestion("unrelated", "다른 터미널", ordinal: 3), thread: "other")
        let location = CodexThreadLocation(threadID: "root", database: db), reader = CodexHistoryReader()
        let first = try reader.read(location)
        try expectEqual(first.count, 2); try expectEqual(try reader.read(location), first)
        try insert(answer("> 첫 질문\n답변", ordinal: 4))
        try sql("UPDATE thread_history_projection_state SET next_rollout_ordinal=5;")
        let remaining = try reader.read(location)
        try expectEqual(remaining.map(\.title), ["둘째 질문"])
        try expectEqual(try CodexHistoryReader().read(location), remaining, "Restart reconstructs unanswered questions")
        try sql("UPDATE thread_items SET updated_at_ordinal=5 WHERE item_id='a'; UPDATE thread_history_projection_state SET next_rollout_ordinal=6;")
        try expectEqual(try reader.read(location), remaining, "An older projection update cannot resurrect an answered question")
        let missing = root.appendingPathComponent("missing.sqlite").path
        try expectThrows(try reader.read(CodexThreadLocation(threadID: "root", database: missing)))
        try expectFalse(FileManager.default.fileExists(atPath: missing), "Read-only access must never create a Codex database")
        try sql("DROP TABLE thread_items;")
        try expectThrows(try reader.read(location))
    }

    func testCodexThreadBinding() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aa-codex-binding-" + UUID().uuidString)
        let day = home.appendingPathComponent("sessions/2026/09/21")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        func rollout(_ id: String, source: Any) throws -> String {
            let url = day.appendingPathComponent("rollout-\(id).jsonl")
            var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "source": source]])
            data.append(10); try data.write(to: url); return url.path
        }
        let root = try rollout("root", source: "cli"), child = try rollout("child", source: ["subagent": ["parent_thread_id": "root"]])
        let files = CodexThreadLocation.openFiles("p42\nn\(root)\nn\(child)\np99\nn/unrelated/path\n")
        let location = try CodexThreadLocation.locate(paths: files[42]!)
        try expectEqual(location.threadID, "root")
        try expectEqual(location.database, home.appendingPathComponent("thread_history_1.sqlite").path)
        try expectThrows(try CodexThreadLocation.locate(paths: [child]))
        let other = try rollout("other", source: "cli")
        try expectThrows(try CodexThreadLocation.locate(paths: [root, other]))
    }

    func testConcurrentCodexAttentionAndDismissal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-codex-engine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory), engine = try ApprovalEngine(paths: paths)
        var session = AgentSession(id: "process:42:first", agent: .codex, pid: 42, started: "first", tty: "/dev/fixture", cwd: "/tmp/project", terminal: .terminal)
        session.phase = .working; session.channel = .terminalScreen
        engine.updateDiscovery([session], records: [])
        let questions = CodexQuestionHistory.pending(threadID: "root", items: [asyncQuestion("a", "첫 질문", ordinal: 1), asyncQuestion("b", "둘째 질문", ordinal: 2)])
        let update = CodexQuestionUpdate(sessionID: session.id, questions: questions)
        engine.updateCodexQuestions([update])
        try expectEqual(engine.snapshot.sessions[0].phase, .working)
        try expect(engine.snapshot.sessions[0].needsReview)
        var tracker = AttentionTracker()
        let first = tracker.update(engine.snapshot)
        try expectEqual(first.count, 2); try expectEqual(engine.snapshot.attentionCount, 2)
        engine.updateCodexQuestions([update]); try expectEqual(tracker.update(engine.snapshot), first)
        engine.receiveScreen(sessionID: session.id, raw: "• Working (esc to interrupt)\n›\n? for shortcuts", generation: "fixture")
        try expectEqual(tracker.update(engine.snapshot), first, "A screen without a question cannot clear the queue")
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: session.id, error: "一時的な読み込み失敗")])
        try expectEqual(tracker.update(engine.snapshot), first, "Keep the last known queue during transient errors")
        try engine.dismissQuestion(sessionID: session.id, questionID: questions[0].id)
        let remaining = tracker.update(engine.snapshot)
        try expectEqual(remaining.map(\.id), [first[1].id], "Dismissing one question preserves the other's notification")
        engine.updateCodexQuestions([update]); try expectEqual(tracker.update(engine.snapshot), remaining)
        let reopened = try ApprovalEngine(paths: paths)
        reopened.updateDiscovery([session], records: []); reopened.updateCodexQuestions([update])
        try expectEqual(reopened.snapshot.sessions[0].questions, [questions[1]])
        engine.updateDiscovery([], records: []); engine.updateCodexQuestions([update])
        try expect(tracker.update(engine.snapshot).isEmpty, "A late collector result cannot resurrect an ended session")
        session.queuedQuestions = questions; session.phase = .input; session.pendingSummary = questions[0].summary
        try expectEqual(AttentionRequest.candidates(session, paused: false).count, 2, "Visible copy of queued question is not a third notification")
    }

    func testTerminalTitleContract() throws {
        let context = JSContext()!
        context.evaluateScript("""
        function Application() { return { running:()=>true, windows:()=>[
          {name:()=> '선택한 창 제목', tabs:()=>[
            {tty:()=>'/dev/1',contents:()=>'',customTitle:()=> '내 탭 제목', selected:()=>false},
            {tty:()=>'/dev/2',contents:()=>'',customTitle:()=>'',selected:()=>true},
            {tty:()=>'/dev/3',contents:()=>'',customTitle:()=>'',selected:()=>false}]},
          {name:()=>{throw Error('title unavailable')},tabs:()=>[
            {tty:()=>'/dev/4',contents:()=> 'still readable',customTitle:()=>{throw Error('closed title')}}]}
        ]}; }
        """)
        let value = context.evaluateScript(try TerminalAdapter.screenScript(ttys: ["/dev/1", "/dev/2", "/dev/3", "/dev/4"]))!
        try expectNil(context.exception)
        let snapshot = try JSONDecoder().decode(TerminalSnapshot.self, from: Data(value.toString().utf8))
        try expectEqual(snapshot.screens.map(\.title), ["내 탭 제목", "선택한 창 제목", nil, nil])
        try expectEqual(snapshot.screens.last?.contents, "still readable")
        try expect(snapshot.failures.isEmpty, "An unavailable optional title must not break approval collection")
    }
}
