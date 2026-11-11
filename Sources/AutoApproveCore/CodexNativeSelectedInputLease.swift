import Foundation

/// Native execution preflight for a held input scope. This deliberately does
/// not claim a complete client census, writer retirement or move authority.
struct CodexNativeRuntimeCohort:Decodable,Sendable {
    struct Thread:Decodable,Sendable {
        let threadId:String,status:String
        let loaded:Bool,hasActiveTurn:Bool,persistent:Bool,hasBackgroundTerminal:Bool
        let hasProtectedRequest:Bool,hasQueuedInput:Bool,readyForWriterShutdown:Bool
        let goal:CodexGoal?
        let goalId:String?
    }
    let producer:String,schemaVersion:Int
    let threads:[Thread],missingThreadIds:[String]
    let knownSubtreeCovered:Bool,readyForWriterShutdown:Bool,inputScopeVerified:Bool
    let membershipComplete:Bool,writersStopped:Bool,migrationAuthorized:Bool

    func validate(threadIDs:[String])throws {
        let scope=try CodexNativeSelectedInputLease.checkedScope(threadIDs)
        let failure=AppError.message("이동 대상의 실행·Goal·대기 입력 상태를 확인하지 못했습니다.")
        guard schemaVersion==1,producer=="autoapprove-selected-runtime-cohort",inputScopeVerified,
              !membershipComplete,!writersStopped,!migrationAuthorized,
              threads.map(\.threadId)==scope,missingThreadIds.count<=4096,
              Set(missingThreadIds).count==missingThreadIds.count,missingThreadIds==missingThreadIds.sorted(),
              missingThreadIds.allSatisfy({UUID(uuidString:$0)?.uuidString.lowercased()==$0}),
              Set(missingThreadIds).isDisjoint(with:scope),knownSubtreeCovered==missingThreadIds.isEmpty else{throw failure}
        for thread in threads {
            guard ["pending-init","running","interrupted","completed","errored","shutdown","not-found","not-loaded"].contains(thread.status),
                  thread.loaded || (thread.status=="not-loaded" && !thread.hasActiveTurn && !thread.hasBackgroundTerminal),
                  (thread.goal==nil)==(thread.goalId==nil) else{throw failure}
            if let goal=thread.goal,let id=thread.goalId {
                guard UUID(uuidString:id)?.uuidString.lowercased()==id,goal.threadId==thread.threadId,
                      !goal.objective.isEmpty,goal.objective.utf8.count<=256_000,
                      goal.tokensUsed>=0,goal.timeUsedSeconds>=0,goal.createdAt>=0,goal.updatedAt>=goal.createdAt,
                      goal.tokenBudget.map({$0>=0}) ?? true,goal.instanceID==nil || goal.instanceID==id else{throw failure}
            }
            let ready=thread.persistent && !thread.hasActiveTurn && !thread.hasBackgroundTerminal
                && !thread.hasProtectedRequest && !thread.hasQueuedInput && thread.goal?.status != .active
            guard thread.readyForWriterShutdown==ready else{throw failure}
        }
        guard readyForWriterShutdown==(knownSubtreeCovered && threads.allSatisfy(\.readyForWriterShutdown)) else{throw failure}
    }
}

