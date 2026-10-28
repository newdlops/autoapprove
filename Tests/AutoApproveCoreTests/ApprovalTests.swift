import Foundation
import JavaScriptCore
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif

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
#if DEBUG
    func testOrdinaryScrollbackDoesNotMaterializeTrimmedRows() throws {
        let history = String(repeating: "completed build step /fixture/output.swift\n", count: 45_000)
        let ordinary = history + "Working\nesc to interrupt"
        let prepared = DetectionLines(ordinary)
        try expectNil(PromptDetector.detect(ordinary, agent: .codex, prepared: prepared))
        try expectFalse(prepared.debugHasMaterializedRawRows,
            "Ordinary screen analysis must leave its 45,000-row transcript unmaterialized")
        try expectFalse(prepared.debugHasMaterializedTrimmedRows,
            "Ordinary screen analysis must avoid a second full array of 45,000 trimmed rows")
        try expectNil(QuestionDetector.detect(agent: .codex, prepared: prepared))
        try expectFalse(prepared.debugHasMaterializedRawRows,
            "A missing menu should only read the bounded screen tail")
        try expectFalse(prepared.debugHasMaterializedTrimmedRows,
            "Menu inspection should trim only its bounded visible tail")

        let permissionLines = DetectionLines(codex)
        try expectNotNil(PromptDetector.detect(codex, agent: .codex, prepared: permissionLines))
        try expect(permissionLines.debugHasMaterializedTrimmedRows,
            "A real dialog retains its full normalized and trimmed context for exact validation")
    }

    func testScreenAnalysisPreservesSourceUTF8ByteCountAcrossLinePreparation() throws {
        let samples = [
            "ASCII\r\ntrailing spaces  \n",
            "e\u{301}\r\n🙂\u{2028}text\r",
            "한글\n\t \n",
            String(repeating: "old output 🙂 e\u{301}\r\n", count: 256)
        ]
        for sample in samples {
            let bridged = String(NSString(string: sample))
            let prepared = PromptDetector.normalizedLinesAndUTF8ByteCount(bridged)
            try expectEqual(prepared.lines, PromptDetector.normalizedLines(bridged),
                "Counted normalization preserves the existing CR/LF and canonical row output")
            try expectEqual(prepared.byteCount, bridged.utf8.count,
                "Source bytes count original decomposed scalars, CRLF and trailing whitespace")
            let analysis = ScreenAnalysis(raw: bridged, agent: .shell)
            try expectEqual(analysis.sourceByteCount, bridged.utf8.count,
                "Screen cache budgeting uses the exact original UTF-8 size")
        }

        let contiguous = DetectionLines(samples[0])
        try expectEqual(contiguous.sourceByteCount, samples[0].utf8.count)
        try expectFalse(contiguous.debugHasMaterializedRawRows,
            "Reading the byte budget alone must not materialize normalized line arrays")
    }
