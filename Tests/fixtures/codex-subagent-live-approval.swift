import Foundation
@testable import AutoApproveCore
@main struct Check { static func main() async throws {
 let home = CommandLine.arguments[1], thread = CommandLine.arguments[2]
 if CommandLine.arguments.count > 3 {
  let target = CodexReplyTarget(executable:"",home:home,threadID:thread)
  let result = try await CodexSubagentApprovals.poll(target:target,cwd:CommandLine.arguments[3],authorize:{ _ in true },completed:{ _,confirmed in precondition(confirmed) })
  precondition(result.responded == 1)
  print("production Swift approval acknowledged")
 } else {
  let c = try CodexQueueConnection(home:home)
  _ = try c.request("thread/resume", ["threadId":thread,"excludeTurns":true])
  _ = try c.request("thread/read", ["threadId":thread,"includeTurns":false])
  print("observer read completed")
 }
}}
