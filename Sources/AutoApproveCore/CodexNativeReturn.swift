import Foundation

// No production observer is bound yet. Complete affected scope, runtime history
// and settings are evidence the native producer must actually establish.
struct CodexNativeReturnServer:Codable,Equatable {
    var home:String,homeIdentity:String,serverID:String,cliVersion:String
    var accountDigest:String?=nil
}
struct CodexNativeReturnThread:Codable,Equatable {
    var source:CodexMigrationRetirement,archive:CodexMigrationRolloutWitness
    var sessionRelativePath:String,historyDigest:String,settingsDigest:String
    var previousOwner:CodexMigrationOwner?
    var id:String {source.goal.threadID}
}
struct CodexNativeReturnPlan:Codable,Equatable {
    var rootID:String,server:CodexNativeReturnServer,threads:[CodexNativeReturnThread]
}
struct CodexNativeReturnObservation {
    struct Thread {
        var id:String,relativePath:String,archived:Bool,loaded:Bool
        var active=false,blocked=false
        var historyDigest:String?=nil,settingsDigest:String?=nil
    }
    var server:CodexNativeReturnServer,affectedIDs:[String],completeScope:Bool,threads:[Thread]
}
struct CodexNativeReturnServices {
    var observe:(CodexNativeReturnPlan)throws->CodexNativeReturnObservation
    var unarchive:(CodexNativeReturnPlan)throws->Void
    var resume:(CodexNativeReturnPlan,String)throws->Void
}
struct CodexNativeReturnState:Codable,Equatable {
    enum Phase:String,Codable {case unarchivePrepared,unarchiveAttempted,resumePrepared,resumeAttempted,verified,completed}
    var plan:CodexNativeReturnPlan
    var phase:Phase = .unarchivePrepared
    var resumeIndex=0
}
final class CodexNativeReturn {
    private let journal:CodexMigrationJournal,services:CodexNativeReturnServices
    init(journal:CodexMigrationJournal,services:CodexNativeReturnServices){self.journal=journal;self.services=services}
    private var failure:AppError {.message("Codex 재연결의 서버·영향 대화·이력·설정을 확인하지 못했습니다. 같은 제어 요청을 반복하지 않습니다.")}
    private func hash(_ value:String)->Bool {value.count==64 && value.allSatisfy({$0.isHexDigit})}
    private func path(_ value:String,prefix:String,id:String)->Bool {
        value.hasPrefix(prefix) && value.utf8.count<=4096 && value.hasSuffix(".jsonl") &&
        URL(fileURLWithPath:value).lastPathComponent.contains(id) &&
        !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) &&
        value.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."})
    }
    private func encode(_ state:CodexGoalReturnState)throws->Data {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(state)
    }
    private func validate(_ plan:CodexNativeReturnPlan,goal:CodexGoalReturnState,record:CodexMigrationJournalRecord)throws {
        guard plan.rootID==goal.source.threadID,plan.server.home==goal.backup.retirement.goal.sourceHome,
              plan.server.homeIdentity==goal.backup.retirement.goal.homeIdentity,plan.server.cliVersion=="0.166.0",
              !plan.server.serverID.isEmpty,plan.server.serverID.utf8.count<=1024,
              plan.server.accountDigest.map(hash) ?? true,
              !plan.threads.isEmpty,plan.threads.count<=512,Set(plan.threads.map(\.id)).count==plan.threads.count,
              plan.threads.first?.id==plan.rootID,goal.stage == .verified,goal.rollout?.stage == .verified else{throw failure}
        try journal.validateReservation(record)
        guard [.applied,.unchanged].contains(try CodexGoalReturn(journal:journal).observe(id:record.id)) else{throw failure}
        for thread in plan.threads {
            try thread.source.verifyCurrent();try thread.archive.validate()
            guard thread.source.goal.sourceHome==goal.source.sourceHome,hash(thread.historyDigest),hash(thread.settingsDigest),
                  path(thread.archive.relativePath,prefix:"archived_sessions/",id:thread.id),
                  path(thread.sessionRelativePath,prefix:"sessions/",id:thread.id),
                  thread.archive.sha256==thread.source.rollout.sha256,thread.archive.size==thread.source.rollout.size,
                  thread.archive.fileIdentity != thread.source.rollout.fileIdentity,
                  try journal.owner(threadID:thread.id)==thread.previousOwner else{throw failure}
            let target=try CodexGoalTransferStore.captureSlot(home:plan.server.home,threadID:thread.id)
            guard target.homeIdentity==plan.server.homeIdentity,target.databaseIdentity==goal.backup.retirement.goal.databaseIdentity,
                  target.schemaFingerprint==thread.source.goal.schemaFingerprint,
                  target.row==thread.source.goal.row,target.continuationDeferred==thread.source.goal.continuationDeferred else{throw failure}
            if thread.id==plan.rootID {
                let expectedFile=goal.rollout?.result == .unchanged ? goal.backup.retirement.rollout:goal.rollout?.staged
                guard thread.source.goal==goal.source,thread.previousOwner==goal.backup.currentOwner,
                      thread.source==goal.rollout?.source,
                      [.applied,.unchanged].contains(goal.rollout?.result),
                      thread.archive.fileIdentity==expectedFile?.fileIdentity,
                      thread.archive.sha256==expectedFile?.sha256,thread.archive.size==expectedFile?.size else{throw failure}
            }
        }
    }
    private func observe(_ plan:CodexNativeReturnPlan)throws->CodexNativeReturnObservation {
        let value=try services.observe(plan)
        guard value.server==plan.server,value.completeScope,
              value.affectedIDs.count==plan.threads.count,Set(value.affectedIDs)==Set(plan.threads.map(\.id)),
              value.threads.count==plan.threads.count,Set(value.threads.map(\.id))==Set(value.affectedIDs),
              value.threads.allSatisfy({!$0.active && !$0.blocked}) else{throw failure}
        for expected in plan.threads {
            guard let row=value.threads.first(where:{$0.id==expected.id}) else{throw failure}
            let expectedPath=row.archived ? expected.archive.relativePath:expected.sessionRelativePath
            guard row.relativePath==expectedPath else{throw failure}
            let file=try CodexMigrationRolloutWitness.capture(home:plan.server.home,homeIdentity:plan.server.homeIdentity,relative:expectedPath)
            guard file.fileIdentity==expected.archive.fileIdentity else{throw failure}
            if !row.loaded {guard file.sha256==expected.archive.sha256,file.size==expected.archive.size else{throw failure}}
        }
        return value
    }
    private func confirmed(_ row:CodexNativeReturnObservation.Thread,_ expected:CodexNativeReturnThread)->Bool {
        !row.archived && row.loaded && row.historyDigest==expected.historyDigest && row.settingsDigest==expected.settingsDigest
    }
    private func load(_ id:String)throws->(CodexMigrationJournalRecord,CodexGoalReturnState,CodexNativeReturnState) {
        let goal=try CodexGoalReturn(journal:journal).state(id:id)
        guard let native=goal.nativeRestore,let loaded=try journal.load(id:id),loaded.consistent,
              native.resumeIndex>=0,native.resumeIndex<=native.plan.threads.count,
              native.phase != .completed else{throw failure}
        try validate(native.plan,goal:goal,record:loaded.record)
        return(loaded.record,goal,native)
    }
    func prepare(id:String,plan:CodexNativeReturnPlan)throws->CodexNativeReturnState {
        var goal=try CodexGoalReturn(journal:journal).state(id:id)
        guard goal.nativeRestore==nil,let loaded=try journal.load(id:id),loaded.consistent else{throw failure}
        try validate(plan,goal:goal,record:loaded.record)
        let observation=try observe(plan)
        guard observation.threads.allSatisfy({$0.archived && !$0.loaded}) else{throw failure}
        goal.nativeRestore = .init(plan:plan)
        _=try journal.save(id:id,payload:encode(goal),expectedRevision:loaded.record.revision)
        return goal.nativeRestore!
    }
    func state(id:String)throws->CodexNativeReturnState {
        if let loaded=try journal.load(id:id),loaded.consistent,loaded.record.terminal {
            let goal=try JSONDecoder().decode(CodexGoalReturnState.self,from:loaded.record.payload)
            guard let native=goal.nativeRestore,native.phase == .completed,native.resumeIndex==native.plan.threads.count,
                  let owners=loaded.record.ownership,Set(owners.map(\.threadID))==Set(native.plan.threads.map(\.id)),
                  owners.count==native.plan.threads.count,
                  native.plan.threads.allSatisfy({entry in owners.contains(where:{
                      $0.threadID==entry.id && $0.previous==entry.previousOwner && $0.retirement==entry.source &&
                      $0.destination == .init(path:native.plan.server.home,identity:native.plan.server.homeIdentity)
                  })}) else{throw failure}
            return native
        }
        return try load(id).2
    }
    private func reconcile(_ id:String)throws->CodexNativeReturnState {
        let (record,initial,native)=try load(id)
        let observation=try observe(native.plan)
        var next=native
        if native.phase == .unarchiveAttempted {
            guard observation.threads.allSatisfy({!$0.archived && !$0.loaded}) else{return native}
            next.phase = .resumePrepared
        }else if native.phase == .resumeAttempted {
            guard native.resumeIndex<native.plan.threads.count else{throw failure}
            for index in 0...native.resumeIndex {
                let expected=native.plan.threads[index],row=observation.threads.first{$0.id==expected.id}!
                guard confirmed(row,expected) else{return native}
            }
            next.resumeIndex+=1
            next.phase=next.resumeIndex==next.plan.threads.count ? .verified:.resumePrepared
        }else if native.phase == .verified {
            guard native.plan.threads.allSatisfy({expected in confirmed(observation.threads.first{$0.id==expected.id}!,expected)}) else{throw failure}
            return native
        }else{throw failure}
        var goal=initial;goal.nativeRestore=next
        _=try journal.save(id:id,payload:encode(goal),expectedRevision:record.revision)
        return next
    }
    func advance(id:String)throws->CodexNativeReturnState {
        let (record,initial,native)=try load(id)
        if [.unarchiveAttempted,.resumeAttempted,.verified].contains(native.phase){return try reconcile(id)}
        let observation=try observe(native.plan)
        var attempted=native
        if native.phase == .unarchivePrepared {
            guard observation.threads.allSatisfy({$0.archived && !$0.loaded}) else{throw failure}
            attempted.phase = .unarchiveAttempted
        }else if native.phase == .resumePrepared {
            guard native.resumeIndex<native.plan.threads.count else{throw failure}
            for (index,expected) in native.plan.threads.enumerated() {
                let row=observation.threads.first{$0.id==expected.id}!
                guard !row.archived,index<native.resumeIndex ? confirmed(row,expected):!row.loaded else{throw failure}
            }
            attempted.phase = .resumeAttempted
        }else{throw failure}
        var goal=initial;goal.nativeRestore=attempted
        let receipt=try journal.save(id:id,payload:encode(goal),expectedRevision:record.revision)
        try journal.validateReservation(receipt)
        if attempted.phase == .unarchiveAttempted {try services.unarchive(attempted.plan)}
        else{try services.resume(attempted.plan,attempted.plan.threads[attempted.resumeIndex].id)}
        return try reconcile(id)
    }
    func commit(id:String)throws->CodexNativeReturnState {
        guard try reconcile(id).phase == .verified else{throw failure}
        let (record,initial,native)=try load(id)
        var completed=native;completed.phase = .completed
        var goal=initial;goal.nativeRestore=completed
        let destination=CodexMigrationJournalRecord.Home(path:native.plan.server.home,identity:native.plan.server.homeIdentity)
        _=try journal.complete(id:id,payload:encode(goal),expectedRevision:record.revision,
            ownership:native.plan.threads.map{.init(threadID:$0.id,previous:$0.previousOwner,destination:destination,retirement:$0.source)})
        try journal.release(id:id)
        return completed
    }
}
