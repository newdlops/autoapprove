#if DEBUG
import Foundation
import CSQLite
import Darwin
@testable import AutoApproveCore

private final class GoalTransferFixture {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-goal-transfer-"+UUID().uuidString)
    let id="00000000-0000-4000-8000-000000000061"
    let other="00000000-0000-4000-8000-000000000062"
    init() throws {
        let fixture=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/codex-goals-0.166.sql")
        let schema=try String(contentsOf:fixture,encoding:.utf8)
        for name in ["a","b","c"] {
            try FileManager.default.createDirectory(atPath:home(name),withIntermediateDirectories:true)
            try exec(name,schema)
        }
        try exec("a","INSERT INTO thread_goals VALUES ('\(id)','original-instance','원래 목표 ''quoted''','paused',1234,37,19,9007199254740993,9007199254741001); INSERT INTO thread_goal_continuation_deferrals VALUES ('\(id)');")
        try exec("b","INSERT INTO thread_goals VALUES ('\(other)','unselected-instance','Unselected','paused',999,51,23,1001,2002);")
    }
    deinit {try? FileManager.default.removeItem(at:root)}
    func home(_ name:String)->String {root.appendingPathComponent(name).path}
    func path(_ name:String)->String {home(name)+"/goals_1.sqlite"}
    func exec(_ name:String,_ sql:String) throws {
        var db:OpaquePointer?;guard sqlite3_open(path(name),&db)==SQLITE_OK else{throw AppError.message("Owned SQLite open failed")};defer{sqlite3_close(db)}
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw AppError.message("Owned SQLite setup failed: "+String(cString:sqlite3_errmsg(db)))}
    }
}

