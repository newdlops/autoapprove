import Foundation
import AutoApproveCore
import CSQLite

private final class OwnedEnginePTY:@unchecked Sendable {
    let terminal:ManagedPTY,descriptor:ManagedPTYDescriptor
    let client=UUID().uuidString
    private let lock=NSLock()
    private var sequence=0
    var statusCalls=0,exitCalls=0,launchCalls=0
    init(_ terminal:ManagedPTY,_ descriptor:ManagedPTYDescriptor){self.terminal=terminal;self.descriptor=descriptor}
    func write(_ text:String)throws {lock.lock();defer{lock.unlock()};sequence+=1;try terminal.input(Data(text.utf8),streamID:descriptor.streamID,client:client,sequence:sequence)}
    func read()->[ProcessRecord] {
        let terminalRecord=ProcessDiscovery.parse("990001 1 ?? 990001 0 Mon Nov 2 10:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")[0]
        var records=((try? ProcessDiscovery.read()) ?? []).filter{"/dev/"+$0.tty==descriptor.tty}
        if let i=records.firstIndex(where:{$0.pid==descriptor.pid}) {records[i].parent=terminalRecord.pid}
        return [terminalRecord]+records
    }
    func adapter()->ScreenHostAdapter {
        ScreenHostAdapter(screens:{targets in TerminalSnapshot(screens:targets.map{TerminalScreen(tty:$0.tty,contents:self.terminal.screen())})},approve:{_,_,_ in .screenChanged},reveal:{_ in nil},restart:{target,expected,command in
            guard self.terminal.screen()==expected,SessionExitRecovery.emptyShellPrompt(expected) else{return .screenChanged}
            self.launchCalls+=1;try self.write(command+"\n");return .sent
        },input:{target,expected,_,input in
            guard self.terminal.screen()==expected else{return .screenChanged}
            if input.text=="/status" {self.statusCalls+=1}
            else if input.text=="/exit" {self.exitCalls+=1}
            else {throw AppError.message("Unexpected owned fixture input")}
            try self.write(input.bytes);return .sent
        })
    }
}

