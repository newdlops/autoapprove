import Foundation
import JavaScriptCore
import AutoApproveCore

private let permissionFixture = "Would you like to run the following command?\n\n  $ echo 한글\n\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\n\nEnter to confirm or esc to cancel"
private let claudePermissionFixture = "Bash command\n  echo 한글\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel"
private let questionFixture = "어떤 환경을 사용할까요?\n❯ 1. 개발 환경\n  2. 테스트 환경\nEnter to select · Esc to cancel"
private let reportedCodexPermissionFixture = """
Would you like to run the following command?

Environment: local

$ rg -n 'lora|adapter|error|warn' .cache/product-evaluation/server-clean.log

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `rg -n 'lora|adapter|error|warn' .cache/product-evaluation/server-clean.log` (p)
  3. No, and tell Codex what to do differently (esc)

Press enter to confirm or esc to cancel
"""

extension ApprovalTests {
    func testCodexRequestIdentitySeparatesCommandsFromRendering() throws {
        let original = PromptDetector.detect(reportedCodexPermissionFixture, agent: .codex)!
        for rendering in ["Earlier output\n" + reportedCodexPermissionFixture,
                          reportedCodexPermissionFixture.replacingOccurrences(of: "product-evaluation", with: "product-\n    evaluation"),
                          reportedCodexPermissionFixture.replacingOccurrences(of: " (p)", with: " (a)"),
                          reportedCodexPermissionFixture.replacingOccurrences(of: "$ rg -n", with: "$  rg  -n")] {
            let prompt = PromptDetector.detect(rendering, agent: .codex)!
            try expectEqual(prompt.requestIdentity, original.requestIdentity, "Rendering and choice shortcuts do not create another permission")
            try expectEqual(prompt.dialog, rendering.hasPrefix("Earlier output") ? reportedCodexPermissionFixture : rendering,
                "Final delivery must still check original whitespace, choices and complete command")
        }
        for changed in [reportedCodexPermissionFixture.replacingOccurrences(of: "server-clean.log", with: "other.log"),
                        reportedCodexPermissionFixture.replacingOccurrences(of: "Environment: local", with: "Environment: remote")] {
            try expect(PromptDetector.detect(changed, agent: .codex)?.requestIdentity != original.requestIdentity)
        }
        let long = reportedCodexPermissionFixture.replacingOccurrences(of: "$ rg -n", with: "$ echo FIRST " + String(repeating: "long-command ", count: 450) + "; rg -n")
        let nextLong = long.replacingOccurrences(of: "echo FIRST", with: "echo SECOND")
        let first = PromptDetector.detect(long, agent: .codex)!
        let second = PromptDetector.detect(nextLong, agent: .codex)!
        try expectEqual(first.summary, second.summary, "The UI summary may be truncated")
        try expect(first.requestIdentity != second.requestIdentity, "Request identity must include command text outside the summary limit")
    }

    func testWrappedPermissionOptionsAndFooter() throws {
        for agent in [AgentKind.claude, .codex] {
            let heading = agent == .claude ? "Do you want to proceed?" : "Would you like to run the following command?"
            let options = "\n› 1. Yes, proceed\n     (y)\n  2. Yes, don't ask\n     again for this session (p)\n  3. No, and tell the agent\n     what to do differently (esc)\n\n"
            for footer in ["Press enter to confirm or esc to cancel", "Press enter to\nconfirm or esc to cancel", "Press enter\nto confirm or\nesc to cancel", "Enter to select\n· Esc to cancel", "Esc to\ncancel"] {
                let screen = heading + options + footer
                try expectEqual(PromptDetector.detect(screen, agent: agent)?.answer, "1", "\(agent): \(footer)")
                try expectEqual(PromptDetector.detect(screen, agent: agent)?.dialog, screen)
                try expectEqual(PromptDetector.detect(screen.replacingOccurrences(of: "\n", with: "\r\n"), agent: agent)?.dialog, screen)
                let selectedNo = screen.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  3.", with: "› 3.")
                try expectNil(PromptDetector.detect(selectedNo, agent: agent))
                try expectEqual(QuestionDetector.detect(selectedNo, agent: agent)?.phase, .approval)
                for suffix in ["\n› New input", "\nUnrelated output", "\nAnother instruction\nEsc to cancel"] {
                    try expectNil(PromptDetector.detect(screen + suffix, agent: agent))
                    try expectNil(QuestionDetector.detect(screen + suffix, agent: agent))
                }
            }
            try expectNil(PromptDetector.detect(heading + options, agent: agent))
            let differentTasks = heading + options.replacingOccurrences(of: "Yes, don't ask\n     again for this session (p)", with: "Yes, deploy to production (p)") + "Enter to\nselect"
            try expectNil(PromptDetector.detect(differentTasks, agent: agent))
            try expectNotNil(QuestionDetector.detect(differentTasks, agent: agent))
        }
        let question = "어떤 작업을 할까요?\n› 1. 미커밋 현황\n  2. PR 상태\n  3. 지정할\n     다른 작업\nEnter to select\n· Esc to cancel"
        try expectEqual(QuestionDetector.detect(question, agent: .claude)?.phase, .input)
        try expectNil(PromptDetector.detect(question, agent: .claude))
    }

