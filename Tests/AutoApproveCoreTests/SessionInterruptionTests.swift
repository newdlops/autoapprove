import Foundation
import AutoApproveCore

private func interruptionFrame(_ error: String, agent: AgentKind) -> String {
    error + "\n\n" + (agent == .claude ? "❯ " : "› Ask Codex to do anything") + "\n\n? for shortcuts"
}

private final class InterruptionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var inputs: [String] = []
    let reply: ResumeDelivery
    init(_ reply: ResumeDelivery = .sent) { self.reply = reply }
    func send(_ text: String = CodexCapacityStop.resumeText) -> ResumeDelivery { lock.lock(); defer { lock.unlock() }; calls += 1; inputs.append(text); return reply }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return inputs }
}

private final class ExitProbe: @unchecked Sendable {
    let lock = NSLock()
    var records: [ProcessRecord] = []
    var commands: [String] = []
    var uncertain = false
    var screen = "To continue this session, run codex resume 00000000-0000-4000-8000-000000000061\nqa% "
    func read() -> [ProcessRecord] { lock.lock(); defer {lock.unlock()}; return records }
    func launch(_ command: String) throws -> TerminalDelivery {
        lock.lock(); defer {lock.unlock()}; commands.append(command)
        if uncertain { throw AppError.message("QA lost result after write") }
        return .sent
    }
}

