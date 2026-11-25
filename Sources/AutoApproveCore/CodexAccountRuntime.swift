import Foundation

/// One account operation keeps the same attested executable and selected home
/// through observation, restart and verification. A later operation resolves
/// again, so an installed CLI update is never hidden by a process-wide cache.
struct CodexAccountRuntime:Sendable {
    let context:CodexCLIContext
    let verifyExecutable:@Sendable (String)throws->Void
    private let official:Bool

    init(_ target:CodexAccountTransitionTarget,
         verifyExecutable:(@Sendable (String)throws->Void)?=nil,
         environment:[String:String]=ProcessInfo.processInfo.environment) throws {
        // A selected-home account operation must not acquire the app process's
        // API key/token instead. Keep executable lookup and ordinary transport
        // settings; authentication belongs to the selected Codex home.
        let inherited:Set<String>=["PATH","ZDOTDIR","LANG","LC_ALL","LC_CTYPE",
            "HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","NO_PROXY",
            "http_proxy","https_proxy","all_proxy","no_proxy","SSL_CERT_FILE","SSL_CERT_DIR"]
        var env=environment.filter{inherited.contains($0.key)}
        env["PATH"]=env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let records=target.witnesses.prefix(50).flatMap {witness in
            ((try? ProcessDiscovery.read(pid:witness.pid)) ?? []).filter {
                $0.pid==witness.pid && $0.started==witness.started && "/dev/"+$0.tty==witness.tty
            }
        }
        let executable=target.executable=="codex" ? nil:target.executable
        let selected:CodexCLIContext?
        // Only internal transport fixtures provide a verifier. Public services
        // always resolve the original signed native CLI, including npm installs.
        if let verifyExecutable {
            selected=try CodexCLIContext.resolve(home:target.home,userHome:NSHomeDirectory(),executable:executable,records:records,environment:env)
            if let selected {try verifyExecutable(selected.executable)}
        } else {
            selected=try CodexOfficialExecutable.resolve(home:target.home,userHome:NSHomeDirectory(),executable:executable,records:records,environment:env)
        }
        guard let selected else {throw AppError.message("공식 Codex CLI를 찾지 못했습니다. Codex 설치를 확인해주세요.")}
        context=selected
        official=verifyExecutable==nil
        self.verifyExecutable=verifyExecutable ?? {try CodexOfficialExecutable.verify($0)}
        try validate(target)
    }

    func validate(_ target:CodexAccountTransitionTarget) throws {
        try Task.checkCancellation()
        guard context.environment["CODEX_HOME"] == (try CodexAccountTransitionTarget.canonicalHome(target.home)) else {
            throw AppError.message("조회할 Codex 로그인 홈이 바뀌었습니다. 다시 확인해주세요.")
        }
        try context.verifyUnchanged()
    }
    func connectedServerIdentity(home:String) throws ->[String] {
        guard official else { return [] }
        return try connectedServerIdentity(CodexQueueConnection(home: home))
    }
    func connectedServerIdentity(_ connection: CodexQueueConnection) throws -> [String] {
        guard official else { return [] }
        let peer = try CodexOfficialExecutable.verifyServer(connection)
        return [String(peer.pid),String(peer.auditPidVersion)]
    }
}