    func testLongPermissionAndCanonicalUnicode() throws {
        try expectEqual(PromptDetector.detect(reportedCodexPermissionFixture, agent: .codex)?.answer, "1", "Reported Codex-only Terminal screenshot")
        let long = permissionFixture.replacingOccurrences(of: "  $ echo 한글", with: "  $ python <<'PY'\n" + String(repeating: "    print('한글')\n", count: 70) + "PY")
        try expectNotNil(PromptDetector.detect(long, agent: .codex))
        try expectEqual(PromptDetector.detect(permissionFixture, agent: .codex)?.dialog, PromptDetector.detect(permissionFixture.decomposedStringWithCanonicalMapping, agent: .codex)?.dialog)
        try expectNil(PromptDetector.detect(permissionFixture.replacingOccurrences(of: "Enter to confirm or esc to cancel", with: ""), agent: .codex))
        let a = PromptDetector.detect(claudePermissionFixture, agent: .claude)!
        let b = PromptDetector.detect(claudePermissionFixture.replacingOccurrences(of: "echo 한글", with: "echo other"), agent: .claude)!
        try expect(a.dialog != b.dialog, "Claude command content before the confirmation heading must be validated")
    }

    func testQuestionMenus() throws {
        for agent in [AgentKind.claude, .codex] {
            try expectEqual(QuestionDetector.detect(questionFixture, agent: agent)?.phase, .input)
            try expect(QuestionDetector.detect(questionFixture, agent: agent)?.summary.contains("테스트 환경") == true)
            try expectNil(PromptDetector.detect(questionFixture, agent: agent))
            try expectNil(QuestionDetector.detect(questionFixture + "\n› New instruction", agent: agent))
            try expectNil(QuestionDetector.detect("```\n" + questionFixture + "\n```", agent: agent))
        }
        let selectedNo = permissionFixture.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  2. No", with: "› 2. No")
        try expectNil(PromptDetector.detect(selectedNo, agent: .codex))
        try expectEqual(QuestionDetector.detect(selectedNo, agent: .codex)?.phase, .approval)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-question-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        var session = AgentSession(id: "fixture", agent: .codex, pid: 42, started: "fixture", tty: "/dev/fixture", cwd: "/tmp", terminal: .vscode)
        session.channel = .vscodeScreen
        engine.updateDiscovery([session], records: [])
        try engine.setAutomatic(session.id, enabled: true)
        engine.receiveScreen(sessionID: session.id, raw: questionFixture, generation: "question")
        try expectEqual(engine.snapshot.sessions[0].phase, .input)
        try expect(engine.snapshot.sessions[0].pendingInTerminal)
        try expect(engine.snapshot.events.isEmpty, "A general answer must not be synthesized by auto-approval")
    }

    func testTerminalApprovalValidation() throws {
        func check(_ current: String, expected: String = permissionFixture, agent: AgentKind = .codex, processes: [String] = ["codex"], tty: String = "/dev/fixture", delivery: String, writes: Int) throws {
            let context = JSContext()!
            context.setObject(current, forKeyedSubscript: "current" as NSString)
            context.setObject(processes, forKeyedSubscript: "processes" as NSString)
            context.setObject(tty, forKeyedSubscript: "tty" as NSString)
            context.evaluateScript("""
            var writes = [];
            var tab = {tty: () => tty, contents: () => current, processes: () => processes};
            function Application(id) { return {running: () => true, windows: () => [{tabs: () => [tab, tab]}], doScript: (value, options) => { if (options.in !== tab) throw Error('wrong target'); writes.push(value); }}; }
            """)
            let result = context.evaluateScript(try TerminalAdapter.approvalScript(tty: "/dev/fixture", expectedScreen: expected, agent: agent))
            try expectNil(context.exception)
            try expectEqual(result?.toString(), delivery)
            try expectEqual(context.evaluateScript("writes.length")?.toInt32(), Int32(writes))
            if writes > 0 { try expectEqual(context.evaluateScript("writes[0]")?.toString(), "1") }
        }
        try check("Changed history\n" + permissionFixture.decomposedStringWithCanonicalMapping + "\n\n", expected: "Old history\n" + permissionFixture, delivery: "sent", writes: 1)
        try check(reportedCodexPermissionFixture, expected: reportedCodexPermissionFixture, delivery: "sent", writes: 1)
        for changed in [permissionFixture.replacingOccurrences(of: "echo 한글", with: "echo changed"), permissionFixture.replacingOccurrences(of: "  $", with: " $"), permissionFixture.replacingOccurrences(of: "› 1.", with: "  1."), permissionFixture + "\n› Next input"] {
            try check(changed, delivery: "screenChanged", writes: 0)
        }
        try check(permissionFixture, processes: ["zsh"], delivery: "agentMissing", writes: 0)
        try check(permissionFixture, tty: "/dev/another", delivery: "missingTarget", writes: 0)
        try check(claudePermissionFixture.decomposedStringWithCanonicalMapping, expected: claudePermissionFixture, agent: .claude, processes: ["claude"], delivery: "sent", writes: 1)
        try check(claudePermissionFixture.replacingOccurrences(of: "echo 한글", with: "echo changed"), expected: claudePermissionFixture, agent: .claude, processes: ["claude"], delivery: "screenChanged", writes: 0)
    }

