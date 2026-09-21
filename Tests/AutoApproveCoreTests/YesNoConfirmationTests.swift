import Foundation
import AutoApproveCore

private let startQuestion = "이 워크트리는 현재 production 브랜치이고 워킹트리가 깨끗합니다. 여기서 바로 작업을 시작할까요?"

private func startInput(_ question: String = startQuestion, labels: [String] = ["예", "아니오"]) -> JSONObject {
    ["questions": [["question": question, "header": "작업 위치", "multiSelect": false,
        "options": labels.map { ["label": $0, "description": $0 == "예" ? "현재 작업 위치에서 진행합니다." : "작업 위치를 다시 정합니다."] }]]]
}

extension ApprovalTests {
    func testYesNoConfirmationSelection() throws {
        for question in [startQuestion, startQuestion.decomposedStringWithCanonicalMapping,
                         "계속 진행할까요?", "Should I start the work here?", "Can we continue the implementation?",
                         "지금 이 워크트리의 미커밋·브랜치 현황을 먼자 훑어볼까요?", "테스트를 실행해 보겠습니다."] {
            let input = startInput(question, labels: ["아니오", "예 (추천)"])
            let answer = YesNoConfirmation.detect(input)
            try expectEqual(answer?.question, question, "Use the original question text as the response key")
            try expectEqual(answer?.answer, "예 (추천)", "Use the yes label, not the first option")
            let updated = answer!.updatedInput(input)
            try expectEqual((updated["answers"] as? [String: String])?[question], "예 (추천)")
            try expectEqual(try JSONSerialization.data(withJSONObject: updated["questions"]!, options: [.sortedKeys]),
                            try JSONSerialization.data(withJSONObject: input["questions"]!, options: [.sortedKeys]))
        }
        for labels in [["예 — git 상태·브랜치·미커밋 변경을 훑습니다.", "아니오 — 기다립니다."],
                       ["네, 진행해주세요", "아니요, 기다려주세요"], ["YES!", "NO."], ["예 (권장)", "아니오"],
                       ["Yes (Recommended)", "No"], ["네".decomposedStringWithCanonicalMapping, "아니요"]] {
            try expectEqual(YesNoConfirmation.detect(startInput(labels: labels))?.answer, labels[0])
        }
        for input in [startInput("  \n"), startInput(labels: ["예시", "아니오"]),
                      startInput(labels: ["네트워크", "아니요"]), startInput(labels: ["Yesterday", "No"]),
                      startInput(labels: ["추천 작업", "다른 작업"]), startInput(labels: ["개발", "운영"]), startInput(labels: ["예", "예"]),
                      startInput(labels: ["예", "아니오", "직접 입력"])] {
            try expectNil(YesNoConfirmation.detect(input))
        }
        var input = startInput()
        var questions = input["questions"] as! [JSONObject]
        questions[0]["multiSelect"] = true; input["questions"] = questions
        try expectNil(YesNoConfirmation.detect(input))
        input = startInput(); input["questions"] = [questions[0], questions[0]]
        try expectNil(YesNoConfirmation.detect(input))
        input = startInput(); input["answers"] = [startQuestion: "아니오"]
        try expect(YesNoConfirmation.detect(input) == nil, "Do not overwrite an existing answer")
    }

