import Foundation
import AutoApproveCore

private let resetRecords = ProcessDiscovery.parse("""
41 1 ttys971 41 41 Wed Oct 21 09:00:00 2026 /fixture/codex
51 1 ttys972 51 51 Wed Oct 21 09:00:01 2026 /fixture/codex
""")
private func resetPrompt(_ command: String = "npm test") -> String {
    "Would you like to run the following command?\n\n$ \(command)\n\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel"
}
private let resetStop = "Synthetic work\n\n■ stream disconnected before completion: network error\n\n› Ask Codex to do anything\n\n? for shortcuts"
private func resetSession(_ record: ProcessRecord) -> AgentSession {
    var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
        tty: "/dev/" + record.tty, cwd: "/fixture", terminal: .iterm)
    session.channel = .itermScreen
    return session
}

/// Hold exactly one operation at a known boundary. Every wait is bounded and
/// every adapter is synthetic; no real process, terminal, or CLI is controlled.
private final class ResetProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var stage: String?, blocked = false, expired = false
    private let repeatHold: Bool
    private var counts: [String: Int] = [:]
    private var text = resetPrompt()
    init(hold: String? = nil, repeatHold: Bool = false) { stage = hold; self.repeatHold = repeatHold }
    private func enter(_ key: String) {
        condition.lock(); defer { condition.unlock() }
        counts[key, default: 0] += 1
        guard stage == key else { return }
        if !repeatHold { stage = nil }; blocked = true
        let deadline = Date().addingTimeInterval(5)
        while blocked { if !condition.wait(until: deadline) { expired = true; blocked = false } }
    }
    func release() { condition.lock(); stage = nil; blocked = false; condition.broadcast(); condition.unlock() }
    var isBlocked: Bool { condition.lock(); defer { condition.unlock() }; return blocked }
    var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return expired }
    func count(_ key: String) -> Int { condition.lock(); defer { condition.unlock() }; return counts[key, default: 0] }
    func setScreen(_ raw: String) { condition.lock(); text = raw; condition.unlock() }
    func processes() -> [ProcessRecord] { enter("process"); return resetRecords }
    func screens(_ targets: [ScreenTarget], stage: String) -> TerminalSnapshot {
        condition.lock(); let captured = text; condition.unlock()
        enter(stage)
        return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: captured) })
    }
    var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { [self] in screens($0, stage: "monitor") },
            approve: { [self] target,_,_ in enter("approve:" + target.tty); return .sent },
            reveal: { _ in nil },
            resume: { [self] _,_,_ in enter("resume"); return .typed },
            input: { [self] _,_,_,input in enter("input:" + input.kind.rawValue); return .sent },
            validationScreens: { [self] in screens($0, stage: "safety") })
    }
}

private actor ResetQuestionProbe {
    private var gate: CheckedContinuation<Void, Never>?
    private var holds = true
    private let holdSend: Bool
    private(set) var prepares = 0
    private(set) var sent = 0
    private(set) var sending = false
    init(holdSend: Bool = false) { self.holdSend = holdSend }
    func prepare(_ question: QueuedQuestion) async -> CodexReplyTarget {
        prepares += 1
        if holds && !holdSend { await withCheckedContinuation { gate = $0 } }
        return CodexReplyTarget(executable: "/unused", home: "/fixture", threadID: question.threadID)
    }
    func release() { holds = false; gate?.resume(); gate = nil }
    func send() async -> String {
        sending = true
        if holds && holdSend { await withCheckedContinuation { gate = $0 } }
        sent += 1; sending = false; return UUID().uuidString
    }
}

@MainActor private func waitReset(_ condition: () async -> Bool) async throws {
    let until = Date().addingTimeInterval(4)
    while !(await condition()), Date() < until { try await Task.sleep(for: .milliseconds(10)) }
    try expect(await condition(), "Reset fixture did not reach the expected operation boundary")
}

