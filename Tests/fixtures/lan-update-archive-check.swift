import Foundation
import AutoApproveCore

@main struct UpdateArchiveCheck {
    static func main()throws {
        guard CommandLine.arguments.count==2 else{throw AppError.message("Expected update ZIP")}
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]),options:.mappedIfSafe)
        try LANUpdateInstallation.validateArchive(data)
        print("PASS update archive accepted by production validator (\(data.count) bytes)")
    }
}
