import Foundation
import Darwin

/// A literal CLI invocation. Native binaries never start a login shell; script
/// wrappers discover their executable/PATH once and reuse that environment.
struct CodexCLIContext {
    let executable:String
    let environment:[String:String]
    private let identity:Identity
    private struct Identity:Equatable {
        let device:dev_t,inode:ino_t,size:off_t,modified:Int64,nanos:Int64
        init?(_ path:String) {
            var info=stat()
            guard stat(path,&info)==0,info.st_mode&S_IFMT==S_IFREG,[getuid(),0].contains(info.st_uid),
                  FileManager.default.isExecutableFile(atPath:path) else{return nil}
            device=info.st_dev;inode=info.st_ino;size=info.st_size
            modified=Int64(info.st_mtimespec.tv_sec);nanos=Int64(info.st_mtimespec.tv_nsec)
        }
    }
    static func resolve(home:String,userHome:String,executable supplied:String?,records:[ProcessRecord]=[],
                        environment base:[String:String]=ProcessInfo.processInfo.environment) throws -> Self? {
        try Task.checkCancellation()
        let home=try CodexAccountTransitionTarget.canonicalHome(home)
        var env=base
        env["HOME"]=userHome;env["CODEX_HOME"]=home;env["NO_COLOR"]="1"
        var requested=supplied
        if let supplied {
            guard validPath(supplied) else{throw AppError.message("Codex 실행 파일의 전체 경로가 필요합니다.")}
        }
        for row in records where row.agent == .codex {
            let launch=ProcessEnvironment.read(row)?["CODEX_HOME"] ?? userHome+"/.codex"
            guard (try? CodexAccountTransitionTarget.canonicalHome(launch))==home,
                  let path=CodexServerLocation.executable(row),
                  requested==nil || URL(fileURLWithPath:requested!).resolvingSymlinksInPath().path==URL(fileURLWithPath:path).resolvingSymlinksInPath().path else{continue}
            requested=requested ?? path
            if let path=ProcessEnvironment.read(row,names:["PATH"])?["PATH"],validSearchPath(path){env["PATH"]=path}
            break
        }
        if let path=requested,let identity=Identity(path),native(path) {
            return .init(executable:path,environment:env,identity:identity)
        }
        // Keep each startup banner outside the result boundary. Only these two
        // fields leave the shell; no full environment or credentials are read.
        let marker="AUTOAPPROVE_CLI_"+UUID().uuidString
        let script="aa_cli_requested=$1; aa_cli_marker=$2; aa_cli_path=$(whence -p -- \"$aa_cli_requested\") || exit 127; print -rn -- \"$aa_cli_marker\"; printf '\\0%s\\0%s\\0' \"$aa_cli_path\" \"$PATH\""
        let found=try CommandRunner.run("/bin/zsh",["-l","-i","-c",script,"autoapprove-cli-context",requested ?? "codex",marker],
            timeout:8,environment:env,inheritEnvironment:false,outputLimit:65536,errorLimit:32768)
        try Task.checkCancellation()
        if found.status==127{return nil}
        guard found.status==0,let range=found.output.range(of:marker+"\0"),
              found.output.range(of:marker+"\0",range:range.upperBound..<found.output.endIndex)==nil else{
            throw AppError.message("Codex 실행 환경의 응답 경계를 확인하지 못했습니다.")
        }
        let fields=found.output[range.upperBound...].split(separator:"\0",omittingEmptySubsequences:false)
        guard fields.count==3,fields[2].isEmpty,validPath(String(fields[0])),validSearchPath(String(fields[1])),
              let identity=Identity(String(fields[0])) else{throw AppError.message("Codex 실행 환경을 확인하지 못했습니다.")}
        env["PATH"]=String(fields[1])
        return .init(executable:String(fields[0]),environment:env,identity:identity)
    }
    func run(_ arguments:[String],timeout:TimeInterval=8) throws -> CommandResult {
        try Task.checkCancellation()
        guard arguments.allSatisfy({!$0.contains("\0")}),Identity(executable)==identity else{
            throw AppError.message("Codex 실행 파일이 바뀌었습니다. 상태를 다시 확인해주세요.")
        }
        let result=try CommandRunner.run(executable,arguments,timeout:timeout,environment:environment,
            inheritEnvironment:false,outputLimit:32768,errorLimit:32768)
        try Task.checkCancellation()
        guard Identity(executable)==identity else{throw AppError.message("Codex 조회 중 실행 파일이 바뀌었습니다.")}
        return result
    }
    private static func validPath(_ value:String)->Bool {
        value.hasPrefix("/") && value.utf8.count<=4096 && !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
    }
    private static func validSearchPath(_ value:String)->Bool {
        !value.isEmpty && value.utf8.count<=32768 && !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains)
    }
    private static func native(_ path:String)->Bool {
        guard let file=try? FileHandle(forReadingFrom:URL(fileURLWithPath:path)) else{return false}
        defer{try? file.close()}
        guard let data=try? file.read(upToCount:4),data.count==4 else{return false}
        return Set<UInt32>([0xfeedface,0xcefaedfe,0xfeedfacf,0xcffaedfe,0xcafebabe,0xbebafeca,0xcafebabf,0xbfbafeca]).contains(data.reduce(UInt32(0)){($0<<8)|UInt32($1)})
    }
}