extension ApprovalTests {
    func testGoalFailureRecoveryUsesLifecycleCommand() throws {
        let frame = interruptionFrame("■ stream disconnected before completion: network error",agent:.codex)
        let stalled = frame.replacingOccurrences(of:"? for shortcuts",with:"? for shortcuts · Goal stalled (/goal resume)")
        guard let stop = CodexCapacityStop.detect(stalled,agent:.codex) else { throw AppError.message("Expected an interrupted Goal") }
        try expectEqual(stop.continuationText,"/goal resume")
        try expectEqual(CodexCapacityStop.detect(frame,agent:.codex)?.continuationText,"이어서 진행하자.")
        try expect(CodexResumeCheck.ready(stalled,region:stop.region,text:stop.continuationText))
        try expectFalse(CodexResumeCheck.ready(stalled,region:stop.region,text:CodexCapacityStop.resumeText))
        for status in ["Goal paused (/goal resume)","Goal hit usage limits (/goal resume)","Goal budget reached","Goal achieved (1h)"] {
            let held = stalled.replacingOccurrences(of:"Goal stalled (/goal resume)",with:status)
            try expect(CodexCapacityStop.detect(held,agent:.codex) == nil,"A held or completed Goal is never resumed")
            try expectFalse(CodexResumeCheck.ready(held,region:stop.region,text:stop.continuationText))
        }
        try expect(CodexCapacityStop.detect(stalled.replacingOccurrences(of:"› Ask Codex to do anything",with:"› 1"),agent:.codex) == nil,"Preserve a user draft, even a single digit")
        try expect(CodexCapacityStop.detect(stalled.replacingOccurrences(of:"■ stream disconnected before completion: network error",with:"• Work complete"),agent:.codex) == nil,"Stalled alone cannot trigger a retry")
        let quoted = "Goal stalled (/goal resume)\n\n"+frame
        try expectEqual(CodexCapacityStop.detect(quoted,agent:.codex)?.continuationText,CodexCapacityStop.resumeText,"Only the current status footer counts")
        let working = "› 이어서 진행하자.\n\nWorking · esc to interrupt"
        try expectFalse(CodexResumeCheck.draftVisible(working,text:CodexCapacityStop.resumeText))
        let plain = CodexCapacityStop.detect(frame,agent:.codex)!
        try expectEqual(CodexResumeCheck.state(before:frame,after:working,region:plain.region,text:plain.continuationText),.submitted)
        try expectEqual(CodexResumeCheck.state(before:frame,after:"",region:plain.region,text:plain.continuationText),.typed)
        let resumed = stalled.replacingOccurrences(of:"Goal stalled (/goal resume)",with:"Pursuing goal")
        try expectEqual(CodexResumeCheck.state(before:stalled,after:resumed,region:stop.region,text:stop.continuationText),.submitted)
        try expectEqual(CodexResumeCheck.state(before:stalled,after:stalled,region:stop.region,text:stop.continuationText),.typed)
        var legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(stop)) as! JSONObject
        legacy.removeValue(forKey:"inputText")
        try expectEqual(try JSONDecoder().decode(CodexCapacityStop.self,from:JSONSerialization.data(withJSONObject:legacy)).continuationText,CodexCapacityStop.resumeText)
    }

    @MainActor func testGoalRecoveryRetiresNumericApprovalAndAuditsActualCommand() async throws {
        let directory = URL(fileURLWithPath:"/private/tmp/aa-goal-error-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let record = ProcessDiscovery.parse("42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0]
        let approval = InterruptionProbe(), recovery = InterruptionProbe()
        let adapter = ScreenHostAdapter(screens:{_ in TerminalSnapshot()},approve:{_,_,_ in _ = approval.send("1"); return .sent},reveal:{_ in nil},resume:{_,_,text in recovery.send(text)})
        let engine = try ApprovalEngine(paths:AppPaths(directory:directory),processReader:{[record]},screenAdapters:[.terminal:adapter])
        defer {engine.stop()}
        engine.interruptionResumeDelays = [0.02]
        var session = AgentSession(id:record.key,agent:.codex,pid:record.pid,started:record.started,tty:"/dev/ttys901",cwd:"/tmp/qa",terminal:.terminal)
        session.channel = .terminalScreen; engine.updateDiscovery([session],records:[record]); try engine.setAutomatic(session.id,enabled:true)
        let permission = "Would you like to run the following command?\n\n$ echo QA\n\n› 1. Yes\n  2. No\n\nEnter to confirm or esc to cancel"
        engine.receiveScreen(sessionID:session.id,raw:permission,generation:"QA")
        let frame = interruptionFrame("■ stream disconnected before completion: network error",agent:.codex)+" · Goal stalled (/goal resume)"
        engine.receiveScreen(sessionID:session.id,raw:permission+"\n\n"+frame,generation:"QA")
        try expectEqual(engine.snapshot.sessions.first?.capacityResume?.message,"/goal resume")
        try await Task.sleep(for:.milliseconds(250))
        try expectEqual(approval.count,0,"A permission replaced by an error cannot type 1 into its composer")
        try expectEqual(recovery.texts,["/goal resume"])
        try expectEqual(engine.snapshot.events.first?.answer,"/goal resume")
        try expectEqual(engine.snapshot.sessions.first?.capacityResume?.phase,.awaiting)
        engine.receiveScreen(sessionID:session.id,raw:permission+"\n\n"+frame,generation:"QA")
        try await Task.sleep(for:.milliseconds(80)); try expectEqual(recovery.count,1)
        engine.receiveScreen(sessionID:session.id,raw:"Working · esc to interrupt\n\n› Ask Codex to do anything\n\n? for shortcuts · Pursuing goal",generation:"QA")
        try expectNotNil(engine.snapshot.sessions.first?.interruption?.recoveredAt)
    }

    func testSessionInterruptionDetection() throws {
        let examples: [(AgentKind,String,SessionInterruption.Kind)] = [
            (.codex,"■ stream disconnected before completion: Transport error: network error: error decoding response body",.transport),
            (.codex,"■ unexpected status 503 Service Unavailable",.api),
            (.claude,"API Error: 529 server overloaded",.api),
            (.claude,"API Error: Connection error.",.transport),
            (.claude,"API Error: 401 unauthorized",.authentication)
        ]
        for (agent,error,kind) in examples {
            let frame = interruptionFrame(error,agent:agent)
            let stop = CodexCapacityStop.detect(frame,agent:agent)
            try expectEqual(stop?.kind,kind); try expectEqual(stop?.agent,agent)
            try expectNil(CodexCapacityStop.detect(frame.replacingOccurrences(of:"? for shortcuts",with:"esc to interrupt"),agent:agent))
            try expectNil(CodexCapacityStop.detect(frame.replacingOccurrences(of:error,with:"Note: "+error),agent:agent))
            let glyph = agent == .claude ? "❯ " : "› Ask Codex to do anything"
            try expectNil(CodexCapacityStop.detect(frame.replacingOccurrences(of:glyph,with:(agent == .claude ? "❯ " : "› ")+"직접 작성 중"),agent:agent))
            try expectNil(CodexCapacityStop.detect(frame.replacingOccurrences(of:"\n\n"+glyph,with:"\n\n● Completed a later response\n\n"+glyph),agent:agent))
        }
    }

    func testInterruptionNotificationKeepsEndedFailureAndDeduplicates() throws {
        var session = AgentSession(id:"qa-error",agent:.codex,pid:41,started:"QA",tty:"/dev/ttys901",cwd:"/tmp/qa",terminal:.terminal)
        session.interruption = SessionInterruption(id:"episode",kind:.transport,detail:"network error")
        session.setPhase(.ended,detail:"CLI exited")
        let directory = URL(fileURLWithPath:"/private/tmp/aa-error-notice-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let engine = try ApprovalEngine(paths:AppPaths(directory:directory),processReader:{ [] })
        var snapshot = engine.snapshot; snapshot.sessions = [session]
        var tracker = AttentionTracker()
        let first = tracker.update(snapshot), second = tracker.update(snapshot)
        try expectEqual(first.count,1); try expectEqual(first.first?.kind,.interruption)
        try expectEqual(first.first?.id,second.first?.id)
        try expect(first.first?.title.contains("작업 중단") == true)
        try expect(session.needsReview); try expectEqual(session.phaseTitle,"오류로 종료됨")
        var normal = session; normal.interruption = nil
        snapshot.sessions = [normal]
        try expectEqual(tracker.update(snapshot).count,0)
        var inbox = SessionInbox(); let now = Date()
        let candidate = SessionInbox.Candidate(key:"error",kind:.question,summary:"작업 중단",isInterruption:true)
        inbox.update([candidate],at:now); inbox.update([candidate],at:now.addingTimeInterval(1))
        try expectEqual(inbox.entries.first?.title,"작업 중단")
    }

    @MainActor func testTransientRecoverySupportsClaudeAndPersistsUncertainWrites() async throws {
        let directory = URL(fileURLWithPath:"/private/tmp/aa-interruption-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        for agent in [AgentKind.codex,.claude] {
            let record = ProcessDiscovery.parse("42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/"+agent.rawValue)[0]
            let probe = InterruptionProbe(.typed)
            let adapter = ScreenHostAdapter(screens:{ _ in TerminalSnapshot() },approve:{ _,_,_ in .sent },reveal:{ _ in nil },resume:{ _,_,_ in probe.send() })
            let paths = AppPaths(directory:directory.appendingPathComponent(agent.rawValue))
            func engine() throws -> ApprovalEngine {
                let value = try ApprovalEngine(paths:paths,processReader:{ [record] },screenAdapters:[.terminal:adapter])
                value.interruptionResumeDelays = [0.03]
                var session = AgentSession(id:record.key,agent:agent,pid:record.pid,started:record.started,tty:"/dev/ttys901",cwd:"/tmp/qa",terminal:.terminal)
                session.channel = .terminalScreen; value.updateDiscovery([session],records:[record]); return value
            }
            let frame = interruptionFrame(agent == .codex ? "■ stream disconnected before completion: network error" : "API Error: Connection error.",agent:agent)
            let subject = try engine(); try subject.setAutomatic(record.key,enabled:true)
            subject.receiveScreen(sessionID:record.key,raw:frame,generation:"QA")
            try expectEqual(subject.snapshot.sessions.first?.interruption?.kind,.transport)
            try await Task.sleep(for:.milliseconds(250))
            try expectEqual(probe.count,1); try expectEqual(subject.snapshot.sessions.first?.capacityResume?.phase,.review)
            subject.stop()
            let restored = try engine(); restored.receiveScreen(sessionID:record.key,raw:frame,generation:"QA")
            try await Task.sleep(for:.milliseconds(250))
            try expectEqual(probe.count,1,"An app restart cannot repeat an uncertain continuation")
            try expectEqual(restored.snapshot.sessions.first?.capacityResume?.phase,.review)
            restored.stop()
        }
    }

    func testExitedRecoveryRequiresExactConversationAndIdleOriginalShell() throws {
        let records = ProcessDiscovery.parse("""
        41 1 ttys901 41 42 Mon Sep 21 09:00:00 2026 /bin/zsh
        42 41 ttys901 42 42 Mon Sep 21 09:00:01 2026 /tmp/qa folder/codex
        """)
        let session = AgentSession(id:records[1].key,agent:.codex,pid:42,started:records[1].started,tty:"/dev/ttys901",cwd:"/tmp/qa",terminal:.terminal)
        let plan = SessionExitRecovery(session:session,process:records[1],shell:records[0],conversationID:"00000000-0000-4000-8000-000000000061")
        try expect(plan.command?.contains("'resume' '00000000-0000-4000-8000-000000000061'") == true)
        try expect(!plan.command!.contains("--last")); try expect(!plan.command!.contains("fork"))
        try expectNil(plan.verifiedShell(in:records))
        var shell = records[0]; shell.foregroundGroup = 41
        try expectNotNil(plan.verifiedShell(in:[shell]))
        var other = records[1]; other.pid = 44; other.processGroup = 41
        try expectNil(plan.verifiedShell(in:[shell,other]))
        shell.started = "changed"; try expectNil(plan.verifiedShell(in:[shell]))
        try expect(SessionExitRecovery.emptyShellPrompt("history\nqa% "))
        try expect(!SessionExitRecovery.emptyShellPrompt("qa% unfinished command"))
        try expect(!SessionExitRecovery.emptyShellPrompt("❯ "))
        try expectEqual(SessionExitRecovery.conversation(in:"To continue this session, run codex resume 00000000-0000-4000-8000-000000000061\nqa% "),"00000000-0000-4000-8000-000000000061")
        try expectNil(SessionExitRecovery.conversation(in:"Example: To continue this session, run codex resume 00000000-0000-4000-8000-000000000061"))
        var unknown = plan; unknown.conversationID = nil; try expectNil(unknown.command)
        let script = try TerminalAdapter.restartScript(target:ScreenTarget(tty:session.tty),expected:"qa%",command:plan.command!)
        try expect(script.contains("jobs.length !== 1")); try expect(script.contains("if (tab.tty() !== target.tty)"))
    }

    @MainActor func testExitedRecoveryRestoresExactConversationAndNeverReplays() async throws {
        for uncertain in [false,true] {
            let directory = URL(fileURLWithPath:"/private/tmp/aa-exit-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:directory)}
            let records = ProcessDiscovery.parse("""
            41 1 ttys901 41 42 Mon Sep 21 09:00:00 2026 /bin/zsh
            42 41 ttys901 42 42 Mon Sep 21 09:00:01 2026 /usr/local/bin/claude
            """)
            let probe = ExitProbe(); probe.records = records; probe.uncertain = uncertain
            let adapter = ScreenHostAdapter(screens:{ targets in TerminalSnapshot(screens:targets.map {TerminalScreen(tty:$0.tty,contents:probe.screen)}) },approve:{_,_,_ in .sent},reveal:{_ in nil},restart:{_,_,command in try probe.launch(command)})
            let paths = AppPaths(directory:directory)
            let engine = try ApprovalEngine(paths:paths,claudeRegistryReader:{_ in []},processReader:{probe.read()},screenAdapters:[.terminal:adapter])
            await engine.connectScreenHost(.terminal)
            engine.interruptionResumeDelays = [0.01]
            var session = AgentSession(id:records[1].key,agent:.claude,pid:42,started:records[1].started,tty:"/dev/ttys901",cwd:"/tmp/qa",terminal:.terminal)
            session.providerID = "00000000-0000-4000-8000-000000000061"; session.channel = .terminalScreen
            engine.updateDiscovery([session],records:records); try engine.setAutomatic(session.id,enabled:true)
            engine.receiveScreen(sessionID:session.id,raw:interruptionFrame("API Error: Connection error.",agent:.claude),generation:"QA")
            var shell = records[0]; shell.foregroundGroup = shell.processGroup; probe.records = [shell]
            engine.updateDiscovery([],records:[shell]); try await Task.sleep(for:.milliseconds(30)); engine.updateDiscovery([],records:[shell])
            try await Task.sleep(for:.milliseconds(1400))
            try expectEqual(probe.commands.count,1)
            try expect(probe.commands[0].contains("'--resume' '00000000-0000-4000-8000-000000000061'"))
            try expectEqual(engine.snapshot.sessions.first?.interruption?.recoveryStatus,uncertain ? "review" : "awaiting")
            engine.stop()
            let restored = try ApprovalEngine(paths:paths,claudeRegistryReader:{_ in []},processReader:{probe.read()},screenAdapters:[.terminal:adapter])
            restored.updateDiscovery([],records:[shell]); try await Task.sleep(for:.milliseconds(50)); try expectEqual(probe.commands.count,1)
            try expectEqual(restored.snapshot.sessions.first?.phase,.ended)
            if !uncertain {
                var process = records[1]; process.pid = 43; process.started = "Mon Sep 21 09:01:00 2026"; process.processGroup = 43; process.foregroundGroup = 43
                var next = session; next.id = process.key; next.pid = process.pid; next.started = process.started; next.channel = .terminalScreen
                probe.records = [shell,process]; restored.updateDiscovery([next],records:probe.records)
                try await Task.sleep(for:.milliseconds(100))
                let old = restored.snapshot.sessions.first {$0.id == session.id}
                try expectEqual(old?.interruption?.resumedSessionID,next.id); try expectNotNil(old?.interruption?.recoveredAt)
                try expect(restored.snapshot.sessions.first {$0.id == next.id}?.automatic == true)
            }
            restored.stop()
        }
    }

    @MainActor func testNormalExitDoesNotRestartAndEmptyRecoveryScheduleIsSafe() async throws {
        let directory = URL(fileURLWithPath:"/private/tmp/aa-normal-exit-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let record = ProcessDiscovery.parse("42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0]
        let probe = ExitProbe(), adapter = ScreenHostAdapter(screens:{_ in TerminalSnapshot()},approve:{_,_,_ in .sent},reveal:{_ in nil},restart:{_,_,command in try probe.launch(command)})
        let engine = try ApprovalEngine(paths:AppPaths(directory:directory),processReader:{[]},screenAdapters:[.terminal:adapter])
        var session = AgentSession(id:record.key,agent:.codex,pid:42,started:record.started,tty:"/dev/ttys901",cwd:"/tmp/qa",terminal:.terminal)
        session.channel = .terminalScreen; engine.updateDiscovery([session],records:[record]); try engine.setAutomatic(record.key,enabled:true)
        engine.updateDiscovery([],records:[]); try await Task.sleep(for:.milliseconds(50))
        try expectEqual(probe.commands.count,0); try expectNil(engine.snapshot.sessions.first?.interruption)
        var nextRecord = record; nextRecord.pid = 43
        session.id = nextRecord.key; session.pid = nextRecord.pid
        engine.updateDiscovery([session],records:[nextRecord]); try engine.setAutomatic(nextRecord.key,enabled:true)
        engine.interruptionResumeDelays = []
        engine.receiveScreen(sessionID:nextRecord.key,raw:interruptionFrame("■ network error",agent:.codex),generation:"QA")
        try expectEqual(engine.snapshot.sessions.first {$0.id == nextRecord.key}?.capacityResume?.phase,.review); engine.stop()
    }

    func testStopFailureHookMigrationPreservesUserHooks() throws {
        let directory = URL(fileURLWithPath:"/private/tmp/aa-stop-failure-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url = directory.appendingPathComponent("settings.json"), executable = "/tmp/autoapprove"
        var settings = HookInstaller.merged(["env":["KEEP":"yes"]],executable:executable)
        var hooks = settings["hooks"] as! [String:[JSONObject]]; hooks.removeValue(forKey:"StopFailure"); settings["hooks"] = hooks
        try JSONSerialization.data(withJSONObject:settings).write(to:url)
        try expectNotNil(try HookInstaller.upgradeTimeouts(executable:executable,url:url))
        let migrated = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! JSONObject
        try expectEqual((migrated["env"] as? [String:String])?["KEEP"],"yes")
        try expectNotNil((migrated["hooks"] as? [String:[JSONObject]])?["StopFailure"])
        try expectNil(try HookInstaller.upgradeTimeouts(executable:executable,url:url))
        hooks["StopFailure"] = []; settings["hooks"] = hooks
        try JSONSerialization.data(withJSONObject:settings).write(to:url)
        try expectNil(try HookInstaller.upgradeTimeouts(executable:executable,url:url))
        try expectEqual(SessionInterruption.Kind.claudeFailure("billing_error"),.configuration)
        try expect(!SessionInterruption.Kind.claudeFailure("authentication_failed").retryable)
    }

    @MainActor func testCompactInventoryDefersAuditWithoutLosingExactHistory() async throws {
        let directory = URL(fileURLWithPath:"/private/tmp/aa-cold-inventory-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let paths = AppPaths(directory:directory); try paths.prepare()
        let store = try AuditStore(path:paths.database)
        let record = ProcessDiscovery.parse("42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0]
        let session = AgentSession(id:record.key,agent:.codex,pid:42,started:record.started,tty:"/dev/ttys901",cwd:"/tmp/qa",terminal:.terminal)
        for index in 0..<200 { try store.append(AuditEvent(sessionID:session.id,summary:"QA \(index)",outcome:"승인 전달",source:"QA",request:String(repeating:"private audit body ",count:500))) }
        let engine = try ApprovalEngine(paths:paths,processReader:{[record]})
        engine.updateDiscovery([session],records:[record]); try engine.setWebEnabled(true,port:0,bonjourEnabled:false,discoveryAddresses:{[]})
        defer {engine.stop()}
        let service = engine.webService!
        func get(_ route: String) async throws -> RemoteHTTPResponse {
            let request = try RemoteHTTPRequest.parse(Data("GET \(route) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))!
            return await service.handle(request)
        }
        let full = try await get("/api/state"), initial = try await get("/api/network?initial=1")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(RemoteDashboard.self,from:initial.body)
        try expectEqual(value.partial,true); try expectEqual(value.nodes.first?.state?.sessions.count,1)
        try expectEqual(value.nodes.first?.state?.snapshot.sessions.count,0); try expectEqual(value.nodes.first?.state?.snapshot.events.count,0)
        try expect(initial.body.count * 100 < full.body.count,"Inventory must not carry full audit bodies")
        let history = try await get("/api/history?session="+session.id.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed)!)
        let events = try decoder.decode([AuditEvent].self,from:history.body)
        try expectEqual(events.count,12); try expect(events.allSatisfy {$0.request?.contains("private audit body") == true})
        let missing = try await get("/api/history?session=other"); try expectEqual(missing.status,404)
    }

    @MainActor func testClaudeStopFailurePublishesAnErrorAndClearsOnUserProgress() throws {
        let directory = URL(fileURLWithPath:"/private/tmp/aa-failure-hook-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let record = ProcessDiscovery.parse("42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/claude")[0]
        let engine = try ApprovalEngine(paths:AppPaths(directory:directory),claudeRegistryReader:{_ in []},processReader:{[record]})
        engine.updateDiscovery(ProcessDiscovery.sessions([record]),records:[record])
        var payload: JSONObject = ["hook_event_name":"StopFailure","session_id":"00000000-0000-4000-8000-000000000061","requestID":UUID().uuidString,
            "agentPID":42,"agentStarted":record.started,"tty":"/dev/ttys901","error":"server_error","error_details":"API Error: 503"]
        _ = engine.handleHook(payload)
        try expectEqual(engine.snapshot.sessions.first?.interruption?.kind,.api)
        try expectNil(engine.snapshot.sessions.first?.completion)
        payload["hook_event_name"] = "UserPromptSubmit"; payload["requestID"] = UUID().uuidString
        _ = engine.handleHook(payload)
        try expectNotNil(engine.snapshot.sessions.first?.interruption?.recoveredAt)
        try expectEqual(engine.snapshot.sessions.first?.phase,.working); engine.stop()
    }
}
