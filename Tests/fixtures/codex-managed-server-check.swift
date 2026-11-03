import Foundation
import AutoApproveCore

@main struct ManagedServerCheck {
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count==7 else{throw AppError.message("Owned fixture arguments required")}
        let service=CodexManagedServerServices.local(userHome:args[1],executable:args[2]=="PATH" ? nil:args[2])
        let before=try await service.inspect(args[3],[])
        guard before.phase.rawValue==args[4] else{throw AppError.message("Before: "+before.phase.rawValue+" "+before.detail)}
        if args[6]=="feature-denied" {
            do {_ = try await service.prepare(args[3],[]);throw AppError.message("Denied feature write claimed success")}
            catch {guard error.localizedDescription.contains("자동 시작 설정을 적용하지 못했습니다") else{throw error}}
            print("{\"verified\":true}");return
        }
        let after=try await service.prepare(args[3],[])
        guard after.phase.rawValue==args[5] else{throw AppError.message("After: "+after.phase.rawValue+" "+after.detail)}
        if after.phase == .running {
            guard after.autoStartEnabled == true else{throw AppError.message("Effective auto-start setting not enabled")}
            guard try await service.prepare(args[3],[]).phase == .running else{throw AppError.message("Already-running preparation changed state")}
        }
        print("{\"verified\":true}")
    }
}
