import Foundation

public struct CodexSubagentGoal:Codable,Equatable,Sendable {
    public let rootThreadID:String
    public let threadID:String
    public let parentThreadID:String
    public var goal:CodexGoal?
    public var executionState:String?
    public var turnID:String?
    public init(rootThreadID:String,threadID:String,parentThreadID:String,goal:CodexGoal?,executionState:String?=nil,turnID:String?=nil) {
        self.rootThreadID=rootThreadID;self.threadID=threadID;self.parentThreadID=parentThreadID;self.goal=goal
        self.executionState=executionState;self.turnID=turnID
    }
}

public enum CodexSubagentGoalAction:String,Codable,Sendable {case pause,resume,wait}

/// Uses original public lifecycle operations and exact persisted Goal identity.
/// Direct child turn input must never recreate a Goal or reset its accounting.
public enum CodexSubagentGoalTransport {
    private static func background<Value:Sendable>(_ operation:@escaping @Sendable () async throws ->Value) async throws ->Value {
        let child=Task.detached(priority:.utility,operation:operation)
        return try await withTaskCancellationHandler(operation:{
            do {let result=try await child.value;try Task.checkCancellation();return result}
            catch {try Task.checkCancellation();throw error}
        },onCancel:{child.cancel()})
    }
    public static func read(target:CodexReplyTarget,cwd:String,childID:String) async throws ->CodexSubagentGoal {
        try await background {
            let connection=try CodexQueueConnection(home:target.home,captureApprovals:true)
            let parent=try validate(connection,target:target,cwd:cwd,childID:childID)
            return try read(connection,target:target,childID:childID,parentID:parent)
        }
    }

    public static func change(target:CodexReplyTarget,cwd:String,expected:CodexSubagentGoal,action:CodexSubagentGoalAction,
                              authorize:@escaping @Sendable () async throws ->Void) async throws ->CodexSubagentGoal {
        let paths=AppPaths()
        if action == .resume {try paths.prepare()}
        return try await change(target:target,cwd:cwd,expected:expected,action:action,
            requestID:UUID(),stateDirectory:paths.directory,authorize:authorize)
    }

    static func change(target:CodexReplyTarget,cwd:String,expected:CodexSubagentGoal,action:CodexSubagentGoalAction,
                       requestID:UUID,stateDirectory:URL,
                       authorize:@escaping @Sendable () async throws ->Void) async throws ->CodexSubagentGoal {
        if action == .resume {return try await resumeOfficial(target:target,cwd:cwd,expected:expected,requestID:requestID,stateDirectory:stateDirectory,authorize:authorize)}
        if action == .pause {return try await pauseOfficial(target:target,cwd:cwd,expected:expected,authorize:authorize)}
        return try await background {
            guard expected.rootThreadID==target.threadID,let goal=expected.goal,
                  UUID(uuidString:goal.instanceID ?? "") != nil,goal.threadId==expected.threadID,
                  goal.status == .paused,expected.executionState != "idle",let turn=expected.turnID else {
                throw RemoteHTTPError(409,"현재 서브에이전트 Goal의 일시정지·재개 상태를 다시 확인해주세요.",diagnostics:["delivery":"not_started"])
            }
            let connection=try CodexQueueConnection(home:target.home,captureApprovals:true)
            _ = try CodexOfficialExecutable.verifyServer(connection)
            let parent=try validate(connection,target:target,cwd:cwd,childID:expected.threadID)
            guard parent==expected.parentThreadID,
                  try read(connection,target:target,childID:expected.threadID,parentID:parent).goal?.revision==goal.revision else {
                throw RemoteHTTPError(409,"서브에이전트의 부모 또는 Goal이 바뀌었습니다. 새 상태를 확인해주세요.",diagnostics:["delivery":"not_started"])
            }
            try await authorize()
            try Task.checkCancellation()
            guard try await waitUntilIdle(connection,childID:expected.threadID,turnID:turn,attempts:60) else {
                throw RemoteHTTPError(408,"서브에이전트 작업이 아직 끝나지 않았습니다. 상태를 새로 고친 뒤 다시 확인해주세요.",diagnostics:["delivery":"not_started"])
            }
            return try read(connection,target:target,childID:expected.threadID,parentID:parent)
        }
    }

