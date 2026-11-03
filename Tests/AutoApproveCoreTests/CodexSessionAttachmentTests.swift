import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testCodexFreshStatusIdentityRequiresFreshCompleteUnambiguousCard() throws {
        let id="00000000-0000-4000-8000-000000000061",other="00000000-0000-4000-8000-000000000062"
        func card(_ value:String)->String {">_ OpenAI Codex (v0.166.0)\nModel: synthetic\nDirectory: /fixture\nPermissions: Read Only\nAgents.md: none\nSession: "+value+"\n› Ask anything\n? for shortcuts"}
        var proof=CodexStatusIdentity(screen:card(id))
        try expect(proof.freshThread(in:card(id))==nil,"An old card is not a response")
        try expect(proof.freshThread(in:"Session: "+other)==nil)
        try expect(proof.freshThread(in:card(id)+"\n"+card(other))==other)
        try expect(CodexStatusIdentity(screen:"").freshThread(in:card(id)+"\n"+card(other))==nil)
        try expect(proof.identify(card(id)+"\n"+card(other)))
        let restored=try JSONDecoder().decode(CodexStatusIdentity.self,from:JSONEncoder().encode(proof))
        try expect(restored.matches(card(id)+"\n"+card(other),thread:other))
        try expectFalse(restored.matches(card(id),thread:other))
        try expectFalse(restored.matches(card(id)+"\n"+card(other)+"\nchanged",thread:other))
        let wrapped=card(String(id.prefix(20))+"\n"+String(id.dropFirst(20)))
        try expectEqual(CodexStatusIdentity(screen:"").freshThread(in:wrapped),id)
        try expect(CodexStatusIdentity(screen:"").freshThread(in:card(id).replacingOccurrences(of:"Permissions:",with:"unrelated:"))==nil)
    }
    func testCodexReplacementPreparationIsReservedBeforeExitAndNeverReplayed() async throws {
        let rows=ProcessDiscovery.parse("""
        910 1 ttys040 910 911 Mon Nov 2 10:00:00 2026 login
        911 910 ttys040 911 911 Mon Nov 2 10:00:01 2026 /fixture/codex
        920 1 ttys041 920 920 Mon Nov 2 10:00:02 2026 /bin/zsh
        """)
        var state=attachmentPlan();state.originalLogin=rows[0];state.context.shell=rows[0];state.phase = .needsTab;state.authorizedToolHosts=[rows[2]]
        var prepared=0,exits=0,saved:[CodexSessionAttachment.Phase]=[]
        let services=CodexSessionAttachmentServices(exit:{exits+=1;return true},shellReady:{false},launch:{throw AppError.message("Unexpected")},verify:{false},prepareReplacement:{prepared+=1;try expectEqual(saved.last,.tabReserved);return rows[2]})
        state=try await services.advance(state,save:{saved.append($0.phase)})
        try expectEqual(state.phase,.ready);try expectEqual(state.context.shell,rows[2]);try expectEqual(prepared,1);try expectEqual(exits,0)
        state=try await services.advance(state,save:{saved.append($0.phase)})
        try expectEqual(state.phase,.waitingShell);try expectEqual(exits,1);try expectEqual(prepared,1);try expect(state.authorizedToolHosts==nil);try expectEqual(state.toolHostShutdownWitnesses,[rows[2]])
        state.phase = .tabReserved
        let restored=try JSONDecoder().decode(CodexSessionAttachment.self,from:JSONEncoder().encode(state))
        let uncertain=try await services.advance(restored,save:{_ in})
        try expectEqual(uncertain.phase,.review);try expectEqual(prepared,1);try expectEqual(exits,1)
        state.phase = .needsTab
        let failed=CodexSessionAttachmentServices(exit:{exits+=1;return true},shellReady:{true},launch:{true},verify:{false},prepareReplacement:{throw AppError.message("Owned tab failed")})
        let rejected=try await failed.advance(state,save:{_ in});try expectEqual(rejected.phase,.review);try expectEqual(exits,1)
        try expect(rejected.preparationNotStarted != true)
        let notStarted=CodexSessionAttachmentServices(exit:{exits+=1;return true},shellReady:{true},launch:{true},verify:{false},prepareReplacement:{throw RemoteHTTPError(409,"Not started",diagnostics:["delivery":"not_started"])})
        let retryable=try await notStarted.advance(state,save:{_ in})
        try expectEqual(retryable.phase,.review);try expectEqual(retryable.preparationNotStarted,true);try expectEqual(exits,1)
    }
    func testCodexReplacementShellAllowsItsOwnLoginButNotSiblingWork() throws {
        let rows=ProcessDiscovery.parse("""
        810 1 ttys031 810 810 Mon Nov 2 10:00:00 2026 login
        811 810 ttys031 810 810 Mon Nov 2 10:00:01 2026 /bin/zsh
        """)
        var state=attachmentPlan();state.context.shell=rows[1]
        try expectEqual(state.context.verifiedShell(in:rows),rows[1],"A shell's own login supervisor is not sibling work")
        let other=ProcessDiscovery.parse("812 811 ttys031 810 810 Mon Nov 2 10:00:02 2026 /bin/sleep")
        try expect(state.context.verifiedShell(in:rows+other)==nil)
        let unrelated=ProcessDiscovery.parse("813 1 ttys031 810 810 Mon Nov 2 10:00:02 2026 login")
        try expect(state.context.verifiedShell(in:rows+unrelated)==nil)
        var loginOnly=state;loginOnly.context.shell=rows[0]
        try expect(loginOnly.context.verifiedShell(in:[rows[0]])==nil)
    }
    private func attachmentPlan() ->CodexSessionAttachment {
        let records=ProcessDiscovery.parse("""
        810 1 ttys031 810 811 Mon Nov 2 10:00:00 2026 /bin/zsh
        811 810 ttys031 811 811 Mon Nov 2 10:01:00 2026 /fixture/bin/codex
        """)
        var session=ProcessDiscovery.sessions(records)[0];session.cwd="/fixture/한글 '$(literal)";session.automatic=false
        return .init(context:.init(session:session,process:records[1],shell:records[0],conversationID:"00000000-0000-4000-8000-000000000061"),home:"/fixture/home space/.codex")
    }
    func testCodexAttachmentSequentialReservationsAndVerification() async throws {
        var state=attachmentPlan(),exitCalls=0,launchCalls=0,ready=false,connected=false,saved:[CodexSessionAttachment.Phase]=[]
        let services=CodexSessionAttachmentServices(exit:{exitCalls+=1;try expectEqual(saved.last,.exitReserved);return true},shellReady:{ready},launch:{launchCalls+=1;try expectEqual(saved.last,.launchReserved);return true},verify:{connected})
        state=try await services.advance(state,save:{saved.append($0.phase)})
        try expectEqual(state.phase,.waitingShell);try expectEqual(exitCalls,1);try expectEqual(launchCalls,0)
        ready=true;state=try await services.advance(state,save:{saved.append($0.phase)})
        try expectEqual(state.phase,.verifying);try expectEqual(launchCalls,1)
        state=try await services.advance(state,save:{saved.append($0.phase)})
        try expectEqual(exitCalls,1);try expectEqual(launchCalls,1)
        connected=true;state=try await services.advance(state,save:{saved.append($0.phase)})
        try expectEqual(state.phase,.connected);try expectEqual(state.context.session.automatic,false)
    }
    func testCodexAttachmentRestartAndAmbiguousDeliveryDoNotReplay() async throws {
        for phase in [CodexSessionAttachment.Phase.exitReserved,.launchReserved,.review] {
            var state=attachmentPlan();state.phase=phase;var calls=0
            let service=CodexSessionAttachmentServices(exit:{calls+=1;return true},shellReady:{false},launch:{calls+=1;return true},verify:{false})
            let restored=try JSONDecoder().decode(CodexSessionAttachment.self,from:JSONEncoder().encode(state))
            let result=try await service.advance(restored,save:{_ in})
            try expectEqual(result.phase,.review);try expectEqual(calls,0)
        }
        for failedExit in [true,false] {
            var calls=0
            let service=CodexSessionAttachmentServices(exit:{calls+=1;return !failedExit},shellReady:{true},launch:{calls+=1;return false},verify:{throw AppError.message("Unreachable")})
            let result=try await service.advance(attachmentPlan(),save:{_ in})
            try expectEqual(result.phase,.review);try expectEqual(calls,failedExit ? 1:2)
            _ = try await service.advance(result,save:{_ in});try expectEqual(calls,failedExit ? 1:2)
        }
        var expired=attachmentPlan();expired.phase = .waitingShell;expired.context.deadline=Date(timeIntervalSince1970:0)
        var writes=0
        let service=CodexSessionAttachmentServices(exit:{writes+=1;return true},shellReady:{true},launch:{writes+=1;return true},verify:{true})
        let result=try await service.advance(expired,save:{_ in})
        try expectEqual(result.phase,.review);try expectEqual(writes,0)
        for phase in [CodexSessionAttachment.Phase.exitReserved,.launchReserved,.verifying] {
            var state=attachmentPlan();state.phase=phase;state.context.deadline=Date().addingTimeInterval(60)
            if phase == .verifying {state.context.deadline=Date(timeIntervalSince1970:0)}
            var exits=0,launches=0
            let proof=CodexSessionAttachmentServices(exit:{exits+=1;return true},shellReady:{true},launch:{launches+=1;return true},verify:{true})
            let recovered=try await proof.advance(state,save:{_ in})
            try expectEqual(recovered.phase,.connected);try expectEqual(exits,0);try expectEqual(launches,phase == .exitReserved ? 1:0)
        }
    }
    func testCodexAttachmentPersistenceFailurePreventsTerminalInput() async throws {
        var calls=0
        let service=CodexSessionAttachmentServices(exit:{calls+=1;return true},shellReady:{true},launch:{calls+=1;return true},verify:{true})
        do {_ = try await service.advance(attachmentPlan(),save:{_ in throw AppError.message("Synthetic disk failure")});throw AppError.message("Must fail")}
        catch {try expectEqual(calls,0)}
    }
    func testCodexAttachmentCommandKeepsHomeConversationAndNoPrompt() throws {
        var state=attachmentPlan();guard let command=state.command else{throw AppError.message("Expected attachment command")}
        try expect(command.contains("'CODEX_HOME=/fixture/home space/.codex'"));try expect(command.contains("'--remote' 'unix://' 'resume' '00000000-0000-4000-8000-000000000061'"))
        try expectFalse(command.contains("--last"));try expectFalse(command.contains(CodexCapacityStop.resumeText))
        state.context.conversationID=nil;try expect(state.command==nil)
        let root=URL(fileURLWithPath:"/private/tmp/aa-attachment-goal-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        try expect(try CodexSessionAttachment.goalIfPresent(home:root.path,threadID:"00000000-0000-4000-8000-000000000061")==nil)
        try Data("invalid database".utf8).write(to:root.appendingPathComponent("goals_1.sqlite"))
        var rejected=false
        do {_ = try CodexSessionAttachment.goalIfPresent(home:root.path,threadID:"00000000-0000-4000-8000-000000000061")}catch{rejected=true}
        try expect(rejected,"Unreadable existing Goal data must not authorize exit")
        let records=ProcessDiscovery.parse("""
        810 1 ttys031 810 811 Mon Nov 2 10:00:00 2026 /bin/zsh
        811 810 ttys031 811 811 Mon Nov 2 10:01:00 2026 /fixture/bin/codex
        812 811 ttys031 811 811 Mon Nov 2 10:01:01 2026 /fixture/bin/node
        813 811 ttys031 813 811 Mon Nov 2 10:01:02 2026 /fixture/bin/codex-code-mode-host
        """)
        try expectFalse(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records),"Idle tool hosts sharing the CLI job do not block attachment")
        let toolHosts=ProcessDiscovery.parse("""
        816 811 ttys031 816 811 Mon Nov 2 10:01:04 2026 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
        817 811 ttys031 817 811 Mon Nov 2 10:01:04 2026 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node
        """)
        try expect(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records+toolHosts),"Automatic attachment cannot assume tool hosts are idle")
        let grant=CodexSessionAttachment.toolHosts(process:records[1],records:records+toolHosts)
        try expectEqual(grant.count,2)
        try expectFalse(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records+toolHosts,authorizedToolHosts:grant))
        for field in ["executable","tty","group"] {
            var other=toolHosts[0]
            if field=="executable" {other.executable=other.executable.replacingOccurrences(of:"node_repl",with:"node")}
            if field=="tty" {other.tty="ttys099"}
            if field=="group" {other.processGroup=999}
            try expect(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records+[other],authorizedToolHosts:grant))
        }
        let descendant=ProcessDiscovery.parse("819 816 ttys031 816 811 Mon Nov 2 10:01:05 2026 /bin/sleep")
        try expect(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records+toolHosts+descendant,authorizedToolHosts:grant))
        var changed=toolHosts[0];changed.started="new instance"
        try expect(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records+[changed],authorizedToolHosts:grant))
        changed=toolHosts[0];changed.pid=999
        try expect(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records+[changed],authorizedToolHosts:grant))
        let unrelatedNode=ProcessDiscovery.parse("818 811 ttys031 818 811 Mon Nov 2 10:01:05 2026 /opt/bin/node")
        try expect(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records+unrelatedNode))
        let work=ProcessDiscovery.parse("814 811 ttys032 814 814 Mon Nov 2 10:01:03 2026 /bin/bash")
        try expect(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records+work))
        let agent=ProcessDiscovery.parse("815 811 ttys031 811 811 Mon Nov 2 10:01:04 2026 /fixture/bin/codex")
        try expect(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records+agent))
    }
}
