import Foundation
import AutoApproveCore

@main struct SubagentGoalFixture {
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count>=6 else {throw AppError.message("Expected owned home, root thread, cwd, child thread and action")}
        let target=CodexReplyTarget(executable:"",home:args[1],threadID:args[2])
        let result:CodexSubagentGoal
        if args[5]=="read" {
            result=try await CodexSubagentGoalTransport.read(target:target,cwd:args[3],childID:args[4])
        } else {
            guard args.count==7,let action=CodexSubagentGoalAction(rawValue:args[5]) else {throw AppError.message("Unknown fixture action")}
            let expected=try JSONDecoder().decode(CodexSubagentGoal.self,from:Data(args[6].utf8))
            result=try await CodexSubagentGoalTransport.change(target:target,cwd:args[3],expected:expected,action:action,authorize:{})
        }
        print(String(decoding:try JSONEncoder().encode(result),as:UTF8.self))
    }
}
