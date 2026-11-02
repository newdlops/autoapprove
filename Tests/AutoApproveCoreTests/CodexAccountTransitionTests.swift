import Foundation
import AutoApproveCore

@MainActor private final class AccountTransitionRig {
    let target = CodexAccountTransitionTarget(home: "/fixture/home", executable: "/fixture/codex",
        witnesses: [.init(pid: 42, started: "original", tty: "/dev/fixture", threadID: "a")])
    var observation = CodexAccountTransitionObservation(savedAccount: "new", serverAccount: "old", serverID: "server-1",
        threads: [.init(id: "a", turnID: "turn-a", active: true), .init(id: "b", turnID: "turn-b", active: true)])
    var effects: [String] = [], saved: [CodexAccountTransitionState] = []
    var saveFails = false, interruptFails = false, restartFails = false, verified = 1
    var observeCount = 0
    var mutateOnObserve: ((Int) -> Void)?
    lazy var services = CodexAccountTransitionServices(observe: { [unowned self] _ in
        observeCount += 1; mutateOnObserve?(observeCount); return observation
    }, interrupt: { [unowned self] _, server, thread, turn in
        try expectEqual(saved.last?.waitingThread, thread, "An interrupt reservation must be durable before submission")
        try expectEqual(saved.last?.reservations[thread], turn)
        effects.append("interrupt:\(server):\(thread):\(turn)")
        if interruptFails { throw AppError.message("unknown acknowledgement") }
    }, restart: { [unowned self] _, _ in
        try expect(saved.last?.restartReserved == true, "Restart must be durably reserved before submission")
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

extension ApprovalTests {
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
