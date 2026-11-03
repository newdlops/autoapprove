import Foundation
@testable import AutoApproveCore
@main struct GoalTransferCheck {
    static func main() {
        do {
            let a=CommandLine.arguments
            if a.count==5,a[1]=="--native-restore" {try NativeReturnBridge.run(a);return}
            if a.count==6,a[1]=="--return-goal" {
                guard a[2].hasPrefix("/private/tmp/aa-cross-home-"),a[3].hasPrefix("/private/tmp/aa-cross-home-") else{throw AppError.message("Owned return homes required")}
                let store=try AuditStore(path:URL(fileURLWithPath:a[2]).deletingLastPathComponent().appendingPathComponent("retirement-audit.sqlite").path)
                let journal=try CodexMigrationJournal(store:store)
                guard let owner=try journal.owner(threadID:a[4]),owner.home.path==a[2] else{throw AppError.message("Owned return source mismatch")}
                let retired=try journal.retired(threadID:a[4],toHome:a[3],expectedOwner:owner)
                let sourceRetirement=try CodexMigrationRetirement.capture(home:a[2],threadID:a[4],rolloutPath:a[5])
                let request=try journal.create(id:UUID().uuidString,homes:[a[2],a[3]],payload:Data("Owned return after closed writer".utf8))
                let backup=try journal.backupRetired(retired,expectedOwner:owner,requestID:request.id,expectedRevision:1)
                let engine=CodexGoalReturn(journal:journal)
                _=try engine.prepare(backup:backup,source:sourceRetirement.goal,expectedRevision:1)
                let result=try engine.apply(id:request.id)
                guard result == .applied || result == .unchanged else{throw AppError.message("Owned return not applied")}
                let target=try CodexGoalTransferStore.captureSlot(home:a[3],threadID:a[4])
                guard target.row==sourceRetirement.goal.row,target.continuationDeferred==sourceRetirement.goal.continuationDeferred else{throw AppError.message("Owned return differs")}
                let history=CodexRolloutReturn(journal:journal)
                _=try history.prepare(id:request.id,source:sourceRetirement)
                guard try history.apply(id:request.id) == .applied,try history.observe(id:request.id) == .applied else{throw AppError.message("Owned history return differs")}
                try backup.verify();try sourceRetirement.verifyCurrent()
                try store.set("owned-goal-return-id",request.id)
                try store.set("owned-goal-return-source",String(decoding:try JSONEncoder().encode(sourceRetirement),as:UTF8.self))
                print("{\"verified\":true,\"exactGoalReturned\":true,\"latestHistoryReturned\":true,\"nativeOwnershipCommitted\":false}")
                return
            }
            if a.count==6,a[1]=="--record-retirement" {
                guard a[2].hasPrefix("/private/tmp/aa-cross-home-"),a[3].hasPrefix("/private/tmp/aa-cross-home-") else{throw AppError.message("Owned retirement homes required")}
                let journal=try CodexMigrationJournal(store:AuditStore(path:URL(fileURLWithPath:a[2]).deletingLastPathComponent().appendingPathComponent("retirement-audit.sqlite").path))
                let retired=try CodexMigrationRetirement.capture(home:a[2],threadID:a[4],rolloutPath:a[5])
                let record=try journal.create(id:UUID().uuidString,homes:[a[2],a[3]],payload:Data("Owned fixture verified native destination".utf8))
                guard let destination=record.homes.first(where:{$0.path==a[3]}) else{throw AppError.message("Owned destination not canonical")}
                _=try journal.complete(id:record.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:a[4],previous:nil,destination:destination,retirement:retired)])
                try journal.release(id:record.id)
                guard let owner=try journal.owner(threadID:a[4]),try journal.retired(threadID:a[4],toHome:a[2],expectedOwner:owner)==retired else{throw AppError.message("Owned retirement not verified")}
                print("{\"verified\":true,\"nativeRetirementWitnessed\":true}")
                return
            }
            if a.count==5,a[1]=="--backup-retired" {
                guard a[2].hasPrefix("/private/tmp/aa-cross-home-"),a[3].hasPrefix("/private/tmp/aa-cross-home-") else{throw AppError.message("Owned backup homes required")}
                let store=try AuditStore(path:URL(fileURLWithPath:a[2]).deletingLastPathComponent().appendingPathComponent("retirement-audit.sqlite").path)
                let journal=try CodexMigrationJournal(store:store)
                guard let owner=try journal.owner(threadID:a[4]),owner.home.path==a[3] else{throw AppError.message("Owned current owner missing")}
                let retired=try journal.retired(threadID:a[4],toHome:a[2],expectedOwner:owner)
                let request=try journal.create(id:UUID().uuidString,homes:[a[3],a[2]],payload:Data("Owned backup-only return".utf8))
                let backup=try journal.backupRetired(retired,expectedOwner:owner,requestID:request.id,expectedRevision:1)
                try backup.verify();try retired.verifyCurrent()
                try store.set("owned-retired-backup",String(decoding:try JSONEncoder().encode(backup),as:UTF8.self))
                _=try journal.save(id:request.id,payload:Data("Cancelled before any replacement".utf8),expectedRevision:1,terminal:true)
                try journal.release(id:request.id)
                print("{\"verified\":true,\"retiredBackupVerified\":true,\"goalReplacementPerformed\":false}")
                return
            }
            if a.count==3,a[1]=="--verify-retired-backup" {
                guard a[2].hasPrefix("/private/tmp/aa-cross-home-") else{throw AppError.message("Owned backup audit root required")}
                let store=try AuditStore(path:a[2]+"/retirement-audit.sqlite")
                guard let encoded=store.value("owned-retired-backup") else{throw AppError.message("Owned backup descriptor missing")}
                let backup=try JSONDecoder().decode(CodexMigrationRetiredBackup.self,from:Data(encoded.utf8))
                try backup.verify()
                let journal=try CodexMigrationJournal(store:store)
                var rejected=false
                do{try journal.verifyBackup(backup,expectedRevision:1)}catch{rejected=true}
                guard rejected else{throw AppError.message("Cancelled backup reservation must not authorize replacement")}
                print("{\"verified\":true,\"backupSurvivedProcessExit\":true,\"cancelledReservationRejected\":true}")
                return
            }
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
