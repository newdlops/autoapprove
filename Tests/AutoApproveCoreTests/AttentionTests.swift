import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testQuestionNotificationDelayPersistenceAndValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-notification-delay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory), engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        try expectEqual(engine.snapshot.questionNotificationDelay, 10)
        for seconds in [1, 3600, 17] {
            try engine.setQuestionNotificationDelay(seconds)
            try expectEqual(engine.snapshot.questionNotificationDelay, seconds)
            try expectEqual(try ApprovalEngine(paths: paths).snapshot.questionNotificationDelay, seconds, "The delay survives app restart")
        }
        for invalid in [-1, 0, 3601, Int.max] {
            try expectThrows(try engine.setQuestionNotificationDelay(invalid))
            try expectEqual(engine.snapshot.questionNotificationDelay, 17)
        }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(engine.snapshot)) as! JSONObject
        legacy.removeValue(forKey: "questionNotificationDelaySeconds")
        try expectEqual(try JSONDecoder().decode(EngineSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy)).questionNotificationDelay, 10)
        let store = try AuditStore(path: paths.database)
        for invalid in ["0", "-1", "3601", "damaged"] {
            try store.set("questionNotificationDelaySeconds", invalid)
            try expectEqual(try ApprovalEngine(paths: paths).snapshot.questionNotificationDelay, 10, "Invalid persisted values use the default")
        }
        try engine.setQuestionNotificationDelay(17)
        _ = try CommandRunner.run("/usr/bin/sqlite3", [paths.database, "DROP TABLE settings"])
        try expectThrows(try engine.setQuestionNotificationDelay(30))
        try expectEqual(engine.snapshot.questionNotificationDelay, 17, "A failed save must not change the running timer setting")
    }

    func testAttentionLifecycle() throws {
        var session = AgentSession(id: "live", agent: .codex, pid: 42, started: "one", tty: "/dev/fixture", cwd: "/tmp/project", terminal: .terminal)
        session.channel = .terminalScreen; session.automatic = true
        session.phase = .input; session.pendingSummary = "어느 작업부터 할까요?\n1. 상태 확인\n2. PR 점검\n3. 직접 입력"
        session.pendingInTerminal = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-attention-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        engine.updateDiscovery([session], records: [])
        var snapshot = engine.snapshot
        snapshot.sessions = [session]
        var tracker = AttentionTracker()
        let first = tracker.update(snapshot)
        try expectEqual(first.count, 1)
        for _ in 0..<8 { try expectEqual(tracker.update(snapshot), first) }
        snapshot.sessions[0].phase = .working; snapshot.sessions[0].pendingSummary = nil
        try expect(tracker.update(snapshot).isEmpty, "Remove resolved notifications")
        snapshot.sessions = [session]
        try expect(tracker.update(snapshot).first?.id != first.first?.id, "A later identical question must alert again")
        snapshot.sessions[0].phase = .approval; snapshot.sessions[0].pendingInTerminal = false
        try expect(tracker.update(snapshot).isEmpty, "An automatic permission in flight must not alert")
        snapshot.paused = true
        try expectEqual(tracker.update(snapshot).count, 1)
        snapshot.paused = false; snapshot.sessions[0].automatic = false
        try expectEqual(tracker.update(snapshot).count, 1)
        snapshot.sessions[0].automatic = true; snapshot.sessions[0].pendingInTerminal = true
        try expectEqual(tracker.update(snapshot).count, 1, "A failed automatic delivery needs attention")
        snapshot.sessions[0].phase = .idle
        try expect(tracker.update(snapshot).isEmpty)
        snapshot.sessions[0].phase = .input; snapshot.sessions[0].pendingSummary = nil
        try expect(tracker.update(snapshot).isEmpty, "Typing into a composer is not a question alert")
    }

    func testAttentionTarget() throws {
        var first = AgentSession(id: "process:42:old", agent: .claude, pid: 42, started: "old", tty: "/dev/tty1", cwd: "/tmp/shared", terminal: .terminal)
        var second = first; second.id = "process:42:new"; second.started = "new"
        try expectEqual(try AttentionRequest.target(sessionID: first.id, sessions: [second, first]).id, first.id)
        try expectThrows(AttentionRequest.target(sessionID: first.id, sessions: [second]))
        first.phase = .ended
        try expectThrows(AttentionRequest.target(sessionID: first.id, sessions: [first, second]))
        first.phase = .input; first.terminal = .vscode
        try expectThrows(AttentionRequest.target(sessionID: first.id, sessions: [first]))
        first.bridgeID = "bridge"; first.terminalID = "terminal-exact"
        try expectEqual(try AttentionRequest.target(sessionID: first.id, sessions: [first]).terminalID, "terminal-exact")
    }

    func testThreeChoiceAttention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-attention-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        _ = engine.handleHook(["session_id": "three", "requestID": "start", "hook_event_name": "SessionStart"])
        try engine.setAutomatic("claude:three", enabled: true)
        let question = "아직 상세하진 설명 전이니, 지금 제가 뭐부터 하면 될까요?"
        let options = [
            ["label": "미커물 현황 훑기", "description": "여러 워크트리에 흔어진 미커밋 아키들을 모아 어느 브랜치·어느 상태인지 한 장으로 정리해서 보여드립니다."],
            ["label": "여는 PR 상태 점검", "description": "kodebox-io/vcm 의 내 PR 들의 CI·리뷰 상태를 훑어 지금 사람 손이 필요한 것만 골라드립니다."],
            ["label": "지정해 주시는 일", "description": "하실 일을 말심해 주시면 그것부터 바로 들어가게습니다."]]
        var payload: JSONObject = ["session_id": "three", "requestID": "pre", "tool_use_id": "one", "hook_event_name": "PreToolUse",
            "tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": question, "options": options]]]]
        var tracker = AttentionTracker()
        try expect(engine.handleHook(payload).isEmpty)
        let first = tracker.update(engine.snapshot)
        try expectEqual(first.count, 1)
        try expect(first[0].summary.contains("3. 지정해 주시는 일"))
        payload["hook_event_name"] = "PermissionRequest"; payload["requestID"] = "permission"
        try expect(engine.handleHook(payload).isEmpty)
        try expectEqual(tracker.update(engine.snapshot), first)
        for type in ["permission_prompt", "idle_prompt"] {
            _ = engine.handleHook(["session_id": "three", "requestID": type, "hook_event_name": "Notification",
                "notification_type": type, "message": "Claude needs your permission"])
            try expectEqual(engine.snapshot.sessions[0].phase, .input)
            try expectEqual(tracker.update(engine.snapshot), first)
        }
        payload["tool_use_id"] = "two"; payload["requestID"] = "next"; payload["hook_event_name"] = "PreToolUse"
        try expect(engine.handleHook(payload).isEmpty)
        try expect(tracker.update(engine.snapshot)[0].id != first[0].id)
        _ = engine.handleHook(["session_id": "three", "requestID": "done", "hook_event_name": "PostToolUse"])
        try expect(tracker.update(engine.snapshot).isEmpty)
        try expect(engine.snapshot.events.allSatisfy { $0.answer == nil })
    }
}
