import Foundation

/// One utility-task owner. The lease drains and pauses input admission for an
/// exact scope. It does not stop accepted work or establish migration ownership.
final class CodexNativeSelectedInputLease {
    enum Operation:String {case inspect,pause,status,renew,release}
    struct Reply:Decodable {
        let schemaVersion:Int,producer:String,pid:UInt32,nonce:String,serverGeneration:String
        let scope:String,threadIds:[String],leaseId:String?,inputAdmissionPaused:Bool,leaseTTLMillis:UInt32
        let membershipComplete:Bool,existingWorkStopped:Bool,goalLifecycleManaged:Bool,credentialsTouched:Bool,migrationAuthorized:Bool
    }
    private struct Request:Encodable {
        let op:String,nonce:String,serverGeneration:String?,leaseId:String?,threadIds:[String]?
    }
    private let connection:CodexNativeLineConnection
    private let threadIDs:[String]
    private var generation:String?
    private var leaseID:String?
    private var held=false
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
            generation=try call(.inspect).serverGeneration
            leaseID=try call(.pause).leaseId
            held=true
        }catch{connection.close();throw error}
    }
    deinit{connection.close()}
    func close(){held=false;connection.close()}
    func status()throws{guard held else{throw Self.failure};_ = try call(.status)}
    func renew()throws{guard held else{throw Self.failure};_ = try call(.renew)}
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
            guard (1...65_536).contains(data.count),nonce.utf8.count==32,
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
            return reply
        }catch{throw failure}
    }
}
