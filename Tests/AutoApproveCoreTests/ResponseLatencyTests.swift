import Foundation
import Combine
import AutoApproveCore

@MainActor private func expectThrowsAsync(_ operation: () async throws -> Void) async throws {
    var failed = false
    do { try await operation() } catch { failed = true }
    try expect(failed, "Expected the isolated response operation to fail")
}

private actor PreparationProbe {
    var reads = 0, writes = 0
    let failures: Int
    init(_ failures: Int) { self.failures = failures }
    func prepare(_ question: QueuedQuestion) throws -> CodexReplyTarget {
        reads += 1
        if reads <= failures { throw RemoteHTTPError(503, "Synthetic transient read", diagnostics: ["delivery": "not_started"]) }
        return CodexReplyTarget(executable: "/unused", home: "/synthetic", threadID: question.threadID)
    }
    func send() -> String { writes += 1; return "00000000-0000-4000-8000-000000000002" }
}
private final class LatencyFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var text = "Working\nesc to interrupt", reads = 0, active = 0, peak = 0
    private var slowStarted = false
    private var slowActive = false, resumes = 0
    func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var slowEntered: Bool { lock.lock(); defer { lock.unlock() }; return slowStarted }
    var slowInFlight: Bool { lock.lock(); defer { lock.unlock() }; return slowActive }
    var resumeCount: Int { lock.lock(); defer { lock.unlock() }; return resumes }
    func resume(_ text: String) -> ResumeDelivery {
        lock.lock(); defer { lock.unlock() }
        guard text == CodexCapacityStop.resumeText else { return .missingTarget }
        resumes += 1; return .sent
    }
    func fast(_ targets: [ScreenTarget]) -> TerminalSnapshot {
        lock.lock(); reads += 1; active += 1; peak = max(peak, active); let raw = text; lock.unlock()
        Thread.sleep(forTimeInterval: 0.03)
        lock.lock(); active -= 1; lock.unlock()
        return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: raw) })
    }
    func slow(_ targets: [ScreenTarget]) -> TerminalSnapshot {
        lock.lock(); slowStarted = true; slowActive = true; lock.unlock()
        Thread.sleep(forTimeInterval: 3)
        lock.lock(); slowActive = false; lock.unlock()
        return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "Working\nesc to interrupt") })
    }
}
private final class LateResponseFrame: @unchecked Sendable {
    private let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private var armed = false, entered = false
    func arm() { lock.lock(); armed = true; lock.unlock() }
    var waiting: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func finish() { release.signal() }
    func read(_ targets: [ScreenTarget]) -> TerminalSnapshot {
        lock.lock(); let delayed = armed; if delayed { entered = true }; lock.unlock()
        if delayed { _ = release.wait(timeout: .now() + 3) }
        let raw = delayed ? "Would you like to run the following command?\n$ touch ~/Library/LaunchAgents/com.fixture.late.plist\n› 1. Yes\n  2. No\nEsc to cancel" : "Working\nesc to interrupt"
        return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: raw) })
    }
}
private final class HookRPCProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = [], identifiers = Set<String>()
    func record(_ message: JSONObject) -> Int {
        lock.lock(); defer { lock.unlock() }
        methods.append(message["method"] as? String ?? "")
        if let id = (message["params"] as? JSONObject)?["requestID"] as? String { identifiers.insert(id) }
        return methods.filter { $0 == "hook" }.count
    }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return methods }
    var uniqueRequests: Int { lock.lock(); defer { lock.unlock() }; return identifiers.count }
}

