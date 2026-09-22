import Foundation
import AutoApproveCore

private let hookProcesses = ProcessDiscovery.parse("""
1 0 ?? 1 0 Tue Sep 22 09:00:00 2026 /sbin/launchd
10 1 ?? 10 0 Tue Sep 22 09:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
11 10 ttys032 11 12 Tue Sep 22 09:00:00 2026 /bin/zsh
12 11 ttys032 12 12 Tue Sep 22 09:00:00 2026 claude
20 12 ?? 20 0 Tue Sep 22 09:00:00 2026 claude bg-pty-host
21 20 ttys037 21 21 Tue Sep 22 09:00:00 2026 claude
22 20 ttys038 22 22 Tue Sep 22 09:00:00 2026 claude
""")
private func hookSession(_ pid: Int32) -> String { hookProcesses.first { $0.pid == pid }!.key }
private final class HookProcesses: @unchecked Sendable { var records = hookProcesses }
private func hookPayload(_ now: Date, pid: Int32 = 21, number: Int = 0) -> JSONObject {
    ["autoapproveProtocol": 1, "requestID": UUID().uuidString, "autoapproveExpiresAt": now.addingTimeInterval(600).timeIntervalSince1970,
     "hook_event_name": "PreToolUse", "session_id": "provider-\(pid)", "agentPID": pid,
     "agentStarted": hookProcesses.first { $0.pid == pid }!.started, "tty": "/dev/ttys037", "cwd": "/tmp/fixture",
     "tool_name": "AskUserQuestion", "tool_use_id": UUID().uuidString,
     "tool_input": ["questions": [["question": "[\(number)] 이 작업을 허용할까요?", "multiSelect": false,
         "options": [["label": "거부"], ["label": "항상 허용"], ["label": "허용"]]]]]]
}
private func bridgeWaiting(_ value: JSONObject) -> Bool { (value["autoapproveBridge"] as? JSONObject)?["waiting"] as? Bool == true }
private func bridgeAnswer(_ value: JSONObject) -> JSONObject? { (value["autoapproveBridge"] as? JSONObject)?["response"] as? JSONObject }
@MainActor private func hookEngine(_ paths: AppPaths, processes: HookProcesses = HookProcesses()) throws -> ApprovalEngine {
    let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { processes.records })
    engine.updateDiscovery(ProcessDiscovery.sessions(processes.records), records: processes.records)
    return engine
}
private func fixturePaths() -> AppPaths { AppPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("aa-hook-" + UUID().uuidString)) }

