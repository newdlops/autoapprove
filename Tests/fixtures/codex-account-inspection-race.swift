import Foundation
import AutoApproveCore
@main struct AccountInspectionRaceCheck {
    static func main() async {
        do {try await run()}catch {FileHandle.standardError.write(Data(error.localizedDescription.utf8));exit(1)}
    }
    static func run() async throws {
        let a=CommandLine.arguments
        let value=try await CodexAccountInspectionServices.live.read(.init(home:a[1],executable:a[2]))
        let expected=a[3]
        guard value.comparison.rawValue==expected else {
            throw AppError.message("Expected \(expected), got \(value.comparison.rawValue) with identity \(value.identity?.email ?? "none")")
        }
        print("{\"verified\":true,\"comparison\":\"\(expected)\"}")
    }
}