#endif
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
                             "Yes, allow all edits during this session", "예, 이 세션에서는 항상 허용",
                             "Yes, and don’t ask again for: npm run *", "Yes, allow reading from src/ from this project",
                             "Yes, and switch to accept edits (auto-approve file edits and\n     common file commands) for this session (shift+tab)",
                             "Yes, and switch to auto mode · auto mode handles these prompts for you"] {
                let screen = heading + "\n› 1. Yes, proceed (y)\n  2. \(repeated)\n  3. No (esc)\nPress enter to confirm or esc to cancel"
                let prompt = PromptDetector.detect(screen, agent: agent)
                try expectEqual(prompt?.answer, "1", "\(agent): \(repeated)")
                try expectEqual(prompt?.dialog, screen, "Validation must retain original wrapping and scope")
                try expectNil(PromptDetector.detect(screen.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "› 2."), agent: agent))
                try expectNil(PromptDetector.detect(screen.replacingOccurrences(of: "  2.", with: "› 2."), agent: agent))
                try expectNil(PromptDetector.detect(screen + "\n› New input", agent: agent))
            }
            for alternate in ["Yes, use production", "Yes, also deploy", "Yes", "Pick another task", "Yes, and switch to the production branch for this session"] {
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
        try expectEqual(sessions.first(where: { $0.pid == 14 })?.terminal, .claudeBackground, "A background PTY is not the ancestor's Terminal tab")
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
              {id:()=>7, name:()=>'Original', bounds:()=>({x:1,y:2,width:800,height:600}), tabs: () => [
                {tty: () => { throw Error('closed tab (-1728)'); }},
                {tty: () => '/dev/ttys001', selected:()=>true, contents: () => 'approval dialog'},
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
        let metadata = try JSONSerialization.jsonObject(with: Data(value!.toString().utf8)) as! JSONObject
        try expectEqual(((metadata["screens"] as! [JSONObject])[0]["cursorWindow"] as? JSONObject)?["windowID"] as? Int, 7)
        let rawValue = context.evaluateScript("{\n" + (try TerminalAdapter.screenScript(ttys: ["/dev/ttys001"], includeCursor: false)) + "\n}")!
        try expectNil(context.exception)
        let rawMetadata = try JSONSerialization.jsonObject(with: Data(rawValue.toString().utf8)) as! JSONObject
        try expect((rawMetadata["screens"] as! [JSONObject])[0]["cursorWindow"] is NSNull, "Background approval reads must skip native window/cursor metadata")
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
        try expectThrows(try TerminalAdapter.approvalScript(tty: shell.tty, expectedScreen: codex, agent: .shell))
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
        let history = String(repeating: "Old output\n", count: 2000)
        for newline in ["\n", "\r\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"] {
            let screen = history + idle.replacingOccurrences(of: "\n", with: newline)
            try expectEqual(ActivityDetector.detect(screen, agent: .codex).phase, .idle)
            var tracker = ActivityTracker()
            let now = Date(timeIntervalSince1970: 10_000)
            try expectEqual(tracker.observe(screen, agent: .codex, generation: "same", at: now).phase, .unknown)
            try expectEqual(tracker.observe(screen, agent: .codex, generation: "same", at: now.addingTimeInterval(2)).phase, .idle,
                "Prepared-tail activity detection and readiness fingerprinting preserve every supported newline form")
        }
        try expectEqual(ActivityDetector.detect("esc to interrupt\n" + history + idle, agent: .codex).phase, .idle, "Old working hints outside the visible tail cannot change the phase")
    }
    func testPromptLineNormalizationPreservesNewlinesAndCanonicalText() throws {
        for (screen, expected) in [
            ("", []),
            ("a\r\nb\rc\n", ["a", "b", "c"]),
            ("\r\r\n", []),
            ("row\n   \n\t", ["row"]),
            ("e\u{301}\u{2028}x\r\n", ["é\u{2028}x"]),
        ] {
            try expectEqual(PromptDetector.normalizedLines(screen), expected)
        }
    }
    func testActivityHintsPreserveUnicodeWordsAndRealDrafts() throws {
        let composer = "\n›\n? for shortcuts"
        for prefix in ["X", "흺\u{301}", "é", "e\u{301}", "١"] {
            let result = ActivityDetector.detect(prefix + "1 background tasks" + composer, agent: .codex)
            try expectEqual(result.phase, .idle)
            try expectFalse(result.monitoring, "Digits attached to a Unicode word are not a background task count")
        }
        for prefix in ["", "• ", "✓ ", "🙂 "] {
            let result = ActivityDetector.detect(prefix + "1 background task" + composer, agent: .codex)
            try expectEqual(result.phase, .idle)
            try expect(result.monitoring)
        }
        for hint in ["ESC TO INTERRUPT", "ctrl+c to STOP", "TAB TO QUEUE"] {
            try expectEqual(ActivityDetector.detect(hint + composer, agent: .codex).phase, .working, "Working hint \(hint.debugDescription)")
        }
        try expectEqual(ActivityDetector.detect("❯ Try “한글 e\u{301} 👨‍👩‍👧‍👦”\n? for shortcuts", agent: .claude).phase, .idle)
        try expectEqual(ActivityDetector.detect("❯ Try “task”\0\n? for shortcuts", agent: .claude).phase, .input)
        try expectEqual(ActivityDetector.detect("› 1. Choice\n? for shortcuts", agent: .codex).phase, .unknown)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-upgrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        var old = once, oldHooks = once["hooks"] as! [String: [JSONObject]]
        for event in HookInstaller.events {
            oldHooks[event] = oldHooks[event]!.map { original in
                var group = original
                group["hooks"] = (group["hooks"] as! [JSONObject]).map { original in
                    var handler = original
                    if (handler["command"] as? String)?.hasSuffix(" hook --autoapprove-managed") == true { handler["timeout"] = 4 }
                    return handler
                }
                return group
            }
        }
        old["hooks"] = oldHooks
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        try expectNil(try HookInstaller.upgradeTimeouts(executable: "/tmp/other-app/autoapprove", url: url))
        try expectNotNil(try HookInstaller.upgradeTimeouts(executable: "/tmp/space name/autoapprove", url: url))
        let upgraded = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        try expectEqual(try JSONSerialization.data(withJSONObject: upgraded, options: .sortedKeys), try JSONSerialization.data(withJSONObject: once, options: .sortedKeys))
        try expectNil(try HookInstaller.upgradeTimeouts(executable: "/tmp/space name/autoapprove", url: url))
        old["disableAllHooks"] = true
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        try expectNil(try HookInstaller.upgradeTimeouts(executable: "/tmp/space name/autoapprove", url: url))
        try JSONSerialization.data(withJSONObject: original).write(to: url)
        try expectNil(try HookInstaller.upgradeTimeouts(executable: "/tmp/space name/autoapprove", url: url))
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
        if WorkingDirectoryFixture.runIfRequested() { return }
        let tests = ApprovalTests()
        var cases: [(String, () async throws -> Void)] = [
            ("AI account login: encrypted PIN, node scope, replay, stale requests and revocation",tests.testAccountCryptoPINReplayAndScope),
            ("AI account login: bounded PIN attempts",tests.testAccountPINAttemptsAreBounded),
            ("AI account login: official challenge URL allowlist",tests.testAccountChallengeOnlyAcceptsOfficialProviderURLs),
            ("AI account login: private PTY ownership, exact code, cancel and hidden inventory",tests.testAccountPrivateLoginOwnershipCancelAndInventory),
            ("Native typing: answered permission survives composer repaint",tests.testAnsweredPermissionSurvivesManualComposerRepaints),
            ("Native typing: host isolation and physical idle",tests.testNativeTypingActivitySeparatesHostsAndPhysicalIdle),
            ("Native typing: local input yields without disabling automation",tests.testNativeTypingYieldsApprovalWithoutDisablingAutomation),
            ("Native typing: input during process validation cancels dispatch",tests.testNativeTypingCancelsApprovalDuringProcessValidation),
            ("Native typing: new work and stable idle release the old receipt",tests.testAnsweredPermissionRetiresOnlyAfterRealResolution),
            ("Network recovery: bounded jitter across long outages",tests.testRecoveryBackoffRemainsBoundedAcrossLongOutages),
            ("Network recovery: same-address return and independent interfaces",tests.testRecoveryTracksSameAddressReturnAndIndependentInterfaces),
            ("Network recovery: wake, cancellation and stopped generations",tests.testRecoveryWakeCancellationAndStopDoNotLeakWaiters),
            ("Network recovery: early wake and server backoff",tests.testRecoveryRetainsEarlyWakeAndRespectsServerBackoff),
            ("Network recovery: relay survives repeated outages without key changes",tests.testRecoveryRelayContinuesPastSixFailuresAndKeepsGateway),
            ("Network recovery: owned cloudflared restarts and explicit stop",tests.testRecoveryCloudflaredRestartsKeepGatewayAndStopPermanently),
            ("Network recovery: credential rejection is permanent and sanitized",tests.testRecoveryCloudflaredCredentialErrorsStopWithoutRetrying),
            ("Input socket: RFC handshake, fragmented masks and bounds",tests.testInputSocketRFCHandshakeFragmentationAndBounds),
            ("Input socket: real gateway auth, ordered PTY and revocation",tests.testInputSocketRealGatewayAuthOrderingAndRevocation),
            ("Tunnel quality: bounded RTT, metrics and privacy",tests.testTunnelQualityBoundsMetricsAndPrivacy),
            ("Workers: owned source refresh preserves DNS and foreign settings",tests.testWorkersSourceRefreshPreservesDNSAndRejectsForeignBindings),
            ("Workers: refresh cancellation cannot restart a stopped tunnel",tests.testWorkersRefreshCancellationCannotRestartStoppedTunnel),
            ("Workers: slow management cannot hold an existing relay connection",tests.testWorkersSlowManagementCannotHoldExistingRelayConnection),
            ("Tunnel PIN: salted verification, format and leading zeros",tests.testPINUsesSaltedVerificationAndKeepsLeadingZeros),
            ("Tunnel PIN: protected persistence, clear and cancellation",tests.testPINKeychainPersistenceClearAndCancellation),
            ("Tunnel PIN: concurrent limit, rotation and cookie revocation",tests.testPINRateLimitConcurrentAttemptsRotationAndSessionRevocation),
            ("Workers: OAuth, SQLite migration and uncertain upload recovery",tests.testWorkersApprovalProvisionAndUncertainUpload),
            ("Workers: protect foreign DNS, script and invalid names",tests.testWorkersForeignResourcesAndInvalidNamesArePreserved),
            ("Workers: cancellation and sanitized permission errors",tests.testWorkersCancelledAuthorizationAndSanitizedPermissionError),
            ("Workers: binary bounds and fixed loopback isolation",tests.testRelayBinaryFramingBoundsAndLoopbackIsolation),
            ("Workers: owned process group cleanup preserves unrelated child",tests.testOwnedWorkerToolCancellationPreservesUnrelatedProcess),
            ("Cloudflare: approved domain pagination and account isolation",tests.testCloudflareApprovalFiltersAndPaginatesRegisteredDomains),
            ("Cloudflare: subdomain validation and legacy address recovery",tests.testCloudflareSubdomainValidationAndLegacyAddressRecovery),
            ("Cloudflare: invalid subdomain never creates remote resources",tests.testCloudflareInvalidSubdomainCannotCreateRemoteResources),
            ("Cloudflare: user address changes preserve prior DNS and tunnel",tests.testCloudflareAddressChangeKeepsPriorDNSAndTunnelIdentity),
            ("Cloudflare: selected zone permission fallback",tests.testCloudflareApprovalSelectedZoneFallbackAndPermissions),
            ("Cloudflare: malformed approval and oversized response rejection",tests.testCloudflareApprovalRejectsMalformedAndOversizedAccountData),
            ("Cloudflare: preserve DNS and reuse owned tunnel",tests.testCloudflareProvisionPreservesDNSAndReusesOwnedResources),
            ("Cloudflare: reconcile lost creation replies across restart",tests.testCloudflareProvisionReconcilesLostCreateReplies),
            ("Cloudflare: cancellation rejects late approval",tests.testCloudflareCancellationRejectsLateApprovalAndUnknownDomain),
            ("Cloudflare: isolated login and owned child cleanup",tests.testCloudflareLiveLoginUsesPrivateHomeAndCleansOwnedChild),
            ("Tunnel: HTTPS authority and private-address isolation", tests.testTunnelOriginsRejectAuthorityConfusionAndPrivateAddresses),
            ("Tunnel: default off and credential-free persisted configuration", tests.testTunnelConfigurationDefaultsOffAndRoundTripsWithoutCredentials),
            ("Tunnel setup: domain completion retains origin restrictions", tests.testTunnelSetupNormalizesDomainsWithoutWeakeningOriginRules),
            ("Tunnel setup: pasted commands yield only a token", tests.testTunnelSetupExtractsOnlyTokenFromPastedInstallCommands),
            ("Tunnel setup: cancellation leaves services off", tests.testCancelledTunnelSetupKeepsWebAndTunnelOff),
            ("Tunnel setup: automatic web preparation before connector launch", tests.testTunnelSetupAutomaticallyOpensWebBeforeLaunchingConnector),
            ("History cache: compact projection matches raw decisions and old-row edits", tests.testCodexHistoryCompactCacheMatchesRawDecisionsAndOldEdits),
            ("Local socket: fragmented Unicode, large lines, buffered order and permissions", tests.testLocalSocketFragmentedUnicodeAndBufferedOrdering),
            ("Local socket: malformed and oversized peers, bounded connections and single disconnect", tests.testLocalSocketMalformedOversizedAndBoundedPeers),
            ("Local socket: restart descriptor lifetime and path ownership", tests.testLocalSocketRestartAndPathOwnership),
            ("History processing: metadata chunks, exact bytes and read bound", tests.testRolloutHeaderStopsAtFirstLineAndKeepsByteLimit),
            ("History processing: fresh long metadata and incomplete header rejection", tests.testRolloutBindingReadsFreshLongMetadataAndRejectsIncompleteHeaders),
            ("History processing: warm metadata still revalidates current roots and failures", tests.testCodexCollectorRevalidatesWarmRolloutMetadata),
            ("History processing: unchanged queries, delta, reset, thread switch and failure", tests.testUnchangedHistoryStillChecksUpdatesResetsAndFailures),
            ("History processing: risk variants, Unicode and fresh installer source", tests.testSystemRiskLazyVariantsRetainWhitespaceUnicodeAndFreshSource),
            ("Screen parsing: Cocoa preparation preserves prompt identity and quoted questions", tests.testCocoaLinePreparationPreservesPromptIdentityAndQuotedQuestions),
            ("Screen parsing: bounded Cocoa suffix retains current and quoted menus", tests.testCocoaBoundedSuffixPreservesCurrentAndQuotedMenus),
            ("Screen parsing: fused Cocoa suffix preserves long trailing blanks and old fence context", tests.testCocoaFusedTrailingBlanksKeepCurrentRequestsAndFenceContext),
            ("Screen parsing: large Cocoa menus preserve normalized fence semantics", tests.testLargeCocoaMenuKeepsNormalizedFenceSemantics),
            ("Session processing: path equivalence and executable identity", tests.testProcessClassificationPreservesPathAndExecutableIdentity),
            ("Session processing: shell names preserve Foundation path semantics", tests.testShellClassificationPreservesFoundationPathSemantics),
            ("Session processing: nested, orphan, cyclic and ended ownership", tests.testSessionProjectionKeepsNestedOrphanCyclicAndEndedPolicies),
            ("System safety: mutations, escaped paths and readonly boundaries", tests.testSystemRiskMutationsAndReadOnlyBoundaries),
            ("System safety: candidate search preserves Unicode case folding and barriers", tests.testSystemRiskCandidateSearchPreservesCaseFoldingAndUnicodeBarriers),
            ("System safety: byte compaction preserves control paths and late candidates", tests.testSystemRiskByteCompactionKeepsControlPathsAndLateCandidates),
            ("System safety: local installers are bounded and never executed", tests.testSystemRiskLocalInstallerIsBoundedAndNeverExecuted),
            ("System safety: original composer ownership and submission", tests.testSystemSafetyComposerOwnershipAndSubmission),
            ("System safety: Claude denies without interruption and durably replays", tests.testSystemSafetyClaudeDeniesAndContinuesWithDurableReplay),
            ("System safety: Claude pause, safe manual action and readonly approval", tests.testSystemSafetyClaudePauseManualAndReadOnlyApproval),
            ("System safety: screen redirection, newline and no approval bytes", tests.testSystemSafetyScreenRedirectHandlesNewlineWithoutApproval),
            ("System safety: screen pause and original user drafts", tests.testSystemSafetyScreenPauseAndUserDraftArePreserved),
            ("System safety: uncertain writes never replay after restart", tests.testSystemSafetyScreenUncertainWriteNeverReplaysAfterRestart),
            ("System safety: original PID start and foreground recheck", tests.testSystemSafetyScreenRechecksProcessAndForegroundBeforeGuidance),
            ("System safety: concurrent Claude acknowledgements are request-bound", tests.testSystemSafetyConcurrentClaudeReceiptsMatchTheirOwnRequest),
            ("Codex MCP tool permission: two-choice Allow/Cancel, colors and wrapping", tests.testCodexMCPToolPermissionWithTwoChoices),
            ("Codex MCP tool permission: escaped payloads, JSON and exact Terminal/iTerm delivery", tests.testCodexMCPToolPermissionEscapesAndExactDelivery),
            ("Codex MCP tool permission: concurrent isolation and single use", tests.testCodexMCPToolPermissionConcurrentAndSingleUse),
            ("Codex one-time Allow: tool scope variants and exact host delivery", tests.testCodexToolPermissionOneTimeAllowVariants),
            ("Codex one-time Allow: Unicode heading whitespace and lookalike rejection", tests.testCodexToolPermissionHeadingWhitespace),
            ("Codex one-time Allow: OFF, pause and single-use automation", tests.testCodexOneTimeAllowAutomationPreservesPolicyAndSingleUse),
            ("Codex terminal input permission: literal escapes survive screen JSON, cells and delivery", tests.testCodexTerminalInputEscapesSurviveScreenAndDelivery),
            ("Codex terminal input permission: complete title, wrapping and literal payload", tests.testCodexTerminalInputPermissionAndWrapping),
            ("Codex terminal input permission: inactive, incomplete and changed requests", tests.testCodexTerminalInputPermissionBoundsAndIdentity),
            ("Codex terminal input permission: concurrent isolation and single use", tests.testCodexTerminalInputApprovalIsolatedAndSingleUse),
            ("Codex selected conversation: explicit message, stale target rejection and original preservation", tests.testExplicitCodexConversationMessagePreservesOriginalAndRejectsStaleTarget),
            ("Published updates: exact stable release, architecture, digest and origin",tests.testPublishedUpdateOnlyAcceptsExactStablePublisherAsset),
            ("Published updates: exact loopback gateway and web ports after reuse",tests.testExplicitLoopbackPortsSurviveListenerReuse),
            ("Published updates: Port Manager namespace, ephemeral and reserved addresses",tests.testPortManagerLoopbackCoordinatesStayInsideDeclaredNamespace),
            ("Published updates: coalesced checks, cache, cancellation and sanitized errors",tests.testPublishedUpdateChecksCoalesceCacheAndCancel),
            ("Published updates: exact ranges and interrupted download resume",tests.testPublishedUpdateRangesResumeAndRejectWrongBoundaries),
            ("Published updates: metadata, origin, exact host and disabled preference",tests.testPublishedVersionControlChecksMetadataWithoutInstalling),
            ("LAN updates: reject wrong peer, downgrade, architecture and oversize", tests.testLANUpdateRejectsWrongPeerDowngradeArchitectureAndOversize),
            ("LAN updates: reject unsafe ZIP paths, links, duplicates and bombs", tests.testLANUpdateArchiveRejectsTraversalLinksDuplicatesAndBombs),
            ("LAN updates: preference persists across engine restart", tests.testLANUpdatePreferenceSurvivesEngineRestart),
            ("Codex queue: snapshot deletion preserves new inputs, consumed inputs and original session", tests.testCodexQueueSnapshotDeletionPreservesNewAndConsumedInputs),
            ("Codex queue: partial deletion, audit and exited-process rejection", tests.testCodexQueuePartialFailureKeepsUndeletedInputsAndAudit),
            ("Web interaction: explicit single/multiple/free-text answers and bounds", tests.testWebQuestionAnswersAreExplicitAndBounded),
            ("Web interaction: MCP ownership, expiry and no default answer", tests.testWebQuestionOwnershipExpiryAndNoDefaultAnswer),
            ("Web interaction: explicit screen capture, cache, permission and stop", tests.testTestScreenCaptureIsExplicitAndStops),
            ("Screen control: compact records, negative origins, retina coordinates and invalid input",tests.testScreenControlBinaryCoordinatesAndValidation),
            ("Screen control: one fresh dispatch snapshot without cross-input target caching",tests.testScreenControlUsesOneFreshTargetWithoutCachingAcrossInputs),
            ("Screen transfer: conditional reply follows fresh capture and image changes",tests.testScreenTransferUsesCurrentCaptureBeforeNotModified),
            ("Screen transfer: cancelled viewer keeps coalesced readers and control",tests.testScreenTransferCancelledViewerKeepsOtherReadersAndControl),
            ("Screen transfer: validators cannot bypass permission or share lifetime",tests.testScreenTransferValidatorCannotBypassPermissionOrShareLifetime),
            ("Screen transfer: actual peer relay preserves validator and node identity",tests.testScreenTransferPeerPreservesValidatorAndFreshNodeIdentity),
            ("Screen control: explicit fresh capability, permission, secret and sequence",tests.testScreenControlRequiresFreshExplicitCapabilityAndPermission),
            ("Screen control: native pointer, drag, double-click, wheel and release",tests.testScreenControlNativePointerDragWheelAndRelease),
            ("Screen control: exact Unicode chunks, shortcuts and manual input priority",tests.testScreenControlUnicodeChunksAndAtomicShortcut),
            ("Screen control: heartbeat, expiry, owner change and share stop",tests.testScreenControlRevokesOnExpiryOwnerChangeAndStop),
            ("Screen control: window focus, partial failure and bounded native input",tests.testScreenControlFocusFailureAndFloodNeverReplay),
            ("Screen control: remote typing yields same-host automatic approval",tests.testScreenControlTypingYieldsAutomationOnlyInItsTerminalHost),
            ("Web interaction: MCP stdio initialization, tool list and errors", tests.testMCPStdioProtocolAndToolErrors),
            ("Web interaction: Claude multiple questions and editing hold", tests.testClaudeWebAnswersMultipleQuestionsAndEditingHold),
            ("Approval recovery: wrapped headings retain identity and active selection", tests.testWrappedPermissionHeadingsKeepRequestIdentity),
            ("Approval recovery: next permission resumes after input completion without another frame", tests.testNextPermissionResumesWhenPreviousInputCompletes),
            ("Approval recovery: consecutive Claude panels tolerate history and reflow", tests.testClaudeConsecutivePanelsAndHistoryReflow),
            ("Approval recovery: confirmed non-write retries without another output event", tests.testConfirmedNonWriteRecoversWithoutAnotherOutputEvent),
            ("Approval recovery: exact Terminal tab works without frontmost app or focus", tests.testApprovalTargetsTabWithoutFrontmostAppOrKeyboardFocus),
            ("Approval recovery: uncertain input is not retried after reflow or resume", tests.testUncertainApprovalDoesNotRetryAfterReflow),
            ("Approval recovery: real terminal cells across widths and clipped heights", tests.testPermissionDetectionAcrossTerminalGridSizes),
            ("LAN HTTP bounds, origin checks and private addresses", tests.testRemoteHTTPBoundsOriginAndPrivateAddresses),
            ("HTTP request: validated target components and value isolation", tests.testHTTPRequestComponentsPreserveTargetAndValueIsolation),
            ("HTTP request: form escapes, duplicate keys and empty values", tests.testHTTPRequestQueryKeepsFormEscapesDuplicatesAndEmptyValues),
            ("HTTP request: framing, malformed targets and origin boundaries", tests.testHTTPRequestTargetRetainsFramingAndOriginBoundaries),
            ("Verified peer addresses keep the shared Wi-Fi route", tests.testRemotePreferredPeerAddressKeepsSharedWiFiRoute),
            ("Discovery: passive neighbor cache filtering and nearby address order", tests.testDiscoveryNeighborHintsAndNearbyOrder),
            ("Stabilization: peer cache expiration, removal and shared pending reads", tests.testPeerCachePrunesExpiredRemovedAndPreservesPending),
            ("Stabilization: replacement cancels old peer reads and rejects late completion", tests.testPeerReplacementCancelsOldReadAndRejectsLateCompletion),
            ("Stabilization: interrupted updates resume only a matching manifest", tests.testLANUpdateDownloadResumesOnlyMatchingManifest),
            ("Stabilization: corrupt cached update is rejected", tests.testLANUpdateDownloadRejectsCorruptCompletedResume),
            ("Stabilization: accessibility and mouse event permission diagnostics", tests.testMouseReportsDistinctAXAndEventPermissions),
            ("Remote terminal coalesces reads, expires cache and omits unchanged output", tests.testRemoteTerminalCoalescingExpiryAndConditionalPayload),
            ("Remote read pruning: shared pending consumers, fresh cache and original stream", tests.testRemoteReadPruningPreservesPendingConsumersAndFreshCache),
            ("Remote read pruning: Orca cached observation and exact original incarnation", tests.testOrcaReadPruningPreservesOriginalIncarnationAndCachedObservation),
            ("Live relay accepts changing output with automation on and binds the exact target", tests.testRemoteRelayWithAutomaticApprovalAndChangedOutput),
            ("Native approval writes serialize with live user input", tests.testRemoteInputSerializesNativeApproval),
            ("Remote original ANSI attributes, bounds and color-only frames", tests.testRemoteOriginalTerminalAttributesAndColorOnlyFrames),
            ("Terminal observer first frame, live text/cursor/color and close/reopen", tests.testTerminalNotificationsKeepFirstFrameLiveChangesAndReopen),
            ("Remote frames preserve exact bridged Unicode and cache native UTF-8", tests.testForeignScreenFramesKeepExactUnicodeAndCacheNativeUTF8),
            ("Remote frame character budget preserves foreign storage and Unicode output", tests.testRemoteFrameCharacterBudgetPreservesForeignAndUnicodeOutput),
            ("Native viewport text and Codex Unicode cursor are captured together", tests.testNativeTextSnapshotKeepsCodexCursorOnSameViewport),
            ("Codex and Claude cursor/display changes preserve the original input and lifetime", tests.testNativePresentationAndCursorPreserveOriginalInput),
            ("Remote terminal read stops once the exact target is found", tests.testRemoteTerminalReadStopsAtExactTarget),
            ("First terminal frame reuses only verified recent monitoring and live output remains fresh", tests.testInitialTerminalReusesOnlyVerifiedRecentMonitor),
            ("First terminal frame rejects changed original processes and ended sessions", tests.testInitialTerminalRejectsChangedOriginalProcess),
            ("First terminal frame honors PID, lifetime, TTY, agent and read-only background ownership", tests.testInitialTerminalHonorsEveryInjectedIdentityField),
            ("Cold first terminal text bypasses presentation without delaying live cursors or reviving disconnected originals", tests.testColdInitialTerminalReadsFreshTextBeforePresentation),
            ("Connection performance: bounded timings contain no terminal content or source identity", tests.testConnectionTimingSamplesAreBoundedAndContentFree),
            ("Native diagnostics: bounded slow reads without source data", tests.testNativeQueryDiagnosticsRetainOnlyBoundedSlowOrFailedReads),
            ("Native diagnostics: errors and overlapping reads release in-flight slots", tests.testNativeQueryDiagnosticsPreserveErrorsAndReleaseOverlappingReads),
            ("Native diagnostics: validation preserves exact targets and fails closed", tests.testValidationReadPrefersExactChannelAndDoesNotFallbackAfterFailure),
            ("Native diagnostics: reader tags actual native sends without source text", tests.testNativeTerminalDiagnosticsTagExactSendWithoutRetainingSourceText),
            ("Native diagnostics: custom reader owns validation and fresh denials", tests.testCustomTerminalReaderRemainsTheOnlyValidationChannel),
            ("Connection performance: Automation preflight stays off main, shares only in-flight queries and rejects revocation", tests.testAutomationPreflightRunsOffMainAndDoesNotCacheGrants),
            ("Connection performance: completed permission queries cannot authorize later requests on a busy actor", tests.testCompletedPermissionQueryCannotAuthorizeALaterRequest),
            ("Connection performance: concurrent first reads share exact sources, cancel independently and preserve live cursors", tests.testInitialConnectionSharesOnlyConcurrentExactOriginals),
            ("Connection performance: input invalidates old first reads without disconnecting or repeating delivery", tests.testInitialConnectionDuringInputRejectsOldReadAndRecovers),
            ("Text terminals check only required live permissions and native previews retain full checks", tests.testTextTerminalChecksOnlyRequiredPermissions),
            ("Targeted original process verification matches discovery and rejects ended PIDs", tests.testTargetedOriginalProcessReadMatchesDiscovery),
            ("Native processes: fresh metadata and original terminal host parity", tests.testNativeProcessMetadataAndOriginalHostParity),
            ("Native processes: agent name prefilter preserves Foundation classification", tests.testProcessAgentNamePrefilterKeepsFoundationClassification),
            ("Native processes: concurrent target and missing-PID reads keep independent values", tests.testConcurrentNativeTargetReadsKeepIndependentValues),
            ("Native processes: start formatting follows process-local timezone changes", tests.testNativeProcessStartFormattingFollowsCurrentTimeZone),
            ("Native processes: filtered ancestor lookup revalidates the complete chain", tests.testFilteredAgentAncestryRevalidatesTheCompleteParentChain),
            ("Native processes: current open files prepare questions without input", tests.testNativeQuestionPreparationUsesCurrentProcessAndOpenFiles),
            ("Native processes: cancellation and missing identity", tests.testNativeProcessCancellationAndMissingIdentity),
            ("Native identity: targeted routing, fresh connection stages and exact fields", tests.testNativeIdentityReadsOnlyTheRequestedPIDAtEveryConnectionStage),
            ("Native identity: read failures and custom-reader authority", tests.testNativeIdentityFailureDoesNotFallbackAndCustomReaderStaysAuthoritative),
            ("Native identity: fresh and cached previews reject changed originals", tests.testNativeIdentityPreviewAndCachedPreviewRejectChangedProcesses),
            ("Command completion handles early exits, concurrent output, Unicode stdin and timeouts", tests.testCommandRunnerExitTimeoutAndConcurrentPipes),
            ("Command pipes: bytes, status, environment and early stdin exit", tests.testCommandPipesPreserveBytesStatusAndEnvironment),
            ("Command pipes: independent UTF-8 repair across chunk boundaries", tests.testCommandPipesRepairUTF8AcrossBoundaries),
            ("Command pipes: limits never return partial success or replay", tests.testCommandPipesLimitsNeverReturnPartialSuccess),
            ("Command pipes: deadline includes inherited stdin and stdout", tests.testCommandPipesDeadlineIncludesInheritedDescriptors),
            ("Command pipes: timeout retires only the owned helper", tests.testCommandPipesTimeoutRetiresOnlyOwnedHelper),
            ("Command pipes: repeated EOF and overflow release descriptors", tests.testCommandPipesRepeatedCallsReleaseDescriptors),
            ("Remote exact terminal, manual input, stale frames and restart receipts", tests.testRemoteTerminalExactTargetStaleFrameAndDurableReceipt),
            ("Remote Terminal scripts validate screen, agent and supported keys", tests.testRemoteTerminalScriptValidationAndKeys),
            ("Unchanged observations stay quiet while changes publish immediately", tests.testUnchangedObservationsDoNotPublishSnapshots),
            ("Detection optimization preserves exact persisted fingerprints and raw Unicode bytes", tests.testFingerprintEncodingKeepsExistingReceipts),
            ("Fingerprint preparation preserves repaired Cocoa and raw chunk boundaries", tests.testFingerprintKeepsRepairedCocoaAndChunkBoundaries),
            ("Request identity preserves Character whitespace, original reservations and exact dialog bytes", tests.testRequestIdentityKeepsCharacterWhitespaceAndExactDialog),
            ("Complete suffix reuse: exact permission history and300-row boundaries", tests.testCompleteSuffixReuseKeepsExactPermissionBoundaries),
            ("Cocoa normalization: Unicode boundaries preserve current dialogs and quoted permissions", tests.testCocoaNormalizationRetainsUnicodeBoundariesAndCurrentDialogs),
            ("Detection optimization preserves Unicode option spacing and ordinary-output rejection", tests.testOptionPrecheckKeepsUnicodeMenusAndRejectsOrdinaryOutput),
            ("Repeated screens retain time, generation, changed requests and ended-process checks", tests.testRepeatedScreensPreserveTimeGenerationAndChangedRequests),
            ("Screen polling publishes coherent batches and preserves immediate stream updates", tests.testScreenPollsPublishTogetherAndKeepImmediateUpdates),
            ("Background screen load keeps UI responsive and publishes coherent requests", tests.testLargeScreenPollKeepsUIResponsiveAndPublishesTogether),
            ("Background screen analysis preserves questions, errors, drafts and system safety", tests.testBackgroundScreenAnalysisPreservesQuestionsErrorsAndSafety),
            ("Repeated web frames bound parsing and keep changed questions", tests.testRepeatedWebFramesBoundParsingAndKeepChangedQuestions),
            ("Background screen results reject replaced targets, disconnects and cancellation", tests.testBackgroundScreenResultsRejectChangedTargetsDisconnectAndCancellation),
            ("Native cwd reads preserve valid paths with duplicate and missing processes", tests.testWorkingDirectoryReadsKeepValidPathsWithDuplicateAndMissingPIDs),
            ("Working directory refreshes cache between process polls", tests.testWorkingDirectoryRefreshReadsNewSessionsImmediatelyAndCachesBriefly),
            ("Keep-awake idle polling sleeps while disabled", tests.testKeepAwakeEvaluationIntervalBacksOffWhenInactive),
            ("Native cwd reads follow a Unicode child's directory changes", tests.testWorkingDirectoryFollowsUnicodeChildDirectoryChanges),
            ("Duplicate indexing preserves Unicode, thread identity and manual overrides", tests.testQuestionDuplicateIndexPreservesCanonicalAndThreadIdentity),
            ("Claude task choices stay manual while confirmations and system safety continue", tests.testClaudeTaskChoicesStayManualWhileConfirmationsContinue),
            ("Claude app approval continues through thirty separately timed requests", tests.testClaudeAppApprovalThenThirtySequentialQuestions),
            ("Automatic Claude questions stay quiet while manual fallback still alerts", tests.testClaudeAutomaticAttentionAndManualFallback),
            ("Claude hook restart, lost response replay and exact identity", tests.testClaudeHookRestartAndExactResponseReplay),
            ("Claude saved responses retain full envelope and acknowledgement validation", tests.testClaudeSavedResponseValidatesWholePayloadAndAcknowledgement),
            ("Claude undecided hooks recheck changed local installer source", tests.testPendingClaudeHookRechecksChangedInstallerSource),
            ("Claude prepared hooks preserve effective session directory safety", tests.testClaudeHookPreparationRespectsEffectiveSessionDirectory),
            ("Claude hook pause, manual response and concurrent isolation", tests.testClaudeHookPauseManualAndConcurrentIsolation),
            ("Claude hook terminal handoff, expiry and PID reuse", tests.testClaudeHookHandoffExpiryAndPIDReuse),
            ("Claude decision and audit rollback together before retry", tests.testClaudeHookDurableSaveFailureAndRetry),
            ("Claude general permission and unsupported question fallback", tests.testClaudeHookGeneralPermissionAndUnsupportedQuestion),
            ("Live Claude hook excludes screen input and rechecks parent exit", tests.testClaudeLiveHookOwnsScreenAndRechecksParent),
            ("Claude registry verifies process identity and exact background parent", tests.testClaudeRegistryIdentityAndExactParent),
            ("Claude restores existing background questions without replaying old hooks", tests.testClaudeRestoresWaitingBackgroundWithoutAHook),
            ("Claude recovered waiting transitions and unavailable metadata", tests.testClaudeRecoveredWaitingTransitionsAndUnavailableMetadata),
            ("Claude recovered question metadata identity and staleness", tests.testClaudeRecoveryMetadataIdentityAndStaleness),
            ("Claude registry batches preserve timezone, DST boundaries and malformed sibling isolation", tests.testClaudeRegistryBatchTimezonesAndMalformedSiblings),
            ("Claude registry paths preserve fresh metadata and isolate nonfiles", tests.testClaudeRegistryPathsKeepFreshMetadataAndRejectNonfiles),
            ("Background hooks inherit main policy and retain original audit context", tests.testBackgroundHookInheritsMainAndAuditsOrigin),
            ("Screen parent lookup does not walk unrelated sessions", tests.testBackgroundParentLookupAvoidsUnrelatedSessionWalk),
            ("Grouped concurrent questions, notifications, completions and read persistence", tests.testGroupedQuestionsNoticesAndReadPersistence),
            ("Background first hook, restart, orphan and PID reuse", tests.testBackgroundFirstHookRestartAndParentExit),
            ("Main screen cannot duplicate a background hook response", tests.testParentScreenCannotDuplicateChildHook),
            ("Parent relationship and grouped read failures stop without partial success", tests.testParentGroupingAndReadSaveFailures),
            ("Claude disconnection persists disabled approval and stops on save failure", tests.testClaudeDisconnectionPersistsOffAndRejectsFailedSave),
            ("Unread notice debounce, reading and repeated occurrences", tests.testInboxDebounceReadAndNewOccurrences),
            ("Read receipts survive incomplete initial discovery and history stays bounded", tests.testInboxRestoresReadReceiptsBeforeObservation),
            ("Exact Korean JSON, independent badges, early-hook preferences and opt-in answer", tests.testKoreanSampleAndPerSessionReadPersistence),
            ("Failed read receipt keeps the unread badge", tests.testInboxReadFailurePreservesBadge),
            ("Error receipt survives a stale exit cache and rejects a newer episode", tests.testInterruptionReadSurvivesStaleExitCacheAndRejectsNewErrors),
            ("Legacy error receipts acknowledge only their exact episode", tests.testLegacyInterruptionReceiptRestoresOnlyTheExactEpisode),
            ("Failed error receipt save keeps the error visible", tests.testInterruptionReadFailureDoesNotHideTheError),
            ("Claude daemon virtual TTY is distinct from Terminal and VS Code", tests.testClaudeDaemonPTYHasDistinctHost),
            ("Codex request identity separates commands from wrapping, history and shortcuts", tests.testCodexRequestIdentitySeparatesCommandsFromRendering),
            ("Wrapped final permission options and keyboard hints retain active-dialog validation", tests.testWrappedPermissionOptionsAndFooter),
            ("Wrapped label text that starts with a redirect, arrow or number stays in its option", tests.testWrappedLabelTextMayLookLikeACursorOrAnOption),
            ("Claude Code 2.1.28x prefix, mode and directory choices with the Tab to amend hint", tests.testClaudeCode2128PermissionMenus),
            ("Claude and Codex ready composers with background monitoring", tests.testMonitoringRequiresReadyComposer),
            ("Changing monitor output, new generations and foreground work", tests.testMonitoringTracksReadinessAcrossOutputChanges),
            ("Monitoring counts, ordinary idle, connection loss and snapshot compatibility", tests.testMonitoringSessionLifecycleAndCompatibility),
            ("Claude background stop, reminders, new work and final completion", tests.testClaudeMonitoringHookLifecycle),
            ("Session order, identity, discovery and restart persistence", tests.testSessionOrderPersistsAcrossDiscoveryAndRestart),
            ("Filtered and multiple session moves preserve hidden slots", tests.testFilteredAndMultipleSessionMoves),
            ("Session moves reject stale, exited and invalid rows", tests.testSessionMoveRejectsStaleAndInvalidRows),
            ("Session order save failure and damaged preferences", tests.testSessionOrderSaveFailureAndDamagedPreference),
            ("Session names, notes and colors persist without crossing session identities", tests.testCustomizationPersistsAndStaysInItsSession),
            ("Session customization reset and original/name/note search", tests.testCustomizationResetAndSearch),
            ("Session customization validation and old snapshot compatibility", tests.testCustomizationValidationAndCompatibility),
            ("Session customization save failure and ended-session rejection", tests.testCustomizationFailureDoesNotPublishOrReviveSessions),
            ("Git unborn, nested, linked worktree, branch switch and detached HEAD", tests.testGitBranchWorktreeAndRefresh),
            ("Git unchanged branch avoids processes and follows reference changes", tests.testGitBranchCacheAvoidsProcessLaunchAndTracksReferences),
            ("Git detached HEAD cache avoids processes and follows HEAD changes", tests.testGitDetachedHeadCacheAvoidsRepeatedProcessLaunchAndTracksHEADChanges),
            ("Git detached cache rejects HEAD races", tests.testGitDetachedCacheRejectsHEADRace),
            ("Git metadata: nonblocking special files, read bounds and packed-reference identity", tests.testGitBranchMetadataBoundsAndPackedReferenceIdentity),
            ("Git metadata: typed paths keep special-file and symlink revalidation", tests.testGitMetadataPathHintsPreserveSpecialFileAndSymlinkRevalidation),
            ("Git metadata: failed reads release descriptors and restore the verified cache", tests.testGitMetadataFailedReadsReleaseFileDescriptors),
            ("Git metadata: complete reads preserve size boundaries and final bytes", tests.testGitMetadataReadsPreserveSizeBoundariesAndTailBytes),
            ("Git non-repository, missing directory and inherited environment isolation", tests.testGitBranchNonRepositoryAndEnvironmentIsolation),
            ("Git metadata binds to live sessions and their current directories", tests.testGitBranchesBindToCurrentSessionDirectory),
            ("Codex locked database, preserved questions and automatic recovery", tests.testCodexHistoryContentionAndRecovery),
            ("Codex temporary, missing, invalid and unsupported history distinction", tests.testCodexHistoryFailureClassification),
            ("Git collection keeps bindings and progress with at most four readers", tests.testGitCollectionKeepsBindingsAndProgressWithBoundedWorkers),
            ("Git collection cancellation stays local and stops queued reads", tests.testGitCollectionCancellationIsLocalAndStopsQueuedReads),
            ("Git collection ignores empty and ineligible targets without starting reads", tests.testGitCollectionEmptyTargetsDoNotStartReaders),
            ("Git collection shared config gets fresh completion validation", tests.testGitCollectionSharedConfigIsValidatedAfterInspection),
            ("Git collection preserves private worktree metadata freshness", tests.testGitCollectionKeepsWorktreeMetadataFresh),
            ("Git collection special shared config leaves stay uncached", tests.testGitCollectionSpecialSharedConfigLeavesRemainUncached),
            ("Git collection missing config and pool bounds remain correct", tests.testGitCollectionMissingSharedConfigAndBoundedPool),
            ("Git collection cancellation drops changed snapshots without retry", tests.testGitCollectionCancellationDropsChangedSnapshotsWithoutRetry),
            ("Git collection post-Git store recheck stays independent", tests.testGitCollectionPostGitStoreRecheckIsIndependentOfSnapshot),
            ("Automation reset: cancel old preflight and isolate other sessions", tests.testAutomationResetCancelsOldPreflightAndKeepsOtherSessions),
            ("Automation reset: in-flight approval stays single use", tests.testAutomationResetKeepsInFlightApprovalSingleUse),
            ("Automation reset: old monitor results cannot restore discarded work", tests.testAutomationResetDiscardsOldMonitorReadAndUsesFreshScreen),
            ("Automation reset: clear timers and preserve uncertain continuation receipts", tests.testAutomationResetClearsCapacityTimerAndPreservesUncertainWrites),
            ("Automation reset: cancel question preflight and require fresh history", tests.testAutomationResetCancelsQuestionPreflightAndRechecksHistory),
            ("Automation reset: preserve off, pause, drafts and exact original binding", tests.testAutomationResetPreservesOffPauseAndManualQuestionHold),
            ("Automation reset: dispatched question keeps its durable single-use receipt", tests.testAutomationResetKeepsDispatchedQuestionReceipt),
            ("Automation reset: cancelled safety preflight sends no approval or keys", tests.testAutomationResetCancelsSafetyPreflightWithoutApprovalOrKeys),
            ("Automation reset: wake original Claude hook and rebuild only its request", tests.testAutomationResetWakesOriginalClaudeHookAndRebuildsFreshRequest),
            ("All automation reset: cancel simultaneous preflights and rebuild all sessions", tests.testAllAutomationResetCancelsConcurrentPreflightsAndRebuildsBothSessions),
            ("All automation reset: default epoch and fresh reads after repeated reset", tests.testAllAutomationResetRotatesDefaultEpochAndAcceptsFreshReadsAfterRepeatedReset),
            ("All automation reset: question preflight cancellation and dispatched receipts", tests.testAllAutomationResetQuestionCancellationAndDispatchedReceipts),
            ("All automation reset: empty, ended and mixed per-session policies", tests.testAllAutomationResetHandlesEmptyEndedAndMixedPolicies),
            ("All automation reset: HTTP replay, origin and exact-node checks", tests.testAllAutomationResetHTTPReceiptOriginAndNodeChecks),
            ("All automation reset: in-flight approval stays single use", tests.testAllAutomationResetKeepsInFlightApprovalSingleUse),
            ("All automation reset: wake every original Claude hook and rebuild fresh requests", tests.testAllAutomationResetWakesEveryClaudeHookAndRebuildsFreshRequests),
            ("Codex question and completion errors recover independently", tests.testCodexQuestionAndCompletionErrorsStayIndependent),
            ("Claude final response, duplicate Stop, new work and pause", tests.testClaudeCompletionLifecycle),
            ("Claude background work, scheduled follow-ups and unanswered questions", tests.testClaudeIncompleteStopDoesNotNotify),
            ("Codex completion baseline, short turns and failed or interrupted outcomes", tests.testCodexCompletionBaselineAndOutcomes),
            ("completion lifecycle, question isolation and history recovery", tests.testCodexCompletionEngineAndRecovery),
            ("Codex latest root turn and read-only completion history", tests.testCodexCompletionReadOnlyHistory),
            ("question reply text, shell literals and exact receipt", tests.testReplyMessageAndReceipt),
            ("Codex questions without server: selected reply reaches the same original terminal", tests.testCodexQuestionReplyWithoutServerUsesOriginal),
            ("Codex questions without server: proven rejection versus uncertain write", tests.testCodexOriginalQuestionReplyFailureAndUnknownReceipt),
            ("Codex questions without server: legacy missing socket is a proven non-write", tests.testLegacyMissingServerReplyIsProvenNonWrite),
            ("Codex questions without server: unavailable queue remains separate from questions", tests.testUnavailableCodexQueueDoesNotBlockQuestionsOrReadServer),
            ("Terminal choices: current menus, wrapping, permission exclusion and bounds", tests.testTerminalChoiceDetectionAndBounds),
            ("Terminal choices: native preflight preserves Unicode spaces and long blank tails", tests.testTerminalChoicePreflightKeepsUnicodeSpacingAndTrailingBlankRows),
            ("Terminal choices: exact frame, manual pause, single use and restart", tests.testTerminalChoiceExactFrameSingleUseAndRestart),
            ("Terminal choices: uncertain writes cannot repeat", tests.testTerminalChoiceUncertainWriteCannotRepeat),
            ("Terminal choices: Codex question tabs submit digits without an extra Enter", tests.testCodexInteractiveChoiceAdvancesWithoutExtraEnter),
            ("explicit question response, durable audit and duplicate prevention", tests.testQuestionReplyAuditAndDuplicateProtection),
            ("uncertain question response and restart reservation", tests.testQuestionReplyUncertainAndPreflightFailure),
            ("question response requires correct thread and saved audit", tests.testQuestionReplyRequiresCorrectThreadAndSavedAudit),
            ("automatic Yes waits five seconds per question and survives repeated reads without resending", tests.testAutomaticQuestionReplyWaitsFiveSecondsPerQuestion),
            ("Response latency: event command completion, UTF-8 pipes and bounded timeout", tests.testResponseEventCommandCompletionAndTimeout),
            ("Response latency: unchanged question reads stay quiet and changes publish immediately", tests.testResponseQuietHistoryAndImmediateChanges),
            ("Response latency: temporary reads recover before a single answer write", tests.testResponseTemporaryPreparationRecoversBeforeSingleWrite),
            ("Response latency: temporary preparation retries remain bounded", tests.testResponseTemporaryPreparationIsBounded),
            ("Response latency: changed question and app stop cancel pre-write recovery", tests.testResponseChangedQuestionAndStopPreventWrites),
            ("Response latency: slow hosts and discovery failures do not block healthy hosts", tests.testResponseIndependentHostsAndQuietPause),
            ("Response latency: default transient recovery is fast and never repeats an unchanged failure", tests.testResponseDefaultTransientRecoveryIsFastAndSingleUse),
            ("Response latency: delayed frames never cross a manager restart", tests.testResponseLateFrameCannotCrossManagerRestart),
            ("Response latency: hook client waits for pushed decisions with older-app fallback", tests.testResponseHookClientWaitAndOlderAppFallback),
            ("Response latency: concurrent hook waits receive exact durable responses immediately", tests.testResponseConcurrentHookWaitsDeliverExactSavedReceipts),
            ("Response latency: default confirmations are fast and editing still cancels them", tests.testResponseFastDefaultConfirmationAndCancellationWindow),
            ("Response latency: live hook wait honors the brief confirmation deadline and pause", tests.testResponseHookWaitConfirmationDeadlineAndPause),
            ("automatic English/Korean Allow preserves the one-time label after five seconds", tests.testAutomaticAllowQuestionReply),
            ("Current model: Codex queued question preserves the existing-model label exactly once", tests.testAutomaticModelQuestionRetainsOriginalLabel),
            ("Current model: original terminal selection works for both agents without replay", tests.testCurrentModelTerminalSelectionAndNoReplay),
            ("Current model: pause, opt-out, changed questions and manual input cancel selection", tests.testCurrentModelTerminalCancelsForPauseChangedQuestionAndManualInput),
            ("automatic question response cancellation, manual answer, new content and resume", tests.testAutomaticQuestionReplyCancellationAndResume),
            ("automatic question responses revalidate authorization and content after preflight", tests.testAutomaticQuestionReplyRevalidatesAfterPreparation),
            ("automatic question response failures, durable audit and restart protection", tests.testAutomaticQuestionReplyFailuresAreNotRetried),
            ("editing and individual cancellation stop automation across polling, resume and restart", tests.testQuestionDraftAndIndividualCancellationPersist),
            ("restored history, duplicate titles, unquoted answers and root changes remain manual", tests.testQuestionHistoryGuardsAutomaticResponses),
            ("fresh transport history blocks automatic answers while preserving manual responses", tests.testAutomaticReplyHonorsFreshTransportHistory),
            ("Codex async queue and exact, partial, ambiguous answer resolution", tests.testCodexQuestionResolution),
            ("Codex read-only history, incremental updates and restart", tests.testCodexHistoryReadOnlyAndIncremental),
            ("Managed Mac load: native file metadata follows live descriptors and exact Unicode", tests.testNativeOpenFilesFollowDescriptorChangesAndUnicode),
            ("Managed Mac load: native file metadata rejects bounds, stale identity and cancellation", tests.testNativeOpenFilesRejectBoundsChangedIdentityAndCancellation),
            ("Process identity: cached start-time formatting preserves concurrent results", tests.testTTYProcessStartFormattingIsStableUnderConcurrentReads),
            ("Managed Mac load: per-process file failures do not block healthy current Codex questions", tests.testCodexCollectorIsolatesFileFailuresAndFollowsCurrentRollout),
            ("Codex root-thread binding excludes children and ambiguous processes", tests.testCodexThreadBinding),
            ("concurrent question alerts, errors, dismissal and session exit", tests.testConcurrentCodexAttentionAndDismissal),
            ("Past questions: persistent batch cleanup, restart, undo and new question isolation", tests.testPastQuestionCleanupPersistsRestoresAndKeepsNewQuestions),
            ("Past questions: changed, new, duplicate and uncertain requests reject atomically", tests.testPastQuestionCleanupRejectsNewChangedAndUncertainRequestsAtomically),
            ("Past questions: failed storage rolls back every marker and visible change", tests.testPastQuestionCleanupRollsBackStorageFailure),
            ("Terminal custom and window titles with isolated failures", tests.testTerminalTitleContract),
            ("Native Terminal content and title batches use exact targets and stable metadata", tests.testNativeTerminalBatchesOnlyRequestedContentsAndTitlesWithStableIdentities),
            ("Native Terminal small multi-tab reads use exact TTY events", tests.testNativeTerminalKeepsSmallMultiTabReadsIndividual),
            ("Native Terminal refreshes titles only for stale TTYs", tests.testNativeTerminalReadsTitlesOnlyForExpiredTTYs),
            ("Native Terminal slow contents identity lookup temporarily falls back to exact TTY reads", tests.testSlowBulkContentsIdentityQueryRequestsTemporaryPerTTYFallback),
            ("Native Terminal slow title batches temporarily use cached titles", tests.testSlowBulkTitleQueriesRequestTemporaryTitleFallback),
            ("Native Terminal title batch rejects unstable and unsupported metadata", tests.testNativeTerminalTitleBatchRejectsUnstableAndUnsupportedMetadata),
            ("Native Terminal title batch stops on denial, deadline and cancellation", tests.testNativeTerminalTitleBatchStopsOnDenialDeadlineAndCancellation),
            ("Loopback server avoids LAN advertisements, discovery and saved-peer mutations", tests.testLoopbackServerDoesNotDiscoverAdvertiseOrRewritePeers),
            ("varied yes/no questions, exact labels and ambiguous alternatives", tests.testYesNoConfirmationSelection),
            ("confirmation menus never choose tasks or multiple answers", tests.testConfirmationMenusNeverChooseTasksOrMultipleAnswers),
            ("Permission cleanup: ASCII identities preserve hint order and task rejection", tests.testPermissionCleanupKeepsASCIIHintOrderAndTaskRejection),
            ("Allow, Deny and Don't allow labels preserve one-time scope", tests.testAllowConfirmationLabels),
            ("Current model: only an explicit unique existing model is retained", tests.testCurrentModelQuestionPolicy),
            ("Current model: Claude hooks retain opt-in, pause, exact answer and audit", tests.testCurrentModelHookPreservesOptInPauseAndAudit),
            ("Codex tool permission columns, Cancel, wrapping and active-dialog guards", tests.testCodexToolPermissionColumnsAndCancellation),
            ("Korean Allow, Always Allow and Deny retain one-time scope and exact labels", tests.testKoreanPermissionLabels),
            ("Korean permission question hook responses, opt-in, deduplication and audit", tests.testKoreanPermissionHookResponseAndAudit),
            ("repeated permission variants preserve the current-request answer", tests.testRepeatedPermissionChoicesPreferCurrentRequest),
            ("repeated permissions never select different tasks or ambiguous answers", tests.testRepeatedPermissionChoicesRejectDifferentDecisions),
            ("Claude and Codex permission variants, wrapped labels and active selection", tests.testBothAgentsRecognizeRepeatedPermissionVariants),
            ("Claude question hook output, cross-event deduplication and saved answer", tests.testYesNoConfirmationHookAndAudit),
            ("question responses require enrollment, resume and the correct session", tests.testYesNoConfirmationOptInAndPause),
            ("question response requires a durable audit", tests.testYesNoConfirmationRequiresSavedAudit),
            ("manual attention, duplicate polling, resolution and repeated questions", tests.testAttentionLifecycle),
            ("Attention counts and existence preserve safety, exact keys, grouping and lifecycle", tests.testAttentionCountsAndExistencePreserveCandidateLifecycle),
            ("Attention terminal fallback keeps exact keys and canonical queued-title deduplication", tests.testAttentionTerminalFallbackKeepsExactKeysAndCanonicalDeduplication),
            ("Attention notification deadlines sleep to delivery and preserve elapsed delay changes", tests.testAttentionNotificationDeadlinesAvoidPollingAndPreserveElapsedDelay),
            ("Question notification delay default, persistence, bounds and failed save", tests.testQuestionNotificationDelayPersistenceAndValidation),
            ("notification opens exact live session only", tests.testAttentionTarget),
            ("three-choice question survives Claude reminders and notifies once", tests.testThreeChoiceAttention),
            ("durable audit history, filtering, pagination and result updates", tests.testAuditHistoryQueries),
            ("full hook request and project survive session exit and restart", tests.testAuditContextSurvivesSession),
            ("reveal exact Terminal tab, minimized restoration and closed-tab isolation", tests.testTerminalRevealTarget),
            ("Launch environment keeps only terminal identity and rejects reused PIDs", tests.testLaunchEnvironmentKeepsOnlyTerminalIdentity),
            ("iTerm2, Orca, multiplexers, forks and nested PTYs identify their host", tests.testTerminalHostIdentification),
            ("iTerm2 visible rows, foreground job check, reveal and permission errors", tests.testITermScriptingContract),
            ("Orca CLI envelope, rendered screen and handle-less refusal", tests.testOrcaCommandContract),
            ("iTerm2 and Orca connections are opt-in, independent and restored", tests.testScreenHostConnectionsAreIndependent),
            ("Codex sub-agent approvals in the parent overlay and clipped long requests", tests.testCodexSubAgentAndClippedApprovals),
            ("window placement across desktop coordinate systems", tests.testTerminalHighlightCoordinates),
            ("long commands and canonical Unicode dialogs", tests.testLongPermissionAndCanonicalUnicode),
            ("interactive question menus versus approval and stale text", tests.testQuestionMenus),
            ("Terminal final validation, exact single input and unreadable tab windows", tests.testTerminalApprovalValidation),
            ("Capacity cell prefix: normal history, Goal fields, held drafts and original errors", tests.testCapacityCellPrefixPreservesGoalAndErrorFields),
            ("Codex capacity stop: real frames, wrapped cell, draft, submission and blocked composers", tests.testCodexCapacityStopDetection),
            ("Codex capacity history: old questions preserve records without blocking a new capacity retry", tests.testCapacityRetryWithHistoricalQuestions),
            ("CLI errors: all error kinds, unknown provider wording and history keep retrying beyond backoff", tests.testAllCLIErrorCellsKeepRetrying),
            ("CLI errors: transport recovery preserves the current question until later user progress", tests.testTransportRetryPreservesCurrentQuestion),
            ("CLI errors: definite non-writes retry beyond three failures and recover when input returns", tests.testRecoveryKeepsRetryingDefiniteNonWrites),
            ("CLI errors: proven rejected writes retry while ambiguous delivery remains single-use", tests.testRecoveryRetriesRejectedWritesButPreservesUnknownResults),
            ("CLI errors: a new failed root turn retries an identical viewport across app restart", tests.testIdenticalErrorUsesNewFailedRootTurnAcrossRestart),
            ("CLI errors: authoritative new failure resolves an uncertain previous delivery without replay", tests.testUncertainRecoveryContinuesAfterAuthoritativeNewFailure),
            ("Codex capacity retries continue beyond the backoff schedule without replaying old frames", tests.testCapacityRetryContinuesBeyondBackoffSchedule),
            ("Codex continue scripts type, re-read, then submit only a visible draft", tests.testCodexResumeScriptsTypeThenSubmit),
            ("Resume submission: validate the entire owned composer, footer and original conversation", tests.testOwnedResumeDraftRequiresEntireComposer),
            ("Resume submission: large scrollback preserves composer ownership checks", tests.testOwnedResumeDraftWithLargeScrollback),
            ("Resume submission: newline-only Return retries survive restart without retyping", tests.testResumeSubmissionSurvivesNewlinesAndRestart),
            ("Resume submission: cancellation, pause, opt-out and user edits survive restart", tests.testResumeSubmissionPreservesUserControls),
            ("Resume submission: legacy Goal drafts require the exact saved audit receipt", tests.testLegacyGoalDraftRecoversOnlyExactAuditReceipt),
            ("Resume submission: rejected Return retries continue without retyping the request", tests.testResumeSubmissionRetriesRejectedEnterWithoutRetyping),
            ("Resume submission: the original Terminal script sends Return alone for a saved draft", tests.testOwnedResumeReturnScriptDoesNotRetype),
            ("Codex capacity continue: opt-in, capped backoff, cancel, pause, drafts and unverified writes", tests.testCodexCapacityResumeRuns),
            ("CLI interruption detection rejects drafts, busy frames and historical errors", tests.testSessionInterruptionDetection),
            ("Automation optimization: identical or wrapped failures cannot repeat plain or Goal continuation", tests.testUnchangedFailureNeverQueuesRepeatedContinuation),
            ("Automation optimization: exit preflight rechecks cancellation, pause, disconnect and opt-out", tests.testExitRecoveryRechecksCancellationAtEveryRead),
            ("Automation optimization: a stale resume result cannot overwrite a new failure", tests.testStaleResumeResultCannotReplaceNewFailure),
            ("Automation optimization: normal completion retires errors before process exit", tests.testNormalCompletionRetiresFailureBeforeExit),
            ("Local dashboard address maps self and preserves other names, backup, permissions and inode", tests.testLocalDashboardNamePreservesHostFileAndOnlyMapsSelf),
            ("Local dashboard alias accepts its exact origin and rejects unrelated sites", tests.testLocalDashboardOriginKeepsExactSameOriginRules),
            ("Local status read: Unicode and all newline forms preserve parsed results", tests.testBoundedLocalStatusPreservesTextAndUnicode),
            ("Local status read: exact byte limit and oversized rejection before read", tests.testBoundedLocalStatusRejectsBeforeReadingLargeFilesAndKeepsExactLimit),
            ("Local status read: fresh rewrites, regular symlinks and nonblocking failures", tests.testBoundedLocalStatusFreshRewritesSymlinksAndFailures),
            ("Local status read: concurrent growth stays within one byte budget", tests.testBoundedLocalStatusConcurrentGrowthKeepsReadBudgetAndNoCache),
            ("Local status read: repeated success and failure close descriptors", tests.testBoundedLocalStatusClosesDescriptorsOnEveryExit),
            ("Local status parser: streaming keeps the released lexical corpus", tests.testStreamingLocalStatusMatchesReleasedLexicalCorpus),
            ("Local status parser: complete newline set and foreign UTF-16 block boundaries", tests.testStreamingLocalStatusKeepsNewlineSetAndCocoaBlockBoundaries),
            ("Local status parser: dense inputs, long lines and late conflicts", tests.testStreamingLocalStatusDenseInputsKeepLateConflictsAndLongLines),
            ("Local status parser: prepared text and conflict rejection stay unchanged", tests.testStreamingLocalStatusPreservesPreparedTextAndConflictRejection),
            ("Cold dashboard publishes healthy Macs and bookmarked local pages before six stalled reads", tests.testColdDashboardPublishesHealthyPeerBeforeStalledReads),
            ("Known offline dashboards preserve selected reconnect, discovery, validators and successful-read expiration", tests.testKnownUnavailableDashboardPreservesSelectionDiscoveryAndFreshReads),
            ("Peer inventory completion waits isolate cancellation and preserve revision, shutdown and timeout boundaries", tests.testPeerCacheCompletionWaitPreservesSharedReadsAndClosesRaces),
            ("Dashboard encoding: default worker preserves wire, tags and fresh controls", tests.testDashboardDefaultEncodingPreservesWireAndFreshControls),
            ("Dashboard encoding: late old responses cannot displace a newer validator", tests.testDashboardLateEncodingCannotDisplaceNewValidator),
            ("Dashboard encoding: cancellation prevents late publication and cache writes", tests.testDashboardCancellationCannotPublishOrCacheLateEncoding),
            ("Dashboard encoding: service stop rejects late generation responses", tests.testDashboardStopRejectsLateEncodingFromOldGeneration),
            ("Dashboard encoding: origin and pinned node checks precede work", tests.testDashboardEncodingNeverPrecedesOriginAndNodeChecks),
            ("Dashboard encoding: equivalent consumers share only active work", tests.testDashboardConcurrentRequestsShareOnlyActiveEncoding),
            ("Dashboard encoding: one cancelled consumer preserves the surviving request", tests.testDashboardOneCancelledConsumerKeepsSharedEncodingAlive),
            ("Dashboard encoding: cancellation wakes HTTP before held producer and a new request works", tests.testDashboardCancellationWakesBeforeHeldProducerAndAllowsNewRequest),
            ("Dashboard encoding: stop wakes HTTP before held preparation returns", tests.testDashboardStopWakesBeforeHeldPreparationIsReleased),
            ("Dashboard encoding: concurrent cancellation never fails surviving consumers", tests.testDashboardCancellationRacesNeverFailSurvivingConsumers),
            ("Dashboard resource use: validators cover controls and identity, excluding only observation time", tests.testDashboardValidatorIncludesAllContentButNotObservationTime),
            ("Dashboard resource use: conditional reads revalidate origin, identity and current controls", tests.testConditionalDashboardRevalidatesIdentityOriginAndControls),
            ("Dashboard resource use: local inventory reuses validators before rebuilding an unchanged response", tests.testConditionalLocalInventoryReusesFreshValidatorBeforeEncoding),
            ("Dashboard resource use: repeated reads do not republish unchanged native web status", tests.testRepeatedDashboardReadsDoNotRepublishNativeWebStatus),
            ("Terminal stream: unchanged screens back off while input remains responsive", tests.testTerminalStreamPollingBacksOffOnlyWhenUnchanged),
            ("Payload reduction: inventory omits unused notice history while preserving unread safety and native data", tests.testWebInventoryDropsOnlyUnusedNoticeHistory),
            ("Payload reduction: JSON paths, controls, Unicode and base64 round-trip without slash escapes", tests.testWireJSONPreservesStringsWithoutSlashEscapes),
            ("Payload reduction: peer reuse requires a fresh identity-pinned matching 304", tests.testPeerInventoryReusesOnlyFreshIdentityPinned304),
            ("Payload reduction: peer validation storage bounds bytes, peers, routes and age", tests.testPeerInventoryValidationRetentionIsBounded),
            ("Payload reduction: gzip inventory pins strong validators to the selected representation and reuses verified 304", tests.testPeerInventoryCompressionKeepsRepresentationValidatorsAndCache),
            ("Payload reduction: inventory compression preserves legacy, size bounds and cancellation", tests.testPeerInventoryCompressionKeepsBoundsLegacyAndCancellation),
            ("Stream compression: every SSE event flushes immediately and preserves exact bytes", tests.testSSEGzipFlushesEachEventAndPreservesExactBytes),
            ("Stream compression: encoding negotiation, bounds, heartbeat and empty opening", tests.testSSEGzipNegotiationBoundsAndEmptyStart),
            ("Terminal HTTP response encodes once within its wire bound", tests.testTerminalHTTPResponseEncodesOnceWithinWireBound),
            ("HTTP compression: complete members preserve exact bytes at bounded compression levels", tests.testCompleteGzipUsesNegotiatedLevelWithoutChangingBytes),
            ("Peer HTTP: explicit OS privacy denial stops; temporary network/VPN loss retains recovery", tests.testPeerLocalNetworkDenialIsExplicitAndDoesNotReplaceTemporaryLoss),
            ("Peer HTTP: fragmented identity/gzip responses preserve bytes and validators", tests.testPeerHTTPResponseDecodesFragmentedIdentityAndGzipExactly),
            ("Peer HTTP: ambiguous headers and wrong identity fail before selecting a route", tests.testPeerHTTPResponseRejectsAmbiguousHeadersAndWrongIdentity),
            ("Peer HTTP: truncated bodies, corrupt gzip and decompression limits are rejected", tests.testPeerHTTPResponseRequiresCompleteBoundedGzipAndBody),
            ("Adaptive read timing: learns load and jitter with bounded fast recovery", tests.testReadTimingLearnsLoadAndVariationWithinRecoveryBounds),
            ("Adaptive read timing: isolates routes, operation kinds, peers and expired samples", tests.testReadTimingIsolatesRoutesOperationsAndExpiredKnowledge),
            ("Adaptive read timing: rejects invalid samples and bounds storage", tests.testReadTimingRejectsInvalidSamplesAndBoundsStorage),
            ("Active terminal polling reduces stable-frame reads and stays bounded", tests.testActiveScreenPollingEasesOffOnlyAfterStableFrames),
            ("Stream deltas: UTF-16 edits preserve exact Unicode and never split surrogate pairs", tests.testTerminalScreenPatchPreservesUTF16AndExactUnicode),
            ("Scroll copy: both directions preserve exact Unicode and periodic spans", tests.testScrollCopyPreservesExactUnicodeInBothDirections),
            ("Scroll copy: unrelated and oversized screens bound matching work", tests.testScrollCopyBoundsWorkAndRejectsUnrelatedScreens),
            ("Peer stream compression: fragmented and coalesced events use bounded decoder pulls", tests.testPeerGzipDecoderHandlesFragmentsAndBoundedPulls),
            ("Peer stream compression: corruption, truncation, trailing bytes and input bounds", tests.testPeerGzipDecoderRejectsCorruptionTruncationAndTrailingBytes),
            ("Terminal read recovery: only invalidated observations retry, bounded and cancellable", tests.testTerminalReadRecoveryIsBoundedAndNeverRetriesIdentityOrPermission),
            ("Goal failure recovery uses lifecycle commands and respects drafts, pause, limits and completion", tests.testGoalFailureRecoveryUsesLifecycleCommand),
            ("Goal blocked without an API error reaches automatic lifecycle recovery", tests.testBlockedGoalWithoutAPIErrorIsRecoverable),
            ("Goal blocked scripts verify the current footer, draft and reactivation", tests.testBlockedGoalScriptsVerifyTheLifecycleFooter),
            ("Goal blocked recovery backs off, cancels and retains confirmed sends across restart", tests.testBlockedGoalRecoveryBackoffCancellationAndRestart),
            ("Goal blocked recovery isolates sessions and respects questions, pause and manual mode", tests.testConcurrentBlockedRecoveryRespectsQuestionsPauseAndOptOut),
            ("Goal recovery changes lifecycle commands without replaying an already confirmed prompt", tests.testPlainRecoveryCanTransitionToGoalResumeWithoutReplayingEither),
            ("CLI recovery recognizes varied errors and preserves explicit account failures", tests.testRecoverableErrorVariantsAndAccountFailurePrecedence),
            ("Goal recovery retires numeric approvals and audits the exact continuation command", tests.testGoalRecoveryRetiresNumericApprovalAndAuditsActualCommand),
            ("CLI failures notify once and remain visible after process exit", tests.testInterruptionNotificationKeepsEndedFailureAndDeduplicates),
            ("Codex and Claude recover in the original CLI without replaying uncertain writes after restart", tests.testTransientRecoverySupportsClaudeAndPersistsUncertainWrites),
            ("Exited CLI recovery requires exact conversation, idle shell and original process identity", tests.testExitedRecoveryRequiresExactConversationAndIdleOriginalShell),
            ("Discovery recovery keeps a fresh parent snapshot and the exact original across duplicate PIDs", tests.testDiscoveryRecoveryUsesLatestSnapshotAndExactOriginal),
            ("Exited Claude resumes in its original shell and app restart cannot replay the launch", tests.testExitedRecoveryRestoresExactConversationAndNeverReplays),
            ("CLI errors: exited recovery retries past three definite non-writes in the original shell", tests.testExitedRecoveryRetriesPastThreeNonWrites),
            ("Normal exit never restarts and an empty recovery schedule cannot index out of bounds", tests.testNormalExitDoesNotRestartAndEmptyRecoveryScheduleIsSafe),
            ("Claude StopFailure migration preserves enabled hooks and user removals", tests.testStopFailureHookMigrationPreservesUserHooks),
            ("Cold inventory defers large audit bodies and loads the exact selected history separately", tests.testCompactInventoryDefersAuditWithoutLosingExactHistory),
            ("Claude StopFailure reports an API failure and clears only after real user progress", tests.testClaudeStopFailurePublishesAnErrorAndClearsOnUserProgress),
            ("Keep-awake counts only auto-approved work that continues without the user", tests.testKeepAwakeWorkingSessions),
            ("Keep-awake app lifetime: no sessions, idle, pause and restart", tests.testKeepAwakeAppLifetimeWithoutSessions),
            ("Keep-awake status: legacy peers and combined display/system idle protection", tests.testKeepAwakeStatusLegacyCompatibilityAndDisplayOptions),
            ("Web messages: original Codex and Claude without queue binding; proven rejection and ambiguity", tests.testOriginalWebMessageWithoutQueue),
            ("Web messages: multiline paste framing and existing TTY byte limit", tests.testMessagePasteProtocolAndTTYLimit),
            ("Web messages: Bonjour publication failure keeps HTTP commands available", tests.testBonjourFailureKeepsWebMessagesAvailable),
            ("Mouse activity: one-minute schedule, cancellation and no catch-up burst", tests.testMouseActivityMinuteSchedule),
            ("Mouse activity: locked screen, permission and failure recovery", tests.testMouseActivityLockAndPermission),
            ("Mouse activity: independent of work, pause, battery and heat; restored setting", tests.testMouseActivityIndependentAndRestored),
            ("Keep-awake app lifetime preserves power/thermal safeguards and owned restoration", tests.testKeepAwakeHoldsWhileWorkRemains),
            ("Keep-awake guard releases after exit, a stopped heartbeat or the battery floor", tests.testKeepAwakeGuardScript),
            ("Keep-awake rule allows only pmset sleep commands and survives AppleScript quoting", tests.testKeepAwakeRuleAndAdminScripts),
            ("Terminal opt-in persists and permission denial stops polling", tests.testTerminalConnectionLifecycle),
            ("Claude question content and permission screen fallback", tests.testHookQuestionAndScreenFallback),
            ("permission dialogs and false positives", tests.testCompletePromptAndFalsePositives),
            ("Claude dialog selection", tests.testClaudePromptAndDifferentSelection),
            ("process identity and child filtering", tests.testDiscoveryKeepsIdentityAndFiltersSubprocesses),
            ("padded bare process names and nested PTYs", tests.testPaddedBareProcessNamesAndNestedPTYs),
            ("only Claude/Codex terminals enter the inventory", tests.testOrdinaryTerminalsAreExcluded),
            ("agent exit excludes ordinary shells and idle counts", tests.testAgentExitDoesNotExposeShellOrCountItAsIdle),
            ("ready composer versus quiet work and unknown screens", tests.testActivityNeedsAReadyComposerNotSilence),
            ("activity hints preserve Unicode words and real drafts", tests.testActivityHintsPreserveUnicodeWordsAndRealDrafts),
            ("Activity footer: hint positions and late errors", tests.testActivityFooterHintPositionsAndLateErrors),
            ("Activity footer: goals, drafts and generation", tests.testActivityFooterGoalsDraftsAndGenerationChecks),
            ("Activity footer: Claude custom metadata and genuine hints", tests.testClaudeCustomStatusFooterRequiresComposerHint),
            ("Activity footer: Codex warnings, drafts and menus", tests.testCodexWarningFooterPreservesDraftsAndRejectsMenus),
            ("Activity footer: Codex server waiting dialog", tests.testCodexServerWaitDialogRemainsWorkingWithoutInput),
            ("prompt line normalization preserves CR/LF, canonical text and trailing blank removal", tests.testPromptLineNormalizationPreservesNewlinesAndCanonicalText),
            ("stable idle confirmation and new screen generations", tests.testIdleConfirmationAndGenerationChange),
            ("idle duration, work transition, connection loss", tests.testEngineClearsIdleOnWorkAndDisconnection),
            ("Claude idle events and new input", tests.testHookIdleResetsOnNewInput),
            ("early hook preserves enrollment after restart", tests.testHookBeforeDiscoveryRestoresEnrollment),
            ("Terminal dictionary contract and closed-tab isolation", tests.testTerminalScriptingContractAndPartialFailure),
            ("Terminal batch reads only exact targets with constant discovery cost", tests.testTerminalBatchReadsOnlyExactTargetsWithBoundedDiscovery),
            ("Terminal batch preserves cursor identity and isolates closed tabs", tests.testTerminalBatchPreservesCursorAndIsolatesClosedTabs),
            ("Terminal cursor reads never measure or resize the source window", tests.testTerminalCursorReadsNeverMeasureWindowsDuringResize),
            ("Terminal and iTerm metadata never measure or change source windows", tests.testTerminalMetadataNeverMeasuresOrChangesWindows),
            ("Terminal batch falls back on topology changes and propagates denial", tests.testTerminalBatchRetriesChangedWindowTopologyWithoutHidingDenial),
            ("Terminal text-only legacy reads skip titles and retain identity, cursor and denial checks", tests.testTerminalTextOnlyLegacyReadsSkipTitlesWithoutWeakeningIdentity),
            ("Native Terminal reads keep exact predicates and original Unicode text", tests.testNativeTerminalReadUsesExactPredicatesAndPreservesText),
            ("Native Terminal first text skips every presentation query", tests.testNativeTerminalFirstTextSkipsAllPresentationQueries),
            ("Remote native reads retain authorization, exact fallback and revocation", tests.testRemoteNativeReadKeepsAuthorizationAndExactFallback),
            ("Remote native reads stop at every cancellation boundary", tests.testRemoteNativeReadCancellationStopsEveryBoundary),
            ("Native Terminal live presentation binds and rechecks exact selected windows", tests.testNativeTerminalPresentationBindsAndRechecksSelectedWindow),
            ("Native Terminal reads isolate closed/ambiguous targets and stop on denial", tests.testNativeTerminalReadIsolatesClosedAndAmbiguousTargetsAndStopsOnDenial),
            ("Native Terminal reads budget cancellation and reject reordered metadata", tests.testNativeTerminalReadBudgetsCancellationAndRejectsReorderedMetadata),
            ("Terminal permission error propagation", tests.testTerminalPermissionFailureIsNotHidden),
            ("enrollment, pause, duplicate requests, isolation", tests.testHookRequiresEnrollmentHonorsPauseAndDoesNotReplay),
            ("discovery capability and process exit", tests.testDiscoveryDoesNotClaimControlAndEndsMissingSessions),
            ("hook installation preserves settings", tests.testHookInstallPreservesOtherSettingsAndIsIdempotent),
            ("SQLite persistence", tests.testAuditPersistsSettingsAndEvents),
            ("disconnected controls and reveal capability", tests.testDisconnectedEnrollmentCanBeDisabled)
        ]
#if DEBUG
        cases.insert(contentsOf: [
            ("Idle poller observations park until source change or cancellation", tests.testIdleObservationWaitsForChangeOrCancellation),
            ("Terminal stream: reused JSON encoder preserves equivalent screen and heartbeat data", tests.testTerminalStreamEncoderReusePreservesWireBytes),
            ("Managed Mac load: stale NFS descriptor paths do not abort open-file discovery", tests.testDescriptorPathReaderSkipsOnlyTransientFDPathErrors),
            ("Screen parsing: ordinary scrollback stays on its bounded suffix", tests.testOrdinaryScrollbackDoesNotMaterializeTrimmedRows),
            ("Screen parsing: source byte counting reuses bridged line normalization", tests.testScreenAnalysisPreservesSourceUTF8ByteCountAcrossLinePreparation),
            ("Screen parsing: Cocoa UTF-16 chunk boundaries preserve rows and source budgets", tests.testCocoaLinePreparationPreservesUTF16ChunkBoundariesAndSourceBudget),
            ("Cocoa normalization: exact rows and original source budgets", tests.testCocoaNormalizationKeepsExactRowsAndSourceBudget),
            ("Codex history: reuse bounded read-only SQLite connections", tests.testCodexHistoryConnectionsAreReusedAndBounded),
            ("Codex history: unchanged DB version skips reads and external commits invalidate", tests.testUnchangedDatabaseVersionSkipsSessionHistoryQueriesAndExternalCommitInvalidatesIt),
            ("Codex history: replaced database file reopens safely", tests.testCodexHistoryConnectionCacheReopensReplacedDatabase),
            ("Codex history: replaced database rebuilds its session projection", tests.testSessionHistoryProjectionRebuildsWhenDatabaseFileIsReplaced),
            ("Codex history: prepared statements are reused per connection", tests.testHistoryStatementsArePreparedOncePerReusedConnection),
            ("Codex history: inactive readers release database statements", tests.testSessionHistoryReaderReleasesStatementsForInactiveDatabase),
            ("Codex history: incremental reads seek both append and rewrite indexes", tests.testIncrementalHistoryQueryUsesAppendAndRewriteIndexes),
            ("Codex history performance: unchanged delta reads stay bounded", tests.testUnchangedHistoryQueryCostDoesNotScaleWithThreadRows),
            ("Codex history: collector rebuilds after database replacement", tests.testCodexCollectorRebuildsProjectionAfterHistoryFileReplacement),
            ("Codex history: synchronous agent rewrites skip large bodies", tests.testIncrementalHistoryQueryOmitsSynchronousAgentBodies),
            ("Codex history: retain question projections and replay old user edits", tests.testHistoryCacheRetainsQuestionsNotOrdinaryMessagesAndReplaysOldEdits),
            ("Codex history: async-to-sync rewrites clear stale pending questions", tests.testRewriteFromAsyncQuestionToSynchronousAgentMessageClearsPendingQuestion)
        ], at: 0)
#endif
        let filterIndex = CommandLine.arguments.firstIndex(of: "--filter")
        let filter = filterIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
        let selected = cases.filter { filter == nil || $0.0.localizedCaseInsensitiveContains(filter!) }
        if selected.isEmpty { print("No matching checks"); exit(1) }
        var failures = 0
        for (name, run) in selected {
            do { try await run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        print("\(selected.count - failures)/\(selected.count) checks passed")
        if failures > 0 { exit(1) }
    }
}