    /// Official 0.169 restores Goal continuation through its ordinary resume
    /// lifecycle. This attaches to the parent-owned child; it injects no user
    /// message, direct child input or new parent turn.
    static func resumeOfficial(target:CodexReplyTarget,cwd:String,expected:CodexSubagentGoal,
                               requestID:UUID,stateDirectory:URL,
                               authorize:@escaping @Sendable () async throws ->Void) async throws ->CodexSubagentGoal {
        try await background {
            guard expected.rootThreadID==target.threadID,let goal=expected.goal,goal.status == .paused,
                  UUID(uuidString:goal.instanceID ?? "") != nil else {
                throw RemoteHTTPError(409,"현재 일시정지된 서브에이전트 Goal을 다시 확인해주세요.",diagnostics:["delivery":"not_started"])
            }
            let connection=try CodexQueueConnection(home:target.home,captureApprovals:true)
            _ = try CodexOfficialExecutable.verifyServer(connection)
            let parent=try validate(connection,target:target,cwd:cwd,childID:expected.threadID)
            var current=try read(connection,target:target,childID:expected.threadID,parentID:parent)
            guard parent==expected.parentThreadID,current.goal?.revision==goal.revision else {
                throw RemoteHTTPError(409,"원래 서브에이전트 Goal이 바뀌었습니다.",diagnostics:["delivery":"not_started"])
            }
            if current.executionState != "idle" {
                guard let turn=current.turnID,turn==expected.turnID,
                      try await waitUntilIdle(connection,childID:expected.threadID,turnID:turn,attempts:60) else {
                    throw RemoteHTTPError(409,"현재 작업이 끝난 뒤 같은 Goal을 재개할 수 있습니다.",diagnostics:["delivery":"not_started"])
                }
                current=try read(connection,target:target,childID:expected.threadID,parentID:parent)
            }
            guard current.executionState=="idle",current.goal?.revision==goal.revision else {
                throw RemoteHTTPError(409,"Goal 재개 전 실행 상태가 바뀌었습니다.",diagnostics:["delivery":"not_started"])
            }
            // Reattach while still paused first: the official idle lifecycle
            // clears any old in-memory active accounting before reactivation.
            try await authorize();try Task.checkCancellation()
            _ = try connection.request("thread/resume",["threadId":expected.threadID,"excludeTurns":true],classifyError:true)
            let access=try CodexOfficialGoalStateAccess(home:target.home,userHome:NSHomeDirectory(),executable:target.executable)
            let snapshot=try access.snapshot(threadID:expected.threadID)
            guard snapshot.row.status=="paused",snapshot.row.goalID==goal.instanceID,
                  snapshot.row.objective==goal.objective,snapshot.row.tokenBudget==goal.tokenBudget,
                  snapshot.row.createdAtMs/1000==goal.createdAt,
                  snapshot.row.tokensUsed>=goal.tokensUsed,snapshot.row.timeUsedSeconds>=goal.timeUsedSeconds,
                  snapshot.row.updatedAtMs<Int64.max else {
                throw RemoteHTTPError(409,"보존할 Goal의 신원·예산·사용량이 바뀌었습니다.",diagnostics:["delivery":"not_started"])
            }
            try await authorize();try Task.checkCancellation()
            let now=Int64(Date().timeIntervalSince1970*1000)
            let timestamp=max(now,snapshot.row.updatedAtMs+1)
            let journal=try CodexOfficialGoalStateJournal(path:stateDirectory.appendingPathComponent("official-goal-states.sqlite").path)
            let receipt=try journal.restore(id:requestID,expected:snapshot,updatedAtMs:timestamp,access:access)
            guard receipt.phase == .applied else {
                throw RemoteHTTPError(409,"이전 Goal 상태 복원 결과를 확인해주세요. 같은 요청을 반복하지 않았습니다.",diagnostics:["delivery":"unknown"])
            }
            try await authorize();try Task.checkCancellation()
            let ready=try read(connection,target:target,childID:expected.threadID,parentID:parent)
            guard let restored=ready.goal,restored.instanceID==goal.instanceID,restored.status == .active,
                  restored.objective==goal.objective,restored.tokenBudget==goal.tokenBudget else {
                throw RemoteHTTPError(409,"Goal 상태 복원 뒤 변경이 발생했습니다. 재개 입력을 보내지 않았습니다.",diagnostics:["delivery":"unknown"])
            }
            let response=try connection.request("thread/resume",["threadId":expected.threadID,"excludeTurns":true],classifyError:true)
            guard let row=response["thread"] as? JSONObject,row["id"] as? String==expected.threadID,
                  row["parentThreadId"] as? String==parent,row["canAcceptDirectInput"] as? Bool==false else {
                throw RemoteHTTPError(409,"공식 하위 대화 재연결 결과를 확인하지 못했습니다.",diagnostics:["delivery":"unknown"])
            }
            let result=try read(connection,target:target,childID:expected.threadID,parentID:parent)
            guard result.goal?.revision==restored.revision,result.goal?.status == .active,
                  result.goal?.tokensUsed ?? -1 >= snapshot.row.tokensUsed,
                  result.goal?.timeUsedSeconds ?? -1 >= snapshot.row.timeUsedSeconds else {
                throw RemoteHTTPError(409,"Goal 재개 결과를 다시 확인해주세요. 요청을 반복하지 않습니다.",diagnostics:["delivery":"unknown"])
            }
            return result
        }
    }