extension ApprovalTests {
    func testClaudeAppApprovalThenThirtySequentialQuestions() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date(), first = hookPayload(now)
        var tracker = AttentionTracker()
        try expect(bridgeWaiting(try engine.handleClaudeHook(first, at: now)))
        try expectEqual(tracker.update(engine.snapshot).count, 1, "An OFF session still needs manual attention")
        let parent = engine.snapshot.sessions.first { $0.id == hookSession(12) }!
        try expectEqual(parent.backgroundChildren.first { $0.id == hookSession(21) }?.claudeApprovals?.count, 1)
        try expect(!parent.automatic)
        try engine.answerClaudeApproval(sessionID: hookSession(21), requestID: first["requestID"] as! String, enableAutomatic: true, at: now)
        try expect(tracker.update(engine.snapshot).isEmpty, "A sending answer must withdraw the manual alert")
        try expect(engine.snapshot.sessions.first { $0.id == hookSession(12) }!.automatic)
        try expectEqual(engine.snapshot.events.first?.outcome, "답변 대기열 등록")
        try expect(!bridgeAnswer(try engine.handleClaudeHook(first, at: now))!.isEmpty)
        try engine.acknowledgeClaudeHook(first, at: now)
        try expectEqual(engine.snapshot.events.first?.outcome, "질문 응답 전달")
        for index in 1...30 {
            let date = now.addingTimeInterval(Double(index) * 6), payload = hookPayload(date, number: index)
            try expect(bridgeWaiting(try engine.handleClaudeHook(payload, at: date)))
            try expect(tracker.update(engine.snapshot).isEmpty, "A fresh automatic Claude question must not alert")
            try expect(bridgeWaiting(try engine.handleClaudeHook(payload, at: date.addingTimeInterval(4.9))), "Each question has its own five-second wait")
            try expect(tracker.update(engine.snapshot).isEmpty, "The whole automatic countdown stays quiet")
            let response = bridgeAnswer(try engine.handleClaudeHook(payload, at: date.addingTimeInterval(5)))!
            let updated = (response["hookSpecificOutput"] as? JSONObject)?["updatedInput"] as? JSONObject
            try expectEqual(updated?["answers"] as? [String: String], ["[\(index)] 이 작업을 허용할까요?": "허용"])
            try engine.acknowledgeClaudeHook(payload, at: date.addingTimeInterval(5))
        }
        try expectEqual(engine.snapshot.events.count, 31)
        try expect(engine.snapshot.events.allSatisfy { $0.sessionID == hookSession(12) && $0.originSessionID == hookSession(21) && $0.outcome == "질문 응답 전달" })
        try expectNil(engine.snapshot.sessions.first { $0.id == hookSession(12) }?.backgroundChildren.first { $0.id == hookSession(21) }?.pendingSummary)
    }

    func testClaudeAutomaticAttentionAndManualFallback() async throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date()
        var start = hookPayload(now, pid: 12); start["hook_event_name"] = "SessionStart"
        _ = try engine.handleClaudeHook(start, at: now)
        try engine.setAutomatic(hookSession(12), enabled: true)
        let question = hookPayload(now, pid: 12)
        var permission = hookPayload(now)
        permission["hook_event_name"] = "PermissionRequest"; permission["tool_name"] = "Bash"
        permission["tool_input"] = ["command": "echo fixture"]
        for payload in [question, permission] { _ = try engine.handleClaudeHook(payload, at: now) }
        var tracker = AttentionTracker()
        try expect(tracker.update(engine.snapshot).isEmpty, "Parent and inherited child automatic requests stay quiet")
        try expectEqual(engine.snapshot.attentionCount, 0)
        try expectEqual(engine.snapshot.sessions[0].claudeApprovals?.count, 1, "The automatic request remains visible and answerable")
        try await Task.sleep(nanoseconds: 900_000_000)
        engine.refreshNotices()
        try expectEqual(engine.snapshot.sessions[0].unreadNoticeCount, 0, "The countdown must not create an unread badge")

        try engine.setPaused(true)
        let paused = tracker.update(engine.snapshot)
        try expectEqual(paused.count, 2, "Pause makes both requests need manual attention")
        try expectEqual(tracker.update(engine.snapshot), paused, "Polling must not duplicate the alerts")
        try engine.setPaused(false)
        try expect(tracker.update(engine.snapshot).isEmpty, "Resuming withdraws pending alerts")
        try engine.setAutomatic(hookSession(12), enabled: false)
        try expectEqual(tracker.update(engine.snapshot).count, 2, "Turning the main OFF also alerts for the child")
        try engine.setAutomatic(hookSession(12), enabled: true)
        try expect(tracker.update(engine.snapshot).isEmpty)

        var manual = hookPayload(now, pid: 22)
        manual["tool_input"] = ["questions": [["question": "어떤 환경을 확인할까요?", "options": [["label": "개발"], ["label": "운영"]]]]]
        _ = try engine.handleClaudeHook(manual, at: now)
        try expectEqual(tracker.update(engine.snapshot).map(\.originSessionID), [hookSession(22)], "An unrelated manual question must not be hidden by automatic siblings")
        try await Task.sleep(nanoseconds: 900_000_000)
        engine.refreshNotices()
        try expectEqual(engine.snapshot.sessions[0].unreadNoticeCount, 1, "Only the manual child creates a badge on the parent")

        try engine.releaseClaudeApproval(sessionID: hookSession(21), requestID: permission["requestID"] as! String)
        let fallback = tracker.update(engine.snapshot)
        try expectEqual(fallback.count, 2, "Terminal handoff still needs attention even with automatic approval ON")
        try expect(fallback.contains { $0.originSessionID == hookSession(21) })
    }

    func testClaudeHookRestartAndExactResponseReplay() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let now = Date(), payload = hookPayload(now), first = try hookEngine(paths)
        _ = try first.handleClaudeHook(payload, at: now)
        let restarted = try hookEngine(paths)
        try expect(bridgeWaiting(try restarted.handleClaudeHook(payload, at: now.addingTimeInterval(1))))
        try restarted.answerClaudeApproval(sessionID: hookSession(21), requestID: payload["requestID"] as! String, at: now.addingTimeInterval(1))
        let afterLostResponse = try hookEngine(paths)
        let response = bridgeAnswer(try afterLostResponse.handleClaudeHook(payload, at: now.addingTimeInterval(2)))!
        try expect(!response.isEmpty)
        let repeated = bridgeAnswer(try afterLostResponse.handleClaudeHook(payload, at: now.addingTimeInterval(3)))!
        try expectEqual(try JSONSerialization.data(withJSONObject: response, options: .sortedKeys), try JSONSerialization.data(withJSONObject: repeated, options: .sortedKeys))
        try expectEqual(afterLostResponse.snapshot.events.count, 1, "Retry must not produce another approval audit")
        try afterLostResponse.acknowledgeClaudeHook(payload, at: now.addingTimeInterval(3))
        try afterLostResponse.acknowledgeClaudeHook(payload, at: now.addingTimeInterval(3))
        try expectEqual(afterLostResponse.snapshot.events.count, 1)
        var altered = payload; altered["tool_input"] = ["questions": []]
        try expectThrows(try afterLostResponse.handleClaudeHook(altered, at: now.addingTimeInterval(4)))
        var permission = payload; permission["requestID"] = UUID().uuidString; permission["hook_event_name"] = "PermissionRequest"
        try expect(bridgeAnswer(try afterLostResponse.handleClaudeHook(permission, at: now.addingTimeInterval(4)))!.isEmpty)
    }

    func testClaudeHookPauseManualAndConcurrentIsolation() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date()
        let a = hookPayload(now), b = hookPayload(now, pid: 22), c = hookPayload(now, number: 2)
        for payload in [a, b, c] { _ = try engine.handleClaudeHook(payload, at: now) }
        try expectEqual(AttentionRequest.candidates(engine.snapshot.sessions.first { $0.id == hookSession(12) }!, paused: false).count, 3)
        try engine.setAutomatic(hookSession(12), enabled: true); try engine.setPaused(true)
        try expect(bridgeWaiting(try engine.handleClaudeHook(a, at: now.addingTimeInterval(6))))
        try engine.answerClaudeApproval(sessionID: hookSession(21), requestID: a["requestID"] as! String, at: now.addingTimeInterval(6))
        _ = try engine.handleClaudeHook(a, at: now.addingTimeInterval(6))
        try expectThrows(try engine.answerClaudeApproval(sessionID: hookSession(22), requestID: c["requestID"] as! String))
        var unrelated = hookPayload(now); unrelated["hook_event_name"] = "PostToolUse"
        _ = try engine.handleClaudeHook(unrelated, at: now.addingTimeInterval(6))
        try expectEqual(AttentionRequest.candidates(engine.snapshot.sessions.first { $0.id == hookSession(12) }!, paused: true).count, 2)
        try engine.setPaused(false)
        for payload in [b, c] { try expect(!bridgeAnswer(try engine.handleClaudeHook(payload, at: now.addingTimeInterval(7)))!.isEmpty) }
    }

    func testClaudeHookHandoffExpiryAndPIDReuse() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let processes = HookProcesses(), engine = try hookEngine(paths, processes: processes), now = Date()
        let payload = hookPayload(now), id = payload["requestID"] as! String
        _ = try engine.handleClaudeHook(payload, at: now)
        try engine.releaseClaudeApproval(sessionID: hookSession(21), requestID: id)
        try expect(bridgeAnswer(try engine.handleClaudeHook(payload, at: now))!.isEmpty)
        var permission = payload; permission["requestID"] = UUID().uuidString; permission["hook_event_name"] = "PermissionRequest"
        try expect(bridgeAnswer(try engine.handleClaudeHook(permission, at: now))!.isEmpty, "Handoff must not trap the same question again")
        try expectThrows(try engine.answerClaudeApproval(sessionID: hookSession(21), requestID: id))
        let next = hookPayload(now); _ = try engine.handleClaudeHook(next, at: now)
        try expectThrows(try engine.answerClaudeApproval(sessionID: hookSession(21), requestID: next["requestID"] as! String, at: now.addingTimeInterval(601)))
        try expect(bridgeAnswer(try engine.handleClaudeHook(next, at: now.addingTimeInterval(601)))!.isEmpty)
        processes.records = hookProcesses.map { original in var record = original; if record.pid == 21 { record.started = "Tue Sep 22 10:00:00 2026" }; return record }
        try expectThrows(try engine.answerClaudeApproval(sessionID: hookSession(21), requestID: next["requestID"] as! String))
        try expectEqual(engine.snapshot.events.filter { $0.result == .delivered }.count, 0)
        processes.records = hookProcesses
        let disconnect = hookPayload(now)
        _ = try engine.handleClaudeHook(disconnect, at: now)
        try engine.removeClaude(settingsURL: paths.directory.appendingPathComponent("fixture-settings.json"))
        try expect(bridgeAnswer(try engine.handleClaudeHook(disconnect, at: now))!.isEmpty, "Disconnect must return outstanding hooks to Claude")
        try expectThrows(try engine.answerClaudeApproval(sessionID: hookSession(21), requestID: disconnect["requestID"] as! String))
    }

    func testClaudeHookDurableSaveFailureAndRetry() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date(), payload = hookPayload(now), id = payload["requestID"] as! String
        _ = try engine.handleClaudeHook(payload, at: now)
        _ = try CommandRunner.run("/usr/bin/sqlite3", [paths.database, "CREATE TRIGGER fail_hook_audit BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'fixture'); END;"])
        try expectThrows(try engine.answerClaudeApproval(sessionID: hookSession(21), requestID: id, at: now))
        try expect(engine.snapshot.events.isEmpty)
        let restarted = try hookEngine(paths)
        try expect(bridgeWaiting(try restarted.handleClaudeHook(payload, at: now)), "A rolled back response cannot approve after restart")
        _ = try CommandRunner.run("/usr/bin/sqlite3", [paths.database, "DROP TRIGGER fail_hook_audit"])
        try restarted.answerClaudeApproval(sessionID: hookSession(21), requestID: id, at: now)
        try expect(!bridgeAnswer(try restarted.handleClaudeHook(payload, at: now))!.isEmpty)
        try expectEqual(restarted.snapshot.events.count, 1)
    }

    func testClaudeHookGeneralPermissionAndUnsupportedQuestion() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date()
        var permission = hookPayload(now); permission["hook_event_name"] = "PermissionRequest"; permission["tool_name"] = "Bash"; permission["tool_input"] = ["command": "echo fixture"]
        _ = try engine.handleClaudeHook(permission, at: now)
        try engine.answerClaudeApproval(sessionID: hookSession(21), requestID: permission["requestID"] as! String, at: now)
        let output = bridgeAnswer(try engine.handleClaudeHook(permission, at: now))?["hookSpecificOutput"] as? JSONObject
        try expectEqual((output?["decision"] as? JSONObject)?["behavior"] as? String, "allow")
        var question = hookPayload(now)
        question["tool_input"] = ["questions": [["question": "어떤 환경?", "options": [["label": "개발"], ["label": "운영"]]]]]
        try expect(bridgeAnswer(try engine.handleClaudeHook(question, at: now))!.isEmpty)
        try expect(engine.snapshot.sessions.first { $0.id == hookSession(12) }!.backgroundChildren.first { $0.id == hookSession(21) }!.claudeApprovals == nil)
    }

    func testClaudeLiveHookOwnsScreenAndRechecksParent() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let processes = HookProcesses(), now = Date()
        processes.records = hookProcesses.filter { $0.pid < 20 }
        let engine = try hookEngine(paths, processes: processes)
        var permission = hookPayload(now, pid: 12)
        permission["hook_event_name"] = "PermissionRequest"; permission["tool_name"] = "Bash"; permission["tool_input"] = ["command": "echo fixture"]
        _ = try engine.handleClaudeHook(permission, at: now)
        try engine.setAutomatic(hookSession(12), enabled: true)
        engine.receiveScreen(sessionID: hookSession(12), raw: "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel", generation: "mirror", source: .terminalScreen)
        try expectEqual(engine.snapshot.sessions.first { $0.id == hookSession(12) }?.channel, .hook)
        try expectEqual(engine.snapshot.sessions.first { $0.id == hookSession(12) }?.claudeApprovals?.count, 1)
        try expect(engine.snapshot.events.isEmpty, "A still-open hook excludes screen approval")
        try engine.releaseClaudeApproval(sessionID: hookSession(12), requestID: permission["requestID"] as! String)
        processes.records = hookProcesses
        engine.updateDiscovery(ProcessDiscovery.sessions(processes.records), records: processes.records)
        let child = hookPayload(now)
        _ = try engine.handleClaudeHook(child, at: now)
        // The next poll's precheck still sees the parent; the final process read discovers its exit.
        processes.records = hookProcesses.filter { $0.pid != 12 }
        try expect(bridgeWaiting(try engine.handleClaudeHook(child, at: now.addingTimeInterval(6))))
        try expect(engine.snapshot.events.allSatisfy { $0.result == .manual })
        try expectEqual(engine.snapshot.sessions.first { $0.id == hookSession(21) }?.automatic, false)
    }
}