extension ApprovalTests {
    func testGoalTransferSlotWitnessesClearedState() throws {
        let f=try GoalTransferFixture()
        let old=try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.id)
        try expectEqual(old.row?.tokensUsed,37)
        try f.exec("a","DELETE FROM thread_goal_continuation_deferrals WHERE thread_id='\(f.id)'; DELETE FROM thread_goals WHERE thread_id='\(f.id)';")
        let cleared=try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.id)
        try expectNil(cleared.row);try expectFalse(cleared.continuationDeferred)
        try expectEqual(cleared.threadID,f.id)
        try expectEqual(cleared.databaseIdentity,old.databaseIdentity)
        try expect(cleared.digest != old.digest)
        try CodexGoalTransferStore.verifyCurrent(cleared)
        try expectThrows(CodexGoalTransferStore.verifyCurrent(old))
        let decoded=try JSONDecoder().decode(CodexGoalTransferSlot.self,from:JSONEncoder().encode(cleared))
        try CodexGoalTransferStore.verifyCurrent(decoded)
        try expectEqual(decoded,cleared)
        try f.exec("a","INSERT INTO thread_goals VALUES ('\(f.id)','new-instance','A new Goal','paused',500,73,29,1100,1200)")
        try expectThrows(CodexGoalTransferStore.verifyCurrent(cleared))
        try expectEqual(try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.id).row?.tokensUsed,73)
    }
    func testGoalTransferAbsentSlotRejectsReplacementAndUnknownState() throws {
        let f=try GoalTransferFixture()
        let empty=try CodexGoalTransferStore.captureSlot(home:f.home("b"),threadID:f.id)
        try expectNil(empty.row)
        try Data(contentsOf:URL(fileURLWithPath:f.path("b"))).write(to:URL(fileURLWithPath:f.path("b")),options:.atomic)
        try expectThrows(CodexGoalTransferStore.verifyCurrent(empty))
        let changed=try CodexGoalTransferStore.captureSlot(home:f.home("b"),threadID:f.id)
        try expect(changed.digest != empty.digest)
        try f.exec("b","INSERT INTO thread_goal_continuation_deferrals VALUES ('\(f.id)')")
        try expectThrows(CodexGoalTransferStore.captureSlot(home:f.home("b"),threadID:f.id))
        try FileManager.default.removeItem(atPath:f.path("b"))
        try expectThrows(CodexGoalTransferStore.captureSlot(home:f.home("b"),threadID:f.id))
        try expectFalse(FileManager.default.fileExists(atPath:f.path("b")))
        try f.exec("c","PRAGMA user_version=99")
        try expectThrows(CodexGoalTransferStore.captureSlot(home:f.home("c"),threadID:f.id))
    }
    func testGoalTransferSlotRejectsForgedAbsenceAndTracksDeferral() throws {
        let f=try GoalTransferFixture()
        let original=try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.id)
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as! [String:Any]
        json.removeValue(forKey:"row")
        let forged=try JSONDecoder().decode(CodexGoalTransferSlot.self,from:JSONSerialization.data(withJSONObject:json))
        try expectThrows(CodexGoalTransferStore.verifyCurrent(forged))
        try f.exec("a","DELETE FROM thread_goal_continuation_deferrals")
        try expectThrows(CodexGoalTransferStore.verifyCurrent(original))
        let current=try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.id)
        try expectEqual(current.row,original.row);try expectFalse(current.continuationDeferred)
        try CodexGoalTransferStore.verifyCurrent(current)
        try expectEqual(try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)?.row,current.row)
    }
    func testGoalTransferSlotRejectsReplacedHomeWithSameDatabase() throws {
        let f=try GoalTransferFixture()
        let empty=try CodexGoalTransferStore.captureSlot(home:f.home("b"),threadID:f.id)
        try FileManager.default.moveItem(atPath:f.home("b"),toPath:f.home("retired-b"))
        try FileManager.default.createDirectory(atPath:f.home("b"),withIntermediateDirectories:true)
        try FileManager.default.moveItem(atPath:f.path("retired-b"),toPath:f.path("b"))
        let changed=try CodexGoalTransferStore.captureSlot(home:f.home("b"),threadID:f.id)
        try expectEqual(changed.databaseIdentity,empty.databaseIdentity)
        try expect(changed.homeIdentity != empty.homeIdentity)
        try expectThrows(CodexGoalTransferStore.verifyCurrent(empty))
        try CodexGoalTransferStore.verifyCurrent(changed)
        let other=try CodexGoalTransferStore.captureSlot(home:f.home("c"),threadID:f.other)
        let sameHomeOtherSlot=try CodexGoalTransferStore.captureSlot(home:f.home("c"),threadID:f.id)
        try expectNil(other.row);try expectNil(sameHomeOtherSlot.row)
        try expect(other.digest != sameHomeOtherSlot.digest,"Absent states must still bind the exact thread")
    }
    func testGoalTransferSnapshotRejectsReplacedHomeWithSameDatabase() throws {
        let f=try GoalTransferFixture()
        let snapshot=try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)!
        try FileManager.default.moveItem(atPath:f.home("a"),toPath:f.home("retired-a"))
        try FileManager.default.createDirectory(atPath:f.home("a"),withIntermediateDirectories:true)
        try FileManager.default.moveItem(atPath:f.path("retired-a"),toPath:f.path("a"))
        try expectThrows(CodexGoalTransferStore.restore(snapshot,toHome:f.home("b"),expectedSchema:snapshot.schemaFingerprint))
        try expectNil(CodexGoalTransferStore.capture(home:f.home("b"),threadID:f.id))
    }
    func testGoalTransferPreservesExactRowAndDeferral() throws {
        let f=try GoalTransferFixture()
        let a=try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)!
        try expectEqual(a.row.tokensUsed,37);try expectEqual(a.row.timeUsedSeconds,19)
        try expectEqual(a.row.tokenBudget,1234);try expectEqual(a.row.createdAtMs,9007199254740993)
        try expect(a.continuationDeferred)
        let other=try CodexGoalTransferStore.capture(home:f.home("b"),threadID:f.other)!
        try CodexGoalTransferStore.restore(a,toHome:f.home("b"),expectedSchema:a.schemaFingerprint)
        let b=try CodexGoalTransferStore.capture(home:f.home("b"),threadID:f.id)!
        try expectEqual(b.row,a.row);try expectEqual(b.continuationDeferred,a.continuationDeferred)
        try expectEqual(try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id),a)
        try expectEqual(try CodexGoalTransferStore.capture(home:f.home("b"),threadID:f.other),other)
        try CodexGoalTransferStore.restore(b,toHome:f.home("c"),expectedSchema:b.schemaFingerprint)
        try expectEqual(try CodexGoalTransferStore.capture(home:f.home("c"),threadID:f.id)?.row,a.row)
        let decoded=try JSONDecoder().decode(CodexGoalTransferSnapshot.self,from:JSONEncoder().encode(a))
        try expectEqual(decoded,a)
    }
    func testGoalTransferRejectsUnknownSchemaAndMigrations() throws {
        for sql in ["PRAGMA user_version=1", "ALTER TABLE thread_goals ADD COLUMN extra INTEGER", "UPDATE _sqlx_migrations SET checksum=X'00'", "CREATE TABLE unknown_state(value TEXT)", "CREATE TRIGGER surprise AFTER INSERT ON thread_goals BEGIN UPDATE thread_goals SET tokens_used=0; END"] {
            let f=try GoalTransferFixture(),s=try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)!
            try f.exec("b",sql)
            try expectThrows(CodexGoalTransferStore.restore(s,toHome:f.home("b"),expectedSchema:s.schemaFingerprint))
            try f.exec("a",sql)
            try expectThrows(CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id))
        }
    }
    func testGoalTransferRejectsStaleOrConflictingRows() throws {
        let f=try GoalTransferFixture(),s=try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)!
        try expectThrows(CodexGoalTransferStore.restore(s,toHome:f.home("a"),expectedSchema:s.schemaFingerprint))
        try expectThrows(CodexGoalTransferStore.restore(s,toHome:f.home("b"),expectedSchema:"unknown"))
        try f.exec("a","UPDATE thread_goals SET tokens_used=38 WHERE thread_id='\(f.id)'")
        try expectThrows(CodexGoalTransferStore.restore(s,toHome:f.home("b"),expectedSchema:s.schemaFingerprint))
        try expectNil(CodexGoalTransferStore.capture(home:f.home("b"),threadID:f.id))
        let current=try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)!
        try CodexGoalTransferStore.restore(current,toHome:f.home("b"),expectedSchema:current.schemaFingerprint)
        try f.exec("b","UPDATE thread_goals SET objective='Keep destination' WHERE thread_id='\(f.id)'")
        let original=try CodexGoalTransferStore.capture(home:f.home("b"),threadID:f.id)
        try expectThrows(CodexGoalTransferStore.restore(current,toHome:f.home("b"),expectedSchema:current.schemaFingerprint))
        try expectEqual(try CodexGoalTransferStore.capture(home:f.home("b"),threadID:f.id),original)
    }
    func testGoalTransferRejectsReplacedAndSymlinkedDatabases() throws {
        let f=try GoalTransferFixture(),s=try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)!
        try Data(contentsOf:URL(fileURLWithPath:f.path("a"))).write(to:URL(fileURLWithPath:f.path("a")),options:.atomic)
        try expectThrows(CodexGoalTransferStore.restore(s,toHome:f.home("b"),expectedSchema:s.schemaFingerprint))
        try FileManager.default.moveItem(atPath:f.path("b"),toPath:f.path("b")+".saved")
        try FileManager.default.createSymbolicLink(atPath:f.path("b"),withDestinationPath:f.path("b")+".saved")
        try expectThrows(CodexGoalTransferStore.capture(home:f.home("b"),threadID:f.other))
        try expectThrows(CodexGoalTransferStore.restore(s,toHome:f.home("b"),expectedSchema:s.schemaFingerprint))
    }
    func testGoalTransferValidatesRowsAndPreservesEmbeddedNUL() throws {
        let f=try GoalTransferFixture()
        try expectThrows(CodexGoalTransferStore.capture(home:f.home("a"),threadID:"not-a-uuid"))
        try f.exec("a","UPDATE thread_goals SET objective=CAST(X'610062' AS TEXT)")
        let s=try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)!
        try expectEqual(s.row.objective,"a\0b")
        try CodexGoalTransferStore.restore(s,toHome:f.home("b"),expectedSchema:s.schemaFingerprint)
        try expectEqual(try CodexGoalTransferStore.capture(home:f.home("b"),threadID:f.id)?.row.objective,"a\0b")
        try f.exec("a","UPDATE thread_goals SET tokens_used=-1")
        try expectThrows(CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id))
    }
    func testGoalTransferRejectsChangedDeferralAndOrphan() throws {
        let f=try GoalTransferFixture(),s=try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)!
        try f.exec("a","DELETE FROM thread_goal_continuation_deferrals")
        try expectThrows(CodexGoalTransferStore.restore(s,toHome:f.home("b"),expectedSchema:s.schemaFingerprint))
        let current=try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)!
        try f.exec("b","INSERT INTO thread_goal_continuation_deferrals VALUES ('\(f.id)')")
        try expectThrows(CodexGoalTransferStore.restore(current,toHome:f.home("b"),expectedSchema:current.schemaFingerprint))
        try CodexGoalTransferStore.restore(current,toHome:f.home("c"),expectedSchema:current.schemaFingerprint)
        try expectFalse(try CodexGoalTransferStore.capture(home:f.home("c"),threadID:f.id)!.continuationDeferred)
    }
    func testGoalTransferRejectsActiveGoalsAndForgedSnapshots() throws {
        let f=try GoalTransferFixture(),s=try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)!
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(s)) as! [String:Any]
        json["formatVersion"]=99
        let forged=try JSONDecoder().decode(CodexGoalTransferSnapshot.self,from:JSONSerialization.data(withJSONObject:json))
        try expectThrows(CodexGoalTransferStore.restore(forged,toHome:f.home("b"),expectedSchema:s.schemaFingerprint))
        try f.exec("a","UPDATE thread_goals SET status='active'")
        try expectThrows(CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id))
        try expectThrows(CodexGoalTransferStore.restore(s,toHome:f.home("b"),expectedSchema:s.schemaFingerprint))
    }
    func testGoalTransferBoundsLockedDestinationsAndSpecialFiles() throws {
        let f=try GoalTransferFixture(),s=try CodexGoalTransferStore.capture(home:f.home("a"),threadID:f.id)!
        var db:OpaquePointer?;try expectEqual(sqlite3_open(f.path("b"),&db),SQLITE_OK)
        defer{sqlite3_close(db)}
        try expectEqual(sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil),SQLITE_OK)
        let start=Date()
        try expectThrows(CodexGoalTransferStore.restore(s,toHome:f.home("b"),expectedSchema:s.schemaFingerprint))
        try expect(Date().timeIntervalSince(start)<2,"Locked destination must fail within its bounded busy deadline")
        try expectEqual(sqlite3_exec(db,"ROLLBACK",nil,nil,nil),SQLITE_OK)
        try expectNil(CodexGoalTransferStore.capture(home:f.home("b"),threadID:f.id))
        try CodexGoalTransferStore.restore(s,toHome:f.home("b"),expectedSchema:s.schemaFingerprint)
        try FileManager.default.moveItem(atPath:f.path("c"),toPath:f.path("c")+".saved")
        try expectEqual(mkfifo(f.path("c"),0o600),0)
        try expectThrows(CodexGoalTransferStore.capture(home:f.home("c"),threadID:f.id))
    }
}
#endif
