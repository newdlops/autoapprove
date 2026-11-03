import Foundation
import Darwin

public struct CodexManagedServerStatus:Codable,Equatable,Sendable {
    public enum Phase:String,Codable,Sendable {case missingCLI,unsupported,stopped,running,unavailable}
    public let phase:Phase
    public let version:String?
    public let detail:String
    public let autoStartEnabled:Bool?
    public var canPrepare:Bool {phase == .stopped || phase == .running && autoStartEnabled == false}
    public init(phase:Phase,version:String?=nil,detail:String,autoStartEnabled:Bool?=nil) {self.phase=phase;self.version=version;self.detail=detail;self.autoStartEnabled=autoStartEnabled}
}

/// Preparation enables automatic daemon use and starts only a missing daemon. It never bootstraps a
/// launch agent, enables remote control, restarts work or changes credentials.
public struct CodexManagedServerServices:Sendable {
    public var inspect:@Sendable(String,[ProcessRecord]) async throws -> CodexManagedServerStatus
    public var prepare:@Sendable(String,[ProcessRecord]) async throws -> CodexManagedServerStatus
    public init(inspect:@escaping @Sendable(String,[ProcessRecord]) async throws -> CodexManagedServerStatus,
                prepare:@escaping @Sendable(String,[ProcessRecord]) async throws -> CodexManagedServerStatus) {
        self.inspect=inspect;self.prepare=prepare
    }
    public static var live:Self {local()}
    public static func local(userHome:String=NSHomeDirectory(),executable:String?=nil)->Self {
        Self(inspect:{home,records in try await background {
            let client=try CodexManagedServerClient(home:home,userHome:userHome,executable:executable,records:records)
            return try client.inspect()
        }},prepare:{home,records in try await background {
            let client=try CodexManagedServerClient(home:home,userHome:userHome,executable:executable,records:records)
            let before=try client.inspect()
            guard before.canPrepare else{return before}
            let enabled=try client.run(["features","enable","daemon_auto_start"])
            guard enabled.status==0,try client.autoStart() else {throw AppError.message("Codex 데몬 자동 시작 설정을 적용하지 못했습니다. 관리 정책과 선택한 홈의 설정 권한을 확인해주세요.")}
            if before.phase == .running {return try client.inspect()}
            try Task.checkCancellation()
            let backup=try client.archiveDanglingSocket()
            var verified=false
            defer {if !verified {backup?.restore()}}
            // A start may race another normal CLI launch; the official start
            // command is idempotent. There is no restart/update fallback.
            let result:CommandResult
            do {result=try client.run(["app-server","daemon","start"],timeout:90)}
            catch is CancellationError {throw CancellationError()}
            catch {return .init(phase:.unavailable,version:before.version,detail:"서버 준비 결과를 확인하지 못했습니다. 같은 요청을 자동으로 반복하지 않습니다. 연결을 다시 확인해주세요.")}
            try Task.checkCancellation()
            let after=try client.inspect()
            if after.phase == .running {backup?.discard();verified=true;return after}
            return .init(phase:.unavailable,version:after.version ?? before.version,detail:result.status==0
                ? "서버 시작 명령은 끝났지만 실행 상태를 확인하지 못했습니다. 연결을 다시 확인해주세요."
                : "관리형 서버를 시작하지 못했습니다. Codex 설치 상태를 확인한 뒤 연결을 다시 확인해주세요.")
        }})
    }
    private static func background<T:Sendable>(_ body:@escaping @Sendable()throws->T) async throws ->T {
        let child=Task.detached(priority:.utility,operation:body)
        return try await withTaskCancellationHandler(operation:{let value=try await child.value;try Task.checkCancellation();return value},onCancel:{child.cancel()})
    }
}

