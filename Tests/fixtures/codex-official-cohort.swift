import Foundation
import Darwin
@testable import AutoApproveCore

/// Original Codex clients in owned PTYs. Only the desktop host adapter is fake.
private final class CohortTerminals:@unchecked Sendable {
    let terminals:[ManagedPTY]
    let loseLaunchReply:Bool
    private let lock=NSRecursiveLock(),client=UUID().uuidString
    private var sequences:[String:Int]=[:],launches:[String:Int]=[:],stops=0,lost=false,goalPrompts=0
    private var ownedKeys=Set<String>()
    init(_ terminals:[ManagedPTY],loseLaunchReply:Bool){self.terminals=terminals;self.loseLaunchReply=loseLaunchReply}
    func terminal(_ tty:String)throws->ManagedPTY {
        guard let terminal=terminals.first(where:{$0.descriptor.tty==tty}) else{throw AppError.message("Not an owned PTY")}
        return terminal
    }
    func write(_ terminal:ManagedPTY,_ text:String)throws {
        try lock.withLock {
            let stream=terminal.descriptor.streamID,sequence=(sequences[stream] ?? 0)+1
            sequences[stream]=sequence
            try terminal.input(Data(text.utf8),streamID:stream,client:client,sequence:sequence)
        }
    }
    func status(_ terminal:ManagedPTY)throws {
        // Match the desktop adapter's separate text and Enter events. Sending
        // both in one PTY burst can invoke Codex's paste heuristic instead.
        try write(terminal,"/status");usleep(200_000);try write(terminal,"\r")
    }
    func records()throws->[ProcessRecord] {
        let ttys=Set(terminals.map{$0.descriptor.tty}),shells=Set(terminals.map{$0.descriptor.pid})
        let host=ProcessDiscovery.parse("2000000000 1 ?? 2000000000 0 Mon Nov 2 10:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")[0]
        let all=try ProcessDiscovery.read()
        var rows=lock.withLock {()->[ProcessRecord] in
            var selected=all.filter{ttys.contains("/dev/"+$0.tty) || ownedKeys.contains($0.key)}
            var pids=Set(selected.map(\.pid)),changed=true
            while changed {
                changed=false
                for record in all where pids.contains(record.parent) && !pids.contains(record.pid) {selected.append(record);pids.insert(record.pid);changed=true}
            }
            ownedKeys.formUnion(selected.map(\.key));return selected
        }
        for index in rows.indices where shells.contains(rows[index].pid){rows[index].parent=host.pid}
        return [host]+rows
    }
    func stop(_ record:ProcessRecord)->Bool {
        guard lock.withLock({ownedKeys.contains(record.key)}),!terminals.contains(where:{$0.descriptor.pid==record.pid}) else{return false}
        if record.agent == .codex {lock.withLock{stops+=1}}
        return kill(record.pid,SIGTERM)==0
    }
    var counts:(Int,[String:Int]) {lock.withLock{(stops,launches)}}
    var pausedPromptCount:Int {lock.withLock{goalPrompts}}
    func closeOwnedClients() {
        // Closing only the parent PTY shell can leave its foreground TUI
        // reconnecting and auto-starting the daemon during Node cleanup.
        for _ in 0..<100 {
            let clients=((try? records()) ?? []).filter{$0.agent == .codex}
            if clients.isEmpty{return}
            for record in clients {
                guard let fresh=try? ProcessDiscovery.read(pid:record.pid),fresh.contains(where:{$0.key==record.key && $0.tty==record.tty && $0.agent == .codex}) else{continue}
                _=kill(record.pid,SIGTERM)
            }
            usleep(50_000)
        }
    }
    func adapter()->ScreenHostAdapter {
        .init(screens:{targets in .init(screens:try targets.map{target in
            .init(tty:target.tty,contents:try self.terminal(target.tty).screen())
        })},approve:{_,_,_ in .screenChanged},reveal:{_ in nil},restart:{target,expected,command in
            let terminal=try self.terminal(target.tty)
            guard terminal.screen()==expected,SessionExitRecovery.emptyShellPrompt(expected) else{return .screenChanged}
            self.lock.withLock{self.launches[target.tty,default:0]+=1}
            try self.write(terminal,command+"\r")
            if self.lock.withLock({if self.loseLaunchReply && !self.lost {self.lost=true;return true};return false}) {
                throw AppError.message("OWNED_LOST_LAUNCH_REPLY")
            }
            return .sent
        },input:{target,expected,_,input in
            let terminal=try self.terminal(target.tty)
            guard terminal.screen()==expected else{return .screenChanged}
            if input.kind == .escape,expected.contains("Resume paused goal?"),expected.contains("Keep it paused; use /goal resume later") {
                self.lock.withLock{self.goalPrompts+=1}
                try self.write(terminal,input.bytes);return .sent
            }
            guard input.text=="/status" else{throw AppError.message("Unexpected owned cohort input")}
            try self.status(terminal);return .sent
        })
    }
}

