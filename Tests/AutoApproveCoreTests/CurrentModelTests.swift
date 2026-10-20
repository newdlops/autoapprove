import Foundation
import AutoApproveCore

private final class ModelInputProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: String
    private var sent: [String] = []
    var uncertain = false
    init(_ raw: String) { self.raw = raw }
    var screen: String { get { lock.lock(); defer { lock.unlock() }; return raw }
        set { lock.lock(); raw = newValue; lock.unlock() } }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return sent }
    func input(expected: String, value: RemoteTerminalInput) throws -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        guard raw == expected else { return .screenChanged }
        sent.append(value.bytes)
        if uncertain { throw AppError.message("합성 모델 선택 응답 유실") }
        return .sent
    }
}

extension ApprovalTests {
    func testCurrentModelQuestionPolicy() throws {
        let positives: [(String, [String], Int)] = [
            ("Which model?", ["Switch model", "Keep current model"], 1),
            ("Select a model", ["gpt-6.1-sol (current)", "gpt-6.2 (Recommended)"], 0),
            ("Choose a model", ["Claude Sonnet 4.6 (current)", "Claude Opus 4.7"], 0),
            ("모델을 바꿀까요?", ["다른 모델 사용", "기존 모델 유지 (권장)"], 1),
            ("모델 선택", ["gpt-6.1-sol [현재]", "gpt-6.2"], 0),
            ("Which model?", ["New model", "Current model"], 1),
            ("모델 선택", ["다른 모델", "현재 모델 그대로"], 1),
            ("Select model. Current model: gpt-6.1-sol", ["gpt-6.2", "gpt-6.1-sol"], 1),
            ("모델 선택 (현재 모델: claude-sonnet-4-6)", ["claude-opus-4-7", "claude-sonnet-4-6"], 1)
        ]
        for (title, options, index) in positives {
            let question = QueuedQuestion(id: "model", threadID: "fixture", title: title, options: options)
            try expectEqual(AutomaticQuestionDecision.detect(question)?.answer, options[index])
            try expect(YesNoConfirmation.detect(question) == nil, "Model choices are a separate explicit policy")
        }
        for (title, labels, answer) in [
            ("Would you like to switch to a different model?", ["Yes", "No"], "No"),
            ("Change the current model?", ["No (esc)", "Yes (y)"], "No (esc)"),
            ("Switch to gpt-6.2?", ["Yes", "No"], "No"),
            ("Try Claude Opus 4.7?", ["No", "Yes"], "No"),
            ("gpt-6.2로 바꿀까요?", ["예", "아니오"], "아니오"),
            ("모델을 변경할까요?", ["예", "아니오"], "아니오"),
            ("모델을 바꿀까요?", ["아니요", "네"], "아니요"),
            ("Keep using the current model?", ["No", "Yes"], "Yes"),
            ("Don't change the current model?", ["Yes", "No"], "Yes"),
            ("Do not keep the current model?", ["Yes", "No"], "No"),
            ("기존 모델을 계속 사용할까요?", ["아니오", "예"], "예"),
            ("Which model?", ["Use a different model", "No, keep current model"], "No, keep current model")
        ] {
            let decision = AutomaticQuestionDecision.detect(QueuedQuestion(id: "confirm-model", threadID: "fixture", title: title, options: labels))
            try expectEqual(decision?.answer, answer)
            try expectEqual(decision?.kind, .keepCurrentModel)
        }
        for (title, options) in [
            ("Which model?", ["gpt-6.1-sol (Recommended)", "gpt-6.2"]),
            ("Which model?", ["Keep current model", "Retain existing model"]),
            ("Which model?", ["Keep current model", "Keep current model"]),
            ("Which model?", ["Keep current model and deploy", "Switch model"]),
            ("Which model?", ["gpt-6.1-sol (current)", "claude-sonnet-4-6 (current)"]),
            ("Which project?", ["Keep current model", "Another project"]),
            ("Which model?", ["Yes, use staging", "No, use production"])
        ] { try expectNil(AutomaticQuestionDecision.detect(QueuedQuestion(id: "manual", threadID: "fixture", title: title, options: options))) }
        let title = "Which model?"
        var input: JSONObject = ["questions": [["question": title, "options": [["label": "gpt-6.2"], ["label": "gpt-6.1-sol", "description": "Currently selected model"]]]]]
        try expectEqual(AutomaticQuestionDecision.detect(input)?.answer, "gpt-6.1-sol")
        let decision = AutomaticQuestionDecision.detect(input)!
        try expectEqual((decision.updatedInput(input)["answers"] as? [String: String])?[title], "gpt-6.1-sol")
        var questions = input["questions"] as! [JSONObject]
        questions[0]["multiSelect"] = true; input["questions"] = questions
        try expectNil(AutomaticQuestionDecision.detect(input))
        questions[0]["multiSelect"] = false; input["questions"] = [questions[0], questions[0]]
        try expectNil(AutomaticQuestionDecision.detect(input))
        input["questions"] = questions; input["answers"] = [title: "gpt-6.2"]
        try expectNil(AutomaticQuestionDecision.detect(input))
    }

