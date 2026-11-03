import Foundation
@testable import AutoApproveCore
@main struct GoalTransferCheck {
    static func main() {
        do {
            let a=CommandLine.arguments
            if a.count==4,a[1]=="--cleared-slot" {
                guard a[2].hasPrefix("/private/tmp/aa-cross-home-") else{throw AppError.message("Owned cleared-slot home required")}
                let slot=try CodexGoalTransferStore.captureSlot(home:a[2],threadID:a[3])
                guard slot.row==nil,!slot.continuationDeferred else{throw AppError.message("Owned Goal was not cleared")}
                try CodexGoalTransferStore.verifyCurrent(slot)
                print("{\"verified\":true,\"clearedGoalSlotWitnessed\":true}")
                return
            }
            guard a.count==4,let snapshot=try CodexGoalTransferStore.capture(home:a[1],threadID:a[3]) else{throw AppError.message("Owned source Goal missing")}
            try CodexGoalTransferStore.restore(snapshot,toHome:a[2],expectedSchema:snapshot.schemaFingerprint)
            guard let imported=try CodexGoalTransferStore.capture(home:a[2],threadID:a[3]),imported.row==snapshot.row,imported.continuationDeferred==snapshot.continuationDeferred else{throw AppError.message("Owned Goal differs after restore")}
            print("{\"verified\":true,\"exactGoalRow\":true,\"continuationDeferral\":true}")
        }catch{FileHandle.standardError.write(Data(error.localizedDescription.utf8));exit(1)}
    }
}
