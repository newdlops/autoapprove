import Foundation

// Internal Goal-only effect. Native writer closure, history import, destination
// connection and ownership commit are separate gates and are not implied here.
struct CodexGoalReturnState:Codable,Equatable {
    enum Stage:String,Codable {case prepared,attempted,verified}
    enum Result:String,Codable {case applied,unchanged,notApplied,unknown}
    var formatVersion=1
    var backup:CodexMigrationRetiredBackup,source:CodexGoalTransferSlot
    var originalPayload:Data
    var stage:Stage = .prepared
    var result:Result?=nil
    var rollout:CodexRolloutReturnState?=nil
    var nativeRestore:CodexNativeReturnState?=nil
}
final class CodexGoalReturn {
    private let journal:CodexMigrationJournal
    init(journal:CodexMigrationJournal){self.journal=journal}
    private var failure:AppError {.message("Goal 반환의 예약·원본·백업 상태가 바뀌었습니다. 같은 변경을 반복하지 않습니다.")}
    private func encode(_ state:CodexGoalReturnState)throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(state)
    }
    private func validate(_ state:CodexGoalReturnState,record:CodexMigrationJournalRecord)throws {
        let backup=state.backup,source=state.source,old=backup.retirement.goal
        guard state.formatVersion==1,record.id==backup.requestID,source.threadID==old.threadID,
              source.sourceHome==backup.currentOwner.home.path,source.homeIdentity==backup.currentOwner.home.identity,
              source.sourceHome != old.sourceHome,source.schemaFingerprint==old.schemaFingerprint,
              state.originalPayload.count<=8*1024*1024,
              (state.stage == .verified) == (state.result != nil),
              state.result.map({$0 == .applied || $0 == .unchanged}) ?? true,
              try journal.owner(threadID:source.threadID)==backup.currentOwner else{throw failure}
        try journal.validateReservation(record)
        try backup.verify()
    }
    func prepare(backup:CodexMigrationRetiredBackup,source:CodexGoalTransferSlot,expectedRevision:Int)throws->CodexGoalReturnState {
        try journal.verifyBackup(backup,expectedRevision:expectedRevision)
        try CodexGoalTransferStore.verifyCurrent(source)
        guard let loaded=try journal.load(id:backup.requestID),loaded.consistent else{throw failure}
        let state=CodexGoalReturnState(backup:backup,source:source,originalPayload:loaded.record.payload)
        try validate(state,record:loaded.record)
        _=try journal.save(id:backup.requestID,payload:encode(state),expectedRevision:expectedRevision)
        return state
    }
    private func load(_ id:String)throws->(CodexMigrationJournalRecord,CodexGoalReturnState) {
        guard let loaded=try journal.load(id:id),loaded.consistent else{throw failure}
        let state=try JSONDecoder().decode(CodexGoalReturnState.self,from:loaded.record.payload)
        try validate(state,record:loaded.record)
        return(loaded.record,state)
    }
    func state(id:String)throws->CodexGoalReturnState {try load(id).1}
    private func sameValue(_ a:CodexGoalTransferSlot,_ b:CodexGoalTransferSlot)->Bool {a.row==b.row && a.continuationDeferred==b.continuationDeferred}
    func apply(id:String)throws->CodexGoalReturnState.Result {
        let (prepared,initial)=try load(id)
        guard initial.stage == .prepared else{throw failure}
        try CodexGoalTransferStore.verifyCurrent(initial.source)
        try initial.backup.retirement.verifyCurrent()
        var state=initial
        if sameValue(initial.source,initial.backup.retirement.goal) {
            state.stage = .verified;state.result = .unchanged
            _=try journal.save(id:id,payload:encode(state),expectedRevision:prepared.revision)
            return .unchanged
        }
        state.stage = .attempted
        // All three copies must contain attempted before any Goal DB write.
        let attempted=try journal.save(id:id,payload:encode(state),expectedRevision:prepared.revision)
        try CodexGoalTransferStore.replaceRetired(initial.source,expected:initial.backup.retirement.goal) {
            try self.validate(state,record:attempted)
            try CodexGoalTransferStore.verifyCurrent(initial.source)
            try initial.backup.retirement.verifyCurrent()
        }
        guard try observe(id:id) == .applied else{throw failure}
        state.stage = .verified;state.result = .applied
        _=try journal.save(id:id,payload:encode(state),expectedRevision:attempted.revision)
        return .applied
    }
    // Observation never retries or changes either Goal DB or journal.
    func observe(id:String)throws->CodexGoalReturnState.Result {
        let (_,state)=try load(id)
        guard state.stage != .prepared else{throw failure}
        do {
            try CodexGoalTransferStore.verifyCurrent(state.source)
            let old=state.backup.retirement.goal
            let current=try CodexGoalTransferStore.captureSlot(home:old.sourceHome,threadID:old.threadID)
            guard current.homeIdentity==old.homeIdentity,current.databaseIdentity==old.databaseIdentity,
                  current.schemaFingerprint==old.schemaFingerprint else{return .unknown}
            if sameValue(current,state.source){return sameValue(old,state.source) ? .unchanged:.applied}
            if current==old{return .notApplied}
            return .unknown
        }catch{return .unknown}
    }
}
