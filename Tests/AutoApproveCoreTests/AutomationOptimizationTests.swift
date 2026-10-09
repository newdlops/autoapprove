import Foundation
import AutoApproveCore

/// Suspend an adapter read at a known await boundary, without touching a real terminal.
private final class RecoveryReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var records: [ProcessRecord]
    private var reads = 0
    private var blocked = false
    private var commands: [String] = []
    let blockAt: Int
    init(records: [ProcessRecord], blockAt: Int) { self.records = records; self.blockAt = blockAt }
    func processes() -> [ProcessRecord] { lock.lock(); defer { lock.unlock() }; return records }
    func setProcesses(_ value: [ProcessRecord]) { lock.lock(); records = value; lock.unlock() }
    func screens(_ targets: [ScreenTarget]) -> TerminalSnapshot {
        guard !targets.isEmpty else { return TerminalSnapshot() }
        lock.lock(); reads += 1; let hold = reads == blockAt
        if hold { blocked = true }; lock.unlock()
        if hold { _ = release.wait(timeout: .now() + 5) }
        return TerminalSnapshot(screens: targets.map {
            TerminalScreen(tty: $0.tty, contents: "To continue this session, run codex resume 00000000-0000-4000-8000-000000000061\nqa% ")
        })
    }
    func launch(_ command: String) -> TerminalDelivery { lock.lock(); defer { lock.unlock() }; commands.append(command); return .sent }
    func unblock() { release.signal() }
    var isBlocked: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    var count: Int { lock.lock(); defer { lock.unlock() }; return commands.count }
}

private final class ResumeResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var calls = 0
    func send() -> ResumeDelivery {
        lock.lock(); calls += 1; let first = calls == 1; lock.unlock()
        if first { _ = release.wait(timeout: .now() + 5); return .typed }
        return .sent
    }
    func unblock() { release.signal() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

private final class ContinuationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [String] = []
    func send(_ text: String) -> ResumeDelivery { lock.lock(); defer { lock.unlock() }; inputs.append(text); return .sent }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return inputs }
}

@MainActor private func waitForAutomation(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try expect(predicate(), "The isolated adapter did not reach its expected await boundary")
}

