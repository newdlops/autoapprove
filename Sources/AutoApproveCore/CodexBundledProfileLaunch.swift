import Foundation

/// Only a validated app resource can select the maintained CLI. Preparation
/// happens before opening a tab; an incompatible live server is never replaced.
enum CodexBundledProfileLaunch {
    static func prepare(entry:TerminalProfileEntry,runtime:CodexBundledRuntime.Installation,
                        server:CodexManagedServerServices,
                        installed:(@Sendable (String) async throws -> (CodexCLIContext,CodexManagedServerStatus)?)? = nil) async throws {
        let entry=try entry.validated()
        guard entry.agent == "codex" else {throw AppError.message("Codex 프로필을 확인해주세요.")}
        try runtime.verifyUnchanged()
        let home=try CodexAccountTransitionTarget.canonicalHome(entry.providerHome ?? NSHomeDirectory()+"/.codex")
        let status=try await server.prepare(home,[])
        try Task.checkCancellation()
        do {
            _ = try await CodexProfileLaunchRuntime.verifiedServer(home:home,runtime:runtime,status:status,installed:installed)
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw AppError.message("선택한 로그인 홈의 Codex 서버를 준비하지 못했습니다. "+error.localizedDescription)
        }
        try runtime.verifyUnchanged()
    }
}
