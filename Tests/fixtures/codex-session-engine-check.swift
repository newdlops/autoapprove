import Foundation
import AutoApproveCore
import CSQLite

private final class OwnedEnginePTY:@unchecked Sendable {
    let terminal:ManagedPTY,descriptor:ManagedPTYDescriptor
    var noShell=false,includeLoginAncestor=false,wrongWindow=false,busyReplacement=false,prepareFails=false,definiteRetry=false,addHostDuringPrepare=false,lingerToolHost=false
    var trackedHosts:[ProcessRecord]=[]
    var manager:ManagedPTYManager?,replacement:OwnedEnginePTY?
    let client=UUID().uuidString
    private let lock=NSLock()
    private var sequence=0
    var statusCalls=0,exitCalls=0,launchCalls=0,prepareCalls=0
    init(_ terminal:ManagedPTY,_ descriptor:ManagedPTYDescriptor){self.terminal=terminal;self.descriptor=descriptor}
    func write(_ text:String)throws {lock.lock();defer{lock.unlock()};sequence+=1;try terminal.input(Data(text.utf8),streamID:descriptor.streamID,client:client,sequence:sequence)}
    func screen(_ tty:String)->String {tty==descriptor.tty ? terminal.screen():replacement?.terminal.screen() ?? ""}
    func read()->[ProcessRecord] {
        let host=ProcessDiscovery.parse("990001 1 ?? 990001 0 Mon Nov 2 10:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")[0]
        var records=((try? ProcessDiscovery.read()) ?? []).filter {row in "/dev/"+row.tty==descriptor.tty || self.trackedHosts.contains(where:{$0.key==row.key})}
        if noShell || includeLoginAncestor {
            let login=ProcessDiscovery.parse(String(noShell ? 990002:990003)+" 990001 "+descriptor.tty.replacingOccurrences(of:"/dev/",with:"")+" "+String(descriptor.pid)+" "+String(descriptor.pid)+" Mon Nov 2 10:00:00 2026 login")[0]
            if let i=records.firstIndex(where:{$0.pid==descriptor.pid}) {records[i].parent=login.pid}
            records.insert(login,at:0)
        } else if let i=records.firstIndex(where:{$0.pid==descriptor.pid}) {records[i].parent=host.pid}
        return [host]+records+(replacement?.read() ?? [])
    }
    func adapter()->ScreenHostAdapter {
        ScreenHostAdapter(screens:{targets in TerminalSnapshot(screens:targets.map{TerminalScreen(tty:$0.tty,contents:self.screen($0.tty))})},approve:{_,_,_ in .screenChanged},reveal:{_ in nil},restart:{target,expected,command in
            guard self.screen(target.tty)==expected,SessionExitRecovery.emptyShellPrompt(expected) else{return .screenChanged}
            if self.lingerToolHost,self.trackedHosts.contains(where:{host in (try? ProcessDiscovery.read(pid:host.pid))?.contains(where:{$0.key==host.key}) == true}) {throw AppError.message("Launch preceded actual tool-host shutdown")}
            self.launchCalls+=1
            let receiver=target.tty==self.descriptor.tty ? self:self.replacement!
            try receiver.write(command+"\n");return .sent
        },input:{target,expected,_,input in
            guard self.screen(target.tty)==expected else{return .screenChanged}
            if input.text=="/status" {self.statusCalls+=1}
            else if input.text=="/exit" {self.exitCalls+=1}
            else {throw AppError.message("Unexpected owned fixture input")}
            try self.write(input.bytes);return .sent
        },replacementShell:{target in
            self.prepareCalls+=1
            if self.definiteRetry,self.prepareCalls==1 {throw RemoteHTTPError(409,"Owned preparation definitely not started",diagnostics:["delivery":"not_started"])}
            guard self.noShell,self.exitCalls==0,self.replacement==nil,let manager=self.manager,!self.prepareFails else{throw AppError.message("Owned replacement preparation failed")}
            let descriptor=try manager.create(cwd:self.descriptor.cwd,program:"shell",command:["/bin/zsh","-f"],columns:100,rows:50)
            let child=OwnedEnginePTY(try manager.terminal(descriptor.ptyID),descriptor);child.includeLoginAncestor=true;self.replacement=child
            let deadline=Date().addingTimeInterval(5)
            while !SessionExitRecovery.emptyShellPrompt(child.terminal.screen()),Date()<deadline {Thread.sleep(forTimeInterval:0.05)}
            guard SessionExitRecovery.emptyShellPrompt(child.terminal.screen()),let shell=child.read().first(where:{$0.pid==descriptor.pid}) else{throw AppError.message("Owned replacement shell missing")}
            if self.addHostDuringPrepare {
                try self.write("/fixture-extra-host\n")
                let deadline=Date().addingTimeInterval(3)
                while Date()<deadline {
                    let rows=self.read()
                    if let root=rows.first(where:{$0.pid==self.descriptor.pid}),CodexSessionAttachment.toolHosts(process:root,records:rows).count==2 {break}
                    Thread.sleep(forTimeInterval:0.05)
                }
            }
            if self.busyReplacement {try child.write("UNSENT-DRAFT");Thread.sleep(forTimeInterval:0.1)}
            return shell
        },replacementShellValid:{_,shell in
            !self.wrongWindow && self.replacement?.read().contains(where:{$0==shell}) == true
        })
    }
}

