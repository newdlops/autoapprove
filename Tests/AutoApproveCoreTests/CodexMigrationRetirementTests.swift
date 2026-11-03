#if DEBUG
import Foundation
import CSQLite
import Darwin
@testable import AutoApproveCore

private final class RetirementFixture {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-retirement-"+UUID().uuidString)
    let thread="00000000-0000-4000-8000-000000000081"
    let store:AuditStore
    init()throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        store=try AuditStore(path:root.appendingPathComponent("audit.sqlite").path)
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/codex-goals-0.166.sql")
        let schema=try String(contentsOf:fixture,encoding:.utf8)
        for name in ["a","b","c"] {
            try FileManager.default.createDirectory(atPath:home(name)+"/archived_sessions",withIntermediateDirectories:true)
            var db:OpaquePointer?;guard sqlite3_open(home(name)+"/goals_1.sqlite",&db)==SQLITE_OK else{throw AppError.message("Owned DB failed")}
            defer{sqlite3_close(db)}
            guard sqlite3_exec(db,schema,nil,nil,nil)==SQLITE_OK else{throw AppError.message("Owned schema failed")}
            try Data("{\"type\":\"owned-synthetic-history\"}\n".utf8).write(to:URL(fileURLWithPath:rollout(name)))
        }
    }
    deinit{try? FileManager.default.removeItem(at:root)}
    func home(_ n:String)->String {root.appendingPathComponent(n).path}
    func rollout(_ n:String)->String {home(n)+"/archived_sessions/rollout-"+thread+".jsonl"}
    func retire(_ j:CodexMigrationJournal,_ source:String,_ destination:String)throws->CodexMigrationOwner {
        let retired=try CodexMigrationRetirement.capture(home:home(source),threadID:thread,rolloutPath:rollout(source))
        let record=try j.create(id:UUID().uuidString,homes:[home(source),home(destination)],payload:Data("owned verified transition".utf8))
        let dest=record.homes.first{$0.path.hasSuffix("/"+destination)}!
        _=try j.complete(id:record.id,payload:Data(),expectedRevision:record.revision,ownership:[.init(threadID:thread,previous:try j.owner(threadID:thread),destination:dest,retirement:retired)])
        try j.release(id:record.id)
        return try j.owner(threadID:thread)!
    }
}
extension ApprovalTests {
    func testMigrationRetirementBindsCurrentOwnerAndHistoricalHome()throws {
        let f=try RetirementFixture(),j=try CodexMigrationJournal(store:f.store)
        let b=try f.retire(j,"a","b")
        let retired=try j.retired(threadID:f.thread,toHome:f.home("a"),expectedOwner:b)
        try expectEqual(retired.goal.threadID,f.thread);try expectNil(retired.goal.row)
        try retired.verifyCurrent()
        let c=try f.retire(j,"b","c")
        try expectThrows(j.retired(threadID:f.thread,toHome:f.home("a"),expectedOwner:b))
        let historical=try j.retired(threadID:f.thread,toHome:f.home("a"),expectedOwner:c)
        try expectEqual(historical,retired)
        try expectThrows(j.retired(threadID:f.thread,toHome:f.home("c"),expectedOwner:c))
    }
    func testMigrationRetirementRejectsChangedHistoryAndGoal()throws {
        let f=try RetirementFixture(),j=try CodexMigrationJournal(store:f.store),b=try f.retire(j,"a","b")
        let old=try j.retired(threadID:f.thread,toHome:f.home("a"),expectedOwner:b)
        try Data("changed history".utf8).write(to:URL(fileURLWithPath:f.rollout("a")))
        try expectThrows(old.verifyCurrent())
        try expectThrows(j.retired(threadID:f.thread,toHome:f.home("a"),expectedOwner:b))
        let f2=try RetirementFixture(),j2=try CodexMigrationJournal(store:f2.store),b2=try f2.retire(j2,"a","b")
        var db:OpaquePointer?;try expectEqual(sqlite3_open(f2.home("a")+"/goals_1.sqlite",&db),SQLITE_OK);defer{sqlite3_close(db)}
        try expectEqual(sqlite3_exec(db,"INSERT INTO thread_goals VALUES ('\(f2.thread)','new','Keep new Goal','paused',100,4,2,100,200)",nil,nil,nil),SQLITE_OK)
        try expectThrows(j2.retired(threadID:f2.thread,toHome:f2.home("a"),expectedOwner:b2))
    }
    func testMigrationRetirementBackupIsDurableExactAndSingleUse()throws {
        let f=try RetirementFixture(),j=try CodexMigrationJournal(store:f.store),b=try f.retire(j,"a","b")
        let retired=try j.retired(threadID:f.thread,toHome:f.home("a"),expectedOwner:b)
        let request=try j.create(id:UUID().uuidString,homes:[f.home("b"),f.home("a")],payload:Data("return reserved".utf8))
        let backup=try j.backupRetired(retired,expectedOwner:b,requestID:request.id,expectedRevision:request.revision)
        try expectEqual(try Data(contentsOf:URL(fileURLWithPath:backup.rolloutPath)),try Data(contentsOf:URL(fileURLWithPath:f.rollout("a"))))
        let saved=try JSONDecoder().decode(CodexMigrationRetiredBackup.Manifest.self,from:Data(contentsOf:URL(fileURLWithPath:backup.recordPath)))
        try expectEqual(saved.retirement,retired);try expectEqual(saved.requestDigest,request.digest);try backup.verify()
        try expectThrows(j.backupRetired(retired,expectedOwner:b,requestID:request.id,expectedRevision:request.revision))
        try Data("corrupt backup".utf8).write(to:URL(fileURLWithPath:backup.rolloutPath))
        try expectThrows(backup.verify())
        try retired.verifyCurrent()
    }
    func testMigrationRetirementRejectsLinkedUnleasedAndWrongScopeBackups()throws {
        let f=try RetirementFixture(),j=try CodexMigrationJournal(store:f.store),b=try f.retire(j,"a","b")
        let retired=try j.retired(threadID:f.thread,toHome:f.home("a"),expectedOwner:b)
        try expectThrows(CodexMigrationRetirement.capture(home:f.home("b"),threadID:f.thread,rolloutPath:f.rollout("a")))
        let linked=f.home("a")+"/archived_sessions/link-"+f.thread+".jsonl"
        try FileManager.default.createSymbolicLink(atPath:linked,withDestinationPath:f.rollout("a"))
        try expectThrows(CodexMigrationRetirement.capture(home:f.home("a"),threadID:f.thread,rolloutPath:linked))
        let request=try j.create(id:UUID().uuidString,homes:[f.home("b"),f.home("a")],payload:Data())
        let foreign=try CodexMigrationJournal(store:f.store)
        try expectThrows(foreign.backupRetired(retired,expectedOwner:b,requestID:request.id,expectedRevision:1))
        try expectThrows(j.backupRetired(retired,expectedOwner:b,requestID:request.id,expectedRevision:99))
        let folder=retired.goal.sourceHome+"/.autoapprove-migrations/backups"
        try FileManager.default.createSymbolicLink(atPath:folder,withDestinationPath:f.home("c"))
        try expectThrows(j.backupRetired(retired,expectedOwner:b,requestID:request.id,expectedRevision:1))
        try retired.verifyCurrent()
    }
    func testMigrationRetirementBackupRejectsChangedRequestBinding()throws {
        let f=try RetirementFixture(),j=try CodexMigrationJournal(store:f.store),b=try f.retire(j,"a","b")
        let retired=try j.retired(threadID:f.thread,toHome:f.home("a"),expectedOwner:b)
        let request=try j.create(id:UUID().uuidString,homes:[f.home("b"),f.home("a")],payload:Data())
        let backup=try j.backupRetired(retired,expectedOwner:b,requestID:request.id,expectedRevision:1)
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(backup)) as! [String:Any]
        json["requestDigest"]=String(repeating:"0",count:64)
        let changed=try JSONDecoder().decode(CodexMigrationRetiredBackup.self,from:JSONSerialization.data(withJSONObject:json))
        try expectThrows(changed.verify())
        try backup.verify()
    }
    func testMigrationRetirementBackupRequiresCurrentConsistentReservation()throws {
        let f=try RetirementFixture(),j=try CodexMigrationJournal(store:f.store),b=try f.retire(j,"a","b")
        let retired=try j.retired(threadID:f.thread,toHome:f.home("a"),expectedOwner:b)
        let request=try j.create(id:UUID().uuidString,homes:[f.home("b"),f.home("a")],payload:Data())
        let backup=try j.backupRetired(retired,expectedOwner:b,requestID:request.id,expectedRevision:1)
        try j.verifyBackup(backup,expectedRevision:1)
        let mirror=request.homes.last!.path+"/.autoapprove-migrations/"+request.id+".json"
        let saved=try Data(contentsOf:URL(fileURLWithPath:mirror))
        try FileManager.default.removeItem(atPath:mirror)
        try expectFalse(try j.load(id:request.id)!.consistent)
        try expectThrows(j.verifyBackup(backup,expectedRevision:1))
        try saved.write(to:URL(fileURLWithPath:mirror));try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:mirror)
        try j.verifyBackup(backup,expectedRevision:1)
        _=try j.save(id:request.id,payload:Data("new stage".utf8),expectedRevision:1)
        try expectThrows(j.verifyBackup(backup,expectedRevision:2))
        try backup.verify();try retired.verifyCurrent()
    }
}
#endif