    func testCurrentModelHookPreservesOptInPauseAndAudit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-model-hook-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root))
        defer { engine.stop() }
        let title = "어떤 모델을 사용할까요?"
        let input: JSONObject = ["questions": [["question": title, "options": [["label": "다른 모델"], ["label": "기존 모델 유지"]]]]]
        var payload: JSONObject = ["session_id": "model", "requestID": "off", "tool_use_id": "off", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": input]
        try expect(engine.handleHook(payload).isEmpty)
        try engine.setAutomatic("claude:model", enabled: true); try engine.setPaused(true)
        payload["requestID"] = "paused"; payload["tool_use_id"] = "paused"
        try expect(engine.handleHook(payload).isEmpty)
        try engine.setPaused(false)
        for event in ["PreToolUse", "PermissionRequest"] {
            payload["hook_event_name"] = event; payload["requestID"] = event; payload["tool_use_id"] = event
            let output = engine.handleHook(payload)["hookSpecificOutput"] as? JSONObject
            let decision = event == "PreToolUse" ? output : output?["decision"] as? JSONObject
            try expectEqual((decision?["updatedInput"] as? JSONObject)?["answers"] as? [String: String], [title: "기존 모델 유지"])
            try expect(engine.handleHook(payload).isEmpty)
        }
        try expectEqual(engine.snapshot.events.filter { $0.outcome == "질문 응답 전달" && $0.answer == "기존 모델 유지" }.count, 2)
    }

    @MainActor private func currentModelFixture(_ root: URL, probe: ModelInputProbe, agent: AgentKind = .codex) async throws -> (ApprovalEngine, AgentSession) {
        let record = ProcessDiscovery.parse("42 1 ttys099 42 42 Mon Oct 5 09:00:00 2026 \(agent.rawValue)")[0]
        var session = AgentSession(id: record.key, agent: agent, pid: record.pid, started: record.started, tty: "/dev/ttys099", cwd: "/fixture", terminal: .iterm)
        session.channel = .itermScreen
        let tty = session.tty
        let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot(screens: [TerminalScreen(tty: tty, contents: probe.screen)]) },
            approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { _,expected,_,value in try probe.input(expected: expected, value: value) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), processReader: { [record] }, screenAdapters: [.iterm: adapter])
        engine.automaticConfirmationDelay = 0.05
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
        try engine.setAutomatic(session.id, enabled: true); await engine.refreshScreens()
        return (engine, session)
    }

    func testCurrentModelTerminalSelectionAndNoReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-model-terminal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = "Which model should be used?\n❯ 1. gpt-6.2\n  2. gpt-6.1-sol (current)\nEnter to select or esc to cancel"
        let changeModel = "Would you like to switch to a different model?\n❯ 1. Yes\n  2. No\nEnter to select or esc to cancel"
        let keepModel = "Keep using the current model?\n❯ 1. No\n  2. Yes\nEnter to select or esc to cancel"
        let modelPicker = screen.replacingOccurrences(of: "Which model should be used?", with: "Select model")
        let namedChange = changeModel.replacingOccurrences(of: "Would you like to switch to a different model?", with: "Switch to gpt-6.2?")
        for agent: AgentKind in [.codex, .claude] { for unknown in [false, true] { for (menuIndex, screen) in [screen, changeModel, keepModel, modelPicker, namedChange].enumerated() {
            let probe = ModelInputProbe(screen); probe.uncertain = unknown
            let directory = root.appendingPathComponent(agent.rawValue + "-\(unknown)-\(menuIndex)")
            let (engine, _) = try await currentModelFixture(directory, probe: probe, agent: agent)
            defer { engine.stop() }
            let deadline = Date().addingTimeInterval(3)
            while probe.messages.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try expectEqual(probe.messages, ["\u{1b}[B\r"], "Select the explicitly current second row, not the first/recommended model")
            try await Task.sleep(for: .milliseconds(100)); await engine.refreshScreens()
            try await Task.sleep(for: .milliseconds(150))
            try expectEqual(probe.messages.count, 1, "A delivered or uncertain selection is never repeated")
            try expect(engine.managedPTY.inventory.isEmpty)
            probe.screen = "Changed earlier output\n" + screen
            await engine.refreshScreens(); try await Task.sleep(for: .milliseconds(150))
            try expectEqual(probe.messages.count, 1, "Unrelated scrollback cannot revive an answered model menu")
            engine.stop()
            let (reopened, _) = try await currentModelFixture(directory, probe: probe, agent: agent)
            defer { reopened.stop() }
            try await Task.sleep(for: .milliseconds(150))
            try expectEqual(probe.messages.count, 1, "Restart cannot replay the same pending model menu")
        }}}
    }

    func testCurrentModelTerminalCancelsForPauseChangedQuestionAndManualInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-model-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = "Which model?\n❯ 1. Another model\n  2. Keep current model\nEnter to select or esc to cancel"
        for action in ["pause", "disable", "changed", "manual"] {
            let probe = ModelInputProbe(screen)
            let (engine, session) = try await currentModelFixture(root.appendingPathComponent(action), probe: probe)
            defer { engine.stop() }
            if action == "pause" { try engine.setPaused(true) }
            if action == "disable" { try engine.setAutomatic(session.id, enabled: false) }
            if action == "changed" { probe.screen = "Which environment?\n❯ 1. Staging\n  2. Production\nEnter to select or esc to cancel"; await engine.refreshScreens() }
            if action == "manual" { _ = try? await engine.remoteInput(["sessionID": session.id, "kind": "up", "revision": "unavailable"]) }
            try await Task.sleep(for: .milliseconds(180)); await engine.refreshScreens()
            try await Task.sleep(for: .milliseconds(150))
            try expect(probe.messages.isEmpty, "Do not replace a paused, opted-out, changed or manually edited question")
        }
    }
}