    static func pauseOfficial(target:CodexReplyTarget,cwd:String,expected:CodexSubagentGoal,
                              authorize:@escaping @Sendable () async throws ->Void,
                              authorizePaused:(@Sendable () async throws ->Void)?=nil) async throws ->CodexSubagentGoal {
        try await background {
            guard expected.rootThreadID==target.threadID,let goal=expected.goal,goal.status == .active,
                  UUID(uuidString:goal.instanceID ?? "") != nil else {
                throw RemoteHTTPError(409,"현재 활성 서브에이전트 Goal을 다시 확인해주세요.",diagnostics:["delivery":"not_started"])
            }
            let connection=try CodexQueueConnection(home:target.home,captureApprovals:true)
            _ = try CodexOfficialExecutable.verifyServer(connection)
            let parent=try validate(connection,target:target,cwd:cwd,childID:expected.threadID)
            let current=try read(connection,target:target,childID:expected.threadID,parentID:parent)
            guard parent==expected.parentThreadID,current.goal?.revision==goal.revision,
                  current.executionState=="idle" || current.turnID==expected.turnID else {
                throw RemoteHTTPError(409,"일시정지할 Goal 또는 현재 작업이 바뀌었습니다.",diagnostics:["delivery":"not_started"])
            }
            let access=try CodexOfficialGoalStateAccess(home:target.home,userHome:NSHomeDirectory(),executable:target.executable)
            func matches(_ snapshot:CodexOfficialGoalStateSnapshot)->Bool {
                snapshot.row.status=="active" && snapshot.row.goalID==goal.instanceID && snapshot.row.objective==goal.objective
                    && snapshot.row.tokenBudget==goal.tokenBudget && snapshot.row.createdAtMs/1000==goal.createdAt
                    && snapshot.row.tokensUsed>=goal.tokensUsed && snapshot.row.timeUsedSeconds>=goal.timeUsedSeconds
            }
            try await authorize();try Task.checkCancellation()
            let before=try access.snapshot(threadID:expected.threadID)
            guard matches(before) else{throw RemoteHTTPError(409,"보존할 Goal이 바뀌었습니다.",diagnostics:["delivery":"not_started"])}
            _ = try access.deferContinuation(before)
            // Defer only future automatic Goal work. Keep the Goal active until
            // the exact observed turn's native abort has flushed its accounting.
            let work=try execution(connection,childID:expected.threadID)
            if work.state != "idle" {
                guard let turn=work.turn,turn==expected.turnID else {
                    throw RemoteHTTPError(409,"자동 진행을 보류했지만 현재 작업이 바뀌었습니다. 새 상태를 확인해주세요.",diagnostics:["delivery":"unknown","continuationDeferred":"true"])
                }
                try await authorize();try Task.checkCancellation()
                _ = try connection.request("turn/interrupt",["threadId":expected.threadID,"turnId":turn],classifyError:true)
                guard try await waitUntilIdle(connection,childID:expected.threadID,turnID:turn,attempts:30) else {
                    throw RemoteHTTPError(409,"자동 진행은 보류했습니다. 원래 작업의 종료를 다시 확인해주세요.",diagnostics:["delivery":"unknown","continuationDeferred":"true"])
                }
            }
            let settled=try access.snapshot(threadID:expected.threadID)
            guard matches(settled),settled.continuationDeferred,settled.row.updatedAtMs<Int64.max,
                  try execution(connection,childID:expected.threadID).state=="idle" else {
                throw RemoteHTTPError(409,"보류 뒤 Goal·작업 상태가 바뀌었습니다. 상태를 새로 확인해주세요.",diagnostics:["delivery":"unknown","continuationDeferred":"true"])
            }
            try await authorize();try Task.checkCancellation()
            _ = try access.pause(settled,updatedAtMs:max(Int64(Date().timeIntervalSince1970*1000),settled.row.updatedAtMs+1))
            // A paused snapshot and the original idle hook also clear cached
            // active accounting; subsequent resume must not charge paused time.
            // SQL persistence can outlive the selected terminal/account binding.
            // Recheck the app's authority before the next native lifecycle RPC.
            try await (authorizePaused ?? authorize)();try Task.checkCancellation()
            _ = try connection.request("thread/resume",["threadId":expected.threadID,"excludeTurns":true],classifyError:true)
            let result=try read(connection,target:target,childID:expected.threadID,parentID:parent)
            guard result.goal?.instanceID==goal.instanceID,result.goal?.status == .paused,result.executionState=="idle",
                  result.goal?.objective==goal.objective,result.goal?.tokenBudget==goal.tokenBudget,
                  result.goal?.tokensUsed ?? -1 >= settled.row.tokensUsed,
                  result.goal?.timeUsedSeconds ?? -1 >= settled.row.timeUsedSeconds else {
                throw RemoteHTTPError(409,"Goal 일시정지 결과를 다시 확인해주세요. 입력을 반복하지 않습니다.",diagnostics:["delivery":"unknown"])
            }
            return result
        }
    }

