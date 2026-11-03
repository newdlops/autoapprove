import Foundation
import CoreGraphics
import AutoApproveCore
import TerminalInputSupport
import CSQLite

private final class OwnedEnginePTY:@unchecked Sendable {
    let terminal:ManagedPTY,descriptor:ManagedPTYDescriptor
    var noShell=false,includeLoginAncestor=false,wrongWindow=false,busyReplacement=false,prepareFails=false,definiteRetry=false,addHostDuringPrepare=false,lingerToolHost=false
    var trackedHosts:[ProcessRecord]=[]
    var manager:ManagedPTYManager?,replacement:OwnedEnginePTY?
    let client=UUID().uuidString
    private let lock=NSLock()
    private var sequence=0
    var nativeAvailable=true,interruptWrites=0,losePauseAck=false
    var keyboardAvailable=false,keyboardPosts=0,permissionRequests=0
    var delayedStatus=false,workingReads=0
    var interruptCalls=0,pauseCalls=0
    var statusCalls=0,exitCalls=0,launchCalls=0,prepareCalls=0
    init(_ terminal:ManagedPTY,_ descriptor:ManagedPTYDescriptor){self.terminal=terminal;self.descriptor=descriptor}
    func write(_ text:String)throws {lock.lock();defer{lock.unlock()};sequence+=1;try terminal.input(Data(text.utf8),streamID:descriptor.streamID,client:client,sequence:sequence)}
    func screen(_ tty:String)->String {let raw=tty==descriptor.tty ? terminal.screen():replacement?.terminal.screen() ?? "";if delayedStatus,raw.contains("Session:"){workingReads+=1;return raw.replacingOccurrences(of:"Working (1s",with:"Working (\(min(workingReads,2))s")};return raw}
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
    func directInterrupt(_ target:ScreenTarget,_ expected:String)throws->TerminalDelivery {
        self.interruptCalls+=1
        return try TerminalDeviceInput.deliver(target:target,agent:.codex,input:.init(kind:.escape),screen:expected,environment:.init(available:{true},capture:{try TTYInputIdentity.capture(pid:$0)},send:{request in
            guard request.tty==self.descriptor.tty,request.identity.pid==target.sourcePID else{throw AppError.message("Wrong owned transport target")}
            self.interruptWrites+=1
            try self.write(String(decoding:request.bytes,as:UTF8.self));if self.losePauseAck {throw AppError.message("Owned interrupt acknowledgement lost")};return .init(error:0,written:request.bytes.count)
        }))
    }
    func keyboardInterrupt(_ target:ScreenTarget,_ expected:String)throws->TerminalDelivery {
        self.interruptCalls+=1
        let env=TerminalKeyboard.Environment(trusted:{true},postingAllowed:{true},run:{_ in "ready:77"},
            metadata:{tty in .init(tty:tty,windowID:77,ownerPID:990001,ownerBundleID:"com.apple.Terminal",selected:true,minimized:false)},
            ownerBundle:{_ in "com.apple.Terminal"},focused:{_ in !self.wrongWindow},processes:{self.read()},postPair:{pid,down,up in
                guard pid==990001,down.getIntegerValueField(.keyboardEventKeycode)==53,down.flags.isEmpty,up.flags.isEmpty else{throw AppError.message("Wrong Goal keyboard event")}
                self.keyboardPosts+=1;self.interruptWrites+=1
                try self.write("\u{1b}")
                if self.losePauseAck {throw AppError.message("Owned keyboard acknowledgement lost")}
            })
        return try TerminalGoalInterrupt.keyboard(target:target,expected:expected,environment:env,userHasPriority:{false})
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
            if input.kind == .escape {
                return try self.directInterrupt(target,expected)
            }
            else if input.text=="/goal pause" {self.pauseCalls+=1}
            else if input.text=="/status" {self.statusCalls+=1;if self.delayedStatus,self.statusCalls==1 {Thread.sleep(forTimeInterval:11)}}
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
        },goalInterrupt:{target,expected in
            try TerminalGoalInterrupt.deliver(target:target,expected:expected,environment:.init(directAvailable:{self.nativeAvailable},keyboardAvailable:{self.keyboardAvailable},direct:{try self.directInterrupt($0,$1)},keyboard:{try self.keyboardInterrupt($0,$1)},requestPermission:{self.permissionRequests+=1}))
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
        let manualGoal=CommandLine.arguments.contains("--manual-goal"),pauseUnconfirmed=CommandLine.arguments.contains("--pause-unconfirmed"),existingManaged=CommandLine.arguments.contains("--existing-managed"),nativeGoalFailure=CommandLine.arguments.contains("--native-goal-failure"),nativeGoal=CommandLine.arguments.contains("--native-goal"),replaceManager=CommandLine.arguments.contains("--replace-login-manager"),idleGoal=CommandLine.arguments.contains("--idle-goal"),pausedGoal=CommandLine.arguments.contains("--paused-goal"),retryGoal=CommandLine.arguments.contains("--retry-goal"),vimGoal=CommandLine.arguments.contains("--vim-goal"),delayedStatus=CommandLine.arguments.contains("--delayed-goal-status"),missingInputRetry=CommandLine.arguments.contains("--missing-input-retry"),unknownGoalAck=CommandLine.arguments.contains("--unknown-goal-ack")
        if goalWait || manualGoal {try goal(pausedGoal ? "paused":"active")}
        var ownedEnvironment=["HOME":root,"CODEX_HOME":home,"PATH":root+":/usr/bin:/bin","PS1":"fixture% ","READY_FILE":root+"/ready","FIXTURE_SOCKET":root+"/daemon.sock","EXPECTED_THREAD":thread,"STATUS_THREAD":wrong ? "00000000-0000-4000-8000-000000000062":thread,"TOOL_HOST_PATH":toolHosts ? root+"/ChatGPT.app/Contents/Resources/cua_node/bin/node":""]
        if manualGoal {ownedEnvironment["FIXTURE_ACTIVE_GOAL"]="1"}
        if vimGoal {ownedEnvironment["FIXTURE_VIM_GOAL"]="1"}
        if idleGoal {ownedEnvironment["FIXTURE_GOAL_IDLE"]="1"}
        if pausedGoal {ownedEnvironment["FIXTURE_GOAL_PAUSED"]="1"}
        if pauseUnconfirmed {ownedEnvironment["IGNORE_GOAL_PAUSE"]="1"}
        if lingerToolHost {ownedEnvironment["LINGER_TOOL_HOST_AFTER_EXIT"]="1"}
        let manager=ManagedPTYManager(environment:ownedEnvironment);defer{manager.stop()}
        let descriptor=try manager.create(cwd:root,program:"shell",command:noShell ? [root+"/codex"]:(loginShell ? [root+"/codex","--fixture-login-shell"]:["/bin/zsh","-f"]),columns:100,rows:50),terminal=try manager.terminal(descriptor.ptyID),probe=OwnedEnginePTY(terminal,descriptor)
        func wait(_ test:()throws->Bool) async throws {let end=Date().addingTimeInterval(8);while Date()<end{if try test(){return};try await Task.sleep(for:.milliseconds(100))};throw AppError.message("Owned fixture not ready")}
        probe.losePauseAck=unknownGoalAck;probe.delayedStatus=delayedStatus;probe.noShell=noShell;probe.manager=manager;probe.wrongWindow=wrongWindow;probe.busyReplacement=busyReplacement;probe.prepareFails=prepareFails;probe.definiteRetry=definiteRetry;probe.addHostDuringPrepare=cancelBeforeExit;probe.lingerToolHost=lingerToolHost
        if !noShell {
            try await wait{SessionExitRecovery.emptyShellPrompt(terminal.screen())}
            let command=profileCommand ? try TerminalProfileEntry(title:"Owned fixture",agent:"codex",cwd:root,conversationID:"",providerHome:home).resumeCommand():HookInstaller.quote(root+"/codex")
            try probe.write(command+"\n")
        }
        try await wait{manualGoal && !idleGoal && !pausedGoal ? CodexProgressScreen.workingFingerprint(terminal.screen()) != nil:CodexGoalScreen.ready(terminal.screen())}
        if loginShell {guard probe.read().contains(where:{$0.pid==descriptor.pid && $0.executable=="-zsh"}) else{throw AppError.message("Expected real login-shell argv identity")}}
        guard let original=probe.read().first(where:{$0.agent == .codex}) else{throw AppError.message("Owned Codex not found")}
        guard try ProcessOpenFiles.codexRolloutPaths(pid:original.pid,expectedStart:original.started).isEmpty else{throw AppError.message("Fixture must have no JSONL")}
        let setup=CodexManagedServerServices(inspect:{selected,_ in .init(phase:selected==home ? .running:.unavailable,version:"0.166.0",detail:"Owned fixture",autoStartEnabled:true)},prepare:{_,_ in throw AppError.message("Must not prepare")})
        var accountObservations=0,restarts=0,resumes=0,verifiedAccount=false
        let accountServices=CodexAccountTransitionServices(observe:{_ in
            accountObservations+=1
            guard probe.exitCalls==1 && probe.launchCalls==1 || nativeGoalFailure && !probe.read().contains(where:{$0.key==original.key}) else{throw AppError.message("Account check preceded original-session attachment")}
            let stopped=manualGoal ? try CodexGoalTransport.readDatabase(home:home,threadID:thread):nil
            return .init(savedAccount:"fixture",serverAccount:"fixture",serverID:restarts>0 ? "fixture-new":"fixture",threads:manualGoal ? [.init(id:thread,turnID:"owned-turn",continuable:true,cwd:root,modelProvider:"openai",goal:stopped,turnStatus:"interrupted")]:[])
        },interrupt:{_,_,_,_ in throw AppError.message("Unexpected fixture interrupt")},restart:{_,_ in guard manualGoal else{throw AppError.message("Fixture account server must not restart")};restarts+=1},verify:{_,_,_ in verifiedAccount=true;return 1},resume:{_,_,original,_ in
            guard manualGoal,verifiedAccount,restarts==1,original.goal?.status == .active,try CodexGoalTransport.readDatabase(home:home,threadID:thread)?.status == .paused else{throw AppError.message("Goal resumed before account verification")}
            resumes+=1;try goal("active");return .goal
        })
        @MainActor func createEngine() throws -> ApprovalEngine {try ApprovalEngine(paths:.init(directory:URL(fileURLWithPath:root+"/state")),processReader:{probe.read()},screenAdapters:[.terminal:probe.adapter()],terminalInputAvailable:{probe.nativeAvailable},codexAccountTransitions:accountServices,codexAccountTargets:{rows in
            var targets=try await CodexAccountTransitionTarget.discover(rows)
            if existingManaged,targets.isEmpty {targets=[.init(home:home,executable:root+"/codex",witnesses:[.init(pid:990099,started:"owned-existing",tty:"/dev/owned-existing",threadID:nil)])]}
            return targets
        },codexManagedServers:setup)}
        let engine=try createEngine()
        if CommandLine.arguments.contains("--keyboard-goal") || CommandLine.arguments.contains("--keyboard-focus") {probe.nativeAvailable=false;probe.keyboardAvailable=true}
        defer{engine.stop()}
        func beginOwnedLogin() throws {
            let login=AgentAccountServices(home:root,check:{_ in .init(agent:"codex",phase:"authenticated")},launch:{_ in try ManagedPTY(cwd:root,command:["/bin/zsh","-f","-c","exit 0"],environment:["HOME":root,"PATH":"/usr/bin:/bin"])})
            engine.agentAccounts=AgentAccounts(services:login,codexServices:{_ in login})
            try engine.setCodexAccountTransitionEnabled(true)
            try engine.agentAccounts.beginNativeCodexLogin(.init(home:home,executable:root+"/codex"))
        }
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
        guard engine.snapshot.sessions.contains(where:{$0.id==original.key && $0.terminal == .terminal && $0.phase == (pausedGoal ? .unknown:manualGoal && !idleGoal ? .working:.idle)}) else{throw AppError.message("Owned engine inventory: "+engine.snapshot.sessions.map{"pid=\($0.pid) host=\($0.terminal.rawValue) phase=\($0.phase.rawValue)"}.joined(separator:",")+" screen="+terminal.screen())}
        if CommandLine.arguments.contains("--keyboard-focus") {
            probe.wrongWindow=true
            var rejected=false
            do {try await engine.reconnectCodexLogin(home:home)}catch {rejected=true}
            guard rejected,probe.interruptWrites==0,probe.keyboardPosts==0,probe.exitCalls==0,try CodexGoalTransport.readDatabase(home:home,threadID:thread)?.status == .active else{throw AppError.message("Changed focused window must not receive Goal keys")}
            print("{\"verified\":true,\"focusChangePreserved\":true,\"interruptWrites\":0,\"exitRequests\":0,\"userTerminalActions\":0}");return
        }
        if unknownGoalAck {
            var rejected=false
            do {try await engine.reconnectCodexLogin(home:home)}catch {rejected=true}
            try await wait{try CodexGoalTransport.readDatabase(home:home,threadID:thread)?.status == .paused}
            for _ in 0..<3 {await engine.ensureCodexManagedServers()}
            do {try await engine.reconnectCodexLogin(home:home)}catch {}
            guard rejected,probe.interruptWrites==1,probe.interruptCalls==1,probe.exitCalls==0 else{throw AppError.message("Unknown input acknowledgement was replayed")}
            print("{\"verified\":true,\"unknownAckNotReplayed\":true,\"interruptWrites\":1,\"exitRequests\":0,\"userTerminalActions\":0}");return
        }
        if vimGoal {
            do {try await engine.reconnectCodexLogin(home:home)}catch {}
            guard probe.statusCalls==0,probe.interruptCalls==0,probe.exitCalls==0,try CodexGoalTransport.readDatabase(home:home,threadID:thread)?.status == .active else{throw AppError.message("Standalone Goal reconnect typed into Vim Normal mode")}
            print("{\"verified\":true,\"vimInputPreserved\":true,\"userTerminalActions\":0}");return
        }
        if manualGoal,prepareFails,existingManaged {
            if nativeGoalFailure {
                try beginOwnedLogin()
                try await wait{engine.agentAccounts.nativeCodexLogin?.phase=="succeeded"}
                let deadline=Date().addingTimeInterval(20)
                while Date()<deadline,engine.codexAccountTransitionNotice?.contains("로그인은 완료됐지만 기존 세션 연결이 보류") != true {try await Task.sleep(for:.milliseconds(100))}
                for _ in 0..<4 {await engine.checkCodexAccountTransitions()}
                guard accountObservations==0,probe.exitCalls==0 else{throw AppError.message("Failed native Goal attachment fell through to account rotation")}
                engine.stop();let restored=try createEngine();defer{restored.stop()}
                for _ in 0..<4 {await restored.checkCodexAccountTransitions()}
                guard accountObservations==0 else{throw AppError.message("Native attachment failure hold was lost after restore")}
                manager.stop();let before=accountObservations
                try await restored.reconnectCodexLogin(home:home)
                guard accountObservations>before,restored.codexAccountTransitionStates[home]?.loginRequestID != nil,resumes==0 else{throw AppError.message("Closed original Goal review blocked a fresh explicit managed reconnect")}
                print("{\"verified\":true,\"nativeFailureHeld\":true,\"restoredHold\":true,\"closedOriginalRecovered\":true,\"userTerminalActions\":0}");return
            }
            var rejected=false
            do {try await engine.reconnectCodexLogin(home:home)}catch {rejected=true}
            guard rejected,accountObservations==0,probe.exitCalls==0 else{throw AppError.message("Failed Goal attachment must prevent account rotation with an existing managed window")}
            print("{\"verified\":true,\"mixedFailureHeld\":true,\"accountObservations\":0,\"userTerminalActions\":0}");return
        }
        if manualGoal,pauseUnconfirmed {
            let task:Task<Void,Error>?
            if replaceManager {try beginOwnedLogin();task=nil}else{task=Task {try await engine.reconnectCodexLogin(home:home)}}
            try await wait{probe.interruptCalls==1 && engine.codexSessionAttachmentNotice?.contains("실제 대기 상태") == true && !engine.codexAccountTransitionBusy}
            if replaceManager {engine.agentAccounts=AgentAccounts()}else{task?.cancel()}
            if let task {do {try await task.value;throw AppError.message("Expected request cancellation")}catch is CancellationError {}}
            try probe.write("/fixture-finish-pause\n")
            try await wait{CodexGoalScreen.ready(terminal.screen())}
            engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
            try await Task.sleep(for:.seconds(2))
            engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
            for _ in 0..<6 {await engine.ensureCodexManagedServers();try await Task.sleep(for:.milliseconds(700))}
            guard probe.exitCalls==0,probe.prepareCalls==0,probe.interruptCalls==1 else{throw AppError.message("Cancelled Goal request continued into automatic exit")}
            if retryGoal {try await engine.reconnectCodexLogin(home:home);guard probe.exitCalls==1,probe.interruptCalls==1 else{throw AppError.message("Explicit retry must not interrupt again")}}
            print("{\"verified\":true,\"cancelledGoalPreserved\":true,\"managerReplaced\":\(replaceManager),\"explicitRetry\":\(retryGoal),\"interrupts\":\(probe.interruptCalls),\"exitRequests\":\(probe.exitCalls),\"userTerminalActions\":0}");return
        }
        if manualGoal {
            if missingInputRetry {
                probe.nativeAvailable=false
                var rejected=false
                do {try await engine.reconnectCodexLogin(home:home)}catch {rejected=true}
                guard rejected,probe.permissionRequests==1,probe.interruptWrites==0,probe.interruptCalls==0,try CodexGoalTransport.readDatabase(home:home,threadID:thread)?.status == .active else{throw AppError.message("Unavailable input must not write or stop Goal")}
                probe.nativeAvailable=true
            }
            if nativeGoal {try beginOwnedLogin()}
            let task=Task {if nativeGoal {
                let end=Date().addingTimeInterval(22);while engine.codexAccountTransitionStates[home]?.loginRequestID==nil,Date()<end {try await Task.sleep(for:.milliseconds(100))}
                guard engine.codexAccountTransitionStates[home]?.loginRequestID != nil else{throw AppError.message("Native Goal reconnect did not reach account handoff")}
            }else{try await engine.reconnectCodexLogin(home:home)}}
            let timeout=Task {try await Task.sleep(for:.seconds(delayedStatus ? 40:25));task.cancel()};defer{timeout.cancel()}
            do {try await task.value}catch {throw AppError.message("Running Goal reconnect did not pause and attach: "+error.localizedDescription)}
            guard probe.interruptWrites==(idleGoal || pausedGoal ? 0:1),probe.interruptCalls==(idleGoal || pausedGoal ? 0:1),probe.pauseCalls==(idleGoal && !pausedGoal ? 1:0),probe.exitCalls==1,probe.launchCalls==1,(try CodexGoalTransport.readDatabase(home:home,threadID:thread)?.status == .paused || nativeGoal && resumes==1) else{throw AppError.message("Goal must actually pause before a single exit and resume")}
            for _ in 0..<12 {await engine.checkCodexAccountTransitions()}
            guard restarts==1,resumes==(pausedGoal ? 0:1),try CodexGoalTransport.readDatabase(home:home,threadID:thread)?.status == (pausedGoal ? .paused:.active) else{throw AppError.message("Goal did not resume exactly once after account verification: restart=\(restarts) resume=\(resumes)")}
            print("{\"verified\":true,\"pausedGoalBeforeAttachment\":true,\"goalResumedAfterLogin\":\(resumes==1),\"goalInitiallyPaused\":\(pausedGoal),\"nativeLogin\":\(nativeGoal),\"goalPauseCommands\":\(probe.pauseCalls),\"interrupts\":\(probe.interruptCalls),\"interruptWrites\":\(probe.interruptWrites),\"keyboardPosts\":\(probe.keyboardPosts),\"retryAfterUnavailable\":\(missingInputRetry),\"exitRequests\":1,\"launchRequests\":1,\"userTerminalActions\":0}");return
        }
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
