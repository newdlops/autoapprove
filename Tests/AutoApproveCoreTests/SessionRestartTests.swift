import Foundation
import AutoApproveCore
import TerminalInputSupport

private final class RestartTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private var screens: [String: String] = [:]
    private var inputs: [String] = []
    private var commands: [String] = []
    private var stage = 0
    let stages: [[ProcessRecord]]
    var onExit: (() -> Void)?
    init(stages: [[ProcessRecord]]) { self.stages = stages }
    var records: [ProcessRecord] { lock.lock(); defer { lock.unlock() }; return stages[stage] }
    var typed: [String] { lock.lock(); defer { lock.unlock() }; return inputs }
    var launched: [String] { lock.lock(); defer { lock.unlock() }; return commands }
    func screen(_ tty: String) -> String { lock.lock(); defer { lock.unlock() }; return screens[tty] ?? "" }
    func show(_ text: String, on tty: String) { lock.lock(); defer { lock.unlock() }; screens[tty] = text }
    func send(_ target: ScreenTarget, _ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        inputs.append(input.bytes)
        return .sent
    }
    private var resumeLines: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return resumeLines }
    /// A line typed into the running CLI; Claude starts working on it.
    func type(_ text: String) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        resumeLines.append(text); claudeStatus = "busy"
        return .sent
    }
    private var signals = 0, claudeStatus = "idle"
    var terminated: Int { lock.lock(); defer { lock.unlock() }; return signals }
    var status: String {
        get { lock.lock(); defer { lock.unlock() }; return claudeStatus }
        set { lock.lock(); defer { lock.unlock() }; claudeStatus = newValue }
    }
    /// The CLI ends on a signal and its shell prompt returns; nothing is typed into the terminal.
    func terminate(_ process: ProcessRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        signals += 1; stage = 1; screens["/dev/" + process.tty] = "Resume this session later.\n❯ "
        return true
    }
    private var rejections = 1
    func restart(_ target: ScreenTarget, expected: String, command: String) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        guard screens[target.tty] == expected else { return .screenChanged }
        // Right after the CLI exits its helper processes can still be listed; the first try is refused.
        if rejections > 0 { rejections -= 1; return .agentMissing }
        commands.append(command); stage = 2; screens[target.tty] = "❯ Try “다음 작업”\n? for shortcuts"
        return .sent
    }
}