extension ApprovalTests {
    func testAutomationResetCancelsOldPreflightAndKeepsOtherSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-preflight-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ResetProbe(hold: "process"); defer { probe.release() }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] },
            processReader: { probe.processes() }, screenAdapters: [.iterm: probe.adapter])
        defer { engine.stop() }
        let a = resetSession(resetRecords[0]), b = resetSession(resetRecords[1])
        engine.updateDiscovery([a,b], records: resetRecords)
        try engine.setAutomatic(a.id, enabled: true); try engine.setAutomatic(b.id, enabled: true)
        engine.receiveScreen(sessionID: a.id, raw: resetPrompt(), generation: "QA")
        try await waitReset { probe.isBlocked }
        let result = try engine.resetAutomation(a.id)
        try expect(result.cancelledTasks > 0); try expect(!result.awaitingDelivery)
        try expect(result.automatic); try expectEqual(result.sessionCount, 1)
        engine.receiveScreen(sessionID: b.id, raw: resetPrompt(), generation: "QA")
        try await waitReset { probe.count("approve:" + b.tty) == 1 }
        // A fresh request is useful even while the old, cancelled read drains.
        engine.receiveScreen(sessionID: a.id, raw: resetPrompt("npm run check"), generation: "QA")
        try await waitReset { probe.count("approve:" + a.tty) == 1 }
        probe.release(); try await Task.sleep(for: .milliseconds(80))
        try expectEqual(probe.count("approve:" + a.tty), 1)
        try expectEqual(probe.count("approve:" + b.tty), 1)
        try expect(engine.snapshot.sessions.allSatisfy(\.automatic)); try expect(!probe.timedOut)
    }

    func testAutomationResetKeepsInFlightApprovalSingleUse() async throws {
        try await checkResetInFlightApproval(all: false)
    }
    func testAllAutomationResetKeepsInFlightApprovalSingleUse() async throws {
        try await checkResetInFlightApproval(all: true)
    }
    private func checkResetInFlightApproval(all: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-write-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = resetSession(resetRecords[0]), probe = ResetProbe(hold: "approve:/dev/ttys971")
        defer { probe.release() }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] },
            processReader: { probe.processes() }, screenAdapters: [.iterm: probe.adapter])
        defer { engine.stop() }
        engine.updateDiscovery([a], records: resetRecords); try engine.setAutomatic(a.id, enabled: true)
        engine.receiveScreen(sessionID: a.id, raw: resetPrompt(), generation: "QA")
        try await waitReset { probe.isBlocked }
        let result = try all ? engine.resetAllAutomation() : engine.resetAutomation(a.id); try expect(result.awaitingDelivery)
        engine.receiveScreen(sessionID: a.id, raw: resetPrompt(), generation: "QA")
        probe.release(); try await Task.sleep(for: .milliseconds(80))
        for _ in 0..<5 { engine.receiveScreen(sessionID: a.id, raw: resetPrompt(), generation: "QA") }
        try await Task.sleep(for: .milliseconds(50))
        try expectEqual(probe.count("approve:" + a.tty), 1)
        try expect(engine.snapshot.sessions.first?.pendingInTerminal == true)
        engine.receiveScreen(sessionID: a.id, raw: resetPrompt("npm run check"), generation: "QA")
        try await waitReset { probe.count("approve:" + a.tty) == 2 }
        try expect(!probe.timedOut)
    }

    func testAutomationResetDiscardsOldMonitorReadAndUsesFreshScreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-monitor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = resetSession(resetRecords[0]), probe = ResetProbe(hold: "monitor")
        defer { probe.release() }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] },
            processReader: { probe.processes() }, screenAdapters: [.iterm: probe.adapter])
        defer { engine.stop() }
        engine.updateDiscovery([a], records: resetRecords); try engine.setAutomatic(a.id, enabled: true)
        let old = Task { await engine.connectScreenHost(.iterm) }
        try await waitReset { probe.isBlocked }
        _ = try engine.resetAutomation(a.id)
        probe.setScreen("• Working (esc to interrupt)"); probe.release(); await old.value
        try await Task.sleep(for: .milliseconds(50))
        try expectEqual(probe.count("approve:" + a.tty), 0, "An old monitor result cannot recreate a discarded approval")
        await engine.refreshScreenHost(.iterm)
        try expectEqual(engine.snapshot.sessions.first?.phase, .working)
        probe.setScreen(resetPrompt("npm run check")); await engine.refreshScreenHost(.iterm)
        try await waitReset { probe.count("approve:" + a.tty) == 1 }
        try expect(!probe.timedOut)
    }

    func testAutomationResetClearsCapacityTimerAndPreservesUncertainWrites() async throws {
        for duringWrite in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-resume-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let a = resetSession(resetRecords[0]), probe = ResetProbe(hold: duringWrite ? "resume" : nil)
            defer { probe.release() }
            let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] },
                processReader: { probe.processes() }, screenAdapters: [.iterm: probe.adapter])
            defer { engine.stop() }
            engine.interruptionResumeDelays = [duringWrite ? 0.01 : 0.2]
            engine.updateDiscovery([a], records: resetRecords); try engine.setAutomatic(a.id, enabled: true)
            engine.receiveScreen(sessionID: a.id, raw: resetStop, generation: "QA")
            if duringWrite { try await waitReset { probe.isBlocked } }
            let result = try engine.resetAutomation(a.id)
            try expectEqual(result.awaitingDelivery, duringWrite)
            try expectNil(engine.snapshot.sessions.first?.capacityResume)
            probe.release(); try await Task.sleep(for: .milliseconds(260))
            try expectEqual(probe.count("resume"), duringWrite ? 1 : 0)
            engine.interruptionResumeDelays = [0.01]
            engine.receiveScreen(sessionID: a.id, raw: resetStop, generation: "QA")
            if duringWrite {
                try await Task.sleep(for: .milliseconds(100)); try expectEqual(probe.count("resume"), 1)
                try expectEqual(engine.snapshot.sessions.first?.capacityResume?.phase, .review)
            } else { try await waitReset { probe.count("resume") == 1 } }
            try expect(!probe.timedOut)
        }
    }

    func testAutomationResetCancelsQuestionPreflightAndRechecksHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-question-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = resetSession(resetRecords[0]), probe = ResetQuestionProbe()
        let transport = CodexReplyTransport(prepare: { _,question in await probe.prepare(question) },
            send: { _,_ in await probe.send() })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), questionTransport: transport,
            claudeRegistryReader: { _ in [] }, processReader: { resetRecords })
        defer { engine.stop(); Task { await probe.release() } }
        engine.automaticConfirmationDelay = 0.01
        let question = QueuedQuestion(id: "reset-question", threadID: "reset-thread", title: "계속 진행할까요?", options: ["Yes", "No"])
        engine.updateDiscovery([a], records: resetRecords)
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: a.id, questions: [], threadID: question.threadID)])
        try engine.setAutomatic(a.id, enabled: true)
        let update = CodexQuestionUpdate(sessionID: a.id, questions: [question], threadID: question.threadID)
        engine.updateCodexQuestions([update])
        try await waitReset { await probe.prepares == 1 }
        let result = try engine.resetAutomation(a.id); try expect(result.cancelledTasks > 0)
        await probe.release()
        try await waitReset { engine.snapshot.sessions.first?.questions.first?.reply?.phase == .cancelled }
        try expectEqual(await probe.sent, 0)
        try await Task.sleep(for: .milliseconds(50)); try expectEqual(await probe.prepares, 1, "Publishing alone cannot reuse old readable history")
        engine.updateCodexQuestions([update])
        try await waitReset { await probe.sent == 1 }
        _ = try engine.resetAutomation(a.id); engine.updateCodexQuestions([update])
        try await Task.sleep(for: .milliseconds(50)); try expectEqual(await probe.sent, 1, "A queued reply keeps its single-use receipt")
        try expectEqual(engine.snapshot.sessions.first?.questions.first?.reply?.phase, .queued)
    }

    func testAutomationResetPreservesOffPauseAndManualQuestionHold() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-policy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = resetSession(resetRecords[0]), probe = ResetProbe()
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] },
            processReader: { probe.processes() }, screenAdapters: [.iterm: probe.adapter])
        defer { engine.stop() }
        engine.updateDiscovery([a], records: resetRecords)
        for _ in 0..<5 { let result = try engine.resetAutomation(a.id); try expect(!result.automatic); try expect(!result.paused) }
        engine.receiveScreen(sessionID: a.id, raw: resetPrompt(), generation: "QA")
        try await Task.sleep(for: .milliseconds(50)); try expectEqual(probe.count("approve:" + a.tty), 0)
        try engine.setPaused(true); try engine.setAutomatic(a.id, enabled: true)
        let result = try engine.resetAutomation(a.id); try expect(result.automatic); try expect(result.paused)
        engine.receiveScreen(sessionID: a.id, raw: resetPrompt(), generation: "QA")
        try await Task.sleep(for: .milliseconds(50)); try expectEqual(probe.count("approve:" + a.tty), 0)
        let question = QueuedQuestion(id: "reset-edited", threadID: "reset-thread", title: "진행할까요?", options: ["Yes", "No"])
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: a.id, questions: [], threadID: question.threadID)])
        let update = CodexQuestionUpdate(sessionID: a.id, questions: [question], threadID: question.threadID)
        engine.updateCodexQuestions([update]); try engine.beginQuestionReply(sessionID: a.id, questionID: question.id)
        _ = try engine.resetAutomation(a.id); engine.updateCodexQuestions([update])
        try expectEqual(engine.snapshot.sessions.first?.questions.first?.automation?.phase, .editing)
        let reply = try await engine.remoteAction(["action":"resetAutomation", "sessionID": a.id])
        try expectEqual(reply["paused"] as? Bool, true); try expectEqual(reply["automatic"] as? Bool, true)
        do { _ = try engine.resetAutomation("missing"); throw AppError.message("Missing sessions must not reset anything") }
        catch { try expectEqual(error.localizedDescription, "실행 중인 세션을 선택해주세요.") }
        try expectEqual(engine.snapshot.sessions.first?.pid, a.pid)
        try expectEqual(engine.snapshot.sessions.first?.started, a.started)
    }

    func testAutomationResetKeepsDispatchedQuestionReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-question-send-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = resetSession(resetRecords[0]), probe = ResetQuestionProbe(holdSend: true)
        let transport = CodexReplyTransport(prepare: { _,question in await probe.prepare(question) }, send: { _,_ in await probe.send() })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), questionTransport: transport,
            claudeRegistryReader: { _ in [] }, processReader: { resetRecords })
        defer { engine.stop(); Task { await probe.release() } }
        engine.automaticConfirmationDelay = 0.01
        let question = QueuedQuestion(id: "reset-sending", threadID: "reset-thread", title: "계속 진행할까요?", options: ["Yes", "No"])
        engine.updateDiscovery([a], records: resetRecords)
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: a.id, questions: [], threadID: question.threadID)])
        try engine.setAutomatic(a.id, enabled: true)
        let update = CodexQuestionUpdate(sessionID: a.id, questions: [question], threadID: question.threadID)
        engine.updateCodexQuestions([update]); try await waitReset { await probe.sending }
        let result = try engine.resetAutomation(a.id); try expect(result.awaitingDelivery)
        engine.updateCodexQuestions([update]); await probe.release()
        try await waitReset { engine.snapshot.sessions.first?.questions.first?.reply?.phase == .queued }
        for _ in 0..<3 { _ = try engine.resetAutomation(a.id); engine.updateCodexQuestions([update]) }
        try await Task.sleep(for: .milliseconds(60)); try expectEqual(await probe.sent, 1)
        try expectEqual(engine.snapshot.sessions.first?.questions.first?.reply?.phase, .queued)
    }

    func testAutomationResetCancelsSafetyPreflightWithoutApprovalOrKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-safety-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = resetSession(resetRecords[0]), probe = ResetProbe(hold: "safety")
        defer { probe.release() }
        let dangerous = resetPrompt("cp fixture.plist ~/Library/LaunchAgents/com.fixture.plist")
        probe.setScreen(dangerous)
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] },
            processReader: { probe.processes() }, screenAdapters: [.iterm: probe.adapter])
        defer { engine.stop() }
        engine.updateDiscovery([a], records: resetRecords); try engine.setAutomatic(a.id, enabled: true)
        engine.receiveScreen(sessionID: a.id, raw: dangerous, generation: "QA")
        try await waitReset { probe.isBlocked }
        _ = try engine.resetAutomation(a.id); probe.release()
        try await Task.sleep(for: .milliseconds(70))
        try expectEqual(probe.count("input:escape"), 0); try expectEqual(probe.count("input:characters"), 0)
        try expectEqual(probe.count("approve:" + a.tty), 0)
        // The old cancelled callback must release its input reservation. A fresh
        // ordinary permission still works, without accepting the system change.
        probe.setScreen(resetPrompt()); engine.receiveScreen(sessionID: a.id, raw: resetPrompt(), generation: "QA")
        try await waitReset { probe.count("approve:" + a.tty) == 1 }
        try expect(!probe.timedOut)
    }

    func testAutomationResetWakesOriginalClaudeHookAndRebuildsFreshRequest() async throws {
        try await checkResetClaudeHooks(all: false)
    }
    func testAllAutomationResetWakesEveryClaudeHookAndRebuildsFreshRequests() async throws {
        try await checkResetClaudeHooks(all: true)
    }
    private func checkResetClaudeHooks(all: Bool) async throws {
        let root = URL(fileURLWithPath: "/private/tmp/aa-rh-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = ProcessDiscovery.parse("42 1 ttys973 42 42 Wed Oct 21 09:00:00 2026 /fixture/claude\n52 1 ttys974 52 52 Wed Oct 21 09:00:01 2026 /fixture/claude")
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, processReader: { records })
        defer { engine.stop() }
        engine.updateDiscovery(ProcessDiscovery.sessions(records), records: records); try engine.start(poll: false)
        engine.automaticConfirmationDelay = 2
        let payloads: [JSONObject] = records.map { record in
            ["autoapproveProtocol": 1, "requestID": UUID().uuidString, "autoapproveExpiresAt": Date().addingTimeInterval(120).timeIntervalSince1970,
             "hook_event_name": "PreToolUse", "session_id": "reset-provider-\(record.pid)", "agentPID": NSNumber(value: record.pid), "agentStarted": record.started,
             "tty": "/dev/" + record.tty, "cwd": "/fixture", "tool_name": "AskUserQuestion", "tool_use_id": UUID().uuidString,
             "tool_input": ["questions": [["question": "계속 진행할까요?", "options": [["label": "아니오"], ["label": "예"]]]]]]
        }
        let socket = engine.paths.socket
        let calls = payloads.map { payload in Task.detached { try SocketClient.request(path: socket, message: ["method":"hookWait", "params":payload], timeout: 4) } }
        try await waitReset { engine.snapshot.sessions.filter { $0.claudeApprovals?.count == 1 }.count == 2 }
        try engine.setAutomatic(records[0].key, enabled: true)
        if all { _ = try engine.resetAllAutomation() }
        else { _ = try engine.resetAutomation(records[0].key) }
        let response = try await calls[0].value
        try expect((response["autoapproveBridge"] as? JSONObject)?["response"] == nil, "A reset wakes the original helper without answering its stale reservation")
        if all {
            let second = try await calls[1].value
            try expect((second["autoapproveBridge"] as? JSONObject)?["response"] == nil)
            try expect(engine.snapshot.sessions.allSatisfy { ($0.claudeApprovals ?? []).isEmpty })
        } else { try expectEqual(engine.snapshot.sessions.first { $0.id == records[1].key }?.claudeApprovals?.count, 1) }
        try engine.setPaused(true)
        let fresh = Task.detached { try SocketClient.request(path: socket, message: ["method":"hookWait", "params":payloads[0]], timeout: 4) }
        try await waitReset { engine.snapshot.sessions.first { $0.id == records[0].key }?.claudeApprovals?.count == 1 }
        try engine.answerClaudeApproval(sessionID: records[0].key, requestID: payloads[0]["requestID"] as! String)
        let rebuilt = try await fresh.value
        try expect((rebuilt["autoapproveBridge"] as? JSONObject)?["response"] is JSONObject)
        if all {
            let other = Task.detached { try SocketClient.request(path: socket, message: ["method":"hookWait", "params":payloads[1]], timeout: 4) }
            try await waitReset { engine.snapshot.sessions.first { $0.id == records[1].key }?.claudeApprovals?.count == 1 }
            try engine.answerClaudeApproval(sessionID: records[1].key, requestID: payloads[1]["requestID"] as! String)
            _ = try await other.value
        } else {
            try engine.answerClaudeApproval(sessionID: records[1].key, requestID: payloads[1]["requestID"] as! String)
            _ = try await calls[1].value
        }
        try expectEqual(engine.snapshot.events.filter { $0.source == "자동화 복구" }.count, 1)
        try expectEqual(engine.snapshot.sessions.count, 2)
    }

    func testAllAutomationResetCancelsConcurrentPreflightsAndRebuildsBothSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-all-preflight-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ResetProbe(hold: "process", repeatHold: true); defer { probe.release() }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] },
            processReader: { probe.processes() }, screenAdapters: [.iterm: probe.adapter])
        defer { engine.stop() }
        let targets = resetRecords.map(resetSession)
        engine.updateDiscovery(targets, records: resetRecords)
        for target in targets {
            try engine.setAutomatic(target.id, enabled: true)
            engine.receiveScreen(sessionID: target.id, raw: resetPrompt(), generation: "QA")
        }
        try await waitReset { probe.count("process") >= 2 && probe.isBlocked }
        let reset = try engine.resetAllAutomation()
        try expect(reset.allSessions); try expectEqual(reset.sessionCount, 2); try expect(reset.cancelledTasks >= 2)
        probe.release(); try await Task.sleep(for: .milliseconds(60))
        for target in targets { try expectEqual(probe.count("approve:" + target.tty), 0) }
        try expectEqual(engine.snapshot.events.filter { $0.source == "자동화 복구" }.count, 1)
        for target in targets { engine.receiveScreen(sessionID: target.id, raw: resetPrompt("npm run check"), generation: "QA") }
        try await waitReset { targets.allSatisfy { probe.count("approve:" + $0.tty) == 1 } }
        try expect(engine.snapshot.sessions.allSatisfy(\.automatic)); try expect(!probe.timedOut)
    }

    func testAllAutomationResetRotatesDefaultEpochAndAcceptsFreshReadsAfterRepeatedReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-all-monitor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ResetProbe(hold: "monitor"); defer { probe.release() }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] },
            processReader: { probe.processes() }, screenAdapters: [.iterm: probe.adapter])
        defer { engine.stop() }
        let targets = resetRecords.map(resetSession)
        engine.updateDiscovery(targets, records: resetRecords)
        for target in targets { try engine.setAutomatic(target.id, enabled: true) }
        let old = Task { await engine.connectScreenHost(.iterm) }
        try await waitReset { probe.isBlocked }
        _ = try engine.resetAllAutomation()
        probe.setScreen("• Working (esc to interrupt)"); probe.release(); await old.value
        for target in targets { try expectEqual(probe.count("approve:" + target.tty), 0) }
        for _ in 0..<3 {
            _ = try engine.resetAllAutomation(); _ = try engine.resetAutomation(targets[0].id)
            await engine.refreshScreenHost(.iterm)
            try expect(engine.snapshot.sessions.allSatisfy { $0.phase == .working }, "A fresh read must use the new global default even for an ID absent from the epoch map")
        }
        probe.setScreen(resetPrompt("npm run check")); await engine.refreshScreenHost(.iterm)
        try await waitReset { targets.allSatisfy { probe.count("approve:" + $0.tty) == 1 } }
        try expect(!probe.timedOut)
    }

    func testAllAutomationResetQuestionCancellationAndDispatchedReceipts() async throws {
        for duringSend in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-all-question-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let probe = ResetQuestionProbe(holdSend: duringSend)
            let transport = CodexReplyTransport(prepare: { _,question in await probe.prepare(question) }, send: { _,_ in await probe.send() })
            let engine = try ApprovalEngine(paths: AppPaths(directory: root), questionTransport: transport,
                claudeRegistryReader: { _ in [] }, processReader: { resetRecords })
            defer { engine.stop(); Task { await probe.release() } }
            engine.automaticConfirmationDelay = 0.01
            let targets = resetRecords.map(resetSession), a = targets[0]
            engine.updateDiscovery(targets, records: resetRecords)
            let question = QueuedQuestion(id: "all-reset-question", threadID: "all-reset-thread", title: "계속 진행할까요?", options: ["Yes", "No"])
            engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: a.id, questions: [], threadID: question.threadID)])
            try engine.setAutomatic(a.id, enabled: true)
            let update = CodexQuestionUpdate(sessionID: a.id, questions: [question], threadID: question.threadID)
            engine.updateCodexQuestions([update])
            try await waitReset { duringSend ? await probe.sending : await probe.prepares == 1 }
            let result = try engine.resetAllAutomation()
            // The transport reserves delivery before its async prepare call.
            // A conservative "awaiting" indication can therefore be true in
            // both cases; the actual write count below proves cancellation.
            if duringSend { try expect(result.awaitingDelivery) }
            await probe.release()
            if !duringSend {
                try await waitReset { engine.snapshot.sessions.first { $0.id == a.id }?.questions.first?.reply?.phase == .cancelled }
                try expectEqual(await probe.sent, 0)
            }
            engine.updateCodexQuestions([update])
            try await waitReset { engine.snapshot.sessions.first { $0.id == a.id }?.questions.first?.reply?.phase == .queued }
            for _ in 0..<3 { _ = try engine.resetAllAutomation(); engine.updateCodexQuestions([update]) }
            try await Task.sleep(for: .milliseconds(50)); try expectEqual(await probe.sent, 1)
            try expectEqual(engine.snapshot.sessions.first { $0.id == targets[1].id }?.automatic, false)
        }
    }

    func testAllAutomationResetHandlesEmptyEndedAndMixedPolicies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-all-empty-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, processReader: { resetRecords })
        defer { engine.stop() }
        try expectEqual(try engine.resetAllAutomation().sessionCount, 0)
        let targets = resetRecords.map(resetSession)
        engine.updateDiscovery(targets, records: resetRecords); try engine.setPaused(true)
        try engine.setAutomatic(targets[0].id, enabled: true)
        for _ in 0..<4 {
            let result = try engine.resetAllAutomation(); try expect(result.paused); try expectEqual(result.sessionCount, 2)
            try expectEqual(engine.snapshot.sessions.first { $0.id == targets[0].id }?.automatic, true)
            try expectEqual(engine.snapshot.sessions.first { $0.id == targets[1].id }?.automatic, false)
        }
        engine.updateDiscovery([], records: [])
        try expect(engine.snapshot.sessions.allSatisfy { $0.phase == .ended })
        let reply = try await engine.remoteAction(["action": "resetAllAutomation"])
        try expectEqual(reply["sessionCount"] as? Int, 0); try expectEqual(reply["allSessions"] as? Bool, true)
        try expectEqual(reply["paused"] as? Bool, true)
        engine.updateDiscovery(targets, records: resetRecords)
        try expectEqual(engine.snapshot.sessions.first { $0.id == targets[0].id }?.pid, targets[0].pid)
        try expectEqual(engine.snapshot.sessions.first { $0.id == targets[1].id }?.started, targets[1].started)
    }

    func testAllAutomationResetHTTPReceiptOriginAndNodeChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reset-all-http-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), processReader: { [] })
        defer { engine.stop() }
        let service = RemoteNetworkService(engine: engine, nodeID: "global-reset-fixture", bonjourEnabled: false, loopbackOnly: true, discoveryAddresses: { [] }, onStatus: { _ in })
        defer { service.stop() }
        let body = try JSONSerialization.data(withJSONObject: ["action": "resetAllAutomation", "requestID": UUID().uuidString])
        func request(_ extra: String = "") throws -> RemoteHTTPRequest {
            var raw = Data("POST /api/action HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\(extra)\r\n".utf8)
            raw.append(body); return try RemoteHTTPRequest.parse(raw)!
        }
        try expectEqual(await service.handle(try request("Origin: http://foreign.example\r\n")).status, 403)
        try expectEqual(await service.handle(try request("X-AutoApprove-Node: wrong-node\r\n")).status, 409)
        try expect(engine.snapshot.events.isEmpty)
        let first = await service.handle(try request()), replay = await service.handle(try request())
        try expectEqual(first.status, 200); try expectEqual(replay.body, first.body)
        let object = try JSONSerialization.jsonObject(with: first.body) as! JSONObject
        try expectEqual(object["allSessions"] as? Bool, true)
        try expectEqual(engine.snapshot.events.filter { $0.source == "자동화 복구" }.count, 1)
    }
}
