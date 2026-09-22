import Foundation
import JavaScriptCore
import AutoApproveCore

@MainActor struct ApprovalTests {
    private let codex = """
    Would you like to run the following command?

      $ npm test

    › 1. Yes, proceed (y)
      2. Yes, and don't ask again for commands that start with `npm test` (p)
      3. No, and tell Codex what to do differently (esc)

    Press enter to confirm or esc to cancel
    """
    func testCompletePromptAndFalsePositives() throws {
        try expectEqual(PromptDetector.detect(codex, agent: .codex)?.answer, "1")
        try expectNotNil(PromptDetector.detect(codex + String(repeating: "\n", count: 50), agent: .codex), "Blank terminal rows must not hide a short dialog")
        try expectNil(PromptDetector.detect("Build logs: yes, proceed", agent: .codex))
        try expectNil(PromptDetector.detect("```text\n" + codex + "\n```", agent: .codex))
        try expectNil(PromptDetector.detect(codex + "\n› Explain this codebase", agent: .codex))
        try expectNil(PromptDetector.detect(codex.replacingOccurrences(of: "› 1.", with: "  1."), agent: .codex))
        try expectNil(PromptDetector.detect(codex, agent: .claude))
    }
    func testClaudePromptAndDifferentSelection() throws {
        let prompt = "Do you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again\n  3. No\nEsc to cancel"
        try expectNotNil(PromptDetector.detect(prompt, agent: .claude))
        try expectNil(PromptDetector.detect(prompt.replacingOccurrences(of: "❯ 1. Yes", with: "  1. Yes"), agent: .claude))
    }
    func testBothAgentsRecognizeRepeatedPermissionVariants() throws {
        for agent in [AgentKind.claude, .codex] {
            let heading = agent == .claude ? "Do you want to proceed?" : "Would you like to run the following command?"
            for repeated in ["Yes, don't ask again", "Yes, don't ask again (a)", "Yes, don’t ask again (a)",
                             "Yes, and don't ask again for commands that start with `npm test` (p)",
                             "Yes, don't ask\n     again for this session (a)",
                             "Yes, allow all edits during this session", "예, 이 세션에서는 항상 허용"] {
                let screen = heading + "\n› 1. Yes, proceed (y)\n  2. \(repeated)\n  3. No (esc)\nPress enter to confirm or esc to cancel"
                let prompt = PromptDetector.detect(screen, agent: agent)
                try expectEqual(prompt?.answer, "1", "\(agent): \(repeated)")
                try expectEqual(prompt?.dialog, screen, "Validation must retain original wrapping and scope")
                try expectNil(PromptDetector.detect(screen.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "› 2."), agent: agent))
                try expectNil(PromptDetector.detect(screen.replacingOccurrences(of: "  2.", with: "› 2."), agent: agent))
                try expectNil(PromptDetector.detect(screen + "\n› New input", agent: agent))
            }
            for alternate in ["Yes, use production", "Yes, also deploy", "Yes", "Pick another task"] {
                let screen = heading + "\n› 1. Yes\n  2. \(alternate)\n  3. No\nEsc to cancel"
                try expectNil(PromptDetector.detect(screen, agent: agent))
            }
            let four = heading + "\n› 1. Yes\n  2. Yes, don't ask again\n  3. Yes, always allow\n  4. No\nEsc to cancel"
            try expectEqual(PromptDetector.detect(four, agent: agent)?.answer, "1")
            try expectNil(PromptDetector.detect(four.replacingOccurrences(of: "  3.", with: "  5."), agent: agent))
            let shortcuts = heading + "\n› 1. Yes [y]\n  2. Yes, don't ask again [a]\n  3. No [esc]\nPress enter to confirm or esc to cancel"
            try expectEqual(PromptDetector.detect(shortcuts, agent: agent)?.answer, "1")
        }
    }
    func testDiscoveryKeepsIdentityAndFiltersSubprocesses() throws {
        let records = ProcessDiscovery.parse("""
        1 0 ?? 1 0 Mon Sep 21 09:00:00 2026 /sbin/launchd
        10 1 ?? 10 0 Mon Sep 21 09:00:01 2026 /Applications/Visual Studio Code.app/Contents/MacOS/Code
        11 10 ttys001 11 12 Mon Sep 21 09:00:02 2026 /bin/zsh
        12 11 ttys001 12 12 Mon Sep 21 09:00:03 2026 /usr/local/bin/codex
        13 12 ttys001 12 12 Mon Sep 21 09:00:04 2026 /usr/local/bin/codex-code-mode-host
        14 12 ttys001 12 12 Mon Sep 21 09:00:05 2026 /usr/local/bin/codex
        15 1 ?? 15 0 Mon Sep 21 09:00:06 2026 /usr/local/bin/claude
        """)
        let sessions = ProcessDiscovery.sessions(records)
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions.first?.terminal, .vscode)
        try expectEqual(sessions.first?.tty, "/dev/ttys001")
        try expect(sessions.first?.id.contains("09:00:03") == true)
        try expect(records.first(where: { $0.pid == 12 })?.isForeground == true)
        try expect(records.first(where: { $0.pid == 11 })?.isForeground == false)
    }
    func testPaddedBareProcessNamesAndNestedPTYs() throws {
        // ps aligns comm with several spaces. Production Claude changes comm to a bare name.
        let records = ProcessDiscovery.parse("""
            1     0 ??           1     0 Sat Sep 19 16:00:00 2026     /sbin/launchd
           10     1 ??          10     0 Sat Sep 19 16:00:01 2026     /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
           11    10 ttys001     11    12 Sat Sep 19 16:00:02 2026     -zsh
           12    11 ttys001     12    12 Sat Sep 19 16:00:03 2026     claude
           13    12 ??          13     0 Sat Sep 19 16:00:04 2026     claude bg-pty-host
           14    13 ttys009     14    14 Sat Sep 19 16:00:05 2026     /Users/test/.local/share/claude/versions/2.1.278
           20     1 ??          20     0 Sat Sep 19 16:00:06 2026     /Applications/Visual Studio Code.app/Contents/MacOS/Code
           21    20 ttys002     21    22 Sat Sep 19 16:00:07 2026     /bin/zsh
           22    21 ttys002     22    22 Sat Sep 19 16:00:08 2026     codex
           23    22 ttys002     22    22 Sat Sep 19 16:00:09 2026     /usr/local/bin/codex-code-mode-host
        """)
        let sessions = ProcessDiscovery.sessions(records)
        try expectEqual(Set(sessions.map(\.pid)), Set<Int32>([12, 14, 22]))
        try expectEqual(records.first(where: { $0.pid == 12 })?.executable, "claude")
        try expectEqual(sessions.first(where: { $0.pid == 12 })?.terminal, .terminal)
        try expectEqual(sessions.first(where: { $0.pid == 22 })?.terminal, .vscode)
        try expectEqual(sessions.first(where: { $0.pid == 14 })?.terminal, .unknown, "A background PTY is not the ancestor's Terminal tab")
    }
    func testTerminalScriptingContractAndPartialFailure() throws {
        let context = JSContext()!
        // JavaScriptCore is a sandboxed in-memory mock here; Application never sends an Apple event.
        context.evaluateScript("""
        function Application(identifier) {
          return {
            running: () => true,
            windows: () => [
              {tabs: () => { throw Error('closed window (-1728)'); }},
              {tabs: () => [
                {tty: () => { throw Error('closed tab (-1728)'); }},
                {tty: () => '/dev/ttys001', contents: () => 'approval dialog'},
                {tty: () => '/dev/ttys002', contents: () => { throw Error('must not read unrelated tab'); }}
              ]}
            ]
          };
        }
        """)
        let value = context.evaluateScript(try TerminalAdapter.screenScript(ttys: ["/dev/ttys001"]))
        try expectNil(context.exception)
        let result = try JSONDecoder().decode(TerminalSnapshot.self, from: Data(value!.toString().utf8))
        try expectEqual(result.screens.count, 1)
        try expectEqual(result.screens.first?.tty, "/dev/ttys001")
        try expectEqual(result.screens.first?.contents, "approval dialog")
        try expectEqual(result.failures.count, 2)
        // No mock tab exposes name(), matching Terminal.sdef. Calling it loses the healthy tab.
    }
    func testOrdinaryTerminalsAreExcluded() throws {
        let records = ProcessDiscovery.parse("""
        1 0 ?? 1 0 Mon Sep 21 09:00:00 2026 /sbin/launchd
        10 1 ?? 10 0 Mon Sep 21 09:00:01 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        11 10 ttys001 11 11 Mon Sep 21 09:00:02 2026 -zsh
        20 1 ?? 20 0 Mon Sep 21 09:00:03 2026 /Applications/Visual Studio Code.app/Contents/MacOS/Code
        21 20 ttys002 21 21 Mon Sep 21 09:00:04 2026 /bin/zsh
        31 10 ttys003 31 32 Mon Sep 21 09:00:05 2026 /bin/bash
        32 31 ttys003 32 32 Mon Sep 21 09:00:06 2026 /usr/bin/sleep
        41 10 ttys004 41 41 Mon Sep 21 09:00:07 2026 /bin/zsh
        42 41 ?? 42 0 Mon Sep 21 09:00:08 2026 /usr/local/bin/server
        51 10 ttys005 51 52 Mon Sep 21 09:00:09 2026 /bin/zsh
        52 51 ttys005 52 52 Mon Sep 21 09:00:10 2026 /bin/bash
        61 1 ?? 61 0 Mon Sep 21 09:00:11 2026 /bin/zsh
        71 1 ttys009 71 71 Mon Sep 21 09:00:12 2026 /bin/zsh
        """)
        let sessions = ProcessDiscovery.sessions(records)
        try expect(sessions.isEmpty, "Idle shells, foreground commands and background jobs are outside the inventory")
        let agents = ProcessDiscovery.parse("""
        12 11 ttys001 12 12 Mon Sep 21 09:01:01 2026 codex
        22 21 ttys002 22 22 Mon Sep 21 09:01:02 2026 claude
        """)
        let managed = ProcessDiscovery.sessions(records + agents)
        try expectEqual(Set(managed.map(\.pid)), Set<Int32>([12, 22]))
        try expectEqual(managed.first { $0.agent == .codex }?.terminal, .terminal)
        try expectEqual(managed.first { $0.agent == .claude }?.terminal, .vscode)
    }
    func testAgentExitDoesNotExposeShellOrCountItAsIdle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        let base = """
        10 1 ?? 10 0 Mon Sep 21 09:00:01 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        11 10 ttys001 11 11 Mon Sep 21 09:00:02 2026 -zsh
        """
        let records = ProcessDiscovery.parse(base)
        var shell = AgentSession(id: "process:11:shell", agent: .shell, pid: 11, started: "shell", tty: "/dev/ttys001", cwd: "/tmp", terminal: .terminal)
        shell.setPhase(.idle, detail: "legacy shell")
        engine.updateDiscovery([shell], records: records)
        try expect(engine.snapshot.sessions.isEmpty, "The engine must also reject ordinary terminals")
        try expectEqual(engine.snapshot.idleCount, 0)
        try expectThrows(try engine.setAutomatic(shell.id, enabled: true))
        engine.receiveScreen(sessionID: shell.id, raw: codex, generation: "forged")
        try expect(engine.snapshot.sessions.isEmpty)
        try expectNil(PromptDetector.detect(codex, agent: .shell))
        try expectThrows(try TerminalAdapter.approve(tty: shell.tty, expectedScreen: codex, agent: .shell))
        let running = ProcessDiscovery.parse(base + "\n12 11 ttys001 12 12 Mon Sep 21 09:00:03 2026 codex")
        engine.updateDiscovery(ProcessDiscovery.sessions(running), records: running)
        try expectEqual(engine.snapshot.sessions.filter { $0.phase != .ended }.map(\.agent), [.codex])
        engine.updateDiscovery(ProcessDiscovery.sessions(records), records: records)
        try expect(engine.snapshot.sessions.filter { $0.phase != .ended }.isEmpty)
        try expectEqual(engine.snapshot.idleCount, 0)
        try expectFalse(engine.snapshot.sessions.contains { $0.agent == .shell })
    }
    func testActivityNeedsAReadyComposerNotSilence() throws {
        let idle = "Done.\n›\n? for shortcuts\n"
        let claudeIdle = "Done.\n────────\n❯\n────────\n⏵⏵ accept edits on (shift+tab to cycle)"
        try expectEqual(ActivityDetector.detect(idle, agent: .codex).phase, .idle)
        try expectEqual(ActivityDetector.detect(claudeIdle, agent: .claude).phase, .idle)
        try expectEqual(ActivityDetector.detect("» Ask Codex to do anything\ngpt-6 · ~/project", agent: .codex).phase, .idle)
        for screen in ["", "Build running…", "›", "Done.\n›\nunknown footer", idle + "Downloading…", "```\n" + idle + "```"] {
            try expectEqual(ActivityDetector.detect(screen, agent: .codex).phase, .unknown)
        }
        for screen in ["• Working (0s • esc to interrupt)\n" + idle, idle + "tab to queue"] {
            try expectEqual(ActivityDetector.detect(screen, agent: screen.contains("❯") ? .claude : .codex).phase, .working)
        }
        try expectEqual(ActivityDetector.detect(codex, agent: .codex).phase, .approval)
        try expectEqual(ActivityDetector.detect("› Please fix this\n? for shortcuts", agent: .codex).phase, .input)
    }
    func testIdleConfirmationAndGenerationChange() throws {
        let idle = "Done.\n›\n? for shortcuts"
        let time = Date(timeIntervalSince1970: 1_000)
        var tracker = ActivityTracker()
        try expectEqual(tracker.observe(idle, agent: .codex, generation: "one", at: time).phase, .unknown)
        try expectEqual(tracker.observe(idle, agent: .codex, generation: "one", at: time.addingTimeInterval(1)).phase, .unknown)
        try expectEqual(tracker.observe(idle, agent: .codex, generation: "one", at: time.addingTimeInterval(2)).phase, .idle)
        try expectEqual(tracker.observe(idle, agent: .codex, generation: "two", at: time.addingTimeInterval(3)).phase, .unknown)
        try expectEqual(tracker.observe("• Working (esc to interrupt)\n" + idle, agent: .codex, generation: "two", at: time.addingTimeInterval(4)).phase, .working)
        try expectEqual(tracker.observe(idle, agent: .codex, generation: "two", at: time.addingTimeInterval(5)).phase, .unknown)
        try expectEqual(tracker.observe(idle, agent: .codex, generation: "two", at: time.addingTimeInterval(7)).phase, .idle)
    }
    func testEngineClearsIdleOnWorkAndDisconnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        var session = AgentSession(id: "process:42:start", agent: .codex, pid: 42, started: "start", tty: "/dev/ttys001", cwd: "/tmp", terminal: .terminal)
        session.channel = .terminalScreen
        engine.updateDiscovery([session], records: [])
        let idle = "›\n? for shortcuts", now = Date()
        engine.receiveScreen(sessionID: session.id, raw: idle, generation: "one", at: now)
        engine.receiveScreen(sessionID: session.id, raw: idle, generation: "one", at: now.addingTimeInterval(2))
        try expectEqual(engine.snapshot.idleCount, 1)
        let since = engine.snapshot.sessions[0].idleSince
        engine.receiveScreen(sessionID: session.id, raw: idle, generation: "one", at: now.addingTimeInterval(3))
        try expectEqual(engine.snapshot.sessions[0].idleSince, since)
        engine.receiveScreen(sessionID: session.id, raw: "• Working (esc to interrupt)\n" + idle, generation: "one")
        try expectEqual(engine.snapshot.sessions[0].phase, .working)
        try expectNil(engine.snapshot.sessions[0].idleSince)
        engine.receiveScreen(sessionID: session.id, raw: idle, generation: "one", at: now.addingTimeInterval(4))
        engine.receiveScreen(sessionID: session.id, raw: idle, generation: "one", at: now.addingTimeInterval(6))
        engine.disconnectTerminal()
        try expectEqual(engine.snapshot.idleCount, 0)
        try expectEqual(engine.snapshot.sessions[0].phase, .unknown)
        try expectNil(engine.snapshot.sessions[0].idleSince)
    }
    func testHookIdleResetsOnNewInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        let send: (String) -> Void = { event in
            _ = engine.handleHook(["session_id": "idle-test", "requestID": UUID().uuidString, "hook_event_name": event])
        }
        send("Stop")
        try expectEqual(engine.snapshot.idleCount, 1)
        let since = engine.snapshot.sessions[0].idleSince
        send("Stop")
        try expectEqual(engine.snapshot.sessions[0].idleSince, since)
        send("UserPromptSubmit")
        try expectEqual(engine.snapshot.sessions[0].phase, .working)
        try expectNil(engine.snapshot.sessions[0].idleSince)
        send("Stop"); send("SessionEnd")
        try expectEqual(engine.snapshot.idleCount, 0)
    }
    func testHookBeforeDiscoveryRestoresEnrollment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory)
        try paths.prepare()
        try AuditStore(path: paths.database).set("automatic:process:42:start", "true")
        let engine = try ApprovalEngine(paths: paths)
        _ = engine.handleHook(["session_id": "early", "agentPID": 42, "agentStarted": "start", "requestID": "early", "hook_event_name": "UserPromptSubmit"])
        try expect(engine.snapshot.sessions[0].automatic, "An early hook must restore the persisted setting")
        let session = AgentSession(id: "process:42:start", agent: .claude, pid: 42, started: "start", tty: "/dev/ttys001", cwd: "/tmp", terminal: .terminal)
        engine.updateDiscovery([session], records: [])
        try expect(engine.snapshot.sessions[0].automatic)
        try expectEqual(engine.snapshot.sessions[0].channel, .hook)
        try engine.setAutomatic(session.id, enabled: false)
        _ = engine.handleHook(["session_id": "early", "agentPID": 42, "agentStarted": "start", "requestID": "later", "hook_event_name": "Stop"])
        try expectFalse(engine.snapshot.sessions[0].automatic, "Subsequent hooks must respect a changed setting")
    }
    func testTerminalPermissionFailureIsNotHidden() throws {
        let context = JSContext()!
        context.evaluateScript("""
        function Application(identifier) {
          return {running: () => true, windows: () => [{tabs: () => [{
            tty: () => '/dev/ttys001',
            contents: () => { const error = Error('denied'); error.errorNumber = -1743; throw error; }
          }]}]};
        }
        """)
        context.evaluateScript(try TerminalAdapter.screenScript(ttys: ["/dev/ttys001"]))
        try expectNotNil(context.exception, "Permission failures must not be reported as a successful empty connection")
    }
    @MainActor func testHookRequiresEnrollmentHonorsPauseAndDoesNotReplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        let base: JSONObject = ["session_id": "first", "cwd": "/tmp/project", "hook_event_name": "SessionStart", "requestID": "start"]
        try expect(engine.handleHook(base).isEmpty)
        var request: JSONObject = ["session_id": "first", "hook_event_name": "PermissionRequest", "requestID": "one", "tool_name": "Bash", "tool_input": ["command": "npm test"]]
        try expect(engine.handleHook(request).isEmpty)
        try expect(engine.snapshot.sessions[0].pendingInTerminal, "A returned hook request requires terminal interaction")
        try engine.setAutomatic("claude:first", enabled: true)
        try expect(engine.snapshot.sessions[0].pendingInTerminal, "Enabling cannot retrieve an already-returned hook request")
        request["requestID"] = "two"
        try expectNotNil(engine.handleHook(request)["hookSpecificOutput"])
        try expectFalse(engine.snapshot.sessions[0].pendingInTerminal)
        try expect(engine.handleHook(request).isEmpty, "Duplicate request must not approve twice")
        request["requestID"] = "three"
        try expectNotNil(engine.handleHook(request)["hookSpecificOutput"], "A new request for the same command is independent")
        try engine.setPaused(true)
        request["requestID"] = "paused"
        try expect(engine.handleHook(request).isEmpty)
        try engine.setPaused(false)
        request["requestID"] = "question"; request["tool_name"] = "AskUserQuestion"
        try expect(engine.handleHook(request).isEmpty)
        request["requestID"] = "other"; request["tool_name"] = "Bash"; request["session_id"] = "second"
        try expect(engine.handleHook(request).isEmpty, "Enabling one session must not enable another")
        try expectEqual(engine.snapshot.events.filter { $0.outcome == "승인 전달" }.count, 2)
    }
    @MainActor func testDiscoveryDoesNotClaimControlAndEndsMissingSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        let session = AgentSession(id: "process:42:start", agent: .codex, pid: 42, started: "start", tty: "/dev/ttys001", cwd: "/tmp", terminal: .vscode)
        engine.updateDiscovery([session], records: [])
        try expectThrows(try engine.setAutomatic(session.id, enabled: true))
        try expectFalse(engine.snapshot.sessions[0].canApprove)
        engine.updateDiscovery([], records: [])
        try expectEqual(engine.snapshot.sessions[0].phase, .ended)
    }
    func testHookInstallPreservesOtherSettingsAndIsIdempotent() throws {
        let original: JSONObject = ["permissions": ["deny": ["Bash(secret *)"]], "hooks": ["PermissionRequest": [["matcher": "Bash", "hooks": [["type": "command", "command": "existing-helper"]]]]]]
        let once = HookInstaller.merged(original, executable: "/tmp/space name/autoapprove")
        let twice = HookInstaller.merged(once, executable: "/tmp/space name/autoapprove")
        try expectEqual(try JSONSerialization.data(withJSONObject: once, options: .sortedKeys), try JSONSerialization.data(withJSONObject: twice, options: .sortedKeys))
        let removed = HookInstaller.merged(twice, executable: nil)
        try expectEqual(try JSONSerialization.data(withJSONObject: original, options: .sortedKeys), try JSONSerialization.data(withJSONObject: removed, options: .sortedKeys))
        try expectEqual(HookInstaller.quote("a'b"), "'a'\\''b'")
    }
    func testAuditPersistsSettingsAndEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        do {
            let store = try AuditStore(path: path)
            try store.set("paused", "true")
            let event = AuditEvent(sessionID: "test", summary: "명령 'quoted'", outcome: "승인 전달", source: "test")
            try store.append(event); try store.append(event)
        }
        let reopened = try AuditStore(path: path)
        try expectEqual(reopened.value("paused"), "true")
        try expectEqual(reopened.recent().count, 1)
        try expectEqual(reopened.recent()[0].summary, "명령 'quoted'")
    }
    @MainActor func testDisconnectedEnrollmentCanBeDisabled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory)
        try paths.prepare()
        try AuditStore(path: paths.database).set("automatic:process:42:start", "true")
        let engine = try ApprovalEngine(paths: paths)
        var session = AgentSession(id: "process:42:start", agent: .codex, pid: 42, started: "start", tty: "/dev/ttys001", cwd: "/tmp", terminal: .vscode)
        session.automatic = true
        engine.updateDiscovery([session], records: [])
        try expect(engine.snapshot.sessions[0].automatic)
        try expectFalse(engine.snapshot.sessions[0].canReveal, "A detected VS Code process has no reveal route yet")
        try engine.setAutomatic(session.id, enabled: false)
        try expectFalse(engine.snapshot.sessions[0].automatic)
        session.bridgeID = "bridge"; session.terminalID = "terminal"
        try expect(session.canReveal)
        session.phase = .ended
        try expectFalse(session.canReveal)
    }
}


