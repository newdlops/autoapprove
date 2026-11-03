import Foundation
import Darwin
import CSQLite
@testable import AutoApproveCore

@main struct RolloutReturnCrashCheck {
    static let thread="00000000-0000-4000-8000-000000000094"
    static func main(){do{try run()}catch{FileHandle.standardError.write(Data(error.localizedDescription.utf8));exit(1)}}
    static func require(_ value:Bool)throws{guard value else{throw AppError.message("Owned rollout crash assertion failed")}}
    static func run()throws {
        let args=CommandLine.arguments
        guard args.count==3,args[1].hasPrefix("/private/tmp/aa-rollout-return-crash-") else{throw AppError.message("Owned crash root required")}
        let root=args[1],mode=args[2],store=try AuditStore(path:root+"/audit.sqlite"),journal=try CodexMigrationJournal(store:store)
        let sourcePath=root+"/b/archived_sessions/rollout-"+thread+".jsonl"
        if mode=="create" {
            let schema=try String(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("codex-goals-0.166.sql"),encoding:.utf8)
            for n in ["a","b"] {
                let home=root+"/"+n
                try FileManager.default.createDirectory(atPath:home+"/archived_sessions",withIntermediateDirectories:true)
                var db:OpaquePointer?;try require(sqlite3_open(home+"/goals_1.sqlite",&db)==SQLITE_OK);defer{sqlite3_close(db)}
                let tokens=n=="a" ? 37:73
                try require(sqlite3_exec(db,schema+"; INSERT INTO thread_goals VALUES ('\(thread)','owned-instance','Owned goal','paused',1234,\(tokens),19,1001,2002);",nil,nil,nil)==SQLITE_OK)
                try Data("{\"history\":\"\(n)\"}\n".utf8).write(to:URL(fileURLWithPath:home+"/archived_sessions/rollout-"+thread+".jsonl"))
            }
            let retired=try CodexMigrationRetirement.capture(home:root+"/a",threadID:thread,rolloutPath:root+"/a/archived_sessions/rollout-"+thread+".jsonl")
            let first=try journal.create(id:UUID().uuidString,homes:[root+"/a",root+"/b"],payload:Data())
            _=try journal.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:thread,previous:nil,destination:first.homes.first{$0.path.hasSuffix("/b")}!,retirement:retired)])
            try journal.release(id:first.id)
            let owner=try journal.owner(threadID:thread)!,request=try journal.create(id:UUID().uuidString,homes:[root+"/b",root+"/a"],payload:Data())
            let backup=try journal.backupRetired(retired,expectedOwner:owner,requestID:request.id,expectedRevision:1)
            let goals=CodexGoalReturn(journal:journal)
            _=try goals.prepare(backup:backup,source:CodexGoalTransferStore.captureSlot(home:root+"/b",threadID:thread),expectedRevision:1)
            try require(try goals.apply(id:request.id) == .applied)
            try store.set("owned-request",request.id)
            print("{\"created\":true}");return
        }
        guard let id=store.value("owned-request") else{throw AppError.message("Owned request missing")}
        _=try journal.repair(id:id)
        let goals=CodexGoalReturn(journal:journal),engine=CodexRolloutReturn(journal:journal)
        let source=try CodexMigrationRetirement.capture(home:root+"/b",threadID:thread,rolloutPath:sourcePath)
        if mode.hasPrefix("crash-") {
            if mode=="crash-no-stage" || mode=="crash-staged" {
                var state=try goals.state(id:id);state.rollout = .init(source:source,stage:.staging)
                let record=try journal.load(id:id)!.record
                _=try journal.save(id:id,payload:JSONEncoder().encode(state),expectedRevision:record.revision)
                if mode=="crash-no-stage"{_exit(70)}
                _=try CodexMigrationRolloutStaging.create(source:source,backup:state.backup)
                _exit(71)
            }
            _=try engine.prepare(id:id,source:source)
            if mode=="crash-verified"{try require(try engine.apply(id:id) == .applied);_exit(74)}
            var state=try goals.state(id:id);state.rollout?.stage = .attempted
            let prior=try journal.load(id:id)!.record
            let attempted=try journal.save(id:id,payload:JSONEncoder().encode(state),expectedRevision:prior.revision)
            if mode=="crash-before-rename"{_exit(72)}
            guard mode=="crash-after-rename" else{throw AppError.message("Unknown owned crash mode")}
            try CodexMigrationRolloutStaging.install(source:source,backup:state.backup,staged:state.rollout!.staged!) {
                try journal.validateReservation(attempted)
            }
            _exit(73) // Actual synced rename, before any verified journal write.
        }
        let initial=try goals.state(id:id),record=try journal.load(id:id)!.record
        try initial.backup.verify();try source.verifyCurrent()
        var result:[String:Any]=["goalTokens":try CodexGoalTransferStore.captureSlot(home:root+"/a",threadID:thread).row!.tokensUsed,
            "ownerRemainsSource":try journal.owner(threadID:thread)?.home.path==root+"/b"]
        if mode=="inspect-no-stage" {
            var blocked=0
            do{_=try engine.recoverStaging(id:id)}catch{blocked+=1}
            do{_=try engine.prepare(id:id,source:source)}catch{blocked+=1}
            do{_=try engine.apply(id:id)}catch{blocked+=1}
            try require(blocked==3)
            try require(!FileManager.default.fileExists(atPath:root+"/a/"+CodexMigrationRolloutStaging.relative(initial.backup)))
            try require(try journal.load(id:id)!.record==record)
            result["missingStageNotReplayed"]=true
        }else if mode=="inspect-staged" {
            let before=try CodexMigrationRolloutStaging.inspect(backup:initial.backup)
            let recovered=try engine.recoverStaging(id:id)
            try require(recovered.rollout?.staged==before)
            try require(try engine.apply(id:id) == .applied)
            result["completeStageAdoptedWithoutCopy"]=true
        }else{
            let observed=try engine.observe(id:id)
            var rejected=false;do{_=try engine.apply(id:id)}catch{rejected=true}
            try require(rejected);try require(try journal.load(id:id)!.record==record)
            result["observed"]=observed.rawValue;result["applyRejected"]=true;result["stage"]=initial.rollout!.stage.rawValue
        }
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self))
    }
}
