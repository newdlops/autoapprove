import Foundation
import AutoApproveCore

@main struct SignedOutRecovery {
    @MainActor static func main() async throws {
        let args=CommandLine.arguments
        guard args.count==3,args[1].hasPrefix("/private/tmp/aa-signed-out-") else {throw AppError.message("Owned temporary home required")}
        let target=CodexAccountTransitionTarget(home:args[1],executable:args[2])
        let services=CodexAccountTransitionServices.live
        let before=try await services.observe(target)
        guard before.savedAccount != nil,before.serverAccount==nil,before.threads.isEmpty else {throw AppError.message("Expected saved login and signed-out empty server")}
        let coordinator=CodexAccountTransitionCoordinator(target:target,services:services,save:{_ in})
        for _ in 0..<40 {
            await coordinator.check()
            if coordinator.state.phase == .complete {
                let after=try await services.observe(target)
                guard after.serverAccount==before.savedAccount,after.serverID != before.serverID,after.threads.isEmpty else {throw AppError.message("Restart did not apply saved login")}
                print("{\"verified\":true,\"signedOutServerRecovered\":true,\"syntheticAuthOnly\":true,\"existingSessionsTouched\":false}")
                return
            }
            if [.review,.unsupported].contains(coordinator.state.phase) {throw AppError.message(coordinator.state.detail)}
            try await Task.sleep(for:.milliseconds(250))
        }
        throw AppError.message("Owned recovery did not complete")
    }
}