extension ApprovalTests {
    @MainActor func testExplicitCodexLoginRequestsStopsBeforeWaitingForAnyTurn() async throws {
        let target = CodexAccountTransitionTarget(home: "/fixture", executable: "/fixture/codex")
        var threads = ["a", "b"].map { CodexAccountTransitionThread(id: $0, turnID: "turn-" + $0, active: true) }
        var stopped: [String] = []
        var restarts = 0
        var services = CodexAccountTransitionServices(
            observe: { _ in .init(savedAccount: "new", serverAccount: "old", serverID: "server", threads: threads) },
            interrupt: { _, _, id, _ in
                stopped.append(id)
                if id == "a" {
                    for _ in 0..<50 {
                        if stopped.contains("b") { return }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    throw AppError.message("The second interrupt waited for the first")
                }
            },
            restart: { _, _ in restarts += 1 },
            verify: { _, _, _ in 0 })
        var idleChecks = 0
        services.observeForIdleCheck = { _ in
            idleChecks += 1
            return .init(savedAccount: "old", serverAccount: "old", serverID: "server", threads: [])
        }
        let coordinator = CodexAccountTransitionCoordinator(target: target, services: services, save: { _ in })
        let start = Date()
        await coordinator.check(now: start)
        try expectEqual(coordinator.state.phase, .ready)
        try expectEqual(idleChecks, 1)
        await coordinator.check(now: start, loginRequestID: UUID().uuidString)
        try expect(stopped.isEmpty, "The first check must publish the input hold")
        await coordinator.check(now: start.addingTimeInterval(1))
        try expectEqual(stopped.sorted(), ["a", "b"])
        try expectEqual(restarts, 0)
        await coordinator.check(now: start.addingTimeInterval(2))
        try expectEqual(stopped.sorted(), ["a", "b"], "The same interrupt must not be sent twice")
        threads[0].active = false
        threads[1].active = false
        await coordinator.check(now: start.addingTimeInterval(3))
        try expectEqual(restarts, 1)
        try expectEqual(idleChecks, 1)
        var completed = coordinator.state
        completed.phase = .complete
        let restored = CodexAccountTransitionCoordinator(target: target, state: completed, services: services, save: { _ in })
        await restored.check(loginRequestID: completed.loginRequestID, preStoppedGoals: threads)
        try expectEqual(restored.state.phase, .complete)
        try expectEqual(idleChecks, 2)
        await restored.check(loginRequestID: UUID().uuidString)
        try expectEqual(restored.state.phase, .stopping)
        try expectEqual(idleChecks, 2)
    }

    func testSessionRestartCommandKeepsKnownOptionsOnly() throws {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for agent in [AgentKind.codex, .claude, .agy] {
            let link = root.appendingPathComponent(agent.rawValue)
            for version in ["old", "new"] {
                let binary = root.appendingPathComponent(agent.rawValue + "-" + version)
                try Data(("#!/bin/sh\nprintf '%s\\n' " + version + " \"$@\"\n").utf8).write(to: binary)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                if version == "new" { try FileManager.default.removeItem(at: link) }
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
                let selected = SessionRestartCommand.installedLauncher(agent: agent, path: ".:" + root.path,
                    runningExecutable: root.appendingPathComponent(agent.rawValue + "-old").path, userHome: nil)
                try expectEqual(selected, link.path)
                let plan = try SessionRestartCommand.plan(agent: agent, executable: selected ?? "", argv: [], conversationID: id)
                let result = try CommandRunner.run(plan.arguments[0], Array(plan.arguments.dropFirst()))
                try expectEqual(result.output.split(separator: "\n").map(String.init), [version] + Array(plan.arguments.dropFirst()))
                try expectEqual(plan.arguments.last, id.lowercased())
            }
        }
        let package = root.appendingPathComponent("packages/app-server-daemon")
        let current = package.appendingPathComponent("current/bin")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        let binary = current.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(atPath: binary.path, withDestinationPath: "/bin/echo")
        let stale = package.appendingPathComponent("releases/old/bin/codex")
        for path in [nil, stale.deletingLastPathComponent().path] {
            try expectEqual(SessionRestartCommand.installedLauncher(agent: .codex, path: path,
                runningExecutable: stale.path, userHome: nil), binary.path)
        }
        let claude = try SessionRestartCommand.plan(agent: .claude, executable: "/opt/claude",
            argv: ["--model", "opus", "--add-dir", "/a", "/b", "--dangerously-skip-permissions", "-c", "--resume", "old", "고쳐줘"], conversationID: id)
        try expectEqual(claude.arguments, ["/opt/claude", "--model", "opus", "--add-dir", "/a", "/b", "--dangerously-skip-permissions", "--resume", id.lowercased()])
        try expectEqual(claude.dropped, ["-c", "--resume", "old", "고쳐줘"], "Prompts and other conversation selectors are not reused")
        try expect(claude.command.contains("'--resume' '\(id.lowercased())'") || claude.command.contains("--resume \(id.lowercased())"))
        let codex = try SessionRestartCommand.plan(agent: .codex, executable: "/opt/codex",
            argv: ["-c", "model=\"o3\"", "resume", "--last", "-p", "work", "-i", "a.png", "b.png", "--search", "다음 작업"], conversationID: id)
        try expectEqual(codex.arguments, ["/opt/codex", "resume", "-c", "model=\"o3\"", "-p", "work", "--search", id.lowercased()])
        try expectEqual(codex.dropped, ["--last", "-i", "a.png", "b.png", "다음 작업"])
        try expectEqual(try SessionRestartCommand.plan(agent: .codex, executable: "/opt/codex", argv: ["--model=o3"], conversationID: id).arguments,
                        ["/opt/codex", "resume", "--model=o3", id.lowercased()])
        let agy = try SessionRestartCommand.plan(agent: .agy, executable: "/opt/agy", argv: ["--model=m1", "--effort", "high", "--sandbox", "--conversation", UUID().uuidString], conversationID: id)
        try expectEqual(agy.arguments, ["/opt/agy", "--model", "m1", "--effort", "high", "--sandbox", "--conversation", id.lowercased()])
        for (agent, argv) in [(AgentKind.agy, ["--model"]), (.agy, ["--conversation", "invalid"]), (.claude, ["--unknown-option", "x"]), (.claude, ["-p", "요약"]), (.codex, ["exec", "작업"]), (.codex, ["--mystery"])] {
            try expectThrows(try SessionRestartCommand.plan(agent: agent, executable: "/opt/cli", argv: argv, conversationID: id))
        }
        try expectThrows(try SessionRestartCommand.plan(agent: .claude, executable: "/opt/claude", argv: [], conversationID: "not-a-uuid"))
        try expectThrows(try SessionRestartCommand.plan(agent: .claude, executable: "claude", argv: [], conversationID: id))
    }

    func testClaudeRegistryKeepsConversationForUnknownStatus() throws {
        // Claude reports statuses this app does not know, such as "shell". The conversation must still be read,
        // or saving a session profile and restarting the session both report that no conversation was found.
        let process = ProcessDiscovery.parse("6244 1 ttys006 6244 6244 Tue Nov 10 20:25:14 2026 /fixture/claude")[0]
        let conversation = "046adb89-3665-413a-996a-dc90a7a65862"
        func registration(_ status: String) -> ClaudeSessionRegistration? {
            let json: JSONObject = ["pid": 6244, "pidDomain": "darwin", "procStart": "Tue Nov 10 20:25:14 2026", "kind": "interactive",
                                    "sessionId": conversation, "status": status, "statusUpdatedAt": Date().timeIntervalSince1970 * 1000]
            return ClaudeSessionRegistry.decode(try! JSONSerialization.data(withJSONObject: json), process: process, processTimeZone: TimeZone(secondsFromGMT: 0)!)
        }
        let shell = try unwrapRestart(registration("shell"))
        try expectEqual(shell.conversationID, conversation)
        try expect(shell.activity == nil, "An unknown status is not reported as activity")
        let idle = try unwrapRestart(registration("idle"))
        try expectEqual(idle.conversationID, conversation); try expectEqual(idle.activity?.status, "idle")
    }

    func testProcessArgumentsParseOnlyArgv() throws {
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        for part in ["/opt/claude", "", "", "/opt/claude", "--model", "opus", "HOME=/Users/fixture", "TERM=xterm", ""] {
            bytes += Array(part.utf8) + [0]
        }
        try expectEqual(ProcessEnvironment.parseArguments(bytes), ["/opt/claude", "--model", "opus"])
        try expectEqual(ProcessEnvironment.parseArguments([1, 2]), [])
    }

    @MainActor func testSessionRestartExitsAndReopensTheSameConversation() async throws {
        try await exerciseRestart(recoverMCP: false)
    }

    @MainActor func testMCPRecoveryRequiresInitializationFromReopenedSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = root.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        test "$1" = mcp && test "$PWD" -ef "$CLAUDE_CONFIG_DIR" || exit 2
        case "$2" in
        get) test -e registered && exit 0
             echo 'No MCP server named "autoapprove".' >&2
             exit 1 ;;
        add) test "$3 $4 $5 $6 $7 $8 $9" = "--transport stdio --scope user autoapprove -- /bin/echo" || exit 3
             echo added >> registered ;;
        esac
        """
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        for _ in 0..<2 {
            try ClaudeMCPRegistration.repair(executable: fixture.path, cwd: root.path, environment: ["CLAUDE_CONFIG_DIR":root.path], relay: "/bin/echo")
        }
        try expectEqual(try String(contentsOf: root.appendingPathComponent("registered"), encoding: .utf8), "added\n")
        try await exerciseRestart(recoverMCP: true)
    }

    @MainActor private func exerciseRestart(recoverMCP: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-restart-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = "Wed Oct 28 12:00:00 2026"
        func records(_ text: String) -> [ProcessRecord] { ProcessDiscovery.parse(text) }
        let running = records("""
        100600 1 ttys060 100600 100601 \(started) /bin/zsh
        100601 100600 ttys060 100601 100601 \(started) /fixture/claude
        """)
        let exited = records("100600 1 ttys060 100600 100600 \(started) /bin/zsh")
        let reopened = records("""
        100600 1 ttys060 100600 100602 \(started) /bin/zsh
        100602 100600 ttys060 100602 100602 \(started) /fixture/claude
        """)
        let terminal = RestartTerminal(stages: [running, exited, reopened])
        let tty = "/dev/ttys060"
        terminal.show("❯ Try “다음 작업”\n? for shortcuts", on: tty)
        var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: terminal.screen($0.tty)) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil },
            restart: { target, expected, command in terminal.restart(target, expected: expected, command: command) },
            input: { target, _, _, input in terminal.send(target, input) })
        adapter.typeLine = { _, text in terminal.type(text) }
        let conversation = UUID().uuidString.lowercased()
        let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { rows in
            rows.filter { $0.pid == 100601 || $0.pid == 100602 }.map { .init(processID: $0.key, kind: "interactive", sessionID: conversation, status: terminal.status) }
        }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: registry, processReader: { terminal.records },
                                        screenAdapters: [.iterm: adapter], singleProcessReader: { pid in terminal.records.filter { $0.pid == pid } })
        defer { engine.stop() }
        let sessionDirectory = ProcessDiscovery.sessions(running).first { $0.agent == .claude }!.cwd
        engine.repairClaudeMCPRegistration = { executable, cwd, _ in
            try expectEqual(executable, "/fixture/claude")
            try expectEqual(cwd, sessionDirectory)
        }
        engine.processTerminator = { terminal.terminate($0) }
        engine.restartResumeSettle = 0.5
        engine.processArgumentsReader = { record in record.pid == 100601 ? ["/fixture/claude", "--model", "opus", "처음 프롬프트"] : nil }
        var session = ProcessDiscovery.sessions(running).first { $0.agent == .claude }!
        session.terminal = .iterm; session.channel = .itermScreen; session.providerID = conversation
        engine.updateDiscovery([session], records: running); await engine.connectScreenHost(.iterm)
        try engine.setAutomatic(session.id, enabled: true)
        func phase() -> SessionPhase? { engine.snapshot.sessions.first { $0.id == session.id }?.phase }
        _ = try await waitForRestart(10) { await engine.refreshScreens(); return phase() == .idle }

        terminal.status = "busy"
        if recoverMCP {
            let result = engine.recoverMCPConnections([session.id, session.id, "missing"], restartCLI: false)
            try expectEqual(result.items.map(\.id), [session.id])
        } else { engine.restartSessions([session.id]) }
        let launched = try await waitForRestart(10) { !terminal.launched.isEmpty }
        try expect(launched, "The resume command must be typed into the original shell: \(engine.snapshot.sessionRestart?.items.first?.message ?? "")")
        try expectEqual(terminal.terminated, 1, "The CLI is ended with one signal")
        try expectEqual(terminal.typed, ["\u{1b}"], "Send exactly one Escape before restarting")
        try expectEqual(terminal.launched.count, 1)
        let command = terminal.launched[0]
        try expect(command.hasPrefix("env 'AUTOAPPROVE_CLAUDE_PROMPT_BRIDGE="))
        try expect(command.contains(["/fixture/claude", "--model", "opus", "--resume", conversation, "--plugin-dir"].map(HookInstaller.quote).joined(separator: " ")))
        terminal.status = "idle"
        var next = ProcessDiscovery.sessions(reopened).first { $0.agent == .claude }!
        next.terminal = .iterm; next.channel = .itermScreen; next.providerID = conversation
        engine.updateDiscovery([next], records: reopened)
        if recoverMCP {
            let owner = UUID().uuidString
            _ = try await engine.mcpAction(["tool": "connection_initialized", "owner": owner, "parentPID": 100601])
            try expect(engine.snapshot.sessionRestart?.items.first?.phase != .done)
            _ = try await engine.mcpAction(["tool": "connection_initialized", "owner": owner, "parentPID": 100602])
        }
        let finished = try await waitForRestart(10) { engine.snapshot.sessionRestart?.items.first?.phase == .done }
        try expect(finished, engine.snapshot.sessionRestart?.items.first?.message ?? "no progress")
        let item = try unwrapRestart(engine.snapshot.sessionRestart?.items.first)
        try expectEqual(item.newSessionID, next.id)
        if recoverMCP {
            try expectEqual(terminal.lines, [])
            try expect(item.isMCPRecovery && item.message.contains("MCP 초기화"))
        } else {
            try expect(item.message.contains("처음 프롬프트"), "Dropped arguments are reported")
            try expectEqual(terminal.lines, [SessionRestartCommand.resumePrompt], "The restarted session is told once to go on with its work")
            try expect(item.message.contains("이어가도록 입력했습니다"), item.message)
        }
        try expectEqual(engine.snapshot.sessions.first { $0.id == next.id }?.automatic, true, "Automatic approval carries over")
        engine.dismissSessionRestarts()
        try expect(engine.snapshot.sessionRestart == nil)
    }

    @MainActor func testMultipleRestartsLaunchIndependentShells() async throws {
        try await verifyIndependentRestarts(host:.iterm)
    }

    @MainActor func testTerminalRestartsDoNotHoldOtherShells() async throws {
        try await verifyIndependentRestarts(host:.terminal)
    }

    @MainActor private func verifyIndependentRestarts(host:ScreenHost) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let terminals = [0, 1].map { index -> RestartTerminal in
            let tty = "ttys42" + String(index), shell = 101420 + index * 10, agent = shell + 1
            let start = "Wed Oct 28 12:00:00 2026"
            let shellRow = "\(shell) 1 \(tty) \(shell) "
            let running = ProcessDiscovery.parse(shellRow + "\(agent) \(start) /bin/zsh\n\(agent) \(shell) \(tty) \(agent) \(agent) \(start) /fixture/claude")
            let exited = ProcessDiscovery.parse(shellRow + "\(shell) \(start) /bin/zsh")
            return RestartTerminal(stages: [running, exited, exited])
        }
        let records = terminals.flatMap(\.records)
        let sessions = ProcessDiscovery.sessions(records).filter { $0.agent == .claude }.map { value in
            var session = value
            session.providerID = UUID().uuidString
            session.terminal = host == .terminal ? .terminal : .iterm
            return session
        }
        let adapter = ScreenHostAdapter(screens: { targets in
            TerminalSnapshot(screens: targets.map { target in
                let t = terminals[target.tty.hasSuffix("0") ? 0 : 1]
                return TerminalScreen(tty: target.tty, contents: t.screen(target.tty))
            })
        }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, restart: { target, expected, command in
            guard terminals.allSatisfy({ $0.terminated == 1 }) else { return .agentMissing }
            return terminals[target.tty.hasSuffix("0") ? 0 : 1].restart(target, expected: expected, command: command)
        }, input: { target,_,_,input in terminals[target.tty.hasSuffix("0") ? 0 : 1].send(target, input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { terminals.flatMap(\.records) }, screenAdapters: [host: adapter])
        defer { engine.stop() }
        engine.processArgumentsReader = { _ in ["/fixture/claude"] }
        engine.processTerminator = { record in
            let i = record.tty.hasSuffix("0") ? 0 : 1
            if terminals[i].typed != ["\u{1b}"] { return false }
            return terminals[i].terminate(record)
        }
        engine.updateDiscovery(sessions, records: records)
        await engine.connectScreenHost(host)
        engine.restartSessions(sessions.map(\.id), resume: false)
        try expect(try await waitForRestart(12) { terminals.allSatisfy { $0.launched.count == 1 } })
        for (i, terminal) in terminals.enumerated() {
            let session = sessions.first { $0.tty.hasSuffix(String(i)) }!
            try expectEqual(terminal.typed, ["\u{1b}"])
            try expectEqual(terminal.terminated, 1)
            try expect(terminal.launched[0].lowercased().contains(session.providerID!.lowercased()))
        }
    }

    @MainActor func testSessionRestartLeavesShelllessCLIUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-restart-shellless-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A CLI started with `exec` has login as its parent. Its tab cannot run anything after the CLI exits,
        // so the session is not exited and nothing is typed or opened.
        let records = ProcessDiscovery.parse("""
        100700 1 ttys070 100700 100701 Wed Oct 28 12:00:00 2026 /usr/bin/login
        100701 100700 ttys070 100701 100701 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        let typed = RestartTerminal(stages: [records])
        typed.show("❯ Try “다음 작업”\n? for shortcuts", on: "/dev/ttys070")
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: typed.screen($0.tty)) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil },
            restart: { target, expected, command in typed.restart(target, expected: expected, command: command) },
            input: { target, _, _, input in typed.send(target, input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.iterm: adapter])
        defer { engine.stop() }
        var session = ProcessDiscovery.sessions(records).first { $0.agent == .claude }!
        session.terminal = .iterm; session.channel = .itermScreen; session.providerID = UUID().uuidString.lowercased(); session.phase = .idle
        engine.updateDiscovery([session], records: records); await engine.connectScreenHost(.iterm)
        engine.processTerminator = { typed.terminate($0) }
        engine.restartSessions([session.id])
        let failed = try await waitForRestart(10) { engine.snapshot.sessionRestart?.items.first?.phase == .failed }
        try expect(failed, engine.snapshot.sessionRestart?.items.first?.message ?? "no progress")
        try expect(engine.snapshot.sessionRestart?.items.first?.message.contains("셸 없이 실행된 세션") == true)
        try expect(typed.typed.isEmpty && typed.launched.isEmpty && typed.terminated == 0, "A session that cannot restart in its own tab is never exited")
    }

    @MainActor func testSessionRestartRefusesUnsupportedTerminals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-restart-tmux-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("100610 1 ttys061 100610 100610 Wed Oct 28 12:00:00 2026 /fixture/codex")
        var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .tmux; session.phase = .idle
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records)
        engine.restartSessions([session.id])
        let failed = try await waitForRestart(5) { engine.snapshot.sessionRestart?.items.first?.phase == .failed }
        try expect(failed && engine.snapshot.sessionRestart?.items.first?.message.contains("지원하지 않습니다") == true)
    }
}

private func unwrapRestart<T>(_ value: T?) throws -> T {
    guard let value else { throw AppError.message("Expected a session restart value") }
    return value
}

@MainActor private func waitForRestart(_ seconds: Double, _ condition: () async -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}
