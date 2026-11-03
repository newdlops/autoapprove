import Foundation
import AutoApproveCore

@MainActor private final class ManagedServerGate {
    var entered=false,released=false,calls=0,effects=0
    private var continuation:CheckedContinuation<Void,Never>?
    func wait() async {calls+=1;entered=true;if !released {await withCheckedContinuation{continuation=$0}}}
    func release() {released=true;continuation?.resume();continuation=nil}
    func finish() throws ->CodexManagedServerStatus {try Task.checkCancellation();effects+=1;return .init(phase:.running,version:"0.166.0",detail:"Synthetic server")}
}

extension ApprovalTests {
    func testAutomaticManagedServerFailureDoesNotRepeat() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-auto-failure-"+UUID().uuidString),gate=ManagedServerGate()
        defer{try? FileManager.default.removeItem(at:root)}
        gate.release()
        let services=CodexManagedServerServices(inspect:{_,_ in .init(phase:.stopped,detail:"Synthetic")},prepare:{_,_ in await gate.wait();throw AppError.message("Synthetic failure")})
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexManagedServers:services)
        defer{engine.stop()}
        await engine.ensureCodexManagedServers();await engine.ensureCodexManagedServers()
        try expectEqual(gate.calls,1);try expect(engine.codexAccountTransitionNotice != nil)
        try expectFalse(engine.codexAccountTransitionBusy)
    }
    func testAutomaticManagedServerPreparationOnce() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-auto-server-"+UUID().uuidString),gate=ManagedServerGate()
        defer{try? FileManager.default.removeItem(at:root)}
        gate.release()
        let services=CodexManagedServerServices(inspect:{_,_ in .init(phase:.stopped,detail:"Synthetic")},prepare:{_,_ in await gate.wait();return try await gate.finish()})
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexManagedServers:services)
        defer{engine.stop()}
        await engine.ensureCodexManagedServers();await engine.ensureCodexManagedServers()
        try expectEqual(gate.calls,1);try expectEqual(gate.effects,1)
        try expectFalse(engine.codexAccountTransitionEnabled)
        engine.stop();await engine.ensureCodexManagedServers();try expectEqual(gate.calls,1)
    }
    func testManagedServerPreparationSerializesWithAccountControl() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-setup-engine-"+UUID().uuidString),gate=ManagedServerGate(),rig=AccountTransitionRig()
        defer{try? FileManager.default.removeItem(at:root)}
        let services=CodexManagedServerServices(inspect:{_,_ in .init(phase:.stopped,detail:"Synthetic")},prepare:{_,_ in await gate.wait();return try await gate.finish()})
        let target=rig.target
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:rig.services,codexAccountTargets:{_ in [target]},codexManagedServers:services)
        defer{gate.release();engine.stop()}
        let task=Task {try await engine.prepareCodexManagedServer(home:target.home)}
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while !gate.entered,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        try expect(gate.entered);try expect(engine.codexAccountTransitionBusy)
        await engine.checkCodexAccountTransitions();try expectEqual(rig.observeCount,0)
        var duplicate=false,reconnect=false
        do {_ = try await engine.prepareCodexManagedServer(home:target.home)}catch{duplicate=true}
        do {try await engine.reconnectCodexLogin(home:target.home)}catch{reconnect=true}
        gate.release();let state=try await task.value
        try expect(duplicate && reconnect);try expectEqual(gate.calls,1);try expectEqual(gate.effects,1)
        try expectEqual(state.phase,.running);try expectFalse(engine.codexAccountTransitionBusy)
        try expectFalse(engine.codexAccountTransitionEnabled,"Preparing a daemon does not opt into account switching")
    }
    func testManagedServerPreparationCancellationAndManagerStop() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-setup-cancel-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        for stop in [false,true] {
            let gate=ManagedServerGate()
            let services=CodexManagedServerServices(inspect:{_,_ in .init(phase:.stopped,detail:"Synthetic")},prepare:{_,_ in await gate.wait();return try await gate.finish()})
            let engine=try ApprovalEngine(paths:.init(directory:root.appendingPathComponent(stop ? "stop":"cancel")),processReader:{[]},codexManagedServers:services)
            defer{gate.release();engine.stop()}
            let task=Task {try await engine.prepareCodexManagedServer(home:"/fixture/.codex")}
            let deadline=ContinuousClock.now.advanced(by:.seconds(5))
            while !gate.entered,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
            try expect(gate.entered)
            if stop {engine.stop()} else {task.cancel()}
            gate.release()
            if case .success=await task.result {throw AppError.message("Cancelled preparation cannot claim success")}
            try expectEqual(gate.effects,0);try expectFalse(engine.codexAccountTransitionBusy)
        }
    }
    func testPreparedServerWithoutOriginalClientsDoesNotAuthorizeReconnect() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-setup-unbound-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let state=CodexManagedServerStatus(phase:.running,version:"0.166.0",detail:"Synthetic server")
        let services=CodexManagedServerServices(inspect:{_,_ in state},prepare:{_,_ in state})
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTargets:{_ in []},codexManagedServers:services)
        defer{engine.stop()}
        let prepared=try await engine.prepareCodexManagedServer(home:"/fixture/.codex")
        try expectEqual(prepared.phase,.running)
        var rejected=false
        do {try await engine.reconnectCodexLogin(home:"/fixture/.codex")}catch{rejected=true}
        try expect(rejected);try expectFalse(engine.codexAccountTransitionEnabled)
        try expect(engine.codexAccountTransitionStates.isEmpty)
    }
}
