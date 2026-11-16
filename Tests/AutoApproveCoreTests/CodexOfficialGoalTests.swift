#if DEBUG
import Foundation
@testable import AutoApproveCore

extension ApprovalTests {
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
