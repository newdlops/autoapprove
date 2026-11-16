import Foundation
@testable import AutoApproveCore

/// A real shell and official TUI in an owned PTY; only Terminal.app discovery
/// and its input adapter are synthetic. No user's Terminal is inspected.
private final class OfficialAttachmentProbe:@unchecked Sendable {
    let terminal:ManagedPTY
    private let lock=NSLock(),client=UUID().uuidString
    private var sequence=0,exits=0,launches=0
    init(_ terminal:ManagedPTY){self.terminal=terminal}
    var counts:(Int,Int){lock.withLock{(exits,launches)}}
    func write(_ text:String)throws {
        try lock.withLock {
            sequence+=1
            try terminal.input(Data(text.utf8),streamID:terminal.descriptor.streamID,client:client,sequence:sequence)
        }
    }
    func read()throws->[ProcessRecord] {
        let descriptor=terminal.descriptor
        let host=ProcessDiscovery.parse("2000000000 1 ?? 2000000000 0 Mon Nov 2 10:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")[0]
        var rows=try ProcessDiscovery.read().filter{"/dev/"+$0.tty==descriptor.tty}
        if let shell=rows.firstIndex(where:{$0.pid==descriptor.pid}) {rows[shell].parent=host.pid}
        return [host]+rows
    }
    func adapter()->ScreenHostAdapter {
        .init(screens:{targets in .init(screens:targets.map{.init(tty:$0.tty,contents:self.terminal.screen())})},
            approve:{_,_,_ in .screenChanged},reveal:{_ in nil},restart:{target,expected,command in
                guard target.tty==self.terminal.descriptor.tty,self.terminal.screen()==expected,
                      SessionExitRecovery.emptyShellPrompt(expected) else{return .screenChanged}
                self.lock.withLock{self.launches+=1};try self.write(command+"\r");return .sent
            },input:{target,expected,_,input in
                guard target.tty==self.terminal.descriptor.tty,self.terminal.screen()==expected else{return .screenChanged}
                guard input.text=="/status" || input.text=="/exit" else{throw AppError.message("Unexpected owned attachment input")}
                if input.text=="/exit" {self.lock.withLock{self.exits+=1}}
                try self.write(input.bytes);return .sent
            })
    }
}

