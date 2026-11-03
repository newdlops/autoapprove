import Foundation
import AutoApproveCore

@main struct AttachmentPTYCheck {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath().path
        let home=try CodexAccountTransitionTarget.canonicalHome(root+"/한글 home/.codex"),thread="00000000-0000-4000-8000-000000000061"
        let manager=ManagedPTYManager(environment:["HOME":root,"CODEX_HOME":home,"PATH":"/usr/bin:/bin","PS1":"fixture% ","READY_FILE":root+"/ready","FIXTURE_SOCKET":root+"/daemon.sock","EXPECTED_THREAD":thread])
        defer{manager.stop()}
        let descriptor=try manager.create(cwd:root,program:"shell",command:["/bin/zsh","-f"],columns:100,rows:30)
        let terminal=try manager.terminal(descriptor.ptyID),client=UUID().uuidString
        var sequence=0
        func write(_ text:String)throws {sequence+=1;try terminal.input(Data(text.utf8),streamID:descriptor.streamID,client:client,sequence:sequence)}
        func readyPID()->Int32? {guard let text=try? String(contentsOfFile:root+"/ready",encoding:.utf8) else{return nil};return text.split(separator:" ").first.flatMap{Int32($0)}}
        func wait(_ predicate:()throws->Bool) async throws {
            let limit=Date().addingTimeInterval(8)
            while Date()<limit {if try predicate(){return};try await Task.sleep(for:.milliseconds(100))}
            throw AppError.message("Owned PTY fixture readiness timeout")
        }
        try await wait{SessionExitRecovery.emptyShellPrompt(terminal.screen())}
        try write(HookInstaller.quote(root+"/codex")+"\n")
        try await wait{readyPID() != nil && CodexProgressScreen.ready(terminal.screen())}
        guard let pid=readyPID(),let process=try ProcessDiscovery.read(pid:pid).first,let shell=try ProcessDiscovery.read(pid:descriptor.pid).first else{throw AppError.message("Owned process metadata missing")}
        var session=ProcessDiscovery.sessions([shell,process])[0];session.cwd=root
        let context=SessionExitRecovery(session:session,process:process,shell:shell,conversationID:thread)
        var state=CodexSessionAttachment(context:context,home:home),exits=0,launches=0
        let services=CodexSessionAttachmentServices(exit:{
            guard CodexProgressScreen.ready(terminal.screen()),try ProcessDiscovery.read(pid:pid).contains(where:{$0.key==process.key}) else{return false}
            exits+=1;try write("/exit\n");return true
        },shellReady:{context.verifiedShell(in:try ProcessDiscovery.read()) != nil && SessionExitRecovery.emptyShellPrompt(terminal.screen())},launch:{
            guard context.verifiedShell(in:try ProcessDiscovery.read()) != nil,let command=state.command else{return false}
            launches+=1;try write(command+"\n");return true
        },verify:{
            guard let next=readyPID(),next != pid,let record=try ProcessDiscovery.read(pid:next).first,record.tty==shell.tty,
                  try ProcessDiscovery.read(pid:shell.pid).first?.key==shell.key else{return false}
            return CodexServerLocation.connectedHome(pid:next,hints:[home])==home
        })
        let until=Date().addingTimeInterval(12)
        while state.phase != .connected,Date()<until {
            state=try await services.advance(state,save:{value in try JSONEncoder().encode(value).write(to:URL(fileURLWithPath:root+"/journal"))})
            if state.phase == .review {throw AppError.message(state.detail)}
            try await Task.sleep(for:.milliseconds(100))
        }
        guard state.phase == .connected,exits==1,launches==1 else{throw AppError.message("Owned attachment phase=\(state.phase.rawValue) exits=\(exits) launches=\(launches) screen=\(terminal.screen())")}
        print("{\"verified\":true,\"actualOwnedPTY\":true,\"sameShellAndTTY\":true,\"actualUnixConnection\":true,\"exitRequests\":1,\"resumeCommands\":1,\"userTerminalActions\":0}")
    }
}