@main struct OfficialCohortCheck {
    @MainActor static func main() async throws {
        let root=CommandLine.arguments[1],executable=CommandLine.arguments[2]
        let standalone=CommandLine.arguments.contains("--standalone-cohort"),sameHome=CommandLine.arguments.contains("--same-home")
        let automatic=CommandLine.arguments.contains("--automatic-enrollment")
        let activeChild=CommandLine.arguments.contains("--active-child-goal")
        let recoverMovedIntent=CommandLine.arguments.contains("--recover-moved-intent")
        let supersededMovedIntent=CommandLine.arguments.contains("--superseded-moved-intent")
        guard !(recoverMovedIntent && supersededMovedIntent),!(recoverMovedIntent || supersededMovedIntent) || activeChild else{throw AppError.message("Moved intent check requires one active child Goal")}
        let activeRoots=CommandLine.arguments.contains("--active-root-goals")
        let backgroundTool=CommandLine.arguments.contains("--background-tool")
        guard !backgroundTool || standalone else{throw AppError.message("Background tool check requires the standalone source")}
        let dedicated=CommandLine.arguments.contains("--dedicated-split")
        guard !dedicated || (!standalone && !sameHome && !automatic) else{throw AppError.message("Dedicated split requires a managed source and a new home")}
        guard !sameHome || standalone else{throw AppError.message("Owned same-home scenario requires a standalone source")}
        guard !automatic || (standalone && sameHome) else{throw AppError.message("Owned automatic enrollment requires the same standalone home")}
        let source=try CodexAccountTransitionTarget.canonicalHome(root+"/home")
        var destination=try CodexAccountTransitionTarget.canonicalHome(root+(sameHome ? "/home":"/destination/home"))
        let environment=["HOME":root,"CODEX_HOME":source,"ZDOTDIR":root,"PATH":"/usr/bin:/bin","PS1":"owned% ",
            "HTTP_PROXY":"http://127.0.0.1:9","HTTPS_PROXY":"http://127.0.0.1:9","NO_PROXY":"127.0.0.1,localhost"]
        guard let cli=try CodexOfficialExecutable.resolve(home:source,userHome:root,executable:executable,environment:environment) else{throw AppError.message("Missing owned official CLI")}
        // This adapter has no desktop scrollback channel. Keep this scenario's
        // fresh /status cards visible; clipped-history has separate coverage.
        let terminalRows=100
        let terminals=try (0..<2).map{_ in try ManagedPTY(cwd:root,command:["/bin/zsh","-f"],columns:140,rows:terminalRows,environment:environment)}
        defer{for terminal in terminals{terminal.close()}}
        let probe=CohortTerminals(terminals,loseLaunchReply:CommandLine.arguments.contains("--lose-launch-reply"))
        defer{probe.closeOwnedClients()}
        var unrelatedSibling:ProcessRecord?
        defer {
            if let witness=unrelatedSibling,let rows=try? ProcessDiscovery.read(pid:witness.pid),rows.contains(where:{$0.key==witness.key}) {_=kill(witness.pid,SIGTERM)}
        }
        for (index,terminal) in terminals.enumerated() {
            note("seed-\(index)")
            try await wait(terminal){SessionExitRecovery.emptyShellPrompt(terminal.screen())}
            if backgroundTool && index==0 {
                try probe.write(terminal,"/bin/sleep 600 &\r")
                for _ in 0..<100 {
                    unrelatedSibling=try probe.records().first(where:{$0.parent==terminal.descriptor.pid && ($0.executable as NSString).lastPathComponent=="sleep"})
                    if unrelatedSibling != nil {break};try await Task.sleep(for:.milliseconds(50))
                }
                guard unrelatedSibling != nil else{throw AppError.message("Owned unrelated sibling did not start")}
            }
            let mode=standalone && index==0 ? ["--no-daemon"]:["--remote","unix://"]
            try probe.write(terminal,try cli.terminalInvocation(mode+["OWNED_COHORT_\(index)"]).map(HookInstaller.quote).joined(separator:" ")+"\r")
            try await wait(terminal){terminal.screen().contains("OWNED_COHORT_REPLY") && CodexGoalScreen.ready(terminal.screen())}
        }
        let originalPeer=try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:source))
        let rows=try probe.records()
        let originals=try terminals.map{terminal in try required(rows.first(where:{$0.agent == .codex && $0.isForeground && "/dev/"+$0.tty==terminal.descriptor.tty}),"Owned original client missing")}
        guard originals.count==2 else{throw AppError.message("Expected two owned Codex clients")}
        if standalone, CodexServerLocation.connectedHome(pid:originals[0].pid,hints:[source]) != nil {throw AppError.message("Owned standalone source already uses the daemon")}
        func engine()throws->ApprovalEngine {
            let engine=try ApprovalEngine(paths:.init(directory:URL(fileURLWithPath:root+"/profile")),processReader:{try probe.records()},
                screenAdapters:[.terminal:probe.adapter()],codexAccountTargets:{try await CodexAccountTransitionTarget.discover($0)},
                codexManagedServers:.local(userHome:root,executable:executable))
            engine.processTerminator={probe.stop($0)}
            return engine
        }
        var app=try engine()
        defer{app.stop()}
        await app.refresh();await app.connectScreenHost(.terminal)
        if dedicated {
            let home=try await app.createCodexIndependentLogin(name:"Owned dedicated split",dedicatedServer:true)
            destination=try CodexAccountTransitionTarget.canonicalHome(home.home)
            // Register the generated home for isolated daemon cleanup before
            // preparing it. No real account or credential is involved.
            try JSONEncoder().encode([home.home]).write(to:URL(fileURLWithPath:root+"/extra-homes.json"),options:.atomic)
            let config=try String(contentsOfFile:source+"/config.toml",encoding:.utf8).replacingOccurrences(of:root+"/home/log",with:destination+"/log")
            try Data(config.utf8).write(to:URL(fileURLWithPath:destination+"/config.toml"),options:.atomic)
            try FileManager.default.createDirectory(atPath:destination+"/app-server-daemon",withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try FileManager.default.copyItem(atPath:source+"/app-server-daemon/settings.json",toPath:destination+"/app-server-daemon/settings.json")
            let server=try await app.prepareCodexManagedServer(home:destination)
            guard server.phase == .running,try await app.codexIndependentLogins().contains(home),home.usesDedicatedServer,
                  try !app.codexIndependentLoginStore.requiresStandalone(home:destination) else{throw AppError.message("Dedicated login policy or original server preparation failed")}
        }
        for original in originals{try app.setAutomatic(original.key,enabled:true)}
        var members:[SessionGroupMember]=[]
        for original in originals {
            let terminal=try probe.terminal("/dev/"+original.tty),before=CodexStatusIdentity(screen:terminal.screen())
            note("status-\(original.pid)");try probe.status(terminal)
            try await wait(terminal){before.freshThread(in:terminal.screen()) != nil}
            let thread=try required(before.freshThread(in:terminal.screen()),"Owned /status missing Session ID")
            let session=try required(app.snapshot.sessions.first(where:{$0.id==original.key}),"Original session missing")
            members.append(SessionGroupLiveSession(session:session,conversationID:thread,providerHome:source).member)
        }
        let group=SessionGroup(name:"Owned preserved hierarchy",members:members).settingLeader(members[0].id)
        try SessionGroupStore(directory:app.paths.directory).save([group])
        let mailbox=try SessionGroupMailbox(directory:app.paths.directory)
        let pending=try mailbox.enqueue(groupID:group.id,senderID:members[1].id,recipientID:members[0].id,kind:.question,text:"OWNED_PENDING_QUESTION")
        let acknowledged=try mailbox.enqueue(groupID:group.id,senderID:members[0].id,recipientID:members[1].id,kind:.reply,text:"OWNED_ACKNOWLEDGED_REPLY")
        try mailbox.acknowledge([acknowledged.id],groupID:group.id,recipientID:members[1].id)
        let previousACK=try mailbox.message(acknowledged.id)?.acknowledgedAt
        let pausedGoals=CommandLine.arguments.contains("--paused-goals")
        guard !standalone || !pausedGoals else{throw AppError.message("Standalone Goal seeding is a separate fixture scenario")}
        var originalGoals:[String:CodexGoal]=[:]
        if pausedGoals {
            let connection=try CodexQueueConnection(home:source)
            for member in members {
                _=try connection.request("thread/goal/set",["threadId":member.conversationID,"objective":"Owned preserved paused Goal","status":"paused","tokenBudget":1234,"origin":"user"])
                originalGoals[member.conversationID]=try CodexGoalTransport.readWithIdentity(connection,home:source,threadID:member.conversationID)
            }
        }
        let selected=originals[0],neighbor=originals[1]
        let selectedID=members[0].conversationID,neighborID=members[1].conversationID
        let ownedTools=backgroundTool ? try CodexCohortProcessFence.capture(rootID:selected.key,records:probe.records()).filter{$0.key != selected.key}:[]
        if backgroundTool {
            guard ownedTools.contains(where:{($0.executable as NSString).lastPathComponent=="sleep"}),
                  !ownedTools.contains(where:{$0.key==unrelatedSibling?.key}) else{throw AppError.message("Background tool ancestry was not isolated from the sibling")}
        }
        if activeRoots {
            guard !pausedGoals && !activeChild && !standalone else{throw AppError.message("Active root Goal check uses managed roots")}
            let connection=try CodexQueueConnection(home:source)
            for member in members {
                _=try connection.request("thread/goal/set",["threadId":member.conversationID,"objective":"Owned migrated active root Goal","status":"active","tokenBudget":1234,"origin":"user"])
                originalGoals[member.conversationID]=try CodexGoalTransport.readWithIdentity(connection,home:source,threadID:member.conversationID)
                var active=false
                for _ in 0..<200 {
                    let row=try connection.request("thread/read",["threadId":member.conversationID,"includeTurns":false])["thread"] as? JSONObject
                    if (row?["status"] as? JSONObject)?["type"] as? String=="active" {active=true;break}
                    try await Task.sleep(for:.milliseconds(100))
                }
                guard active else{throw AppError.message("Root Goal did not start its original work")}
            }
            try await Task.sleep(for:.seconds(2))
        }
        note("prepare")
        if CommandLine.arguments.contains("--unsupported-history-schema") {
            guard !standalone && !automatic && !pausedGoals && !activeRoots && !activeChild else{throw AppError.message("Schema refusal uses the ordinary managed fixture")}
            let modified=try CommandRunner.run("/usr/bin/sqlite3",[source+"/thread_history_1.sqlite","CREATE TABLE unsupported_history_schema(value TEXT)"])
            guard modified.status==0 else{throw AppError.message("Could not prepare owned schema refusal")}
            var rejected=false
            do {_=try await app.prepareCodexSessionMove(sessionID:selected.key,destinationHome:destination)}
            catch {rejected=error.localizedDescription.contains("페이지형 대화 이력")}
            let live=try probe.records()
            guard rejected,probe.counts.0==0,probe.counts.1.isEmpty,
                  originals.allSatisfy({original in live.contains(where:{$0.key==original.key})}),
                  try SessionGroupStore(directory:app.paths.directory).load()==[group],
                  try mailbox.message(pending.id)?.acknowledgedAt==nil,
                  try mailbox.message(acknowledged.id)?.acknowledgedAt==previousACK else{throw AppError.message("Incompatible schema reached process or group effects")}
            print("{\"verified\":true,\"unsupportedSchemaRefusedBeforeStop\":true,\"originalOfficialRuntime\":true,\"originalClientsAndGroupsPreserved\":true,\"userTerminalTouched\":false}")
            return
        }
        let move:CodexSessionMovePlan
        var automaticResult:CodexSessionAttachment?
        if automatic {
            if CommandLine.arguments.contains("--automatic-before-effects") {
                let manual=try await app.prepareStandaloneCodexCohortMove(sessionID:selected.key,destinationHome:source)
                app.stop();app=try engine();await app.refresh();await app.connectScreenHost(.terminal)
                await app.recoverCodexCohortMoves()
                guard try CodexCohortRestart(store:app.store).state(UUID(uuidString:manual.id)!)?.phase == .captured,
                      probe.counts.0==0,probe.counts.1.isEmpty else{throw AppError.message("A manual proposal ran or was discarded without consent")}
                try app.cancelCodexSessionMove(id:manual.id)
                let abandoned=try await app.prepareStandaloneCodexCohortMove(sessionID:selected.key,destinationHome:source,automaticEnrollment:true)
                app.stop();app=try engine();await app.refresh();await app.connectScreenHost(.terminal)
                await app.recoverCodexCohortMoves()
                guard try CodexCohortRestart(store:app.store).state(UUID(uuidString:abandoned.id)!)?.phase == .cancelled,
                      probe.counts.0==0,probe.counts.1.isEmpty else{throw AppError.message("An abandoned automatic proposal caused effects instead of fresh preparation")}
            }
            await app.attachStandaloneCodexSessions(home:source)
            if probe.loseLaunchReply {
                app.stop();app=try engine();await app.refresh();await app.connectScreenHost(.terminal)
                await app.recoverCodexCohortMoves()
            }
            let ids=try JSONDecoder().decode([UUID].self,from:Data((app.store.value("codexCohortRestartIDs") ?? "[]").utf8))
            let id=try required(ids.last,"Automatic enrollment did not reserve a plan: "+(app.codexSessionAttachmentNotice ?? "none"))
            let state=try required(CodexCohortRestart(store:app.store).state(id),"Automatic enrollment lost its state")
            guard state.phase == .completed,let saved=app.store.value("codexSessionAttachments") else{throw AppError.message("Automatic enrollment did not complete: "+(app.codexSessionAttachmentNotice ?? "none"))}
            automaticResult=try required(JSONDecoder().decode([String:CodexSessionAttachment].self,from:Data(saved.utf8))[selected.key],"Automatic enrollment did not persist its connected receipt")
            move = .init(cohort:state.plan,conversationCount:1)
        }
        else if standalone {move=try await app.prepareStandaloneCodexSessionMove(sessionID:selected.key,destinationHome:destination)}
        else {move=try await app.prepareCodexSessionMove(sessionID:selected.key,destinationHome:destination)}
        guard move.conversationCount==1,automatic || probe.counts.0==0 else{throw AppError.message("Preparation changed processes or scope")}
        var lateChildren:[String]=[]
        var childTurns=Set<String>()
        if CommandLine.arguments.contains("--late-child") {
            guard !automatic && !pausedGoals else{throw AppError.message("Late-child history uses a manual move without paused roots")}
            note("late-child-spawn")
            let connection=try CodexQueueConnection(home:source)
            _=try connection.request("turn/start",["threadId":selectedID,"input":[["type":"text","text":"OWNED_LATE_CHILD","text_elements":[]]]])
            for _ in 0..<200 {
                let scope:[CodexMigrationThread]
                do {scope=try CodexMigrationThread.captureScope(connection:connection,home:source,rootIDs:[selectedID])}
                catch {
                    guard error.localizedDescription.contains("대화 상태와 실행 차례") else{throw error}
                    try await Task.sleep(for:.milliseconds(100));continue
                }
                let children=scope.filter{$0.id != selectedID}
                if activeChild,children.count==1,children[0].active,
                   let goal=try CodexGoalTransport.readWithIdentity(connection,home:source,threadID:children[0].id),goal.status == .active {
                    let page=try connection.request("thread/turns/list",["threadId":children[0].id,"limit":100,"itemsView":"notLoaded"])
                    childTurns=Set((page["data"] as? [JSONObject] ?? []).compactMap{$0["id"] as? String})
                    if !childTurns.isEmpty {lateChildren=children.map(\.id);originalGoals[children[0].id]=goal;break}
                }
                if activeChild {try await Task.sleep(for:.milliseconds(100));continue}
                if children.count==1,scope.allSatisfy({!$0.active}),
                   String(data:try JSONSerialization.data(withJSONObject:connection.request("thread/read",["threadId":children[0].id,"includeTurns":true])),encoding:.utf8)?.contains("OWNED_CHILD_HISTORY_REPLY")==true {
                    lateChildren=children.map(\.id);break
                }
                try await Task.sleep(for:.milliseconds(100))
            }
            guard lateChildren.count==1 else{throw AppError.message("Original runtime did not persist the post-preview child")}
            note("late-child-history-persisted")
            if activeChild {try await Task.sleep(for:.seconds(2))}
        }
        var result:CodexSessionAttachment
        let observations=Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for:.seconds(10))
                let screens=terminals.map{["tty":$0.descriptor.tty,"screen":$0.screen()]}
                try JSONSerialization.data(withJSONObject:screens).write(to:URL(fileURLWithPath:root+"/owned-screens.json"),options:.atomic)
            }
        }
        defer{observations.cancel()}
        do {
            note("perform")
            if let automaticResult {result=automaticResult}
            else {result=try await app.performCodexSessionMove(id:move.id)}
        }
        catch {
            guard probe.loseLaunchReply,error.localizedDescription.contains("OWNED_LOST_LAUNCH_REPLY") else{throw error}
            app.stop();app=try engine()
            note("cold-recovery")
            await app.refresh();await app.connectScreenHost(.terminal)
            result=try await app.performCodexSessionMove(id:move.id)
        }
        guard result.phase == .connected else{throw AppError.message("Cohort recovery remains incomplete: "+result.detail)}
        guard !pausedGoals || probe.pausedPromptCount>0 else{throw AppError.message("Paused-Goal chooser recovery was not exercised")}
        let current=try probe.records().filter{$0.agent == .codex && $0.isForeground}
        let affected=standalone ? 1:2
        let peer=try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:source))
        guard current.count==2,probe.counts.0==affected,probe.counts.1.count==affected,probe.counts.1.values.allSatisfy({$0==1}),
              standalone ? peer==originalPeer:peer != originalPeer else{throw AppError.message("Wrong client restart count or source server changed unexpectedly")}
        if backgroundTool {
            let remaining=try probe.records()
            guard CodexCohortProcessFence.live(ownedTools,records:remaining).isEmpty,
                  remaining.contains(where:{$0.key==unrelatedSibling?.key}) else{throw AppError.message("Original tool hosts survived or an unrelated sibling was terminated")}
        }
        for (record,id,home) in [(selected,selectedID,destination),(neighbor,neighborID,source)] {
            let shouldRestart=record.key==selected.key || !standalone
            let replacement=try required(current.first(where:{$0.tty==record.tty && (shouldRestart ? $0.key != record.key:$0.key==record.key)}),"Original terminal not restored or unrelated client restarted")
            guard CodexServerLocation.connectedHome(pid:replacement.pid,hints:[home])==home,
                  app.store.value("automatic:"+replacement.key)=="true" else{throw AppError.message("Wrong restored account or automation")}
            if dedicated && record.key==selected.key {
                let account=try await app.codexSessionAccount(sessionID:replacement.key)
                guard account.loginGroupName=="Owned dedicated split",account.sharedSessions==1 else{throw AppError.message("Dedicated home lost its account name or isolated cohort")}
            }
            let reply=try CodexQueueConnection(home:home).request("thread/read",["threadId":id,"includeTurns":true])
            guard String(data:try JSONSerialization.data(withJSONObject:reply),encoding:.utf8)?.contains("OWNED_COHORT_REPLY")==true else{throw AppError.message("Persisted conversation history missing")}
            if let original=originalGoals[id] {
                let goal=try CodexGoalTransport.readWithIdentity(CodexQueueConnection(home:home),home:home,threadID:id)
                guard goal?.instanceID==original.instanceID,goal?.objective==original.objective,
                      goal?.status == (activeRoots ? .active:.paused),
                      activeRoots ? goal?.tokensUsed ?? -1 >= original.tokensUsed:goal?.tokensUsed==original.tokensUsed,
                      activeRoots ? goal?.timeUsedSeconds ?? -1 >= 2:goal?.timeUsedSeconds==original.timeUsedSeconds,
                      goal?.tokenBudget==original.tokenBudget else{throw AppError.message("Paused Goal identity, budget or accounting was changed")}
            }
        }
        let restored=try required(SessionGroupStore(directory:app.paths.directory).load().first(where:{$0.id==group.id}),"Group disappeared")
        for child in lateChildren {
            let connection=try CodexQueueConnection(home:destination)
            // The official paginated history index is materialized on cold
            // resume. An unselected dormant child has not been loaded by the
            // parent's TUI yet; verify the actual native selection lifecycle.
            if !activeChild {_=try connection.request("thread/resume",["threadId":child,"excludeTurns":true])}
            let reply=try connection.request("thread/read",["threadId":child,"includeTurns":false])
            let history=try connection.request("thread/turns/list",["threadId":child,"limit":100,"itemsView":"full"])
            try JSONSerialization.data(withJSONObject:["metadata":reply,"history":history]).write(to:URL(fileURLWithPath:root+"/owned-restored-child.json"),options:.atomic)
            guard let row=reply["thread"] as? JSONObject,row["parentThreadId"] as? String==selectedID else{throw AppError.message("Post-preview child parent changed")}
            if activeChild {
                let goal=try CodexGoalTransport.readWithIdentity(connection,home:destination,threadID:child)
                guard let original=originalGoals[child],goal?.instanceID==original.instanceID,goal?.status == .active,
                      goal?.objective==original.objective,goal?.tokenBudget==original.tokenBudget,
                      goal?.tokensUsed ?? -1 >= original.tokensUsed,goal?.timeUsedSeconds ?? -1 >= original.timeUsedSeconds,
                      row["canAcceptDirectInput"] as? Bool==false,
                      childTurns.isSubset(of:Set((history["data"] as? [JSONObject] ?? []).compactMap{$0["id"] as? String})) else{throw AppError.message("Active child Goal identity, accounting or prior turns were not restored")}
            } else {
                guard String(data:try JSONSerialization.data(withJSONObject:history),encoding:.utf8)?.contains("OWNED_CHILD_HISTORY_REPLY")==true else{throw AppError.message("Post-preview child history was lost")}
            }
        }
        if recoverMovedIntent || supersededMovedIntent {
            note("recover-moved-goal-intent")
            let child=try required(lateChildren.first,"Moved Goal missing")
            let parent=try required(current.first(where:{$0.tty==selected.tty}),"Moved parent missing")
            let actual=try await app.readCodexSubagentGoal(sessionID:parent.key,childID:child)
            var beforeMove=actual
            beforeMove.goal=originalGoals[child];beforeMove.turnID=childTurns.first
            let ledger=try CodexSubagentGoalActionStore(path:app.paths.directory.appendingPathComponent("subagent-goal-actions.sqlite").path)
            let old=UUID()
            // Simulate a durable unresolved request saved by the old runtime.
            // Its target/Goal metadata are from before the real home handoff;
            // the actual native Goal has already been restored at destination.
            var pending=CodexSubagentGoalReceipt(requestID:old,binding:"owned-before-home-move",phase:.reserved,detail:"Controller result was lost",
                intent:.init(sessionID:selected.key,home:source,expected:beforeMove,action:.pause,createdAt:Date().addingTimeInterval(-120)))
            try ledger.reserve(pending);pending.phase = .unknown;try ledger.finish(pending)
            if supersededMovedIntent {
                var paused=actual;paused.goal?.status = .paused
                var newer=CodexSubagentGoalReceipt(requestID:UUID(),binding:"owned-new-home-resume",phase:.reserved,detail:"Newer destination resume",
                    intent:.init(sessionID:parent.key,home:destination,expected:paused,action:.resume))
                try ledger.reserve(newer);newer.phase = .confirmed;newer.result=actual;try ledger.finish(newer)
            }
            await app.recoverCodexGoalIntents()
            let saved=try required(ledger.read(old),"Moved intent disappeared")
            let fresh=try await app.readCodexSubagentGoal(sessionID:parent.key,childID:child)
            guard saved.phase == (supersededMovedIntent ? .notStarted:.confirmed),
                  fresh.goal?.instanceID==beforeMove.goal?.instanceID,
                  fresh.goal?.status == (supersededMovedIntent ? .active:.paused),
                  supersededMovedIntent || fresh.executionState=="idle" else{throw AppError.message("Moved intent was not reconciled against journal-proven homes: "+saved.detail)}
            await app.recoverCodexGoalIntents()
            guard try ledger.read(old)?.phase==saved.phase else{throw AppError.message("Settled moved intent changed on a repeated recovery")}
        }
        guard restored.leaderMemberID==group.leaderMemberID,restored.members.map(\.id)==group.members.map(\.id),
              restored.members.map(\.parentMemberID)==group.members.map(\.parentMemberID),
              restored.members[0].conversationID==selectedID,restored.members[0].providerHome==destination,
              restored.members[1].conversationID==neighborID,restored.members[1].providerHome==source,
              restored.members.allSatisfy({member in current.contains(where:{$0.key==member.runtimeID})}) else{throw AppError.message("Group identities or hierarchy were not restored")}
        var call:JSONObject=["owner":UUID().uuidString,"tool":"get_group_messages","groupID":group.id.uuidString,
            "agentKind":"codex","conversationID":selectedID,"codexCallerConversationID":selectedID,"codexCallerHome":destination]
        let inbox=try await app.mcpAction(call)
        guard let messages=inbox["messages"] as? [JSONObject],messages.count==1,
              messages[0]["messageID"] as? String==pending.id.uuidString,
              messages[0]["text"] as? String=="OWNED_PENDING_QUESTION" else{throw AppError.message("Moved conversation lost its original group inbox")}
        call["tool"]="ack_group_messages";call["messageIDs"]=[pending.id.uuidString]
        _=try await app.mcpAction(call)
        let coldMailbox=try SessionGroupMailbox(directory:app.paths.directory)
        guard try coldMailbox.message(pending.id)?.acknowledgedAt != nil,
              try coldMailbox.message(acknowledged.id)?.acknowledgedAt==previousACK else{throw AppError.message("Message ID or ACK state was lost across the move")}
        // Re-entering the completed durable operation must not send more input.
        _=try await app.performCodexSessionMove(id:move.id)
        guard probe.counts.1.values.allSatisfy({$0==1}) else{throw AppError.message("Completed operation launched again")}
        if CommandLine.arguments.contains("--roundtrip") {
            guard !standalone && !sameHome && !automatic && !pausedGoals else{throw AppError.message("Roundtrip uses managed homes without paused roots")}
            note("roundtrip-new-turn")
            let moved=try required(current.first(where:{$0.tty==selected.tty}),"Moved TUI missing")
            let retainedNeighbor=try required(current.first(where:{$0.tty==neighbor.tty}),"Neighbor missing")
            let connection=try CodexQueueConnection(home:destination)
            _=try connection.request("turn/start",["threadId":selectedID,"input":[["type":"text","text":"OWNED_ROUNDTRIP_LATEST","text_elements":[]]]])
            var completed=false
            for _ in 0..<200 {
                let response=try connection.request("thread/read",["threadId":selectedID,"includeTurns":true])
                if let row=response["thread"] as? JSONObject,(row["status"] as? JSONObject)?["type"] as? String=="idle",
                   String(data:try JSONSerialization.data(withJSONObject:response),encoding:.utf8)?.contains("OWNED_ROUNDTRIP_REPLY")==true {completed=true;break}
                try await Task.sleep(for:.milliseconds(100))
            }
            guard completed else{throw AppError.message("Latest roundtrip turn did not persist")}
            let oldPeer=try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:source))
            let back=try await app.prepareCodexSessionMove(sessionID:moved.key,destinationHome:source)
            guard back.restartingSessionCount==1 else{throw AppError.message("Return captured an unrelated home client")}
            let returned=try await app.performCodexSessionMove(id:back.id)
            guard returned.phase == .connected else{throw AppError.message("Roundtrip incomplete: "+returned.detail)}
            let live=try probe.records().filter{$0.agent == .codex && $0.isForeground}
            guard live.contains(where:{$0.key==retainedNeighbor.key}),
                  let selectedAgain=live.first(where:{$0.tty==selected.tty && $0.key != moved.key}),
                  CodexServerLocation.connectedHome(pid:selectedAgain.pid,hints:[source])==source,
                  try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:source))==oldPeer,
                  app.store.value("automatic:"+selectedAgain.key)=="true",
                  probe.counts.0==affected+1,probe.counts.1["/dev/"+selected.tty]==2,
                  probe.counts.1["/dev/"+neighbor.tty]==1 else{throw AppError.message("Return restarted unrelated clients or duplicated a launch")}
            let latest=try CodexQueueConnection(home:source).request("thread/turns/list",["threadId":selectedID,"limit":100,"itemsView":"full"])
            guard String(data:try JSONSerialization.data(withJSONObject:latest),encoding:.utf8)?.contains("OWNED_ROUNDTRIP_REPLY")==true else{throw AppError.message("Returned paginated history is older than the moved conversation")}
            for child in lateChildren {
                let history=try CodexQueueConnection(home:source).request("thread/turns/list",["threadId":child,"limit":100,"itemsView":"full"])
                guard String(data:try JSONSerialization.data(withJSONObject:history),encoding:.utf8)?.contains("OWNED_CHILD_HISTORY_REPLY")==true else{throw AppError.message("Returned child history disappeared")}
            }
            let rebound=try required(SessionGroupStore(directory:app.paths.directory).load().first(where:{$0.id==group.id}),"Returned group missing")
            guard rebound.leaderMemberID==group.leaderMemberID,rebound.members.map(\.id)==group.members.map(\.id),
                  rebound.members.map(\.parentMemberID)==group.members.map(\.parentMemberID),
                  rebound.members.allSatisfy({$0.providerHome==source}),
                  try coldMailbox.message(pending.id)?.acknowledgedAt != nil,
                  try coldMailbox.message(acknowledged.id)?.acknowledgedAt==previousACK else{throw AppError.message("Roundtrip group or mailbox bindings changed")}
            _=try await app.performCodexSessionMove(id:back.id)
            guard probe.counts.0==affected+1,probe.counts.1["/dev/"+selected.tty]==2 else{throw AppError.message("Completed return was repeated")}
            note("roundtrip-preserved-latest-history")
        }
        print("{\"verified\":true,\"productionPrepareAndPerform\":true,\"originalOfficialRuntime\":true,\"twoTerminals\":true,\"onlySelectedHomeChanged\":true,\"historyAndGroupRolesPreserved\":true,\"pendingInboxAndACKsPreserved\":true,\"singleLaunchPerAffectedTerminal\":true,\"affectedClients\":\(affected),\"standaloneEnrollment\":\(standalone),\"automaticEnrollment\":\(automatic),\"sameHome\":\(sameHome),\"coldLostReplyRecovery\":\(probe.loseLaunchReply),\"pausedGoalsChecked\":\(pausedGoals),\"userTerminalTouched\":false}")
    }
    static func required<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw AppError.message(message)};return value}
    static func note(_ stage:String){FileHandle.standardError.write(Data(("COHORT_STAGE:"+stage+"\n").utf8))}
    static func wait(_ terminal:ManagedPTY,_ ready:()throws->Bool) async throws {
        for _ in 0..<600 {
            if try ready(){return}
            guard terminal.isRunning else{throw AppError.message("Owned shell exited: "+terminal.screen())}
            try await Task.sleep(for:.milliseconds(50))
        }
        throw AppError.message("Owned cohort screen timeout: "+terminal.screen())
    }
}