    /// Complete an interrupted native idle hook without another Goal mutation.
    /// Attaching an already running child does not send it a turn or a message.
    static func settleRecovered(target:CodexReplyTarget,cwd:String,expected:CodexSubagentGoal,
                                authorize:@escaping @Sendable () async throws ->Void) async throws ->CodexSubagentGoal {
        try await background {
            let connection=try CodexQueueConnection(home:target.home,captureApprovals:true)
            _ = try CodexOfficialExecutable.verifyServer(connection)
            let parent=try validate(connection,target:target,cwd:cwd,childID:expected.threadID)
            let current=try read(connection,target:target,childID:expected.threadID,parentID:parent)
            guard CodexGoalIntentRecovery.sameGoal(expected,current),current.goal?.status==expected.goal?.status else {
                throw AppError.message("복구할 Goal이 바뀌었습니다.")
            }
            if current.executionState != "idle" {
                guard current.goal?.status == .active else{throw AppError.message("일시정지된 작업의 종료를 확인 중입니다.")}
                return current
            }
            let access=try CodexOfficialGoalStateAccess(home:target.home,userHome:NSHomeDirectory(),executable:target.executable)
            let snapshot=try access.snapshot(threadID:current.threadID)
            guard snapshot.row.goalID==current.goal?.instanceID,!snapshot.continuationDeferred,
                  snapshot.row.status==current.goal?.status.rawValue else{throw AppError.message("Goal의 자동 진행 보류 상태를 확인해주세요.")}
            try await authorize();try Task.checkCancellation()
            _ = try connection.request("thread/resume",["threadId":current.threadID,"excludeTurns":true],classifyError:true)
            let result=try read(connection,target:target,childID:current.threadID,parentID:parent)
            guard CodexGoalIntentRecovery.sameGoal(current,result),result.goal?.status==current.goal?.status else {
                throw AppError.message("Goal 복구 마무리 결과를 다시 확인해야 합니다.")
            }
            return result
        }
    }

