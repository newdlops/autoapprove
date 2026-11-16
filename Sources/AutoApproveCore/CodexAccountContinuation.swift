import Foundation

public enum CodexAccountContinuationResult:String,Codable,Sendable {case goal,conversation,skipped}

/// Continues durably reserved work without typing into
/// its terminal or changing its saved model, working directory or draft.
enum CodexAccountContinuationLocal {
    static func resume(_ target:CodexAccountTransitionTarget,runtime:CodexAccountRuntime,expected:CodexAccountTransitionObservation,
                       original:CodexAccountTransitionThread,receipt:String) async throws -> CodexAccountContinuationResult {
        guard UUID(uuidString:original.id) != nil,UUID(uuidString:receipt) != nil,original.continuable==true,
              original.active || original.goal?.status == .active,let account=expected.savedAccount,expected.serverAccount==account else {
            throw AppError.message("전환으로 중단한 원래 작업과 재개 기록을 확인하지 못했습니다.")
        }
        let connection=try CodexQueueConnection(home:target.home,requestScopedDeadline:true)
        func verifyConnection() throws {try verifyAccount(target,runtime:runtime,expected:expected,account:account)}
        func sameThread(_ row:JSONObject) throws -> Bool {
            guard row["id"] as? String==original.id,row["cwd"] as? String==original.cwd,
                  row["modelProvider"] as? String==original.modelProvider,row["ephemeral"] as? Bool==false else{return false}
            if let owner=original.subagent {
                return try CodexAccountTransitionLocal.subagentOwner(connection,row:row)==owner
            }
            return row["source"] is String && row["threadSource"] as? String=="user" &&
                (row["parentThreadId"]==nil || row["parentThreadId"] is NSNull)
        }
        func sameGoal(_ lhs:CodexGoal,_ rhs:CodexGoal) -> Bool {
            lhs.threadId==rhs.threadId && lhs.objective==rhs.objective && lhs.createdAt==rhs.createdAt && lhs.tokenBudget==rhs.tokenBudget &&
                (lhs.instanceID==nil || rhs.instanceID==nil || lhs.instanceID==rhs.instanceID)
        }
        func goalMatches(_ current:CodexGoal?) -> Bool {
            guard let previous=original.goal else {return current==nil}
            guard let current,sameGoal(previous,current) else{return false}
            if original.subagent != nil {
                guard UUID(uuidString:previous.instanceID ?? "") != nil,current.instanceID==previous.instanceID,
                      current.tokensUsed>=previous.tokensUsed,current.timeUsedSeconds>=previous.timeUsedSeconds else{return false}
            }
            return current.status == (previous.status == .active ? .paused:previous.status)
        }
        try verifyConnection()
        let summary=try connection.request("thread/read",["threadId":original.id,"includeTurns":false])
        guard let row=summary["thread"] as? JSONObject,try sameThread(row) else{return .skipped}
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
            guard let value=loaded["thread"] as? JSONObject,try sameThread(value),
                  (value["status"] as? JSONObject)?["type"] as? String=="idle" else{return .skipped}
        }
        func current() throws -> CodexAccountTransitionThread? {
            let value=try CodexAccountTransitionLocal.thread(connection,id:original.id,home:target.home,allowSubagent:true)
            guard value.continuable==true,value.cwd==original.cwd,value.modelProvider==original.modelProvider,
                  value.subagent==original.subagent,
                  !value.active,value.turnID==original.turnID,value.blocker==nil,goalMatches(value.goal) else{return nil}
            guard original.goal?.status == .active || value.turnStatus=="interrupted" else{return nil}
            return value
        }
        guard try current() != nil else{return .skipped}
        try verifyConnection()
        guard let stopped=try current() else{return .skipped}
        try Task.checkCancellation()
        if let previous=original.goal,previous.status == .active {
            if let owner=original.subagent,let paused=stopped.goal {
                let paths=AppPaths();try paths.prepare()
                let selected=CodexReplyTarget(executable:runtime.context.executable,home:target.home,threadID:owner.rootThreadID)
                let child=CodexSubagentGoal(rootThreadID:owner.rootThreadID,threadID:original.id,parentThreadID:owner.parentThreadID,
                    goal:paused,executionState:"idle",turnID:stopped.turnID)
                _ = try await CodexSubagentGoalTransport.resumeOfficial(target:selected,cwd:owner.rootCwd,expected:child,
                    requestID:UUID(uuidString:receipt)!,stateDirectory:paths.directory,authorize:{
                        try verifyAccount(target,runtime:runtime,expected:expected,account:account)
                        let connection=try CodexQueueConnection(home:target.home)
                        let value=try CodexAccountTransitionLocal.thread(connection,id:original.id,home:target.home,allowSubagent:true)
                        guard value.subagent==owner,value.turnID==original.turnID,!value.active,
                              value.cwd==original.cwd,value.modelProvider==original.modelProvider,
                              value.blocker==nil || value.blocker=="활성 Goal",
                              let goal=value.goal,goal.instanceID==paused.instanceID,goal.objective==paused.objective,
                              goal.createdAt==paused.createdAt,goal.tokenBudget==paused.tokenBudget,
                              [.paused,.active].contains(goal.status),goal.tokensUsed>=paused.tokensUsed,
                              goal.timeUsedSeconds>=paused.timeUsedSeconds else {
                            throw AppError.message("하위 Goal 재개 직전 원래 작업·부모·Goal이 바뀌었습니다. 새 작업은 시작하지 않았습니다.")
                        }
                        // An active Goal masks these blockers in the summary.
                        // Recheck them independently after restoring status.
                        for method in ["thread/queue/list","thread/backgroundTerminals/list"] {
                            let page=try connection.request(method,["threadId":original.id,"limit":1])
                            guard let rows=page["data"] as? [JSONObject],rows.isEmpty,
                                  try CodexAccountTransitionLocal.nextCursor(page)==nil else {
                                throw AppError.message("하위 대화에 새 대기 입력·백그라운드 작업이 있습니다. 재개를 보류했습니다.")
                            }
                        }
                    })
                return .goal
            }
            let result=try connection.request("thread/goal/set",["threadId":original.id,"status":"active","origin":"automatic"])
            guard let goal=try CodexGoalTransport.decode(result,threadID:original.id),goal.status == .active,sameGoal(previous,goal),
                  goal.tokensUsed>=previous.tokensUsed,goal.timeUsedSeconds>=previous.timeUsedSeconds else {
                throw AppError.message("Goal 이어가기 결과를 확인하지 못했습니다. 같은 명령은 반복하지 않습니다.")
            }
            return .goal
        }
        guard original.subagent==nil else{return .skipped}
        let result=try connection.request("turn/start",["threadId":original.id,"clientUserMessageId":receipt,
            "input":[["type":"text","text":"이어서 진행하자."]]])
        guard let turn=result["turn"] as? JSONObject,let id=turn["id"] as? String,!id.isEmpty,id.utf8.count<=256,
              let status=turn["status"] as? String,["inProgress","completed","failed","interrupted"].contains(status) else {
            throw AppError.message("대화 이어가기 결과를 확인하지 못했습니다. 같은 요청은 반복하지 않습니다.")
        }
        return .conversation
    }

    private static func verifyAccount(_ target:CodexAccountTransitionTarget,runtime:CodexAccountRuntime,
                                      expected:CodexAccountTransitionObservation,account:String) throws {
        try Task.checkCancellation()
        let connection=try CodexQueueConnection(home:target.home)
        guard try CodexAccountTransitionLocal.identity(target,runtime:runtime)==expected.serverID,
              try CodexAccountMetadataProcess.read(target,runtime:runtime)==account,
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
}