    func testTerminalConnectionLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-connect-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory)
        let probe = TerminalReadProbe()
        let reader: @Sendable ([String]) throws -> TerminalSnapshot = { _ in try probe.read() }
        let initial = try ApprovalEngine(paths: paths, terminalReader: reader)
        await initial.refreshTerminal()
        try expectEqual(probe.count, 0, "Never opt in without the user's connect action")
        await initial.connectTerminal()
        try expect(initial.snapshot.health.terminalRequested)
        try expect(initial.snapshot.health.terminalConnected)
        let restarted = try ApprovalEngine(paths: paths, terminalReader: reader)
        try expect(restarted.snapshot.health.terminalRequested)
        await restarted.refreshTerminal()
        try expectEqual(probe.count, 2, "Reconnect on launch without asking for the same opt-in")
        probe.error = TerminalAdapterError.permissionDenied
        await restarted.refreshTerminal()
        try expectFalse(restarted.snapshot.health.terminalConnected)
        try expect(restarted.snapshot.health.terminalRequested)
        await restarted.refreshTerminal()
        try expectEqual(probe.count, 3, "Do not repeatedly request denied Automation permission")
        probe.error = nil
        await restarted.connectTerminal()
        try expectEqual(probe.count, 4)
        restarted.disconnectTerminal()
        let disconnected = try ApprovalEngine(paths: paths, terminalReader: reader)
        await disconnected.refreshTerminal()
        try expectFalse(disconnected.snapshot.health.terminalRequested)
        try expectEqual(probe.count, 4, "An explicit disconnect must survive restart")
    }

    func testHookQuestionAndScreenFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-hook-question-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        var payload: JSONObject = ["session_id": "fixture", "requestID": "start", "hook_event_name": "SessionStart"]
        _ = engine.handleHook(payload)
        try engine.setAutomatic("claude:fixture", enabled: true)
        payload["hook_event_name"] = "PreToolUse"; payload["tool_name"] = "AskUserQuestion"; payload["requestID"] = "question"
        payload["tool_input"] = ["questions": [["question": "어떤 환경을 사용할까요?", "options": [["label": "개발", "description": "로컬 실행"], ["label": "테스트", "description": "검증"]]]]]
        try expect(engine.handleHook(payload).isEmpty)
        var current = engine.snapshot.sessions[0]
        try expectEqual(current.phase, .input)
        try expect(current.pendingSummary?.contains("2. 테스트 — 검증") == true)
        try expect(current.pendingInTerminal)
        payload["hook_event_name"] = "PermissionRequest"; payload["requestID"] = "question-permission"
        try expect(engine.handleHook(payload).isEmpty)
        try expectEqual(engine.snapshot.sessions[0].phase, .input)
        engine.receiveScreen(sessionID: current.id, raw: claudePermissionFixture, generation: "screen", source: .terminalScreen)
        try expectEqual(engine.snapshot.sessions[0].channel, .hook, "Question ownership must not become permission approval")
        _ = engine.handleHook(["session_id": "fixture", "requestID": "answered", "hook_event_name": "PostToolUse", "tool_name": "AskUserQuestion"])
        payload["hook_event_name"] = "Notification"; payload["notification_type"] = "permission_prompt"; payload["requestID"] = "network"; payload["message"] = "네트워크 권한 확인"; payload.removeValue(forKey: "tool_input"); payload.removeValue(forKey: "tool_name")
        _ = engine.handleHook(payload)
        engine.receiveScreen(sessionID: current.id, raw: claudePermissionFixture, generation: "screen", source: .terminalScreen)
        current = engine.snapshot.sessions[0]
        try expectEqual(current.channel, .terminalScreen, "A returned permission request can use a verified connected screen")
        try expectEqual(current.phase, .approval)
        payload["hook_event_name"] = "PermissionRequest"; payload["tool_name"] = "Bash"; payload["requestID"] = "allowed"
        try expectNotNil(engine.handleHook(payload)["hookSpecificOutput"])
        engine.receiveScreen(sessionID: current.id, raw: claudePermissionFixture, generation: "screen", source: .terminalScreen)
        try expectEqual(engine.snapshot.sessions[0].channel, .hook)
        try expectEqual(engine.snapshot.sessions[0].phase, .working, "Already-allowed hooks cannot approve a stale screen again")
    }
}

private final class TerminalReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var failure: Error?
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var error: Error? {
        get { lock.lock(); defer { lock.unlock() }; return failure }
        set { lock.lock(); defer { lock.unlock() }; failure = newValue }
    }
    func read() throws -> TerminalSnapshot {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        if let failure { throw failure }
        return TerminalSnapshot()
    }
}
