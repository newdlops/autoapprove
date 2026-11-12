import Foundation

/// A profile never supplies a binary. Keep the app's client when attaching to
/// a verified compatible server; changing clients also changes question handling.
struct CodexProfileLaunchRuntime:Sendable {
    let bundled:CodexBundledRuntime.Installation?
    let installed:CodexCLIContext?
    let version:String

    static func resolve(entry:TerminalProfileEntry,runtime:CodexBundledRuntime.Installation,
                        server:CodexManagedServerServices,
                        installed:(@Sendable (String) async throws -> (CodexCLIContext,CodexManagedServerStatus)?)? = nil) async throws -> Self {
        let entry=try entry.validated()
        guard entry.agent == "codex" else {throw AppError.message("Codex 프로필을 확인해주세요.")}
        try runtime.verifyUnchanged()
        let home=try CodexAccountTransitionTarget.canonicalHome(entry.providerHome ?? NSHomeDirectory()+"/.codex")
        let status=try await server.inspect(home,[])
        try Task.checkCancellation()
        if status.phase == .running,status.version==runtime.version {
            try runtime.verifyUnchanged()
            return .init(bundled:runtime,installed:nil,version:runtime.version)
        }
        if status.phase == .stopped {
            try await CodexBundledProfileLaunch.prepare(entry:entry,runtime:runtime,server:server)
            return .init(bundled:runtime,installed:nil,version:runtime.version)
        }
        // Inspection never updates/restarts a daemon, enables a feature or
        // changes credentials. Incompatibility cannot fall back to preparation.
        let replacement:(CodexCLIContext,CodexManagedServerStatus)?
        if let installed {replacement=try await installed(home)}
        else {replacement=try await installedRuntime(home,observer:runtime.executable)}
        if let (cli,current)=replacement,current.phase == .running,
           let version=current.version {
            try verify(cli,version:version)
            // The installed CLI attests the existing server, not the client
            // to launch. The bundled 0.167.1 client has been exercised against
            // 0.167.2, including child approvals displayed on the parent.
            // Do not silently discard its behavior after an external update.
            guard runtime.version == "0.167.1",version == "0.167.2" else {
                throw AppError.message("실행 중인 Codex 서버와 앱 내장 클라이언트의 호환성을 확인하지 못했습니다. AutoApprove 업데이트가 필요합니다. 기존 서버는 유지했습니다.")
            }
            try runtime.verifyUnchanged()
            return .init(bundled:runtime,installed:nil,version:runtime.version)
        }
        throw AppError.message("실행 중인 Codex 서버와 호환되는 CLI를 확인하지 못했습니다. 기존 서버는 유지했습니다. "+status.detail)
    }

    func verifyUnchanged() throws {
        try bundled?.verifyUnchanged()
        if let installed {try Self.verify(installed,version:version)}
    }
    private static func verify(_ cli:CodexCLIContext,version:String) throws {
        let result=try cli.run(["--version"])
        guard result.status==0,result.output.trimmingCharacters(in:.whitespacesAndNewlines)=="codex-cli "+version,
              CodexAccountTransitionLocal.supported(version) else {throw AppError.message("복원할 Codex CLI가 바뀌었습니다. 다시 확인해주세요.")}
    }
    private static func installedRuntime(_ home:String,observer:String) async throws -> (CodexCLIContext,CodexManagedServerStatus)? {
        let cli:CodexCLIContext?=try await Task.detached(priority:.utility) {
            guard let observer=try CodexCLIContext.resolve(home:home,userHome:NSHomeDirectory(),executable:observer) else{return nil}
            let reply=try observer.run(["app-server","daemon","version"])
            guard reply.status==0,let data=reply.output.data(using:.utf8),
                  let metadata=try JSONSerialization.jsonObject(with:data) as? JSONObject,
                  metadata["status"] as? String=="running",
                  let managed=metadata["managedCodexPath"] as? String,
                  let published=metadata["socketPath"] as? String,
                  let socket=CodexQueueConnection.socketPath(home:home),
                  URL(fileURLWithPath:published).resolvingSymlinksInPath().path==socket else{return nil}
            return try CodexCLIContext.resolve(home:home,userHome:NSHomeDirectory(),executable:managed)
        }.value
        guard let cli else{return nil}
        // Re-read with the managed CLI itself. The existing inspector requires
        // CLI/server/managed versions, socket and executable ownership to agree.
        let status=try await CodexManagedServerServices.local(executable:cli.executable).inspect(home,[])
        guard status.phase == .running else{return nil}
        return (cli,status)
    }
}
