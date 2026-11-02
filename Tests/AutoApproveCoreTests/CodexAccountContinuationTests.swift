import Foundation
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif

@MainActor private func continuationRig() -> AccountTransitionRig {
    let r=AccountTransitionRig()
    for index in r.observation.threads.indices {r.observation.threads[index].continuable=true}
    r.observation.threads[0].goal = .init(threadId:"a",objective:"Finish original work",status:.active,createdAt:10,updatedAt:10,tokenBudget:10000)
    r.observation.threads.append(.init(id:"c",turnID:"turn-c",continuable:true,goal:.init(threadId:"c",objective:"Already paused",status:.paused,createdAt:20,updatedAt:20)))
    r.persistedThreads.insert("c")
    r.services.interrupt={_,_,id,token in
        try expectEqual(r.saved.last?.reservations[id],token)
        r.effects.append("stop:"+id)
        let index=r.observation.threads.firstIndex(where:{$0.id==id})!
        r.observation.threads[index].active=false
        if r.observation.threads[index].goal?.status == .active {r.observation.threads[index].goal?.status = .paused}
    }
    r.services.resume={_,_,original,receipt in
        try expectEqual(r.saved.last?.resumeReservations?[original.id],receipt,"A continuation must be durable before dispatch")
        try expectNotNil(UUID(uuidString:receipt))
        r.effects.append("resume:"+original.id)
        let index=r.observation.threads.firstIndex(where:{$0.id==original.id})!
        r.observation.threads[index].active=true;r.observation.threads[index].turnID="continued-"+original.id
        if original.goal?.status == .active {r.observation.threads[index].goal?.status = .active;return .goal}
        return .conversation
    }
    return r
}
@MainActor private func reachContinuation(_ r:AccountTransitionRig,_ c:CodexAccountTransitionCoordinator) async throws {
    for _ in 0..<20 {
        if c.state.phase == .reconnecting {r.observation.serverID="server-2";r.observation.serverAccount="new"}
        await c.check()
        if c.state.phase == .resuming {return}
    }
    try expectEqual(c.state.phase,.resuming,"Only fully verified reconnection may enter automatic continuation")
}

extension ApprovalTests {
    func testAccountContinuationUsageAccountingDoesNotInvalidateIdleRestartBarrier() async throws {
        let r=AccountTransitionRig();r.idle(0);r.idle(1)
        r.observation.threads[0].goal = .init(threadId:"a",objective:"Paused original",status:.paused,createdAt:10,updatedAt:10,tokensUsed:100)
        r.mutateOnObserve={_ in r.observation.threads[0].goal?.tokensUsed+=1;r.observation.threads[0].goal?.updatedAt+=1}
        let c=r.coordinator();await c.check();await c.check()
        try expectEqual(c.state.phase,.reconnecting,"Usage flushing on an already paused Goal must not look like replacement work")
        try expectEqual(r.effects,["restart"])
    }
    func testAccountContinuationResumesOnlyReservedOriginalWorkOnce() async throws {
        let r=continuationRig()
        var c=r.coordinator()
        try await reachContinuation(r,c)
        try expectEqual(r.effects,["stop:a","stop:b","restart"])
        await c.check()
        let partial=try JSONDecoder().decode(CodexAccountTransitionState.self,from:JSONEncoder().encode(c.state))
        c=r.coordinator(restored:partial)
        for _ in 0..<4 {await c.check()}
        try expectEqual(c.state.phase,.complete)
        try expectEqual(r.effects,["stop:a","stop:b","restart","resume:a","resume:b"])
        try expectEqual(c.state.resumeResults?["a"],.goal)
        try expectEqual(c.state.resumeResults?["b"],.conversation)
        try expect(c.state.resumeResults?["c"]==nil,"Already paused idle work must never gain a continuation request")
        let saved=try JSONDecoder().decode(CodexAccountTransitionState.self,from:JSONEncoder().encode(c.state))
        let restored=r.coordinator(restored:saved)
        for _ in 0..<3 {await restored.check()}
        try expectEqual(r.effects.count,5,"Completed continuation receipts must survive restoration without replay")
    }
    func testAccountContinuationUnknownAcknowledgementNeverReplaysOrResumesTheNextThread() async throws {
        let r=continuationRig()
        r.services.resume={_,_,thread,id in
            try expectEqual(r.saved.last?.resumeReservations?[thread.id],id)
            r.effects.append("unknown-resume:"+thread.id)
            throw AppError.message("delivered but acknowledgement lost")
        }
        let c=r.coordinator();try await reachContinuation(r,c);await c.check()
        try expectEqual(c.state.phase,.review)
        let restored=r.coordinator(restored:r.saved.last)
        for _ in 0..<3 {await restored.check()}
        try expectEqual(r.effects,["stop:a","stop:b","restart","unknown-resume:a"])
        try restored.cancel();await restored.check()
        try expectEqual(r.effects.count,4)
    }
    func testAccountContinuationPersistenceFailureAndCancellationPrecedeAnyWrite() async throws {
        for failSave in [false,true] {
            let r=continuationRig(),c=r.coordinator();try await reachContinuation(r,c)
            if failSave {r.saveFails=true;await c.check()} else {try c.cancel();await c.check()}
            try expectEqual(r.effects,["stop:a","stop:b","restart"],"A failed reservation or cancellation must precede every continuation write")
        }
    }
    func testAccountContinuationChangedAccountAndLegacyJournalsNeverAcquireNewAuthorization() async throws {
        for legacy in [false,true] {
            let r=continuationRig(),c=r.coordinator();try await reachContinuation(r,c)
            if legacy {
                var saved=c.state;saved.resumeEnabled=nil;saved.resumeServerID=nil;saved.phase = .reconnecting
                let restored=r.coordinator(restored:saved);await restored.check()
                try expectEqual(restored.state.phase,.complete)
            } else {
                r.observation.savedAccount="changed-account";await c.check()
                try expectEqual(c.state.phase,.review)
            }
            try expectEqual(r.effects,["stop:a","stop:b","restart"],"Neither a changed account nor an old journal authorizes an automatic prompt")
        }
    }
}
