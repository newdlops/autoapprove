import Foundation
import AutoApproveCore

private let startQuestion = "이 워크트리는 현재 production 브랜치이고 워킹트리가 깨끗합니다. 여기서 바로 작업을 시작할까요?"

private func startInput(_ question: String = startQuestion, labels: [String] = ["예", "아니오"]) -> JSONObject {
    ["questions": [["question": question, "header": "작업 위치", "multiSelect": false,
        "options": labels.map { ["label": $0, "description": $0 == "예" ? "현재 작업 위치에서 진행합니다." : "작업 위치를 다시 정합니다."] }]]]
}

extension ApprovalTests {
    func testKoreanPermissionLabels() throws {
        let cases: [([String], Int)] = [
            (["허용", "항상 허용", "거부"], 0),
            (["항상 허용", "거부", "허용"], 2),
            (["거부", "허용 (추천)", "항상 허용"].map(\.decomposedStringWithCanonicalMapping), 1),
            (["허용 (a)", "항상\n허용 (s)", "거부 (esc)"], 0),
            (["허용", "거부"], 0), (["거부", "허용, 이번 요청만 허용"], 1),
            (["허용", "Always allow", "Deny"], 0), (["Allow", "항상 허용", "거부"], 0)
        ]
        for (labels, index) in cases {
            let input = startInput(labels: labels)
            let confirmation = YesNoConfirmation.detect(input)
            try expectEqual(confirmation?.answer, labels[index])
            try expectEqual((confirmation?.updatedInput(input)["answers"] as? [String: String])?[startQuestion], labels[index])
            try expectEqual(YesNoConfirmation.detect(QueuedQuestion(id: "korean-allow", threadID: "fixture", title: startQuestion, options: labels))?.answer, labels[index])
        }
        for labels in [["항상 허용", "거부"], ["허용, 항상 허용", "거부"],
                       ["허용", "허용", "거부"], ["허용", "예", "거부"],
                       ["허용", "다른 프로젝트", "거부"], ["허용목록", "항상 허용", "거부"],
                       ["허용됨", "거부"], ["허용", "거부됨"]] {
            try expect(YesNoConfirmation.detect(startInput(labels: labels)) == nil, "No unique current-request answer: \(labels)")
        }
        let scoped: JSONObject = ["questions": [["question": startQuestion, "options": [
            ["label": "허용", "description": "이 세션에서는 항상 허용"], ["label": "거부"]
        ]]]]
        try expectNil(YesNoConfirmation.detect(scoped))
        for agent: AgentKind in [.claude, .codex] {
            let heading = agent == .claude ? "Do you want to proceed?" : "Would you like to run the following command?"
            let screen = heading + "\n❯ 1. 허용 (a)\n  2. 항상\n     허용 (s)\n  3. 거부 (esc)\nPress enter to confirm or esc to cancel"
            try expectEqual(PromptDetector.detect(screen, agent: agent)?.answer, "1")
            try expectNotNil(PromptDetector.detect(screen.decomposedStringWithCanonicalMapping, agent: agent))
            try expectNil(PromptDetector.detect(screen.replacingOccurrences(of: "❯ 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "❯ 2."), agent: agent))
            try expectNil(PromptDetector.detect(screen + "\n❯ 새 질문", agent: agent))
        }
    }

    func testKoreanPermissionHookResponseAndAudit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-korean-allow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        let input = startInput("이 요청을 허용할까요?", labels: ["항상 허용", "거부", "허용"])
        var payload: JSONObject = ["session_id": "korean-allow", "requestID": "off", "tool_use_id": "off",
            "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": input]
        try expect(engine.handleHook(payload).isEmpty)
        try engine.setAutomatic("claude:korean-allow", enabled: true)
        for event in ["PreToolUse", "PermissionRequest"] {
            payload["hook_event_name"] = event; payload["requestID"] = event; payload["tool_use_id"] = event
            let output = engine.handleHook(payload)["hookSpecificOutput"] as? JSONObject
            let decision = event == "PreToolUse" ? output : output?["decision"] as? JSONObject
            try expectEqual(decision?[event == "PreToolUse" ? "permissionDecision" : "behavior"] as? String, "allow")
            let updated = decision?["updatedInput"] as? JSONObject
            try expectEqual((updated?["answers"] as? [String: String])?["이 요청을 허용할까요?"], "허용")
            try expectEqual(try JSONSerialization.data(withJSONObject: updated?["questions"] ?? [], options: [.sortedKeys]),
                            try JSONSerialization.data(withJSONObject: input["questions"]!, options: [.sortedKeys]))
            try expect(engine.handleHook(payload).isEmpty, "Do not answer the same Korean permission question twice")
        }
        let delivered = engine.snapshot.events.filter { $0.outcome == "질문 응답 전달" }
        try expectEqual(delivered.count, 2)
        try expect(delivered.allSatisfy { $0.answer == "허용" })
    }

    func testAllowConfirmationLabels() throws {
        let cases: [([String], Int)] = [
            (["Deny", "Allow"], 1), (["allow (Recommended)", "Don't allow"], 0),
            (["Do not allow", "ALLOW!"], 1), (["Don’t allow (esc)", "Allow (a)"], 1),
            (["Allow — 이번 작업을 진행합니다.", "No"], 0),
            (["Allow once", "Deny"], 0), (["Allow this request only", "Don't allow"], 0),
            (["Always allow", "Deny", "Allow once (Recommended)"], 2),
            (["Allow for this session", "Allow", "Don't allow"], 1),
            (["No", "Allow this time", "Yes, don't ask again"], 1),
            (["Allow", "Cancel"], 0),
            (["Allow", "Allow for this session", "Always allow", "Cancel"], 0)
        ]
        for (labels, index) in cases {
            let input = startInput(labels: labels)
            let confirmation = YesNoConfirmation.detect(input)
            try expectEqual(confirmation?.answer, labels[index], "Preserve the one-time Allow label: \(labels)")
            try expectEqual((confirmation?.updatedInput(input)["answers"] as? [String: String])?[startQuestion], labels[index])
            try expectEqual(YesNoConfirmation.detect(QueuedQuestion(id: "allow", threadID: "fixture", title: startQuestion, options: labels))?.answer, labels[index])
        }
        for labels in [["Don't allow", "Deny"], ["Allowance", "No"], ["Allowed", "No"],
                       ["Allow", "Yes", "Deny"], ["Always allow", "Deny"],
                       ["Allow for this session", "Deny"], ["Allow, don't ask again", "No"],
                       ["Allow", "Allow another project", "Deny"], ["Allow once", "Allow this time", "Deny"]] {
            try expect(YesNoConfirmation.detect(startInput(labels: labels)) == nil, "Do not guess an Allow choice: \(labels)")
        }
        let scoped: JSONObject = ["questions": [["question": startQuestion, "options": [
            ["label": "Allow", "description": "Always allow"], ["label": "Deny"]
        ]]]]
        try expectNil(YesNoConfirmation.detect(scoped))
        for agent: AgentKind in [.claude, .codex] {
            let title = agent == .codex ? "Would you like to run the following command?\n\n$ printf fixture" : "Do you want to proceed?"
            let screen = title + "\n› 1. Allow once\n  2. Always allow\n  3. Don't allow\nPress enter to confirm or esc to cancel"
            try expectEqual(PromptDetector.detect(screen, agent: agent)?.answer, "1")
        }
    }

    func testCodexToolPermissionColumnsAndCancellation() throws {
        let options = """
        › 1. Allow                   Run the tool and continue.
          2. Allow for this session  Run the tool and remember this choice for this session.
          3. Always allow            Run the tool and remember this choice for future tool calls.
          4. Cancel                  Cancel this tool call
        """
        for heading in ["Allow preview?", "Allow preview", "Approve app tool call?", "Would you like to run the following command?"] {
            let screen = heading + "\nTool: preview\nURL: http://localhost:4173\n" + options + "\nPress enter to submit or esc to cancel"
            let prompt = PromptDetector.detect(screen, agent: .codex)
            try expectEqual(prompt?.answer, "1", "Recognize the supplied four-choice tool permission")
            try expectEqual(prompt?.dialog, screen, "Final validation keeps the complete unmodified dialog")
            let wrapped = screen.replacingOccurrences(of: "remember this choice for", with: "remember this\n                             choice for")
            try expectEqual(PromptDetector.detect(wrapped, agent: .codex)?.requestIdentity, prompt?.requestIdentity)
            for invalid in [
                screen.replacingOccurrences(of: "Run the tool and continue.", with: "Run another tool instead."),
                screen.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "› 2."),
                screen + "\n› Next message", "```\n" + screen,
                screen.replacingOccurrences(of: "Press enter to submit or esc to cancel", with: "")
            ] { try expectNil(PromptDetector.detect(invalid, agent: .codex)) }
        }
        try expectNil(PromptDetector.detect("Which project should run first?\n" + options + "\nEnter to submit", agent: .codex))
        for labels in [["Allow preview", "Allow production", "Cancel"], ["Allow", "Run tests", "Always allow", "Cancel"], ["Allow", "Cancel", "Deny"]] {
            try expectNil(YesNoConfirmation.detect(startInput(labels: labels)))
        }
    }

    func testRepeatedPermissionChoicesPreferCurrentRequest() throws {
        let cases = [
            ["Yes", "Yes, don't ask again", "No"],
            ["Yes (y)", "Yes, don't ask again (a)", "No (esc)"],
            ["Yes (Recommended) [y]", "Yes, don't ask again [a]", "No [esc]"],
            ["Yes, proceed (y)", "Yes, and don't ask again for commands that start with `npm test` (p)", "No (esc)"],
            ["No", "Yes, don’t ask again", "Yes (Recommended)"],
            ["Yes, allow once", "Yes, do not ask me for approval again", "No"],
            ["Yes", "Yes, don't ask\nagain (a)", "No"],
            ["Yes", "Yes, approve for this session", "Yes, allow all edits during this session", "No"],
            ["예", "예, 앞으로 묻지 않기", "아니오"],
            ["아니오", "예, 이 세션에서는 항상 허용", "예, 이번 요청만 허용"],
            ["네", "네, 이후에도 허용", "네, 항상 승인", "아니요"].map(\.decomposedStringWithCanonicalMapping)
        ]
        let expected = [0, 0, 0, 0, 2, 0, 0, 0, 0, 2, 0]
        for (index, labels) in cases.enumerated() {
            let input = startInput(labels: labels)
            let answer = YesNoConfirmation.detect(input)
            try expectEqual(answer?.answer, labels[expected[index]], "Preserve the current-request label: \(labels)")
            try expectEqual((answer?.updatedInput(input)["answers"] as? [String: String])?[startQuestion], labels[expected[index]])
        }
        let described: JSONObject = ["questions": [["question": startQuestion, "options": [
            ["label": "Yes", "description": "Allow all edits during this session."],
            ["label": "No", "description": "Cancel"],
            ["label": "Yes, proceed", "description": "Allow this request"]
        ]]]]
        try expectEqual(YesNoConfirmation.detect(described)?.answer, "Yes, proceed")
    }

    func testRepeatedPermissionChoicesRejectDifferentDecisions() throws {
        for labels in [
            ["Yes, use staging", "Yes, use production", "No"],
            ["Yes", "Yes, also deploy", "No"],
            ["Yes", "Yes", "No"],
            ["Yes", "Yes, don't ask again", "Choose another project", "No"],
            ["Yes, don't ask again", "Yes, always allow", "No"],
            ["Yes", "Yes, don't ask again", "Yes, always allow"],
            ["Yes", "Yes, don't ask again", "No", "No, choose another task"]
        ] {
            try expect(YesNoConfirmation.detect(startInput(labels: labels)) == nil, "Keep distinct/ambiguous choices manual: \(labels)")
        }
        var input = startInput(labels: ["Yes", "Yes, don't ask again", "No"])
        var questions = input["questions"] as! [JSONObject]
        questions[0]["multiSelect"] = true; input["questions"] = questions
        try expectNil(YesNoConfirmation.detect(input))
        questions[0]["multiSelect"] = false; input["questions"] = [questions[0], questions[0]]
        try expectNil(YesNoConfirmation.detect(input))
        input["questions"] = questions; input["answers"] = [startQuestion: "No"]
        try expectNil(YesNoConfirmation.detect(input))
        let duplicateLabels: JSONObject = ["questions": [["question": startQuestion, "options": [
            ["label": "Yes", "description": "Allow once"],
            ["label": "Yes", "description": "Don't ask again"],
            ["label": "No", "description": "Cancel"]
        ]]]]
        try expect(YesNoConfirmation.detect(duplicateLabels) == nil, "A hook cannot disambiguate identical answer labels")
    }

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
                       ["Yes (Recommended)", "No"], ["Yes (y)", "No (esc)"], ["네".decomposedStringWithCanonicalMapping, "아니요"]] {
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
        payload["tool_input"] = startInput(labels: ["아니오", "예", "예, 앞으로 묻지 않기"])
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
