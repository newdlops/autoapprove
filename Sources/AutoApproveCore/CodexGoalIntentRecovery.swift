import Foundation

enum CodexGoalIntentRecovery {
    static func sameGoal(_ original:CodexSubagentGoal,_ current:CodexSubagentGoal)->Bool {
        guard let a=original.goal,let b=current.goal,let id=a.instanceID,UUID(uuidString:id) != nil else{return false}
        return original.rootThreadID==current.rootThreadID && original.parentThreadID==current.parentThreadID
            && original.threadID==current.threadID && b.instanceID==id && a.threadId==b.threadId
            && a.objective==b.objective && a.createdAt==b.createdAt && a.tokenBudget==b.tokenBudget
            && b.tokensUsed>=a.tokensUsed && b.timeUsedSeconds>=a.timeUsedSeconds
    }
    static func desired(_ action:CodexSubagentGoalAction)->CodexGoal.Status {action == .resume ? .active:.paused}
}