    func testYesNoConfirmationHookAndAudit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-start-answer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory)
        let engine = try ApprovalEngine(paths: paths)
        _ = engine.handleHook(["session_id": "start", "requestID": "session", "hook_event_name": "SessionStart", "cwd": "/tmp/start-fixture"])
        try engine.setAutomatic("claude:start", enabled: true)
        var payload: JSONObject = ["session_id": "start", "requestID": "pre-one", "tool_use_id": "question-one",
            "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": startInput()]
        let result = engine.handleHook(payload)["hookSpecificOutput"] as? JSONObject
        try expectEqual(result?["hookEventName"] as? String, "PreToolUse")
        try expectEqual(result?["permissionDecision"] as? String, "allow")
        let updated = result?["updatedInput"] as? JSONObject
        try expectEqual((updated?["answers"] as? [String: String])?[startQuestion], "예")
        try expectEqual(engine.snapshot.sessions[0].phase, .working)
        try expectFalse(engine.snapshot.sessions[0].pendingInTerminal)
        payload["requestID"] = "permission-same"; payload["hook_event_name"] = "PermissionRequest"
        try expect(engine.handleHook(payload).isEmpty, "One tool call cannot answer twice across hook events")
        try expectEqual(engine.snapshot.events.count, 1)
        payload["tool_use_id"] = "question-two"; payload["requestID"] = "permission-new"
        let fallback = engine.handleHook(payload)["hookSpecificOutput"] as? JSONObject
        let decision = fallback?["decision"] as? JSONObject
        try expectEqual(decision?["behavior"] as? String, "allow")
        try expectEqual(((decision?["updatedInput"] as? JSONObject)?["answers"] as? [String: String])?[startQuestion], "예")
        _ = engine.handleHook(["session_id": "start", "requestID": "end", "hook_event_name": "SessionEnd"])
        let stored = try AuditStore(path: paths.database, readOnly: true)
        let history = try stored.history(result: .delivered)
        try expectEqual(history.total, 2)
        try expect(history.events.allSatisfy { $0.answer == "예" && $0.result == .delivered && $0.tool == "AskUserQuestion" })
        try expect(history.events.allSatisfy { $0.request?.contains("현재 작업 위치에서 진행합니다.") == true && $0.context?.cwd == "/tmp/start-fixture" })
        try expectEqual(try stored.history(result: .review).total, 0)
        try expectEqual(try stored.history(search: "예").total, 2)
    }

    func testYesNoConfirmationOptInAndPause() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-start-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        var payload: JSONObject = ["session_id": "policy", "requestID": "off", "tool_use_id": "off",
            "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": startInput()]
        try expect(engine.handleHook(payload).isEmpty)
        try expectEqual(engine.snapshot.sessions[0].phase, .input)
        try engine.setAutomatic("claude:policy", enabled: true)
        try engine.setPaused(true)
        payload["tool_use_id"] = "paused"; payload["requestID"] = "paused"
        try expect(engine.handleHook(payload).isEmpty)
        try engine.setPaused(false)
        payload["tool_use_id"] = "choice"; payload["requestID"] = "choice"
        payload["tool_input"] = startInput("어떤 프로젝트를 수정할까요?", labels: ["A", "B"])
        try expect(engine.handleHook(payload).isEmpty)
        try expectEqual(engine.snapshot.sessions[0].phase, .input)
        payload["session_id"] = "other"; payload["tool_input"] = startInput()
        try expect(engine.handleHook(payload).isEmpty, "Another session's setting cannot authorize this answer")
        try expect(engine.snapshot.events.allSatisfy { $0.answer == nil })
    }

    func testYesNoConfirmationRequiresSavedAudit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-start-save-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory)
        let engine = try ApprovalEngine(paths: paths)
        _ = engine.handleHook(["session_id": "save", "requestID": "session", "hook_event_name": "SessionStart"])
        try engine.setAutomatic("claude:save", enabled: true)
        let removed = try CommandRunner.run("/usr/bin/sqlite3", [paths.database, "DROP TABLE events"])
        try expectEqual(removed.status, 0)
        let result = engine.handleHook(["session_id": "save", "requestID": "save-failure", "hook_event_name": "PreToolUse",
            "tool_name": "AskUserQuestion", "tool_input": startInput()])
        try expect(result.isEmpty, "A response must not leave the app when its audit cannot be saved")
        try expectNotNil(engine.snapshot.health.auditError)
        try expectEqual(engine.snapshot.sessions[0].phase, .input)
        try expect(engine.snapshot.sessions[0].pendingInTerminal)
    }
}