@main struct EngineAttachmentCheck {
    @MainActor static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath().path
        let home=try CodexAccountTransitionTarget.canonicalHome(root+"/home/.codex"),thread="00000000-0000-4000-8000-000000000061",red=CommandLine.arguments.contains("--expect-unresolved"),wrong=CommandLine.arguments.contains("--wrong-thread"),goalWait=CommandLine.arguments.contains("--goal-wait")
        func goal(_ status:String)throws {
            var db:OpaquePointer?
            guard sqlite3_open(home+"/goals_1.sqlite",&db)==SQLITE_OK else{throw AppError.message("Owned Goal database failed")}
            defer{sqlite3_close(db)}
            let sql="CREATE TABLE IF NOT EXISTS thread_goals(thread_id TEXT PRIMARY KEY,goal_id TEXT,objective TEXT,status TEXT,token_budget INTEGER,tokens_used INTEGER,time_used_seconds INTEGER,created_at_ms INTEGER,updated_at_ms INTEGER); INSERT OR REPLACE INTO thread_goals VALUES('\(thread)','fixture-goal','Owned test','\(status)',NULL,0,0,100000,110000);"
            guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw AppError.message("Owned Goal update failed")}
        }
        if goalWait {try goal("active")}
        let manager=ManagedPTYManager(environment:["HOME":root,"CODEX_HOME":home,"PATH":"/usr/bin:/bin","PS1":"fixture% ","READY_FILE":root+"/ready","FIXTURE_SOCKET":root+"/daemon.sock","EXPECTED_THREAD":thread,"STATUS_THREAD":wrong ? "00000000-0000-4000-8000-000000000062":thread]);defer{manager.stop()}
        let descriptor=try manager.create(cwd:root,program:"shell",command:["/bin/zsh","-f"],columns:100,rows:50),terminal=try manager.terminal(descriptor.ptyID),probe=OwnedEnginePTY(terminal,descriptor)
        func wait(_ test:()throws->Bool) async throws {let end=Date().addingTimeInterval(8);while Date()<end{if try test(){return};try await Task.sleep(for:.milliseconds(100))};throw AppError.message("Owned fixture not ready")}
        try await wait{SessionExitRecovery.emptyShellPrompt(terminal.screen())};try probe.write(HookInstaller.quote(root+"/codex")+"\n")
        try await wait{CodexProgressScreen.ready(terminal.screen())}
        guard let original=probe.read().first(where:{$0.agent == .codex}) else{throw AppError.message("Owned Codex not found")}
        guard try ProcessOpenFiles.codexRolloutPaths(pid:original.pid,expectedStart:original.started).isEmpty else{throw AppError.message("Fixture must have no JSONL")}
        let setup=CodexManagedServerServices(inspect:{selected,_ in .init(phase:selected==home ? .running:.unavailable,version:"0.166.0",detail:"Owned fixture",autoStartEnabled:true)},prepare:{_,_ in throw AppError.message("Must not prepare")})
        let engine=try ApprovalEngine(paths:.init(directory:URL(fileURLWithPath:root+"/state")),processReader:{probe.read()},screenAdapters:[.terminal:probe.adapter()],terminalInputAvailable:{true},codexAccountTargets:{try await CodexAccountTransitionTarget.discover($0)},codexManagedServers:setup)
        defer{engine.stop()}
        await engine.refresh();await engine.connectScreenHost(.terminal);try engine.setAutomatic(original.key,enabled:true)
        engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
        try await Task.sleep(for:.seconds(2))
        engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
        guard engine.snapshot.sessions.contains(where:{$0.id==original.key && $0.terminal == .terminal && $0.phase == .idle}) else{throw AppError.message("Owned engine inventory: "+engine.snapshot.sessions.map{"pid=\($0.pid) host=\($0.terminal.rawValue) phase=\($0.phase.rawValue)"}.joined(separator:",")+" screen="+terminal.screen())}
        if goalWait {
            await engine.ensureCodexManagedServers()
            guard probe.statusCalls==1,probe.exitCalls==0,engine.codexSessionAttachmentNotice?.contains("활성 Goal") == true else{throw AppError.message("Active Goal must wait")}
            try goal("complete");try probe.write("/fixture-progress\n")
            try await wait{terminal.screen().contains("Goal completed")}
            engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
            try await Task.sleep(for:.seconds(2))
            engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
        }
        let deadline=Date().addingTimeInterval(red || wrong ? 3:20)
        var attached=false
        repeat {
            engine.receiveScreen(sessionID:original.key,raw:terminal.screen(),generation:"owned",source:.terminalScreen)
            await engine.ensureCodexManagedServers()
            attached=try await engine.codexLoginTargets().contains(where:{$0.home==home && $0.witnesses.contains(where:{$0.pid != original.pid})})
            if attached,engine.codexSessionAttachmentNotice?.contains("기존 창·같은 대화의 관리형 서버 연결을 확인했습니다.") == true {break};try await Task.sleep(for:.milliseconds(150))
        }while Date()<deadline
        if red {
            guard !attached,probe.statusCalls==0,probe.exitCalls==0,engine.codexSessionAttachmentNotice?.contains("대화 ID") == true else{throw AppError.message("Expected SQLite-only discovery failure not reproduced: \(engine.codexSessionAttachmentNotice ?? "none") inventory=\(engine.snapshot.sessions.map{"\($0.phase.rawValue) pending=\($0.pendingInTerminal) review=\($0.needsReview)"})")}
        } else if wrong {
            guard !attached,probe.statusCalls==1,probe.exitCalls==0,probe.launchCalls==0,probe.read().contains(where:{$0.key==original.key}) else{throw AppError.message("Mismatched thread must retain the original process")}
        } else {
            guard attached,engine.codexSessionAttachmentNotice?.contains("기존 창·같은 대화의 관리형 서버 연결을 확인했습니다.") == true,probe.statusCalls==(goalWait ? 2:1),probe.exitCalls==1,probe.launchCalls==1 else{throw AppError.message("Engine attachment failed: "+(engine.codexSessionAttachmentNotice ?? "none")+" status=\(probe.statusCalls) exit=\(probe.exitCalls) launch=\(probe.launchCalls)")}
        }
        print("{\"verified\":true,\"productionEngine\":true,\"sqliteOnly\":true,\"expectedUnresolved\":\(red),\"mismatchedThread\":\(wrong),\"goalWait\":\(goalWait),\"statusRequests\":\(probe.statusCalls),\"exitRequests\":\(probe.exitCalls),\"launchRequests\":\(probe.launchCalls),\"userTerminalActions\":0}")
    }
}