@main struct EngineAttachmentCheck {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath().path
        let home=try CodexAccountTransitionTarget.canonicalHome(root+"/home/.codex"),thread="00000000-0000-4000-8000-000000000061",red=CommandLine.arguments.contains("--expect-unresolved"),wrong=CommandLine.arguments.contains("--wrong-thread"),goalWait=CommandLine.arguments.contains("--goal-wait"),loginShell=CommandLine.arguments.contains("--login-shell"),manual=CommandLine.arguments.contains("--manual-reconnect"),screenOff=CommandLine.arguments.contains("--screen-disconnected"),noShell=CommandLine.arguments.contains("--no-shell"),wrongWindow=CommandLine.arguments.contains("--wrong-window"),busyReplacement=CommandLine.arguments.contains("--busy-replacement"),prepareFails=CommandLine.arguments.contains("--prepare-fails"),profileCommand=CommandLine.arguments.contains("--profile-command"),definiteRetry=CommandLine.arguments.contains("--definite-retry"),toolHosts=CommandLine.arguments.contains("--tool-hosts"),autoToolWait=CommandLine.arguments.contains("--auto-tool-wait"),cancelBeforeExit=CommandLine.arguments.contains("--cancel-before-exit") || CommandLine.arguments.contains("--cancel-and-retry"),cancelAndRetry=CommandLine.arguments.contains("--cancel-and-retry"),lingerToolHost=CommandLine.arguments.contains("--linger-tool-host")
        func goal(_ status:String)throws {
            var db:OpaquePointer?
            guard sqlite3_open(home+"/goals_1.sqlite",&db)==SQLITE_OK else{throw AppError.message("Owned Goal database failed")}
            defer{sqlite3_close(db)}
            let sql="CREATE TABLE IF NOT EXISTS thread_goals(thread_id TEXT PRIMARY KEY,goal_id TEXT,objective TEXT,status TEXT,token_budget INTEGER,tokens_used INTEGER,time_used_seconds INTEGER,created_at_ms INTEGER,updated_at_ms INTEGER); INSERT OR REPLACE INTO thread_goals VALUES('\(thread)','fixture-goal','Owned test','\(status)',NULL,0,0,100000,110000);"
            guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw AppError.message("Owned Goal update failed")}
        }
        if goalWait {try goal("active")}
        var ownedEnvironment=["HOME":root,"CODEX_HOME":home,"PATH":root+":/usr/bin:/bin","PS1":"fixture% ","READY_FILE":root+"/ready","FIXTURE_SOCKET":root+"/daemon.sock","EXPECTED_THREAD":thread,"STATUS_THREAD":wrong ? "00000000-0000-4000-8000-000000000062":thread,"TOOL_HOST_PATH":toolHosts ? root+"/ChatGPT.app/Contents/Resources/cua_node/bin/node":""]
        if lingerToolHost {ownedEnvironment["LINGER_TOOL_HOST_AFTER_EXIT"]="1"}
        let manager=ManagedPTYManager(environment:ownedEnvironment);defer{manager.stop()}
        let descriptor=try manager.create(cwd:root,program:"shell",command:noShell ? [root+"/codex"]:(loginShell ? [root+"/codex","--fixture-login-shell"]:["/bin/zsh","-f"]),columns:100,rows:50),terminal=try manager.terminal(descriptor.ptyID),probe=OwnedEnginePTY(terminal,descriptor)
        func wait(_ test:()throws->Bool) async throws {let end=Date().addingTimeInterval(8);while Date()<end{if try test(){return};try await Task.sleep(for:.milliseconds(100))};throw AppError.message("Owned fixture not ready")}
        probe.noShell=noShell;probe.manager=manager;probe.wrongWindow=wrongWindow;probe.busyReplacement=busyReplacement;probe.prepareFails=prepareFails;probe.definiteRetry=definiteRetry;probe.addHostDuringPrepare=cancelBeforeExit;probe.lingerToolHost=lingerToolHost
        if !noShell {
            try await wait{SessionExitRecovery.emptyShellPrompt(terminal.screen())}
            let command=profileCommand ? try TerminalProfileEntry(title:"Owned fixture",agent:"codex",cwd:root,conversationID:"",providerHome:home).resumeCommand():HookInstaller.quote(root+"/codex")
            try probe.write(command+"\n")
        }
        try await wait{CodexProgressScreen.ready(terminal.screen())}
        if loginShell {guard probe.read().contains(where:{$0.pid==descriptor.pid && $0.executable=="-zsh"}) else{throw AppError.message("Expected real login-shell argv identity")}}
        guard let original=probe.read().first(where:{$0.agent == .codex}) else{throw AppError.message("Owned Codex not found")}
        guard try ProcessOpenFiles.codexRolloutPaths(pid:original.pid,expectedStart:original.started).isEmpty else{throw AppError.message("Fixture must have no JSONL")}
        let setup=CodexManagedServerServices(inspect:{selected,_ in .init(phase:selected==home ? .running:.unavailable,version:"0.166.0",detail:"Owned fixture",autoStartEnabled:true)},prepare:{_,_ in throw AppError.message("Must not prepare")})
        var accountObservations=0
        let accountServices=CodexAccountTransitionServices(observe:{_ in
            guard probe.exitCalls==1,probe.launchCalls==1 else{throw AppError.message("Account check preceded original-session attachment")}
            accountObservations+=1
            return .init(savedAccount:"fixture",serverAccount:"fixture",serverID:"fixture",threads:[])
        },interrupt:{_,_,_,_ in throw AppError.message("Unexpected fixture interrupt")},restart:{_,_ in throw AppError.message("Fixture account server must not restart")},verify:{_,_,_ in 1})
        let engine=try ApprovalEngine(paths:.init(directory:URL(fileURLWithPath:root+"/state")),processReader:{probe.read()},screenAdapters:[.terminal:probe.adapter()],terminalInputAvailable:{true},codexAccountTransitions:accountServices,codexAccountTargets:{try await CodexAccountTransitionTarget.discover($0)},codexManagedServers:setup)
        defer{engine.stop()}
        await engine.refresh()
        if screenOff {
            await engine.ensureCodexManagedServers()
            guard engine.codexSessionAttachmentNotice?.contains("Terminal·iTerm 화면 연결 필요") == true,engine.codexSessionAttachmentNotice?.contains(descriptor.tty.replacingOccurrences(of:"/dev/",with:"")) == true,probe.statusCalls==0,probe.exitCalls==0 else{throw AppError.message("Missing screen connection must identify this terminal")}
            print("{\"verified\":true,\"screenConnectionRequired\":true,\"perTerminalReason\":true,\"userTerminalActions\":0}");return
        }
        await engine.connectScreenHost(.terminal);try engine.setAutomatic(original.key,enabled:true)
        engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
        try await Task.sleep(for:.seconds(2))
        engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
        guard engine.snapshot.sessions.contains(where:{$0.id==original.key && $0.terminal == .terminal && $0.phase == .idle}) else{throw AppError.message("Owned engine inventory: "+engine.snapshot.sessions.map{"pid=\($0.pid) host=\($0.terminal.rawValue) phase=\($0.phase.rawValue)"}.joined(separator:",")+" screen="+terminal.screen())}
        if toolHosts {
            let expected=CodexSessionAttachment.toolHosts(process:original,records:probe.read())
            probe.trackedHosts=expected
            guard expected.count==1,CodexSessionAttachment.hasIndependentChildWork(process:original,records:probe.read()) else{throw AppError.message("Owned independent tool host must be real and block automatic exit")}
        }
        if autoToolWait {
            await engine.ensureCodexManagedServers();await engine.ensureCodexManagedServers()
            guard probe.exitCalls==0,probe.prepareCalls==0,probe.read().contains(where:{$0.key==original.key}) else{throw AppError.message("Automatic discovery may not clean up independent hosts")}
            print("{\"verified\":true,\"automaticToolHostProtection\":true,\"userTerminalActions\":0}");return
        }
        if cancelBeforeExit {
            let task=Task {try await engine.reconnectCodexLogin(home:home)}
            try await wait{engine.codexSessionAttachmentNotice?.contains("같은 창의 빈 복구 탭을 확인했습니다") == true}
            guard probe.exitCalls==0 else{throw AppError.message("New tool host must block original exit")}
            task.cancel()
            do {try await task.value;throw AppError.message("Cancellation must stop the request")}catch is CancellationError {}
            try probe.write("/fixture-remove-extra-host\n")
            try await wait{terminal.screen().contains("New tool host finished")}
            engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
            try await Task.sleep(for:.seconds(2))
            engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
            await engine.ensureCodexManagedServers();await engine.ensureCodexManagedServers()
            guard probe.exitCalls==0,probe.launchCalls==0,probe.prepareCalls==1,probe.read().contains(where:{$0.key==original.key}) else{throw AppError.message("Cancelled cleanup permission leaked into automatic attachment")}
            if cancelAndRetry {
                try await engine.reconnectCodexLogin(home:home)
                guard probe.exitCalls==1,probe.launchCalls==1,probe.prepareCalls==1 else{throw AppError.message("New explicit request must reuse prepared tab and reconnect once")}
                print("{\"verified\":true,\"cancelledGrantProtected\":true,\"newRequestResumed\":true,\"preparedTabs\":1,\"exitRequests\":1,\"launchRequests\":1,\"userTerminalActions\":0}");return
            }
            print("{\"verified\":true,\"cancelledGrantProtected\":true,\"preparedTabs\":1,\"exitRequests\":0,\"userTerminalActions\":0}");return
        }
        if goalWait {
            await engine.ensureCodexManagedServers()
            guard probe.statusCalls==1,probe.exitCalls==0,engine.codexSessionAttachmentNotice?.contains("활성 Goal") == true else{throw AppError.message("Active Goal must wait")}
            try goal("complete");try probe.write("/fixture-progress\n")
            try await wait{terminal.screen().contains("Goal completed")}
            engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
            try await Task.sleep(for:.seconds(2))
            engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
        }
        if definiteRetry {
            await engine.ensureCodexManagedServers()
            guard probe.prepareCalls==1,probe.exitCalls==0,probe.replacement==nil else{throw AppError.message("A not-started preparation must preserve the original")}
            try await engine.reconnectCodexLogin(home:home)
        }
        if manual {
            do {try await engine.reconnectCodexLogin(home:home)}catch {
                if prepareFails {
                    guard error.localizedDescription.contains("기존 세션 연결을 완료하지 못했습니다"),probe.prepareCalls==1,probe.exitCalls==0,probe.read().contains(where:{$0.key==original.key}) else{throw AppError.message("Preparation failure must report its actual stage and preserve original")}
                    print("{\"verified\":true,\"explicitPreparationFailureReported\":true,\"originalPreserved\":true,\"exitRequests\":0,\"userTerminalActions\":0}");return
                }
                throw AppError.message("Manual connection failed: "+(engine.codexSessionAttachmentNotice ?? "none")+" · "+error.localizedDescription)
            }
            guard accountObservations>0 else{throw AppError.message("Manual reconnect must reach account check after attachment")}}
        let deadline=Date().addingTimeInterval(red || wrong || wrongWindow || busyReplacement || prepareFails ? 3:20)
        var attached=false
        repeat {
            engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
            await engine.ensureCodexManagedServers()
            attached=try await engine.codexLoginTargets().contains(where:{$0.home==home && $0.witnesses.contains(where:{$0.pid != original.pid})})
            if attached,engine.codexSessionAttachmentNotice?.contains("기존 창·같은 대화의 관리형 서버 연결을 확인했습니다.") == true {break};try await Task.sleep(for:.milliseconds(150))
        }while Date()<deadline
        if red {
            guard !attached,probe.statusCalls==0,probe.exitCalls==0,engine.codexSessionAttachmentNotice?.contains(loginShell || noShell ? "원본 셸":"대화 ID") == true else{throw AppError.message("Expected SQLite-only discovery failure not reproduced: \(engine.codexSessionAttachmentNotice ?? "none") inventory=\(engine.snapshot.sessions.map{"\($0.phase.rawValue) pending=\($0.pendingInTerminal) review=\($0.needsReview)"})")}
        } else if wrongWindow || busyReplacement || prepareFails {
            guard !attached,probe.prepareCalls==1,probe.exitCalls==0,probe.launchCalls==0,probe.read().contains(where:{$0.key==original.key}) else{throw AppError.message("Replacement failure must preserve the original and never reopen a tab")}
        } else if wrong {
            guard !attached,probe.statusCalls==1,probe.exitCalls==0,probe.launchCalls==0,probe.read().contains(where:{$0.key==original.key}) else{throw AppError.message("Mismatched thread must retain the original process")}
        } else {
            guard attached,engine.codexSessionAttachmentNotice?.contains("기존 창·같은 대화의 관리형 서버 연결을 확인했습니다.") == true,probe.statusCalls==(goalWait ? 2:1),probe.exitCalls==1,probe.launchCalls==1 else{throw AppError.message("Engine attachment failed: "+(engine.codexSessionAttachmentNotice ?? "none")+" status=\(probe.statusCalls) exit=\(probe.exitCalls) launch=\(probe.launchCalls)")}
        }
        print("{\"verified\":true,\"productionEngine\":true,\"sqliteOnly\":true,\"expectedUnresolved\":\(red),\"mismatchedThread\":\(wrong),\"goalWait\":\(goalWait),\"loginShell\":\(loginShell),\"noShell\":\(noShell),\"profileCommand\":\(profileCommand),\"preparationAttempts\":\(probe.prepareCalls),\"preparedTabs\":\(probe.replacement == nil ? 0:1),\"definiteRetry\":\(definiteRetry),\"toolHosts\":\(toolHosts),\"waitedForToolHostExit\":\(lingerToolHost),\"replacementRejected\":\(wrongWindow || busyReplacement || prepareFails),\"manualReconnect\":\(manual),\"accountObservations\":\(accountObservations),\"statusRequests\":\(probe.statusCalls),\"exitRequests\":\(probe.exitCalls),\"launchRequests\":\(probe.launchCalls),\"userTerminalActions\":0}")
    }
}