func expect(_ value: Bool, _ message: String = "Expected true", file: StaticString = #filePath, line: UInt = #line) throws {
    if !value { throw AppError.message("\(file):\(line): \(message)") }
}
func expectFalse(_ value: Bool, _ message: String = "Expected false") throws { try expect(!value, message) }
func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "Values differ") throws { try expect(lhs == rhs, "\(message): \(lhs) != \(rhs)") }
func expectNil<T>(_ value: T?) throws { try expect(value == nil, "Expected nil") }
func expectNotNil<T>(_ value: T?, _ message: String = "Expected a value") throws { try expect(value != nil, message) }
func expectThrows<T>(_ operation: @autoclosure () throws -> T) throws {
    do { _ = try operation() } catch { return }
    throw AppError.message("Expected an error")
}

@main struct CheckRunner {
    @MainActor static func main() async {
        let tests = ApprovalTests()
        let cases: [(String, () async throws -> Void)] = [
            ("Codex request identity separates commands from wrapping, history and shortcuts", tests.testCodexRequestIdentitySeparatesCommandsFromRendering),
            ("Wrapped final permission options and keyboard hints retain active-dialog validation", tests.testWrappedPermissionOptionsAndFooter),
            ("Claude and Codex ready composers with background monitoring", tests.testMonitoringRequiresReadyComposer),
            ("Changing monitor output, new generations and foreground work", tests.testMonitoringTracksReadinessAcrossOutputChanges),
            ("Monitoring counts, ordinary idle, connection loss and snapshot compatibility", tests.testMonitoringSessionLifecycleAndCompatibility),
            ("Claude background stop, reminders, new work and final completion", tests.testClaudeMonitoringHookLifecycle),
            ("Session order, identity, discovery and restart persistence", tests.testSessionOrderPersistsAcrossDiscoveryAndRestart),
            ("Filtered and multiple session moves preserve hidden slots", tests.testFilteredAndMultipleSessionMoves),
            ("Session moves reject stale, exited and invalid rows", tests.testSessionMoveRejectsStaleAndInvalidRows),
            ("Session order save failure and damaged preferences", tests.testSessionOrderSaveFailureAndDamagedPreference),
            ("Git unborn, nested, linked worktree, branch switch and detached HEAD", tests.testGitBranchWorktreeAndRefresh),
            ("Git non-repository, missing directory and inherited environment isolation", tests.testGitBranchNonRepositoryAndEnvironmentIsolation),
            ("Git metadata binds to live sessions and their current directories", tests.testGitBranchesBindToCurrentSessionDirectory),
            ("Codex locked database, preserved questions and automatic recovery", tests.testCodexHistoryContentionAndRecovery),
            ("Codex temporary, missing, invalid and unsupported history distinction", tests.testCodexHistoryFailureClassification),
            ("Codex question and completion errors recover independently", tests.testCodexQuestionAndCompletionErrorsStayIndependent),
            ("Claude final response, duplicate Stop, new work and pause", tests.testClaudeCompletionLifecycle),
            ("Claude background work, scheduled follow-ups and unanswered questions", tests.testClaudeIncompleteStopDoesNotNotify),
            ("Codex completion baseline, short turns and failed or interrupted outcomes", tests.testCodexCompletionBaselineAndOutcomes),
            ("completion lifecycle, question isolation and history recovery", tests.testCodexCompletionEngineAndRecovery),
            ("Codex latest root turn and read-only completion history", tests.testCodexCompletionReadOnlyHistory),
            ("question reply text, shell literals and exact receipt", tests.testReplyMessageAndReceipt),
            ("explicit question response, durable audit and duplicate prevention", tests.testQuestionReplyAuditAndDuplicateProtection),
            ("uncertain question response and restart reservation", tests.testQuestionReplyUncertainAndPreflightFailure),
            ("question response requires correct thread and saved audit", tests.testQuestionReplyRequiresCorrectThreadAndSavedAudit),
            ("automatic Yes waits five seconds per question and survives repeated reads without resending", tests.testAutomaticQuestionReplyWaitsFiveSecondsPerQuestion),
            ("automatic Allow preserves the one-time label after five seconds", tests.testAutomaticAllowQuestionReply),
            ("automatic question response cancellation, manual answer, new content and resume", tests.testAutomaticQuestionReplyCancellationAndResume),
            ("automatic question responses revalidate authorization and content after preflight", tests.testAutomaticQuestionReplyRevalidatesAfterPreparation),
            ("automatic question response failures, durable audit and restart protection", tests.testAutomaticQuestionReplyFailuresAreNotRetried),
            ("editing and individual cancellation stop automation across polling, resume and restart", tests.testQuestionDraftAndIndividualCancellationPersist),
            ("restored history, duplicate titles, unquoted answers and root changes remain manual", tests.testQuestionHistoryGuardsAutomaticResponses),
            ("fresh transport history blocks automatic answers while preserving manual responses", tests.testAutomaticReplyHonorsFreshTransportHistory),
            ("Codex async queue and exact, partial, ambiguous answer resolution", tests.testCodexQuestionResolution),
            ("Codex read-only history, incremental updates and restart", tests.testCodexHistoryReadOnlyAndIncremental),
            ("Codex root-thread binding excludes children and ambiguous processes", tests.testCodexThreadBinding),
            ("concurrent question alerts, errors, dismissal and session exit", tests.testConcurrentCodexAttentionAndDismissal),
            ("Terminal custom and window titles with isolated failures", tests.testTerminalTitleContract),
            ("varied yes/no questions, exact labels and ambiguous alternatives", tests.testYesNoConfirmationSelection),
            ("Allow, Deny and Don't allow labels preserve one-time scope", tests.testAllowConfirmationLabels),
            ("repeated permission variants preserve the current-request answer", tests.testRepeatedPermissionChoicesPreferCurrentRequest),
            ("repeated permissions never select different tasks or ambiguous answers", tests.testRepeatedPermissionChoicesRejectDifferentDecisions),
            ("Claude and Codex permission variants, wrapped labels and active selection", tests.testBothAgentsRecognizeRepeatedPermissionVariants),
            ("Claude question hook output, cross-event deduplication and saved answer", tests.testYesNoConfirmationHookAndAudit),
            ("question responses require enrollment, resume and the correct session", tests.testYesNoConfirmationOptInAndPause),
            ("question response requires a durable audit", tests.testYesNoConfirmationRequiresSavedAudit),
            ("manual attention, duplicate polling, resolution and repeated questions", tests.testAttentionLifecycle),
            ("notification opens exact live session only", tests.testAttentionTarget),
            ("three-choice question survives Claude reminders and notifies once", tests.testThreeChoiceAttention),
            ("durable audit history, filtering, pagination and result updates", tests.testAuditHistoryQueries),
            ("full hook request and project survive session exit and restart", tests.testAuditContextSurvivesSession),
            ("reveal exact Terminal tab, minimized restoration and closed-tab isolation", tests.testTerminalRevealTarget),
            ("window placement across desktop coordinate systems", tests.testTerminalHighlightCoordinates),
            ("long commands and canonical Unicode dialogs", tests.testLongPermissionAndCanonicalUnicode),
            ("interactive question menus versus approval and stale text", tests.testQuestionMenus),
            ("Terminal final validation and exact single input", tests.testTerminalApprovalValidation),
            ("Terminal opt-in persists and permission denial stops polling", tests.testTerminalConnectionLifecycle),
            ("Claude question content and permission screen fallback", tests.testHookQuestionAndScreenFallback),
            ("permission dialogs and false positives", tests.testCompletePromptAndFalsePositives),
            ("Claude dialog selection", tests.testClaudePromptAndDifferentSelection),
            ("process identity and child filtering", tests.testDiscoveryKeepsIdentityAndFiltersSubprocesses),
            ("padded bare process names and nested PTYs", tests.testPaddedBareProcessNamesAndNestedPTYs),
            ("only Claude/Codex terminals enter the inventory", tests.testOrdinaryTerminalsAreExcluded),
            ("agent exit excludes ordinary shells and idle counts", tests.testAgentExitDoesNotExposeShellOrCountItAsIdle),
            ("ready composer versus quiet work and unknown screens", tests.testActivityNeedsAReadyComposerNotSilence),
            ("stable idle confirmation and new screen generations", tests.testIdleConfirmationAndGenerationChange),
            ("idle duration, work transition, connection loss", tests.testEngineClearsIdleOnWorkAndDisconnection),
            ("Claude idle events and new input", tests.testHookIdleResetsOnNewInput),
            ("early hook preserves enrollment after restart", tests.testHookBeforeDiscoveryRestoresEnrollment),
            ("Terminal dictionary contract and closed-tab isolation", tests.testTerminalScriptingContractAndPartialFailure),
            ("Terminal permission error propagation", tests.testTerminalPermissionFailureIsNotHidden),
            ("enrollment, pause, duplicate requests, isolation", tests.testHookRequiresEnrollmentHonorsPauseAndDoesNotReplay),
            ("discovery capability and process exit", tests.testDiscoveryDoesNotClaimControlAndEndsMissingSessions),
            ("hook installation preserves settings", tests.testHookInstallPreservesOtherSettingsAndIsIdempotent),
            ("SQLite persistence", tests.testAuditPersistsSettingsAndEvents),
            ("disconnected controls and reveal capability", tests.testDisconnectedEnrollmentCanBeDisabled)
        ]
        var failures = 0
        for (name, run) in cases {
            do { try await run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        print("\(cases.count - failures)/\(cases.count) checks passed")
        if failures > 0 { exit(1) }
    }
}
