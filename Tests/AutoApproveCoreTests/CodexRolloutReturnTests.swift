#if DEBUG
import Foundation
@testable import AutoApproveCore

private func rolloutFixture()throws->(GoalReturnFixture,CodexMigrationRetirement) {
    let f=try GoalReturnFixture(),goals=CodexGoalReturn(journal:f.journal)
    _=try goals.prepare(backup:f.backup,source:f.source(),expectedRevision:1)
    _=try goals.apply(id:f.backup.requestID)
    let path=f.home("b")+"/archived_sessions/rollout-"+f.thread+".jsonl"
    try Data("{\"owned\":\"new B history with another turn\"}\n".utf8).write(to:URL(fileURLWithPath:path))
    let source=try CodexMigrationRetirement.capture(home:f.home("b"),threadID:f.thread,rolloutPath:path)
    return(f,source)
}
extension ApprovalTests {
    func testRolloutReturnAtomicallyReplacesExactArchiveAndPreservesBackup()throws {
        let (f,source)=try rolloutFixture(),engine=CodexRolloutReturn(journal:f.journal)
        let old=f.backup.retirement.rollout
        let state=try engine.prepare(id:f.backup.requestID,source:source)
        try expectEqual(state.rollout?.stage,.prepared)
        try expectEqual(try engine.apply(id:f.backup.requestID),.applied)
        try expectEqual(try engine.observe(id:f.backup.requestID),.applied)
        let current=try CodexMigrationRolloutWitness.capture(home:f.backup.retirement.goal.sourceHome,homeIdentity:f.backup.retirement.goal.homeIdentity,relative:old.relativePath)
        try expectEqual(current.sha256,source.rollout.sha256);try expect(current.fileIdentity != old.fileIdentity)
        try expect(current.fileIdentity != source.rollout.fileIdentity)
        try f.backup.verify();try source.verifyCurrent()
        try expectThrows(engine.apply(id:f.backup.requestID))
        try expectEqual(try f.journal.owner(threadID:f.thread),f.owner)
    }
    func testRolloutReturnRecoversCompleteStageWithoutCopyReplay()throws {
        let (f,source)=try rolloutFixture(),goals=CodexGoalReturn(journal:f.journal)
        var state=try goals.state(id:f.backup.requestID)
        state.rollout = .init(source:source,stage:.staging)
        let record=try f.journal.load(id:f.backup.requestID)!.record
        _=try f.journal.save(id:record.id,payload:JSONEncoder().encode(state),expectedRevision:record.revision)
        let staged=try CodexMigrationRolloutStaging.create(source:source,backup:f.backup)
        let engine=CodexRolloutReturn(journal:f.journal)
        try expectEqual(try engine.recoverStaging(id:record.id).rollout?.staged,staged)
        try expectEqual(try engine.apply(id:record.id),.applied)
        try expectThrows(engine.recoverStaging(id:record.id))
    }
    func testRolloutReturnIncompleteStageAndAttemptNeverReplay()throws {
        let (f,source)=try rolloutFixture(),goals=CodexGoalReturn(journal:f.journal)
        var state=try goals.state(id:f.backup.requestID)
        state.rollout = .init(source:source,stage:.staging)
        var record=try f.journal.load(id:f.backup.requestID)!.record
        _=try f.journal.save(id:record.id,payload:JSONEncoder().encode(state),expectedRevision:record.revision)
        let engine=CodexRolloutReturn(journal:f.journal)
        try expectThrows(engine.recoverStaging(id:record.id));try expectThrows(engine.prepare(id:record.id,source:source))
        try expectThrows(engine.apply(id:record.id))
        let partialPath=f.backup.retirement.goal.sourceHome+"/"+CodexMigrationRolloutStaging.relative(f.backup)
        try Data("partial".utf8).write(to:URL(fileURLWithPath:partialPath))
        try expectThrows(engine.recoverStaging(id:record.id))
        try expectThrows(CodexMigrationRolloutStaging.create(source:source,backup:f.backup))
        try expectEqual(try Data(contentsOf:URL(fileURLWithPath:partialPath)),Data("partial".utf8))
        try FileManager.default.removeItem(atPath:partialPath) // Owned test cleanup, never a recovery action.
        let staged=try CodexMigrationRolloutStaging.create(source:source,backup:f.backup)
        _=try engine.recoverStaging(id:record.id)
        state=try goals.state(id:record.id);state.rollout?.stage = .attempted
        record=try f.journal.load(id:record.id)!.record
        _=try f.journal.save(id:record.id,payload:JSONEncoder().encode(state),expectedRevision:record.revision)
        try expectEqual(try engine.observe(id:record.id),.notApplied)
        try expectThrows(engine.apply(id:record.id))
        try expectEqual(try CodexMigrationRolloutStaging.inspect(backup:f.backup),staged)
    }
    func testRolloutReturnCommittedAttemptObservesWithoutRenameReplay()throws {
        let (f,source)=try rolloutFixture(),engine=CodexRolloutReturn(journal:f.journal),goals=CodexGoalReturn(journal:f.journal)
        _=try engine.prepare(id:f.backup.requestID,source:source)
        var state=try goals.state(id:f.backup.requestID);state.rollout?.stage = .attempted
        let prior=try f.journal.load(id:f.backup.requestID)!.record
        let attempted=try f.journal.save(id:prior.id,payload:JSONEncoder().encode(state),expectedRevision:prior.revision)
        try CodexMigrationRolloutStaging.install(source:source,backup:f.backup,staged:state.rollout!.staged!) {
            try f.journal.validateReservation(attempted)
        }
        let restarted=CodexRolloutReturn(journal:f.journal)
        try expectEqual(try restarted.observe(id:prior.id),.applied)
        try expectEqual(try restarted.observe(id:prior.id),.applied)
        try expectThrows(restarted.apply(id:prior.id))
        try expectEqual(try f.journal.load(id:prior.id)!.record,attempted)
        try f.backup.verify();try source.verifyCurrent()
    }
    func testRolloutReturnRejectsChangedSourceArchiveBackupAndGoal()throws {
        for changed in ["source","archive","backup","goal"] {
            let (f,source)=try rolloutFixture(),engine=CodexRolloutReturn(journal:f.journal)
            _=try engine.prepare(id:f.backup.requestID,source:source)
            let archive=f.backup.retirement.goal.sourceHome+"/"+f.backup.retirement.rollout.relativePath
            if changed=="goal"{try f.exec("a","UPDATE thread_goals SET objective='External Goal'")}
            else {
                let path=changed=="source" ? source.goal.sourceHome+"/"+source.rollout.relativePath:changed=="archive" ? archive:f.backup.rolloutPath
                try Data("external changed data".utf8).write(to:URL(fileURLWithPath:path))
            }
            let before=try Data(contentsOf:URL(fileURLWithPath:archive))
            try expectThrows(engine.apply(id:f.backup.requestID))
            try expectEqual(try Data(contentsOf:URL(fileURLWithPath:archive)),before)
        }
    }
    func testRolloutReturnAuthorityFailureAndLinkedStagePreserveArchive()throws {
        let (f,source)=try rolloutFixture(),engine=CodexRolloutReturn(journal:f.journal)
        let state=try engine.prepare(id:f.backup.requestID,source:source)
        let archived=f.backup.retirement.goal.sourceHome+"/"+f.backup.retirement.rollout.relativePath
        let before=try Data(contentsOf:URL(fileURLWithPath:archived))
        try expectThrows(CodexMigrationRolloutStaging.install(source:source,backup:f.backup,staged:state.rollout!.staged!) {
            throw AppError.message("Owned authority changed before rename")
        })
        try expectEqual(try Data(contentsOf:URL(fileURLWithPath:archived)),before)
        let stagedPath=f.backup.retirement.goal.sourceHome+"/"+CodexMigrationRolloutStaging.relative(f.backup)
        try FileManager.default.removeItem(atPath:stagedPath)
        try FileManager.default.createSymbolicLink(atPath:stagedPath,withDestinationPath:source.goal.sourceHome+"/"+source.rollout.relativePath)
        try expectThrows(engine.apply(id:f.backup.requestID))
        try expectEqual(try Data(contentsOf:URL(fileURLWithPath:archived)),before)
        try source.verifyCurrent();try f.backup.verify()
    }
}
#endif
