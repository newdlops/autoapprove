import Foundation
import AutoApproveCore

@main struct GoalProtocolCheck {
    static func main() async throws {
        let home=CommandLine.arguments[1],mode=CommandLine.arguments[2],thread="00000000-0000-4000-8000-000000000209"
        let target=CodexReplyTarget(executable:"",home:home,threadID:thread)
        guard let goal=try await CodexGoalTransport.live.read(target,home),goal.status == .blocked else {throw AppError.message("Missing synthetic Goal")}
        if mode=="replaced" {
            do {_ = try await CodexGoalTransport.live.change(target,home,goal,.cancel);throw AppError.message("Changed Goal was cleared")}
            catch let error as RemoteHTTPError {guard error.status==409 else {throw error}}
        } else {
            guard let active=try await CodexGoalTransport.live.change(target,home,goal,.resume),active.status == .active else {throw AppError.message("Goal was not resumed")}
            guard try await CodexGoalTransport.live.change(target,home,active,.cancel)==nil else {throw AppError.message("Goal was not cleared")}
            guard try await CodexGoalTransport.live.read(target,home)==nil else {throw AppError.message("Cleared Goal still present")}
        }
        print("Goal protocol passed: "+mode)
    }
}