private struct CodexManagedServerClient {
    let home:String,userHome:String
    let context:CodexCLIContext?
    var executable:String? {context?.executable}
    init(home:String,userHome:String,executable:String?,records:[ProcessRecord]) throws {
        let canonicalHome=try CodexAccountTransitionTarget.canonicalHome(home)
        self.home=canonicalHome;self.userHome=userHome
        context=try CodexCLIContext.resolve(home:canonicalHome,userHome:userHome,executable:executable,records:records)
    }
    func run(_ arguments:[String],timeout:TimeInterval=8) throws ->CommandResult {
        guard let context else {throw AppError.message("Codex CLI를 찾지 못했습니다.")}
        return try context.run(arguments,timeout:timeout)
    }
    func archiveDanglingSocket() throws ->CodexControlSocketBackup? {
        let entry=URL(fileURLWithPath:home).appendingPathComponent("app-server-control/app-server-control.sock").path
        var before=stat(),target=stat()
        if lstat(entry,&before) != 0 {
            guard errno==ENOENT else {throw AppError.message("서버 소켓 경로의 접근 권한을 확인해주세요.")}
            return nil
        }
        guard before.st_uid==getuid(),before.st_mode & S_IFMT == S_IFLNK,
              stat(entry,&target) != 0,errno==ENOENT else {
            throw AppError.message("서버 소켓이 바뀌어 준비를 보류했습니다. 연결을 다시 확인해주세요.")
        }
        let backup=CodexControlSocketBackup(source:entry,path:entry+".autoapprove-stale-"+UUID().uuidString,device:before.st_dev,inode:before.st_ino)
        guard renamex_np(entry,backup.path,UInt32(RENAME_EXCL))==0 else {throw AppError.message("이전 서버 링크를 보관하지 못했습니다. 경로 권한을 확인해주세요.")}
        var current=stat()
        guard backup.owns(),stat(backup.path,&target) != 0,errno==ENOENT,
              lstat(entry,&current) != 0,errno==ENOENT else {
            backup.restore()
            throw AppError.message("준비 중 서버 소켓이 바뀌었습니다. 새 서버를 시작하지 않았습니다.")
        }
        return backup
    }
    func autoStart() throws ->Bool {
        let result=try run(["features","list"])
        let rows=result.output.split(separator:"\n").map{$0.split(whereSeparator:{$0.isWhitespace})}.filter{$0.first=="daemon_auto_start"}
        guard result.status==0,rows.count==1,rows[0].count==3,["true","false"].contains(String(rows[0][2])) else {throw AppError.message("Codex 데몬 자동 시작의 유효 설정을 확인하지 못했습니다.")}
        return rows[0][2]=="true"
    }
    func inspect() throws ->CodexManagedServerStatus {
        guard let executable,FileManager.default.isExecutableFile(atPath:executable) else {
            return .init(phase:.missingCLI,detail:"이 Mac의 로그인 셸에서 Codex CLI를 찾지 못했습니다. Codex를 설치한 뒤 연결을 다시 확인해주세요.")
        }
        let cli=try run(["--version"])
        let value=cli.output.trimmingCharacters(in:.whitespacesAndNewlines)
        guard cli.status==0,value.hasPrefix("codex-cli ") else {
            return .init(phase:.unavailable,detail:"설치된 Codex 버전을 확인하지 못했습니다. CLI 설치와 실행 권한을 확인해주세요.")
        }
        let version=String(value.dropFirst("codex-cli ".count))
        guard version.utf8.count<=32,version.range(of:#"^[0-9]+\.[0-9]+\.[0-9]+$"#,options:.regularExpression) != nil else {
            return .init(phase:.unavailable,detail:"Codex의 정식 버전 번호를 확인하지 못했습니다. CLI 설치를 확인해주세요.")
        }
        guard CodexAccountTransitionLocal.supported(version) else {
            return .init(phase:.unsupported,version:version,detail:"Codex \(version)은 관리형 서버 자동 전환 대상이 아닙니다. Codex 0.166.0 이상으로 업데이트해주세요.")
        }
        let result=try run(["app-server","daemon","version"])
        if result.status==0,let data=result.output.data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:data) as? JSONObject {
            var managedInfo=stat()
            guard object["status"] as? String=="running",["pid","launchd"].contains(object["backend"] as? String ?? ""),
                  object["cliVersion"] as? String==version,object["appServerVersion"] as? String==version,object["managedCodexVersion"] as? String==version,
                  let socket=CodexQueueConnection.socketPath(home:home),let published=object["socketPath"] as? String,
                  URL(fileURLWithPath:published).resolvingSymlinksInPath().path==socket,
                  let managed=object["managedCodexPath"] as? String,managed.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:managed),
                  stat(managed,&managedInfo)==0,[getuid(),0].contains(managedInfo.st_uid) else {
                return .init(phase:.unavailable,version:version,detail:"기존 서버의 버전·소켓 연결을 확인하지 못했습니다. 실행 중인 작업을 유지하고 Codex 설치 상태를 확인해주세요.")
            }
            return .init(phase:.running,version:version,detail:"이 홈의 관리형 Codex 서버가 실행 중입니다.",autoStartEnabled:try autoStart())
        }
        guard result.status != 0 else {
            return .init(phase:.unavailable,version:version,detail:"관리형 서버의 응답 형식을 확인하지 못했습니다. 서버를 시작하거나 다시 시작하지 않았습니다.")
        }
        let entry=URL(fileURLWithPath:home).appendingPathComponent("app-server-control/app-server-control.sock").path
        var info=stat()
        let exists=lstat(entry,&info)==0,lookupError=errno
        var target=stat()
        let dangling=exists && info.st_uid==getuid() && info.st_mode & S_IFMT == S_IFLNK
            && stat(entry,&target) != 0 && errno==ENOENT
        guard !exists && lookupError==ENOENT || dangling else {
            return .init(phase:.unavailable,version:version,detail:"서버 소켓의 상태를 확인하지 못했습니다. 서버를 다시 시작하지 않았습니다. 연결을 다시 확인해주세요.")
        }
        let capability=try run(["app-server","daemon","start","--help"])
        guard capability.status==0,capability.output.contains("app-server daemon start") else {
            return .init(phase:.unsupported,version:version,detail:"이 Codex 설치는 관리형 데몬 시작 명령을 지원하지 않습니다. 공식 Codex CLI 설치를 업데이트해주세요.")
        }
        return .init(phase:.stopped,version:version,detail:dangling
            ? "이전 서버의 연결 경로가 사라졌습니다. 관리형 서버를 준비해주세요."
            : "이 홈의 관리형 Codex 서버가 아직 준비되지 않았습니다.",autoStartEnabled:try autoStart())
    }
}

private struct CodexControlSocketBackup {
    let source:String,path:String,device:dev_t,inode:ino_t
    func owns()->Bool {
        var info=stat()
        return lstat(path,&info)==0 && info.st_uid==getuid() && info.st_mode & S_IFMT == S_IFLNK && info.st_dev==device && info.st_ino==inode
    }
    func restore() {
        // Exclusive restore never overwrites a socket another CLI published.
        guard owns() else{return}
        _ = renamex_np(path,source,UInt32(RENAME_EXCL))
    }
    func discard() {guard owns() else{return};_ = unlink(path)}
}
