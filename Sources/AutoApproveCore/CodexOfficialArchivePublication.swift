import Foundation
import Darwin

struct CodexOfficialArchivePublicationState:Codable,Equatable {
    enum Stage:String,Codable {case prepared,attempted,verified}
    let source:CodexMigrationRolloutWitness,archivePath:String
    var stage:Stage = .prepared
}

/// Publishes the *latest verified return*, not the old original snapshot, into
/// its absent native archive slot. Unarchive/resume and ownership publication
/// remain separate observed operations. A lost rename response never retries it.
final class CodexOfficialArchivePublication {
    private let journal:CodexMigrationJournal
    init(journal:CodexMigrationJournal){self.journal=journal}
    private var failure:AppError {.message("최신 대화 이력의 복귀 위치·Goal·저널을 확인하지 못했습니다. 파일 게시를 반복하지 않았습니다.")}
    private func encoded(_ state:CodexGoalReturnState)throws->Data {let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(state)}
    private func matches(_ a:CodexMigrationRolloutWitness,_ b:CodexMigrationRolloutWitness)->Bool {
        a.fileIdentity==b.fileIdentity && a.sha256==b.sha256 && a.size==b.size && a.modifiedSeconds==b.modifiedSeconds && a.modifiedNanoseconds==b.modifiedNanoseconds
    }
    private func load(_ id:String)throws->(CodexMigrationJournalRecord,CodexGoalReturnState) {
        let goal=try CodexGoalReturn(journal:journal).state(id:id)
        guard let loaded=try journal.load(id:id),loaded.consistent,goal.stage == .verified,goal.rollout?.stage == .verified,
              goal.backup.retirement.official != nil,
              [.applied,.unchanged].contains(try CodexGoalReturn(journal:journal).observe(id:id)) else{throw failure}
        try journal.validateReservation(loaded.record)
        if let plan=goal.officialPublication {
            let old=goal.backup.retirement
            guard plan.source.relativePath==old.rollout.relativePath,plan.archivePath==old.originalArchivePath,
                  let expected=goal.rollout?.result == .unchanged ? old.rollout:goal.rollout?.staged,
                  matches(plan.source,expected) else{throw failure}
            try plan.source.validate();_=try RetirementFiles.components(plan.archivePath)
        }
        return(loaded.record,goal)
    }
    private func authorize(_ state:CodexGoalReturnState,source:CodexOfficialWriterLease,destination:CodexOfficialWriterLease,checkpoint:()throws->Void)throws {
        try source.verifyScope(home:state.source.sourceHome,threadIDs:[state.source.threadID])
        try destination.verifyScope(home:state.backup.retirement.goal.sourceHome,threadIDs:[state.source.threadID])
        try Task.checkCancellation();try checkpoint()
        try state.rollout?.source.verifyCurrent()
        try source.verifyScope(home:state.source.sourceHome,threadIDs:[state.source.threadID])
        try destination.verifyScope(home:state.backup.retirement.goal.sourceHome,threadIDs:[state.source.threadID])
    }
    func prepare(id:String,source:CodexOfficialWriterLease,destination:CodexOfficialWriterLease,checkpoint:()throws->Void)throws->CodexOfficialArchivePublicationState {
        let (record,initial)=try load(id)
        guard initial.officialPublication==nil else{throw failure}
        try authorize(initial,source:source,destination:destination,checkpoint:checkpoint)
        let old=initial.backup.retirement
        let actual=try CodexMigrationRolloutWitness.capture(home:old.goal.sourceHome,homeIdentity:old.goal.homeIdentity,relative:old.rollout.relativePath)
        guard let expected=initial.rollout?.result == .unchanged ? old.rollout:initial.rollout?.staged,matches(actual,expected) else{throw failure}
        let plan=CodexOfficialArchivePublicationState(source:actual,archivePath:old.originalArchivePath)
        guard try physical(initial,plan) == .notApplied else{throw failure}
        var state=initial;state.officialPublication=plan
        _=try journal.save(id:id,payload:encoded(state),expectedRevision:record.revision)
        return plan
    }
    func state(id:String)throws->CodexOfficialArchivePublicationState {
        guard let plan=try load(id).1.officialPublication else{throw failure};return plan
    }
    func observe(id:String)throws->CodexGoalReturnState.Result {
        let (_,state)=try load(id);guard let plan=state.officialPublication else{throw failure}
        return try physical(state,plan)
    }
    private func physical(_ state:CodexGoalReturnState,_ plan:CodexOfficialArchivePublicationState)throws->CodexGoalReturnState.Result {
        let home=state.backup.retirement.goal
        let root=try RetirementFiles.home(home.sourceHome,identity:home.homeIdentity);defer{close(root)}
        func witness(_ relative:String)throws->CodexMigrationRolloutWitness? {
            let parts=try RetirementFiles.components(relative),parent=try RetirementFiles.directory(root,parts.dropLast().joined(separator:"/"));defer{close(parent)}
            var info=stat()
            if fstatat(parent,parts.last!,&info,AT_SYMLINK_NOFOLLOW) != 0 {if errno==ENOENT{return nil};throw failure}
            return try .capture(home:home.sourceHome,homeIdentity:home.homeIdentity,relative:relative)
        }
        let original=try witness(plan.source.relativePath),archive=try witness(plan.archivePath)
        if original==nil,let archive,matches(archive,plan.source){return .applied}
        if let original,matches(original,plan.source),archive==nil{return .notApplied}
        return .unknown
    }
    func advance(id:String,source:CodexOfficialWriterLease,destination:CodexOfficialWriterLease,checkpoint:()throws->Void,
                 afterAttempt:()throws->Void={},afterRename:()throws->Void={})throws->CodexOfficialArchivePublicationState {
        let (record,initial)=try load(id);guard var plan=initial.officialPublication else{throw failure}
        try authorize(initial,source:source,destination:destination,checkpoint:checkpoint)
        if plan.stage != .prepared {
            guard plan.stage == .attempted,try physical(initial,plan) == .applied else{return plan}
            plan.stage = .verified;var state=initial;state.officialPublication=plan
            _=try journal.save(id:id,payload:encoded(state),expectedRevision:record.revision);return plan
        }
        guard try physical(initial,plan) == .notApplied else{throw failure}
        plan.stage = .attempted;var attempted=initial;attempted.officialPublication=plan
        let reservation=try journal.save(id:id,payload:encoded(attempted),expectedRevision:record.revision)
        try afterAttempt()
        try authorize(attempted,source:source,destination:destination,checkpoint:checkpoint)
        try journal.validateReservation(reservation)
        guard try physical(attempted,plan) == .notApplied else{throw failure}
        let home=initial.backup.retirement.goal
        let root=try RetirementFiles.home(home.sourceHome,identity:home.homeIdentity);defer{close(root)}
        let from=try RetirementFiles.components(plan.source.relativePath),to=try RetirementFiles.components(plan.archivePath)
        let fromPath=from.dropLast().joined(separator:"/"),toPath=to.dropLast().joined(separator:"/")
        let input=try RetirementFiles.directory(root,fromPath);defer{close(input)}
        let output=try RetirementFiles.directory(root,toPath);defer{close(output)}
        let currentRoot=try RetirementFiles.home(home.sourceHome,identity:home.homeIdentity);defer{close(currentRoot)}
        let currentInput=try RetirementFiles.directory(currentRoot,fromPath);defer{close(currentInput)}
        let currentOutput=try RetirementFiles.directory(currentRoot,toPath);defer{close(currentOutput)}
        for (first,second) in [(root,currentRoot),(input,currentInput),(output,currentOutput)] {
            var a=stat(),b=stat();guard fstat(first,&a)==0,fstat(second,&b)==0,a.st_dev==b.st_dev,a.st_ino==b.st_ino else{throw failure}
        }
        try journal.validateReservation(reservation)
        try authorize(attempted,source:source,destination:destination,checkpoint:checkpoint)
        guard try physical(attempted,plan) == .notApplied else{throw failure}
        guard renameatx_np(input,from.last!,output,to.last!,UInt32(RENAME_EXCL))==0 else{throw failure}
        let file=try RetirementFiles.file(output,to.last!);defer{close(file)}
        try RetirementFiles.sync(file);guard fsync(input)==0,fsync(output)==0 else{throw failure}
        try afterRename()
        guard try physical(attempted,plan) == .applied else{throw failure}
        plan.stage = .verified;attempted.officialPublication=plan
        _=try journal.save(id:id,payload:encoded(attempted),expectedRevision:reservation.revision)
        return plan
    }
}
