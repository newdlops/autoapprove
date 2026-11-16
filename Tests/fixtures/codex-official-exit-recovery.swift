import Foundation
@testable import AutoApproveCore

private final class RecoveryProbe:@unchecked Sendable {
    let lock=NSLock(),root:String,environment:[String:String],screen:String
    var records:[ProcessRecord]=[]
    private var commands:[String]=[]
    private var replacement:ManagedPTY?
    init(root:String,environment:[String:String],thread:String) {
        self.root=root;self.environment=environment
        screen="To continue this session, run codex resume "+thread+"\nowned% "
    }
    func read()->[ProcessRecord] {lock.withLock {records}}
    func set(_ values:[ProcessRecord]) {lock.withLock {records=values}}
    func send(_ command:String)throws->TerminalDelivery {
        // The adapter is synthetic; only this test's own PTY receives the real
        // production recovery command. No Terminal.app input is performed.
        let terminal=try ManagedPTY(cwd:root,program:"codex",command:["/bin/zsh","-c","exec "+command],columns:120,rows:40,environment:environment)
        lock.withLock {commands.append(command);replacement=terminal}
        return .sent
    }
    var terminal:ManagedPTY? {lock.withLock {replacement}}
    var count:Int {lock.withLock {commands.count}}
}

@main struct OfficialExitRecoveryCheck {
    @MainActor static func main() async throws {
        let root=CommandLine.arguments[1],executable=CommandLine.arguments[2],home=root+"/home"
        let environment=["HOME":root,"CODEX_HOME":home,"ZDOTDIR":root,"PATH":"/usr/bin:/bin",
            "HTTP_PROXY":"http://127.0.0.1:9","HTTPS_PROXY":"http://127.0.0.1:9","NO_PROXY":"127.0.0.1,localhost"]
        guard let cli=try CodexOfficialExecutable.resolve(home:home,userHome:root,executable:executable,environment:environment) else {throw AppError.message("Owned official CLI missing")}
        // Create the original through the real CLI. An app-server-created root
        // keeps its VSCode source even after TUI resume and is not a CLI fixture.
        let source=try ManagedPTY(cwd:root,program:"codex",command:cli.terminalInvocation(["OWNED_HISTORY_USER"]),columns:120,rows:40,environment:environment)
        defer {source.close()}
        var record=try await native(source,executable:executable,root:root,home:home)
        try await visible(source,"OWNED_HISTORY_REPLY")
        let open=try CommandRunner.run("/usr/sbin/lsof",["-a","-p",String(record.pid),"-Fpn"],timeout:5)
        let thread=try CodexThreadLocation.locate(paths:CodexThreadLocation.openFiles(open.output)[record.pid] ?? []).threadID
        let shell=ProcessDiscovery.parse("2000000000 1 \(record.tty) 2000000000 2000000000 \(record.started) /bin/zsh")[0]
        record.parent=shell.pid
        let probe=RecoveryProbe(root:root,environment:environment,thread:thread)
        defer {probe.terminal?.close()};probe.set([shell,record])
        let adapter=ScreenHostAdapter(screens:{ targets in TerminalSnapshot(screens:targets.map{TerminalScreen(tty:$0.tty,contents:probe.screen)}) },
            approve:{_,_,_ in .sent},reveal:{_ in nil},restart:{_,_,command in try probe.send(command)})
        let paths=AppPaths(directory:URL(fileURLWithPath:root+"/profile"))
        let engine=try ApprovalEngine(paths:paths,processReader:{probe.read()},screenAdapters:[.terminal:adapter])
        defer {engine.stop()}
        await engine.connectScreenHost(.terminal);engine.interruptionResumeDelays=[0.01]
        var session=AgentSession(id:record.key,agent:.codex,pid:record.pid,started:record.started,tty:"/dev/"+record.tty,cwd:root,terminal:.terminal)
        session.channel = .terminalScreen
        engine.updateDiscovery([session],records:probe.read());try engine.setAutomatic(session.id,enabled:true)
        engine.updateDiscovery([session],records:probe.read())
        guard let captured=await engine.observedExitLaunch(session.id),captured.userHome==root,
              captured.providerHome==URL(fileURLWithPath:home).resolvingSymlinksInPath().path else {
            throw AppError.message("Production engine did not capture the original login home")
        }
        engine.receiveScreen(sessionID:session.id,raw:"■ stream disconnected before completion: network error\n\n› Ask Codex to do anything\n\n? for shortcuts",generation:"owned-error")
        source.close()
        for _ in 0..<100 {
            if try ProcessDiscovery.read(pid:record.pid).isEmpty {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        probe.set([shell]);engine.updateDiscovery([],records:[shell])
        try await Task.sleep(for:.milliseconds(30));engine.updateDiscovery([],records:[shell])
        for _ in 0..<200 {
            if probe.terminal != nil {break}
            try await Task.sleep(for:.milliseconds(50))
        }
        guard let replacement=probe.terminal else {
            throw AppError.message("Owned recovery did not launch: "+(engine.snapshot.sessions.first?.interruption?.recoveryDetail ?? "missing status"))
        }
        var nextRecord=try await native(replacement,executable:executable,root:root,home:home)
        guard ProcessEnvironment.arguments(nextRecord).map({Array($0.dropFirst())})==["resume",thread,CodexCapacityStop.resumeText] else {
            throw AppError.message("Recovery lost the exact original conversation")
        }
        try await visible(replacement,"OWNED_RECOVERY_REPLY")
        nextRecord.parent=shell.pid
        var next=AgentSession(id:nextRecord.key,agent:.codex,pid:nextRecord.pid,started:nextRecord.started,tty:"/dev/"+nextRecord.tty,cwd:root,terminal:.terminal)
        // The adapter's replacement PTY has a different tty. Represent the same
        // original-shell delivery contract in discovery; native() above attests
        // the actual owned process and environment separately.
        nextRecord.tty=record.tty;next.tty=session.tty;next.channel = .terminalScreen
        probe.set([shell,nextRecord]);engine.updateDiscovery([next],records:probe.read())
        for _ in 0..<100 {
            if engine.snapshot.sessions.first(where:{$0.id==session.id})?.interruption?.recoveredAt != nil {break}
            try await Task.sleep(for:.milliseconds(50))
        }
        guard engine.snapshot.sessions.first(where:{$0.id==session.id})?.interruption?.recoveredAt != nil,
              engine.snapshot.sessions.first(where:{$0.id==next.id})?.automatic == true,probe.count==1 else {
            let files=try CommandRunner.run("/usr/sbin/lsof",["-a","-p",String(nextRecord.pid),"-Fpn"],timeout:5)
            let paths=CodexThreadLocation.openFiles(files.output)[nextRecord.pid] ?? []
            let actual=try? CodexThreadLocation.locate(paths:paths).threadID
            let state=engine.snapshot.sessions.map {"\($0.id) phase=\($0.phase) auto=\($0.automatic) recovery=\($0.interruption?.recoveryStatus ?? "none")"}.joined(separator:"; ")
            throw AppError.message("Recovery verification failed; actual=\(actual ?? "nil") expected=\(thread) commands=\(probe.count) states=\(state)")
        }
        engine.stop()
        let restored=try ApprovalEngine(paths:paths,processReader:{probe.read()},screenAdapters:[.terminal:adapter])
        defer {restored.stop()};restored.updateDiscovery([next],records:probe.read())
        try await Task.sleep(for:.milliseconds(100))
        guard probe.count==1 else {throw AppError.message("App restart replayed a recovery command")}
        print("{\"verified\":true,\"threadID\":\"\(thread)\",\"productionExitRecovery\":true,\"officialSourceCapture\":true,\"exactConversationAndHome\":true,\"sameConversationVerified\":true,\"automationPreserved\":true,\"recoveryNotReplayed\":true,\"syntheticTerminalAdapter\":true,\"userTerminalTouched\":false}")
    }
    static func visible(_ terminal:ManagedPTY,_ text:String) async throws {
        for _ in 0..<300 {
            if terminal.screen().contains(text) {return}
            guard terminal.isRunning else {throw AppError.message("Owned CLI exited: "+terminal.screen())}
            try await Task.sleep(for:.milliseconds(50))
        }
        let descriptor=terminal.descriptor
        _ = try? CommandRunner.run("/usr/bin/sample",[String(descriptor.pid),"1","1","-file",descriptor.cwd+"/owned-timeout.sample"],timeout:5)
        throw AppError.message("Owned screen missing "+text+": "+terminal.screen())
    }
    static func native(_ terminal:ManagedPTY,executable:String,root:String,home:String) async throws ->ProcessRecord {
        for _ in 0..<200 {
            if let record=try ProcessDiscovery.read(pid:terminal.descriptor.pid).first(where:{$0.agent == .codex}) {
                let canonical:(String)->String={URL(fileURLWithPath:$0).resolvingSymlinksInPath().path}
                let env=ProcessEnvironment.read(record,names:["HOME","CODEX_HOME","AUTOAPPROVE_NATIVE_RUNTIME_ROOT","AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"])
                guard CodexServerLocation.executable(record).map(canonical)==canonical(executable),env?["HOME"]==root,
                      env?["CODEX_HOME"].map(canonical)==canonical(home),env?["AUTOAPPROVE_NATIVE_RUNTIME_ROOT"]==nil,
                      env?["AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"]==nil else {throw AppError.message("Owned CLI identity or environment changed")}
                return record
            }
            try await Task.sleep(for:.milliseconds(50))
        }
        throw AppError.message("Owned native process missing")
    }
}
