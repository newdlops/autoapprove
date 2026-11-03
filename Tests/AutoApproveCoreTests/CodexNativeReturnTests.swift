#if DEBUG
import Foundation
@testable import AutoApproveCore

private final class NativeReturnFixture {
    let f:GoalReturnFixture,source:CodexMigrationRetirement
    var plan:CodexNativeReturnPlan
    var observation:CodexNativeReturnObservation
    var unarchives=0,resumes=0
    var loseUnarchive=false,loseResume=false,dropBeforeResume=false,hideSettings=false,hideHistory=false
    init(unchangedHistory:Bool=false)throws {
        f=try GoalReturnFixture()
        let goals=CodexGoalReturn(journal:f.journal)
        _=try goals.prepare(backup:f.backup,source:f.source(),expectedRevision:1);_=try goals.apply(id:f.backup.requestID)
        let path=f.home("b")+"/archived_sessions/rollout-"+f.thread+".jsonl"
        if !unchangedHistory{try Data("{\"history\":\"latest B\"}\n".utf8).write(to:URL(fileURLWithPath:path))}
        source=try CodexMigrationRetirement.capture(home:f.home("b"),threadID:f.thread,rolloutPath:path)
        let history=CodexRolloutReturn(journal:f.journal)
        _=try history.prepare(id:f.backup.requestID,source:source);_=try history.apply(id:f.backup.requestID)
        let old=f.backup.retirement
        let archive=try CodexMigrationRolloutWitness.capture(home:old.goal.sourceHome,homeIdentity:old.goal.homeIdentity,relative:old.rollout.relativePath)
        let server=CodexNativeReturnServer(home:old.goal.sourceHome,homeIdentity:old.goal.homeIdentity,serverID:"owned-server-generation",cliVersion:"0.166.0")
        let thread=CodexNativeReturnThread(source:source,archive:archive,sessionRelativePath:"sessions/rollout-"+f.thread+".jsonl",historyDigest:String(repeating:"a",count:64),settingsDigest:String(repeating:"b",count:64),previousOwner:f.owner)
        plan = .init(rootID:f.thread,server:server,threads:[thread])
        observation = .init(server:server,affectedIDs:[f.thread],completeScope:true,threads:[.init(id:f.thread,relativePath:archive.relativePath,archived:true,loaded:false)])
    }
    func addChild()throws {
        let id="00000000-0000-4000-8000-000000000092",relative="archived_sessions/rollout-"+id+".jsonl"
        for home in ["a","b"] {
            try f.exec(home,"INSERT INTO thread_goals VALUES ('\(id)','child-instance','Child Goal','paused',500,5,2,1001,2002)")
            try Data("{\"owned\":\"child history\"}\n".utf8).write(to:URL(fileURLWithPath:f.home(home)+"/"+relative))
        }
        let child=try CodexMigrationRetirement.capture(home:f.home("b"),threadID:id,rolloutPath:f.home("b")+"/"+relative)
        let archive=try CodexMigrationRolloutWitness.capture(home:plan.server.home,homeIdentity:plan.server.homeIdentity,relative:relative)
        plan.threads.append(.init(source:child,archive:archive,sessionRelativePath:"sessions/rollout-"+id+".jsonl",historyDigest:String(repeating:"c",count:64),settingsDigest:String(repeating:"d",count:64),previousOwner:nil))
        observation.affectedIDs.append(id);observation.threads.append(.init(id:id,relativePath:relative,archived:true,loaded:false))
    }
    func engine()->CodexNativeReturn {
        .init(journal:f.journal,services:.init(observe:{_ in self.observation},unarchive:{plan in
            self.unarchives+=1
            let state=try CodexGoalReturn(journal:self.f.journal).state(id:self.f.backup.requestID)
            try self.f.expectPhase(state,.unarchiveAttempted)
            for (index,thread) in plan.threads.enumerated() {
                let destination=plan.server.home+"/"+thread.sessionRelativePath
                try FileManager.default.createDirectory(at:URL(fileURLWithPath:destination).deletingLastPathComponent(),withIntermediateDirectories:true)
                try FileManager.default.moveItem(atPath:plan.server.home+"/"+thread.archive.relativePath,toPath:destination)
                self.observation.threads[index].archived=false;self.observation.threads[index].relativePath=thread.sessionRelativePath
            }
            if self.loseUnarchive{throw AppError.message("Owned lost unarchive acknowledgment")}
        },resume:{plan,id in
            self.resumes+=1
            let state=try CodexGoalReturn(journal:self.f.journal).state(id:self.f.backup.requestID)
            try self.f.expectPhase(state,.resumeAttempted)
            if self.dropBeforeResume{throw AppError.message("Owned resume delivery unknown before effect")}
            guard let index=plan.threads.firstIndex(where:{$0.id==id}) else{throw AppError.message("Wrong owned thread")}
            self.observation.threads[index].loaded=true;self.observation.threads[index].historyDigest=self.hideHistory ? nil:plan.threads[index].historyDigest
            self.observation.threads[index].settingsDigest=self.hideSettings ? nil:plan.threads[index].settingsDigest
            if self.loseResume{throw AppError.message("Owned lost resume acknowledgment")}
        }))
    }
}
private extension GoalReturnFixture {
    func expectPhase(_ state:CodexGoalReturnState,_ phase:CodexNativeReturnState.Phase)throws {
        guard state.nativeRestore?.phase==phase,try journal.load(id:backup.requestID)?.consistent==true else{throw AppError.message("Native effect preceded synced attempted receipt")}
    }
}
extension ApprovalTests {
    func testNativeReturnCommitsOnlyAfterHistorySettingsAndLoadVerification()throws {
        let f=try NativeReturnFixture(),engine=f.engine(),id=f.f.backup.requestID
        _=try engine.prepare(id:id,plan:f.plan)
        try expectThrows(engine.commit(id:id))
        try expectEqual(try engine.advance(id:id).phase,.resumePrepared)
        try expectEqual(try f.f.journal.owner(threadID:f.f.thread),f.f.owner)
        try expectEqual(try engine.advance(id:id).phase,.verified)
        try expectEqual(f.unarchives,1);try expectEqual(f.resumes,1)
        try expectEqual(try engine.commit(id:id).phase,.completed)
        try expectEqual(try f.f.journal.owner(threadID:f.f.thread)?.home.path,f.plan.server.home)
        try expectEqual(try engine.state(id:id).phase,.completed)
        try expectThrows(engine.advance(id:id));try expectThrows(engine.commit(id:id))
    }
    func testNativeReturnLostAcknowledgmentsReconcileWithoutReplaying()throws {
        let f=try NativeReturnFixture(),engine=f.engine(),id=f.f.backup.requestID
        _=try engine.prepare(id:id,plan:f.plan);f.loseUnarchive=true
        try expectThrows(engine.advance(id:id))
        try expectEqual(try f.engine().advance(id:id).phase,.resumePrepared)
        f.loseResume=true
        try expectThrows(f.engine().advance(id:id))
        try expectEqual(try f.engine().advance(id:id).phase,.verified)
        try expectEqual(f.unarchives,1);try expectEqual(f.resumes,1)
    }
    func testNativeReturnUnknownResumeAndMissingSettingsHoldOriginalOwner()throws {
        for missing in ["undelivered","settings","history"] {
            let f=try NativeReturnFixture(),engine=f.engine(),id=f.f.backup.requestID
            _=try engine.prepare(id:id,plan:f.plan);_=try engine.advance(id:id)
            f.dropBeforeResume = missing=="undelivered";f.hideSettings=missing=="settings";f.hideHistory=missing=="history"
            do{_=try engine.advance(id:id)}catch{}
            for _ in 0..<3{try expectEqual(try f.engine().advance(id:id).phase,.resumeAttempted)}
            try expectThrows(engine.commit(id:id))
            try expectEqual(f.unarchives,1);try expectEqual(f.resumes,1)
            try expectEqual(try f.f.journal.owner(threadID:f.f.thread),f.f.owner)
        }
    }
    func testNativeReturnChangedEndpointScopeAndPendingInputSendNoEffects()throws {
        for changed in ["endpoint","account","version","path","child","incomplete","input","active"] {
            let f=try NativeReturnFixture(),engine=f.engine(),id=f.f.backup.requestID
            _=try engine.prepare(id:id,plan:f.plan)
            if changed=="endpoint"{f.observation.server.serverID="replacement"}
            else if changed=="account"{f.observation.server.accountDigest=String(repeating:"f",count:64)}
            else if changed=="version"{f.observation.server.cliVersion="0.167.0"}
            else if changed=="path"{f.observation.threads[0].relativePath="sessions/unexpected.jsonl"}
            else if changed=="child"{f.observation.affectedIDs.append(UUID().uuidString.lowercased())}
            else if changed=="incomplete"{f.observation.completeScope=false}
            else if changed=="active"{f.observation.threads[0].active=true}
            else{f.observation.threads[0].blocked=true}
            try expectThrows(engine.advance(id:id))
            try expectEqual(f.unarchives,0);try expectEqual(f.resumes,0)
        }
    }
    func testNativeReturnUnchangedHistoryStillRestoresSameGoal()throws {
        let f=try NativeReturnFixture(unchangedHistory:true),engine=f.engine(),id=f.f.backup.requestID
        _=try engine.prepare(id:id,plan:f.plan)
        _=try engine.advance(id:id)
        try expectEqual(try engine.advance(id:id).phase,.verified)
        try expectEqual(try engine.commit(id:id).phase,.completed)
        try expectEqual(f.unarchives,1);try expectEqual(f.resumes,1)
    }
    func testNativeReturnWholeSubtreeRestoresSequentiallyAndCommitsTogether()throws {
        let f=try NativeReturnFixture();try f.addChild()
        let engine=f.engine(),id=f.f.backup.requestID,child=f.plan.threads[1].id
        _=try engine.prepare(id:id,plan:f.plan);_=try engine.advance(id:id)
        try expectEqual(try engine.advance(id:id).resumeIndex,1)
        try expectNil(f.f.journal.owner(threadID:child))
        f.observation.affectedIDs.append(UUID().uuidString.lowercased())
        try expectThrows(engine.advance(id:id));try expectEqual(f.resumes,1)
        f.observation.affectedIDs.removeLast()
        try expectEqual(try engine.advance(id:id).phase,.verified)
        try expectEqual(f.unarchives,1);try expectEqual(f.resumes,2)
        _=try engine.commit(id:id)
        let rootOwner=try f.f.journal.owner(threadID:f.f.thread)!,childOwner=try f.f.journal.owner(threadID:child)!
        try expectEqual(rootOwner.journalDigest,childOwner.journalDigest)
        try expectEqual(childOwner.home.path,f.plan.server.home)
        try expectEqual(try engine.state(id:id).phase,.completed)
    }
}
#endif
