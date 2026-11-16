import Foundation

/// Non-secret launch identity retained while the original process still exists.
/// It does not attest a saved executable: every later launch verifies it again.
public struct CodexSessionLaunch: Codable, Sendable, Equatable {
    public let executable: String
    public let userHome: String
    public let providerHome: String
    public let path: String?

    static func capture(_ record:ProcessRecord,userHome:String=NSHomeDirectory()) throws ->Self {
        try Task.checkCancellation()
        guard record.agent == .codex,
              let observed=ProcessEnvironment.read(record,names:["HOME","CODEX_HOME","PATH"]),
              let executable=CodexServerLocation.executable(record) else {
            throw AppError.message("원래 Codex의 실행 파일과 로그인 홈을 확인하지 못했습니다. 기존 세션을 유지했습니다.")
        }
        let userHome=observed["HOME"] ?? userHome
        let hint=try CodexAccountTransitionTarget.canonicalHome(observed["CODEX_HOME"] ?? userHome+"/.codex")
        let home=CodexServerLocation.connectedHome(pid:record.pid,hints:[hint]) ?? hint
        // Socket inspection must not turn a reused PID into a saved launch identity.
        guard ProcessEnvironment.executablePath(record)==executable else {
            throw AppError.message("원래 Codex 프로세스가 바뀌어 로그인 홈을 저장하지 못했습니다.")
        }
        try Task.checkCancellation()
        return .init(executable:executable,userHome:userHome,providerHome:home,path:observed["PATH"])
    }

    func officialContext(environment:[String:String]=ProcessInfo.processInfo.environment) throws ->CodexCLIContext {
        guard userHome.hasPrefix("/"),!userHome.contains("\0"),
              executable.hasPrefix("/"),!executable.contains("\0"),path?.contains("\0") != true else {
            throw AppError.message("저장된 Codex 실행 환경을 확인하지 못했습니다.")
        }
        var env=environment
        if let path {env["PATH"]=path}
        guard let context=try CodexOfficialExecutable.resolve(home:providerHome,userHome:userHome,
            executable:executable,environment:env) else {
            throw AppError.message("공식 Codex CLI를 찾지 못했습니다. 기존 세션을 유지했습니다.")
        }
        return context
    }

    /// Legacy attachment receipts already identify the destination home. Recover
    /// the source's login environment while it is live, or from its verified
    /// original shell after exit; never borrow the app's current login.
    static func forAttachment(_ context:SessionExitRecovery,home:String,records:[ProcessRecord]) throws ->Self {
        if let saved=context.codexLaunch {return saved}
        if let process=records.first(where:{$0.key==context.session.id}) {return try capture(process)}
        guard let shell=context.verifiedShell(in:records),
              let environment=ProcessEnvironment.read(shell,names:["HOME","PATH"]),
              let userHome=environment["HOME"],userHome.hasPrefix("/") else {
            throw AppError.message("원래 Codex와 셸의 로그인 환경을 확인하지 못했습니다. 재연결 명령을 보내지 않았습니다.")
        }
        return .init(executable:context.executable,userHome:userHome,
            providerHome:try CodexAccountTransitionTarget.canonicalHome(home),path:environment["PATH"])
    }

    func reconnectionContext(home:String,mode:CodexSessionAttachment.ExecutionMode) async throws ->CodexCLIContext {
        let selected=Self(executable:executable,userHome:userHome,
            providerHome:try CodexAccountTransitionTarget.canonicalHome(home),path:path)
        let cli=try await Task.detached(priority:.utility){try selected.officialContext()}.value
        if mode == .standalone {return cli}
        // Reconnect only to an attested existing daemon. This never creates,
        // replaces or updates a server while the original TUI is still alive.
        guard let (matching,status)=try await CodexProfileLaunchRuntime.installedRuntime(home,
            observer:cli.executable,userHome:userHome,environment:cli.environment),status.phase == .running else {
            throw AppError.message("재연결할 공식 Codex 서버를 확인하지 못했습니다. 원래 세션을 유지했습니다.")
        }
        return matching
    }
}
