import Foundation
import AutoApproveCore

@MainActor private final class AccountTransitionRig {
    var target = CodexAccountTransitionTarget(home: "/fixture/home", executable: "/fixture/codex",
        witnesses: [.init(pid: 42, started: "original", tty: "/dev/fixture", threadID: "a")])
    var observation = CodexAccountTransitionObservation(savedAccount: "new", serverAccount: "old", serverID: "server-1",
        threads: [.init(id: "a", turnID: "turn-a", active: true), .init(id: "b", turnID: "turn-b", active: true)])
    var effects: [String] = [], saved: [CodexAccountTransitionState] = []
    var saveFails = false, interruptFails = false, restartFails = false, verified = 1
    var checkReservations = true
    var observeFails = false
    var observeCount = 0
    var mutateOnObserve: ((Int) -> Void)?
    lazy var services = CodexAccountTransitionServices(observe: { [unowned self] _ in
        observeCount += 1; mutateOnObserve?(observeCount)
        if observeFails { throw AppError.message("temporary login inspection failure") }
        return observation
    }, interrupt: { [unowned self] _, server, thread, turn in
        if checkReservations {
            try expectEqual(saved.last?.waitingThread, thread, "An interrupt reservation must be durable before submission")
            try expectEqual(saved.last?.reservations[thread], turn)
        }
        effects.append("interrupt:\(server):\(thread):\(turn)")
        if interruptFails { throw AppError.message("unknown acknowledgement") }
    }, restart: { [unowned self] _, _ in
        if checkReservations { try expect(saved.last?.restartReserved == true, "Restart must be durably reserved before submission") }
        effects.append("restart")
        if restartFails { throw AppError.message("unknown restart") }
    }, verify: { [unowned self] _, witnesses in
        try expectEqual(witnesses, target.witnesses); return verified
    })
    func coordinator(restored: CodexAccountTransitionState? = nil) -> CodexAccountTransitionCoordinator {
        CodexAccountTransitionCoordinator(target: target, state: restored, services: services, save: { [unowned self] in
            if saveFails { throw AppError.message("disk unavailable") }; saved.append($0)
        })
    }
    func idle(_ index: Int) { observation.threads[index].active = false }
}

private final class AccountInputProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var screen = AccountInputProbe.prompt
    static let prompt = "Would you like to run the following command?\n\n$ npm test\n\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel"
    func sent() { lock.lock(); count += 1; lock.unlock() }
    var writes: Int { lock.lock(); defer { lock.unlock() }; return count }
    func setScreen(_ value: String) { lock.lock(); screen = value; lock.unlock() }
    func currentScreen() -> String { lock.lock(); defer { lock.unlock() }; return screen }
    var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { [self] targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: currentScreen()) }) },
            approve: { [self] _, _, _ in sent(); return .sent }, reveal: { _ in nil },
            resume: { [self] _, _, _ in sent(); return .sent }, input: { [self] _, _, _, _ in sent(); return .sent })
    }
}
private final class AccountTargetList: @unchecked Sendable {
    private let lock = NSLock()
    private var listed = true
    let target: CodexAccountTransitionTarget
    init(_ target: CodexAccountTransitionTarget) { self.target = target }
    func hide() { lock.lock(); listed = false; lock.unlock() }
    func show() { lock.lock(); listed = true; lock.unlock() }
    func read() -> [CodexAccountTransitionTarget] { lock.lock(); defer { lock.unlock() }; return listed ? [target] : [] }
}

