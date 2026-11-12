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

/// Only the opt-in managed native API can mutate a v2 child Goal. There is no
/// ordinary goal/set fallback, terminal injection, new Goal or cold resume.
public enum CodexSubagentGoalTransport {
    public static func read(target:CodexReplyTarget,cwd:String,childID:String) async throws ->CodexSubagentGoal {
        try await Task.detached(priority:.utility) {
            let connection=try CodexQueueConnection(home:target.home,captureApprovals:true)
            let parent=try validate(connection,target:target,cwd:cwd,childID:childID)
            return try read(connection,target:target,childID:childID,parentID:parent)
        }.value
    }

    public static func change(target:CodexReplyTarget,cwd:String,expected:CodexSubagentGoal,action:CodexSubagentGoalAction,
                              authorize:@escaping @Sendable () async throws ->Void) async throws ->CodexSubagentGoal {
        try await Task.detached(priority:.utility) {
            guard expected.rootThreadID==target.threadID,let goal=expected.goal,let instance=goal.instanceID,
                  goal.threadId==expected.threadID,
                  action == .pause ? goal.status == .active:
                    action == .resume ? goal.status == .paused:
                      goal.status == .paused && expected.executionState != "idle" && expected.turnID != nil else {
                throw RemoteHTTPError(409,"현재 서브에이전트 Goal의 일시정지·재개 상태를 다시 확인해주세요.",diagnostics:["delivery":"not_started"])
            }
            let connection=try CodexQueueConnection(home:target.home,captureApprovals:true)
            let parent=try validate(connection,target:target,cwd:cwd,childID:expected.threadID)
            guard parent==expected.parentThreadID,
                  try read(connection,target:target,childID:expected.threadID,parentID:parent).goal?.revision==goal.revision else {
                throw RemoteHTTPError(409,"서브에이전트의 부모 또는 Goal이 바뀌었습니다. 새 상태를 확인해주세요.",diagnostics:["delivery":"not_started"])
            }
            try await authorize()
            try Task.checkCancellation()
            if action == .wait {
                guard try await waitUntilIdle(connection,childID:expected.threadID,turnID:expected.turnID!,attempts:60) else {
                    throw RemoteHTTPError(408,"서브에이전트 작업이 아직 끝나지 않았습니다. 상태를 새로 고친 뒤 다시 확인해주세요.",diagnostics:["delivery":"not_started"])
                }
                return try read(connection,target:target,childID:expected.threadID,parentID:parent)
            }
            let identity:JSONObject=["goalId":instance,"objective":goal.objective,"status":goal.status.rawValue,
                                     "tokenBudget":goal.tokenBudget.map{$0 as Any} ?? NSNull()]
            let result=try connection.request("autoapprove/thread/goal/control",[
                "threadId":expected.threadID,"parentThreadId":parent,"expected":identity,"action":action.rawValue
            ],classifyError:true)
            let expectedStatus:CodexGoal.Status = action == .resume ? .active:.paused
            guard result["goalId"] as? String==instance,
                  var changed=try CodexGoalTransport.decode(result,threadID:expected.threadID),
                  changed.objective==goal.objective,changed.tokenBudget==goal.tokenBudget,changed.createdAt==goal.createdAt,
                  changed.tokensUsed>=goal.tokensUsed,changed.timeUsedSeconds>=goal.timeUsedSeconds,
                  changed.status==expectedStatus else {
                throw RemoteHTTPError(409,"Goal 변경 결과를 확인하지 못했습니다. 같은 요청을 다시 보내지 말고 상태를 새로 확인해주세요.",diagnostics:["delivery":"unknown"])
            }
            changed.instanceID=instance
            // Pausing the Goal stops future continuation, not an in-flight turn.
            // Interrupt only the turn the user observed, never its replacement.
            if action == .pause,let observedTurn=expected.turnID {
                let current=try execution(connection,childID:expected.threadID)
                if current.turn==observedTurn {
                    _ = try connection.request("turn/interrupt",["threadId":expected.threadID,"turnId":observedTurn],classifyError:true)
                    _ = try await waitUntilIdle(connection,childID:expected.threadID,turnID:observedTurn,attempts:30)
                }
            }
            return try read(connection,target:target,childID:expected.threadID,parentID:parent)
        }.value
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
        let response=try connection.request("autoapprove/thread/goal/read",["threadId":childID,"parentThreadId":parentID],classifyError:true)
        var goal=try CodexGoalTransport.decode(response,threadID:childID)
        if let identity=response["identity"] as? JSONObject {
            guard let instance=identity["goalId"] as? String,UUID(uuidString:instance) != nil,
                  let current=goal,identity["objective"] as? String==current.objective,identity["status"] as? String==current.status.rawValue,
                  (identity["tokenBudget"] as? NSNumber)?.int64Value==current.tokenBudget,
                  identity["tokenBudget"] is NSNumber || identity["tokenBudget"] is NSNull else {
                throw AppError.message("서브에이전트 Goal의 식별자와 상태가 일치하지 않습니다.")
            }
            goal?.instanceID=instance
        } else if goal != nil || !(response["identity"] is NSNull) {
            throw AppError.message("서브에이전트 Goal 식별자를 확인하지 못했습니다.")
        }
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
    public var read:@Sendable(CodexReplyTarget,String,String) async throws ->CodexSubagentGoal
    public var change:@Sendable(CodexReplyTarget,String,CodexSubagentGoal,CodexSubagentGoalAction,@escaping @Sendable () async throws ->Void) async throws ->CodexSubagentGoal
    public init(read:@escaping @Sendable(CodexReplyTarget,String,String) async throws ->CodexSubagentGoal,
                change:@escaping @Sendable(CodexReplyTarget,String,CodexSubagentGoal,CodexSubagentGoalAction,@escaping @Sendable () async throws ->Void) async throws ->CodexSubagentGoal) {self.read=read;self.change=change}
    public static let live=Self(read:{try await CodexSubagentGoalTransport.read(target:$0,cwd:$1,childID:$2)},
                               change:{try await CodexSubagentGoalTransport.change(target:$0,cwd:$1,expected:$2,action:$3,authorize:$4)})
}
