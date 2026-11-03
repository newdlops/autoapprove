#if DEBUG
import Foundation
import CSQLite
@testable import AutoApproveCore

private final class OwnershipFixture {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-owner-journal-"+UUID().uuidString)
    let thread="00000000-0000-4000-8000-000000000071"
    let second="00000000-0000-4000-8000-000000000072"
    var path:String {root.appendingPathComponent("audit.sqlite").path}
    init()throws {for name in ["a","b","c"]{try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true)}}
    deinit{try? FileManager.default.removeItem(at:root)}
    func home(_ name:String)->String {root.appendingPathComponent(name).path}
    func journal()throws->CodexMigrationJournal {try .init(store:AuditStore(path:path))}
    func reserve(_ j:CodexMigrationJournal,_ a:String="a",_ b:String="b")throws->CodexMigrationJournalRecord {
        try j.create(id:UUID().uuidString,homes:[home(a),home(b)],payload:Data("reserved".utf8))
    }
    func ref(_ record:CodexMigrationJournalRecord,_ name:String)->CodexMigrationJournalRecord.Home {
        record.homes.first{$0.path.hasSuffix("/"+name)}!
    }
    func exec(_ sql:String)throws {
        var db:OpaquePointer?;guard sqlite3_open(path,&db)==SQLITE_OK else{throw AppError.message("Owned DB open failed")};defer{sqlite3_close(db)}
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw AppError.message("Owned DB mutation failed")}
    }
}
extension ApprovalTests {
    func testMigrationOwnershipCommitsCohortAndRoundTripLineage()throws {
        let f=try OwnershipFixture(),j=try f.journal(),first=try f.reserve(j)
        let b=f.ref(first,"b")
        let complete=try j.complete(id:first.id,payload:Data("verified A to B".utf8),expectedRevision:1,ownership:[
            .init(threadID:f.thread,previous:nil,destination:b),.init(threadID:f.second,previous:nil,destination:b)])
        try expectEqual(complete.formatVersion,2);try expect(complete.terminal)
        let owner=try j.owner(threadID:f.thread)!,other=try j.owner(threadID:f.second)!
        try expectEqual(owner.revision,1);try expectEqual(owner.home,b);try expectEqual(owner.journalDigest,complete.digest)
        try j.release(id:first.id)
        let next=try f.reserve(j,"b","a"),a=f.ref(next,"a")
        _=try j.complete(id:next.id,payload:Data("verified B to A".utf8),expectedRevision:1,ownership:[.init(threadID:f.thread,previous:owner,destination:a)])
        let returned=try j.owner(threadID:f.thread)!
        try expectEqual(returned.revision,2);try expectEqual(returned.home,a)
        try expectEqual(try j.owner(threadID:f.second),other)
        try expectEqual(try f.journal().owner(threadID:f.thread),returned)
    }
    func testMigrationOwnershipRejectsStaleAndForeignOwnerWithoutCommit()throws {
        let f=try OwnershipFixture(),j=try f.journal(),first=try f.reserve(j)
        _=try j.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:f.thread,previous:nil,destination:f.ref(first,"b"))])
        let old=try j.owner(threadID:f.thread)!
        try j.release(id:first.id)
        let second=try f.reserve(j,"b","c")
        _=try j.complete(id:second.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:f.thread,previous:old,destination:f.ref(second,"c"))])
        let current=try j.owner(threadID:f.thread)!
        try j.release(id:second.id)
        let stale=try f.reserve(j)
        try expectThrows(j.complete(id:stale.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:f.thread,previous:old,destination:f.ref(stale,"a"))]))
        try expectEqual(try j.owner(threadID:f.thread),current)
        try expectEqual(try j.load(id:stale.id)!.record,stale)
        try expectThrows(j.complete(id:stale.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:f.thread,previous:nil,destination:f.ref(stale,"a"))]))
    }
    func testMigrationOwnershipRollsBackWholeCohortAndCentralReceipt()throws {
        let f=try OwnershipFixture(),j=try f.journal(),first=try f.reserve(j)
        try f.exec("CREATE TRIGGER reject_second BEFORE INSERT ON codex_migration_thread_owners WHEN NEW.thread_id='\(f.second)' BEGIN SELECT RAISE(ABORT,'owned failure'); END")
        try expectThrows(j.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[
            .init(threadID:f.thread,previous:nil,destination:f.ref(first,"b")),.init(threadID:f.second,previous:nil,destination:f.ref(first,"b"))]))
        try expectNil(j.owner(threadID:f.thread));try expectNil(j.owner(threadID:f.second))
        try expectEqual(try j.load(id:first.id)!.record,first)
        try f.exec("DROP TRIGGER reject_second")
        _=try j.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:f.thread,previous:nil,destination:f.ref(first,"b"))])
        try expectEqual(try j.owner(threadID:f.thread)?.revision,1)
    }
    func testMigrationOwnershipPartialMirrorsRequireRepairAfterRestart()throws {
        let f=try OwnershipFixture();var j:CodexMigrationJournal?=try f.journal()
        let first=try f.reserve(j!),folder=first.homes.last!.path+"/.autoapprove-migrations"
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:folder)
        defer{try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder)}
        try expectThrows(j!.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:f.thread,previous:nil,destination:f.ref(first,"b"))]))
        try expectThrows(j!.owner(threadID:f.thread));j=nil
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder)
        let restarted=try f.journal()
        try expectThrows(restarted.owner(threadID:f.thread))
        let repaired=try restarted.repair(id:first.id)
        try expect(repaired.terminal);try expect(try restarted.load(id:first.id)!.consistent)
        try expectEqual(try restarted.owner(threadID:f.thread)?.revision,1)
        try restarted.release(id:first.id)
    }
    func testMigrationOwnershipRejectsMalformedAndUnleasedCompletions()throws {
        let f=try OwnershipFixture(),j=try f.journal(),first=try f.reserve(j)
        let change=CodexMigrationOwnerChange(threadID:f.thread,previous:nil,destination:f.ref(first,"b"))
        try expectThrows(j.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[]))
        try expectThrows(j.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[change,change]))
        let foreign=try f.journal()
        try expectThrows(foreign.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[change]))
        try expectThrows(j.owner(threadID:"invalid"))
        try expectEqual(try j.load(id:first.id)!.record,first)
    }
    func testMigrationOwnershipReadFailureAndTamperingAreNotAbsence()throws {
        let f=try OwnershipFixture(),j=try f.journal(),first=try f.reserve(j)
        _=try j.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:f.thread,previous:nil,destination:f.ref(first,"b"))])
        try f.exec("UPDATE codex_migration_thread_owners SET revision=99 WHERE thread_id='\(f.thread)'")
        try expectThrows(j.owner(threadID:f.thread))
        try f.exec("DROP TABLE codex_migration_thread_owners")
        try expectThrows(j.owner(threadID:f.thread))
    }
    func testMigrationOwnershipMissingProjectionCannotBeRecreatedAsEmpty()throws {
        let f=try OwnershipFixture(),j=try f.journal(),first=try f.reserve(j)
        _=try j.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:f.thread,previous:nil,destination:f.ref(first,"b"))])
        try f.exec("DROP TABLE codex_migration_thread_owners")
        try expectThrows(f.journal())
    }
    func testMigrationOwnershipDeletedRowCannotBeClaimedAsUnowned()throws {
        let f=try OwnershipFixture(),j=try f.journal(),first=try f.reserve(j)
        _=try j.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:f.thread,previous:nil,destination:f.ref(first,"b"))])
        try j.release(id:first.id)
        try f.exec("DELETE FROM codex_migration_thread_owners WHERE thread_id='\(f.thread)'")
        try expectThrows(j.owner(threadID:f.thread))
        let next=try f.reserve(j)
        try expectThrows(j.complete(id:next.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:f.thread,previous:nil,destination:f.ref(next,"a"))]))
        try expectEqual(try j.load(id:next.id)!.record,next)
    }
}
#endif