@main struct OfficialAttachmentCheck {
    @MainActor static func main() async throws {
        let root=CommandLine.arguments[1],executable=CommandLine.arguments[2]
        let home=try CodexAccountTransitionTarget.canonicalHome(root+"/home")
        let environment=["HOME":root,"CODEX_HOME":home,"ZDOTDIR":root,"PATH":"/usr/bin:/bin","PS1":"owned% ",
            "HTTP_PROXY":"http://127.0.0.1:9","HTTPS_PROXY":"http://127.0.0.1:9","NO_PROXY":"127.0.0.1,localhost"]
        guard let cli=try CodexOfficialExecutable.resolve(home:home,userHome:root,executable:executable,environment:environment) else{throw AppError.message("Owned official CLI missing")}
        let terminal=try ManagedPTY(cwd:root,command:["/bin/zsh","-f"],columns:120,rows:40,environment:environment)
        defer{terminal.close()}
        let probe=OfficialAttachmentProbe(terminal)
        try await wait(terminal){SessionExitRecovery.emptyShellPrompt(terminal.screen())}
        // Deliberately stale shell variables must be removed from both launches.
        try probe.write("export AUTOAPPROVE_NATIVE_RUNTIME_ROOT=/owned-stale-root AUTOAPPROVE_SELECTED_TRANSITION_SOCKET=/owned-stale-socket CODEX_HOME=/owned-wrong-home\r")
        try await wait(terminal){SessionExitRecovery.emptyShellPrompt(terminal.screen())}
        try probe.write(try cli.terminalInvocation(["--no-daemon","OWNED_HISTORY_USER"]).map(HookInstaller.quote).joined(separator:" ")+"\r")
        try await wait(terminal){terminal.screen().contains("OWNED_HISTORY_REPLY") && CodexGoalScreen.ready(terminal.screen())}
        guard let original=try probe.read().first(where:{$0.agent == .codex && $0.isForeground}) else{throw AppError.message("Owned original CLI missing")}
        let location=try CodexThreadLocation.locate(paths:ProcessOpenFiles.codexRolloutPaths(pid:original.pid,expectedStart:original.started))
        let thread=location.threadID
        guard CodexServerLocation.connectedHome(pid:original.pid,hints:[home])==nil else{throw AppError.message("Source must start independently")}

        let servers=CodexManagedServerServices.local(userHome:root,executable:cli.executable)
        guard try await servers.prepare(home,[]).phase == .running else{throw AppError.message("Owned official daemon not prepared")}
        let engine=try ApprovalEngine(paths:.init(directory:URL(fileURLWithPath:root+"/profile")),
            processReader:{try probe.read()},screenAdapters:[.terminal:probe.adapter()],codexManagedServers:servers)
        defer{engine.stop()}
        await engine.refresh();await engine.connectScreenHost(.terminal)
        try engine.setAutomatic(original.key,enabled:true)
        engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
        try await Task.sleep(for:.seconds(2))
        engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
        var connected=false
        for _ in 0..<100 {
            await engine.ensureCodexManagedServers()
            if let json=engine.store.value("codexSessionAttachments"),
               let state=try JSONDecoder().decode([String:CodexSessionAttachment].self,from:Data(json.utf8))[original.key],state.phase == .connected {
                guard state.context.conversationID==thread else{throw AppError.message("Reconnection changed conversation")}
                connected=true;break
            }
            await engine.refresh()
            engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
            try await Task.sleep(for:.milliseconds(200))
        }
        guard connected,probe.counts==(1,1),let next=try probe.read().first(where:{$0.agent == .codex && $0.isForeground}),next.key != original.key,
              CodexServerLocation.connectedHome(pid:next.pid,hints:[home])==home else {
            throw AppError.message("Owned official attachment failed: \(engine.codexSessionAttachmentNotice ?? "none") counts=\(probe.counts) screen=\(terminal.screen())")
        }
        try CodexOfficialExecutable.verify(CodexServerLocation.executable(next) ?? "")
        let env=ProcessEnvironment.read(next,names:["HOME","CODEX_HOME","AUTOAPPROVE_NATIVE_RUNTIME_ROOT","AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"])
        guard env?["HOME"]==root,env?["CODEX_HOME"]==home,
              env?["AUTOAPPROVE_NATIVE_RUNTIME_ROOT"]==nil,env?["AUTOAPPROVE_SELECTED_TRANSITION_SOCKET"]==nil,
              ProcessEnvironment.arguments(next).map({Array($0.dropFirst())})==["--remote","unix://","resume",thread],
              engine.store.value("automatic:"+next.key)=="true" else{throw AppError.message("Reconnection lost original identity, environment or automation")}
        try await wait(terminal){terminal.screen().contains("OWNED_HISTORY_REPLY") && CodexGoalScreen.ready(terminal.screen())}
        await engine.ensureCodexManagedServers()
        guard probe.counts==(1,1) else{throw AppError.message("Reconnection repeated terminal input")}
        print("{\"verified\":true,\"threadID\":\"\(thread)\",\"productionAttachment\":true,\"officialClientAndServer\":true,\"sameShellAndConversation\":true,\"historyPreserved\":true,\"automationPreserved\":true,\"privateVariablesRemoved\":true,\"singleExitAndLaunch\":true,\"syntheticTerminalAdapter\":true,\"userTerminalTouched\":false}")
    }
    static func wait(_ terminal:ManagedPTY,_ ready:()throws->Bool) async throws {
        for _ in 0..<400 {
            if try ready(){return}
            guard terminal.isRunning else{throw AppError.message("Owned terminal exited: "+terminal.screen())}
            try await Task.sleep(for:.milliseconds(50))
        }
        throw AppError.message("Owned attachment screen timeout: "+terminal.screen())
    }
}
