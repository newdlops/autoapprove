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
        try expectEqual(PromptDetector.detect(codex, agent: .codex, prepared: permissionLines)?.dialog, codex,
            "The native scanner must retain the exact real dialog without requiring a full row-array allocation")
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
#if DEBUG
        if await BundledRuntimeProbe.runIfRequested() { return }
#endif
        let tests = ApprovalTests()
        var cases: [(String, () async throws -> Void)] = [
            ("Session groups: exact conversation identity validation",tests.testSessionGroupIdentityValidation),
            ("Session groups: terminal status refresh rejects historical IDs",tests.testSessionGroupTerminalStatusRequiresFreshCard),
            ("Session groups: storage and malformed data preservation",tests.testSessionGroupStoragePreservesInvalidData),
            ("Session groups: live conversation identity and ambiguity",tests.testSessionGroupMatchingRejectsAmbiguousAndChangedConversations),
            ("Session groups: MCP caller isolation and same-agent members",tests.testSessionGroupMCPOnlyReturnsCallersGroupsAndSameAgent),
            ("Session groups: exact binding without thread discovery",tests.testSessionGroupObservationsUseExactBindingWithoutThreadList),
            ("Session groups: stale process revalidation",tests.testSessionGroupObservationRejectsExitedProcess),
            ("Session groups: leader tree validation, moves and legacy files",tests.testSessionGroupTreeValidationAndEdits),
            ("Session groups: reports only the assigned turn, one line",tests.testSessionGroupOrchestrationReportsOnlyTheAssignedTurn),
            ("Session groups: worker question returns and completion becomes a report",tests.testGroupWorkerQuestionReturnsAndCompletionBecomesReport),
            ("Session groups: a task turns on worker automatic approval",tests.testGroupTaskTurnsOnWorkerAutomaticApproval),
            ("Session groups: a worker choice question reaches the parent and is answered",tests.testGroupWorkerChoiceQuestionReachesParentAndIsAnswered),
            ("Session groups: list badges tell leaders from members",tests.testSessionGroupBadgesForSessionLists),
            ("Session groups: session list tree nests members and keeps order",tests.testSessionListTreeNestsGroupsAndKeepsOrder),
            ("Session restart: command keeps known options only",tests.testSessionRestartCommandKeepsKnownOptionsOnly),
            ("Session restart: process arguments parse only argv",tests.testProcessArgumentsParseOnlyArgv),
            ("Session restart: exits and reopens the same conversation",tests.testSessionRestartExitsAndReopensTheSameConversation),
            ("Session restart: a shell-less CLI is left untouched",tests.testSessionRestartLeavesShelllessCLIUntouched),
            ("Session restart: unsupported terminals are refused",tests.testSessionRestartRefusesUnsupportedTerminals),
            ("Session profiles: multiple private files, explicit update, import and restart",tests.testTerminalProfilesMultiplePrivateFilesAndRestart),
            ("Session profiles: fresh native titles repair startup capture and active duplicate detection",tests.testTerminalProfileFreshTabTitleRepairsStartupCaptureAndActiveDeduplication),
            ("Session profiles: unresolved conversations require an explicit new CLI choice",tests.testTerminalProfileSavingRequiresExplicitNewCLISelection),
            ("Session profiles: validated explicit binding and preserved identity failures",tests.testTerminalProfileCaptureUsesValidatedExplicitBindingAndPreservesFailures),
            ("Session profiles: malformed, future, duplicate and unsafe files",tests.testTerminalProfilesRejectMalformedUnsafeAndDuplicateFiles),
            ("Session profiles: fixed resume grammar and native host contracts",tests.testTerminalProfileFixedCommandsAndNativeHostContracts),
            ("Session profiles: optional conversation starts CLI and saves separate entries",tests.testTerminalProfileFreshCLICommandsAndPrivateFiles),
            ("Session profiles: fresh CLI tabs and bounded duplicate launch receipts",tests.testTerminalProfileFreshCLIRestoreKeepsTabsAndReceipts),
            ("Session profiles: duplicate prevention, missing folder and uncertain delivery",tests.testTerminalProfileRestoreDeduplicationAndPartialFailure),
            ("Session profiles: exact identity, explicit daemon picker and stale process",tests.testTerminalProfileCaptureBindsExactConversationsAndRejectsStalePID),
            ("Session profiles: restore skips AX/pickers and save shares fresh conversation lists",tests.testTerminalProfileRestorationSkipsLayoutAndPickersAndSaveSharesLists),
            ("Session profiles: full named Codex binding excludes ambiguous and preview matches",tests.testCodexProfileNameBindingRequiresUniqueFullNamedConversation),
            ("Session profiles: named daemon conversations persist and resume automatically",tests.testTerminalProfileAutomaticallySavesNamedDaemonConversationsAndResumesThem),
            ("Session profiles: changed native title rejects a stale Codex conversation",tests.testTerminalProfileNamedConversationRejectsChangedNativeTitle),
            ("OS permissions: signed identity and unambiguous requester headlines",tests.testOSPermissionPolicyIdentityAndPromptAttribution),
            ("OS permissions: manual response with AUTO off and durable replay protection",tests.testOSPermissionManualResponseWithoutAutomaticPolicyAndDurableReplayGuard),
            ("OS permissions: manual stale, protected, pause and source validation",tests.testOSPermissionManualResponseRejectsStaleProtectedPausedAndChangedSource),
            ("OS permissions: uncertain manual response cannot retry or auto allow",tests.testOSPermissionManualUncertainResponseCannotBeRetriedOrAutoAllowed),
            ("OS permissions: explicit kinds, app enrollment and session isolation",tests.testOSPermissionDefaultsAndSessionIsolation),
            ("OS permissions: shared controllers are current-request only",tests.testOSPermissionSharedControllersAreOneRequestOnly),
            ("OS permissions: manager setup stays manual without blocking CLI work",tests.testOSPermissionManagerSetupIsManualAndIndependent),
            ("OS permissions: pause, OFF, revocation, typing and original process races",tests.testOSPermissionPauseOffRevocationAndProcessChange),
            ("OS permissions: durable receipts prevent replay after restart",tests.testOSPermissionReceiptsSurviveRestartAndUncertainInput),
            ("OS permissions: settings transition and direct user authentication",tests.testOSPermissionSettingsTransitionAndManualAuthentication),
            ("OS permissions: permission waiting suspends progress and terminal approval",tests.testOSPermissionWaitingStopsProgressInterruptAndTerminalApproval),
            ("OS permissions: last-moment revocation and reused CLI identity",tests.testOSPermissionLastMomentRevocationAndReusedSessionIdentity),
            ("OS permissions: one-request settings scope ends on withdrawal",tests.testOSPermissionOneShotSettingsAndPolicyWithdrawal),
            ("Permission footer: hard wrap, complete dialog and trailing output rejection",tests.testHardWrappedPermissionFooterRetainsWholeDialogAndRejections),
            ("Codex approval reflow: late validation respects pause, OFF and newer question",tests.testApprovalReflowLateValidationCannotOverridePauseDisableOrNewQuestion),
            ("Codex file edits: connected session uses one visible approval",tests.testBoundCodexFileEditsUseOneVisibleScreenApproval),
            ("Codex file edits: other and uncertain inputs remain guarded",tests.testBoundCodexScreenApprovalRejectsOtherAndUncertainRequests),
            ("Codex file edits: pause, disabled, selection and system guard",tests.testBoundCodexFileEditScreenRespectsPauseSelectionAndSafety),
            ("Codex approval reflow: unknown delivery never refreshes or retries",tests.testApprovalReflowUnknownDeliveryNeverStartsRefreshOrRetry),
            ("Codex approval reflow: cell-wrapped choices and subagent keep one-time scope",tests.testCodexApprovalCellWrappedChoicesAndSubagentPreserveOneTimeScope),
            ("Codex approval reflow: Allow reason keeps enclosing command heading",tests.testCodexAllowReasonCannotReplaceTheEnclosingCommandHeading),
            ("Codex approval reflow: clipped, unknown and task choices remain manual",tests.testCodexReflowNeverCompletesClippedUnknownOrTaskChoices),
            ("Codex approval reflow: final validator binds exact command and question",tests.testCodexReflowFinalValidatorStillChecksExactCommandAndQuestion),
            ("Codex approval reflow: fresh original follows a definitive mismatch without an event",tests.testApprovalReflowDefinitiveMismatchReadsFreshOriginalWithoutAnotherEvent),
            ("Codex approval reflow: fresh task question retires a stale permission",tests.testApprovalReflowFreshQuestionRetiresOldPermissionWithoutAnAnswer),
            ("Native typing: answered permission survives composer repaint",tests.testAnsweredPermissionSurvivesManualComposerRepaints),
            ("Native typing: host isolation and physical idle",tests.testNativeTypingActivitySeparatesHostsAndPhysicalIdle),
            ("Native typing: local input yields without disabling automation",tests.testNativeTypingYieldsApprovalWithoutDisablingAutomation),
            ("Native typing: input during process validation cancels dispatch",tests.testNativeTypingCancelsApprovalDuringProcessValidation),
            ("Native typing: new work and stable idle release the old receipt",tests.testAnsweredPermissionRetiresOnlyAfterRealResolution),
            ("Local socket: fragmented Unicode, large lines, buffered order and permissions", tests.testLocalSocketFragmentedUnicodeAndBufferedOrdering),
            ("Local socket: malformed and oversized peers, bounded connections and single disconnect", tests.testLocalSocketMalformedOversizedAndBoundedPeers),
            ("Local socket: restart descriptor lifetime and path ownership", tests.testLocalSocketRestartAndPathOwnership),
            ("Screen parsing: Cocoa preparation preserves prompt identity and quoted questions", tests.testCocoaLinePreparationPreservesPromptIdentityAndQuotedQuestions),
            ("Screen parsing: bounded Cocoa suffix retains current and quoted menus", tests.testCocoaBoundedSuffixPreservesCurrentAndQuotedMenus),
            ("Screen parsing: fused Cocoa suffix preserves long trailing blanks and old fence context", tests.testCocoaFusedTrailingBlanksKeepCurrentRequestsAndFenceContext),
            ("Screen parsing: large Cocoa menus preserve normalized fence semantics", tests.testLargeCocoaMenuKeepsNormalizedFenceSemantics),
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
            ("OS permissions: web revision rejects revoked, ABA and exited policies",tests.testOSPermissionWebRevisionRejectsStalePolicyAndABARestore),
            ("Web interaction: explicit single/multiple/free-text answers and bounds", tests.testWebQuestionAnswersAreExplicitAndBounded),
            ("Web interaction: MCP ownership, expiry and no default answer", tests.testWebQuestionOwnershipExpiryAndNoDefaultAnswer),
            ("Web interaction: MCP stdio initialization, tool list and errors", tests.testMCPStdioProtocolAndToolErrors),
            ("Web interaction: explicit screen capture, cache, permission and stop", tests.testTestScreenCaptureIsExplicitAndStops),
            ("Discovery: passive neighbor cache filtering and nearby address order", tests.testDiscoveryNeighborHintsAndNearbyOrder),
            ("Web interaction: Claude multiple questions and editing hold", tests.testClaudeWebAnswersMultipleQuestionsAndEditingHold),
            ("Approval recovery: wrapped headings retain identity and active selection", tests.testWrappedPermissionHeadingsKeepRequestIdentity),
            ("Approval recovery: next permission resumes after input completion without another frame", tests.testNextPermissionResumesWhenPreviousInputCompletes),
            ("Approval recovery: consecutive Claude panels tolerate history and reflow", tests.testClaudeConsecutivePanelsAndHistoryReflow),
            ("Approval recovery: confirmed non-write retries without another output event", tests.testConfirmedNonWriteRecoversWithoutAnotherOutputEvent),
            ("Approval recovery: exact Terminal tab works without frontmost app or focus", tests.testApprovalTargetsTabWithoutFrontmostAppOrKeyboardFocus),
            ("Approval recovery: uncertain input is not retried after reflow or resume", tests.testUncertainApprovalDoesNotRetryAfterReflow),
            ("Approval recovery: real terminal cells across widths and clipped heights", tests.testPermissionDetectionAcrossTerminalGridSizes),
            ("Native processes: fresh metadata and original terminal host parity", tests.testNativeProcessMetadataAndOriginalHostParity),
            ("Native processes: agent name prefilter preserves Foundation classification", tests.testProcessAgentNamePrefilterKeepsFoundationClassification),
            ("Native processes: concurrent target and missing-PID reads keep independent values", tests.testConcurrentNativeTargetReadsKeepIndependentValues),
            ("Native processes: start formatting follows process-local timezone changes", tests.testNativeProcessStartFormattingFollowsCurrentTimeZone),
            ("Native processes: filtered ancestor lookup revalidates the complete chain", tests.testFilteredAgentAncestryRevalidatesTheCompleteParentChain),
            ("Native processes: input ancestor chain is bounded fresh and fails closed", tests.testInputAncestorChainIsBoundedFreshAndFailsClosed),
            ("Native processes: input ancestor chain matches fresh kernel records", tests.testNativeInputAncestorChainMatchesFreshProcessRecords),
            ("Native processes: current open files prepare questions without input", tests.testNativeQuestionPreparationUsesCurrentProcessAndOpenFiles),
            ("Native processes: cancellation and missing identity", tests.testNativeProcessCancellationAndMissingIdentity),
            ("Background screen analysis preserves questions, errors, drafts and system safety", tests.testBackgroundScreenAnalysisPreservesQuestionsErrorsAndSafety),
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
            ("Released Claude question takes only its choice screen", tests.testReleasedClaudeQuestionTakesOnlyItsChoiceScreen),
            ("Claude registry verifies process identity and exact background parent", tests.testClaudeRegistryIdentityAndExactParent),
            ("Claude restores existing background questions without replaying old hooks", tests.testClaudeRestoresWaitingBackgroundWithoutAHook),
            ("Claude recovered waiting transitions and unavailable metadata", tests.testClaudeRecoveredWaitingTransitionsAndUnavailableMetadata),
            ("Claude recovered question metadata identity and staleness", tests.testClaudeRecoveryMetadataIdentityAndStaleness),
            ("Background hooks inherit main policy and retain original audit context", tests.testBackgroundHookInheritsMainAndAuditsOrigin),
            ("Grouped concurrent questions, notifications, completions and read persistence", tests.testGroupedQuestionsNoticesAndReadPersistence),
            ("Background first hook, restart, orphan and PID reuse", tests.testBackgroundFirstHookRestartAndParentExit),
            ("Main screen cannot duplicate a background hook response", tests.testParentScreenCannotDuplicateChildHook),
            ("Claude disconnection persists disabled approval and stops on save failure", tests.testClaudeDisconnectionPersistsOffAndRejectsFailedSave),
            ("Exact Korean JSON, independent badges, early-hook preferences and opt-in answer", tests.testKoreanSampleAndPerSessionReadPersistence),
            ("Codex request identity separates commands from wrapping, history and shortcuts", tests.testCodexRequestIdentitySeparatesCommandsFromRendering),
            ("Wrapped final permission options and keyboard hints retain active-dialog validation", tests.testWrappedPermissionOptionsAndFooter),
            ("Wrapped label text that starts with a redirect, arrow or number stays in its option", tests.testWrappedLabelTextMayLookLikeACursorOrAnOption),
            ("Claude Code 2.1.28x prefix, mode and directory choices with the Tab to amend hint", tests.testClaudeCode2128PermissionMenus),
            ("Claude and Codex ready composers with background monitoring", tests.testMonitoringRequiresReadyComposer),
            ("Claude background stop, reminders, new work and final completion", tests.testClaudeMonitoringHookLifecycle),
            ("Session order, identity, discovery and restart persistence", tests.testSessionOrderPersistsAcrossDiscoveryAndRestart),
            ("Session names, notes and colors persist without crossing session identities", tests.testCustomizationPersistsAndStaysInItsSession),
            ("Session customization reset and original/name/note search", tests.testCustomizationResetAndSearch),
            ("Session customization validation and old snapshot compatibility", tests.testCustomizationValidationAndCompatibility),
            ("Claude final response, duplicate Stop, new work and pause", tests.testClaudeCompletionLifecycle),
            ("Claude background work, scheduled follow-ups and unanswered questions", tests.testClaudeIncompleteStopDoesNotNotify),
            ("Codex completion baseline, short turns and failed or interrupted outcomes", tests.testCodexCompletionBaselineAndOutcomes),
            ("completion lifecycle, question isolation and history recovery", tests.testCodexCompletionEngineAndRecovery),
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
            ("automatic English/Korean Allow preserves the one-time label after five seconds", tests.testAutomaticAllowQuestionReply),
            ("automatic question response cancellation, manual answer, new content and resume", tests.testAutomaticQuestionReplyCancellationAndResume),
            ("automatic question responses revalidate authorization and content after preflight", tests.testAutomaticQuestionReplyRevalidatesAfterPreparation),
            ("automatic question response failures, durable audit and restart protection", tests.testAutomaticQuestionReplyFailuresAreNotRetried),
            ("editing and individual cancellation stop automation across polling, resume and restart", tests.testQuestionDraftAndIndividualCancellationPersist),
            ("restored history, duplicate titles, unquoted answers and root changes remain manual", tests.testQuestionHistoryGuardsAutomaticResponses),
            ("fresh transport history blocks automatic answers while preserving manual responses", tests.testAutomaticReplyHonorsFreshTransportHistory),
            ("Codex async queue and exact, partial, ambiguous answer resolution", tests.testCodexQuestionResolution),
            ("Codex queued questions: exact structured reply identity", tests.testCodexStructuredQuestionRepliesMatchExactItemAndIndex),
            ("Codex queued questions: bound server history without rollout", tests.testCodexServerBoundQuestionsWithoutOpenRollout),
            ("Process identity: cached start-time formatting preserves concurrent results", tests.testTTYProcessStartFormattingIsStableUnderConcurrentReads),
            ("Codex root-thread binding excludes children and ambiguous processes", tests.testCodexThreadBinding),
            ("concurrent question alerts, errors, dismissal and session exit", tests.testConcurrentCodexAttentionAndDismissal),
            ("varied yes/no questions, exact labels and ambiguous alternatives", tests.testYesNoConfirmationSelection),
            ("confirmation menus never choose tasks or multiple answers", tests.testConfirmationMenusNeverChooseTasksOrMultipleAnswers),
            ("Permission cleanup: ASCII identities preserve hint order and task rejection", tests.testPermissionCleanupKeepsASCIIHintOrderAndTaskRejection),
            ("Allow, Deny and Don't allow labels preserve one-time scope", tests.testAllowConfirmationLabels),
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
            ("notification opens exact live session only", tests.testAttentionTarget),
            ("three-choice question survives Claude reminders and notifies once", tests.testThreeChoiceAttention),
            ("durable audit history, filtering, pagination and result updates", tests.testAuditHistoryQueries),
            ("full hook request and project survive session exit and restart", tests.testAuditContextSurvivesSession),
            ("reveal exact Terminal tab, minimized restoration and closed-tab isolation", tests.testTerminalRevealTarget),
            ("iTerm2, Orca, multiplexers, forks and nested PTYs identify their host", tests.testTerminalHostIdentification),
            ("iTerm2 visible rows, foreground job check, reveal and permission errors", tests.testITermScriptingContract),
            ("Codex sub-agent approvals in the parent overlay and clipped long requests", tests.testCodexSubAgentAndClippedApprovals),
            ("long commands and canonical Unicode dialogs", tests.testLongPermissionAndCanonicalUnicode),
            ("interactive question menus versus approval and stale text", tests.testQuestionMenus),
            ("CLI errors: all error kinds, unknown provider wording and history keep retrying beyond backoff", tests.testAllCLIErrorCellsKeepRetrying),
            ("CLI errors: transport recovery preserves the current question until later user progress", tests.testTransportRetryPreservesCurrentQuestion),
            ("CLI errors: definite non-writes retry beyond three failures and recover when input returns", tests.testRecoveryKeepsRetryingDefiniteNonWrites),
            ("CLI errors: proven rejected writes retry while ambiguous delivery remains single-use", tests.testRecoveryRetriesRejectedWritesButPreservesUnknownResults),
            ("CLI errors: a new failed root turn retries an identical viewport across app restart", tests.testIdenticalErrorUsesNewFailedRootTurnAcrossRestart),
            ("CLI errors: authoritative new failure resolves an uncertain previous delivery without replay", tests.testUncertainRecoveryContinuesAfterAuthoritativeNewFailure),
            ("CLI interruption detection rejects drafts, busy frames and historical errors", tests.testSessionInterruptionDetection),
            ("CLI recovery recognizes varied errors and preserves explicit account failures", tests.testRecoverableErrorVariantsAndAccountFailurePrecedence),
            ("CLI failures notify once and remain visible after process exit", tests.testInterruptionNotificationKeepsEndedFailureAndDeduplicates),
            ("Codex and Claude recover in the original CLI without replaying uncertain writes after restart", tests.testTransientRecoverySupportsClaudeAndPersistsUncertainWrites),
            ("Exited CLI recovery requires exact conversation, idle shell and original process identity", tests.testExitedRecoveryRequiresExactConversationAndIdleOriginalShell),
            ("Exited Claude resumes in its original shell and app restart cannot replay the launch", tests.testExitedRecoveryRestoresExactConversationAndNeverReplays),
            ("CLI errors: exited recovery retries past three definite non-writes in the original shell", tests.testExitedRecoveryRetriesPastThreeNonWrites),
            ("Claude StopFailure migration preserves enabled hooks and user removals", tests.testStopFailureHookMigrationPreservesUserHooks),
            ("Claude StopFailure reports an API failure and clears only after real user progress", tests.testClaudeStopFailurePublishesAnErrorAndClearsOnUserProgress),
            ("Claude question content and permission screen fallback", tests.testHookQuestionAndScreenFallback),
            ("permission dialogs and false positives", tests.testCompletePromptAndFalsePositives),
            ("Claude dialog selection", tests.testClaudePromptAndDifferentSelection),
            ("process identity and child filtering", tests.testDiscoveryKeepsIdentityAndFiltersSubprocesses),
            ("only Claude/Codex terminals enter the inventory", tests.testOrdinaryTerminalsAreExcluded),
            ("agent exit excludes ordinary shells and idle counts", tests.testAgentExitDoesNotExposeShellOrCountItAsIdle),
            ("ready composer versus quiet work and unknown screens", tests.testActivityNeedsAReadyComposerNotSilence),
            ("activity hints preserve Unicode words and real drafts", tests.testActivityHintsPreserveUnicodeWordsAndRealDrafts),
            ("stable idle confirmation and new screen generations", tests.testIdleConfirmationAndGenerationChange),
            ("idle duration, work transition, connection loss", tests.testEngineClearsIdleOnWorkAndDisconnection),
            ("Claude idle events and new input", tests.testHookIdleResetsOnNewInput),
            ("early hook preserves enrollment after restart", tests.testHookBeforeDiscoveryRestoresEnrollment),
            ("enrollment, pause, duplicate requests, isolation", tests.testHookRequiresEnrollmentHonorsPauseAndDoesNotReplay),
            ("discovery capability and process exit", tests.testDiscoveryDoesNotClaimControlAndEndsMissingSessions),
            ("hook installation preserves settings", tests.testHookInstallPreservesOtherSettingsAndIsIdempotent),
            ("Hook relocation: same home, existing or missing build, backup and idempotence",tests.testHookRelocationMovesSameHomeWithBackupAndIdempotence),
            ("Hook relocation: foreign, disabled and noncanonical commands remain untouched",tests.testHookRelocationKeepsForeignDisabledAndNoncanonicalCommands),
            ("Hook relocation: startup scopes repair to engine home",tests.testHookRelocationStartupScopesToEngineHome),
            ("SQLite persistence", tests.testAuditPersistsSettingsAndEvents),
            ("disconnected controls and reveal capability", tests.testDisconnectedEnrollmentCanBeDisabled)
        ]
#if DEBUG
        cases.insert(contentsOf: [
            ("Session profiles: compatible newer server preserves the bundled client",tests.testProfileLaunchKeepsBundledClientWithCompatibleNewerServer),
            ("Session profiles: matching bundled server preserves auto-start settings",tests.testProfileLaunchUsesMatchingBundledServerWithoutChangingAutoStart),
            ("Screen parsing: ordinary scrollback stays on its bounded suffix", tests.testOrdinaryScrollbackDoesNotMaterializeTrimmedRows),
            ("Screen parsing: source byte counting reuses bridged line normalization", tests.testScreenAnalysisPreservesSourceUTF8ByteCountAcrossLinePreparation),
            ("Screen parsing: Cocoa UTF-16 chunk boundaries preserve rows and source budgets", tests.testCocoaLinePreparationPreservesUTF16ChunkBoundariesAndSourceBudget),
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