/// One utility-task owner. The lease drains and pauses input admission for an
/// exact scope. It does not stop accepted work or establish migration ownership.
final class CodexNativeSelectedInputLease {
    enum Operation:String {case inspect,pause,status,renew,release,cohort}
    struct Reply:Decodable {
        let schemaVersion:Int,producer:String,pid:UInt32,nonce:String,serverGeneration:String
        let scope:String,threadIds:[String],leaseId:String?,inputAdmissionPaused:Bool,leaseTTLMillis:UInt32
        let membershipComplete:Bool,existingWorkStopped:Bool,goalLifecycleManaged:Bool,credentialsTouched:Bool,migrationAuthorized:Bool
        let runtimeCohortSupported:Bool?
        let runtimeCohort:CodexNativeRuntimeCohort?
    }
    private struct Request:Encodable {
        let op:String,nonce:String,serverGeneration:String?,leaseId:String?,threadIds:[String]?
    }
    private let connection:CodexNativeLineConnection
    private let threadIDs:[String]
    private var generation:String?
    private var leaseID:String?
    private var held=false
    private var cohortSupported=false
    private static var failure:AppError {.message("선택한 대화의 서버 입력 차단을 확인하지 못했습니다. 이동을 진행하지 않습니다.")}
    static func checkedScope(_ ids:[String])throws->[String] {
        guard (1...512).contains(ids.count),Set(ids).count==ids.count,
              ids.allSatisfy({UUID(uuidString:$0)?.uuidString.lowercased()==$0}) else{throw failure}
        return ids.sorted()
    }
    init(path:String,expected:CodexNativeDisplayedConnection,threadIDs:[String])throws {
        self.threadIDs=try Self.checkedScope(threadIDs)
        connection=try CodexNativeLineConnection(path:path)
        do {
            guard connection.peer.identity==expected.serverPeer else{throw Self.failure}
            let inspected=try call(.inspect)
            generation=inspected.serverGeneration
            cohortSupported=inspected.runtimeCohortSupported==true
            leaseID=try call(.pause).leaseId
            held=true
        }catch{connection.close();throw error}
    }
    deinit{connection.close()}
    func close(){held=false;connection.close()}
    func status()throws{guard held else{throw Self.failure};_ = try call(.status)}
    func renew()throws{guard held else{throw Self.failure};_ = try call(.renew)}
    func cohort()throws->CodexNativeRuntimeCohort {
        guard held,cohortSupported else{close();throw Self.failure}
        guard let value=try call(.cohort).runtimeCohort else{close();throw Self.failure}
        return value
    }
    func release()throws {
        guard held else{throw Self.failure}
        defer{close()}
        _ = try call(.release)
    }
    private func call(_ operation:Operation)throws->Reply {
        do {
            let nonce=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
            let request=Request(op:operation.rawValue,nonce:nonce,serverGeneration:generation,
                                leaseId:leaseID,threadIds:operation == .pause ? threadIDs:nil)
            let data=try connection.exchange(JSONEncoder().encode(request))
            return try Self.validate(data,operation:operation,nonce:nonce,peer:connection.peer.identity,
                                     generation:generation,leaseID:leaseID,threadIDs:threadIDs)
        }catch{close();throw error}
    }
    static func validate(_ data:Data,operation:Operation,nonce:String,peer:CodexNativePeerIdentity,
                         generation:String?,leaseID:String?,threadIDs:[String])throws->Reply {
        do {
            let scope=try checkedScope(threadIDs)
            guard (1...(operation == .cohort ? 1_048_576:65_536)).contains(data.count),nonce.utf8.count==32,
                  nonce.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{throw failure}
            let reply=try JSONDecoder().decode(Reply.self,from:data)
            let paused=operation != .inspect && operation != .release
            guard reply.schemaVersion==1,reply.producer=="autoapprove-selected-input-lease",
                  reply.pid==peer.pid,reply.nonce==nonce,reply.scope=="selected-thread-input",
                  UUID(uuidString:reply.serverGeneration)?.uuidString.lowercased()==reply.serverGeneration,
                  generation==nil || reply.serverGeneration==generation,
                  reply.threadIds==(operation == .inspect ? []:scope),reply.inputAdmissionPaused==paused,
                  !reply.membershipComplete,!reply.existingWorkStopped,!reply.goalLifecycleManaged,
                  !reply.credentialsTouched,!reply.migrationAuthorized,
                  paused ? (1...30_000).contains(reply.leaseTTLMillis):reply.leaseTTLMillis==0 else{throw failure}
            if operation == .inspect {
                guard generation==nil,leaseID==nil,reply.leaseId==nil else{throw failure}
            }else {
                guard generation != nil,let id=reply.leaseId,UUID(uuidString:id)?.uuidString.lowercased()==id,
                      operation == .pause ? leaseID==nil:id==leaseID else{throw failure}
            }
            if operation == .cohort {
                guard let cohort=reply.runtimeCohort else{throw failure}
                try cohort.validate(threadIDs:scope)
            }else {guard reply.runtimeCohort==nil else{throw failure}}
            return reply
        }catch{throw failure}
    }
}
