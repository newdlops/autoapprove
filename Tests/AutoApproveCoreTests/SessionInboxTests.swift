import Foundation
import AutoApproveCore

private let koreanInput: JSONObject = ["questions": [["header": "확인", "multiSelect": false,
    "options": [["description": "그대로 진행합니다.", "label": "예"],
                ["description": "진행하지 않고 다음 질문으로 넘어갑니다.", "label": "아니오"]],
    "question": "계속 진행할까요?"]]]

extension ApprovalTests {
    func testClaudeDisconnectionPersistsOffAndRejectsFailedSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-disconnect-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(directory: root), settings = root.appendingPathComponent("claude-settings.json")
        let engine = try ApprovalEngine(paths: paths)
        _ = try HookInstaller.install(executable: "/tmp/fixture-helper", url: settings)
        let payload: JSONObject = ["hook_event_name": "SessionStart", "session_id": "disconnect", "requestID": "start"]
        _ = engine.handleHook(payload)
        try engine.setAutomatic("claude:disconnect", enabled: true)
        try engine.removeClaude(settingsURL: settings)
        try expect(!HookInstaller.isInstalled(url: settings))
        try expect(!engine.snapshot.sessions[0].automatic)
        let restarted = try ApprovalEngine(paths: paths)
        _ = restarted.handleHook(payload)
        try expect(!restarted.snapshot.sessions[0].automatic, "Removing a hook cannot re-enable approval on restart")
        _ = try HookInstaller.install(executable: "/tmp/fixture-helper", url: settings)
        try restarted.setAutomatic("claude:disconnect", enabled: true)
        _ = try CommandRunner.run("/usr/bin/sqlite3", [paths.database, "DROP TABLE settings"])
        try expectThrows(try restarted.removeClaude(settingsURL: settings))
        try expect(HookInstaller.isInstalled(url: settings), "A failed settings save must not claim disconnection succeeded")
        try expect(restarted.snapshot.sessions[0].automatic)
    }

    func testInboxDebounceReadAndNewOccurrences() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let question = SessionInbox.Candidate(key: "question", kind: .question, summary: "계속 진행할까요?")
        let completion = SessionInbox.Candidate(key: "completion", kind: .completion, summary: "작업을 마쳤습니다.")
        var inbox = SessionInbox()
        inbox.update([question, completion], at: start)
        inbox.update([question, completion], at: start.addingTimeInterval(0.7))
        try expect(inbox.entries.isEmpty)
        inbox.update([question, completion], at: start.addingTimeInterval(0.9))
        try expectEqual(inbox.entries.count, 1)
        try expectEqual(inbox.entries.first?.isRead, false)
        inbox.markRead()
        inbox.update([question, completion], at: start.addingTimeInterval(3.1))
        try expectEqual(inbox.entries.count, 2)
        try expect(inbox.entries.allSatisfy(\.isRead), "Viewing before the delivery delay also acknowledges the pending completion")
        inbox.update([], at: start.addingTimeInterval(4))
        try expectEqual(inbox.entries.count, 2, "Resolved questions retain their notification history")
        inbox.update([question], at: start.addingTimeInterval(5))
        inbox.update([question], at: start.addingTimeInterval(6))
        try expectEqual(inbox.entries.count, 3)
        try expectEqual(inbox.entries.first?.isRead, false, "A new occurrence is unread even when the wording repeats")
        try expect(!inbox.isRead("question"))
        inbox.update([question], at: start.addingTimeInterval(10))
        try expectEqual(inbox.entries.count, 3, "Polling never duplicates a live event")
    }

    func testInboxRestoresReadReceiptsBeforeObservation() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let candidate = SessionInbox.Candidate(key: "question", kind: .question, summary: "확인")
        var inbox = SessionInbox()
        inbox.update([candidate], at: start)
        inbox.update([candidate], at: start.addingTimeInterval(1))
        inbox.markRead()
        var restored = try JSONDecoder().decode(SessionInbox.self, from: JSONEncoder().encode(inbox))
        restored.update([], at: start.addingTimeInterval(2), reconcilesAbsence: false)
        restored.update([candidate], at: start.addingTimeInterval(3))
        try expectEqual(restored.entries, inbox.entries)
        try expect(restored.isRead("question"))
        for index in 0..<60 {
            let next = SessionInbox.Candidate(key: "\(index)", kind: .completion, summary: String(repeating: "가", count: 800))
            restored.update([next], at: start.addingTimeInterval(Double(index * 5 + 10)))
            restored.update([next], at: start.addingTimeInterval(Double(index * 5 + 14)))
        }
        try expectEqual(restored.entries.count, 50)
        try expect(restored.entries.allSatisfy { $0.summary.count <= 600 })
    }

    func testKoreanSampleAndPerSessionReadPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-korean-inbox-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(directory: root)
        let engine = try ApprovalEngine(paths: paths)
        let id = "process:45846:fixture"
        var payload: JSONObject = ["hook_event_name": "PreToolUse", "session_id": "korean-fixture", "requestID": "one",
            "tool_use_id": "one", "agentPID": 45846, "agentStarted": "fixture", "tty": "/dev/ttys037",
            "cwd": "/tmp/project", "tool_name": "AskUserQuestion", "tool_input": koreanInput]
        try expect(engine.handleHook(payload).isEmpty)
        try expectEqual(engine.snapshot.sessions[0].pendingSummary, "계속 진행할까요?\n1. 예 — 그대로 진행합니다.\n2. 아니오 — 진행하지 않고 다음 질문으로 넘어갑니다.")
        try expect(engine.snapshot.sessions[0].activityDetail?.contains("자동 승인이 꺼져") == true)
        var other = payload; other["agentPID"] = 45847; other["session_id"] = "other"
        _ = engine.handleHook(other)
        try await Task.sleep(nanoseconds: 900_000_000)
        engine.refreshNotices()
        try expect(engine.snapshot.sessions.allSatisfy { $0.unreadNoticeCount == 1 })
        try engine.markNotificationsRead(id)
        try expectEqual(engine.snapshot.sessions.first { $0.id == id }?.unreadNoticeCount, 0)
        try expectEqual(engine.snapshot.sessions.first { $0.id != id }?.unreadNoticeCount, 1)
        try expect(engine.snapshot.sessions.allSatisfy { $0.pendingInTerminal && $0.phase == .input })
        try expect(engine.snapshot.events.allSatisfy { $0.answer == nil }, "Reading a badge does not answer a question")
        let metadata = SessionCustomization(title: "한글 확인", note: "정확한 세션", color: .blue)
        try engine.setCustomization(id, value: metadata)
        let restarted = try ApprovalEngine(paths: paths)
        let discovered = AgentSession(id: id, agent: .claude, pid: 45846, started: "fixture", tty: "/dev/ttys037", cwd: "/tmp/project", terminal: .claudeBackground)
        restarted.updateDiscovery([discovered], records: [])
        _ = restarted.handleHook(payload)
        try expectEqual(restarted.snapshot.sessions[0].unreadNoticeCount, 0)
        try expectEqual(restarted.snapshot.sessions[0].customization, metadata)
        let hookFirst = try ApprovalEngine(paths: paths)
        _ = hookFirst.handleHook(payload)
        try expectEqual(hookFirst.snapshot.sessions[0].customization, metadata)
        try expectEqual(hookFirst.snapshot.sessions[0].unreadNoticeCount, 0)
        try hookFirst.setAutomatic(id, enabled: true)
        payload["tool_use_id"] = "new-question"; payload["requestID"] = "new-question"
        let output = hookFirst.handleHook(payload)["hookSpecificOutput"] as? JSONObject
        try expectEqual(output?["permissionDecision"] as? String, "allow")
        try expectEqual(((output?["updatedInput"] as? JSONObject)?["answers"] as? [String: String])?["계속 진행할까요?"], "예")
        try expectEqual(hookFirst.snapshot.events.first?.answer, "예")
    }

    func testInboxReadFailurePreservesBadge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-inbox-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(directory: root), engine = try ApprovalEngine(paths: AppPaths(directory: root))
        var inbox = SessionInbox()
        let candidate = SessionInbox.Candidate(key: "q", kind: .question, summary: "확인")
        inbox.update([candidate], at: .distantPast); inbox.update([candidate])
        try AuditStore(path: paths.database).set("inbox:process:42:fixture", String(decoding: JSONEncoder().encode(inbox), as: UTF8.self))
        engine.updateDiscovery([AgentSession(id: "process:42:fixture", agent: .claude, pid: 42, started: "fixture", tty: "/dev/test", cwd: "/tmp/project", terminal: .terminal)], records: [])
        try expectEqual(engine.snapshot.sessions[0].unreadNoticeCount, 1)
        _ = try CommandRunner.run("/usr/bin/sqlite3", [paths.database, "DROP TABLE settings"])
        try expectThrows(try engine.markNotificationsRead("process:42:fixture"))
        try expectEqual(engine.snapshot.sessions[0].unreadNoticeCount, 1)
    }

    func testClaudeDaemonPTYHasDistinctHost() throws {
        let records = ProcessDiscovery.parse("""
        1 0 ?? 1 0 Sat Sep 19 16:06:16 2026 /sbin/launchd
        45743 1 ?? 45743 0 Sat Sep 19 16:55:10 2026 /Users/test/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude
        45846 45743 ttys037 45846 45846 Sat Sep 19 16:55:12 2026 /Users/test/.local/share/claude/versions/2.1.278
        45878 45846 ttys037 45846 45846 Sat Sep 19 16:55:12 2026 /usr/local/bin/node
        """)
        let sessions = ProcessDiscovery.sessions(records)
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions[0].pid, 45846)
        try expectEqual(sessions[0].terminal, .claudeBackground)
        try expectEqual(sessions[0].tty, "/dev/ttys037")
        try expect(!sessions[0].canReveal, "A daemon's virtual TTY must not open an unrelated Terminal tab")
    }
}
