import Foundation
import CryptoKit
import Darwin

// Coordinates durable preparation, native writer handoff and archive import.
// The engine observes client/server membership and owns terminal reconnection.
// Credentials stay in their selected login homes throughout the move.
struct CodexMigrationAccount:Codable,Equatable,Sendable {
    var provider:String,email:String?,authenticated:Bool
}
struct CodexMigrationEndpoint:Codable,Equatable,Sendable {
    var home:String,physicalHomeID:String,serverID:String,socketID:String
    var cliIdentity:String,cliVersion:String
    var account:CodexMigrationAccount
    static func capture(home:String,runtime:CodexNativeServerRuntime,account:CodexServerAccountIdentity)throws->Self {
        let canonical=try CodexAccountTransitionTarget.canonicalHome(home)
        guard let pointer=realpath(canonical,nil) else{throw AppError.message("로그인 그룹의 홈 폴더를 확인하지 못했습니다.")}
        defer{free(pointer)}
        let path=String(cString:pointer);var info=stat()
        guard lstat(path,&info)==0,info.st_mode&S_IFMT==S_IFDIR,info.st_uid==getuid(),
              runtime.peer.pid>0,runtime.peer.effectiveUid==getuid(),!runtime.serverGeneration.isEmpty,
              runtime.executable.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:runtime.executable) else {
            throw AppError.message("로그인 그룹의 실제 홈·Codex 서버를 확인하지 못했습니다.")
        }
        return .init(home:path,physicalHomeID:"\(info.st_dev):\(info.st_ino)",
            serverID:"\(runtime.peer.pid):\(runtime.serverGeneration)",socketID:runtime.controlSocket,
            cliIdentity:runtime.executable,cliVersion:runtime.cliVersion,
            account:.init(provider:account.provider,email:account.email,authenticated:account.authenticated))
    }
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
    static func captureScope(connection:CodexQueueConnection,home:String,rootIDs:[String])throws->[Self] {
        let roots=try CodexNativeSelectedInputLease.checkedScope(rootIDs)
        var ids=Set(roots)
        for root in roots {
            var cursor:String?,seen=Set<String>()
            repeat {
                try Task.checkCancellation()
                var params:JSONObject=["ancestorThreadId":root,"archived":false,"limit":100,"useStateDbOnly":true]
                if let cursor{params["cursor"]=cursor}
                // Migration requires the stored relation filter. A loaded-only
                // fallback could silently omit a dormant child and its Goal.
                let page=try connection.request("thread/list",params,classifyError:true)
                guard let rows=page["data"] as? [JSONObject],rows.count<=100 else {
                    throw AppError.message("이동할 서브에이전트 목록을 확인하지 못했습니다.")
                }
                for row in rows {
                    guard let id=row["id"] as? String,UUID(uuidString:id)?.uuidString.lowercased()==id,
                          let parent=row["parentThreadId"] as? String,UUID(uuidString:parent) != nil,parent != id else {
                        throw AppError.message("이동할 서브에이전트의 부모 연결을 확인하지 못했습니다.")
                    }
                    ids.insert(id)
                    guard ids.count<=512 else{throw AppError.message("한 번에 이동할 대화 범위가 너무 큽니다.")}
                }
                cursor=page["nextCursor"] as? String
                guard cursor==nil || seen.insert(cursor!).inserted else {
                    throw AppError.message("이동할 서브에이전트 목록의 페이지가 반복됐습니다.")
                }
            }while cursor != nil
        }
        let threads=try ids.sorted().map{try capture(connection:connection,home:home,id:$0)}
        let byID=Dictionary(uniqueKeysWithValues:threads.map{($0.id,$0)})
        for thread in threads where !roots.contains(thread.id) {
            var current=thread.id,seen=Set<String>()
            while !roots.contains(current) {
                guard seen.insert(current).inserted,let parent=byID[current]?.parentID,byID[parent] != nil else {
                    throw AppError.message("이동할 대화 범위에 연결되지 않은 서브에이전트가 있습니다.")
                }
                current=parent
            }
        }
        return threads
    }
    static func capture(connection:CodexQueueConnection,home:String,id:String)throws->Self {
        let response=try connection.request("thread/read",["threadId":id,"includeTurns":false])
        guard let row=response["thread"] as? JSONObject,row["id"] as? String==id else {
            throw AppError.message("이동할 대화의 저장 상태를 확인하지 못했습니다.")
        }
        let parent=row["parentThreadId"] as? String
        guard row["parentThreadId"]==nil || row["parentThreadId"] is NSNull
                || parent.map({UUID(uuidString:$0) != nil && $0 != id}) == true else {
            throw AppError.message("이동할 대화의 부모 연결을 확인하지 못했습니다.")
        }
        let current:CodexAccountTransitionThread
        if (row["status"] as? JSONObject)?["type"] as? String == "notLoaded" {
            guard row["ephemeral"] as? Bool==false,let cwd=row["cwd"] as? String,cwd.hasPrefix("/"),
                  let provider=row["modelProvider"] as? String,!provider.isEmpty else {
                throw AppError.message("휴면 대화의 저장 설정을 확인하지 못했습니다.")
            }
            current = .init(id:id,active:false,continuable:true,cwd:cwd,modelProvider:provider,
                goal:try CodexSessionAttachment.goalIfPresent(home:home,threadID:id))
        }else {
            current=try CodexAccountTransitionLocal.thread(connection,id:id,metadata:response,home:home,allowSubagent:true)
        }
        guard current.continuable==true else{throw AppError.message("이동할 대화의 저장 이력을 이어갈 수 없습니다.")}
        let settingsKeys=["model","modelProvider","cwd","approvalPolicy","approvalsReviewer","sandbox",
                          "serviceTier","reasoningEffort","disabledPluginIds","runtimeWorkspaceRoots"]
        var settings:JSONObject=[:]
        for key in settingsKeys {if let value=row[key] {settings[key]=value}}
        let settingsData=try JSONSerialization.data(withJSONObject:settings,options:[.sortedKeys,.fragmentsAllowed])
        let configuration=SHA256.hash(data:settingsData).map{String(format:"%02x",$0)}.joined()
        return .init(id:id,home:home,parentID:parent,turnID:current.turnID,
            goalRevision:current.goal.map{$0.instanceID ?? $0.revision},configurationID:configuration,
            resumable:true,active:current.active,goalStatus:current.goal?.status)
    }
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
    enum Stage:String,Codable {case reserved,prepared,cancelled,completed}
    enum Cancellation:String,Codable {case requested,changedBeforeEffects}
    struct Execution:Codable,Equatable {
        enum Phase:String,Codable {case shutdownAttempted,retireAttempted,incomingAttempted,activationAttempted}
        var phase:Phase
        var ownershipRevision:Int?=nil
        var sourceRetirementRevision:Int?=nil
    }
    struct SourceRetirement:Codable,Equatable {
        let ownershipRevision:Int,homeIdentity:String,files:[CodexNativeArchivedFile]
    }
    var formatVersion=1
    var request:CodexSessionMigrationRequest
    var stage:Stage = .prepared
    var cancellation:Cancellation?=nil
    // Verified owners at preparation. Once execution exists, recovery must
    // consult native durable policy rather than treating this as current fact.
    var currentOwners:[String:String]
    var execution:Execution?=nil
    var goalSlots:[CodexGoalTransferSlotReference]?=nil
    var sourceRetirement:SourceRetirement?=nil
    var destinationImportObservation:CodexNativeImportObservation?=nil
    var destinationActivation:CodexNativeActivationReceipt?=nil
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
            guard [endpoint.serverID,endpoint.socketID,endpoint.cliIdentity,endpoint.account.provider].allSatisfy({text($0)}),
                  endpoint.account.email.map({text($0)}) ?? true,
                  ["0.166.0","0.167.1"].contains(endpoint.cliVersion) else{throw failure}
        }
        guard source.cliVersion==destination.cliVersion,
              source.home != destination.home,source.physicalHomeID != destination.physicalHomeID,
              source.serverID != destination.serverID,source.socketID != destination.socketID,
              destination.account.authenticated else{throw failure}
    }
    private static func client(_ value:CodexMigrationClient)throws {
        guard value.identity.pid>0,text(value.identity.started,max:256),value.identity.tty.hasPrefix("/dev/"),text(value.identity.tty,max:512),
              value.threadIDs.count<=512,Set(value.threadIDs).count==value.threadIDs.count,
              value.threadIDs.allSatisfy(threadID) else{throw failure}
    }
    private static func request(_ value:CodexSessionMigrationRequest)throws {
        guard UUID(uuidString:value.id)?.uuidString.lowercased()==value.id,
              !value.clients.isEmpty,value.clients.count<=64,!value.threads.isEmpty,value.threads.count<=512,
              Set(value.clients.map(\.identity)).count==value.clients.count,Set(value.clients.map{$0.identity.pid}).count==value.clients.count,
              Set(value.threads.map(\.id)).count==value.threads.count else{throw failure}
        try endpoints(value.source,value.destination)
        for member in value.clients {
            try client(member);guard member.home==value.source.home,!member.threadIDs.isEmpty,!member.blocked else{throw failure}
        }
        let selected=Set(value.clients.flatMap(\.threadIDs))
        let byID=Dictionary(uniqueKeysWithValues:value.threads.map{($0.id,$0)})
        guard selected.isSubset(of:Set(byID.keys)) else{throw failure}
        for thread in value.threads where !selected.contains(thread.id) {
            var current=thread.id,seen=Set<String>()
            while !selected.contains(current) {
                guard seen.insert(current).inserted,let parent=byID[current]?.parentID,byID[parent] != nil else{throw failure}
                current=parent
            }
        }
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
              state.currentOwners==Dictionary(uniqueKeysWithValues:state.request.threads.map{($0.id,state.stage == .completed ? state.request.destination.home:state.request.source.home)}),
              record.terminal==([.cancelled,.completed].contains(state.stage)),
              (state.stage == .cancelled)==(state.cancellation != nil) else{throw failure}
        if state.stage == .completed {
            guard state.destinationActivation != nil,let changes=record.ownership,
                  Set(changes.map(\.threadID))==Set(state.request.threads.map(\.id)),
                  changes.allSatisfy({$0.destination.path==state.request.destination.home
                      && $0.destination.identity==state.request.destination.physicalHomeID}) else{throw failure}
        }
        if let references=state.goalSlots {
            let ids=Set(state.request.threads.map(\.id))
            guard references.count==ids.count,Set(references.map(\.threadID))==ids,
                  references.map(\.threadID)==references.map(\.threadID).sorted() else{throw failure}
            for reference in references {
                try reference.validate(requestID:state.request.id,sourceHome:state.request.source.home,threadIDs:ids)
            }
        }
        if let retirement=state.sourceRetirement {
            let ids=Set(state.request.threads.map(\.id))
            guard let execution=state.execution,execution.phase != .shutdownAttempted,
                  retirement.ownershipRevision>0,retirement.homeIdentity==state.request.source.physicalHomeID,
                  (1...4096).contains(retirement.files.count),
                  Set(retirement.files.map(\.threadId))==ids,
                  Set(retirement.files.map(\.relativePath)).count==retirement.files.count else{throw failure}
            for file in retirement.files {try file.validate(scope:ids)}
            if execution.phase == .incomingAttempted || execution.phase == .activationAttempted {
                guard execution.sourceRetirementRevision==retirement.ownershipRevision else{throw failure}
            }
        }
        if let observation=state.destinationImportObservation {
            guard let execution=state.execution,execution.phase == .incomingAttempted || execution.phase == .activationAttempted,
                  let revision=execution.ownershipRevision,revision>=0,revision<Int.max,
                  let sourceRevision=execution.sourceRetirementRevision,let retirement=state.sourceRetirement,
                  let references=state.goalSlots else{throw failure}
            let ids=Set(state.request.threads.map(\.id))
            let slots=try references.map{try CodexGoalTransferSlotStore.load($0,home:state.request.source.home,
                homeIdentity:state.request.source.physicalHomeID,requestID:state.request.id,threadIDs:ids)}
            try observation.validate(requestID:state.request.id,home:state.request.destination.physicalHomeID,
                revision:execution.phase == .incomingAttempted ? revision+1:revision,sourceRevision:sourceRevision,slots:slots)
            guard retirement.ownershipRevision==sourceRevision else{throw failure}
        }
        if let activation=state.destinationActivation {
            guard let execution=state.execution,execution.phase == .activationAttempted,
                  state.destinationImportObservation != nil,
                  let revision=execution.ownershipRevision,revision<Int.max else{throw failure}
            try activation.validate(requestID:state.request.id,threadIDs:state.request.threads.map(\.id),
                revision:revision+1,home:state.request.destination.physicalHomeID)
        }
        if let execution=state.execution {
            guard [.prepared,.completed].contains(state.stage),state.goalSlots != nil,
                  execution.phase == .retireAttempted ? ((execution.ownershipRevision.map{$0>=0} ?? false) && execution.sourceRetirementRevision==nil):
                  execution.phase == .incomingAttempted || execution.phase == .activationAttempted ? ((execution.ownershipRevision.map{$0>=0} ?? false) && (execution.sourceRetirementRevision.map{$0>0} ?? false)):
                    (execution.ownershipRevision==nil && execution.sourceRetirementRevision==nil) else{throw failure}
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
            state.goalSlots=try CodexGoalTransferSlotStore.capture(home:value.source.home,
                homeIdentity:value.source.physicalHomeID,requestID:value.id,threadIDs:value.threads.map(\.id))
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
    func activeStates()throws->[CodexSessionMigrationState] {
        try journal.activeRecords().map { record in
            guard let loaded=try journal.load(id:record.id),loaded.consistent else{throw Self.failure}
            return try Self.decode(loaded.record)
        }
    }
    /// Execute one prepared move. Recovery observes the recorded phase instead
    /// of calling this entry point again after an uncertain native response.
    func executePrepared(id:String,source:CodexNativeServerRuntime,destination:CodexNativeServerRuntime,
                         sourceLease:CodexNativeSelectedInputLease,destinationLease:CodexNativeSelectedInputLease,
                         clientHolds:[CodexNativeTerminalInputHold]=[]) async throws->CodexSessionMigrationState {
        guard let prepared=try state(id:id),prepared.stage == .prepared,prepared.execution==nil,
              prepared.request.source.serverID=="\(source.peer.pid):\(source.serverGeneration)",
              prepared.request.destination.serverID=="\(destination.peer.pid):\(destination.serverGeneration)",
              prepared.request.source.socketID==source.controlSocket,
              prepared.request.destination.socketID==destination.controlSocket else{throw Self.failure}
        defer{sourceLease.close();destinationLease.close()}
        var shutdown=try await beginSelectedShutdown(id:id,lease:sourceLease)
        while shutdown.state=="pending" {
            try Task.checkCancellation()
            for hold in clientHolds{try hold.renew()}
            try sourceLease.renew();try destinationLease.renew()
            try await Task.sleep(for:.seconds(1))
            shutdown=try sourceLease.shutdownStatus()
        }
        guard shutdown.state=="stopped" else{throw Self.failure}
        for hold in clientHolds{try hold.renew()}
        let ids=prepared.request.threads.map(\.id)
        func ownership(_ runtime:CodexNativeServerRuntime)throws->CodexNativeOwnershipObservation {
            try CodexNativeSelectedInputLease.observeOwnership(path:runtime.controlSocket,
                expectedServerPeer:runtime.peer,threadIDs:ids)
        }
        _=try retireSelectedSource(id:id,lease:sourceLease,ownership:ownership(source))
        try destinationLease.renew()
        _=try acceptSelectedIncoming(id:id,lease:destinationLease,ownership:ownership(destination))
        for hold in clientHolds{try hold.renew()}
        var nextRenewal=Date.distantPast
        _=try activateImportedSessions(id:id,lease:destinationLease,checkpoint:{
            guard Date()>=nextRenewal else{return}
            for hold in clientHolds{try hold.renew()}
            try sourceLease.renew();try destinationLease.renew()
            nextRenewal=Date().addingTimeInterval(5)
        })
        return try complete(id:id,source:ownership(source),destination:ownership(destination))
    }
    /// Connect the prepared journal to the held source lease before stopping
    /// its selected runtimes. A saved attempt is never submitted a second time.
    func beginSelectedShutdown(id:String,lease:CodexNativeSelectedInputLease) async throws->CodexNativeSelectedShutdown {
        guard let initial=try journal.load(id:id),initial.consistent else{throw Self.failure}
        let state=try Self.decode(initial.record)
        guard state.stage == .prepared,state.execution==nil else{throw Self.failure}
        try Self.validate(try await services.observe(state.request),for:state.request)
        try Task.checkCancellation()
        guard let current=try journal.load(id:id),current.consistent,current.record==initial.record else{throw Self.failure}
        let descriptor=try journal.duplicateLockDescriptor(id:id,home:state.request.source.home,
            expectedRevision:current.record.revision)
        let lock=try lease.borrowJournalLock(descriptor)
        guard lock.role=="source" else{lease.close();throw Self.failure}
        let cohort=try lease.cohort()
        guard cohort.readyForWriterShutdown,cohort.threads.map(\.threadId)==state.request.threads.map(\.id).sorted() else {
            lease.close()
            throw AppError.message("이동할 대화와 서브에이전트의 Goal·작업·대기 입력을 먼저 정리해주세요.")
        }
        _=try recordExecutionAttempt(id:id,phase:.shutdownAttempted)
        guard let reserved=try journal.load(id:id),reserved.consistent else{lease.close();throw Self.failure}
        try lease.synchronizeJournal(reserved.record)
        return try lease.beginShutdown()
    }
    func retireSelectedSource(id:String,lease:CodexNativeSelectedInputLease,
                              ownership:CodexNativeOwnershipObservation)throws->CodexSessionMigrationState {
        guard let state=try state(id:id),state.stage == .prepared,
              state.execution?.phase == .shutdownAttempted,state.sourceRetirement==nil else{throw Self.failure}
        let ids=state.request.threads.map(\.id)
        try ownership.validate(threadIDs:ids)
        guard ownership.homeIdentity==state.request.source.physicalHomeID,
              ownership.threads.allSatisfy({$0.phase==nil || $0.phase=="active"}),
              try lease.shutdownStatus().state=="stopped" else{throw Self.failure}
        _=try recordExecutionAttempt(id:id,phase:.retireAttempted,ownershipRevision:ownership.ownershipRevision)
        guard let reserved=try journal.load(id:id),reserved.consistent else{lease.close();throw Self.failure}
        try lease.synchronizeJournal(reserved.record)
        _=try lease.prepareRetirement(expectedOwnershipRevision:ownership.ownershipRevision)
        let receipt=try lease.commitRetirement()
        return try recordSourceRetirement(receipt,id:id)
    }
    func acceptSelectedIncoming(id:String,lease:CodexNativeSelectedInputLease,
                                ownership:CodexNativeOwnershipObservation)throws->CodexNativeIncomingReceipt {
        guard let state=try state(id:id),state.stage == .prepared,
              state.execution?.phase == .retireAttempted,let retirement=state.sourceRetirement else{throw Self.failure}
        try ownership.validate(threadIDs:state.request.threads.map(\.id))
        guard ownership.homeIdentity==state.request.destination.physicalHomeID,
              ownership.threads.allSatisfy({$0.phase==nil || $0.phase=="retired"}) else{throw Self.failure}
        _=try recordExecutionAttempt(id:id,phase:.incomingAttempted,ownershipRevision:ownership.ownershipRevision,
            sourceRetirementRevision:retirement.ownershipRevision)
        guard let reserved=try journal.load(id:id),reserved.consistent else{lease.close();throw Self.failure}
        let descriptor=try journal.duplicateLockDescriptor(id:id,home:state.request.destination.home,
            expectedRevision:reserved.record.revision)
        let lock=try lease.borrowJournalLock(descriptor)
        guard lock.role=="destination" else{lease.close();throw Self.failure}
        _=try lease.prepareIncoming(expectedOwnershipRevision:ownership.ownershipRevision,
            sourceRetirementRevision:retirement.ownershipRevision)
        return try lease.commitIncoming()
    }
    /// Finish only from fresh durable observations of both homes. Activation's
    /// reply alone cannot establish that the source still belongs to this move.
    @discardableResult func complete(id:String,source:CodexNativeOwnershipObservation,
                                     destination:CodexNativeOwnershipObservation)throws->CodexSessionMigrationState {
        guard let initial=try journal.load(id:id) else{throw Self.failure}
        // A successful central commit can lose its reply or stop before both
        // mirrors are written. Repair that same terminal record, never publish
        // a second ownership change on recovery.
        let record:CodexMigrationJournalRecord
        if initial.record.terminal {record=try journal.repair(id:id)}
        else {guard initial.consistent else{throw Self.failure};record=initial.record}
        var state=try Self.decode(record)
        if state.stage == .completed {
            try journal.release(id:id)
            return state
        }
        guard state.stage == .prepared,let retirement=state.sourceRetirement,
              let activation=state.destinationActivation else{throw Self.failure}
        let ids=state.request.threads.map(\.id)
        try source.validate(threadIDs:ids);try destination.validate(threadIDs:ids)
        let target=CodexMigrationJournalRecord.Home(path:state.request.destination.home,
            identity:state.request.destination.physicalHomeID)
        guard source.homeIdentity==state.request.source.physicalHomeID,
              source.ownershipRevision==retirement.ownershipRevision,
              destination.homeIdentity==target.identity,destination.ownershipRevision==activation.ownershipRevision,
              source.threads.allSatisfy({$0.phase=="retired" && $0.requestId==state.request.id && $0.ownerHomeIdentity==target.identity}),
              destination.threads.allSatisfy({$0.phase=="active" && $0.requestId==state.request.id && $0.ownerHomeIdentity==target.identity}) else{throw Self.failure}
        guard let references=state.goalSlots else{throw Self.failure}
        let changes=try ids.sorted().map { threadID -> CodexMigrationOwnerChange in
            let previous=try journal.owner(threadID:threadID)
            guard previous.map({$0.home.path==state.request.source.home
                && $0.home.identity==state.request.source.physicalHomeID}) ?? true else{throw Self.failure}
            let files=retirement.files.filter{$0.threadId==threadID}
            guard files.count==1,let file=files.first,
                  let reference=references.first(where:{$0.threadID==threadID}) else{throw Self.failure}
            let slot=try CodexGoalTransferSlotStore.load(reference,home:state.request.source.home,
                homeIdentity:state.request.source.physicalHomeID,requestID:state.request.id,threadIDs:Set(ids))
            let backup=CodexMigrationRetirement(formatVersion:1,goal:slot,rollout:file.witness)
            return .init(threadID:threadID,previous:previous,destination:target,retirement:backup)
        }
        state.stage = .completed
        state.currentOwners=Dictionary(uniqueKeysWithValues:ids.map{($0,target.path)})
        let saved=try journal.complete(id:id,payload:Self.encode(state),expectedRevision:record.revision,ownership:changes)
        let result=try Self.decode(saved)
        try journal.release(id:id)
        return result
    }
    @discardableResult func recordDestinationImportObservation(
        _ observation:CodexNativeImportObservation,id:String,ownershipRevision:Int,sourceRetirementRevision:Int
    )throws->CodexSessionMigrationState {
        guard let parsed=UUID(uuidString:id) else{throw Self.failure}
        let canonical=parsed.uuidString.lowercased()
        guard canonical==id,let loaded=try journal.load(id:canonical),loaded.consistent else{throw Self.failure}
        var state=try Self.decode(loaded.record)
        guard state.stage == .prepared,state.destinationImportObservation==nil,
              let execution=state.execution,execution.phase == .incomingAttempted,
              execution.ownershipRevision.map({$0<Int.max && $0+1==ownershipRevision}) == true,
              execution.sourceRetirementRevision==sourceRetirementRevision,
              let retirement=state.sourceRetirement,retirement.ownershipRevision==sourceRetirementRevision,
              let references=state.goalSlots else{throw Self.failure}
        let ids=Set(state.request.threads.map(\.id))
        let slots=try references.map{try CodexGoalTransferSlotStore.load($0,home:state.request.source.home,
            homeIdentity:state.request.source.physicalHomeID,requestID:canonical,threadIDs:ids)}
        try observation.validate(requestID:canonical,home:state.request.destination.physicalHomeID,
            revision:ownershipRevision,sourceRevision:sourceRetirementRevision,slots:slots)
        state.destinationImportObservation=observation
        let saved=try journal.save(id:canonical,payload:Self.encode(state),expectedRevision:loaded.record.revision)
        guard let confirmed=try journal.load(id:canonical),confirmed.consistent,confirmed.record==saved else{throw Self.failure}
        return try Self.decode(confirmed.record)
    }
    @discardableResult func recordDestinationActivation(
        _ receipt:CodexNativeActivationReceipt,id:String
    )throws->CodexSessionMigrationState {
        guard let parsed=UUID(uuidString:id) else{throw Self.failure}
        let canonical=parsed.uuidString.lowercased()
        guard canonical==id,let loaded=try journal.load(id:canonical),loaded.consistent else{throw Self.failure}
        var state=try Self.decode(loaded.record)
        guard state.stage == .prepared,state.destinationActivation==nil,
              let execution=state.execution,execution.phase == .activationAttempted,
              let revision=execution.ownershipRevision,revision<Int.max,
              state.destinationImportObservation != nil else{throw Self.failure}
        try receipt.validate(requestID:canonical,threadIDs:state.request.threads.map(\.id),
            revision:revision+1,home:state.request.destination.physicalHomeID)
        state.destinationActivation=receipt
        let saved=try journal.save(id:canonical,payload:Self.encode(state),expectedRevision:loaded.record.revision)
        guard let confirmed=try journal.load(id:canonical),confirmed.consistent,confirmed.record==saved else{throw Self.failure}
        return try Self.decode(confirmed.record)
    }
    @discardableResult func activateImportedSessions(id:String,lease:CodexNativeSelectedInputLease,checkpoint:()throws->Void={})throws->CodexSessionMigrationState {
        guard let state=try state(id:id),state.stage == .prepared,
              let execution=state.execution,execution.phase == .incomingAttempted,
              let expectedRevision=execution.ownershipRevision,expectedRevision<Int.max,
              let sourceRevision=execution.sourceRetirementRevision,
              let references=state.goalSlots else{throw Self.failure}
        let ownershipRevision=expectedRevision+1
        let ids=Set(state.request.threads.map(\.id))
        let slots=try references.map{try CodexGoalTransferSlotStore.load($0,home:state.request.source.home,
            homeIdentity:state.request.source.physicalHomeID,requestID:state.request.id,threadIDs:ids)}
        guard let files=state.sourceRetirement?.files else{throw Self.failure}
        _=try CodexNativeSelectedArchiveImport.install(requestID:id,
            sourceHome:state.request.source.home,sourceHomeIdentity:state.request.source.physicalHomeID,
            destinationHome:state.request.destination.home,destinationHomeIdentity:state.request.destination.physicalHomeID,
            files:files,goalSlots:references,threadIDs:state.request.threads.map(\.id),checkpoint:checkpoint)
        let observation=try lease.verifyIncoming(slots:slots,ownershipRevision:ownershipRevision,
            sourceRetirementRevision:sourceRevision)
        _=try recordDestinationImportObservation(observation,id:id,ownershipRevision:ownershipRevision,
            sourceRetirementRevision:sourceRevision)
        guard let imported=try journal.load(id:id),imported.consistent else{throw Self.failure}
        try lease.synchronizeJournal(imported.record)
        _=try recordExecutionAttempt(id:id,phase:.activationAttempted,ownershipRevision:ownershipRevision,
            sourceRetirementRevision:sourceRevision)
        guard let activating=try journal.load(id:id),activating.consistent else{throw Self.failure}
        try lease.synchronizeJournal(activating.record)
        let receipt=try lease.activateIncoming()
        return try recordDestinationActivation(receipt,id:id)
    }
    /// Persist each irreversible native step before issuing it. A lost save
    /// reply is resolved by reading the journal; the same transition is never
    /// resubmitted from this API.
    @discardableResult func recordExecutionAttempt(
        id:String,
        phase:CodexSessionMigrationState.Execution.Phase,
        ownershipRevision:Int?=nil,
        sourceRetirementRevision:Int?=nil
    )throws->CodexSessionMigrationState {
        guard let parsed=UUID(uuidString:id) else{throw Self.failure}
        let canonical=parsed.uuidString.lowercased()
        guard canonical==id,let loaded=try journal.load(id:canonical),loaded.consistent else{throw Self.failure}
        var state=try Self.decode(loaded.record)
        guard state.stage == .prepared else{throw Self.failure}
        let next=CodexSessionMigrationState.Execution(phase:phase,ownershipRevision:ownershipRevision,
            sourceRetirementRevision:sourceRetirementRevision)
        let allowed:Bool
        switch (state.execution?.phase,phase) {
        case (nil,.shutdownAttempted):allowed=true
        case (.shutdownAttempted?,.retireAttempted):allowed=true
        case (.retireAttempted?,.incomingAttempted):
            allowed=state.sourceRetirement?.ownershipRevision==sourceRetirementRevision
        case (.incomingAttempted?,.activationAttempted):
            allowed=state.sourceRetirement?.ownershipRevision==sourceRetirementRevision && state.destinationImportObservation != nil
        default:allowed=false
        }
        guard allowed,
              phase == .shutdownAttempted ? (ownershipRevision==nil && sourceRetirementRevision==nil):
                phase == .retireAttempted ? ((ownershipRevision.map{$0>=0} ?? false) && sourceRetirementRevision==nil):
                ((ownershipRevision.map{$0>=0} ?? false) && (sourceRetirementRevision.map{$0>0} ?? false)) else{throw Self.failure}
        guard let references=state.goalSlots else{throw Self.failure}
        let ids=Set(state.request.threads.map(\.id))
        for reference in references {
            _=try CodexGoalTransferSlotStore.load(reference,home:state.request.source.home,
                homeIdentity:state.request.source.physicalHomeID,requestID:state.request.id,threadIDs:ids)
        }
        state.execution=next
        let saved=try journal.save(id:canonical,payload:Self.encode(state),expectedRevision:loaded.record.revision)
        guard let confirmed=try journal.load(id:canonical),confirmed.consistent,
              confirmed.record==saved else{throw Self.failure}
        return try Self.decode(confirmed.record)
    }
    @discardableResult func recordSourceRetirement(_ receipt:CodexNativeRetirementReceipt,id:String)throws->CodexSessionMigrationState {
        guard let parsed=UUID(uuidString:id) else{throw Self.failure}
        let canonical=parsed.uuidString.lowercased()
        guard canonical==id,let loaded=try journal.load(id:canonical),loaded.consistent else{throw Self.failure}
        var state=try Self.decode(loaded.record)
        guard state.stage == .prepared,state.sourceRetirement==nil,
              let execution=state.execution,execution.phase == .retireAttempted,
              let expected=execution.ownershipRevision,expected<Int.max,let files=receipt.files else{throw Self.failure}
        try receipt.validate(requestID:canonical,threadIDs:state.request.threads.map(\.id),phase:"retired",
            revision:expected+1,homeIdentity:state.request.source.physicalHomeID)
        guard !files.isEmpty else{throw Self.failure}
        state.sourceRetirement = .init(ownershipRevision:receipt.ownershipRevision,
            homeIdentity:state.request.source.physicalHomeID,files:files)
        let saved=try journal.save(id:canonical,payload:Self.encode(state),expectedRevision:loaded.record.revision)
        guard let confirmed=try journal.load(id:canonical),confirmed.consistent,confirmed.record==saved else{throw Self.failure}
        return try Self.decode(confirmed.record)
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
