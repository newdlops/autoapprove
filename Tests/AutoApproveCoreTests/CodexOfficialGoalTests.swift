#if DEBUG
import Foundation
@testable import AutoApproveCore

@MainActor private final class GoalRecoveryProbe {
    var current:CodexSubagentGoal
    var changes=0
    init(_ current:CodexSubagentGoal){self.current=current}
}

extension ApprovalTests {
    func testEngineGoalRecoveryReconcilesColdIntentsAndRejectsSupersededGoals() async throws {
        for scenario in ["needed","already","replaced","superseded"] {
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("aa-engine-goal-recover-"+UUID().uuidString)
            let paths=AppPaths(directory:directory);try paths.prepare()
            defer{try? FileManager.default.removeItem(at:directory)}
            let root=UUID().uuidString.lowercased(),child=UUID().uuidString.lowercased()
            let original=CodexGoal(threadId:child,objective:"Persist this desired pause",status:.active,createdAt:100,updatedAt:100,instanceID:UUID().uuidString)
            let expected=CodexSubagentGoal(rootThreadID:root,threadID:child,parentThreadID:root,goal:original,executionState:"idle")
            let probe=GoalRecoveryProbe(expected)
            if scenario=="already" {probe.current.goal?.status = .paused}
            if scenario=="replaced" {probe.current.goal?.instanceID=UUID().uuidString}
            let records=ProcessDiscovery.parse("2000000000 1 ttys991 2000000000 2000000000 Mon Nov 2 10:00:00 2026 /owned/codex")
            let record=records[0],session=AgentSession(id:record.key,agent:.codex,pid:record.pid,started:record.started,tty:"/dev/"+record.tty,cwd:directory.path,terminal:.terminal)
            try AuditStore(path:paths.database).set("codexApprovalBinding:"+session.id,String(decoding:JSONEncoder().encode(CodexApprovalBinding(threadID:root,title:"Owned parent")),as:UTF8.self))
            let id=UUID(),path=directory.appendingPathComponent("subagent-goal-actions.sqlite").path
            do {
                let ledger=try CodexSubagentGoalActionStore(path:path)
                try ledger.reserve(.init(requestID:id,binding:"owned",phase:.reserved,detail:"Crash before result",
                    intent:.init(sessionID:session.id,home:directory.path,expected:expected,action:.pause)))
                if scenario=="superseded" {
                    var newer=CodexSubagentGoalReceipt(requestID:UUID(),binding:"newer",phase:.reserved,detail:"Newer resume",
                        intent:.init(sessionID:session.id,home:directory.path,expected:expected,action:.resume))
                    try ledger.reserve(newer);newer.phase = .confirmed;try ledger.finish(newer)
                }
            }
            let target=CodexReplyTarget(executable:"/owned/codex",home:directory.path,threadID:root)
            let transport=CodexReplyTransport(prepare:{_,_ in target},send:{_,_ in throw AppError.message("No messages")},prepareMessage:{_ in target},prepareQueue:{_,_ in target})
            let services=CodexSubagentGoalServices(read:{_,_,_ in await MainActor.run{probe.current}},change:{_,_,_,action,authorize in
                try await authorize()
                return await MainActor.run{probe.changes+=1;probe.current.goal?.status = action == .resume ? .active:.paused;return probe.current}
            })
            for _ in 0..<2 {
                let engine=try ApprovalEngine(paths:paths,questionTransport:transport,processReader:{records},codexSubagentGoals:services)
                engine.updateDiscovery([session],records:records)
                try expectEqual(engine.snapshot.sessions.first?.codexApprovalBinding?.threadID,root,"Recovered parent binding")
                _ = try await engine.readCodexSubagentGoal(sessionID:session.id,childID:child)
                await engine.recoverCodexGoalIntents();engine.stop()
            }
            let receipt=try CodexSubagentGoalActionStore(path:path).read(id)!
            try expectEqual(receipt.phase,scenario=="needed" || scenario=="already" ? .confirmed:.notStarted)
            try expectEqual(probe.changes,scenario=="needed" ? 1:0)
            if scenario=="needed" || scenario=="already" {try expectEqual(receipt.result?.goal?.instanceID,original.instanceID)}
        }
    }
    func testGoalIntentSurvivesRestartWithoutReplayingLegacyReceipts() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-goal-intent-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let path=root.appendingPathComponent("actions.sqlite").path,id=UUID(),legacy=UUID()
        let goal=CodexGoal(threadId:UUID().uuidString,objective:"Retain recovery identity",status:.active,createdAt:100,updatedAt:100,instanceID:UUID().uuidString)
        let expected=CodexSubagentGoal(rootThreadID:UUID().uuidString,threadID:goal.threadId,parentThreadID:UUID().uuidString,goal:goal)
        do {
            let store=try CodexSubagentGoalActionStore(path:path)
            try store.reserve(.init(requestID:id,binding:"owned",phase:.reserved,detail:"Pending",
                intent:.init(sessionID:"original-session",home:root.path,expected:expected,action:.pause)))
            try store.reserve(.init(requestID:legacy,binding:"old",phase:.reserved,detail:"Legacy without intent"))
        }
        let reopened=try CodexSubagentGoalActionStore(path:path)
        let pending=try reopened.pendingIntents()
        try expectEqual(pending.map(\.requestID),[id])
        try expectEqual(pending.first?.intent?.expected,expected)
        try expectEqual(pending.first?.intent?.home,root.path)
        try expectEqual(pending.first?.intent?.action,.pause)
        try expect(try reopened.isLatestIntent(id))
        try expectFalse(try reopened.isLatestIntent(legacy))
        var receipt=pending[0];receipt.phase = .confirmed
        try reopened.finish(receipt)
        try expectEqual(try reopened.pendingIntents().count,0)
        try expectEqual(try reopened.read(legacy)?.phase,.reserved)
        let newer=UUID()
        var olderDate=pending[0].intent!.createdAt;olderDate.addTimeInterval(-100)
        try reopened.reserve(.init(requestID:newer,binding:"new resume",phase:.reserved,detail:"New desired state",
            intent:.init(sessionID:"reconnected-session",home:root.path,expected:expected,action:.resume,createdAt:olderDate)))
        var completed=try reopened.read(newer)!;completed.phase = .confirmed
        try reopened.finish(completed)
        try expectFalse(try reopened.isLatestIntent(id),"A newer completed request supersedes an earlier intent, even across terminal reconnection and clock rollback")
        try expect(try reopened.isLatestIntent(newer))
        let movedHome=root.appendingPathComponent("moved").path,moved=UUID()
        try reopened.reserve(.init(requestID:moved,binding:"new home resume",phase:.reserved,detail:"Moved desired state",
            intent:.init(sessionID:"moved-session",home:movedHome,expected:expected,action:.resume)))
        var movedReceipt=try reopened.read(moved)!;movedReceipt.phase = .confirmed;try reopened.finish(movedReceipt)
        try expect(try reopened.isLatestIntent(newer),"Home-local ordering alone cannot infer a migration")
        try expectFalse(try reopened.isLatestIntent(newer,homes:[root.path,movedHome]),"Journal-proven homes share durable intent ordering")
        try expect(try reopened.isLatestIntent(moved,homes:[root.path,movedHome]))
        try expectThrows(reopened.isLatestIntent(newer,homes:[movedHome]))
    }
    func testOfficialGoalIdentityPreservesAccountingAndRejectsReplacement() throws {
        let stored=CodexGoal(threadId:UUID().uuidString,objective:"Keep this exact child Goal",status:.active,
            createdAt:100,updatedAt:110,tokensUsed:12,timeUsedSeconds:3,tokenBudget:1234,instanceID:UUID().uuidString)
        var api=stored;api.instanceID=nil;api.tokensUsed=19;api.timeUsedSeconds=5
        var later=stored;later.tokensUsed=21;later.timeUsedSeconds=6;later.updatedAt=115
        let observed=try CodexGoalTransport.identify(api,before:stored,after:later)
        try expectEqual(observed.instanceID,stored.instanceID)
        try expectEqual(observed.tokensUsed,api.tokensUsed)
        try expectEqual(observed.timeUsedSeconds,api.timeUsedSeconds)
        // A replacement may have identical API fields, including second-level time.
        var replaced=later;replaced.instanceID=UUID().uuidString
        try expectThrows(CodexGoalTransport.identify(api,before:stored,after:replaced))
        try expectThrows(CodexGoalTransport.identify(api,before:nil,after:later))
        try expectThrows(CodexGoalTransport.identify(api,before:stored,after:nil))
        var otherThread=later;otherThread.threadId=UUID().uuidString
        try expectThrows(CodexGoalTransport.identify(api,before:otherThread,after:otherThread))
        var changed=later;changed.status = .paused
        try expectThrows(CodexGoalTransport.identify(api,before:stored,after:changed))
        changed=later;changed.tokenBudget=1235
        try expectThrows(CodexGoalTransport.identify(api,before:changed,after:changed))
        changed=later;changed.objective="A new objective"
        try expectThrows(CodexGoalTransport.identify(api,before:changed,after:changed))
    }
}
#endif
