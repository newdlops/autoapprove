import Foundation
@testable import AutoApproveCore

private final class ResumeCalls:@unchecked Sendable {
    private let lock=NSLock();private var value=0
    func begin(){lock.withLock{value+=1}}
    var count:Int{lock.withLock{value}}
}

private struct PauseCrashRequest:Codable {
    let id:UUID
    let expected:CodexSubagentGoal
}

/// Exercises the exact engine action called by the app. Session discovery is
/// synthetic; all child Goal reads, state persistence and official resume RPCs
/// are real and address only this fixture's private official server.
@main struct OfficialChildResumeCheck {
    @MainActor static func main() async throws {
        let args=CommandLine.arguments
        guard (6...9).contains(args.count),args[1].hasPrefix("/private/tmp/aa-child-goal-"),args[1].hasSuffix("/home") else{throw AppError.message("Owned Goal fixture required")}
        let home=args[1],cli=args[2],root=args[3],cwd=args[4],child=args[5]
        let action:CodexSubagentGoalAction = args.dropFirst(6).contains("pause") ? .pause:.resume
        let compatibility=args.dropFirst(6).contains("compatibility")
        let crashPoint=args.dropFirst(6).first(where:{$0.hasPrefix("crash-")})
        let recoverPause=args.dropFirst(6).contains("recover-pause")
        guard crashPoint==nil || ["crash-deferred","crash-settled","crash-paused","crash-confirmed"].contains(crashPoint!),
              !(compatibility && (crashPoint != nil || recoverPause)),
              (crashPoint==nil && !recoverPause) || action == .pause else{throw AppError.message("Invalid owned pause crash mode")}
        let status:CodexGoal.Status = action == .pause ? .paused:.active
        let paths=AppPaths(directory:URL(fileURLWithPath:cwd+"/official-resume-engine"));try paths.prepare()
        let records=ProcessDiscovery.parse("2000000000 1 ttys991 2000000000 2000000000 Mon Nov 2 10:00:00 2026 "+cli)
        let record=records[0],session=AgentSession(id:record.key,agent:.codex,pid:record.pid,started:record.started,tty:"/dev/"+record.tty,cwd:cwd,terminal:.terminal)
        try AuditStore(path:paths.database).set("codexApprovalBinding:"+session.id,
            String(decoding:try JSONEncoder().encode(CodexApprovalBinding(threadID:root,title:"Owned parent")),as:UTF8.self))
        let target=CodexReplyTarget(executable:cli,home:home,threadID:root)
        let transport=CodexReplyTransport(prepare:{_,_ in throw AppError.message("No question delivery in this test")},
            send:{_,_ in throw AppError.message("No parent messages permitted")},prepareMessage:{_ in target},prepareQueue:{_,thread in
                guard thread==root else{throw AppError.message("Wrong root selection")};return target
            })
        let calls=ResumeCalls()
        var observedServices=CodexSubagentGoalServices.live
        if compatibility {
            let live=observedServices.change
            observedServices.requestedChange=nil
            observedServices.change={target,cwd,expected,action,authorize in
                calls.begin();return try await live(target,cwd,expected,action,authorize)
            }
        }else{
            let live=observedServices.requestedChange!
            observedServices.requestedChange={target,cwd,expected,action,id,directory,authorize in
                calls.begin()
                let authorizations=ResumeCalls()
                let result=try await live(target,cwd,expected,action,id,directory,{
                    try await authorize();authorizations.begin()
                    // Real controller process death, after the first persistent
                    // deferral or after native interrupt/accounting has settled.
                    if crashPoint=="crash-deferred",authorizations.count==2{_exit(73)}
                    if crashPoint=="crash-settled",authorizations.count==3{_exit(74)}
                    if crashPoint=="crash-paused",authorizations.count==4{_exit(76)}
                })
                // The native lifecycle succeeded but the outer action receipt
                // has not yet recorded that result.
                if crashPoint=="crash-confirmed"{_exit(75)}
                return result
            }
        }
        let services=observedServices
        func make()throws->ApprovalEngine {
            let engine=try ApprovalEngine(paths:paths,questionTransport:transport,processReader:{records},codexSubagentGoals:services)
            engine.updateDiscovery([session],records:records);return engine
        }
        let engine=try make();defer{engine.stop()}
        let crashFile=paths.directory.appendingPathComponent("owned-pause-crash-request.json")
        if recoverPause {
            let saved=try JSONDecoder().decode(PauseCrashRequest.self,from:Data(contentsOf:crashFile))
            let replay=try await engine.changeCodexSubagentGoal(sessionID:session.id,expected:saved.expected,action:.pause,requestID:saved.id)
            guard replay.phase == .reserved,replay.result==nil,calls.count==0 else{throw AppError.message("Uncertain pause was dispatched again after process death")}
            let current=try await engine.readCodexSubagentGoal(sessionID:session.id,childID:child)
            guard let goal=current.goal,let old=saved.expected.goal,goal.instanceID==old.instanceID,
                  goal.objective==old.objective,goal.tokenBudget==old.tokenBudget,
                  goal.tokensUsed>=old.tokensUsed,goal.timeUsedSeconds>=old.timeUsedSeconds else{throw AppError.message("Pause crash changed the original Goal")}
            let neededNewPause=goal.status == .active
            if neededNewPause {
                // A fresh observation and a distinct explicit request can finish
                // the still-active, deferred Goal. Never replay the uncertain ID.
                let fresh=try await engine.changeCodexSubagentGoal(sessionID:session.id,expected:current,action:.pause,requestID:UUID())
                guard fresh.phase == .confirmed,fresh.result?.goal?.instanceID==old.instanceID,
                      fresh.result?.goal?.status == .paused,fresh.result?.executionState=="idle" else{throw AppError.message("Fresh pause could not settle the deferred original Goal")}
            }else{
                guard goal.status == .paused,current.executionState=="idle" else{throw AppError.message("Unknown pause outcome needs review")}
            }
            let final=try await engine.readCodexSubagentGoal(sessionID:session.id,childID:child)
            guard final.goal?.status == .paused,final.executionState=="idle",calls.count==(neededNewPause ? 1:0) else{throw AppError.message("Unexpected pause recovery dispatch count")}
            engine.stop()
            let restored=try make();defer{restored.stop()}
            let repeated=try await restored.changeCodexSubagentGoal(sessionID:session.id,expected:saved.expected,action:.pause,requestID:saved.id)
            guard repeated.phase == .reserved,repeated.result==nil,calls.count==(neededNewPause ? 1:0) else{throw AppError.message("Recovered app replayed uncertain original pause")}
            print("{\"verified\":true,\"productionEnginePause\":true,\"compatibilityEntry\":false,\"pauseCrashObserved\":true,\"uncertainRequestNotReplayed\":true,\"freshObservedPauseRequired\":\(neededNewPause),\"liveDispatches\":\(calls.count),\"sameGoal\":true,\"parentMessagesSent\":0,\"syntheticSessionDiscovery\":true}")
            return
        }
        let expected=try await engine.readCodexSubagentGoal(sessionID:session.id,childID:child)
        guard expected.goal?.status == (action == .pause ? .active:.paused),action == .pause || expected.executionState=="idle" else{throw AppError.message("Owned child lifecycle precondition changed")}
        let request=UUID()
        if crashPoint != nil {
            try JSONEncoder().encode(PauseCrashRequest(id:request,expected:expected)).write(to:crashFile,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:crashFile.path)
        }
        let receipt=try await engine.changeCodexSubagentGoal(sessionID:session.id,expected:expected,action:action,requestID:request)
        guard receipt.phase == .confirmed,receipt.result?.goal?.status == status,
              receipt.result?.goal?.instanceID==expected.goal?.instanceID else{throw AppError.message("Production Goal \(action.rawValue) failed: "+receipt.detail)}
        let repeated=try await engine.changeCodexSubagentGoal(sessionID:session.id,expected:expected,action:action,requestID:request)
        guard repeated.result==receipt.result else{throw AppError.message("Repeated request changed its stored result")}
        engine.stop()
        let restored=try make();defer{restored.stop()}
        let replay=try await restored.changeCodexSubagentGoal(sessionID:session.id,expected:expected,action:action,requestID:request)
        guard replay.phase == .confirmed,replay.result==receipt.result,calls.count==1 else{throw AppError.message("App restart did not retain the exact Goal receipt or repeated dispatch")}
        print("{\"verified\":true,\"productionEngineResume\":\(action == .resume),\"productionEnginePause\":\(action == .pause),\"compatibilityEntry\":\(compatibility),\"receiptConfirmed\":true,\"sameGoal\":true,\"repeatAndRestartReadOnly\":true,\"liveDispatches\":1,\"parentMessagesSent\":0,\"syntheticSessionDiscovery\":true}")
    }
}
