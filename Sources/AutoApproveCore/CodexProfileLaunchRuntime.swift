import Foundation

/// A profile never supplies a binary. Use the official client matching its
/// server, without replacing a live daemon or falling back to a patched client.
struct CodexProfileLaunchRuntime:Sendable {
    typealias VerifyInstalled = @Sendable (CodexCLIContext,String) throws -> Void
    let bundled:CodexBundledRuntime.Installation?
    let installed:CodexCLIContext?
    let version:String
    var standalone=false
    private let verifyInstalled:VerifyInstalled

    static func resolveInstalled(entry:TerminalProfileEntry,cli:CodexCLIContext,server:CodexManagedServerServices,
                                 installed:(@Sendable (String) async throws -> (CodexCLIContext,CodexManagedServerStatus)?)? = nil,
                                 verifyInstalled:@escaping VerifyInstalled = {try Self.verify($0,$1)}) async throws -> Self {
        let entry=try entry.validated()
        guard entry.agent == "codex" else{throw AppError.message("Codex 프로필을 확인해주세요.")}
        let home=try CodexAccountTransitionTarget.canonicalHome(entry.providerHome ?? NSHomeDirectory()+"/.codex")
        let before=try await server.inspect(home,[])
        let status:CodexManagedServerStatus
        if before.phase == .stopped {status=try await server.prepare(home,[])}
        else {status=before}
        try Task.checkCancellation()
        if status.phase == .running,let version=status.version {
            try verifyInstalled(cli,version)
            return .init(bundled:nil,installed:cli,version:version,verifyInstalled:verifyInstalled)
        }
        let replacement:(CodexCLIContext,CodexManagedServerStatus)?
        if let installed {replacement=try await installed(home)}
        else {replacement=try await installedRuntime(home,observer:cli.executable)}
        if let (matching,current)=replacement,current.phase == .running,let version=current.version {
            try verifyInstalled(matching,version)
            return .init(bundled:nil,installed:matching,version:version,verifyInstalled:verifyInstalled)
        }
        throw AppError.message("공식 Codex 서버의 실행 상태를 확인하지 못했습니다. "+status.detail)
    }

    static func resolve(entry:TerminalProfileEntry,runtime:CodexBundledRuntime.Installation,
                        server:CodexManagedServerServices,
                        installed:(@Sendable (String) async throws -> (CodexCLIContext,CodexManagedServerStatus)?)? = nil,
                        verifyInstalled:@escaping VerifyInstalled = {try Self.verify($0,$1)}) async throws -> Self {
        let entry=try entry.validated()
        guard entry.agent == "codex" else {throw AppError.message("Codex 프로필을 확인해주세요.")}
        try runtime.verifyUnchanged()
        let home=try CodexAccountTransitionTarget.canonicalHome(entry.providerHome ?? NSHomeDirectory()+"/.codex")
        do {
            let status=try await server.inspect(home,[])
            try Task.checkCancellation()
            if status.phase == .stopped {
                return try await CodexBundledProfileLaunch.prepare(entry:entry,runtime:runtime,server:server,installed:installed,verifyInstalled:verifyInstalled)
            }
            return try await verifiedServer(home:home,runtime:runtime,status:status,installed:installed,verifyInstalled:verifyInstalled)
        } catch is CancellationError {throw CancellationError()}
        catch {
            // A new conversation has no existing writer to reconnect. It can
            // use the original CLI without attaching to or replacing a legacy
            // daemon. Saved-conversation resumes retain the server requirement.
            try Task.checkCancellation()
            guard !entry.resumesConversation else {throw error}
            try runtime.verifyUnchanged()
            return .init(bundled:runtime,installed:nil,version:runtime.version,standalone:true,verifyInstalled:verifyInstalled)
        }
    }

    /// Official daemon start can select an already-installed newer managed binary.
    /// Apply the same attestation after start as when attaching to an existing server.
    static func verifiedServer(home:String,runtime:CodexBundledRuntime.Installation,status:CodexManagedServerStatus,
                               installed:(@Sendable (String) async throws -> (CodexCLIContext,CodexManagedServerStatus)?)? = nil,
                               verifyInstalled:@escaping VerifyInstalled = {try Self.verify($0,$1)}) async throws -> Self {
        try Task.checkCancellation()
        if status.phase == .running,status.version==runtime.version {
            try runtime.verifyUnchanged()
            return .init(bundled:runtime,installed:nil,version:runtime.version,verifyInstalled:verifyInstalled)
        }
        // Inspection never updates/restarts a daemon, enables a feature or
        // changes credentials. Incompatibility cannot fall back to preparation.
        let replacement:(CodexCLIContext,CodexManagedServerStatus)?
        if let installed {replacement=try await installed(home)}
        else {replacement=try await installedRuntime(home,observer:runtime.executable)}
        if let (cli,current)=replacement,current.phase == .running,
           let version=current.version {
            try verifyInstalled(cli,version)
            return .init(bundled:nil,installed:cli,version:version,verifyInstalled:verifyInstalled)
        }
        throw AppError.message("실행 중인 Codex 서버와 호환되는 CLI를 확인하지 못했습니다. 기존 서버는 유지했습니다. "+status.detail)
    }

    func verifyUnchanged() throws {
        try bundled?.verifyUnchanged()
        if let installed {try verifyInstalled(installed,version)}
    }
    static func verify(_ cli:CodexCLIContext,_ version:String) throws {
        try cli.verifyUnchanged()
        try CodexOfficialExecutable.verify(cli.executable)
        let result=try cli.run(["--version"])
        guard result.status==0,result.output.trimmingCharacters(in:.whitespacesAndNewlines)=="codex-cli "+version,
              CodexAccountTransitionLocal.supported(version) else {throw AppError.message("복원할 Codex CLI가 바뀌었습니다. 다시 확인해주세요.")}
    }
    static func installedRuntime(_ home:String,observer:String,userHome:String=NSHomeDirectory(),
                                 environment:[String:String]=ProcessInfo.processInfo.environment) async throws -> (CodexCLIContext,CodexManagedServerStatus)? {
        let cli:CodexCLIContext?=try await Task.detached(priority:.utility) {
            guard let observer=try CodexCLIContext.resolve(home:home,userHome:userHome,executable:observer,environment:environment) else{return nil}
            let officialObserver=try CodexOfficialExecutable.context(observer)
            let reply=try officialObserver.run(["app-server","daemon","version"])
            guard reply.status==0,let data=reply.output.data(using:.utf8),
                  let metadata=try JSONSerialization.jsonObject(with:data) as? JSONObject,
                  metadata["status"] as? String=="running",
                  let managed=metadata["managedCodexPath"] as? String,
                  let published=metadata["socketPath"] as? String,
                  let socket=CodexQueueConnection.socketPath(home:home),
                  URL(fileURLWithPath:published).resolvingSymlinksInPath().path==socket else{return nil}
            try CodexOfficialExecutable.verify(managed)
            guard let selected=try CodexCLIContext.resolve(home:home,userHome:userHome,executable:managed,environment:environment) else{return nil}
            return try selected.selectingNativeExecutable(managed)
        }.value
        guard let cli else{return nil}
        // Re-read with the managed CLI itself. The existing inspector requires
        // CLI/server/managed versions, socket and executable ownership to agree.
        let status=try await CodexManagedServerServices.local(userHome:userHome,executable:cli.executable).inspect(home,[])
        guard status.phase == .running else{return nil}
        return (cli,status)
    }
}
