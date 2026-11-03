import Foundation
import AutoApproveCore
@main struct AccountInspectionLiveCheck {
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count==3 else{throw AppError.message("Owned inspection arguments required")}
        let result=try await CodexAccountInspectionServices.live.read(.init(home:args[1],executable:args[2]))
        guard result.comparison == .signedOut,result.identity?.authenticated==false,result.connectedSessions==0 else{
            throw AppError.message("Owned signed-out inspection failed: "+result.comparison.rawValue+" "+result.detail)
        }
        print("{\"verified\":true,\"comparison\":\"\(result.comparison.rawValue)\"}")
    }
}