    @discardableResult private static func waitUntilIdle(_ connection:CodexQueueConnection,childID:String,
                                                           turnID:String,attempts:Int) async throws -> Bool {
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let current=try execution(connection,childID:childID)
            if current.state=="idle" {return true}
            if current.turn != turnID {return false}
            if attempt+1<attempts {try await Task.sleep(for:.seconds(1))}
        }
        return false
    }

    private static func validate(_ connection:CodexQueueConnection,target:CodexReplyTarget,cwd:String,childID:String) throws ->String {
        guard target.queueAvailable,UUID(uuidString:target.threadID) != nil,UUID(uuidString:childID) != nil,childID != target.threadID else {
            throw RemoteHTTPError(409,"연결된 부모 대화의 서브에이전트를 선택해주세요.",diagnostics:["delivery":"not_started"])
        }
        let root=try connection.request("thread/read",["threadId":target.threadID,"includeTurns":false])["thread"] as? JSONObject
        guard let root,root["id"] as? String==target.threadID,root["cwd"] as? String==cwd,
              root["parentThreadId"]==nil || root["parentThreadId"] is NSNull else{
            throw RemoteHTTPError(409,"부모 대화의 경로와 연결이 바뀌었습니다.",diagnostics:["delivery":"not_started"])
        }
        let rows=try CodexSubagentApprovals.subtree(connection,root:root)
        let owned=CodexSubagentApprovals.ownedThreads(root:target.threadID,rows:rows,includeInactive:true)
        guard owned[target.threadID]?["cwd"] as? String==cwd,let child=owned[childID],
              let parent=child["parentThreadId"] as? String,owned[parent] != nil,
              ["active","idle","systemError"].contains((child["status"] as? JSONObject)?["type"] as? String ?? "") else {
            throw RemoteHTTPError(409,"현재 부모·서브에이전트 연결을 확인하지 못했습니다.",diagnostics:["delivery":"not_started"])
        }
        return parent
    }

    private static func read(_ connection:CodexQueueConnection,target:CodexReplyTarget,childID:String,parentID:String) throws ->CodexSubagentGoal {
        let goal=try CodexGoalTransport.readWithIdentity(connection,home:target.home,threadID:childID)
        let work=try execution(connection,childID:childID)
        return CodexSubagentGoal(rootThreadID:target.threadID,threadID:childID,parentThreadID:parentID,goal:goal,executionState:work.state,turnID:work.turn)
    }

    private static func execution(_ connection:CodexQueueConnection,childID:String) throws ->(state:String,turn:String?) {
        let row=try connection.request("thread/read",["threadId":childID,"includeTurns":false])["thread"] as? JSONObject
        guard row?["id"] as? String==childID,let state=(row?["status"] as? JSONObject)?["type"] as? String else {throw AppError.message("서브에이전트 실행 상태를 확인하지 못했습니다.")}
        if state=="idle" {return(state,nil)}
        let turns=try connection.request("thread/turns/list",["threadId":childID,"limit":1,"itemsView":"notLoaded","sortDirection":"desc"])["data"] as? [JSONObject]
        let turn=turns?.first
        return(state,turn?["status"] as? String=="inProgress" ? turn?["id"] as? String:nil)
    }
}

public struct CodexSubagentGoalServices:Sendable {
    typealias RequestedChange = @Sendable(CodexReplyTarget,String,CodexSubagentGoal,CodexSubagentGoalAction,UUID,URL,@escaping @Sendable () async throws ->Void) async throws ->CodexSubagentGoal
    var requestedChange:RequestedChange?
    var settleRecovered:(@Sendable(CodexReplyTarget,String,CodexSubagentGoal,@escaping @Sendable () async throws ->Void) async throws ->CodexSubagentGoal)?
    public var read:@Sendable(CodexReplyTarget,String,String) async throws ->CodexSubagentGoal
    public var change:@Sendable(CodexReplyTarget,String,CodexSubagentGoal,CodexSubagentGoalAction,@escaping @Sendable () async throws ->Void) async throws ->CodexSubagentGoal
    public init(read:@escaping @Sendable(CodexReplyTarget,String,String) async throws ->CodexSubagentGoal,
                change:@escaping @Sendable(CodexReplyTarget,String,CodexSubagentGoal,CodexSubagentGoalAction,@escaping @Sendable () async throws ->Void) async throws ->CodexSubagentGoal) {self.read=read;self.change=change}
    public static let live:Self = {
        var services=Self(read:{try await CodexSubagentGoalTransport.read(target:$0,cwd:$1,childID:$2)},
                          change:{try await CodexSubagentGoalTransport.change(target:$0,cwd:$1,expected:$2,action:$3,authorize:$4)})
        services.requestedChange={target,cwd,expected,action,id,directory,authorize in
            try await CodexSubagentGoalTransport.change(target:target,cwd:cwd,expected:expected,action:action,
                requestID:id,stateDirectory:directory,authorize:authorize)
        }
        services.settleRecovered={try await CodexSubagentGoalTransport.settleRecovered(target:$0,cwd:$1,expected:$2,authorize:$3)}
        return services
    }()
}
