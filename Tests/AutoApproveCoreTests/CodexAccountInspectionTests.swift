import Foundation
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif

@MainActor private final class InspectionGate {
    var calls=0
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    func read(_ target:CodexAccountTransitionTarget) async ->CodexAccountInspection {
        calls+=1;await withCheckedContinuation{waiters.append($0)}
        return .init(home:target.home,identity:.init(provider:"ChatGPT",email:"current@example.test",plan:"pro"),comparison:.different,connectedSessions:target.witnesses.count)
    }
    func release(){let saved=waiters;waiters=[];for waiter in saved{waiter.resume()}}
    func entered() async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(5))
        while calls==0,ContinuousClock.now<end {try await Task.sleep(for:.milliseconds(10))}
        guard calls>0 else{throw AppError.message("Owned inspection did not enter")}
    }
}
private final class InspectionTargets:@unchecked Sendable {
    private let lock=NSLock()
    private var targets:[CodexAccountTransitionTarget]
    init(_ target:CodexAccountTransitionTarget){targets=[target]}
    func read()->[CodexAccountTransitionTarget]{lock.lock();defer{lock.unlock()};return targets}
    func replace(_ target:CodexAccountTransitionTarget){lock.lock();targets=[target];lock.unlock()}
}
extension ApprovalTests {
    private func inspectionFixture()->(URL,[ProcessRecord],CodexAccountTransitionTarget) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-inspection-"+UUID().uuidString)
        let rows=ProcessDiscovery.parse("4242 1 ttys142 4242 4242 Wed Nov 4 00:00:01 2026 /fixture/bin/codex")
        let row=rows[0]
        return (root,rows,.init(home:root.appendingPathComponent("codex-home").path,executable:"/fixture/bin/codex",witnesses:[.init(pid:row.pid,started:row.started,tty:"/dev/"+row.tty,threadID:nil)]))
    }
    func testAccountInspectionMismatchNeverAdvancesEnabledTransition() async throws {
        let (root,rows,target)=inspectionFixture();defer{try? FileManager.default.removeItem(at:root)}
        let rig=AccountTransitionRig();rig.target=target
        let reader=CodexAccountInspectionServices(read:{target in .init(home:target.home,identity:.init(provider:"ChatGPT"),comparison:.different,connectedSessions:target.witnesses.count)})
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{rows},codexAccountTransitions:rig.services,codexAccountTargets:{_ in [target]},codexAccountInspections:reader);defer{engine.stop()}
        try engine.setCodexAccountTransitionEnabled(true)
        let result=try await engine.inspectCodexAccount(home:target.home)
        try expectEqual(result.comparison,.different)
        try expectEqual(rig.effects,[]);try expectEqual(rig.observeCount,0)
        try expect(engine.codexAccountTransitionStates.isEmpty);try expectFalse(engine.codexAccountTransitionBusy)
        try expect(engine.codexAccountTransitionEnabled)
    }
    func testAccountInspectionAvailableWithAutomaticSwitchingOff() async throws {
        let(root,rows,target)=inspectionFixture();defer{try? FileManager.default.removeItem(at:root)}
        let service=CodexAccountInspectionServices(read:{t in .init(home:t.home,identity:.init(provider:"ChatGPT"),comparison:.same,connectedSessions:t.witnesses.count)})
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{rows},codexAccountTargets:{_ in [target]},codexAccountInspections:service);defer{engine.stop()}
        let result=try await engine.inspectCodexAccount(home:target.home)
        try expectEqual(result.comparison,.same);try expectFalse(engine.codexAccountTransitionEnabled)
        try expect(engine.codexAccountTransitionStates.isEmpty)
    }
    func testAccountInspectionCoalescesAndCallerCancellationIsIndependent() async throws {
        let(root,rows,target)=inspectionFixture(),gate=InspectionGate();defer{gate.release();try? FileManager.default.removeItem(at:root)}
        let service=CodexAccountInspectionServices(read:{await gate.read($0)})
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{rows},codexAccountTargets:{_ in [target]},codexAccountInspections:service);defer{engine.stop()}
        let a=Task{try await engine.inspectCodexAccount(home:target.home)}
        let b=Task{try await engine.inspectCodexAccount(home:target.home)}
        try await gate.entered();try await Task.sleep(for:.milliseconds(100))
        try expectFalse(engine.codexAccountTransitionBusy)
        a.cancel();gate.release()
        if case .success=await a.result {throw AppError.message("Cancelled consumer received a successful account check")}
        let result=try await b.value
        try expectEqual(result.comparison,.different);try expectEqual(gate.calls,1)
    }
    func testAccountInspectionRejectsChangedMembershipAndEngineStop() async throws {
        for stop in [false,true] {
            let(root,rows,target)=inspectionFixture(),gate=InspectionGate(),targets=InspectionTargets(target)
            defer{gate.release();try? FileManager.default.removeItem(at:root)}
            let service=CodexAccountInspectionServices(read:{await gate.read($0)})
            let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{rows},codexAccountTargets:{_ in targets.read()},codexAccountInspections:service);defer{engine.stop()}
            let task=Task{try await engine.inspectCodexAccount(home:target.home)}
            try await gate.entered()
            if stop{engine.stop()}else{var changed=target;changed.witnesses[0].pid=9999;targets.replace(changed)}
            gate.release()
            if case .success=await task.result {throw AppError.message("Stale or stopped inspection was accepted")}
            try expectFalse(engine.codexAccountTransitionBusy);try expect(engine.codexAccountTransitionStates.isEmpty)
        }
    }
    func testAccountInspectionCannotFinishWithPreLoginAccountAfterLoginStarts() async throws {
        let(root,rows,target)=inspectionFixture(),gate=InspectionGate()
        defer{gate.release();try? FileManager.default.removeItem(at:root)}
        let service=CodexAccountInspectionServices(read:{await gate.read($0)})
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{rows},codexAccountTargets:{_ in [target]},codexAccountInspections:service)
        defer{engine.stop()}
        let auth=AgentAccountServices(home:root.path,check:{_ in .init(agent:"codex",phase:"authenticated")},launch:{_ in
            try ManagedPTY(cwd:root.path,command:["/bin/sleep","30"],environment:["HOME":root.path,"PATH":"/usr/bin:/bin"])
        })
        engine.agentAccounts=AgentAccounts(services:auth,codexServices:{_ in auth})
        let checking=Task{try await engine.inspectCodexAccount(home:target.home)}
        try await gate.entered()
        try engine.agentAccounts.beginNativeCodexLogin(target)
        try expect(engine.agentAccounts.busy,"An observation must not block beginning login")
        gate.release()
        if case .success=await checking.result {throw AppError.message("Pre-login account observation became current after login started")}
        try expect(engine.codexAccountTransitionStates.isEmpty)
    }
}

