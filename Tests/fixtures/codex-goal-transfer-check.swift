import Foundation
@testable import AutoApproveCore
@main struct GoalTransferCheck {
    static func main() {
        do {
            let a=CommandLine.arguments
            guard a.count==4,let snapshot=try CodexGoalTransferStore.capture(home:a[1],threadID:a[3]) else{throw AppError.message("Owned source Goal missing")}
            try CodexGoalTransferStore.restore(snapshot,toHome:a[2],expectedSchema:snapshot.schemaFingerprint)
            guard let imported=try CodexGoalTransferStore.capture(home:a[2],threadID:a[3]),imported.row==snapshot.row,imported.continuationDeferred==snapshot.continuationDeferred else{throw AppError.message("Owned Goal differs after restore")}
            print("{\"verified\":true,\"exactGoalRow\":true,\"continuationDeferral\":true}")
        }catch{FileHandle.standardError.write(Data(error.localizedDescription.utf8));exit(1)}
    }
}
