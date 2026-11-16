import Foundation
import Darwin

/// Official archived-history handoff after the caller has stopped the affected
/// clients. No private TUI connection IDs or native input leases are used.
struct CodexOfficialConversationTransferState:Codable,Equatable {
    let source:CodexMigrationRetirement
    let destinationHome:String
    var goalSlots:[CodexGoalTransferSlotReference]?
    var retirement:CodexOfficialRetirementIntent?
    var imported:CodexNativeSelectedArchiveImport?
    var returnTo:CodexMigrationRetirement?
    var returnVerified:Bool?
}

final class CodexOfficialConversationTransfer {
    private let journal:CodexMigrationJournal
    private let store:AuditStore
    private var stage="기록 확인"
    init(store:AuditStore)throws{self.store=store;journal=try CodexMigrationJournal(store:store)}
    private var failure:AppError {.message("공식 Codex 대화 이전의 "+stage+" 단계에서 기록·원본·목적지가 일치하지 않습니다. 기존 이력을 덮어쓰지 않았습니다.")}
    private func encode(_ state:CodexOfficialConversationTransferState)throws->Data {try JSONEncoder().encode(state)}
    private func key(_ id:String)->String {"codexOfficialTransfer:"+id}
    private func save(_ value:CodexOfficialConversationTransferState,record:CodexMigrationJournalRecord)throws {
        try journal.validateReservation(record)
        try store.set(key(record.id),String(decoding:encode(value),as:UTF8.self))
    }
    func prepare(id:UUID,sourceHome:String,destinationHome:String,threadID:String,archivedPath:String,
                 checkpoint:()throws->Void)throws {
        try checkpoint()
        let source=try CodexMigrationRetirement.capture(home:sourceHome,threadID:threadID,rolloutPath:archivedPath)
        let selected=try CodexAccountTransitionTarget.canonicalHome(destinationHome)
        guard let pointer=realpath(selected,nil) else{throw failure}
        let destination=String(cString:pointer);free(pointer)
        guard source.goal.sourceHome != destination else{throw failure}
        let owner=try journal.owner(threadID:threadID)
        if let owner {guard owner.home.path==source.goal.sourceHome else{throw failure}}
        var state=CodexOfficialConversationTransferState(source:source,destinationHome:destination)
        if let owner {state.returnTo=try? journal.retired(threadID:threadID,toHome:destination,expectedOwner:owner)}
        _=try journal.create(id:id.uuidString.lowercased(),homes:[source.goal.sourceHome,destination],payload:encode(state))
    }
    func state(id:UUID)throws->CodexOfficialConversationTransferState {
        guard let loaded=try journal.load(id:id.uuidString.lowercased()),loaded.consistent else{throw failure}
        let binding=(try? JSONDecoder().decode(CodexGoalReturnState.self,from:loaded.record.payload))?.originalPayload ?? loaded.record.payload
        let payload=loaded.record.terminal ? loaded.record.payload:store.value(key(loaded.record.id)).map{Data($0.utf8)} ?? binding
        let value=try JSONDecoder().decode(CodexOfficialConversationTransferState.self,from:payload)
        let initial=try JSONDecoder().decode(CodexOfficialConversationTransferState.self,from:binding)
        guard value.source==initial.source,value.destinationHome==initial.destinationHome,value.returnTo==initial.returnTo else{throw failure}
        guard loaded.record.homes.contains(where:{$0.path==value.source.goal.sourceHome && $0.identity==value.source.goal.homeIdentity}),
              loaded.record.homes.contains(where:{$0.path==value.destinationHome}) else{throw failure}
        return value
    }
    func completed(id:UUID)throws->Bool {
        guard let loaded=try journal.load(id:id.uuidString.lowercased()),loaded.consistent,loaded.record.terminal else{return false}
        let value=try state(id:id)
        guard let owner=try journal.owner(threadID:value.source.goal.threadID) else{return false}
        return owner.home.path==value.destinationHome && (value.imported != nil || value.returnVerified==true)
    }
    func advance(id:UUID,checkpoint:()throws->Void)throws->CodexOfficialConversationTransferState {
        let requestID=id.uuidString.lowercased()
        let record=try journal.repair(id:requestID)
        var value=try state(id:id)
        if record.terminal {guard try completed(id:id) else{throw failure};return value}
        guard let destination=record.homes.first(where:{$0.path==value.destinationHome}) else{throw failure}
        let thread=value.source.goal.threadID
        // Exclude both original rollout writers through the original Codex lock
        // protocol. The caller's checkpoint supplies the stopped-cohort barrier.
        let sourceLease=try CodexOfficialWriterLease(home:value.source.goal.sourceHome,threadIDs:[thread])
        let targetLease=try CodexOfficialWriterLease(home:destination.path,threadIDs:[thread],initializeDestination:true)
        defer{sourceLease.close();targetLease.close()}
        func check()throws {
            try Task.checkCancellation();try checkpoint()
            try sourceLease.verifyScope(home:value.source.goal.sourceHome,threadIDs:[thread])
            try targetLease.verifyScope(home:destination.path,threadIDs:[thread])
        }
        try check()
        stage="Goal 보관"
        if value.goalSlots==nil {
            value.goalSlots=try CodexGoalTransferSlotStore.capture(home:value.source.goal.sourceHome,homeIdentity:value.source.goal.homeIdentity,requestID:requestID,threadIDs:[thread])
            try save(value,record:record)
        }
        let retirement=CodexOfficialRetirement(journal:journal)
        stage="원본 보관 준비"
        if value.retirement==nil {
            if let recovered=try? retirement.load(record:record,sourceHome:value.source.goal.sourceHome,threadID:thread) {value.retirement=recovered}
            else {value.retirement=try retirement.prepare(record:record,source:value.source,lease:sourceLease,checkpoint:check)}
            try save(value,record:record)
        }
        guard let intent=value.retirement,let slots=value.goalSlots else{throw failure}
        if let old=value.returnTo {
            stage="최신 대화 복귀"
            let retirementState=try retirement.observe(intent)
            if retirementState == .reserved {
                guard try retirement.withdraw(intent,record:record,lease:sourceLease,checkpoint:check) == .withheld else{throw failure}
            }else{guard retirementState == .withheld else{throw failure}}
            let latest=try retirement.storageFact(intent)
            guard let owner=try journal.owner(threadID:thread),owner.home.path==value.source.goal.sourceHome else{throw failure}
            let goals=CodexGoalReturn(journal:journal)
            if (try? goals.state(id:requestID))==nil {
                let backup=try journal.backupRetired(old,expectedOwner:owner,requestID:requestID,expectedRevision:record.revision)
                _=try goals.prepare(backup:backup,source:latest.goal,expectedRevision:record.revision)
            }
            try check()
            guard [.applied,.unchanged].contains(try goals.recover(id:requestID)) else{throw failure}
            let history=CodexRolloutReturn(journal:journal)
            // Publication consumes the staged destination path. Once its own
            // intent exists, let that observer confirm the rename instead of
            // mistaking the consumed path for missing history.
            if try goals.state(id:requestID).officialPublication==nil {
                if try goals.state(id:requestID).rollout==nil {_=try history.prepare(id:requestID,source:latest)}
                try check()
                guard [.applied,.unchanged].contains(try history.recover(id:requestID)) else{throw failure}
            }
            let publication=CodexOfficialArchivePublication(journal:journal)
            if try goals.state(id:requestID).officialPublication==nil {
                _=try publication.prepare(id:requestID,source:sourceLease,destination:targetLease,checkpoint:check)
            }
            guard try publication.advance(id:requestID,source:sourceLease,destination:targetLease,checkpoint:check).stage == .verified,
                  try publication.observe(id:requestID) == .applied else{throw failure}
            value.returnVerified=true
            try check()
            let current=try journal.repair(id:requestID)
            _=try journal.complete(id:requestID,payload:encode(value),expectedRevision:current.revision,
                ownership:[.init(threadID:thread,previous:owner,destination:destination,retirement:latest)])
            try journal.release(id:requestID)
            return value
        }
        stage="대화 파일 복사"
        if value.imported==nil {
            guard try retirement.observe(intent) == .reserved else{throw failure}
            let file=value.source.rollout
            let archived=CodexNativeArchivedFile(threadId:thread,relativePath:file.relativePath,fileIdentity:file.fileIdentity,
                sha256:file.sha256,size:file.size,modifiedSeconds:file.modifiedSeconds,modifiedNanoseconds:file.modifiedNanoseconds)
            value.imported=try CodexNativeSelectedArchiveImport.install(requestID:requestID,
                sourceHome:value.source.goal.sourceHome,sourceHomeIdentity:value.source.goal.homeIdentity,
                destinationHome:destination.path,destinationHomeIdentity:destination.identity,files:[archived],goalSlots:slots,threadIDs:[thread],checkpoint:check)
            try save(value,record:record)
        }
        guard let imported=value.imported,imported.importedFiles.count==1 else{throw failure}
        stage="목적지 검증"
        let installed=imported.importedFiles[0]
        let actual=try CodexMigrationRolloutWitness.capture(home:destination.path,homeIdentity:destination.identity,relative:installed.relativePath,checkpoint:check)
        let targetGoal=try CodexGoalTransferStore.captureSlot(home:destination.path,threadID:thread)
        guard actual==installed.witness,actual.sha256==value.source.rollout.sha256,
              imported.marker.requestID==requestID,imported.marker.goalSlots==slots,installed.threadId==thread,
              targetGoal.row==value.source.goal.row,targetGoal.continuationDeferred==value.source.goal.continuationDeferred else{throw failure}
        try check()
        stage="원본 보관"
        // Re-observe an uncertain withdrawal; the retained original inode is
        // never deleted, and destination activation is still a separate step.
        guard try retirement.withdraw(intent,record:record,lease:sourceLease,checkpoint:check) == .withheld else{throw failure}
        let fact=try retirement.storageFact(intent)
        let previous=try journal.owner(threadID:thread)
        stage="이전 결과 저장"
        guard previous==nil || previous?.home.path==value.source.goal.sourceHome else{throw failure}
        _=try journal.complete(id:requestID,payload:encode(value),expectedRevision:record.revision,
            ownership:[.init(threadID:thread,previous:previous,destination:destination,retirement:fact)])
        try journal.release(id:requestID)
        return value
    }
}