extension ApprovalTests {
    @MainActor func testUnchangedFailureNeverQueuesRepeatedContinuation() async throws {
        for (agent, goal) in [(AgentKind.codex, false), (.codex, true), (.claude, false)] {
            let directory = URL(fileURLWithPath: "/private/tmp/aa-repeat-continue-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/" + agent.rawValue)[0]
            let probe = ContinuationProbe()
            let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot() }, approve: { _,_,_ in .sent },
                reveal: { _ in nil }, resume: { _,_,text in probe.send(text) })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.terminal: adapter])
            defer { engine.stop() }
            engine.interruptionResumeDelays = [0.02]
            var session = AgentSession(id: record.key, agent: agent, pid: record.pid, started: record.started,
                tty: "/dev/ttys901", cwd: "/tmp/qa", terminal: .terminal)
            session.channel = .terminalScreen
            engine.updateDiscovery([session], records: [record]); try engine.setAutomatic(session.id, enabled: true)
            let heading = agent == .codex ? "■ stream disconnected before completion: network error" : "API Error: Connection error."
            let footer = "? for shortcuts" + (goal ? " · Goal stalled (/goal resume)" : "")
            let stop = "Earlier task\n\n" + heading + "\n\n" + (agent == .claude ? "❯ " : "› Ask Codex to do anything") + "\n\n" + footer
            let text = goal ? CodexCapacityStop.goalResumeText : CodexCapacityStop.resumeText
            engine.receiveScreen(sessionID: session.id, raw: stop, generation: "QA")
            try await waitForAutomation { engine.snapshot.sessions.first?.capacityResume?.phase == .awaiting }
            try expectEqual(probe.texts, [text])
            // Advancing observation time alone cannot prove another failure occurred.
            for seconds in [4.0, 30, 300, 3600] {
                engine.receiveScreen(sessionID: session.id, raw: stop, generation: "QA", at: Date().addingTimeInterval(seconds))
                try expectEqual(engine.snapshot.sessions.first?.capacityResume?.phase, .awaiting)
            }
            let wrapped = stop.replacingOccurrences(of: "Earlier task", with: "Earlier\ntask")
                .replacingOccurrences(of: "completion: network", with: "completion:\nnetwork")
            engine.receiveScreen(sessionID: session.id, raw: wrapped, generation: "QA")
            try expectEqual(engine.snapshot.sessions.first?.capacityResume?.phase, .awaiting, "Word wrapping is not a new failure")
            try await Task.sleep(for: .milliseconds(80)); try expectEqual(probe.texts, [text])
            // Real work followed by a failure may redraw the exact same transcript.
            engine.receiveScreen(sessionID: session.id, raw: "• Working (esc to interrupt)", generation: "QA")
            engine.receiveScreen(sessionID: session.id, raw: stop, generation: "QA")
            try await waitForAutomation { probe.texts.count == 2 && engine.snapshot.sessions.first?.capacityResume?.phase == .awaiting }
            let next = "› New request\n\n" + stop
            engine.receiveScreen(sessionID: session.id, raw: next, generation: "QA")
            try await waitForAutomation { probe.texts.count == 3 && engine.snapshot.sessions.first?.capacityResume?.phase == .awaiting }
            let done = "• Work complete\n\n" + (agent == .claude ? "❯ " : "› Ask Codex to do anything") + "\n\n? for shortcuts" + (goal ? " · Goal achieved (1m)" : "")
            engine.receiveScreen(sessionID: session.id, raw: done, generation: "QA")
            try expectNil(engine.snapshot.sessions.first?.capacityResume)
            try expectEqual(engine.snapshot.sessions.first?.automatic, true)
            try expectEqual(engine.snapshot.sessions.first?.interruption?.needsAttention, false)
            engine.updateDiscovery([], records: [])
            for _ in 0..<10 { engine.receiveScreen(sessionID: session.id, raw: stop, generation: "QA") }
            try await Task.sleep(for: .milliseconds(80)); try expectEqual(probe.texts, [text, text, text])
        }
    }

    @MainActor func testExitRecoveryRechecksCancellationAtEveryRead() async throws {
        for read in [1, 2] {
            for action in ["cancel", "pause", "disconnect", "automaticOff"] {
                let directory = URL(fileURLWithPath: "/private/tmp/aa-recovery-race-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let records = ProcessDiscovery.parse("""
                41 1 ttys901 41 42 Mon Sep 21 09:00:00 2026 /bin/zsh
                42 41 ttys901 42 42 Mon Sep 21 09:00:01 2026 /usr/local/bin/claude
                """)
                let probe = RecoveryReadGate(records: records, blockAt: read)
                defer { probe.unblock() }
                let adapter = ScreenHostAdapter(screens: { probe.screens($0) }, approve: { _,_,_ in .sent },
                    reveal: { _ in nil }, restart: { _,_,command in probe.launch(command) })
                let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { _ in [] },
                    processReader: { probe.processes() }, screenAdapters: [.terminal: adapter])
                defer { engine.stop() }
                await engine.connectScreenHost(.terminal)
                engine.interruptionResumeDelays = [0.01]
                var session = AgentSession(id: records[1].key, agent: .claude, pid: 42, started: records[1].started,
                    tty: "/dev/ttys901", cwd: "/tmp/qa", terminal: .terminal)
                session.providerID = "00000000-0000-4000-8000-000000000061"; session.channel = .terminalScreen
                engine.updateDiscovery([session], records: records); try engine.setAutomatic(session.id, enabled: true)
                engine.receiveScreen(sessionID: session.id, raw: "API Error: Connection error.\n\n❯ \n\n? for shortcuts", generation: "QA")
                var shell = records[0]; shell.foregroundGroup = shell.processGroup
                probe.setProcesses([shell]); engine.updateDiscovery([], records: [shell])
                try await Task.sleep(for: .milliseconds(30)); engine.updateDiscovery([], records: [shell])
                try await waitForAutomation { probe.isBlocked }
                switch action {
                case "cancel": engine.cancelCapacityResume(session.id)
                case "pause": try engine.setPaused(true); try engine.setPaused(false)
                case "disconnect": engine.disconnectScreenHost(.terminal)
                default: try engine.setAutomatic(session.id, enabled: false)
                }
                probe.unblock()
                // The old path waits one second after the first read before sending.
                try await Task.sleep(for: .milliseconds(read == 1 ? 1250 : 150))
                try expectEqual(probe.count, 0, "\(action) at read \(read) must stop the original-shell command")
                if action == "cancel" || action == "automaticOff" {
                    try expectEqual(engine.snapshot.sessions.first?.interruption?.recoveryStatus, "cancelled")
                }
            }
        }
    }

    @MainActor func testStaleResumeResultCannotReplaceNewFailure() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aa-resume-result-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0]
        let probe = ResumeResultGate(); defer { probe.unblock() }
        let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot() }, approve: { _,_,_ in .sent },
            reveal: { _ in nil }, resume: { _,_,_ in probe.send() })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        engine.interruptionResumeDelays = [0.02]
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
            tty: "/dev/ttys901", cwd: "/tmp/qa", terminal: .terminal)
        session.channel = .terminalScreen
        engine.updateDiscovery([session], records: [record]); try engine.setAutomatic(session.id, enabled: true)
        let stop = "■ stream disconnected before completion: network error\n\n› Ask Codex to do anything\n\n? for shortcuts"
        engine.receiveScreen(sessionID: session.id, raw: stop, generation: "QA")
        try await waitForAutomation { probe.count == 1 }
        try engine.setAutomatic(session.id, enabled: false); try engine.setAutomatic(session.id, enabled: true)
        let next = "› A new user turn\n\n" + stop
        engine.receiveScreen(sessionID: session.id, raw: next, generation: "QA")
        probe.unblock()
        try await waitForAutomation { probe.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        try expectEqual(engine.snapshot.sessions.first?.capacityResume?.phase, .awaiting)
        try expectEqual(engine.snapshot.sessions.first?.automatic, true)
        for _ in 0..<10 { engine.receiveScreen(sessionID: session.id, raw: next, generation: "QA") }
        try await Task.sleep(for: .milliseconds(80)); try expectEqual(probe.count, 2)
        try expect(engine.snapshot.events.contains { $0.outcome == "입력 확인 필요 · 이어서 진행 전송 미확인" }, "A superseded delivery still keeps its audit result")
    }

    @MainActor func testNormalCompletionRetiresFailureBeforeExit() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aa-stop-after-error-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        41 1 ttys901 41 42 Mon Sep 21 09:00:00 2026 /bin/zsh
        42 41 ttys901 42 42 Mon Sep 21 09:00:01 2026 /usr/local/bin/claude
        """)
        let probe = RecoveryReadGate(records: records, blockAt: 99)
        let adapter = ScreenHostAdapter(screens: { probe.screens($0) }, approve: { _,_,_ in .sent },
            reveal: { _ in nil }, restart: { _,_,command in probe.launch(command) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { _ in [] },
            processReader: { probe.processes() }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        await engine.connectScreenHost(.terminal)
        engine.interruptionResumeDelays = [0.01]
        var session = AgentSession(id: records[1].key, agent: .claude, pid: 42, started: records[1].started,
            tty: "/dev/ttys901", cwd: "/tmp/qa", terminal: .terminal)
        session.channel = .terminalScreen
        engine.updateDiscovery([session], records: records); try engine.setAutomatic(session.id, enabled: true)
        var payload: JSONObject = ["hook_event_name": "StopFailure", "session_id": "00000000-0000-4000-8000-000000000061",
            "requestID": UUID().uuidString, "agentPID": 42, "agentStarted": records[1].started, "tty": "/dev/ttys901", "error": "server_error"]
        _ = engine.handleHook(payload)
        try expectEqual(engine.snapshot.sessions.first?.interruption?.needsAttention, true)
        payload["hook_event_name"] = "Stop"; payload["requestID"] = UUID().uuidString
        _ = engine.handleHook(payload)
        try expectEqual(engine.snapshot.sessions.first?.interruption?.needsAttention, false)
        try expectEqual(engine.snapshot.sessions.first?.automatic, true)
        var shell = records[0]; shell.foregroundGroup = shell.processGroup
        probe.setProcesses([shell]); engine.updateDiscovery([], records: [shell])
        try await Task.sleep(for: .milliseconds(30)); engine.updateDiscovery([], records: [shell])
        try await Task.sleep(for: .milliseconds(1250)); try expectEqual(probe.count, 0)
        try expect(engine.snapshot.sessions.first?.interruption?.recoveryStatus != "scheduled")
    }
}
