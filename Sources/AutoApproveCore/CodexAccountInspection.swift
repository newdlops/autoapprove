import Foundation
import Darwin

/// Observation only. This value never authorizes a reconnect or account change.
public struct CodexAccountInspection:Sendable {
    public enum Comparison:String,Sendable {case same,different,signedOut,unverified}
    public let home:String
    public let identity:CodexServerAccountIdentity?
    public let comparison:Comparison
    public let connectedSessions:Int
    public let observedAt:Date
    public let detail:String
    public init(home:String,identity:CodexServerAccountIdentity?=nil,comparison:Comparison,
                connectedSessions:Int,observedAt:Date=Date(),detail:String?=nil) {
        self.home=home;self.identity=identity;self.comparison=comparison;self.connectedSessions=connectedSessions;self.observedAt=observedAt
        self.detail=detail ?? Self.message(comparison)
    }
    private static func message(_ value:Comparison)->String {
        switch value {
        case .same:return "저장된 로그인과 연결 서버의 계정이 같습니다."
        case .different:return "저장된 로그인과 연결 서버의 계정이 다릅니다. 적용하려면 재연결을 선택하세요."
        case .signedOut:return "저장된 로그인과 연결 서버에서 로그인된 계정을 확인하지 못했습니다."
        case .unverified:return "계정 비교를 완료하지 못했습니다. 기존 작업을 유지하고 다시 확인해주세요."
        }
    }
    /// Private local IPC/CLI output, never part of the public LAN inventory.
    public var json:JSONObject {
        var result:JSONObject=["home":home,"comparison":comparison.rawValue,"connectedSessions":connectedSessions,
            "observedAt":ISO8601DateFormatter().string(from:observedAt),"detail":detail,"identity":NSNull()]
        if let identity {
            var value:JSONObject=["provider":identity.provider,"authenticated":identity.authenticated]
            if let email=identity.email {value["email"]=email};if let plan=identity.plan {value["plan"]=plan}
            result["identity"]=value
        }
        return result
    }
}
public struct CodexAccountInspectionServices:Sendable {
    public var read:@Sendable(CodexAccountTransitionTarget) async throws ->CodexAccountInspection
    public init(read:@escaping @Sendable(CodexAccountTransitionTarget) async throws ->CodexAccountInspection){self.read=read}
    public static var inactive:Self {.init(read:{_ in throw AppError.message("이 실행의 읽기 전용 계정 조회 연결을 확인해주세요.")})}
    public static var live:Self {.init(read:{target in
        let task=Task.detached(priority:.utility){try localRead(target)}
        return try await withTaskCancellationHandler(operation:{let result=try await task.value;try Task.checkCancellation();return result},onCancel:{task.cancel()})
    })}
    private static func localRead(_ target:CodexAccountTransitionTarget) throws ->CodexAccountInspection {
        try Task.checkCancellation()
        let rows:[ProcessRecord]
        if target.executable=="codex" {rows=try ProcessDiscovery.read()}
        else {rows=target.witnesses.prefix(50).flatMap{(try? ProcessDiscovery.read(pid:$0.pid)) ?? []}}
        guard let context=try CodexCLIContext.resolve(home:target.home,userHome:NSHomeDirectory(),
            executable:target.executable=="codex" ? nil:target.executable,records:rows) else{
            return .init(home:target.home,comparison:.unverified,connectedSessions:target.witnesses.count,detail:"Codex CLI를 찾지 못했습니다. 로그인 확인은 기존 작업을 변경하지 않았습니다.")
        }
        var current=target;current.executable=context.executable
        let saved:String?,savedRead:Bool
        do {saved=try CodexAccountMetadataProcess.read(current,environment:context.environment);savedRead=true}
        catch is CancellationError {throw CancellationError()}
        catch {saved=nil;savedRead=false}
        try Task.checkCancellation()
        do {
            guard let socket=CodexQueueConnection.socketPath(home:target.home) else{throw AppError.message("No connected server")}
            var before=stat()
            guard lstat(socket,&before)==0 else{throw AppError.message("No socket identity")}
            let connection=try CodexQueueConnection(home:target.home)
            let peer=try connection.peerProcessID()
            let server=try CodexAccountTransitionLocal.account(connection.request("accountSession/list",["refreshWorkspaceMetadata":false]))
            let identity=try CodexServerAccountIdentity.decode(connection.request("account/read",["refreshToken":false]))
            try Task.checkCancellation()
            let afterAccount=try CodexAccountTransitionLocal.account(connection.request("accountSession/list",["refreshWorkspaceMetadata":false]))
            var after=stat()
            guard server==afterAccount,try connection.peerProcessID()==peer,
                  CodexQueueConnection.socketPath(home:target.home)==socket,lstat(socket,&after)==0,
                  before.st_dev==after.st_dev,before.st_ino==after.st_ino else{throw AppError.message("Account observation changed")}
            let comparison:CodexAccountInspection.Comparison
            if !identity.authenticated,savedRead {comparison=saved==nil ? .signedOut:.different}
            else if savedRead,let saved,let server {comparison=saved==server ? .same:.different}
            else {comparison = .unverified}
            try Task.checkCancellation()
            return .init(home:target.home,identity:identity,comparison:comparison,connectedSessions:target.witnesses.count)
        } catch is CancellationError {throw CancellationError()}
        catch {return .init(home:target.home,comparison:.unverified,connectedSessions:target.witnesses.count,
            detail:savedRead && saved != nil ? "저장된 로그인은 확인했지만 연결 서버의 계정은 확인하지 못했습니다.":"저장된 로그인과 연결 서버의 계정 비교를 완료하지 못했습니다.")}
    }
}

