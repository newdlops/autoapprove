import Foundation

// This effect ends at the archived file. Native unarchive/resume and final
// ownership publication require separate scoped, observed effects.
struct CodexRolloutReturnState:Codable,Equatable {
    enum Stage:String,Codable {case staging,prepared,attempted,verified}
    var source:CodexMigrationRetirement
    var stage:Stage
    var staged:CodexMigrationRolloutWitness?=nil
    var result:CodexGoalReturnState.Result?=nil
}
final class CodexRolloutReturn {
    private let journal:CodexMigrationJournal
    private var goals:CodexGoalReturn {CodexGoalReturn(journal:journal)}
    private var failure:AppError {.message("대화 이력 반환의 원본·보관본·예약 상태가 바뀌었습니다. 같은 파일 변경을 반복하지 않습니다.")}
    init(journal:CodexMigrationJournal){self.journal=journal}
    private func encode(_ state:CodexGoalReturnState)throws->Data {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(state)
    }
    private func load(_ id:String)throws->(CodexMigrationJournalRecord,CodexGoalReturnState) {
        let state=try goals.state(id:id)
        guard state.stage == .verified,let loaded=try journal.load(id:id),loaded.consistent,
              [.applied,.unchanged].contains(try goals.observe(id:id)) else{throw failure}
        try journal.validateReservation(loaded.record)
        if let rollout=state.rollout {
            guard rollout.source.goal==state.source,
                  (rollout.stage == .staging)==(rollout.staged==nil),
                  (rollout.stage == .verified)==(rollout.result != nil),
                  rollout.result.map({$0 == .applied || $0 == .unchanged}) ?? true else{throw failure}
            try rollout.source.verifyCurrent()
            if let staged=rollout.staged {
                try staged.validate()
                guard staged.relativePath==CodexMigrationRolloutStaging.relative(state.backup),
                      staged.size==rollout.source.rollout.size,staged.sha256==rollout.source.rollout.sha256 else{throw failure}
            }
        }
        return(loaded.record,state)
    }
    private func verifyOriginal(_ state:CodexGoalReturnState)throws {
        let old=state.backup.retirement
        guard try CodexMigrationRolloutWitness.capture(home:old.goal.sourceHome,homeIdentity:old.goal.homeIdentity,relative:old.rollout.relativePath)==old.rollout else{throw failure}
    }
    func prepare(id:String,source:CodexMigrationRetirement)throws->CodexGoalReturnState {
        let (record,initial)=try load(id)
        guard initial.rollout==nil,source.goal==initial.source else{throw failure}
        try source.verifyCurrent();try verifyOriginal(initial)
        var state=initial;state.rollout = .init(source:source,stage:.staging)
        let staging=try journal.save(id:id,payload:encode(state),expectedRevision:record.revision)
        // A persisted staging intent is single-use too. Recovery may adopt only
        // a complete matching file; it never copies over missing/partial output.
        _=try CodexMigrationRolloutStaging.create(source:source,backup:state.backup)
        try journal.validateReservation(staging)
        return try recoverStaging(id:id)
    }
    func recoverStaging(id:String)throws->CodexGoalReturnState {
        let (record,initial)=try load(id)
        guard let rollout=initial.rollout,rollout.stage == .staging else{throw failure}
        try verifyOriginal(initial)
        let staged=try CodexMigrationRolloutStaging.inspect(backup:initial.backup)
        guard staged.sha256==rollout.source.rollout.sha256,staged.size==rollout.source.rollout.size else{throw failure}
        var state=initial;state.rollout?.stage = .prepared;state.rollout?.staged=staged
        try journal.validateReservation(record)
        _=try journal.save(id:id,payload:encode(state),expectedRevision:record.revision)
        return state
    }
    func apply(id:String)throws->CodexGoalReturnState.Result {
        let (record,initial)=try load(id)
        guard let rollout=initial.rollout,rollout.stage == .prepared,let staged=rollout.staged else{throw failure}
        try verifyOriginal(initial)
        guard try CodexMigrationRolloutStaging.inspect(backup:initial.backup)==staged else{throw failure}
        var state=initial
        if rollout.source.rollout.sha256==state.backup.retirement.rollout.sha256,
           rollout.source.rollout.size==state.backup.retirement.rollout.size {
            state.rollout?.stage = .verified;state.rollout?.result = .unchanged
            _=try journal.save(id:id,payload:encode(state),expectedRevision:record.revision)
            return .unchanged
        }
        state.rollout?.stage = .attempted
        let attempted=try journal.save(id:id,payload:encode(state),expectedRevision:record.revision)
        try CodexMigrationRolloutStaging.install(source:rollout.source,backup:initial.backup,staged:staged) {
            let (fresh,_)=try self.load(id)
            guard fresh==attempted else{throw self.failure}
            try self.verifyOriginal(initial)
        }
        guard try observe(id:id) == .applied else{throw failure}
        state.rollout?.stage = .verified;state.rollout?.result = .applied
        _=try journal.save(id:id,payload:encode(state),expectedRevision:attempted.revision)
        return .applied
    }
    func observe(id:String)throws->CodexGoalReturnState.Result {
        let (_,state)=try load(id)
        guard let rollout=state.rollout,[.attempted,.verified].contains(rollout.stage),let staged=rollout.staged else{throw failure}
        do {
            let old=state.backup.retirement
            let target=try CodexMigrationRolloutWitness.capture(home:old.goal.sourceHome,homeIdentity:old.goal.homeIdentity,relative:old.rollout.relativePath)
            if target.fileIdentity==staged.fileIdentity,target.sha256==staged.sha256,target.size==staged.size{return .applied}
            if target==old.rollout {
                return old.rollout.sha256==rollout.source.rollout.sha256 && old.rollout.size==rollout.source.rollout.size ? .unchanged:.notApplied
            }
            return .unknown
        }catch{return .unknown}
    }
}
