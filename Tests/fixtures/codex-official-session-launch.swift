import Foundation
@testable import AutoApproveCore

@main struct OfficialSessionLaunchCheck {
    @MainActor static func main() async throws {
        let root=CommandLine.arguments[1],executable=CommandLine.arguments[2],home=root+"/home"
        let environment=["HOME":root,"CODEX_HOME":home,"ZDOTDIR":root,"PATH":"/usr/bin:/bin",
            "HTTP_PROXY":"http://127.0.0.1:9","HTTPS_PROXY":"http://127.0.0.1:9","NO_PROXY":"127.0.0.1,localhost"]
        guard let original=try CodexOfficialExecutable.resolve(home:home,userHome:root,executable:executable,environment:environment) else {
            throw AppError.message("Owned official CLI missing")
        }
        let source=try ManagedPTY(cwd:root,program:"codex",command:original.terminalInvocation(["OWNED_HISTORY_USER"]),columns:120,rows:40,environment:environment)
        defer {source.close()}
        let record=try await native(source,executable:executable,root:root,home:home)
        try await visible(source,"OWNED_HISTORY_REPLY")
        let open=try CommandRunner.run("/usr/sbin/lsof",["-a","-p",String(record.pid),"-Fpn"],timeout:5)
        let thread=try CodexThreadLocation.locate(paths:CodexThreadLocation.openFiles(open.output)[record.pid] ?? []).threadID
        let client=UUID().uuidString,draft="OWNED_SOURCE_DRAFT"
        try source.input(Data(draft.utf8),streamID:source.descriptor.streamID,client:client,sequence:1)
        try await visible(source,draft)

        let selected=try CodexOfficialExecutable.forSession(record,environment:environment)
        guard selected.executable==original.executable,selected.environment["CODEX_HOME"]==original.environment["CODEX_HOME"] else {
            throw AppError.message("Source selection lost its original executable or login home")
        }
        let manager=ManagedPTYManager(environment:environment),pid=record.pid
        let engine=try ApprovalEngine(paths:AppPaths(directory:URL(fileURLWithPath:root+"/profile")),
            processReader:{try ProcessDiscovery.read(pid:pid)},managedPTY:manager)
        defer {engine.stop()}
        let session=AgentSession(id:record.key,agent:.codex,pid:record.pid,started:record.started,tty:"/dev/"+record.tty,cwd:root,terminal:.terminal)
        engine.updateDiscovery([session],records:[record])
        let request:JSONObject=["sessionID":session.id,"conversationID":thread,"reuse":true,"columns":120,"rows":40]
        let opened=try await engine.createPTY(request),fork=try manager.terminal(opened.ptyID)
        let forkRecord=try await native(fork,executable:executable,root:root,home:home)
        guard ProcessEnvironment.arguments(forkRecord).map({Array($0.dropFirst())})==["fork",thread] else {
            throw AppError.message("Fork did not receive the exact original conversation")
        }
        try await visible(fork,"OWNED_HISTORY_REPLY")
        guard source.isRunning,source.screen().contains(draft),!fork.screen().contains(draft) else {
            throw AppError.message("Opening a fork changed the original input draft")
        }
        let reused=try await engine.createPTY(request)
        guard reused.ptyID==opened.ptyID,manager.inventory.count==1 else {throw AppError.message("A repeated continuation created another fork")}

        // Exercise the same command construction used by a manual restart. The
        // live original remains open; this owned PTY verifies actual CLI parsing
        // and history restoration, not keyboard delivery into a user terminal.
        let plan=try SessionRestartCommand.plan(agent:.codex,executable:selected.executable,
            argv:["--model","fixture-model","resume",thread],conversationID:thread)
        let resumed=try ManagedPTY(cwd:root,program:"codex",command:selected.terminalInvocation(Array(plan.arguments.dropFirst())),columns:120,rows:40,environment:selected.environment)
        defer {resumed.close()}
        let resumedRecord=try await native(resumed,executable:executable,root:root,home:home)
        guard ProcessEnvironment.arguments(resumedRecord).map({Array($0.dropFirst())})==Array(plan.arguments.dropFirst()) else {
            throw AppError.message("Resume lost the preserved CLI options or conversation")
        }
        try await visible(resumed,"OWNED_HISTORY_REPLY")
        guard source.isRunning,source.screen().contains(draft) else {throw AppError.message("Resume affected the original draft")}
        print("{\"verified\":true,\"threadID\":\"\(thread)\",\"officialSourceSelection\":true,\"productionEngineFork\":true,\"exactConversationAndHome\":true,\"persistedHistoryVisible\":true,\"originalDraftRetained\":true,\"repeatForkDeduplicated\":true,\"actualResumeOptionsAndHistory\":true,\"userTerminalTouched\":false}")
    }
    static func visible(_ terminal:ManagedPTY,_ text:String) async throws {
        for _ in 0..<300 {
            if terminal.screen().contains(text) {return}
            guard terminal.isRunning else {throw AppError.message("Owned CLI exited before expected history: "+terminal.screen())}
            try await Task.sleep(for:.milliseconds(50))
        }
        let descriptor=terminal.descriptor
        _ = try? CommandRunner.run("/usr/bin/sample",[String(descriptor.pid),"1","1","-file",descriptor.cwd+"/owned-timeout.sample"],timeout:5)
        throw AppError.message("Owned screen did not contain "+text+": "+terminal.screen())
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
