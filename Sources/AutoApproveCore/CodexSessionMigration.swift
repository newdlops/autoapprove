import Foundation
import Darwin

// Internal prepare-only gate. There is deliberately no native termination,
// import, launch, credential-copy or UI/IPC binding in this component yet.
// The native adapter must prove complete membership and backend identities;
// distinct strings supplied by an unverified producer are not isolation proof.
struct CodexMigrationAccount:Codable,Equatable,Sendable {
    var subjectID:String,sessionID:String,workspaceID:String
}
struct CodexMigrationEndpoint:Codable,Equatable,Sendable {
    var home:String,physicalHomeID:String,serverID:String,socketID:String
    var credentialStoreID:String,cliIdentity:String,cliVersion:String
    var account:CodexMigrationAccount
}
struct CodexMigrationClientID:Codable,Hashable,Sendable {
    var pid:Int32,started:String,tty:String
}
struct CodexMigrationClient:Codable,Equatable,Sendable {
    var identity:CodexMigrationClientID,home:String,threadIDs:[String]
    var hasDraft=false,hasQuestion=false,hasQueuedInput=false,hasIndependentWork=false
    fileprivate var blocked:Bool {hasDraft || hasQuestion || hasQueuedInput || hasIndependentWork}
    fileprivate func sameMembership(_ other:Self)->Bool {
        identity==other.identity && home==other.home && Set(threadIDs)==Set(other.threadIDs) && blocked==other.blocked
    }
}
struct CodexMigrationThread:Codable,Equatable,Sendable {
    var id:String,home:String,parentID:String?,turnID:String?,goalRevision:String?,configurationID:String,resumable:Bool
    var active=false
    var goalStatus:CodexGoal.Status?=nil
}
struct CodexSessionMigrationObservation:Sendable {
    var source:CodexMigrationEndpoint,destination:CodexMigrationEndpoint
    var clients:[CodexMigrationClient],threads:[CodexMigrationThread]
    var completeClients:Bool,completeThreads:Bool
}
struct CodexSessionMigrationRequest:Codable,Equatable,Sendable {
    var id:String,source:CodexMigrationEndpoint,destination:CodexMigrationEndpoint
    var clients:[CodexMigrationClient],threads:[CodexMigrationThread]
}
struct CodexSessionMigrationState:Codable,Equatable {
    enum Stage:String,Codable {case reserved,prepared,cancelled}
    enum Cancellation:String,Codable {case requested,changedBeforeEffects}
    struct Execution:Codable,Equatable {
        enum Phase:String,Codable {case shutdownAttempted,retireAttempted}
        var phase:Phase
        var ownershipRevision:Int?=nil
    }
    var formatVersion=1
    var request:CodexSessionMigrationRequest
    var stage:Stage = .prepared
    var cancellation:Cancellation?=nil
    // Verified owners at preparation. Once execution exists, recovery must
    // consult native durable policy rather than treating this as current fact.
    var currentOwners:[String:String]
    var execution:Execution?=nil
}
@MainActor struct CodexSessionMigrationServices {
    var observe:(CodexSessionMigrationRequest) async throws ->CodexSessionMigrationObservation
}

