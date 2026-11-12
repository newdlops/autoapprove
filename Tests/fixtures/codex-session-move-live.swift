import Foundation
import Darwin
@testable import AutoApproveCore

/// Owned real CLI/server/PTY processes, through the application's move API.
/// No model turns or real credentials are used.
@main struct SessionMoveLive {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count==3 else{throw AppError.message("Expected CLI and private fixture directory")}
        let cli=CommandLine.arguments[1],root=CommandLine.arguments[2]
        let files=FileManager.default,app=URL(fileURLWithPath:root+"/app"),work=root+"/work"
        func mark(_ stage:String)throws {
            try stage.write(toFile:root+"/stage.txt",atomically:true,encoding:.utf8)
        }
        try files.createDirectory(atPath:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let groups=CodexLoginGroupStore(directory:app.appendingPathComponent("codex-login-groups"))
        let source=try groups.create(name:"Owned source"),destination=try groups.create(name:"Owned destination")
        let runtimeRoot=try CodexNativeRuntimeRoot.prepare()
        var servers:[Process]=[]
        defer{for server in servers where server.isRunning{server.terminate()}}
        func wait(_ label:String,seconds:Double=15,_ predicate:() async throws->Bool) async throws {
            let deadline=Date().addingTimeInterval(seconds)
            while Date()<deadline {
                if try await predicate(){return}
                try await Task.sleep(for:.milliseconds(100))
            }
            throw AppError.message("Owned move timed out: "+label)
        }
        func environment(_ home:String)->[String:String] {
            ["HOME":root,"CODEX_HOME":home,"PATH":"/usr/bin:/bin","TERM":"xterm-256color",
             "PS1":"fixture% ","NO_COLOR":"1","OTEL_SDK_DISABLED":"true",
             "AUTOAPPROVE_NATIVE_RUNTIME_ROOT":runtimeRoot,
             "HTTP_PROXY":"http://127.0.0.1:9","HTTPS_PROXY":"http://127.0.0.1:9",
             "NO_PROXY":"127.0.0.1,localhost"]
        }
        for (index,group) in [source,destination].enumerated() {
            let config="""
            model = "owned-fixture"
            model_provider = "owned"
            check_for_update_on_startup = false
            cli_auth_credentials_store = "file"
            [analytics]
            enabled = false
            [features]
            goals = true
            daemon_auto_start = false
            apps = false
            plugins = false
            [model_providers.owned]
            name = "Owned offline fixture"
            base_url = "http://127.0.0.1:9/v1"
            wire_api = "responses"
            requires_openai_auth = true
            [projects."\(work)"]
            trust_level = "trusted"
            """
            try config.write(toFile:group.home+"/config.toml",atomically:true,encoding:.utf8)
            // Fake local auth enables account/read without contacting a provider.
            try #"{"OPENAI_API_KEY":"sk-owned-offline-fixture"}"#.write(toFile:group.home+"/auth.json",atomically:true,encoding:.utf8)
            let socket=root+"/\(index).sock",control=group.home+"/app-server-control"
            try files.createDirectory(atPath:control,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try files.createSymbolicLink(atPath:control+"/app-server-control.sock",withDestinationPath:socket)
            let log=root+"/server-\(index).log"
            files.createFile(atPath:log,contents:nil,attributes:[.posixPermissions:0o600])
            let process=Process();process.executableURL=URL(fileURLWithPath:cli)
            process.arguments=["app-server","--listen","unix://"+socket]
            process.environment=environment(group.home);process.currentDirectoryURL=URL(fileURLWithPath:work)
            process.standardInput=FileHandle.nullDevice
            process.standardOutput=try FileHandle(forWritingTo:URL(fileURLWithPath:log));process.standardError=process.standardOutput
            try process.run();servers.append(process)
            try await wait("server socket") {files.fileExists(atPath:socket)}
        }
        func seed()throws->(String,JSONObject,CodexGoalTransferSlot) {
            let connection=try CodexQueueConnection(home:source.home)
            let started=try connection.request("thread/start",["cwd":work,"threadSource":"user"])
            guard let thread=(started["thread"] as? JSONObject)?["id"] as? String else{throw AppError.message("Owned thread missing")}
            _=try connection.request("thread/name/set",["threadId":thread,"name":"Owned migration keeps this conversation"])
            let goal=try connection.request("thread/goal/set",["threadId":thread,"objective":"Keep paused Goal across login groups","tokenBudget":4321,"status":"paused","origin":"user"])
            return (thread,goal,try CodexGoalTransferStore.captureSlot(home:source.home,threadID:thread))
        }
        // The setup RPC is released before the application's client census.
        let (thread,goal,goalBefore)=try seed()
        let manager=ManagedPTYManager(environment:environment(source.home))
        defer{manager.stop()}
        let descriptor=try manager.create(cwd:work,program:"shell",command:["/bin/zsh","-f"],columns:120,rows:36)
        let terminal=try manager.terminal(descriptor.ptyID),client=UUID().uuidString
        defer{try? terminal.screen().write(toFile:root+"/owned-screen.txt",atomically:true,encoding:.utf8)}
        var sequence=0
        func input(_ text:String)throws {
            sequence+=1;try terminal.input(Data(text.utf8),streamID:descriptor.streamID,client:client,sequence:sequence)
        }
        try await wait("empty shell") {SessionExitRecovery.emptyShellPrompt(terminal.screen())}
        let command=[cli,"--remote","unix://","--no-alt-screen","-C",work,"resume",thread]
        try input(command.map(HookInstaller.quote).joined(separator:" ")+"\n")
        let shellPID=descriptor.pid
        let reader:@Sendable()throws->[ProcessRecord]={
            let records=try ProcessDiscovery.read(),index=ProcessDiscovery.index(records)
            return records.filter{$0.pid==shellPID || ProcessDiscovery.ancestors(of:$0.parent,byPID:index).contains(where:{$0.pid==shellPID})}
        }
        let targetReader:@Sendable([ProcessRecord])async throws->[CodexAccountTransitionTarget]={records in
            try [source,destination].compactMap {group in
                let home=try CodexAccountTransitionTarget.canonicalHome(group.home)
                let witnesses=records.filter{$0.agent == .codex && CodexServerLocation.connectedHome(pid:$0.pid,hints:[home])==home}
                    .map{CodexAccountTransitionWitness(pid:$0.pid,started:$0.started,tty:"/dev/"+$0.tty,threadID:thread)}
                return witnesses.isEmpty ? nil:.init(home:home,executable:cli,witnesses:witnesses)
            }
        }
        let engine=try ApprovalEngine(paths:.init(directory:app),processReader:reader,managedPTY:manager,
            codexAccountTargets:targetReader)
        defer{try? JSONEncoder().encode(engine.snapshot).write(to:URL(fileURLWithPath:root+"/owned-state.json"))}
        defer{engine.stop()}
        var original:AgentSession?
        var keptPaused=false
        try await wait("source TUI",seconds:25) {
            await engine.refresh()
            original=engine.snapshot.sessions.first{$0.agent == .codex && $0.phase != .ended}
            if !keptPaused,terminal.screen().contains("Resume paused goal?") {
                // The owned source starts paused; explicitly retain that choice.
                keptPaused=true;try input("\u{1b}[B\r")
            }
            return original != nil && CodexGoalScreen.ready(terminal.screen())
        }
        guard let original else{throw AppError.message("Owned source session missing")}
        // Respect the manager's three-second user-input writer reservation.
        try await Task.sleep(for:.seconds(3))
        try mark("source-ready")
        let plan=try await engine.prepareCodexSessionMove(sessionID:original.id,destinationHome:destination.home)
        try mark("move-prepared")
        guard plan.conversationCount==1 else{throw AppError.message("Unexpected selected scope")}
        let result=try await engine.performCodexSessionMove(id:plan.id)
        try mark("move-result-"+result.phase.rawValue)
        guard result.phase == .connected else{throw AppError.message(result.detail)}
        let target=try CodexQueueConnection(home:destination.home)
        let goalAfter=try target.request("thread/goal/get",["threadId":thread])
        guard NSDictionary(dictionary:goal)==NSDictionary(dictionary:goalAfter),
              try CodexGoalTransferStore.captureSlot(home:destination.home,threadID:thread).row?.goalID==goalBefore.row?.goalID,
              try engine.codexSessionMoveRecoveries().isEmpty,
              let next=try reader().first(where:{$0.agent == .codex && $0.key != original.id}),
              "/dev/"+next.tty==original.tty,
              CodexServerLocation.connectedHome(pid:next.pid,hints:[destination.home])==(try CodexAccountTransitionTarget.canonicalHome(destination.home)) else {
            throw AppError.message("Owned move completion/Goal/same-terminal check failed")
        }
        let report:[String:Any]=["verified":true,"applicationMoveAPI":true,"realCLIAndServers":true,
            "sameShellAndTTY":true,"sameConversation":true,"pausedGoalIdentityPreserved":true,
            "completedRecoveryCleared":true,"modelTurnsSubmitted":0]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:URL(fileURLWithPath:root+"/report.json"));print(String(decoding:data,as:UTF8.self))
    }
}
