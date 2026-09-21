import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testAuditHistoryQueries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-audit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory); try paths.prepare()
        let session = AgentSession(id: "fixture", agent: .codex, pid: 42, started: "fixture", tty: "/dev/ttys-test", cwd: "/tmp/한글 프로젝트", terminal: .terminal)
        let through = Date()
        do {
            let store = try AuditStore(path: paths.database)
            for index in 0..<2005 {
                var event = AuditEvent(sessionID: session.id, summary: "명령 \(index)", outcome: index % 2 == 0 ? "승인 입력 전달" : "입력 확인 필요", source: "Terminal 화면", context: AuditContext(session: session), request: "echo 100%_literal\n전체 명령 \(index)")
                event.date = through.addingTimeInterval(-Double(index + 1))
                try store.append(event)
            }
            var attempt = AuditEvent(sessionID: session.id, summary: "pending", outcome: "승인 시도 · 결과 미확인", source: "VS Code 화면")
            attempt.date = through.addingTimeInterval(-0.5)
            try store.append(attempt)
            attempt.outcome = "승인 입력 전달"; try store.append(attempt)
        }
        let reopened = try AuditStore(path: paths.database, readOnly: true)
        let first = try reopened.history(through: through)
        let second = try reopened.history(through: through, offset: 100)
        try expectEqual(first.total, 2006, "Old audit records must not be silently removed at 2,000 entries")
        try expectEqual(first.events.count, 100)
        try expectEqual(first.events[0].outcome, "승인 입력 전달", "Acknowledgement updates the same persisted attempt")
        try expectEqual(Set(first.events.map(\.id)).intersection(Set(second.events.map(\.id))).count, 0)
        try expectEqual(try reopened.history(search: "한글 프로젝트", through: through).total, 2005)
        try expectEqual(try reopened.history(search: "100%_literal", through: through).total, 2005)
        try expectEqual(try reopened.history(search: "100%wildcard", through: through).total, 0)
        try expectEqual(try reopened.history(search: "%' OR 1=1 --", through: through).total, 0)
        try expectEqual(try reopened.history(result: .delivered, through: through).total, 1004)
        try expectEqual(try reopened.history(result: .review, through: through).total, 1002)
        try expectEqual(try reopened.history(result: .manual, through: through).total, 0)
        let legacy = try JSONDecoder().decode(AuditEvent.self, from: Data(#"{"id":"old","sessionID":"old-session","date":0,"summary":"old command","outcome":"승인 전달","source":"Claude 훅"}"#.utf8))
        try expectNil(legacy.context)
        try expectEqual(legacy.requestText, "old command")
        try expectEqual(legacy.result, .delivered)
    }

    func testAuditContextSurvivesSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-audit-hook-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory)
        let command = "echo 시작\n" + String(repeating: "long command content\n", count: 400) + "echo 마지막까지 저장"
        do {
            let engine = try ApprovalEngine(paths: paths)
            var hook: JSONObject = ["hook_event_name": "SessionStart", "session_id": "audit-fixture", "requestID": "start", "cwd": "/tmp/audit-project", "tty": "/dev/ttys-test"]
            _ = engine.handleHook(hook)
            try engine.setAutomatic("claude:audit-fixture", enabled: true)
            hook["hook_event_name"] = "PermissionRequest"; hook["requestID"] = "permission"; hook["tool_name"] = "Bash"; hook["tool_input"] = ["command": command]
            try expectNotNil(engine.handleHook(hook)["hookSpecificOutput"])
            hook["hook_event_name"] = "SessionEnd"; hook["requestID"] = "end"
            _ = engine.handleHook(hook)
        }
        let restarted = try ApprovalEngine(paths: paths)
        try expect(restarted.snapshot.sessions.isEmpty)
        let page = try await restarted.auditHistory(search: "마지막까지 저장", result: .delivered)
        try expectEqual(page.total, 1)
        let event = page.events[0]
        try expectEqual(event.context?.cwd, "/tmp/audit-project")
        try expectEqual(event.context?.tty, "/dev/ttys-test")
        try expectEqual(event.context?.agent, .claude)
        try expectEqual(event.tool, "Bash")
        let input = try JSONSerialization.jsonObject(with: Data(event.requestText.utf8)) as! JSONObject
        try expectEqual(input["command"] as? String, command)
    }
}
