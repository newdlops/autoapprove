import Foundation
import AutoApproveCore

extension ApprovalTests {
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
        let work=ProcessDiscovery.parse("814 811 ttys032 814 814 Mon Nov 2 10:01:03 2026 /bin/bash")
        try expect(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records+work))
        let agent=ProcessDiscovery.parse("815 811 ttys031 811 811 Mon Nov 2 10:01:04 2026 /fixture/bin/codex")
        try expect(CodexSessionAttachment.hasIndependentChildWork(process:records[1],records:records+agent))
    }
}
