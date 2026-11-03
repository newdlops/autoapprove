import Foundation
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif

@MainActor final class AccountTransitionRig {
    var target = CodexAccountTransitionTarget(home: "/fixture/home", executable: "/fixture/codex",
        witnesses: [.init(pid: 42, started: "original", tty: "/dev/fixture", threadID: "a")])
    var observation = CodexAccountTransitionObservation(savedAccount: "new", serverAccount: "old", serverID: "server-1",
        threads: [.init(id: "a", turnID: "turn-a", active: true), .init(id: "b", turnID: "turn-b", active: true)])
    var effects: [String] = [], saved: [CodexAccountTransitionState] = []
    var saveFails = false, interruptFails = false, restartFails = false, verified = 1
    var checkReservations = true
    var observeFails = false
    var observeCount = 0
    var persistedThreads:Set<String>=["a","b"]
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
    }, verify: { [unowned self] _, witnesses,threads in
        try expectEqual(witnesses, target.witnesses)
        guard Set(threads.map(\.id)).isSubset(of:persistedThreads) else{return 0}
        return verified
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
    func testAccountReconnectJoinsExistingTransitionWithoutNewRestart() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-reconnect-join-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig();r.idle(0);r.idle(1);r.checkReservations=false
        let target=r.target
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]});defer{engine.stop()}
        try engine.setCodexAccountTransitionEnabled(true)
        await engine.checkCodexAccountTransitions();await engine.checkCodexAccountTransitions()
        try expectEqual(r.effects,["restart"])
        r.observation.serverID="server-2";r.observation.serverAccount="new"
        try await engine.reconnectCodexLogin(home:target.home)
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.complete)
        for _ in 0..<3 {await engine.checkCodexAccountTransitions()}
        try expectEqual(r.effects,["restart"],"A duplicate reconnect must only reconcile the existing reservation")
    }
    func testAccountReviewReadsQuiescenceBeforeContinuingWithoutRepeatedInterrupt() async throws {
        let r=AccountTransitionRig();r.interruptFails=true
        let c=r.coordinator();await c.check();await c.check()
        try expectEqual(c.state.phase,.review);try expectEqual(r.effects.count,1)
        await c.check();try expectEqual(c.state.phase,.review);try expectEqual(r.effects.count,1)
        r.idle(0);await c.check()
        try expectEqual(c.state.phase,.stopping,"Fresh proof that the reserved turn stopped can release review")
        try expectEqual(r.effects.count,1,"The recovery inspection must not send any lifecycle command")
        r.interruptFails=false;await c.check()
        try expectEqual(r.effects.count,2);try expect(r.effects.last?.contains(":b:")==true)
        r.idle(1);await c.check();await c.check()
        try expectEqual(r.effects.filter{$0=="restart"}.count,1)
    }
    func testAccountReconnectWaitsForReadOnlyInspection() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-reconnect-busy-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig();r.idle(0);r.idle(1);r.checkReservations=false;r.observation.savedAccount="old"
        var reads=0
        var services=r.services
        services.observe={_ in reads+=1;try await Task.sleep(for:.milliseconds(150));return r.observation}
        let target=r.target
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:services,codexAccountTargets:{_ in [target]});defer{engine.stop()}
        try engine.setCodexAccountTransitionEnabled(true)
        let checking=Task {await engine.checkCodexAccountTransitions()}
        while reads==0 {await Task.yield()}
        try expect(engine.codexAccountTransitionBusy)
        try await engine.reconnectCodexLogin(home:target.home)
        await checking.value
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.stopping)
        await engine.checkCodexAccountTransitions()
        try expectEqual(r.effects,["restart"])
    }
    func testAccountReconnectWaitsForCompletionWithoutCreatingAnotherRequest() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-reconnect-completing-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig();r.idle(0);r.idle(1);r.checkReservations=false
        var verifying=false;var services=r.services
        services.verify={_,_,_ in verifying=true;try await Task.sleep(for:.milliseconds(150));return 1}
        let target=r.target
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:services,codexAccountTargets:{_ in [target]});defer{engine.stop()}
        try engine.setCodexAccountTransitionEnabled(true)
        await engine.checkCodexAccountTransitions();await engine.checkCodexAccountTransitions()
        r.observation.serverID="server-2";r.observation.serverAccount="new"
        let checking=Task {await engine.checkCodexAccountTransitions()}
        let deadline=Date().addingTimeInterval(3)
        while !verifying,Date()<deadline {try await Task.sleep(for:.milliseconds(10))}
        try expect(verifying)
        try await engine.reconnectCodexLogin(home:target.home);await checking.value
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.complete)
        for _ in 0..<3 {await engine.checkCodexAccountTransitions()}
        try expectEqual(r.effects,["restart"])
    }
    func testAccountReviewNeverRetriesReservedInterruptOrChangedIdentity() async throws {
        for changed in ["account","server","turn","missing","active"] {
            let r=AccountTransitionRig();r.interruptFails=true
            let c=r.coordinator();await c.check();await c.check()
            r.idle(0)
            switch changed {
            case "account":r.observation.savedAccount="another"
            case "server":r.observation.serverID="another"
            case "turn":r.observation.threads[0].turnID="another"
            case "missing":r.observation.threads.removeFirst()
            default:r.observation.threads[0].active=true
            }
            for _ in 0..<3 {await c.check()}
            try expectEqual(c.state.phase,.review);try expectEqual(r.effects.count,1)
        }
        let r=AccountTransitionRig();r.interruptFails=true;let c=r.coordinator();await c.check();await c.check()
        let restored=r.coordinator(restored:c.state);r.idle(0)
        await restored.check();try expectEqual(restored.state.phase,.stopping)
        try expectEqual(r.effects.count,1);try expectEqual(restored.state.reservations["a"],"turn-a")
    }
    func testAccountTransitionDiscoveryGapReturnsToVerifiedConnectionWithoutManualCancellation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-account-gap-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig();r.idle(0);r.idle(1);r.checkReservations=false
        let targets=AccountTargetList(r.target)
        func create() throws -> ApprovalEngine {try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in targets.read()})}
        var engine=try create();defer{engine.stop()}
        try engine.setCodexAccountTransitionEnabled(true)
        await engine.checkCodexAccountTransitions();await engine.checkCodexAccountTransitions()
        targets.hide();await engine.checkCodexAccountTransitions()
        try expectEqual(engine.codexAccountTransitionStates[r.target.home]?.phase,.reconnecting,"A disappearing socket/process inventory during restart must retain its reconnect window")
        engine.stop();engine=try create()
        r.observation.serverID="server-2";r.observation.serverAccount="new";targets.show()
        await engine.checkCodexAccountTransitions()
        try expectEqual(engine.codexAccountTransitionStates[r.target.home]?.phase,.complete,"Restored restart reservations must reconcile read-only when every original connection is proved")
        try expectEqual(r.effects,["restart"],"Read-only recovery must not repeat a reserved restart")
    }
    func testAccountTransitionStaleNoEffectUnsupportedHomesDoNotKeepShowingErrors() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-account-stale-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig();r.observeFails=true;r.checkReservations=false
        let targets=AccountTargetList(r.target)
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in targets.read()});defer{engine.stop()}
        try engine.setCodexAccountTransitionEnabled(true);await engine.checkCodexAccountTransitions()
        try expectEqual(engine.codexAccountTransitionStates.count,1)
        targets.hide();await engine.checkCodexAccountTransitions()
        try expect(engine.codexAccountTransitionStates.isEmpty,"A vanished unsupported home with no conversation or effect reservation must stop displaying stale RPC failures")
        try expect(r.effects.isEmpty)
    }
    func testAccountTransitionUnknownRestartReconcilesOnlyWithNewServerAndOriginalProof() async throws {
        let r=AccountTransitionRig();r.idle(0);r.idle(1);r.restartFails=true
        let c=r.coordinator();await c.check();await c.check()
        try expectEqual(c.state.phase,.review)
        let restored=r.coordinator(restored:r.saved.last)
        await restored.check();try expectEqual(restored.state.phase,.review)
        r.observation.serverID="server-2";r.observation.serverAccount="new";r.verified=0
        await restored.check();try expectEqual(restored.state.phase,.review)
        r.verified=1;await restored.check()
        try expectEqual(restored.state.phase,.complete,"A lost restart acknowledgement may be resolved by fresh read-only account/history/process proof")
        try expectEqual(r.effects,["restart"])
    }
    func testNativeCodexLoginCannotStartDuringHeldTransition() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-login-gate-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig(),target=r.target,probe=AccountInputProbe()
        let engine=try ApprovalEngine(paths:.init(directory:root.appendingPathComponent("profile")),processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]});defer{engine.stop()}
        let login=AgentAccountServices(home:root.path,check:{agent in .init(agent:agent,phase:"authenticated")},launch:{_ in probe.sent();return try ManagedPTY(cwd:root.path,command:["/bin/zsh","-f","-c","exit 0"],environment:["HOME":root.path,"PATH":"/usr/bin:/bin"])})
        engine.agentAccounts=AgentAccounts(services:login,codexServices:{_ in login})
        try engine.setCodexAccountTransitionEnabled(true);await engine.checkCodexAccountTransitions()
        var rejected=false
        do {try engine.agentAccounts.beginNativeCodexLogin(target)} catch {rejected=true}
        try expect(rejected,"A stale login button must not start authentication while a transition is held")
        try expectEqual(probe.writes,0,"Reject before creating an authentication PTY")
        try engine.cancelCodexAccountTransition(home:target.home)
        try engine.agentAccounts.beginNativeCodexLogin(target)
        try expectEqual(probe.writes,1,"Normal login remains available after the explicit hold is cancelled")
    }
    func testCodexLoginAliasesReachCanonicalServerAndSurviveRestoration() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-login-alias-"+UUID().uuidString)
        let real=root.appendingPathComponent("real-home"),alias=root.appendingPathComponent("alias-home")
        try FileManager.default.createDirectory(at:real,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:real)
        defer{try? FileManager.default.removeItem(at:root)}
        let canonical=real.standardizedFileURL.resolvingSymlinksInPath().path
        for mode in ["native","manual","restored"] {
            let r=AccountTransitionRig();r.target.home=canonical;r.idle(0);r.idle(1);r.observation.savedAccount="old";r.checkReservations=false
            let target=r.target,paths=AppPaths(directory:root.appendingPathComponent("profile-"+mode))
            if mode=="restored" {
                try paths.prepare();let store=try AuditStore(path:paths.database)
                try store.set("codexAccountTransitionEnabled","true")
                try store.set("codexAccountLoginRequests.v1",String(decoding:JSONEncoder().encode([alias.path:UUID().uuidString]),as:UTF8.self))
            }
            let engine=try ApprovalEngine(paths:paths,processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]});defer{engine.stop()}
            if mode=="manual" {try await engine.reconnectCodexLogin(home:alias.path)}
            else if mode=="restored" {await engine.checkCodexAccountTransitions()}
            else {
                let login=AgentAccountServices(home:root.path,check:{agent in .init(agent:agent,phase:"authenticated")},launch:{_ in try ManagedPTY(cwd:root.path,command:["/bin/zsh","-f","-c","exit 0"],environment:["HOME":root.path,"PATH":"/usr/bin:/bin"])})
                engine.agentAccounts=AgentAccounts(services:login,codexServices:{_ in login})
                try engine.agentAccounts.beginNativeCodexLogin(.init(home:alias.path,executable:target.executable))
                for _ in 0..<100 {if engine.codexAccountTransitionStates[canonical]?.phase == .stopping {break};try await Task.sleep(for:.milliseconds(20))}
            }
            try expectEqual(engine.codexAccountTransitionStates[canonical]?.phase,.stopping,"Alias login must reach the canonical shared server: "+mode)
            await engine.checkCodexAccountTransitions();r.observation.serverID="server-2"
            await engine.checkCodexAccountTransitions();try expectEqual(engine.codexAccountTransitionStates[canonical]?.phase,.complete)
            engine.stop()
            let restored=try ApprovalEngine(paths:paths,processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]});defer{restored.stop()}
            await restored.checkCodexAccountTransitions();try expectEqual(r.effects,["restart"],"Alias restoration must not replay an already applied login")
        }
    }
    func testDormantFailedTurnsRemainWaitingWithoutMutationReservations() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-dormant-hold-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let records=ProcessDiscovery.parse("41 1 ttys971 41 41 Wed Oct 21 09:00:00 2026 /fixture/codex")
        var session=AgentSession(id:records[0].key,agent:.codex,pid:41,started:records[0].started,tty:"/dev/ttys971",cwd:"/fixture",terminal:.terminal)
        session.channel = .terminalScreen
        let r=AccountTransitionRig(),probe=AccountInputProbe();r.idle(0);r.idle(1);r.checkReservations=false
        r.target.witnesses=[.init(pid:session.pid,started:session.started,tty:session.tty,threadID:nil)]
        let target=r.target
        func create() throws -> ApprovalEngine {
            let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{records},screenAdapters:[.terminal:probe.adapter],codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]})
            engine.interruptionResumeDelays=[0.02];engine.updateDiscovery([session],records:records);try engine.setAutomatic(session.id,enabled:true);return engine
        }
        var engine=try create();defer{engine.stop()}
        try engine.setCodexAccountTransitionEnabled(true)
        await engine.checkCodexAccountTransitions();await engine.checkCodexAccountTransitions()
        r.observation.serverID="server-2";r.observation.serverAccount="new";await engine.checkCodexAccountTransitions()
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.complete)
        try expect(engine.codexAccountTransitionStates[target.home]?.reservations.isEmpty==true)
        let error="■ Synthetic provider error from dormant failed turn\n\n› Ask Codex to do anything\n\n? for shortcuts"
        for restored in [false,true] {
            if restored {engine.stop();engine=try create()}
            engine.updateCodexQuestions([.init(sessionID:session.id,turn:.init(threadID:"a",turnID:"turn-a",status:"failed"))])
            probe.setScreen(error);engine.receiveScreen(sessionID:session.id,raw:error,generation:restored ? "restored-error":"late-error")
            try await Task.sleep(for:.milliseconds(150))
            try expectEqual(probe.writes,0,"An original dormant failure must remain waiting after completion and app restoration")
        }
        engine.updateCodexQuestions([.init(sessionID:session.id,turn:.init(threadID:"a",turnID:"new-user-turn",status:"failed"))])
        engine.receiveScreen(sessionID:session.id,raw:error,generation:"new-user-turn")
        let deadline=Date().addingTimeInterval(3)
        while probe.writes==0,Date()<deadline {try await Task.sleep(for:.milliseconds(20))}
        try expect(probe.writes>0,"A new user turn must release only the old continuation hold")
    }
    func testAccountTransitionReconnectWindowStartsAfterLifecycleAcknowledgement() async throws {
        let r=AccountTransitionRig();r.idle(0);r.idle(1);r.verified=0
        var services=r.services
        services.restart={_,_ in r.effects.append("restart");try await Task.sleep(for:.milliseconds(60))}
        let c=CodexAccountTransitionCoordinator(target:r.target,services:services,save:{r.saved.append($0)})
        let start=Date()
        await c.check(now:start);await c.check(now:start)
        r.observation.serverID="server-2";r.observation.serverAccount="new"
        await c.check(now:start.addingTimeInterval(120.02))
        try expectEqual(c.state.phase,.reconnecting,"A slow acknowledged server restart must leave the full reconnect window available")
        try expectEqual(r.effects,["restart"])
    }
    func testExplicitCodexReconnectRejectsUnknownHomeBeforeEnablingAutomation() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-explicit-reconnect-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig();r.idle(0);r.idle(1);r.observation.savedAccount="old";r.checkReservations=false
        let target=r.target
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]});defer{engine.stop()}
        var rejected=false
        do {try await engine.reconnectCodexLogin(home:"/unrelated/home")} catch {rejected=true}
        try expect(rejected,"A reconnect request must match a currently connected Codex home")
        try expectFalse(engine.codexAccountTransitionEnabled,"A stale/foreign target must not enable automation")
        try expectEqual(r.observeCount,0)
        try await engine.reconnectCodexLogin(home:target.home)
        await engine.checkCodexAccountTransitions()
        try expectEqual(r.effects,["restart"])
    }
    func testNativeCodexSameAccountReloginStillRefreshesEveryOriginalProcessOnce() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-relogin-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig();r.checkReservations=false
        r.observation.savedAccount="old"
        let target=r.target
        let engine=try ApprovalEngine(paths:.init(directory:root.appendingPathComponent("profile")),processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]})
        defer{engine.stop()}
        let login=AgentAccountServices(home:root.path,check:{agent in .init(agent:agent,phase:"authenticated")},launch:{_ in
            try ManagedPTY(cwd:root.path,command:["/bin/zsh","-f","-c","exit 0"],environment:["HOME":root.path,"PATH":"/usr/bin:/bin"])
        })
        engine.agentAccounts=AgentAccounts(services:login,codexServices:{_ in login})
        try engine.agentAccounts.beginNativeCodexLogin(target)
        let loginDeadline=Date().addingTimeInterval(5)
        while Date()<loginDeadline,engine.agentAccounts.nativeCodexLogin?.phase != "succeeded" || engine.codexAccountTransitionStates[target.home]?.phase != .stopping {
            try await Task.sleep(for:.milliseconds(20))
        }
        try expectEqual(engine.agentAccounts.nativeCodexLogin?.phase,"succeeded","The owned native login fixture must finish before checking application")
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.stopping,"The native completion callback must enable and begin the transition")
        func advance(until ready:()->Bool) async throws {
            let deadline=Date().addingTimeInterval(5)
            repeat {
                await engine.checkCodexAccountTransitions()
                if ready(){return}
                try await Task.sleep(for:.milliseconds(10))
            } while Date()<deadline
            try expect(ready(),"The asynchronous native completion/check must settle before the next transition step")
        }
        try await advance{r.effects.count==1}
        try expectEqual(r.effects,["interrupt:server-1:a:turn-a"],"A successful same-account login must refresh existing authentication instead of being ignored")
        r.idle(0)
        try await advance{r.effects.count==2}
        try expectEqual(r.effects,["interrupt:server-1:a:turn-a","interrupt:server-1:b:turn-b"])
        r.idle(1)
        try await advance{r.effects.last=="restart"}
        try expectEqual(r.effects.last,"restart")
        r.observation.serverID="server-2"
        try await advance{engine.codexAccountTransitionStates[target.home]?.phase == .complete}
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.complete)
        try expectEqual(r.effects.filter{$0=="restart"}.count,1,"The same completed login receipt must not restart twice")
        r.observeFails=true
        await engine.checkCodexAccountTransitions()
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.complete,"A later read-only failure must not freeze every session behind an already completed restart")
        r.observeFails=false
        try await advance{!engine.codexAccountTransitionBusy}
        try expectEqual(r.effects.filter{$0=="restart"}.count,1)
        try await engine.reconnectCodexLogin(home:target.home)
        try await advance{r.effects.filter{$0=="restart"}.count==2}
        try expectEqual(r.effects.filter{$0=="restart"}.count,2,"A later manual reconnect must supersede the completed native login receipt")
        r.observation.serverID="server-3"
        try await advance{engine.codexAccountTransitionStates[target.home]?.phase == .complete}
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.complete)
        try expectEqual(r.effects.filter{$0=="restart"}.count,2,"The old successful native job must not replay after a newer manual reconnect")
        let restored=try ApprovalEngine(paths:.init(directory:root.appendingPathComponent("profile")),processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]})
        defer{restored.stop()}
        await restored.checkCodexAccountTransitions()
        try expectEqual(r.effects.filter{$0=="restart"}.count,2,"App restoration must retain the newest consumed login receipt")
    }
    func testAccountTransitionManualCheckStopsRemainingMutationsOnEngineStop() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-stop-check-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig(),target=r.target
        var events:[String]=[],stop:(()->Void)?
        var services=r.services
        services.interrupt={_,_,_,_ in
            events.append("goal-paused");stop?()
            try Task.checkCancellation()
            events.append("background-terminated");events.append("turn-interrupted")
        }
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:services,codexAccountTargets:{_ in [target]})
        stop={ [weak engine] in engine?.stop() };defer{engine.stop()}
        try engine.setCodexAccountTransitionEnabled(true)
        await engine.checkCodexAccountTransitions();await engine.checkCodexAccountTransitions()
        try expectEqual(events,["goal-paused"],"Engine stop must cancel remaining writes from a manual check")
        let restored=try ApprovalEngine(paths:.init(directory:root),processReader:{[]});defer{restored.stop()}
        try expectEqual(restored.codexAccountTransitionStates[target.home]?.phase,.review)
        try expectNotNil(restored.codexAccountTransitionStates[target.home]?.reservations["a"])
    }
    func testAccountTransitionQuiescesWorkersThenPreservesQueueBarrier() async throws {
        let r=AccountTransitionRig();r.idle(0);r.idle(1)
        r.observation.threads[0].blocker="활성 Goal"
        let c=r.coordinator();await c.check();await c.check()
        r.observation.threads[0].blocker="백그라운드 작업";await c.check()
        try expectEqual(c.state.waitingThread,"a")
        r.observation.threads[0].blocker="대기 입력";await c.check();await c.check()
        try expectEqual(c.state.phase,.waiting);try expectFalse(c.state.restartReserved)
        try expectEqual(r.effects.count,1);try expect(c.state.detail.contains("대기 입력"))
    }
    func testAccountTransitionOffscreenConversationsDoNotNeedToStayLoaded() async throws {
        let r=AccountTransitionRig();r.idle(0);r.idle(1);let c=r.coordinator()
        await c.check();await c.check()
        r.observation.serverID="server-2";r.observation.serverAccount="new"
        r.observation.threads.removeLast()
        await c.check()
        try expectEqual(c.state.phase,.complete,"Persisted offscreen conversations need not be reattached by a TUI before account application completes")
    }
    #if DEBUG
    func testNativeLoginCompletionReceiptBindsBeforeItsDeferredCallback() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-login-race-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let marker=root.appendingPathComponent("finish"),r=AccountTransitionRig(),target=r.target
        r.idle(0);r.idle(1);r.checkReservations=false
        let engine=try ApprovalEngine(paths:.init(directory:root.appendingPathComponent("profile")),processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]});defer{engine.stop()}
        let login=AgentAccountServices(home:root.path,check:{agent in .init(agent:agent,phase:"authenticated")},launch:{_ in
            try ManagedPTY(cwd:root.path,command:["/bin/zsh","-f","-c","while [[ ! -f \"$1\" ]]; do /bin/sleep 0.02; done","owned-login",marker.path],environment:["HOME":root.path,"PATH":"/usr/bin:/bin"])
        })
        engine.agentAccounts=AgentAccounts(services:login,codexServices:{_ in login})
        let forward=engine.agentAccounts.nativeCodexLoginCompleted
        var delayedHome:String?
        engine.agentAccounts.nativeCodexLoginCompleted={delayedHome=$0}
        try engine.setCodexAccountTransitionEnabled(true);try engine.agentAccounts.beginNativeCodexLogin(target)
        await engine.checkCodexAccountTransitions()
        try expectEqual(r.observeCount,0,"Passive polling must wait for the native ceremony to finish")
        try Data().write(to:marker)
        for _ in 0..<100 {if engine.agentAccounts.nativeCodexLogin?.phase=="succeeded" {break};try await Task.sleep(for:.milliseconds(20))}
        await engine.checkCodexAccountTransitions()
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.loginRequestID,engine.agentAccounts.nativeCodexLogin?.id,"The observed successful login must bind before its queued completion callback")
        try expectNotNil(delayedHome);forward?(delayedHome!)
        for _ in 0..<10 {await engine.checkCodexAccountTransitions();if r.effects.contains("restart"){break};await Task.yield()}
        r.observation.serverID="server-2";r.observation.serverAccount="new"
        for _ in 0..<6 {await engine.checkCodexAccountTransitions();await Task.yield()}
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.complete)
        try expectEqual(r.effects,["restart"],"Late completion must not turn one native login into a second refresh")
    }
    func testNativeCodexLoginReplacementInvalidatesAlreadyQueuedCompletion() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-native-replace-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig(),target=r.target
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]});defer{engine.stop()}
        let old=engine.agentAccounts
        old.nativeCodexLoginCompleted?(target.home)
        engine.agentAccounts=AgentAccounts()
        for _ in 0..<10 {await Task.yield()}
        try expectFalse(engine.codexAccountTransitionEnabled,"An old manager's queued completion must not enable the replacement manager")
        try expectEqual(r.observeCount,0)
    }
    func testNativeCodexLoginWakesPollingWithoutWaitingThirtySeconds() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-wake-"+UUID().uuidString.prefix(8))
        defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig(),target=r.target
        r.checkReservations=false
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]});defer{engine.stop()}
        try engine.start()
        try await Task.sleep(for:.milliseconds(100))
        engine.agentAccounts.nativeCodexLoginCompleted?(target.home)
        for _ in 0..<100 {if !r.effects.isEmpty {break};try await Task.sleep(for:.milliseconds(20))}
        try expectFalse(r.effects.isEmpty,"Native login must wake the parked poller without a thirty-second hold")
    }
    #endif
    func testAccountTransitionQuiescesIdleGoalAndBackgroundWorkOnce() async throws {
        for reason in ["활성 Goal","백그라운드 작업"] {
            let r=AccountTransitionRig();r.idle(0);r.idle(1)
            r.observation.threads[0].turnID=nil;r.observation.threads[0].blocker=reason
            let c=r.coordinator();await c.check();await c.check();await c.check()
            try expectEqual(r.effects.count,1,"Idle owned work must receive one normal quiesce request")
            try expectNotNil(c.state.reservations["a"])
            try expectFalse(c.state.restartReserved)
            r.observation.threads[0].blocker=nil
            await c.check();await c.check()
            try expectEqual(r.effects.filter{$0=="restart"}.count,1)
        }
    }
    func testAccountTransitionMissingConversationProofStopsBeforeAnyEffect() async throws {
        let r=AccountTransitionRig();r.idle(0);r.idle(1)
        r.target.witnesses=[.init(pid:42,started:"first",tty:"/dev/fixture",threadID:nil),.init(pid:43,started:"second",tty:"/dev/fixture-empty",threadID:nil)]
        r.verified=2;let c=r.coordinator()
        await c.check();await c.check()
        try expectEqual(c.state.phase,.reconnecting)
        r.observation.serverID="server-2";r.observation.serverAccount="new"
        r.observation.threads.removeLast();r.persistedThreads.remove("b");await c.check()
        try expectEqual(c.state.phase,.reconnecting,"All original conversations must remain readable, even when every process reconnects")
        r.observation.threads.append(.init(id:"b",turnID:"turn-b"))
        r.persistedThreads.insert("b")
        await c.check();try expectEqual(c.state.phase,.complete)
        try expectEqual(c.state.verified,2);try expectEqual(r.effects,["restart"])
    }
    func testAccountTransitionReconnectionFreshBarrierRejectsAccountAndMembershipRaces() async throws {
        for mutation in ["account","server","thread","active","queue"] {
            let r=AccountTransitionRig();r.idle(0);r.idle(1);let c=r.coordinator()
            await c.check();await c.check()
            r.observation.serverID="server-2";r.observation.serverAccount="new"
            let next=r.observeCount+2
            r.mutateOnObserve={ n in
                guard n==next else{return}
                switch mutation {
                case "account":r.observation.serverAccount="other"
                case "server":r.observation.serverID="server-3"
                case "thread":r.observation.threads[0].id="foreign"
                case "active":r.observation.threads[0].active=true
                default:r.observation.threads[0].blocker="queued input"
                }
            }
            await c.check();try expectEqual(c.state.phase,.review)
            try expectEqual(r.effects,["restart"],"A fresh reconnect race must never replay the restart")
        }
    }
    func testNativeCodexLoginStartsAllSessionTransitionWithoutAnySettingsView() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-login-apply-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let r=AccountTransitionRig();r.idle(0);r.idle(1);r.checkReservations=false
        r.target.witnesses=[.init(pid:42,started:"first",tty:"/dev/fixture",threadID:nil),.init(pid:43,started:"second",tty:"/dev/fixture-empty",threadID:nil)];r.verified=2
        let target=r.target
        let engine=try ApprovalEngine(paths:.init(directory:root.appendingPathComponent("profile")),processReader:{[]},codexAccountTransitions:r.services,codexAccountTargets:{_ in [target]});defer{engine.stop()}
        let services=AgentAccountServices(home:root.path,check:{agent in .init(agent:agent,phase:"authenticated")},launch:{_ in
            try ManagedPTY(cwd:root.path,command:["/bin/zsh","-f","-c","exit 0"],environment:["HOME":root.path,"PATH":"/usr/bin:/bin"])
        })
        engine.agentAccounts=AgentAccounts(services:services,codexServices:{_ in services})
        try expectFalse(engine.codexAccountTransitionEnabled)
        try engine.agentAccounts.beginNativeCodexLogin(target)
        for _ in 0..<100 {if engine.codexAccountTransitionStates[target.home]?.phase == .stopping {break};try await Task.sleep(for:.milliseconds(20))}
        try expect(engine.codexAccountTransitionEnabled,"Successful native login must start application without a settings view")
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.stopping)
        let restartDeadline=Date().addingTimeInterval(5)
        while Date()<restartDeadline,engine.codexAccountTransitionStates[target.home]?.phase != .reconnecting {
            await engine.checkCodexAccountTransitions()
            try await Task.sleep(for:.milliseconds(10))
        }
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.reconnecting,"Wait for the in-flight native completion check to release before changing server evidence")
        try expectEqual(r.effects,["restart"])
        r.observation.serverID="server-2";r.observation.serverAccount="new"
        let connectedDeadline=Date().addingTimeInterval(5)
        while Date()<connectedDeadline,engine.codexAccountTransitionStates[target.home]?.phase != .complete {
            await engine.checkCodexAccountTransitions()
            try await Task.sleep(for:.milliseconds(10))
        }
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.phase,.complete)
        try expectEqual(engine.codexAccountTransitionStates[target.home]?.verified,2)
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
        let r = AccountTransitionRig(); r.checkReservations = false
        let targets = AccountTargetList(r.target)
        let engine = try ApprovalEngine(paths: .init(directory: root), processReader: { [] },
            codexAccountTransitions: r.services, codexAccountTargets: { _ in targets.read() })
        defer { engine.stop() }
        try engine.setCodexAccountTransitionEnabled(true)
        await engine.checkCodexAccountTransitions(); await engine.checkCodexAccountTransitions()
        try expectEqual(engine.codexAccountTransitionStates[r.target.home]?.phase, .waiting)
        targets.hide(); await engine.checkCodexAccountTransitions()
        try expectEqual(engine.codexAccountTransitionStates[r.target.home]?.phase, .review)
        try engine.cancelCodexAccountTransition(home: r.target.home)
        try engine.setCodexAccountTransitionEnabled(false)
        try expectFalse(engine.codexAccountTransitionHeld)
        targets.show(); try engine.setCodexAccountTransitionEnabled(true)
        await engine.checkCodexAccountTransitions()
        try expectEqual(r.effects, ["interrupt:server-1:a:turn-a"], "Rediscovery must not repeat a reserved interruption")
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
            try expectEqual(r.effects.count,reason == "대기 입력" ? 0:1)
            try expectEqual(c.state.phase, .waiting)
            if reason == "대기 입력" {try expect(c.state.detail.contains(reason))}
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
