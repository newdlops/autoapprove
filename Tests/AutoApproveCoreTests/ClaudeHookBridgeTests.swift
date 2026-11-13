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
    engine.automaticConfirmationDelay = 5
    engine.updateDiscovery(ProcessDiscovery.sessions(processes.records), records: processes.records)
    return engine
}
private func fixturePaths() -> AppPaths { AppPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("aa-hook-" + UUID().uuidString)) }

extension ApprovalTests {
    func testClaudeTaskChoicesStayManualWhileConfirmationsContinue() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date()
        defer { engine.stop() }
        var start = hookPayload(now, pid: 12); start["hook_event_name"] = "SessionStart"
        _ = try engine.handleClaudeHook(start, at: now)
        try engine.setAutomatic(hookSession(12), enabled: true)
        let cases: [(String, [String], Bool)] = [
            ("어떤 환경을 사용할까요?", ["개발 (추천)", "운영"], false),
            ("Which environment?", ["Yes, use staging", "No, use production"], false),
            ("What should run?", ["Allow: deploy", "Deny"], false),
            ("Which task?", ["Yes", "No, run tests instead"], false),
            ("여러 항목을 고르세요", ["응", "아니오"], true),
            ("cp fixture ~/Library/LaunchAgents/com.fixture.plist 대신 어떤 예약 방법을 쓸까요?", ["프로젝트 타이머", "수동 실행"], false)
        ]
        for event in ["PreToolUse", "PermissionRequest"] {
            for (title, labels, multiSelect) in cases {
                var payload = hookPayload(now)
                payload["hook_event_name"] = event
                let input: JSONObject = ["questions": [["question": title, "multiSelect": multiSelect,
                    "options": labels.map { ["label": $0, "description": "선택한 항목으로 진행합니다."] }]]]
                payload["tool_input"] = input
                // AutoApprove cannot answer a task choice, so the hook returns at once and Claude's terminal shows it.
                try expectEqual(bridgeAnswer(try engine.handleClaudeHook(payload, at: now))?.isEmpty, true, "A task choice is released to Claude's terminal at once")
                try expectEqual(bridgeAnswer(try engine.handleClaudeHook(payload, at: now.addingTimeInterval(60)))?.isEmpty, true, "A repeated task choice gets the same release, never a default answer")
                let requestID = payload["requestID"] as! String
                let child = engine.snapshot.sessions.first { $0.id == hookSession(12) }?.backgroundChildren.first { $0.id == hookSession(21) }
                try expect(child?.pendingInTerminal == true, "The released choice is pending in the terminal")
                try expect(child?.claudeApprovals?.contains { $0.id == requestID } != true, "A released choice leaves no app-held card")
                try expect(child?.pendingSummary?.isEmpty == false, "The terminal request keeps a summary for the app")
                try engine.acknowledgeClaudeHook(payload, at: now.addingTimeInterval(60))
            }
            var confirmation = hookPayload(now, pid: 22)
            confirmation["hook_event_name"] = event
            confirmation["tool_input"] = ["questions": [["question": "계속 진행할까요?", "options": [["label": "아니오"], ["label": "응"]]]]]
            try expect(bridgeWaiting(try engine.handleClaudeHook(confirmation, at: now)))
            let output = bridgeAnswer(try engine.handleClaudeHook(confirmation, at: now.addingTimeInterval(5)))!["hookSpecificOutput"] as! JSONObject
            let decision = event == "PreToolUse" ? output : output["decision"] as! JSONObject
            try expectEqual((decision["updatedInput"] as? JSONObject)?["answers"] as? [String: String], ["계속 진행할까요?": "응"])
            try engine.acknowledgeClaudeHook(confirmation, at: now.addingTimeInterval(5))
        }
        var riskyConfirmation = hookPayload(now)
        riskyConfirmation["hook_event_name"] = "PermissionRequest"
        riskyConfirmation["tool_input"] = ["questions": [["question": "sudo id 명령을 실행할까요?", "options": [["label": "Yes"], ["label": "No"]]]]]
        let riskyOutput = bridgeAnswer(try engine.handleClaudeHook(riskyConfirmation, at: now))?["hookSpecificOutput"] as? JSONObject
        try expectEqual((riskyOutput?["decision"] as? JSONObject)?["behavior"] as? String, "deny", "A risky yes/no request still receives safe redirection")
        var operation = hookPayload(now)
        operation["hook_event_name"] = "PermissionRequest"; operation["tool_name"] = "Bash"
        operation["tool_input"] = ["command": "cp fixture ~/Library/LaunchAgents/com.fixture.plist"]
        let output = bridgeAnswer(try engine.handleClaudeHook(operation, at: now))?["hookSpecificOutput"] as? JSONObject
        try expectEqual((output?["decision"] as? JSONObject)?["behavior"] as? String, "deny", "Actual system changes still receive safe redirection")
    }

    func testClaudeAppApprovalThenThirtySequentialQuestions() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date(), first = hookPayload(now)
        var tracker = AttentionTracker()
        // A manual session cannot answer, so the question returns to Claude's terminal at once.
        try expectEqual(bridgeAnswer(try engine.handleClaudeHook(first, at: now))?.isEmpty, true, "A manual question is released to the terminal at once")
        try expectEqual(tracker.update(engine.snapshot).count, 1, "An OFF session still needs manual attention in the terminal")
        let parent = engine.snapshot.sessions.first { $0.id == hookSession(12) }!
        try expect(parent.backgroundChildren.first { $0.id == hookSession(21) }?.claudeApprovals?.isEmpty ?? true, "A released question is not held in the app")
        try expect(!parent.automatic)
        try engine.setAutomatic(hookSession(12), enabled: true)
        try expect(engine.snapshot.sessions.first { $0.id == hookSession(12) }!.automatic)
        try expectEqual(bridgeAnswer(try engine.handleClaudeHook(first, at: now))?.isEmpty, true, "A released question is never answered after the fact")
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
        let automaticAnswers = engine.snapshot.events.filter { $0.outcome == "질문 응답 전달" }
        try expectEqual(automaticAnswers.count, 30, "Only the thirty automatic questions were answered by AutoApprove")
        try expect(automaticAnswers.allSatisfy { $0.sessionID == hookSession(12) && $0.originSessionID == hookSession(21) })
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
        // The manual question is released to the terminal, so the restarted app has no answer to replay.
        let released = bridgeAnswer(try restarted.handleClaudeHook(payload, at: now.addingTimeInterval(1)))
        try expectEqual(released?.isEmpty, true, "A restarted manual question is released without an app answer")
        let afterLostResponse = try hookEngine(paths)
        let response = bridgeAnswer(try afterLostResponse.handleClaudeHook(payload, at: now.addingTimeInterval(2)))!
        let repeated = bridgeAnswer(try afterLostResponse.handleClaudeHook(payload, at: now.addingTimeInterval(3)))!
        try expectEqual(try JSONSerialization.data(withJSONObject: response, options: .sortedKeys), try JSONSerialization.data(withJSONObject: repeated, options: .sortedKeys))
        try expect(afterLostResponse.snapshot.events.allSatisfy { $0.outcome != "질문 응답 전달" }, "Retry must not produce an automatic answer audit")
        try afterLostResponse.acknowledgeClaudeHook(payload, at: now.addingTimeInterval(3))
        try afterLostResponse.acknowledgeClaudeHook(payload, at: now.addingTimeInterval(3))
        try expect(afterLostResponse.snapshot.events.allSatisfy { $0.outcome != "질문 응답 전달" })
        var altered = payload; altered["tool_input"] = ["questions": []]
        try expectThrows(try afterLostResponse.handleClaudeHook(altered, at: now.addingTimeInterval(4)))
        var permission = payload; permission["requestID"] = UUID().uuidString; permission["hook_event_name"] = "PermissionRequest"
        try expect(bridgeAnswer(try afterLostResponse.handleClaudeHook(permission, at: now.addingTimeInterval(4)))!.isEmpty)
    }

    func testClaudeSavedResponseValidatesWholePayloadAndAcknowledgement() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date(), payload = hookPayload(now)
        defer { engine.stop() }
        // The released response is the exact `{}` Claude receives; every replay must match it.
        let answer = bridgeAnswer(try engine.handleClaudeHook(payload, at: now))!
        let mutations: [(inout JSONObject) -> Void] = [
            { $0["tool_input"] = ["questions": []] },
            { $0["cwd"] = "/different/fixture" },
            { $0["hook_event_name"] = "PermissionRequest" },
            { $0["session_id"] = "another-provider" },
            { $0["agentPID"] = 22 },
            { $0["agentStarted"] = "another-start" },
            { $0["tty"] = "/dev/ttys038" },
            { $0["autoapproveExpiresAt"] = now.addingTimeInterval(599).timeIntervalSince1970 },
            { $0["tool_name"] = "Read" },
            { $0["tool_use_id"] = "another-tool" },
            { $0["extra"] = "e\u{301} 🤖 /\u{0000}\u{0004}" }
        ]
        for mutate in mutations {
            var changed = payload; mutate(&changed)
            try expectThrows(try engine.handleClaudeHook(changed, at: now))
            try engine.acknowledgeClaudeHook(changed, at: now)
            try expect(engine.snapshot.events.allSatisfy { $0.outcome != "질문 응답 전달" }, "A changed envelope cannot create an answer from the saved release")
        }
        let invalid: [(inout JSONObject) -> Void] = [
            { $0["autoapproveProtocol"] = 2 },
            { $0["requestID"] = "not-a-uuid" },
            { $0.removeValue(forKey: "hook_event_name") },
            { $0.removeValue(forKey: "session_id") },
            { $0["session_id"] = "" },
            { $0["autoapproveExpiresAt"] = now.timeIntervalSince1970 },
            { $0["autoapproveExpiresAt"] = now.addingTimeInterval(611).timeIntervalSince1970 },
            { $0["autoapproveExpiresAt"] = Double.infinity },
            { $0["autoapproveExpiresAt"] = Double.nan }
        ]
        for mutate in invalid {
            var changed = payload; mutate(&changed)
            try expect(bridgeAnswer(try engine.handleClaudeHook(changed, at: now))!.isEmpty)
            try engine.acknowledgeClaudeHook(changed, at: now)
            try expect(engine.snapshot.events.allSatisfy { $0.outcome != "질문 응답 전달" })
        }
        try engine.acknowledgeClaudeHook(payload, at: now)
        try engine.acknowledgeClaudeHook(payload, at: now)
        try expect(engine.snapshot.events.allSatisfy { $0.outcome != "질문 응답 전달" }, "A released question never creates an automatic answer")
        let repeated = bridgeAnswer(try engine.handleClaudeHook(payload, at: now))!
        try expectEqual(try JSONSerialization.data(withJSONObject: repeated, options: .sortedKeys),
                        try JSONSerialization.data(withJSONObject: answer, options: .sortedKeys))
    }

    func testPendingClaudeHookRechecksChangedInstallerSource() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date()
        defer { engine.stop() }
        let tools = paths.directory.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let script = tools.appendingPathComponent("install_fixture.py")
        try "print('synthetic report')".write(to: script, atomically: true, encoding: .utf8)
        var request = hookPayload(now)
        request["hook_event_name"] = "PermissionRequest"; request["tool_name"] = "Bash"
        request["cwd"] = paths.directory.path
        request["tool_input"] = ["command": "python3 tools/install_fixture.py --install"]
        // A manual installer request is released to Claude's terminal dialog at once.
        try expectEqual(bridgeAnswer(try engine.handleClaudeHook(request, at: now))?.isEmpty, true)
        func risk() -> SystemCommandRisk? {
            engine.snapshot.sessions.first { $0.id == hookSession(12) }?.backgroundChildren
                .first { $0.id == hookSession(21) }?.systemCommandRisk
        }
        try expectNil(risk())
        // Write text only: this synthetic installer is never executed.
        try "Path.home().joinpath('Library/LaunchAgents/com.fixture.test.plist').write_text('fixture')"
            .write(to: script, atomically: true, encoding: .utf8)
        // A new request inspects the current installer source; the released one is never answered again.
        // A new tool call has a new identity; a retry of the same tool call returns the saved release.
        var retry = request; retry["requestID"] = UUID().uuidString; retry["tool_use_id"] = UUID().uuidString
        try expectEqual(bridgeAnswer(try engine.handleClaudeHook(retry, at: now.addingTimeInterval(1)))?.isEmpty, true)
        try expectEqual(risk()?.kind, .persistence, "A new request must inspect current installer source again")
        try expect(engine.snapshot.events.allSatisfy { !["승인 전달", "질문 응답 전달"].contains($0.outcome) }, "Releasing an installer request never approves it")
    }

    func testClaudeHookPreparationRespectsEffectiveSessionDirectory() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date()
        defer { engine.stop() }
        let tools = paths.directory.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try "Path.home().joinpath('Library/LaunchAgents/com.fixture.test.plist').write_text('fixture')"
            .write(to: tools.appendingPathComponent("install_fixture.py"), atomically: true, encoding: .utf8)
        var start = hookPayload(now)
        start["hook_event_name"] = "SessionStart"; start["cwd"] = paths.directory.path
        _ = try engine.handleClaudeHook(start, at: now)
        try engine.setAutomatic(hookSession(12), enabled: true)
        var request = hookPayload(now)
        request["tool_name"] = "Bash"; request.removeValue(forKey: "cwd")
        request["tool_input"] = ["command": "python3 tools/install_fixture.py --install"]
        let response = bridgeAnswer(try engine.handleClaudeHook(request, at: now))
        let output = response?["hookSpecificOutput"] as? JSONObject
        try expectEqual(output?["permissionDecision"] as? String, "deny",
                        "A missing payload cwd must use the current session directory for installer inspection")
        try expectEqual(engine.snapshot.events.first?.outcome, "시스템 변경 거절 · 안전한 대안 안내")
    }

    func testClaudeHookPauseManualAndConcurrentIsolation() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date()
        let a = hookPayload(now), b = hookPayload(now, pid: 22), c = hookPayload(now, number: 2)
        // Each manual request is released to its own terminal; none waits for an app answer.
        for payload in [a, b, c] { try expectEqual(bridgeAnswer(try engine.handleClaudeHook(payload, at: now))?.isEmpty, true) }
        // Attention is one item per waiting session: child 21 holds two released requests, child 22 one.
        try expectEqual(AttentionRequest.candidates(engine.snapshot.sessions.first { $0.id == hookSession(12) }!, paused: false).count, 2)
        try engine.setAutomatic(hookSession(12), enabled: true); try engine.setPaused(true)
        try expectEqual(bridgeAnswer(try engine.handleClaudeHook(a, at: now.addingTimeInterval(6)))?.isEmpty, true, "A released request is never answered after pause or automatic approval changes")
        var unrelated = hookPayload(now); unrelated["hook_event_name"] = "PostToolUse"
        _ = try engine.handleClaudeHook(unrelated, at: now.addingTimeInterval(6))
        // Claude's PostToolUse for child 21 ends its released requests; child 22's request is still waiting in its terminal.
        let parentAfterPause = engine.snapshot.sessions.first { $0.id == hookSession(12) }!
        let stillWaiting = AttentionRequest.candidates(parentAfterPause, paused: true).map(\.sourceSessionID)
        try expect(stillWaiting.contains(hookSession(22)))
        try engine.setPaused(false)
        for payload in [b, c] { try expectEqual(bridgeAnswer(try engine.handleClaudeHook(payload, at: now.addingTimeInterval(7)))?.isEmpty, true) }
        try expect(engine.snapshot.events.allSatisfy { !["승인 전달", "질문 응답 전달"].contains($0.outcome) }, "Released requests never create an automatic answer")
    }

    func testClaudeHookHandoffExpiryAndPIDReuse() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let processes = HookProcesses(), engine = try hookEngine(paths, processes: processes), now = Date()
        let payload = hookPayload(now), id = payload["requestID"] as! String
        _ = try engine.handleClaudeHook(payload, at: now)
        // A released request is already in Claude's terminal, so the app has nothing to hand back.
        try expectThrows(try engine.releaseClaudeApproval(sessionID: hookSession(21), requestID: id))
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
        let engine = try hookEngine(paths), now = Date(), payload = hookPayload(now)
        _ = try CommandRunner.run("/usr/bin/sqlite3", [paths.database, "CREATE TRIGGER fail_hook_receipt BEFORE INSERT ON claude_hooks BEGIN SELECT RAISE(ABORT, 'fixture'); END;"])
        // A release whose receipt cannot be saved must fail, so the helper retries instead of Claude receiving an unsaved answer.
        try expectThrows(try engine.handleClaudeHook(payload, at: now))
        try expect(engine.snapshot.events.allSatisfy { !["승인 전달", "질문 응답 전달"].contains($0.outcome) }, "A failed release never records an approval")
        let restarted = try hookEngine(paths)
        _ = try CommandRunner.run("/usr/bin/sqlite3", [paths.database, "DROP TRIGGER fail_hook_receipt"])
        try expectEqual(bridgeAnswer(try restarted.handleClaudeHook(payload, at: now))?.isEmpty, true, "After the fault clears, the retry releases the request once")
        try expectEqual(bridgeAnswer(try restarted.handleClaudeHook(payload, at: now))?.isEmpty, true, "The saved release is replayed exactly")
        try expect(restarted.snapshot.events.allSatisfy { !["승인 전달", "질문 응답 전달"].contains($0.outcome) })
    }

    func testClaudeHookGeneralPermissionAndUnsupportedQuestion() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date()
        var permission = hookPayload(now); permission["hook_event_name"] = "PermissionRequest"; permission["tool_name"] = "Bash"; permission["tool_input"] = ["command": "echo fixture"]
        // A manual general permission is released to Claude's terminal dialog instead of waiting for an app answer.
        try expectEqual(bridgeAnswer(try engine.handleClaudeHook(permission, at: now))?.isEmpty, true)
        var question = hookPayload(now)
        question["tool_input"] = ["questions": [["question": "어떤 환경?", "options": [["label": "개발"], ["label": "운영"]]]]]
        try expectEqual(bridgeAnswer(try engine.handleClaudeHook(question, at: now))?.isEmpty, true, "A manual question is released to the terminal")
        let child = engine.snapshot.sessions.first { $0.id == hookSession(12) }!.backgroundChildren.first { $0.id == hookSession(21) }
        try expectEqual(child?.pendingInTerminal, true, "The released question is pending in the terminal")
        try expect(child?.claudeApprovals?.isEmpty ?? true, "The released question leaves no app card")
        var invalid = hookPayload(now); invalid["tool_input"] = ["questions": []]
        try expect(bridgeAnswer(try engine.handleClaudeHook(invalid, at: now))!.isEmpty, "Malformed question preserves the original terminal flow")
    }

    func testClaudeLiveHookOwnsScreenAndRechecksParent() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let processes = HookProcesses(), now = Date()
        processes.records = hookProcesses.filter { $0.pid < 20 }
        let engine = try hookEngine(paths, processes: processes)
        // Only a request AutoApprove can answer within its confirmation window keeps the hook open.
        var start = hookPayload(now, pid: 12); start["hook_event_name"] = "SessionStart"
        _ = try engine.handleClaudeHook(start, at: now)
        try engine.setAutomatic(hookSession(12), enabled: true)
        var permission = hookPayload(now, pid: 12)
        permission["hook_event_name"] = "PermissionRequest"; permission["tool_name"] = "Bash"; permission["tool_input"] = ["command": "echo fixture"]
        try expect(bridgeWaiting(try engine.handleClaudeHook(permission, at: now)))
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

    func testReleasedClaudeQuestionTakesOnlyItsChoiceScreen() throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let processes = HookProcesses(), now = Date()
        processes.records = hookProcesses.filter { $0.pid < 20 }
        let engine = try hookEngine(paths, processes: processes)
        var start = hookPayload(now, pid: 12); start["hook_event_name"] = "SessionStart"
        _ = try engine.handleClaudeHook(start, at: now)
        var question = hookPayload(now, pid: 12)
        question["tool_input"] = ["questions": [["question": "어느 환경을 쓸까요?", "options": [["label": "개발"], ["label": "운영"]]]]]
        // The manual question is released; no app card keeps the hook open.
        try expectEqual(bridgeAnswer(try engine.handleClaudeHook(question, at: now))?.isEmpty, true)
        // A permission dialog must not take ownership of a released question.
        engine.receiveScreen(sessionID: hookSession(12), raw: "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel", generation: "mirror", source: .terminalScreen)
        try expectEqual(engine.snapshot.sessions.first { $0.id == hookSession(12) }?.channel, .hook)
        // Its own choice menu may take the released question.
        engine.receiveScreen(sessionID: hookSession(12), raw: "어느 환경을 쓸까요?\n❯ 1. 개발\n  2. 운영\nEnter to select", generation: "mirror-choice", source: .terminalScreen)
        let released = engine.snapshot.sessions.first { $0.id == hookSession(12) }
        try expectEqual(released?.channel, .terminalScreen, "The released question is answered only through its choice screen")
        try expect(released?.pendingInTerminal == true)
    }

    func testClaudeWebAnswersMultipleQuestionsAndEditingHold() async throws {
        let paths = fixturePaths(); defer { try? FileManager.default.removeItem(at: paths.directory) }
        let engine = try hookEngine(paths), now = Date()
        var payload = hookPayload(now)
        let input: JSONObject = ["questions": [
            ["question": "환경?", "options": [["label": "개발"], ["label": "운영"]]],
            ["question": "확인 항목?", "multiSelect": true, "options": [["label": "화면"], ["label": "입력"]]]]]
        payload["tool_input"] = input
        // A manual multi-question form is released to Claude's terminal; the app form has nothing to answer.
        try expectEqual(bridgeAnswer(try engine.handleClaudeHook(payload, at: now))?.isEmpty, true)
        try engine.setAutomatic(hookSession(12), enabled: true)
        try expectEqual(bridgeAnswer(try engine.handleClaudeHook(payload, at: now.addingTimeInterval(6)))?.isEmpty, true, "General questions never auto-select a default")
        try expectThrows(try engine.replyClaudeQuestions(sessionID: hookSession(21), requestID: payload["requestID"] as! String, answers: [:], at: now.addingTimeInterval(6)))
        try expectThrows(try engine.replyClaudeQuestions(sessionID: hookSession(21), requestID: payload["requestID"] as! String,
            answers: ["0": ["choices": ["개발"], "text": ""], "1": ["choices": ["화면", "입력"], "text": "한글🧪"]], at: now.addingTimeInterval(6)))
        let yes = hookPayload(now)
        _ = try engine.handleClaudeHook(yes, at: now)
        _ = try await engine.remoteAction(["action": "beginClaudeQuestion", "sessionID": hookSession(21), "requestIDForApproval": yes["requestID"]!])
        // Editing turns the automatic answer off, so the hook is handed to Claude's terminal instead of waiting in the app.
        try expectEqual(bridgeAnswer(try engine.handleClaudeHook(yes, at: now.addingTimeInterval(6)))?.isEmpty, true, "Editing stops the five-second automatic answer")
        try expect(engine.snapshot.sessions.first { $0.id == hookSession(12) }!.automatic)
    }
}