extension ApprovalTests {
    func testAccountTransitionMissingConversationProofStopsBeforeAnyEffect() async throws {
        for idle in [false,true] {
            let r=AccountTransitionRig()
            r.target.witnesses.append(.init(pid:43,started:"empty-window",tty:"/dev/fixture-empty",threadID:nil))
            if idle {r.idle(0);r.idle(1)}
            let c=r.coordinator()
            await c.check();await c.check();await c.check(now:Date().addingTimeInterval(121))
            try expectEqual(c.state.phase,.unsupported)
            try expectFalse(c.state.held)
            try expect(r.effects.isEmpty,"Missing conversation identity must block before interrupt or restart")
            try expect(c.state.detail.contains("대화 ID"))
            try expect(c.state.detail.contains("현재 로그인 확인"))
            try expect(c.state.reservations.isEmpty);try expectFalse(c.state.restartReserved)
        }
    }
    func testAccountTransitionCancelledReservationSurvivesSignedOutAndUnknownReads() async throws {
        let r = AccountTransitionRig(), c = r.coordinator()
        await c.check(); await c.check(); try c.cancel()
        r.observation.savedAccount = nil; await c.check()
        r.observation.savedAccount = "new"; await c.check(); await c.check()
        r.observeFails = true; await c.check(); r.observeFails = false
        let restored = r.coordinator(restored: r.saved.last)
        for _ in 0..<3 { await restored.check() }
        try expectEqual(r.effects.count, 1, "Signed-out/unknown observations must never rearm the cancelled interrupt")
        try expectEqual(restored.state.phase, .cancelled)
        try expectEqual(restored.state.reservations["a"], "turn-a")
    }
    func testAccountTransitionMissingTargetCanCancelWithoutAppRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-account-missing-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = AccountTransitionRig(); r.checkReservations = false; r.idle(0); r.idle(1)
        let targets = AccountTargetList(r.target)
        let engine = try ApprovalEngine(paths: .init(directory: root), processReader: { [] },
            codexAccountTransitions: r.services, codexAccountTargets: { _ in targets.read() })
        defer { engine.stop() }
        try engine.setCodexAccountTransitionEnabled(true)
        await engine.checkCodexAccountTransitions(); await engine.checkCodexAccountTransitions()
        try expectEqual(engine.codexAccountTransitionStates[r.target.home]?.phase, .reconnecting)
        targets.hide(); await engine.checkCodexAccountTransitions()
        try expectEqual(engine.codexAccountTransitionStates[r.target.home]?.phase, .review)
        try engine.cancelCodexAccountTransition(home: r.target.home)
        try engine.setCodexAccountTransitionEnabled(false)
        try expectFalse(engine.codexAccountTransitionHeld)
        targets.show(); try engine.setCodexAccountTransitionEnabled(true)
        await engine.checkCodexAccountTransitions()
        try expectEqual(r.effects, ["restart"], "Rediscovery must not repeat a reserved restart")
    }
    func testAccountTransitionInterruptedWorkNeverAutomaticallyContinuesAfterCompletionOrCancellation() async throws {
        let official = "■ Conversation interrupted - use /feedback if something went wrong\n\n› Ask Codex to do anything\n\n? for shortcuts"
        for completed in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-account-stopped-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let records = ProcessDiscovery.parse("41 1 ttys971 41 41 Wed Oct 21 09:00:00 2026 /fixture/codex")
            var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .terminal; session.channel = .terminalScreen
            let r = AccountTransitionRig(), probe = AccountInputProbe()
            r.checkReservations = false
            r.target.witnesses = [.init(pid: session.pid, started: session.started, tty: session.tty, threadID: "a")]
            let target = r.target
            func create() throws -> ApprovalEngine {
                let engine = try ApprovalEngine(paths: .init(directory: root), processReader: { records }, screenAdapters: [.terminal: probe.adapter],
                    codexAccountTransitions: r.services, codexAccountTargets: { _ in [target] })
                engine.interruptionResumeDelays = [0.02]
                engine.updateDiscovery([session], records: records); try engine.setAutomatic(session.id, enabled: true)
                return engine
            }
            var engine = try create(); defer { engine.stop() }
            try engine.setCodexAccountTransitionEnabled(true)
            await engine.checkCodexAccountTransitions(); await engine.checkCodexAccountTransitions()
            if completed {
                r.idle(0); await engine.checkCodexAccountTransitions(); await engine.checkCodexAccountTransitions()
                r.idle(1); await engine.checkCodexAccountTransitions(); await engine.checkCodexAccountTransitions()
                r.observation.serverID = "server-2"; r.observation.serverAccount = "new"
                await engine.checkCodexAccountTransitions()
                try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase, .complete)
            } else { try engine.cancelCodexAccountTransition(home: target.home) }
            for restored in [false, true] {
                if restored { engine.stop(); engine = try create() }
                probe.setScreen(official)
                engine.receiveScreen(sessionID: session.id, raw: official, generation: "official-interrupted")
                try await Task.sleep(for: .milliseconds(120))
                try expectEqual(probe.writes, 0, "Normal interruption must stay waiting after completion/cancellation and restoration")
                // A stale provider error must not revive the same interrupted turn either.
                let stale = "■ Synthetic provider error from stopped turn\n\n› Ask Codex to do anything\n\n? for shortcuts"
                engine.updateCodexQuestions([.init(sessionID: session.id, turn: .init(threadID: "a", turnID: "turn-a", status: "interrupted"))])
                probe.setScreen(stale); engine.receiveScreen(sessionID: session.id, raw: stale, generation: "stale-error")
                try await Task.sleep(for: .milliseconds(120))
                try expectEqual(probe.writes, 0, "A durable stopped-turn reservation must outlive the temporary global hold")
            }
            // A new authoritative turn permits the user's existing recovery preference again.
            let fresh = "■ Synthetic provider error from new user turn\n\n› Ask Codex to do anything\n\n? for shortcuts"
            engine.updateCodexQuestions([.init(sessionID: session.id, turn: .init(threadID: "a", turnID: "new-user-turn", status: "failed"))])
            probe.setScreen(fresh); engine.receiveScreen(sessionID: session.id, raw: fresh, generation: "new-turn")
            let deadline = Date().addingTimeInterval(3)
            while probe.writes == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try expect(probe.writes > 0, "A new user turn must not inherit the old interrupted-turn hold")
        }
    }
    func testCodexNormalInterruptedCellIsNotARetryableProviderFailure() throws {
        for cell in ["■ Conversation interrupted - use /feedback if something went wrong", "■ Conversation interrupted - use /feedback if\nsomething went wrong"] {
            let frame = cell + "\n\n› Ask Codex to do anything\n\n? for shortcuts"
            try expect(CodexCapacityStop.detect(frame, agent: .codex) == nil, "Normal interruption must not enter automatic error recovery")
        }
    }
    func testAccountTransitionEngineOptInAndJournalSurviveRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-account-engine-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = AccountTransitionRig(), target = r.target
        r.checkReservations = false
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), processReader: { [] },
            codexAccountTransitions: r.services, codexAccountTargets: { _ in [target] })
        defer { engine.stop() }
        await engine.checkCodexAccountTransitions(); try expectEqual(r.observeCount, 0, "Default off must not inspect authentication")
        try engine.setCodexAccountTransitionEnabled(true)
        try expect(engine.codexAccountTransitionEnabled)
        await engine.checkCodexAccountTransitions()
        try expect(engine.codexAccountTransitionHeld)
        await engine.checkCodexAccountTransitions()
        try expectEqual(r.effects.count, 1)
        engine.stop()
        let restored = try ApprovalEngine(paths: AppPaths(directory: root), processReader: { [] },
            codexAccountTransitions: r.services, codexAccountTargets: { _ in [target] })
        defer { restored.stop() }
        try expect(restored.codexAccountTransitionEnabled)
        try expect(restored.codexAccountTransitionHeld, "A prior unconfirmed reservation must hold automation even before discovery")
        await restored.checkCodexAccountTransitions()
        try expectEqual(r.effects.count, 1); try expectEqual(restored.codexAccountTransitionStates[target.home]?.phase, .review)
        try restored.cancelCodexAccountTransition(home: target.home)
        try expectFalse(restored.codexAccountTransitionHeld)
        try restored.setCodexAccountTransitionEnabled(false)
    }
    func testAccountTransitionEngineHoldBlocksRealDispatchAndKeepsAutomaticSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-account-hold-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = ProcessDiscovery.parse("41 1 ttys971 41 41 Wed Oct 21 09:00:00 2026 /fixture/codex")
        var session = AgentSession(id: records[0].key, agent: .codex, pid: 41, started: records[0].started,
            tty: "/dev/ttys971", cwd: "/fixture", terminal: .iterm)
        session.channel = .itermScreen
        let r = AccountTransitionRig(), target = r.target, probe = AccountInputProbe()
        let transport = CodexReplyTransport(prepare: { _, q in .init(executable: "/fixture/codex", home: "/fixture/home", threadID: q.threadID) },
            send: { _, _ in probe.sent(); return "receipt" }, prepareMessage: { _ in .init(executable: "/fixture/codex", home: "/fixture/home", threadID: "a") })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), questionTransport: transport, processReader: { records }, screenAdapters: [.iterm: probe.adapter],
            codexAccountTransitions: r.services, codexAccountTargets: { _ in [target] })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records); try engine.setAutomatic(session.id, enabled: true)
        try engine.setCodexAccountTransitionEnabled(true); await engine.checkCodexAccountTransitions()
        engine.receiveScreen(sessionID: session.id, raw: AccountInputProbe.prompt, generation: "account-hold")
        try await Task.sleep(for: .milliseconds(250))
        try expectEqual(probe.writes, 0, "Transition must block the actual automatic approval transport")
        try expect(engine.snapshot.sessions.first?.automatic == true, "A temporary hold must preserve the user's automatic preference")
        try expectFalse(engine.snapshot.paused)
        do {
            _ = try await engine.remoteAction(["action": "sendMessage", "sessionID": session.id, "text": "must remain unsent"])
            throw AppError.message("Message accepted while switching")
        } catch let error as RemoteHTTPError {
            try expectEqual(error.status, 409); try expectEqual(error.diagnostics?["delivery"], "not_started")
        }
        try expectEqual(probe.writes, 0, "A new remote message must not enter the existing queue during transition")
        try engine.cancelCodexAccountTransition(home: target.home)
        engine.receiveScreen(sessionID: session.id, raw: AccountInputProbe.prompt.replacingOccurrences(of: "npm test", with: "npm run check"), generation: "after-hold")
        // A fresh screen is required after releasing the hold; original flags remain unchanged.
        try expect(engine.snapshot.sessions.first?.automatic == true)
    }
    func testAccountTransitionSequentialStopsAwaitActualIdle() async throws {
        let r = AccountTransitionRig(), c = r.coordinator()
        await c.check()
        try expect(c.state.held, "Changed account must establish the automation hold before stopping work")
        await c.check()
        try expectEqual(r.effects, ["interrupt:server-1:a:turn-a"])
        for _ in 0..<3 { await c.check() }
        try expectEqual(r.effects.count, 1, "Acknowledgement alone cannot stop the next conversation")
        r.idle(0); await c.check(); await c.check()
        try expectEqual(r.effects, ["interrupt:server-1:a:turn-a", "interrupt:server-1:b:turn-b"])
        r.idle(1); await c.check(); await c.check()
        try expectEqual(r.effects.last, "restart")
        try expectEqual(r.effects.count, 3)
        await c.check()
        try expectEqual(r.effects.count, 3, "Old-server observation after restart must not resubmit")
        r.observation.serverID = "server-2"; r.observation.serverAccount = "new"
        await c.check()
        try expectEqual(c.state.phase, .complete)
        try expectFalse(c.state.held)
        try expectEqual(c.state.verified, 1)
    }
    func testAccountTransitionSameAccountLogoutAndBarriers() async throws {
        for account in ["old", nil] as [String?] {
            let r = AccountTransitionRig(); r.observation.savedAccount = account
            let c = r.coordinator(); for _ in 0..<3 { await c.check() }
            try expect(r.effects.isEmpty); try expectFalse(c.state.held)
        }
        for reason in ["대기 입력", "백그라운드 작업", "활성 Goal"] {
            let r = AccountTransitionRig(); r.idle(0); r.idle(1); r.observation.threads[0].blocker = reason
            let c = r.coordinator(); for _ in 0..<4 { await c.check() }
            try expect(r.effects.isEmpty); try expectEqual(c.state.phase, .waiting)
            try expect(c.state.detail.contains(reason))
        }
    }
    func testAccountTransitionAmbiguousEffectsAndPersistenceAreNotRetried() async throws {
        let r = AccountTransitionRig(); r.interruptFails = true
        let c = r.coordinator(); for _ in 0..<4 { await c.check() }
        try expectEqual(c.state.phase, .review); try expectEqual(r.effects.count, 1)
        let restored = r.coordinator(restored: r.saved.last)
        for _ in 0..<3 { await restored.check() }
        try expectEqual(restored.state.phase, .review); try expectEqual(r.effects.count, 1)
        let disk = AccountTransitionRig(); disk.saveFails = true
        let blocked = disk.coordinator(); for _ in 0..<3 { await blocked.check() }
        try expect(disk.effects.isEmpty); try expectEqual(blocked.state.phase, .review)
        let restart = AccountTransitionRig(); restart.idle(0); restart.idle(1); restart.restartFails = true
        let restarting = restart.coordinator(); for _ in 0..<5 { await restarting.check() }
        try expectEqual(restarting.state.phase, .review); try expectEqual(restart.effects, ["restart"])
    }
    func testAccountTransitionFreshBarrierTurnAndAccountRaces() async throws {
        for mutation in 0..<4 {
            let r = AccountTransitionRig(), c = r.coordinator()
            await c.check(); await c.check()
            switch mutation {
            case 0: r.observation.threads[0].turnID = "different-turn"
            case 1: r.observation.threads.append(.init(id: "new-thread"))
            case 2: r.observation.savedAccount = "third-account"
            default: r.observation.serverID = "different-server"
            }
            await c.check(); await c.check()
            try expectEqual(c.state.phase, .review); try expectEqual(r.effects.count, 1)
        }
        let r = AccountTransitionRig(); r.idle(0); r.idle(1)
        let c = r.coordinator(); await c.check()
        r.mutateOnObserve = { count in if count == 3 { r.observation.threads[0].active = true } }
        await c.check()
        try expectFalse(r.effects.contains("restart"), "Restart must recheck the complete barrier immediately before submission")
    }
    func testAccountTransitionRejectsServerAccountChangeWithoutSocketReplacement() async throws {
        let r = AccountTransitionRig(), c = r.coordinator()
        await c.check()
        r.observation.serverAccount = "unexpected-account"
        await c.check()
        try expectEqual(c.state.phase, .review, "Authentication can change inside an existing server without replacing its socket")
        try expect(r.effects.isEmpty)
    }
    func testAccountTransitionCancellationTimeoutAndReconnectProof() async throws {
        let r = AccountTransitionRig(), c = r.coordinator()
        await c.check(); await c.check(); try c.cancel()
        for _ in 0..<3 { await c.check() }
        try expectEqual(r.effects.count, 1); try expectEqual(c.state.phase, .cancelled); try expectFalse(c.state.held)
        let timeout = AccountTransitionRig(), waiting = timeout.coordinator()
        let now = Date(); await waiting.check(now: now); await waiting.check(now: now)
        await waiting.check(now: now.addingTimeInterval(121))
        try expectEqual(waiting.state.phase, .review); try expectEqual(timeout.effects.count, 1)
        let proof = AccountTransitionRig(); proof.idle(0); proof.idle(1); proof.verified = 0
        let p = proof.coordinator(); await p.check(now: now); await p.check(now: now)
        proof.observation.serverID = "server-2"; proof.observation.serverAccount = "new"
        await p.check(now: now.addingTimeInterval(121))
        try expectEqual(p.state.phase, .review, "Server account alone cannot prove original TUI conversation reconnection")
    }
}
