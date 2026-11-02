import Foundation

public enum CodexAccountContinuationResult:String,Codable,Sendable {case goal,conversation,skipped}

/// Continues a durably reserved, previously running root without typing into
/// its terminal or changing its saved model, working directory or draft.
enum CodexAccountContinuationLocal {
    static func resume(_ target:CodexAccountTransitionTarget,expected:CodexAccountTransitionObservation,
                       original:CodexAccountTransitionThread,receipt:String) throws -> CodexAccountContinuationResult {
        guard UUID(uuidString:original.id) != nil,UUID(uuidString:receipt) != nil,original.continuable==true,
              original.active || original.goal?.status == .active,let account=expected.savedAccount,expected.serverAccount==account else {
            throw AppError.message("전환으로 중단한 원래 작업과 재개 기록을 확인하지 못했습니다.")
        }
        let connection=try CodexQueueConnection(home:target.home)
        func verifyConnection() throws {
            try Task.checkCancellation()
            guard try CodexAccountTransitionLocal.identity(target)==expected.serverID,
                  try CodexAccountMetadataProcess.read(target)==account,
                  try CodexAccountTransitionLocal.account(connection.request("accountSession/list",["refreshWorkspaceMetadata":false]))==account else {
                throw AppError.message("이어가기 직전 로그인·서버가 바뀌었습니다. 새 요청은 보내지 않았습니다.")
            }
            let server=try connection.peerProcessID()
            for witness in target.witnesses {
                guard CodexAccountTransitionLocal.sameProcess(witness),
                      CodexServerLocation.connectedHome(pid:witness.pid,hints:[target.home],peerPID:server)==target.home else {
                    throw AppError.message("원래 Codex 창의 연결이 바뀌었습니다. 이어가기를 보류했습니다.")
                }
            }
        }
        func sameRoot(_ row:JSONObject) -> Bool {
            row["id"] as? String==original.id && row["cwd"] as? String==original.cwd && row["modelProvider"] as? String==original.modelProvider &&
            row["source"] is String && row["threadSource"] as? String=="user" && row["ephemeral"] as? Bool==false &&
            (row["parentThreadId"]==nil || row["parentThreadId"] is NSNull)
        }
        func sameGoal(_ lhs:CodexGoal,_ rhs:CodexGoal) -> Bool {
            lhs.threadId==rhs.threadId && lhs.objective==rhs.objective && lhs.createdAt==rhs.createdAt && lhs.tokenBudget==rhs.tokenBudget &&
                (lhs.instanceID==nil || rhs.instanceID==nil || lhs.instanceID==rhs.instanceID)
        }
        func goalMatches(_ current:CodexGoal?) -> Bool {
            guard let previous=original.goal else {return current==nil}
            guard let current,sameGoal(previous,current) else{return false}
            return current.status == (previous.status == .active ? .paused:previous.status)
        }
        try verifyConnection()
        let summary=try connection.request("thread/read",["threadId":original.id,"includeTurns":false])
        guard let row=summary["thread"] as? JSONObject,sameRoot(row) else{return .skipped}
        if (row["status"] as? JSONObject)?["type"] as? String=="notLoaded" {
            // Load only the exact original persisted thread, after checking
            // that its last turn and Goal still belong to the stopped work.
            let page=try connection.request("thread/turns/list",["threadId":original.id,"limit":1,"itemsView":"notLoaded","sortDirection":"desc"],classifyError:true)
            guard let turns=page["data"] as? [JSONObject],turns.count<=1,
                  turns.first?["id"] as? String==original.turnID,
                  turns.first==nil || ["completed","interrupted","failed"].contains(turns.first?["status"] as? String ?? "") else{return .skipped}
            guard original.goal?.status == .active || turns.first?["status"] as? String=="interrupted" else{return .skipped}
            var goal=try CodexGoalTransport.decode(connection.request("thread/goal/get",["threadId":original.id]),threadID:original.id)
            if let value=goal,let stored=try? CodexGoalTransport.readDatabase(home:target.home,threadID:original.id),sameGoal(value,stored) {goal?.instanceID=stored.instanceID}
            guard goalMatches(goal) else{return .skipped}
            try verifyConnection()
            let loaded=try connection.request("thread/resume",["threadId":original.id,"excludeTurns":true])
            guard let value=loaded["thread"] as? JSONObject,sameRoot(value),
                  (value["status"] as? JSONObject)?["type"] as? String=="idle" else{return .skipped}
        }
        func current() throws -> CodexAccountTransitionThread? {
            let value=try CodexAccountTransitionLocal.thread(connection,id:original.id,home:target.home)
            guard value.continuable==true,value.cwd==original.cwd,value.modelProvider==original.modelProvider,
                  !value.active,value.turnID==original.turnID,value.blocker==nil,goalMatches(value.goal) else{return nil}
            guard original.goal?.status == .active || value.turnStatus=="interrupted" else{return nil}
            return value
        }
        guard try current() != nil else{return .skipped}
        try verifyConnection()
        guard try current() != nil else{return .skipped}
        try Task.checkCancellation()
        if let previous=original.goal,previous.status == .active {
            let result=try connection.request("thread/goal/set",["threadId":original.id,"status":"active","origin":"automatic"])
            guard let goal=try CodexGoalTransport.decode(result,threadID:original.id),goal.status == .active,sameGoal(previous,goal),
                  goal.tokensUsed>=previous.tokensUsed,goal.timeUsedSeconds>=previous.timeUsedSeconds else {
                throw AppError.message("Goal 이어가기 결과를 확인하지 못했습니다. 같은 명령은 반복하지 않습니다.")
            }
            return .goal
        }
        let result=try connection.request("turn/start",["threadId":original.id,"clientUserMessageId":receipt,
            "input":[["type":"text","text":"이어서 진행하자."]]])
        guard let turn=result["turn"] as? JSONObject,let id=turn["id"] as? String,!id.isEmpty,id.utf8.count<=256,
              let status=turn["status"] as? String,["inProgress","completed","failed","interrupted"].contains(status) else {
            throw AppError.message("대화 이어가기 결과를 확인하지 못했습니다. 같은 요청은 반복하지 않습니다.")
        }
        return .conversation
    }
}