@MainActor final class CodexSessionMigrationCoordinator {
    private let journal:CodexMigrationJournal
    private let services:CodexSessionMigrationServices
    private var preparing=false
    private var preparingID:String?
    private var preparationCancelled=false
    init(journal:CodexMigrationJournal,services:CodexSessionMigrationServices) {self.journal=journal;self.services=services}
    private static var failure:AppError {.message("선택한 Codex 세션·계정·대화의 소유권 또는 대기 입력을 확인하지 못했습니다. 원본을 유지했습니다.")}
    private static func text(_ value:String,max:Int=1024)->Bool {
        !value.isEmpty && value.utf8.count<=max && !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
    }
    private static func threadID(_ value:String)->Bool {UUID(uuidString:value)?.uuidString.lowercased()==value}
    private static func physicalHome(_ value:CodexMigrationEndpoint)throws {
        let canonical=try CodexAccountTransitionTarget.canonicalHome(value.home)
        guard let pointer=realpath(canonical,nil) else{throw failure};defer{free(pointer)}
        let path=String(cString:pointer);var info=stat()
        guard path==value.home,lstat(path,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),
              value.physicalHomeID=="\(info.st_dev):\(info.st_ino)" else{throw failure}
    }
    private static func endpoints(_ source:CodexMigrationEndpoint,_ destination:CodexMigrationEndpoint)throws {
        for endpoint in [source,destination] {
            try physicalHome(endpoint)
            guard [endpoint.serverID,endpoint.socketID,endpoint.credentialStoreID,endpoint.cliIdentity,
                   endpoint.account.subjectID,endpoint.account.sessionID,endpoint.account.workspaceID].allSatisfy({text($0)}),
                  ["0.166.0","0.167.1"].contains(endpoint.cliVersion) else{throw failure}
        }
        guard source.cliVersion==destination.cliVersion,
              source.home != destination.home,source.physicalHomeID != destination.physicalHomeID,
              source.serverID != destination.serverID,source.socketID != destination.socketID,
              source.credentialStoreID != destination.credentialStoreID else{throw failure}
    }
    private static func client(_ value:CodexMigrationClient)throws {
        guard value.identity.pid>0,text(value.identity.started,max:256),value.identity.tty.hasPrefix("/dev/"),text(value.identity.tty,max:512),
              !value.threadIDs.isEmpty,value.threadIDs.count<=512,Set(value.threadIDs).count==value.threadIDs.count,
              value.threadIDs.allSatisfy(threadID) else{throw failure}
    }
    private static func request(_ value:CodexSessionMigrationRequest)throws {
        guard UUID(uuidString:value.id)?.uuidString.lowercased()==value.id,
              !value.clients.isEmpty,value.clients.count<=64,!value.threads.isEmpty,value.threads.count<=512,
              Set(value.clients.map(\.identity)).count==value.clients.count,Set(value.clients.map{$0.identity.pid}).count==value.clients.count,
              Set(value.threads.map(\.id)).count==value.threads.count else{throw failure}
        try endpoints(value.source,value.destination)
        for member in value.clients {
            try client(member);guard member.home==value.source.home,!member.blocked else{throw failure}
        }
        let selected=Set(value.clients.flatMap(\.threadIDs))
        guard selected==Set(value.threads.map(\.id)) else{throw failure}
        for thread in value.threads {
            guard threadID(thread.id),thread.home==value.source.home,thread.resumable,text(thread.configurationID),
                  thread.parentID.map({threadID($0) && $0 != thread.id}) ?? true,
                  thread.turnID.map({text($0)}) ?? true,
                  thread.goalRevision.map({text($0)}) ?? true,
                  (thread.goalRevision==nil)==(thread.goalStatus==nil),!thread.active || thread.turnID != nil else{throw failure}
        }
    }
    private static func validate(_ observation:CodexSessionMigrationObservation,for value:CodexSessionMigrationRequest)throws {
        try request(value)
        guard observation.completeClients,observation.completeThreads,observation.clients.count<=1024,observation.threads.count<=4096,
              observation.source==value.source,observation.destination==value.destination,
              Set(observation.clients.map(\.identity)).count==observation.clients.count,
              Set(observation.clients.map{$0.identity.pid}).count==observation.clients.count,
              Set(observation.threads.map(\.id)).count==observation.threads.count else{throw failure}
        let homes=Set([value.source.home,value.destination.home]),selected=Set(value.clients.map(\.identity)),ids=Set(value.threads.map(\.id))
        for member in observation.clients {
            try client(member);guard homes.contains(member.home) else{throw failure}
            if selected.contains(member.identity) {
                guard let expected=value.clients.first(where:{$0.identity==member.identity}),member.sameMembership(expected),!member.blocked else{throw failure}
            }else if !ids.isDisjoint(with:member.threadIDs) {throw failure}
        }
        guard observation.clients.filter({selected.contains($0.identity)}).count==selected.count else{throw failure}
        let observed=Dictionary(uniqueKeysWithValues:observation.threads.map{($0.id,$0)})
        for thread in value.threads {guard observed[thread.id]==thread else{throw failure}}
        // Include every known descendant of any selected conversation. A
        // hidden child cannot silently remain with the old writer/account.
        for thread in observation.threads {
            guard threadID(thread.id),homes.contains(thread.home),thread.parentID.map(threadID) ?? true else{throw failure}
            var cursor=thread.parentID,seen:Set<String>=[thread.id]
            while let parent=cursor {
                guard seen.insert(parent).inserted else{throw failure}
                if ids.contains(parent),!ids.contains(thread.id) {throw failure}
                cursor=observed[parent]?.parentID
            }
        }
    }
    private static func encode(_ state:CodexSessionMigrationState)throws->Data {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(state)
    }
    private static func decode(_ record:CodexMigrationJournalRecord)throws->CodexSessionMigrationState {
        let state=try JSONDecoder().decode(CodexSessionMigrationState.self,from:record.payload)
        try request(state.request)
        let expected=[state.request.source,state.request.destination].map{CodexMigrationJournalRecord.Home(path:$0.home,identity:$0.physicalHomeID)}.sorted{$0.path<$1.path}
        guard state.formatVersion==1,state.request.id==record.id,record.homes==expected,
              state.currentOwners==Dictionary(uniqueKeysWithValues:state.request.threads.map{($0.id,state.request.source.home)}),
              record.terminal==(state.stage == .cancelled),
              (state.stage == .cancelled)==(state.cancellation != nil) else{throw failure}
        if let execution=state.execution {
            guard state.stage == .prepared,
                  execution.phase == .retireAttempted ? (execution.ownershipRevision.map{$0>=0} ?? false):execution.ownershipRevision==nil else{throw failure}
        }
        return state
    }
    func prepare(_ proposed:CodexSessionMigrationRequest) async throws ->CodexSessionMigrationState {
        guard !preparing else{throw Self.failure};preparing=true
        preparationCancelled=false
        defer{preparing=false;preparingID=nil;preparationCancelled=false}
        var value=proposed
        guard let id=UUID(uuidString:value.id) else{throw Self.failure};value.id=id.uuidString.lowercased()
        preparingID=value.id
        try Self.request(value)
        try Self.validate(try await services.observe(value),for:value)
        guard !preparationCancelled else{throw CancellationError()}
        try Task.checkCancellation()
        var state=CodexSessionMigrationState(request:value,stage:.reserved,currentOwners:Dictionary(uniqueKeysWithValues:value.threads.map{($0.id,value.source.home)}))
        let reserved=try journal.create(id:value.id,homes:[value.source.home,value.destination.home],payload:Self.encode(state))
        do {
            _ = try Self.decode(reserved)
            try Self.validate(try await services.observe(value),for:value)
            guard !preparationCancelled else{throw CancellationError()}
            try Task.checkCancellation()
            guard let fresh=try journal.load(id:value.id),fresh.consistent,fresh.record==reserved else{throw Self.failure}
            state.stage = .prepared
            _ = try journal.save(id:value.id,payload:Self.encode(state),expectedRevision:reserved.revision)
            return state
        }catch {
            // No native effect exists at this stage. If cancellation cannot
            // persist in all copies, retain the reservation for explicit repair.
            try? cancel(id:value.id,reason:.changedBeforeEffects)
            throw error
        }
    }
    func state(id:String)throws->CodexSessionMigrationState? {
        guard let loaded=try journal.load(id:id) else{return nil}
        guard loaded.consistent else{throw Self.failure};return try Self.decode(loaded.record)
    }
    func cancel(id:String)throws {
        guard let parsed=UUID(uuidString:id) else{throw Self.failure}
        let canonical=parsed.uuidString.lowercased()
        if preparing {
            guard preparingID==canonical else{throw Self.failure}
            // Accept cancellation even if the observer ignores cancellation.
            // Before reservation there is nothing to release or create.
            preparationCancelled=true
            if try journal.load(id:canonical)==nil {return}
        }
        try cancel(id:canonical,reason:.requested)
    }
    private func cancel(id:String,reason:CodexSessionMigrationState.Cancellation)throws {
        let record=try journal.repair(id:id)
        var state=try Self.decode(record)
        // A lost native reply can hide a completed shutdown or publication.
        // Preparation-only cancellation cannot safely release such a move.
        guard state.execution==nil else{throw Self.failure}
        if state.stage == .cancelled {try journal.release(id:id);return}
        state.stage = .cancelled;state.cancellation=reason
        _ = try journal.save(id:id,payload:Self.encode(state),expectedRevision:record.revision,terminal:true)
        try journal.release(id:id)
    }
}
