#if DEBUG
import Foundation
import CSQLite
@testable import AutoApproveCore

final class GoalReturnFixture {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-goal-return-"+UUID().uuidString)
    let thread="00000000-0000-4000-8000-000000000091"
    let store:AuditStore,journal:CodexMigrationJournal
    let owner:CodexMigrationOwner,backup:CodexMigrationRetiredBackup
    init()throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        store=try AuditStore(path:root.appendingPathComponent("audit.sqlite").path)
        journal=try CodexMigrationJournal(store:store)
        let schema=try String(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/codex-goals-0.166.sql"),encoding:.utf8)
        for n in ["a","b"] {
            let h=root.appendingPathComponent(n).path
            try FileManager.default.createDirectory(atPath:h+"/archived_sessions",withIntermediateDirectories:true)
            var db:OpaquePointer?;guard sqlite3_open(h+"/goals_1.sqlite",&db)==SQLITE_OK else{throw AppError.message("Owned DB open")};defer{sqlite3_close(db)}
            let tokens=n=="a" ? 37:73,seconds=n=="a" ? 19:29
            guard sqlite3_exec(db,schema+"; INSERT INTO thread_goals VALUES ('\(thread)','same-instance','Keep exact Goal','paused',1234,\(tokens),\(seconds),1001,2002); INSERT INTO thread_goal_continuation_deferrals VALUES ('\(thread)');",nil,nil,nil)==SQLITE_OK else{throw AppError.message("Owned setup")}
            try Data("{\"owned\":\"history\"}\n".utf8).write(to:URL(fileURLWithPath:h+"/archived_sessions/rollout-"+thread+".jsonl"))
        }
        let a=root.appendingPathComponent("a").path,b=root.appendingPathComponent("b").path
        let retirement=try CodexMigrationRetirement.capture(home:a,threadID:thread,rolloutPath:a+"/archived_sessions/rollout-"+thread+".jsonl")
        let first=try journal.create(id:UUID().uuidString,homes:[a,b],payload:Data())
        let destination=first.homes.first{$0.path.hasSuffix("/b")}!
        _=try journal.complete(id:first.id,payload:Data(),expectedRevision:1,ownership:[.init(threadID:thread,previous:nil,destination:destination,retirement:retirement)])
        try journal.release(id:first.id);owner=try journal.owner(threadID:thread)!
        let reserved=try journal.create(id:UUID().uuidString,homes:[a,b],payload:Data("return".utf8))
        backup=try journal.backupRetired(retirement,expectedOwner:owner,requestID:reserved.id,expectedRevision:1)
    }
    deinit{try? FileManager.default.removeItem(at:root)}
    func home(_ n:String)->String {root.appendingPathComponent(n).path}
    func exec(_ n:String,_ sql:String)throws {
        var db:OpaquePointer?;guard sqlite3_open(home(n)+"/goals_1.sqlite",&db)==SQLITE_OK else{throw AppError.message("Owned DB open")};defer{sqlite3_close(db)}
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw AppError.message("Owned SQL")}
    }
    func source()throws->CodexGoalTransferSlot {try CodexGoalTransferStore.captureSlot(home:home("b"),threadID:thread)}
}
extension ApprovalTests {
    func testGoalReturnReplacesOnlyExactRetiredRowAndPreservesBackup()throws {
        let f=try GoalReturnFixture(),source=try f.source(),engine=CodexGoalReturn(journal:f.journal)
        let prepared=try engine.prepare(backup:f.backup,source:source,expectedRevision:1)
        try expectEqual(prepared.stage,.prepared)
        try expectEqual(try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.thread).row?.tokensUsed,37)
        try expectEqual(try engine.apply(id:f.backup.requestID),.applied)
        let target=try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.thread)
        try expectEqual(target.row,source.row);try expectEqual(target.continuationDeferred,source.continuationDeferred)
        try expectEqual(try f.source(),source);try f.backup.verify()
        try expectThrows(engine.apply(id:f.backup.requestID))
        try expectEqual(try f.journal.owner(threadID:f.thread),f.owner,"Goal storage change cannot claim native destination ownership")
    }
    func testGoalReturnClearedSourceRemovesRetiredGoalAndDeferral()throws {
        let f=try GoalReturnFixture()
        try f.exec("b","DELETE FROM thread_goal_continuation_deferrals; DELETE FROM thread_goals")
        let engine=CodexGoalReturn(journal:f.journal)
        _=try engine.prepare(backup:f.backup,source:f.source(),expectedRevision:1)
        try expectEqual(try engine.apply(id:f.backup.requestID),.applied)
        let target=try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.thread)
        try expectNil(target.row);try expectFalse(target.continuationDeferred);try f.backup.verify()
        try expectEqual(try engine.observe(id:f.backup.requestID),.applied)
    }
    func testGoalReturnAttemptedWithoutWriteIsObservedNeverReplayed()throws {
        let f=try GoalReturnFixture(),engine=CodexGoalReturn(journal:f.journal)
        var state=try engine.prepare(backup:f.backup,source:f.source(),expectedRevision:1)
        state.stage = .attempted
        _=try f.journal.save(id:f.backup.requestID,payload:JSONEncoder().encode(state),expectedRevision:2)
        let restarted=CodexGoalReturn(journal:f.journal)
        try expectThrows(restarted.apply(id:f.backup.requestID))
        try expectEqual(try restarted.observe(id:f.backup.requestID),.notApplied)
        try expectEqual(try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.thread).row?.tokensUsed,37)
    }
    func testGoalReturnRejectsChangedSourceDestinationAndBackup()throws {
        for changed in ["source","destination","backup"] {
            let f=try GoalReturnFixture(),engine=CodexGoalReturn(journal:f.journal)
            _=try engine.prepare(backup:f.backup,source:f.source(),expectedRevision:1)
            if changed=="backup"{try Data("changed backup".utf8).write(to:URL(fileURLWithPath:f.backup.rolloutPath))}
            else{try f.exec(changed=="source" ? "b":"a","UPDATE thread_goals SET objective='Keep external update'")}
            let before=try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.thread)
            try expectThrows(engine.apply(id:f.backup.requestID))
            try expectEqual(try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.thread),before)
        }
    }
    func testGoalReturnObservesCommittedAttemptWithoutReplayingIt()throws {
        let f=try GoalReturnFixture(),engine=CodexGoalReturn(journal:f.journal),source=try f.source()
        var state=try engine.prepare(backup:f.backup,source:source,expectedRevision:1)
        state.stage = .attempted
        let attempted=try f.journal.save(id:f.backup.requestID,payload:JSONEncoder().encode(state),expectedRevision:2)
        try CodexGoalTransferStore.replaceRetired(source,expected:f.backup.retirement.goal) {
            try f.journal.validateReservation(attempted);try f.backup.verify();try CodexGoalTransferStore.verifyCurrent(source)
        }
        let saved=try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.thread)
        let restored=CodexGoalReturn(journal:f.journal)
        try expectEqual(try restored.observe(id:f.backup.requestID),.applied)
        try expectEqual(try restored.observe(id:f.backup.requestID),.applied)
        try expectThrows(restored.apply(id:f.backup.requestID))
        try expectEqual(try f.journal.load(id:f.backup.requestID)!.record,attempted,"Observation must not rewrite the attempted journal")
        try expectEqual(try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.thread),saved)
    }
    func testGoalReturnAuthorityFailureRollsBackPendingReplacement()throws {
        let f=try GoalReturnFixture(),before=f.backup.retirement.goal,source=try f.source()
        var reads=0
        try expectThrows(CodexGoalTransferStore.replaceRetired(source,expected:before) {
            reads+=1
            if reads==2{throw AppError.message("Owned authority changed before commit")}
        })
        try expectEqual(reads,2)
        try expectEqual(try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.thread),before)
        try expectEqual(try f.source(),source)
    }
    func testGoalReturnLockFailureNeverReplaysAfterLockRelease()throws {
        let f=try GoalReturnFixture(),engine=CodexGoalReturn(journal:f.journal)
        _=try engine.prepare(backup:f.backup,source:f.source(),expectedRevision:1)
        var db:OpaquePointer?;try expectEqual(sqlite3_open(f.home("a")+"/goals_1.sqlite",&db),SQLITE_OK);defer{sqlite3_close(db)}
        try expectEqual(sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil),SQLITE_OK)
        let start=Date();try expectThrows(engine.apply(id:f.backup.requestID))
        try expect(Date().timeIntervalSince(start)<2)
        try expectEqual(sqlite3_exec(db,"ROLLBACK",nil,nil,nil),SQLITE_OK)
        try expectEqual(try engine.state(id:f.backup.requestID).stage,.attempted)
        try expectEqual(try engine.observe(id:f.backup.requestID),.notApplied)
        try expectThrows(engine.apply(id:f.backup.requestID))
        try expectEqual(try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.thread).row?.tokensUsed,37)
    }
    func testGoalReturnEqualValueNeedsNoGoalDatabaseWrite()throws {
        let f=try GoalReturnFixture()
        try f.exec("b","UPDATE thread_goals SET tokens_used=37,time_used_seconds=19")
        let engine=CodexGoalReturn(journal:f.journal)
        _=try engine.prepare(backup:f.backup,source:f.source(),expectedRevision:1)
        var db:OpaquePointer?;try expectEqual(sqlite3_open(f.home("a")+"/goals_1.sqlite",&db),SQLITE_OK);defer{sqlite3_close(db)}
        try expectEqual(sqlite3_exec(db,"BEGIN IMMEDIATE",nil,nil,nil),SQLITE_OK)
        try expectEqual(try engine.apply(id:f.backup.requestID),.unchanged)
        try expectEqual(try engine.state(id:f.backup.requestID).stage,.verified)
        try expectEqual(try engine.observe(id:f.backup.requestID),.unchanged)
        try expectEqual(sqlite3_exec(db,"ROLLBACK",nil,nil,nil),SQLITE_OK)
        try expectEqual(try CodexGoalTransferStore.captureSlot(home:f.home("a"),threadID:f.thread),f.backup.retirement.goal)
    }
}
#endif