extension ApprovalTests {
    private func latencyFixture(_ engine: ApprovalEngine) -> (AgentSession, QueuedQuestion) {
        let session = AgentSession(id: "process:42:latency", agent: .codex, pid: 42, started: "latency", tty: "/dev/fixture-latency", cwd: "/synthetic", terminal: .vscode)
        let question = QueuedQuestion(id: "latency-question", threadID: "00000000-0000-4000-8000-000000000001", title: "Which test?", options: ["First", "Second"])
        engine.updateDiscovery([session], records: []); engine.updateCodexQuestions([.init(sessionID: session.id, questions: [question])])
        return (session, question)
    }
    func testResponseEventCommandCompletionAndTimeout() throws {
        let text = "한글 \"literal\" $() `quoted`\n🙂\n" + String(repeating: "input-data\n", count: 12_000)
        let result = try CommandRunner.run("/bin/cat", [], timeout: 3, input: Data(text.utf8))
        try expectEqual(result.output, text); try expectEqual(result.status, 0)
        let failed = try CommandRunner.run("/usr/bin/false", [], timeout: 1)
        try expectEqual(failed.status, 1)
        try expectThrows(try CommandRunner.run("/no/such/executable", []))
        let start = ProcessInfo.processInfo.systemUptime
        try expectThrows(try CommandRunner.run("/bin/sleep", ["1"], timeout: 0.04))
        try expect(ProcessInfo.processInfo.systemUptime - start < 0.6, "The owned command must retain a bounded timeout")
        for _ in 0..<30 { try expectEqual(try CommandRunner.run("/usr/bin/true", [], timeout: 3).status, 0) }
    }
    func testResponseQuietHistoryAndImmediateChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-response-quiet-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }); defer { engine.stop() }
        let (session, question) = latencyFixture(engine), observed = engine.snapshot.sessions[0].codexQuestionsObservedAt
        var count = 0; let subscription = engine.$snapshot.dropFirst().sink { _ in count += 1 }; defer { subscription.cancel() }
        for index in 0..<100 { engine.updateCodexQuestions([.init(sessionID: session.id, questions: [question])], at: Date().addingTimeInterval(Double(index))) }
        try expectEqual(count, 0, "Unchanged history must not repaint subscribers")
        try expectEqual(engine.snapshot.sessions[0].codexQuestionsObservedAt, observed)
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: nil, error: "Synthetic read failure")])
        try expectEqual(count, 1); try expectEqual(engine.snapshot.sessions[0].questions.count, 1)
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: [question])])
        try expectEqual(count, 2, "Recovery must publish immediately without losing the prior question")
        var changed = question; changed.title = "Which different test?"
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: [changed])])
        try expectEqual(count, 3); try expectEqual(engine.snapshot.sessions[0].questions[0].title, changed.title)
    }
    func testResponseTemporaryPreparationRecoversBeforeSingleWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-response-retry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = PreparationProbe(2)
        let transport = CodexReplyTransport(prepare: { _, question in try await probe.prepare(question) }, send: { _, _ in await probe.send() })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), questionTransport: transport, claudeRegistryReader: { _ in [] }); defer { engine.stop() }
        let (session, question) = latencyFixture(engine), start = ProcessInfo.processInfo.systemUptime
        try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "First")
        try expectEqual(await probe.reads, 3); try expectEqual(await probe.writes, 1)
        try expectEqual(engine.snapshot.sessions[0].questions[0].reply?.phase, .queued)
        try expect(ProcessInfo.processInfo.systemUptime - start < 1.5, "Transient pre-write reads must recover without a long polling wait")
        try await expectThrowsAsync { try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "Duplicate") }
        try expectEqual(await probe.writes, 1)
    }
    func testResponseTemporaryPreparationIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-response-bounded-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = PreparationProbe(20)
        let transport = CodexReplyTransport(prepare: { _, question in try await probe.prepare(question) }, send: { _, _ in await probe.send() })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), questionTransport: transport, claudeRegistryReader: { _ in [] }); defer { engine.stop() }
        let (session, question) = latencyFixture(engine)
        try await expectThrowsAsync { try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "First") }
        try expectEqual(await probe.reads, 3); try expectEqual(await probe.writes, 0)
        try expectEqual(engine.snapshot.sessions[0].questions[0].reply?.phase, .failed)
    }
    func testResponseChangedQuestionAndStopPreventWrites() async throws {
        for stop in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-response-stop-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let probe = PreparationProbe(1)
            let transport = CodexReplyTransport(prepare: { _, question in try await probe.prepare(question) }, send: { _, _ in await probe.send() })
            let engine = try ApprovalEngine(paths: AppPaths(directory: root), questionTransport: transport, claudeRegistryReader: { _ in [] }); defer { engine.stop() }
            let (session, question) = latencyFixture(engine)
            let change = Task { @MainActor in
                try await Task.sleep(for: .milliseconds(20))
                if stop { engine.stop() } else { var next = question; next.title = "Changed during read"; engine.updateCodexQuestions([.init(sessionID: session.id, questions: [next])]) }
            }
            try await expectThrowsAsync { try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "First") }
            try await change.value; try expectEqual(await probe.reads, 1); try expectEqual(await probe.writes, 0)
        }
    }
    func testResponseIndependentHostsAndQuietPause() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/aa-response-hosts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = LatencyFrames()
        let fast = ScreenHostAdapter(screens: { frames.fast($0) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil })
        let slow = ScreenHostAdapter(screens: { frames.slow($0) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, processReader: { throw AppError.message("Synthetic discovery contention") }, screenAdapters: [.terminal: fast, .orca: slow]); defer { engine.stop() }
        let terminal = AgentSession(id: "process:42:fast-host", agent: .codex, pid: 42, started: "fast-host", tty: "/dev/fixture-fast", cwd: root.path, terminal: .terminal)
        var orca = AgentSession(id: "process:43:slow-host", agent: .claude, pid: 43, started: "slow-host", tty: "/dev/fixture-slow", cwd: root.path, terminal: .orca); orca.orcaHandle = "synthetic-pane"
        engine.updateDiscovery([terminal, orca], records: [])
        await engine.connectScreenHost(.terminal); await engine.connectScreenHost(.orca)
        try engine.setAutomatic(terminal.id, enabled: true); try engine.start()
        let started = ProcessInfo.processInfo.systemUptime
        while frames.count < 2, ProcessInfo.processInfo.systemUptime - started < 1 { try await Task.sleep(for: .milliseconds(10)) }
        frames.set("Which test?\n› 1. First\n  2. Second\nEnter to select")
        let deadline = ProcessInfo.processInfo.systemUptime + 2.8
        while engine.snapshot.sessions.first(where: { $0.id == terminal.id })?.phase != .input, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try expectEqual(engine.snapshot.sessions.first(where: { $0.id == terminal.id })?.phase, .input)
        try expect(frames.slowInFlight, "A healthy host must update while another host is still being read")
        try expectEqual(frames.maximum, 1, "One host must never have overlapping screen reads")
        try engine.setPaused(true); let reads = frames.count
        try await Task.sleep(for: .milliseconds(350)); try expect(frames.count <= reads + 1)
        engine.stop(); let afterStop = frames.count
        try await Task.sleep(for: .milliseconds(200)); try expectEqual(frames.count, afterStop)
        try expect(engine.snapshot.events.isEmpty, "Observations must never send a synthetic question answer")
    }
    func testResponseDefaultTransientRecoveryIsFastAndSingleUse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-response-first-retry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = ProcessDiscovery.parse("42 1 ttys980 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0], frames = LatencyFrames()
        let adapter = ScreenHostAdapter(screens: { frames.fast($0) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, resume: { _,_,text in frames.resume(text) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, processReader: { [record] }, screenAdapters: [.terminal: adapter]); defer { engine.stop() }
        let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/ttys980", cwd: root.path, terminal: .terminal)
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.terminal)
        try engine.setAutomatic(session.id, enabled: true)
        let error = "Original task\n\n■ stream disconnected before completion: network error\n\n› Ask Codex to do anything\n\n? for shortcuts"
        let start = ProcessInfo.processInfo.systemUptime
        engine.receiveScreen(sessionID: session.id, raw: error, generation: "synthetic-recovery")
        while frames.resumeCount == 0, ProcessInfo.processInfo.systemUptime - start < 2.5 { try await Task.sleep(for: .milliseconds(10)) }
        try expectEqual(frames.resumeCount, 1, "The default transient first retry must complete without the previous five-second wait")
        try expectEqual(engine.snapshot.sessions[0].capacityResume?.phase, .awaiting)
        for _ in 0..<20 { engine.receiveScreen(sessionID: session.id, raw: error, generation: "synthetic-recovery") }
        try await Task.sleep(for: .milliseconds(200)); try expectEqual(frames.resumeCount, 1, "An unchanged failure must never queue another continuation")
    }
    func testResponseLateFrameCannotCrossManagerRestart() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/aa-late-frame-" + UUID().uuidString), frames = LateResponseFrame()
        defer { frames.finish(); try? FileManager.default.removeItem(at: root) }
        let adapter = ScreenHostAdapter(screens: { frames.read($0) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, screenAdapters: [.terminal: adapter]); defer { engine.stop() }
        let session = AgentSession(id: "process:42:late-frame", agent: .codex, pid: 42, started: "late-frame", tty: "/dev/fixture-late", cwd: root.path, terminal: .terminal)
        engine.updateDiscovery([session], records: []); await engine.connectScreenHost(.terminal); try engine.start(poll: false)
        frames.arm(); let pending = Task { await engine.refreshTerminal() }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !frames.waiting, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try expect(frames.waiting)
        engine.stop(); try engine.start(poll: false)
        engine.receiveScreen(sessionID: session.id, raw: "• Working (esc to interrupt)", generation: "new-manager")
        frames.finish(); await pending.value
        try expectEqual(engine.snapshot.sessions[0].phase, .working)
        try expect(engine.snapshot.sessions[0].systemSafety == nil, "An old manager's delayed frame must not create a new unsafe action")
        try expect(engine.snapshot.events.isEmpty)
    }
    func testResponseHookClientWaitAndOlderAppFallback() async throws {
        for stream in [true, false] {
            let root = URL(fileURLWithPath: "/private/tmp/aa-hook-rpc-" + UUID().uuidString), probe = HookRPCProbe()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let socket = root.appendingPathComponent("s").path
            let response: JSONObject = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "deny", "message": "Synthetic safe alternative", "interrupt": false]]]
            let server = SocketServer(path: socket, handler: { message, peer in
                let count = probe.record(message), method = message["method"] as? String
                if method == "hookAck" { _ = peer.send(["result": [:]]); return }
                if method == "hookWait" || (!stream && count >= 2) {
                    if stream { Thread.sleep(forTimeInterval: 0.15) }
                    _ = peer.send(["result": ["autoapproveBridge": ["response": response]]])
                } else {
                    var bridge: JSONObject = ["waiting": true]; if stream { bridge["waitSupported"] = true }
                    _ = peer.send(["result": ["autoapproveBridge": bridge]])
                }
            }, disconnected: { _ in })
            try server.start(); defer { server.stop() }
            let result = await Task.detached { ClaudeHookClient.run(payload: ["hook_event_name": "PermissionRequest"], path: socket) }.value
            try expectEqual((result["hookSpecificOutput"] as? JSONObject)?["hookEventName"] as? String, "PermissionRequest")
            try expectNil(result["autoapproveBridge"])
            try expectEqual(probe.calls, stream ? ["hook", "hookWait", "hookAck"] : ["hook", "hook", "hookAck"])
            try expectEqual(probe.uniqueRequests, 1, "Reconnect and waiting must preserve one helper invocation UUID")
        }
    }
    func testResponseConcurrentHookWaitsDeliverExactSavedReceipts() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/aa-hook-waits-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = ProcessDiscovery.parse("42 1 ttys980 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/claude")[0]
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, processReader: { [record] }); defer { engine.stop() }
        engine.updateDiscovery(ProcessDiscovery.sessions([record]), records: [record]); try engine.start(poll: false)
        let payloads: [JSONObject] = (0..<2).map { number in
            ["autoapproveProtocol": 1, "requestID": UUID().uuidString, "autoapproveExpiresAt": Date().addingTimeInterval(120).timeIntervalSince1970,
             "hook_event_name": "PermissionRequest", "session_id": "synthetic-provider", "agentPID": NSNumber(value: record.pid), "agentStarted": record.started,
             "tty": "/dev/ttys980", "cwd": "/fixture", "tool_name": "Bash", "tool_use_id": "synthetic-tool-\(number)", "tool_input": ["command": "echo synthetic-\(number)"]]
        }
        let socket = engine.paths.socket
        let calls = payloads.map { payload in Task.detached { try SocketClient.request(path: socket, message: ["method": "hookWait", "params": payload], timeout: 20) } }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while engine.snapshot.sessions.first?.claudeApprovals?.count != 2, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try expectEqual(engine.snapshot.sessions[0].claudeApprovals?.count, 2)
        let start = ProcessInfo.processInfo.systemUptime
        try engine.answerClaudeApproval(sessionID: record.key, requestID: payloads[0]["requestID"] as! String)
        let first = try await calls[0].value
        try expect((first["autoapproveBridge"] as? JSONObject)?["response"] is JSONObject)
        try expect(ProcessInfo.processInfo.systemUptime - start < 0.3, "A stored decision must wake its helper without the 400ms polling interval")
        try expect(engine.snapshot.sessions[0].claudeApprovals?.contains(where: { $0.id == payloads[1]["requestID"] as? String && !$0.sending }) == true)
        try engine.acknowledgeClaudeHook(payloads[0])
        try engine.answerClaudeApproval(sessionID: record.key, requestID: payloads[1]["requestID"] as! String)
        _ = try await calls[1].value; try engine.acknowledgeClaudeHook(payloads[1])
        let replay = try await Task.detached { try SocketClient.request(path: socket, message: ["method": "hookWait", "params": payloads[0]], timeout: 2) }.value
        try expect((replay["autoapproveBridge"] as? JSONObject)?["response"] is JSONObject)
        try expectEqual(engine.snapshot.events.count, 2)
        try expect(engine.snapshot.events.allSatisfy { $0.outcome == "승인 전달" })
    }
    func testResponseFastDefaultConfirmationAndCancellationWindow() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/aa-confirm-fast-" + UUID().uuidString), probe = PreparationProbe(0)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = CodexReplyTransport(prepare: { _, question in try await probe.prepare(question) }, send: { _,_ in await probe.send() })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), questionTransport: transport, claudeRegistryReader: { _ in [] }); defer { engine.stop() }
        var session = AgentSession(id: "process:42:fast-confirm", agent: .codex, pid: 42, started: "fast-confirm", tty: "/dev/fixture-confirm", cwd: "/fixture", terminal: .terminal); session.channel = .terminalScreen
        engine.updateDiscovery([session], records: [])
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: [], threadID: "fast-thread")]); try engine.setAutomatic(session.id, enabled: true)
        var question = QueuedQuestion(id: "fast-confirm", threadID: "fast-thread", title: "계속 진행할까요?", options: ["아니오", "예"])
        let start = ProcessInfo.processInfo.systemUptime
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: [question])])
        try await Task.sleep(for: .milliseconds(150)); try expectEqual(await probe.writes, 0)
        while await probe.writes == 0, ProcessInfo.processInfo.systemUptime - start < 1.5 { try await Task.sleep(for: .milliseconds(10)) }
        try expectEqual(await probe.writes, 1, "The supported confirmation must use its brief default delay")
        question.id = "fast-cancel"; question.title = "다음 작업을 계속 진행할까요?"
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: [question])]); try engine.beginQuestionReply(sessionID: session.id, questionID: question.id)
        try await Task.sleep(for: .milliseconds(700)); try expectEqual(await probe.writes, 1, "Editing must still cancel the brief automatic confirmation")
    }

    func testResponseHookWaitConfirmationDeadlineAndPause() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/aa-hook-deadline-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = ProcessDiscovery.parse("42 1 ttys980 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/claude")[0]
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, processReader: { [record] }); defer { engine.stop() }
        engine.updateDiscovery(ProcessDiscovery.sessions([record]), records: [record]); try engine.start(poll: false)
        _ = try engine.handleClaudeHook(["autoapproveProtocol": 1, "requestID": UUID().uuidString,
            "autoapproveExpiresAt": Date().addingTimeInterval(120).timeIntervalSince1970,
            "hook_event_name": "SessionStart", "session_id": "synthetic-provider", "agentPID": NSNumber(value: record.pid),
            "agentStarted": record.started, "tty": "/dev/ttys980", "cwd": "/fixture"])
        try engine.setAutomatic(record.key, enabled: true)
        for paused in [false, true] {
            let payload: JSONObject = ["autoapproveProtocol": 1, "requestID": UUID().uuidString,
                "autoapproveExpiresAt": Date().addingTimeInterval(120).timeIntervalSince1970,
                "hook_event_name": "PreToolUse", "session_id": "synthetic-provider", "agentPID": NSNumber(value: record.pid),
                "agentStarted": record.started, "tty": "/dev/ttys980", "cwd": "/fixture", "tool_name": "AskUserQuestion", "tool_use_id": UUID().uuidString,
                "tool_input": ["questions": [["question": "계속 진행할까요?", "options": [["label": "아니오"], ["label": "예"]]]]]]
            let socket = engine.paths.socket, start = ProcessInfo.processInfo.systemUptime
            let call = Task.detached { try SocketClient.request(path: socket, message: ["method": "hookWait", "params": payload], timeout: 20) }
            while engine.snapshot.sessions.first?.claudeApprovals?.first == nil, ProcessInfo.processInfo.systemUptime - start < 1 { try await Task.sleep(for: .milliseconds(10)) }
            try expect(engine.snapshot.sessions.first?.claudeApprovals?.first != nil)
            let before = engine.snapshot.events.count
            if paused { try engine.setPaused(true) }
            try await Task.sleep(for: .milliseconds(paused ? 700 : 150))
            try expectEqual(engine.snapshot.events.count, before)
            try expect(engine.snapshot.sessions.first?.claudeApprovals?.first?.sending == false)
            let resumed = ProcessInfo.processInfo.systemUptime
            if paused { try engine.setPaused(false) }
            let result = try await call.value
            let response = (result["autoapproveBridge"] as? JSONObject)?["response"] as? JSONObject
            let input = (response?["hookSpecificOutput"] as? JSONObject)?["updatedInput"] as? JSONObject
            try expectEqual(input?["answers"] as? [String: String], ["계속 진행할까요?": "예"])
            let elapsed = ProcessInfo.processInfo.systemUptime - (paused ? resumed : start)
            try expect(elapsed < (paused ? 0.4 : 1.5), "A confirmation deadline or resumed hook must wake directly")
            if !paused { try expect(elapsed >= 0.45, "The cancellation window must not be skipped") }
            try engine.acknowledgeClaudeHook(payload)
            try expectEqual(engine.snapshot.events.count, before + 1)
        }
    }
}
