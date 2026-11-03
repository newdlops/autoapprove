import Foundation
import AutoApproveCore
import CSQLite

private final class AttachmentTimeline:@unchecked Sendable {
    private let lock=NSLock();private var rows:[String]=[]
    func append(_ value:String){lock.lock();rows.append(value);lock.unlock()}
    var events:[String]{lock.lock();defer{lock.unlock()};return rows}
}
@main struct MultiAttachmentCheck {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath().path,home=root+"/home/.codex"
        let ids=["00000000-0000-4000-8000-000000000061","00000000-0000-4000-8000-000000000062"]
        func setGoal(_ id:String,_ status:String)throws {
            var db:OpaquePointer?;guard sqlite3_open(home+"/goals_1.sqlite",&db)==SQLITE_OK else{throw AppError.message("Owned database unavailable")};defer{sqlite3_close(db)}
            let sql="CREATE TABLE IF NOT EXISTS thread_goals(thread_id TEXT PRIMARY KEY,goal_id TEXT,objective TEXT,status TEXT,token_budget INTEGER,tokens_used INTEGER,time_used_seconds INTEGER,created_at_ms INTEGER,updated_at_ms INTEGER); INSERT OR REPLACE INTO thread_goals VALUES('\(id)','goal-\(id)','Objective \(id)','\(status)',NULL,0,0,100000,110000);"
            guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw AppError.message("Owned database write failed")}
        }
        func wait(_ test:()throws->Bool)async throws {
            let end=Date().addingTimeInterval(8)
            while Date()<end {if try test(){return};try await Task.sleep(for:.milliseconds(100))}
            throw AppError.message("Owned multi-session fixture not ready")
        }
        let timeline=AttachmentTimeline()
        var managers:[ManagedPTYManager]=[],probes:[OwnedEnginePTY]=[],originals:[AgentSession]=[]
        defer{for manager in managers{manager.stop()}}
        for (i,id) in ids.enumerated() {
            try setGoal(id,"active")
            let env=["HOME":root,"CODEX_HOME":home,"PATH":root+":/usr/bin:/bin","PS1":"fixture% ","READY_FILE":root+"/ready-\(i)","FIXTURE_SOCKET":root+"/daemon.sock","EXPECTED_THREAD":id,"FIXTURE_ACTIVE_GOAL":"1"]
            let manager=ManagedPTYManager(environment:env);managers.append(manager)
            let descriptor=try manager.create(cwd:root,program:"shell",command:["/bin/zsh","-f"],columns:100,rows:50)
            let terminal=try manager.terminal(descriptor.ptyID),probe=OwnedEnginePTY(terminal,descriptor)
            probe.manager=manager;probe.nativeAvailable=true;probe.keyboardAvailable=true
            probe.event={timeline.append("\(i):"+$0)}
            try await wait{SessionExitRecovery.emptyShellPrompt(terminal.screen())}
            try probe.write(HookInstaller.quote(root+"/codex")+"\n")
            try await wait{CodexGoalScreen.workingReady(terminal.screen())}
            guard var original=ProcessDiscovery.sessions(probe.read()).first(where:{$0.agent == .codex}) else{throw AppError.message("Owned original missing")}
            original.cwd=root;originals.append(original);probes.append(probe)
        }
        let first=probes[0],second=probes[1];first.additional=second
        let paths=AppPaths(directory:URL(fileURLWithPath:root+"/state"));try paths.prepare()
        let store=try AuditStore(path:paths.database)
        var journal:[String:CodexSessionAttachment]=[:]
        for (i,original) in originals.enumerated() {
            let rows=probes[i].read()
            guard let process=rows.first(where:{$0.key==original.id}),let shell=rows.first(where:{$0.pid==probes[i].descriptor.pid}) else{throw AppError.message("Owned shell missing")}
            var plan=CodexSessionAttachment(context:.init(session:original,process:process,shell:shell,conversationID:ids[i]),home:home)
            plan.goalBeforePause=try CodexGoalTransport.readDatabase(home:home,threadID:ids[i]);plan.phase = .review
            plan.detail="자동 연결 보류: Mac 연결 설정의 ‘직접 입력 연결’을 확인해주세요. 새 연결은 macOS 로그인 항목 설정에서 허용하며 원래 CLI를 유지합니다."
            journal[original.id]=plan
        }
        try store.set("codexSessionAttachments",String(decoding:JSONEncoder().encode(journal),as:UTF8.self))
        var restarts=0,resumed=Set<String>()
        let services=CodexAccountTransitionServices(observe:{_ in
            let rows=first.read()
            var threads:[CodexAccountTransitionThread]=[]
            for (i,id) in ids.enumerated() where probes[i].launchCalls==1 {
                threads.append(.init(id:id,turnID:"turn-"+id,continuable:true,cwd:root,modelProvider:"openai",goal:try CodexGoalTransport.readDatabase(home:home,threadID:id),turnStatus:"interrupted"))
            }
            guard !rows.isEmpty else{throw AppError.message("Owned inventory disappeared")}
            return .init(savedAccount:"fixture",serverAccount:"fixture",serverID:restarts==0 ? "old":"new",threads:threads)
        },interrupt:{_,_,_,_ in throw AppError.message("Standalone Goal must be paused before server control")},restart:{_,_ in
            guard probes.allSatisfy({$0.exitCalls==1 && $0.launchCalls==1}) else{throw AppError.message("Common server rotated before both conversations attached")}
            restarts+=1
        },verify:{target,_,_ in target.witnesses.count},resume:{_,_,thread,_ in
            let id=thread.id
            guard restarts==1,ids.contains(id),resumed.insert(id).inserted,
                  try CodexGoalTransport.readDatabase(home:home,threadID:id)?.status == .paused else{throw AppError.message("Wrong or duplicated Goal continuation")}
            try setGoal(id,"active");return .goal
        })
        let setup=CodexManagedServerServices(inspect:{_,_ in .init(phase:.running,version:"0.166.0",detail:"Owned shared server",autoStartEnabled:true)},prepare:{_,_ in throw AppError.message("Unexpected daemon setup")})
        let engine=try ApprovalEngine(paths:paths,processReader:{first.read()},screenAdapters:[.terminal:first.adapter()],codexAccountTransitions:services,codexAccountTargets:{try await CodexAccountTransitionTarget.discover($0)},codexManagedServers:setup)
        defer{engine.stop()}
        await engine.refresh();await engine.connectScreenHost(.terminal)
        for original in originals {try engine.setAutomatic(original.id,enabled:true);engine.receiveScreen(sessionID:original.id,raw:first.screen(original.tty),generation:"owned",source:.terminalScreen)}
        await engine.ensureCodexManagedServers()
        guard probes.allSatisfy({$0.interruptCalls==0 && $0.exitCalls==0}) else{throw AppError.message("Passive discovery changed an independent Goal")}
        let task=Task{try await engine.reconnectCodexLogin(home:home)}
        let timeout=Task{try await Task.sleep(for:.seconds(65));task.cancel()};defer{timeout.cancel()}
        do {try await task.value}catch {throw AppError.message("Persisted helper failure blocks all-session reconnect: "+error.localizedDescription)}
        for _ in 0..<12 {await engine.checkCodexAccountTransitions()}
        guard probes.allSatisfy({$0.keyboardPosts==1 && $0.interruptWrites==1 && $0.exitCalls==1 && $0.launchCalls==1}),restarts==1,resumed==Set(ids) else{throw AppError.message("Both distinct Goals must attach and continue exactly once")}
        let targets=try await engine.codexLoginTargets()
        guard targets.count==1,targets[0].home==home,targets[0].witnesses.count==2 else{throw AppError.message("Two independent conversations did not consolidate under one daemon")}
        for id in ids {guard try CodexGoalTransport.readDatabase(home:home,threadID:id)?.status == .active else{throw AppError.message("Goal lost after consolidation")}}
        for original in originals {
            let events=store.recent(limit:200).filter{$0.sessionID==original.id && $0.summary=="Codex 세션 서버 연결"}
            for phase in ["needsPause","pauseReserved","waitingPause","ready","exitReserved","waitingShell","launchReserved","verifying","connected"] {
                guard events.contains(where:{$0.outcome.hasPrefix("["+phase+"]")}) else{throw AppError.message("Missing durable connection stage: "+phase)}
            }
            guard !events.contains(where:{$0.outcome.contains("Objective ")}) else{throw AppError.message("Goal objective must not enter connection diagnostics")}
        }
        let expected=originals[0].pid < originals[1].pid ? ["0:pause","0:exit","0:launch","1:pause","1:exit","1:launch"]:["1:pause","1:exit","1:launch","0:pause","0:exit","0:launch"]
        guard timeline.events==expected else{throw AppError.message("Attachment was not sequential: "+timeline.events.joined(separator:","))}
        print("{\"verified\":true,\"legacyFailuresRecovered\":2,\"distinctGoals\":2,\"sharedServers\":1,\"connectedWitnesses\":2,\"keyboardPosts\":2,\"sequential\":true,\"serverRotations\":1,\"goalResumptions\":2,\"userTerminalActions\":0}")
    }
}
