#if DEBUG
import Foundation
import CSQLite
import Darwin
@testable import AutoApproveCore

private final class MigrationJournalFixture {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-migration-journal-"+UUID().uuidString)
    let id=UUID().uuidString.lowercased()
    init() throws {for name in ["a","b","c"]{try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true)}}
    deinit{try? FileManager.default.removeItem(at:root)}
    func home(_ name:String)->String {root.appendingPathComponent(name).path}
    func store(_ name:String="audit") throws ->AuditStore {try AuditStore(path:root.appendingPathComponent(name+".sqlite").path)}
    var homes:[String] {[home("b"),home("a")]}
    func payload(_ stage:String)->Data {Data("{\"stage\":\"\(stage)\"}".utf8)}
}
extension ApprovalTests {
    func testMigrationJournalDescriptorRetainsExactKernelReservation()throws {
        let f=try MigrationJournalFixture(),store=try f.store()
        var journal:CodexMigrationJournal?=try .init(store:store)
        let record=try journal!.create(id:f.id,homes:f.homes,payload:f.payload("prepared"))
        var descriptor:CodexMigrationLockDescriptor?=try journal!.duplicateLockDescriptor(id:f.id,home:f.homes[0],expectedRevision:1)
        try expectEqual(descriptor!.requestID,record.id)
        try expectEqual(descriptor!.digest,record.digest)
        try descriptor!.withDescriptor {fd in try expect(fcntl(fd,F_GETFD)&FD_CLOEXEC != 0)}
        try expectThrows(journal!.duplicateLockDescriptor(id:f.id,home:f.homes[0],expectedRevision:2))
        try expectThrows(journal!.duplicateLockDescriptor(id:f.id,home:f.home("c"),expectedRevision:1))
        journal=nil
        let recovering=try CodexMigrationJournal(store:store)
        try expectThrows(recovering.repair(id:f.id))
        descriptor=nil
        try expectEqual(try recovering.repair(id:f.id),record)
    }
    func testMigrationJournalMirrorsAndTerminalRelease() throws {
        let f=try MigrationJournalFixture(),store=try f.store(),j=try CodexMigrationJournal(store:store)
        let first=try j.create(id:f.id,homes:f.homes,payload:f.payload("reserved"))
        try expectEqual(first.revision,1);try expectEqual(first.homes.map(\.path),first.homes.map(\.path).sorted())
        try expect(try j.load(id:f.id)!.consistent)
        let next=try j.save(id:f.id,payload:f.payload("attempted"),expectedRevision:1)
        try expectEqual(next.revision,2);try expectEqual(next.previousDigest,first.digest)
        try expectThrows(j.save(id:f.id,payload:f.payload("stale"),expectedRevision:1))
        try expectThrows(j.release(id:f.id))
        _=try j.save(id:f.id,payload:f.payload("complete"),expectedRevision:2,terminal:true)
        try j.release(id:f.id)
        let second=try CodexMigrationJournal(store:store)
        _=try second.create(id:UUID().uuidString,homes:f.homes.reversed(),payload:f.payload("prepared"))
    }
    func testMigrationJournalLocksSurviveCoordinatorRestart() throws {
        let f=try MigrationJournalFixture(),store=try f.store()
        var old:CodexMigrationJournal?=try .init(store:store)
        _=try old!.create(id:f.id,homes:f.homes,payload:f.payload("attempted"))
        let other=try CodexMigrationJournal(store:f.store("other"))
        try expectThrows(other.create(id:UUID().uuidString,homes:f.homes.reversed(),payload:f.payload("prepared")))
        old=nil
        try expectThrows(other.create(id:UUID().uuidString,homes:f.homes.reversed(),payload:f.payload("prepared")))
        let restored=try CodexMigrationJournal(store:store)
        let record=try restored.repair(id:f.id)
        try expectEqual(record.payload,f.payload("attempted"));try expect(try restored.load(id:f.id)!.consistent)
        try expectEqual(try restored.activeRecords().map(\.id),[f.id])
    }
    func testMigrationJournalRepairsPartialMirrorWithoutRevisingIntent() throws {
        let f=try MigrationJournalFixture(),store=try f.store(),j=try CodexMigrationJournal(store:store)
        let first=try j.create(id:f.id,homes:f.homes,payload:f.payload("reserved"))
        let last=first.homes.last!.path+"/.autoapprove-migrations"
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:last)
        defer{try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:last)}
        try expectThrows(j.save(id:f.id,payload:f.payload("attempted"),expectedRevision:1))
        let partial=try j.load(id:f.id)!
        try expectEqual(partial.record.revision,2);try expectFalse(partial.consistent)
        try expectThrows(j.save(id:f.id,payload:f.payload("must not advance"),expectedRevision:2))
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:last)
        let repaired=try j.repair(id:f.id)
        try expectEqual(repaired,partial.record);try expect(try j.load(id:f.id)!.consistent)
    }
    func testMigrationJournalRejectsCorruptAndLinkedMirrors() throws {
        let f=try MigrationJournalFixture(),j=try CodexMigrationJournal(store:f.store())
        let first=try j.create(id:f.id,homes:f.homes,payload:f.payload("reserved"))
        let mirror=first.homes[0].path+"/.autoapprove-migrations/"+f.id+".json"
        try Data("broken".utf8).write(to:URL(fileURLWithPath:mirror),options:.atomic)
        try expectThrows(j.load(id:f.id));try expectThrows(j.repair(id:f.id))
        try FileManager.default.removeItem(atPath:mirror)
        try FileManager.default.createSymbolicLink(atPath:mirror,withDestinationPath:"active.json")
        try expectThrows(j.load(id:f.id))
    }
    func testMigrationJournalRejectsAliasesAndMissingCentralAuthority() throws {
        let f=try MigrationJournalFixture(),j=try CodexMigrationJournal(store:f.store())
        try expectThrows(j.create(id:f.id,homes:[f.home("a"),f.home("a")+"/../a"],payload:f.payload("reserved")))
        try expectThrows(j.create(id:"invalid",homes:f.homes,payload:Data()))
        let bad=f.home("c")+"/.autoapprove-migrations"
        try FileManager.default.createSymbolicLink(atPath:bad,withDestinationPath:f.home("a"))
        try expectThrows(j.create(id:f.id,homes:[f.home("b"),f.home("c")],payload:Data()))
    }
    func testMigrationJournalDuplicateIDFailureReleasesForeignLease() throws {
        let f=try MigrationJournalFixture(),store=try f.store()
        var original:CodexMigrationJournal?=try .init(store:store)
        _=try original!.create(id:f.id,homes:f.homes,payload:f.payload("reserved"));original=nil
        let foreign=try CodexMigrationJournal(store:f.store("foreign"))
        try expectThrows(foreign.create(id:f.id,homes:f.homes,payload:f.payload("different")))
        let restored=try CodexMigrationJournal(store:store)
        _=try restored.repair(id:f.id)
        try expect(try restored.load(id:f.id)!.consistent)
    }
    func testMigrationJournalTerminalHistoryRemainsReadableDuringAnotherRequest() throws {
        let f=try MigrationJournalFixture(),store=try f.store(),j=try CodexMigrationJournal(store:store)
        _=try j.create(id:f.id,homes:f.homes,payload:f.payload("reserved"))
        let terminal=try j.save(id:f.id,payload:f.payload("complete"),expectedRevision:1,terminal:true)
        try j.release(id:f.id)
        let next=try CodexMigrationJournal(store:store)
        _=try next.create(id:UUID().uuidString,homes:f.homes,payload:f.payload("new scope"))
        try expect(try j.load(id:f.id)!.consistent)
        try expectEqual(try j.repair(id:f.id),terminal)
        try j.release(id:f.id)
    }
    func testMigrationJournalCentralReadAndWriteFailuresNeverBecomeAbsence() throws {
        let f=try MigrationJournalFixture(),store=try f.store();try store.prepareMigrationJournal()
        let readOnly=try AuditStore(path:f.root.appendingPathComponent("audit.sqlite").path,readOnly:true)
        let rejected=try CodexMigrationJournal(store:readOnly)
        try expectThrows(rejected.create(id:f.id,homes:f.homes,payload:f.payload("reserved")))
        let writer=try CodexMigrationJournal(store:store)
        _=try writer.create(id:f.id,homes:f.homes,payload:f.payload("reserved"))
        var db:OpaquePointer?;try expectEqual(sqlite3_open(f.root.appendingPathComponent("audit.sqlite").path,&db),SQLITE_OK)
        defer{sqlite3_close(db)}
        try expectEqual(sqlite3_exec(db,"DROP TABLE codex_migration_journals",nil,nil,nil),SQLITE_OK)
        try expectThrows(writer.load(id:f.id));try expectThrows(writer.activeRecords())
    }
}
#endif
