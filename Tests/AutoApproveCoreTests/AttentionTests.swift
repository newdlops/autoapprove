import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testAttentionCountsAndExistencePreserveCandidateLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-attention-count-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root))
        defer { engine.stop() }
        func session(_ id: String) -> AgentSession {
            var value = AgentSession(id: id, agent: .codex, pid: 42, started: "fixture", tty: "/dev/fixture",
                cwd: "/tmp/project", terminal: .terminal)
            value.automatic = true; value.phase = .input; value.channel = .terminalScreen
            return value
        }
        func question(_ id: String) -> QueuedQuestion {
            QueuedQuestion(id: id, threadID: "fixture", title: "\(id) e\u{301} 질문?", options: ["첫 번째", "둘째 🤖"])
        }
        let risk = SystemCommandRisk.detect("launchctl bootstrap gui/501 /fixture/test.plist")!
        func approval(_ id: String, automatic: Bool = false, sending: Bool = false, unsafe: Bool = false) throws -> ClaudeApproval {
            var input: JSONObject = ["id": id, "summary": "\(id) 승인", "answer": "Yes", "isQuestion": false,
                "sending": sending, "expiresAt": 1000]
            if automatic { input["automaticAt"] = 900 }
            if unsafe { input["systemCommandRisk"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(risk)) }
            return try JSONDecoder().decode(ClaudeApproval.self, from: JSONSerialization.data(withJSONObject: input))
        }
        func check(_ value: AgentSession, paused: Bool = false, keys: [String]) throws {
            let full = AttentionRequest.candidates(value, paused: paused)
            try expectEqual(full.map(\.key), keys)
            try expectEqual(AttentionRequest.count(value, paused: paused), keys.count)
            try expectEqual(AttentionRequest.needsAttention(value, paused: paused), !keys.isEmpty)
            var snapshot = engine.snapshot; snapshot.sessions = [value]; snapshot.paused = paused
            try expectEqual(snapshot.attentionCount, keys.count)
        }
        var main = session("main"), child = session("child"), grand = session("grand")
        var scheduled = question("scheduled"); scheduled.automation = QuestionAutomation(phase: .scheduled)
        var sending = question("sending"); sending.reply = QuestionReply(phase: .sending, answer: "first", message: "fixture")
        var queued = question("queued"); queued.reply = QuestionReply(phase: .queued, answer: "first", message: "fixture")
        var cancelled = question("cancelled"); cancelled.reply = QuestionReply(phase: .cancelled, answer: "first", message: "fixture")
        let plain = question("plain")
        main.queuedQuestions = [plain, scheduled, sending, queued, cancelled]
        main.pendingSummary = plain.summary; main.pendingRequestID = "duplicate-terminal"
        child.queuedQuestions = [question("child-question")]
        child.claudeApprovals = try [approval("manual"), approval("automatic", automatic: true),
            approval("sending", sending: true), approval("unsafe", unsafe: true)]
        grand.pendingSummary = "원본 터미널 질문"; grand.pendingRequestID = "terminal:grand"
        child.backgroundSessions = [grand]; main.backgroundSessions = [child]
        main.systemSafety = SystemSafetyNotice(id: "warning", risk: risk, request: "fixture only")
        main.interruption = SessionInterruption(id: "failure", kind: .transport, detail: "fixture error")
        var inbox = SessionInbox()
        let notice = SessionInbox.Candidate(key: SessionNotice.key(.question, "systemSafety:warning"),
            kind: .question, summary: "fixture warning", isSystemSafety: true)
        inbox.update([notice]); main.notices = inbox.entries
        let own = ["systemSafety:warning", "interruption:failure", "plain", "cancelled"]
        let grouped = ["child\nchild-question", "child\nbridge:manual", "child\ngrand\nterminal:grand"]
        try check(main, keys: own + grouped)
        let values = AttentionRequest.candidates(main, paused: false)
        try expectEqual(values.map(\.sourceSessionID), ["main", "main", "main", "main", "child", "child", "grand"])
        try expectEqual(values.last?.sourceKey, "terminal:grand")
        try expectEqual(values[2].summary, plain.summary)
        try expectEqual(Array(values.prefix(2)).map(\.kind), [.systemChange, .interruption])
        try check(main, paused: true, keys: ["systemSafety:warning", "interruption:failure", "plain", "scheduled", "cancelled",
            "child\nchild-question", "child\nbridge:manual", "child\nbridge:automatic", "child\ngrand\nterminal:grand"])
        var ended = main; ended.phase = .ended
        try check(ended, keys: Array(own.prefix(2)))
        inbox.markRead(); main.notices = inbox.entries; main.interruption?.acknowledgedAt = Date()
        try check(main, keys: Array(own.suffix(2)) + grouped)
        ended.notices = inbox.entries; ended.interruption?.recoveredAt = Date()
        try check(ended, keys: [])
        var shell = main; shell.agent = .shell
        try check(shell, keys: [])
        var reserved = child
        reserved.queuedQuestions = []; reserved.backgroundSessions = nil
        reserved.claudeApprovals = try [approval("automatic", automatic: true)]
        reserved.pendingSummary = "승인 목록이 있는 동안 터미널 폴백을 만들지 않는다"
        reserved.pendingInTerminal = true
        try check(reserved, keys: [])
        try check(reserved, paused: true, keys: ["bridge:automatic"])
    }

    func testAttentionNotificationDeadlinesAvoidPollingAndPreserveElapsedDelay() throws {
        let observed = Date(timeIntervalSince1970: 1_000)
        try expectEqual(AttentionNotificationSchedule.deadline(kind: .question, observedAt: observed, questionDelay: 10),
            observed.addingTimeInterval(10))
        try expectEqual(AttentionNotificationSchedule.deadline(kind: .question, observedAt: observed, questionDelay: 3600),
            observed.addingTimeInterval(3600))
        try expectEqual(AttentionNotificationSchedule.deadline(kind: .question, observedAt: observed, questionDelay: 0),
            observed.addingTimeInterval(1), "Invalid live values stay within the supported notification delay range")
        try expectEqual(AttentionNotificationSchedule.deadline(kind: .completion, observedAt: observed, questionDelay: 10),
            observed.addingTimeInterval(3))
        for kind in [AttentionRequest.Kind.interruption, .systemChange] {
            try expectEqual(AttentionNotificationSchedule.deadline(kind: kind, observedAt: observed, questionDelay: 10), observed)
        }
        let settingChangedAt = observed.addingTimeInterval(4)
        let changedDelay = AttentionNotificationSchedule.deadline(kind: .question, observedAt: observed, questionDelay: 20)
        try expectEqual(changedDelay.timeIntervalSince(settingChangedAt), 16,
            "Recalculating from the original observation preserves elapsed time when the setting changes")
    }

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
