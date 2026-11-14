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
        if input.bytes.contains("/exit") { stage = 1; screens[target.tty] = "Resume this session later.\nuser@mac project %" }
        return .sent
    }
    func restart(_ target: ScreenTarget, expected: String, command: String) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        guard screens[target.tty] == expected else { return .screenChanged }
        commands.append(command); stage = 2; screens[target.tty] = "❯ Try “다음 작업”\n? for shortcuts"
        return .sent
    }
}

/// A Terminal window whose CLI replaced its shell: restarting opens a new tab in the same window.
private final class ShelllessTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private var screens: [String: String] = [:]
    private var stage = 0
    private var commands: [String] = []
    private var opened = false
    let stages: [[ProcessRecord]]
    init(stages: [[ProcessRecord]]) { self.stages = stages }
    var records: [ProcessRecord] { lock.lock(); defer { lock.unlock() }; return stages[stage] }
    var launched: [String] { lock.lock(); defer { lock.unlock() }; return commands }
    var tabOpened: Bool { lock.lock(); defer { lock.unlock() }; return opened }
    func screen(_ tty: String) -> String { lock.lock(); defer { lock.unlock() }; return screens[tty] ?? "" }
    func show(_ text: String, on tty: String) { lock.lock(); defer { lock.unlock() }; screens[tty] = text }
    func openTab() -> ProcessRecord {
        lock.lock(); defer { lock.unlock() }
        opened = true; stage = 1; screens["/dev/ttys071"] = "user@mac ~ %"
        return stages[1].first { $0.tty == "ttys071" && SessionExitRecovery.isShell($0) }!
    }
    func send(_ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        if input.bytes.contains("/exit") { stage = 2; screens["/dev/ttys070"] = "[프로세스 완료됨]" }
        return .sent
    }
    func restart(_ target: ScreenTarget, expected: String, command: String) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        guard target.tty == "/dev/ttys071", screens[target.tty] == expected else { return .screenChanged }
        commands.append(command); stage = 3; screens[target.tty] = "❯ Try “다음 작업”\n? for shortcuts"
        return .sent
    }
}

