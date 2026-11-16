import Foundation
@testable import AutoApproveCore

/// Uses the production account adapters against an owned original daemon.
@main struct OfficialAccountChildGoalCheck {
    @MainActor static func main() async throws {
        let args=CommandLine.arguments
        guard args.count==7,args[1].hasPrefix("/private/tmp/aa-child-goal-"),args[1].hasSuffix("/home") else {
            throw AppError.message("Owned original account fixture required")
        }
        let home=args[1],cli=args[2],root=args[3],cwd=args[4],child=args[5],mode=args[6]
        let target=CodexAccountTransitionTarget(home:home,executable:cli)
        let services=CodexAccountTransitionServices.live
        let connection=try CodexQueueConnection(home:home,requestScopedDeadline:true)
        let originalFile=URL(fileURLWithPath:cwd+"/account-child-original.json")
        if mode=="resume" {
            let original=try JSONDecoder().decode(CodexAccountTransitionThread.self,from:Data(contentsOf:originalFile))
            let observed=try await services.observe(target)
            guard observed.savedAccount != nil,observed.savedAccount==observed.serverAccount else {throw AppError.message("Synthetic account identity missing")}
            let before=try CodexGoalTransport.readWithIdentity(connection,home:home,threadID:child)
            var wrongParent=original;wrongParent.subagent?.parentThreadID=UUID().uuidString.lowercased()
            var wrongTurn=original;wrongTurn.turnID=UUID().uuidString.lowercased()
            var wrongGoal=original;wrongGoal.goal?.instanceID=UUID().uuidString.lowercased()
            for stale in [wrongParent,wrongTurn,wrongGoal] {
                guard try await services.resume!(target,observed,stale,UUID().uuidString) == .skipped else {
                    throw AppError.message("Stale child owner, turn or Goal was accepted")
                }
            }
            guard try CodexGoalTransport.readWithIdentity(connection,home:home,threadID:child)==before else {
                throw AppError.message("Stale child continuation changed the paused Goal")
            }
            let result=try await services.resume!(target,observed,original,UUID().uuidString)
            guard result == .goal else {throw AppError.message("Original child Goal did not resume through account adapter")}
            let repeated=try await services.resume!(target,observed,original,UUID().uuidString)
            guard repeated == .skipped else {throw AppError.message("Already resumed Goal was dispatched again")}
            print("{\"verified\":true,\"accountChildResumed\":true,\"alreadyActiveSkipped\":true,\"staleOwnerTurnGoalSkipped\":true}");return
        }
        let observed=try await services.observe(target)
        guard let original=observed.threads.first(where:{$0.id==child}),original.active,let turn=original.turnID else {
            throw AppError.message("Original active child missing from account observation")
        }
        if mode=="reproduce" {
            do {try await services.interrupt(target,observed.serverID,child,turn)}
            catch let error as CodexControlRPCError where error.method=="thread/goal/set" && error.code == -32600 && error.reason.contains("direct app-server input is not allowed") {
                print("{\"verified\":true,\"accountChildDefectReproduced\":true}");return
            }
            catch let error as RemoteHTTPError where error.status==409 && error.message.contains("thread/goal/set") && error.message.contains("-32600") {
                print("{\"verified\":true,\"accountChildDefectReproduced\":true}");return
            }
            throw AppError.message("Expected the original account child defect")
        }
        let encoded=try JSONEncoder().encode(original)
        let owner=(try JSONSerialization.jsonObject(with:encoded) as? JSONObject)?["subagent"] as? JSONObject
        guard mode=="pause",original.continuable==true,original.goal?.status == .active,
              owner?["rootThreadID"] as? String==root,owner?["parentThreadID"] as? String==root else {
            throw AppError.message("Account observation omitted the child Goal or its owner")
        }
        try JSONEncoder().encode(original).write(to:originalFile,options:.atomic)
        do {try await services.interrupt(target,observed.serverID,child,turn)}
        catch {
            let status=(try? CodexQueueConnection(home:home).request("thread/goal/get",["threadId":child])["goal"] as? JSONObject)?["status"] as? String
            FileHandle.standardError.write(Data("owned account pause failed; fresh Goal status=\(status ?? "unknown")\n".utf8));throw error
        }
        let settled=try CodexAccountTransitionLocal.thread(connection,id:child,home:home,allowSubagent:true)
        guard !settled.active,settled.goal?.status == .paused,settled.turnID==turn,
              settled.goal?.instanceID==original.goal?.instanceID else {throw AppError.message("Account child pause lost its exact Goal or turn")}
        print("{\"verified\":true,\"accountChildPaused\":true,\"ownershipPersisted\":true}")
    }
}
