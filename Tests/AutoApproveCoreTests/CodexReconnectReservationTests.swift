import Foundation
import AutoApproveCore

@MainActor private final class ReconnectLookupGate {
    var calls=0,entered=false,released=false
    private var continuation:CheckedContinuation<Void,Never>?
    func wait() async {entered=true;if released{return};await withCheckedContinuation{continuation=$0}}
    func read(_ target:CodexAccountTransitionTarget) async->[CodexAccountTransitionTarget] {
        calls+=1;if calls==1 {await wait()};return [target]
    }
    func release() {released=true;continuation?.resume();continuation=nil}
}
@MainActor private func waitForReconnectLookup(_ gate:ReconnectLookupGate) async throws {
    let deadline=ContinuousClock.now.advanced(by:.seconds(5))
    while !gate.entered,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
    try expect(gate.entered,"The synthetic lookup must suspend before the concurrent check")
}

extension ApprovalTests {
    func testManualCodexReconnectReservesLookupBeforeAutomaticInspection() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-reconnect-race-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let rig=AccountTransitionRig();rig.idle(0);rig.idle(1);rig.observation.savedAccount="old";rig.checkReservations=false
        let target=rig.target,lookup=ReconnectLookupGate(),inspection=ReconnectLookupGate()
        var services=rig.services;let observe=services.observe
        services.observe={target in await inspection.wait();return try await observe(target)}
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:services,codexAccountTargets:{_ in await lookup.read(target)})
        defer{lookup.release();inspection.release();engine.stop()}
        try engine.setCodexAccountTransitionEnabled(true)
        let manual=Task {try await engine.reconnectCodexLogin(home:target.home)}
        try await waitForReconnectLookup(lookup)
        let automatic=Task {await engine.checkCodexAccountTransitions()}
        try await Task.sleep(for:.milliseconds(100))
        let overlapped=inspection.entered
        lookup.release();inspection.release()
        let result=await manual.result;await automatic.value
        try expectFalse(overlapped,"An automatic check must not take ownership while a manual reconnect validates its home")
        try result.get()
        try expectFalse(engine.codexAccountTransitionBusy)
        await engine.checkCodexAccountTransitions()
        try expectEqual(rig.effects.filter{$0=="restart"}.count,1)
    }
    func testConcurrentManualCodexReconnectCannotCreateAnotherLookupOrReceipt() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-reconnect-double-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let rig=AccountTransitionRig();rig.idle(0);rig.idle(1);rig.observation.savedAccount="old";rig.checkReservations=false
        let target=rig.target,lookup=ReconnectLookupGate()
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:rig.services,codexAccountTargets:{_ in await lookup.read(target)})
        defer{lookup.release();engine.stop()}
        let first=Task {try await engine.reconnectCodexLogin(home:target.home)}
        try await waitForReconnectLookup(lookup)
        var rejected=false
        do {try await engine.reconnectCodexLogin(home:target.home)}catch{rejected=true}
        let calls=lookup.calls
        lookup.release();let result=await first.result
        try expect(rejected,"A second reconnect must be rejected before inspecting or storing another intent")
        try expectEqual(calls,1)
        try result.get()
        await engine.checkCodexAccountTransitions()
        try expectEqual(rig.effects.filter{$0=="restart"}.count,1)
    }
    func testManualCodexReconnectCancellationAndStopReleaseLookupWithoutEffects() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-reconnect-cancel-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        for stop in [false,true] {
            let rig=AccountTransitionRig(),target=rig.target,lookup=ReconnectLookupGate()
            let engine=try ApprovalEngine(paths:.init(directory:root.appendingPathComponent(stop ? "stop":"cancel")),processReader:{[]},codexAccountTransitions:rig.services,codexAccountTargets:{_ in await lookup.read(target)})
            defer{lookup.release();engine.stop()}
            let task=Task {try await engine.reconnectCodexLogin(home:target.home)}
            try await waitForReconnectLookup(lookup)
            if stop {engine.stop()} else {task.cancel()}
            lookup.release()
            if case .success=await task.result {throw AppError.message("Cancelled/stopped lookup cannot reconnect")}
            try expectFalse(engine.codexAccountTransitionBusy)
            try expectFalse(engine.codexAccountTransitionEnabled)
            try expectEqual(rig.observeCount,0);try expect(rig.effects.isEmpty)
        }
    }
    func testUnverifiedCodexServerNoticeDoesNotClaimServerIsAbsent() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-reconnect-notice-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let rig=AccountTransitionRig()
        let engine=try ApprovalEngine(paths:.init(directory:root),processReader:{[]},codexAccountTransitions:rig.services,codexAccountTargets:{_ in []})
        defer{engine.stop()}
        try engine.setCodexAccountTransitionEnabled(true);await engine.checkCodexAccountTransitions()
        try expect(engine.codexAccountTransitionNotice?.contains("확인") == true)
        try expectFalse(engine.codexAccountTransitionNotice?.contains("없습니다") == true,"An unproven connection is not evidence that no managed server exists")
        try expectEqual(rig.observeCount,0);try expect(rig.effects.isEmpty)
    }
    func testManualCodexReconnectUsesEachMachineHomeAndExecutableWithoutGuessing() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/aa-reconnect-profiles-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        let profiles=[("/Users/alex/.codex","/opt/homebrew/bin/codex"),("/Users/서연/Library/Application Support/Codex data","/usr/local/bin/codex"),("/Volumes/Workspace/users/team/.codex","/Users/team/.local/bin/codex")]
        for (index,profile) in profiles.enumerated() {
            let rig=AccountTransitionRig();rig.target.home=try CodexAccountTransitionTarget.canonicalHome(profile.0);rig.target.executable=profile.1
            rig.idle(0);rig.idle(1);rig.observation.savedAccount="old";rig.checkReservations=false
            let target=rig.target
            var services=rig.services;let observe=services.observe
            services.observe={received in
                try expectEqual(received.executable,profile.1,"Use this machine's verified executable without a fixed install directory")
                return try await observe(received)
            }
            let engine=try ApprovalEngine(paths:.init(directory:root.appendingPathComponent(String(index))),processReader:{[]},codexAccountTransitions:services,codexAccountTargets:{_ in [target]})
            defer{engine.stop()}
            var rejected=false
            do {try await engine.reconnectCodexLogin(home:"/Users/another-machine/.codex")}catch{rejected=true}
            try expect(rejected);try expectFalse(engine.codexAccountTransitionEnabled);try expectEqual(rig.observeCount,0)
            try await engine.reconnectCodexLogin(home:profile.0);await engine.checkCodexAccountTransitions()
            try expectEqual(rig.effects,["restart"])
            try expect(rig.observeCount>0)
        }
    }
}