extension ApprovalTests {
    func testSessionRestartCommandKeepsKnownOptionsOnly() throws {
        let id = UUID().uuidString
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
        for (agent, argv) in [(AgentKind.claude, ["--unknown-option", "x"]), (.claude, ["-p", "요약"]), (.codex, ["exec", "작업"]), (.codex, ["--mystery"])] {
            try expectThrows(try SessionRestartCommand.plan(agent: agent, executable: "/opt/cli", argv: argv, conversationID: id))
        }
        try expectThrows(try SessionRestartCommand.plan(agent: .claude, executable: "/opt/claude", argv: [], conversationID: "not-a-uuid"))
        try expectThrows(try SessionRestartCommand.plan(agent: .claude, executable: "claude", argv: [], conversationID: id))
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
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: terminal.screen($0.tty)) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil },
            restart: { target, expected, command in terminal.restart(target, expected: expected, command: command) },
            input: { target, _, _, input in terminal.send(target, input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { terminal.records }, screenAdapters: [.iterm: adapter])
        defer { engine.stop() }
        let conversation = UUID().uuidString.lowercased()
        engine.processArgumentsReader = { record in record.pid == 100601 ? ["/fixture/claude", "--model", "opus", "처음 프롬프트"] : nil }
        var session = ProcessDiscovery.sessions(running).first { $0.agent == .claude }!
        session.terminal = .iterm; session.channel = .itermScreen; session.providerID = conversation
        engine.updateDiscovery([session], records: running); await engine.connectScreenHost(.iterm)
        try engine.setAutomatic(session.id, enabled: true)
        func phase() -> SessionPhase? { engine.snapshot.sessions.first { $0.id == session.id }?.phase }
        _ = try await waitForRestart(10) { await engine.refreshScreens(); return phase() == .idle }

        engine.restartSessions([session.id])
        let launched = try await waitForRestart(30) { !terminal.launched.isEmpty }
        try expect(launched, "The resume command must be typed into the original shell: \(engine.snapshot.sessionRestart?.items.first?.message ?? "")")
        try expect(terminal.typed.contains { $0.contains("/exit") }, "The CLI must be asked to exit first")
        try expectEqual(terminal.launched, [["/fixture/claude", "--model", "opus", "--resume", conversation].map(HookInstaller.quote).joined(separator: " ")])
        // The app's discovery loop reports the new CLI.
        var next = ProcessDiscovery.sessions(reopened).first { $0.agent == .claude }!
        next.terminal = .iterm; next.channel = .itermScreen; next.providerID = conversation
        engine.updateDiscovery([next], records: reopened)
        let finished = try await waitForRestart(10) { engine.snapshot.sessionRestart?.items.first?.phase == .done }
        try expect(finished, engine.snapshot.sessionRestart?.items.first?.message ?? "no progress")
        let item = try unwrapRestart(engine.snapshot.sessionRestart?.items.first)
        try expectEqual(item.newSessionID, next.id)
        try expect(item.message.contains("처음 프롬프트"), "Dropped arguments are reported")
        try expectEqual(engine.snapshot.sessions.first { $0.id == next.id }?.automatic, true, "Automatic approval carries over")
        engine.dismissSessionRestarts()
        try expect(engine.snapshot.sessionRestart == nil)
    }

    @MainActor func testSessionRestartOpensNewTabForShelllessCLI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-restart-tab-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = "Wed Oct 28 12:00:00 2026"
        func records(_ text: String) -> [ProcessRecord] { ProcessDiscovery.parse(text) }
        // Restored profiles run `exec claude`, so login is the CLI's parent and no shell remains.
        let running = records("""
        100700 1 ttys070 100700 100701 \(started) /usr/bin/login
        100701 100700 ttys070 100701 100701 \(started) claude
        """)
        let tab = records("""
        100700 1 ttys070 100700 100701 \(started) /usr/bin/login
        100701 100700 ttys070 100701 100701 \(started) claude
        100710 1 ttys071 100710 100711 \(started) /usr/bin/login
        100711 100710 ttys071 100711 100711 \(started) -zsh
        """)
        let exited = records("""
        100710 1 ttys071 100710 100711 \(started) /usr/bin/login
        100711 100710 ttys071 100711 100711 \(started) -zsh
        """)
        let reopened = records("""
        100710 1 ttys071 100710 100720 \(started) /usr/bin/login
        100711 100710 ttys071 100711 100720 \(started) -zsh
        100720 100711 ttys071 100720 100720 \(started) claude
        """)
        let terminal = ShelllessTerminal(stages: [running, tab, exited, reopened])
        terminal.show("❯ Try “다음 작업”\n? for shortcuts", on: "/dev/ttys070")
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: terminal.screen($0.tty)) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil },
            restart: { target, expected, command in terminal.restart(target, expected: expected, command: command) },
            input: { _, _, _, input in terminal.send(input) },
            replacementShell: { _ in terminal.openTab() }, replacementShellValid: { _, shell in shell.tty == "ttys071" })
        let conversation = UUID().uuidString.lowercased()
        // The conversation comes only from Claude's session registry.
        let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { rows in
            rows.filter { $0.pid == 100701 }.map { .init(processID: $0.key, kind: "interactive", activity: .init(providerID: conversation, status: "idle", changedAt: Date())) }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let identity = TTYInputIdentity(pid: 100701, processGroup: 100701, uid: getuid(), effectiveUID: geteuid(), device: 70,
            startSeconds: UInt64(formatter.date(from: started)!.timeIntervalSince1970), startMicroseconds: 1)
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: registry, processReader: { terminal.records },
                                        screenAdapters: [.terminal: adapter], terminalInputAvailable: { true },
                                        terminalInputIdentity: { pid in pid == identity.pid ? identity : nil })
        defer { engine.stop() }
        engine.processArgumentsReader = { record in record.pid == 100701 ? ["claude", "--resume", "11111111-1111-1111-1111-111111111111"] : nil }
        engine.processPathReader = { record in record.pid == 100701 ? "/Users/fixture/.local/bin/claude" : nil }
        var session = ProcessDiscovery.sessions(running).first { $0.agent == .claude }!
        session.terminal = .terminal; session.channel = .terminalScreen; session.cwd = "/tmp/복원 프로젝트"
        engine.updateDiscovery([session], records: running); await engine.connectScreenHost(.terminal)
        try engine.setAutomatic(session.id, enabled: true)
        _ = try await waitForRestart(10) { await engine.refreshScreens(); return engine.snapshot.sessions.first { $0.id == session.id }?.phase == .idle }

        engine.restartSessions([session.id])
        let launched = try await waitForRestart(45) { !terminal.launched.isEmpty }
        try expect(launched, "The resume command must reach the new tab: \(engine.snapshot.sessionRestart?.items.first?.message ?? "") stage records \(terminal.records.map(\.pid))")
        try expect(terminal.tabOpened, "A tab must be opened before the CLI exits")
        try expectEqual(terminal.launched, ["cd -- '/tmp/복원 프로젝트' && '/Users/fixture/.local/bin/claude' '--resume' '\(conversation)'"],
                        "The new tab returns to the CLI's folder and reopens the current conversation, not the one in the old arguments")
        var next = ProcessDiscovery.sessions(reopened).first { $0.agent == .claude }!
        next.terminal = .terminal; next.channel = .terminalScreen
        engine.updateDiscovery([next], records: reopened)
        let finished = try await waitForRestart(10) { engine.snapshot.sessionRestart?.items.first?.phase == .done }
        try expect(finished, engine.snapshot.sessionRestart?.items.first?.message ?? "no progress")
        try expect(engine.snapshot.sessionRestart?.items.first?.message.contains("새 탭") == true)
        try expectEqual(engine.snapshot.sessions.first { $0.id == next.id }?.automatic, true)
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
