import Foundation
import JavaScriptCore
import AutoApproveCore

private func recoveryPrompt(_ command: String, agent: AgentKind = .codex) -> String {
    let heading = agent == .codex ? "Would you like to run the following command?" : "Bash command\n  \(command)\nDo you want to proceed?"
    let context = agent == .codex ? "\n\n  $ \(command)" : ""
    return heading + context + "\n\n› 1. Yes\n  2. No\n\nEnter to confirm or esc to cancel"
}

private final class ApprovalRecoveryProbe: @unchecked Sendable {
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var calls: [(ScreenTarget, String)] = []
    var blockedTTY: String?
    var rejectFirst = false
    var throwFirst = false
    func approve(_ target: ScreenTarget, _ raw: String) throws -> TerminalDelivery {
        lock.lock(); calls.append((target, raw)); let first = calls.count == 1; lock.unlock()
        if first && target.tty == blockedTTY { _ = gate.wait(timeout: .now() + 5) }
        if first && throwFirst { throw AppError.message("Fixture lost delivery receipt") }
        return first && rejectFirst ? .screenChanged : .sent
    }
    func release() { gate.signal() }
    var inputs: [(ScreenTarget, String)] { lock.lock(); defer { lock.unlock() }; return calls }
}

private final class NativeTypingActivity:@unchecked Sendable {
    private let lock = NSLock()
    private var idle:TimeInterval = 0,bundle:String? = ScreenHost.iterm.bundleID
    func set(idle:TimeInterval,bundle:String?) {lock.lock();self.idle = idle;self.bundle = bundle;lock.unlock()}
    var activity:NativeKeyboardActivity {NativeKeyboardActivity(idleSeconds:{self.lock.lock();defer {self.lock.unlock()};return self.idle},frontmostBundle:{self.lock.lock();defer {self.lock.unlock()};return self.bundle})}
}

private final class NativeTypingValidationGate:@unchecked Sendable {
    private let lock = NSLock(),gate = DispatchSemaphore(value:0)
    private var entered = false
    func wait() {lock.lock();let first = !entered;entered = true;lock.unlock();if first {_ = gate.wait(timeout:.now()+3)}}
    var started:Bool {lock.lock();defer {lock.unlock()};return entered}
    func release() {gate.signal()}
}

private let computerUsePermission="""
Field 1/1
Allow Computer Use to use "AutoApprove Profiles QA"?

App: AutoApprove Profiles QA

› 1. Allow                  Run the tool and continue
  2. Allow for this session Run the tool and remember this choice for this session
  3. Always allow           Run the tool and remember this choice for future tool calls
  4. Cancel                 Cancel this tool call
enter to submit | esc to cancel
"""
private final class DeliveredFrameProbe:@unchecked Sendable {
    let frame:String
    private let lock=NSLock()
    private var reads:[ScreenTarget]=[]
    init(_ frame:String) {self.frame=frame}
    func read(_ targets:[ScreenTarget]) -> TerminalSnapshot {
        lock.lock();reads += targets;lock.unlock()
        return .init(screens:targets.map {.init(tty:$0.tty,contents:frame)})
    }
    var targets:[ScreenTarget] {lock.lock();defer {lock.unlock()};return reads}
}

extension ApprovalTests {
    func testComputerUseFieldSubmissionUsesReturnWithoutTextPaste() throws {
        let context=JSContext()!
        context.setObject(computerUsePermission,forKeyedSubscript:"frame" as NSString)
        context.evaluateScript("""
        var writes=[],submitted=0,pasted=0;
        const fixtureTab={tty:()=>'/dev/fixture',contents:()=>frame,processes:()=>['codex']};
        function Application(){return {running:()=>true,windows:()=>[{tabs:()=>[fixtureTab]}],doScript:(text,options)=>{
          if(options.in!==fixtureTab)throw Error('wrong tab');writes.push(text);
          // Text plus Return is a paste to Codex's single-choice field. A
          // standalone Return submits the already selected Allow option.
          if(text.length)pasted++;else submitted++;
        }};}
        """)
        let script=try TerminalAdapter.approvalScript(tty:"/dev/fixture",expectedScreen:computerUsePermission,agent:.codex)
        try expectEqual(context.evaluateScript(script)?.toString(),"sent");try expectNil(context.exception)
        try expectEqual(context.evaluateScript("submitted")?.toInt32(),1,"Computer Use fields need standalone Return, not pasted numeric text")
        try expectEqual(context.evaluateScript("pasted")?.toInt32(),0)
        try expectEqual(context.evaluateScript("writes.length")?.toInt32(),1)
        context.setObject(computerUsePermission.replacingOccurrences(of:"› 1.",with:"  1.").replacingOccurrences(of:"  4.",with:"› 4."),forKeyedSubscript:"frame" as NSString)
        try expectEqual(context.evaluateScript(script)?.toString(),"screenChanged")
        try expectEqual(context.evaluateScript("submitted")?.toInt32(),1,"A changed selection never receives Return")
    }
    func testComputerUseSamePermissionAfterFastConfirmedTransition() async throws {
        try expectEqual(PromptDetector.detect(computerUsePermission,agent:.codex)?.answer,"1")
        let probe=ApprovalRecoveryProbe(),frames=DeliveredFrameProbe("Working\nesc to interrupt")
        let (engine,sessions,directory)=try recoveryEngine(probe,host:.terminal,validation:{frames.read($0)})
        defer {engine.stop();try? FileManager.default.removeItem(at:directory)}
        let id=sessions[0].id,generation="same-computer-use"
        engine.receiveScreen(sessionID:id,raw:computerUsePermission,generation:generation)
        try await waitForRecovery({probe.inputs.count == 1},"The exact Computer Use Allow menu dispatches once")
        try await waitForRecovery({engine.snapshot.sessions.first?.phase == .working},"Read the brief real work after delivery, before the normal slow poll")
        engine.receiveScreen(sessionID:id,raw:computerUsePermission,generation:generation)
        try await waitForRecovery({probe.inputs.count == 2},"A newly requested identical Computer Use permission must not inherit the preceding reservation")
        try expect(frames.targets.allSatisfy {$0.tty == sessions[0].tty},"Follow-up observation stays on the exact original tab")
    }
    func testComputerUseFollowupNeverReplaysWithoutResolution() async throws {
        for raw in [computerUsePermission,"", "Done\n› Draft text\nGPT-6.1-Sol max · ~/fixture · Ready · Context 35% left\n⚠ 1 warning · f2 to view"] {
            let probe=ApprovalRecoveryProbe(),frames=DeliveredFrameProbe(raw)
            let (engine,sessions,directory)=try recoveryEngine(probe,host:.terminal,validation:{frames.read($0)})
            defer {engine.stop();try? FileManager.default.removeItem(at:directory)}
            engine.receiveScreen(sessionID:sessions[0].id,raw:computerUsePermission,generation:"unresolved-computer-use")
            try await waitForRecovery({probe.inputs.count == 1},"Deliver one permission")
            try await Task.sleep(for:.milliseconds(1100))
            engine.receiveScreen(sessionID:sessions[0].id,raw:computerUsePermission,generation:"unresolved-computer-use")
            try await Task.sleep(for:.milliseconds(50))
            try expectEqual(probe.inputs.count,1,"The same dialog, a blank repaint or a draft is never proof to repeat Return")
            try expect(frames.targets.count<=4,"Post-delivery reads have a strict per-request bound")
        }
    }
    func testComputerUseFollowupDiscardsPausedOrDisabledRead() async throws {
        for pause in [true,false] {
            let gate=NativeTypingValidationGate(),probe=ApprovalRecoveryProbe()
            let (engine,sessions,directory)=try recoveryEngine(probe,host:.terminal,validation:{targets in gate.wait();return .init(screens:targets.map {.init(tty:$0.tty,contents:"Working\nesc to interrupt")})})
            defer {gate.release();engine.stop();try? FileManager.default.removeItem(at:directory)}
            let id=sessions[0].id
            engine.receiveScreen(sessionID:id,raw:computerUsePermission,generation:"held-transition")
            try await waitForRecovery({gate.started},"The post-delivery read starts on the original tab")
            if pause {try engine.setPaused(true)} else {try engine.setAutomatic(id,enabled:false)}
            gate.release();try await Task.sleep(for:.milliseconds(80))
            try expectEqual(engine.snapshot.sessions.first?.phase,.approval,"A late read cannot retire a receipt after pause/OFF")
            if pause {try engine.setPaused(false)} else {try engine.setAutomatic(id,enabled:true)}
            engine.receiveScreen(sessionID:id,raw:computerUsePermission,generation:"held-transition")
            try await Task.sleep(for:.milliseconds(80));try expectEqual(probe.inputs.count,1)
        }
    }
    func testNativeTypingActivitySeparatesHostsAndPhysicalIdle() throws {
        let state = NativeTypingActivity(),activity = state.activity
        for (bundle,terminal) in [("com.apple.Terminal",TerminalKind.terminal),("com.googlecode.iterm2",.iterm),("com.stablyai.orca",.orca),("com.microsoft.VSCode",.vscode),("com.microsoft.VSCodeInsiders",.vscode),("com.todesktop.230313mzl4w4u92",.vscode),("com.exafunction.windsurf",.vscode),("com.vscodium",.vscode)] {
            state.set(idle:0.1,bundle:bundle);try expect(activity.hasPriority(terminal:terminal));try expect(activity.hasPriority(terminal:.tmux))
            try expectFalse(activity.hasPriority(terminal:.pty));try expectFalse(activity.hasPriority(terminal:.unknown))
            state.set(idle:0.1,bundle:"fixture.other-app");try expectFalse(activity.hasPriority(terminal:terminal),"Typing in another app cannot stall background approvals")
            for idle in [1.2,2,.infinity,.nan,-1] {state.set(idle:idle,bundle:bundle);try expectFalse(activity.hasPriority(terminal:terminal))}
        }
    }
    func testNativeTypingYieldsApprovalWithoutDisablingAutomation() async throws {
        let probe = ApprovalRecoveryProbe(),activity = NativeTypingActivity()
        let (engine,sessions,directory) = try recoveryEngine(probe,nativeKeyboardActivity:activity.activity)
        defer {engine.stop();try? FileManager.default.removeItem(at:directory)}
        let id = sessions[0].id,prompt = recoveryPrompt("echo native-input")
        for _ in 0..<12 {engine.receiveScreen(sessionID:id,raw:prompt,generation:"native-input");try await Task.sleep(for:.milliseconds(10))}
        try expectEqual(probe.inputs.count,0,"No automatic Return may overlap physical typing in the target host")
        try expect(engine.snapshot.sessions.first?.automatic == true)
        activity.set(idle:2,bundle:ScreenHost.iterm.bundleID)
        engine.receiveScreen(sessionID:id,raw:prompt,generation:"native-input")
        try await waitForRecovery({probe.inputs.count == 1},"The pending permission resumes when local typing ends")
        activity.set(idle:0,bundle:"fixture.other-app")
        engine.receiveScreen(sessionID:id,raw:recoveryPrompt("echo background-input"),generation:"native-input")
        try await waitForRecovery({probe.inputs.count == 2},"Typing elsewhere preserves background approval speed")
    }
    func testNativeTypingCancelsApprovalDuringProcessValidation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-native-typing-"+UUID().uuidString)
        let probe = ApprovalRecoveryProbe(),activity = NativeTypingActivity(),gate = NativeTypingValidationGate()
        activity.set(idle:2,bundle:ScreenHost.iterm.bundleID)
        let records = ProcessDiscovery.parse("82001 1 ttys891 82001 82001 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")
        var session = ProcessDiscovery.sessions(records)[0];session.terminal = .iterm;session.channel = .itermScreen
        let adapter = ScreenHostAdapter(screens:{_ in TerminalSnapshot()},approve:{target,raw,_ in try probe.approve(target,raw)},reveal:{_ in nil})
        let engine = try ApprovalEngine(paths:AppPaths(directory:root),processReader:{gate.wait();return records},screenAdapters:[.iterm:adapter],nativeKeyboardActivity:activity.activity)
        defer {gate.release();engine.stop();try? FileManager.default.removeItem(at:root)}
        engine.updateDiscovery([session],records:records);try engine.setAutomatic(session.id,enabled:true)
        let prompt = recoveryPrompt("echo queued-input")
        engine.receiveScreen(sessionID:session.id,raw:prompt,generation:"queued-input")
        try await waitForRecovery({gate.started},"The approval must be waiting for process identity validation")
        activity.set(idle:0,bundle:ScreenHost.iterm.bundleID);gate.release()
        try await Task.sleep(for:.milliseconds(60));try expectEqual(probe.inputs.count,0,"Physical typing that starts during async validation cancels dispatch")
        activity.set(idle:2,bundle:ScreenHost.iterm.bundleID)
        engine.receiveScreen(sessionID:session.id,raw:prompt,generation:"queued-input")
        try await waitForRecovery({probe.inputs.count == 1},"The same pending permission remains usable afterward")
    }
    func testAnsweredPermissionRetiresOnlyAfterRealResolution() async throws {
        let probe = ApprovalRecoveryProbe()
        let (engine,sessions,directory) = try recoveryEngine(probe)
        defer {engine.stop();try? FileManager.default.removeItem(at:directory)}
        let id = sessions[0].id,prompt = recoveryPrompt("echo repeated-legitimate-command"),generation = "resolved-input"
        engine.receiveScreen(sessionID:id,raw:prompt,generation:generation)
        try await waitForRecovery({probe.inputs.count == 1},"The first permission is delivered")
        engine.receiveScreen(sessionID:id,raw:"Working\nesc to interrupt",generation:generation)
        engine.receiveScreen(sessionID:id,raw:prompt,generation:generation)
        try await waitForRecovery({probe.inputs.count == 2},"Observed real work lets the same command request permission again")
        let idle = "Done\n›\nGPT-6.1-Sol max · ~/fixture · Ready · Context 35% left\n⚠ 1 warning · f2 to view",now = Date()
        engine.receiveScreen(sessionID:id,raw:idle,generation:generation,at:now)
        engine.receiveScreen(sessionID:id,raw:idle,generation:generation,at:now.addingTimeInterval(2.1))
        engine.receiveScreen(sessionID:id,raw:prompt,generation:generation,at:now.addingTimeInterval(2.2))
        try await waitForRecovery({probe.inputs.count == 3},"A stable empty composer also retires the preceding reservation")
    }
    func testAnsweredPermissionSurvivesManualComposerRepaints() async throws {
      for agent in [AgentKind.codex,.claude] {
        let probe = ApprovalRecoveryProbe()
        let (engine,sessions,directory) = try recoveryEngine(probe,agents:[agent])
        defer {engine.stop();try? FileManager.default.removeItem(at:directory)}
        let id = sessions[0].id,prompt = recoveryPrompt("echo one-permission",agent:agent)
        let draft = agent == .codex ? "Done\n› Draft 한글\nGPT-6.1-Sol max · ~/fixture · Ready · Context 35% left\n⚠ 1 warning · f2 to view" : "Done\n────────\n❯ Draft 한글\n────────\nfixture | main | Opus 5.5 | ctx 42% | 7d 94%\n⏵⏵ auto mode on (shift+tab to cycle)"
        try expectEqual(ActivityDetector.detect(draft,agent:agent).phase,.input)
        engine.receiveScreen(sessionID:id,raw:prompt,generation:"typing-process")
        try await waitForRecovery({probe.inputs.count == 1},"The first permission is delivered")
        for _ in 0..<8 {
            engine.receiveScreen(sessionID:id,raw:draft,generation:"typing-process")
            engine.receiveScreen(sessionID:id,raw:prompt,generation:"typing-process")
            try await Task.sleep(for:.milliseconds(30))
        }
        try expectEqual(probe.inputs.count,1,"Manual composer repaints cannot drop a dispatched reservation and inject Return repeatedly")
        engine.receiveScreen(sessionID:id,raw:recoveryPrompt("echo next-permission",agent:agent),generation:"typing-process")
        try await waitForRecovery({probe.inputs.count == 2},"A genuinely different permission still proceeds")
      }
    }
    private func recoveryEngine(_ probe: ApprovalRecoveryProbe, agents: [AgentKind] = [.codex],nativeKeyboardActivity:NativeKeyboardActivity? = nil,
                                host:ScreenHost = .iterm,validation:(@Sendable ([ScreenTarget]) throws -> TerminalSnapshot)? = nil) throws -> (ApprovalEngine, [AgentSession], URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-approval-recovery-" + UUID().uuidString)
        let records = ProcessDiscovery.parse(agents.enumerated().map { index, agent in
            "\(82001 + index) 1 ttys\(891 + index) \(82001 + index) \(82001 + index) Mon Sep 21 09:00:0\(index) 2026 /usr/local/bin/\(agent.rawValue)"
        }.joined(separator: "\n"))
        let sessions = records.map { record -> AgentSession in
            var session = AgentSession(id: record.key, agent: record.agent!, pid: record.pid, started: record.started,
                tty: "/dev/" + record.tty, cwd: "/tmp/approval-fixture", terminal: host.kind)
            session.channel = host.channel; return session
        }
        let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot() }, approve: { target, raw, _ in try probe.approve(target, raw) }, reveal: { _ in nil },validationScreens:validation)
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [host: adapter],nativeKeyboardActivity:nativeKeyboardActivity)
        engine.updateDiscovery(sessions, records: records)
        for session in sessions { try engine.setAutomatic(session.id, enabled: true) }
        return (engine, sessions, directory)
    }

    private func waitForRecovery(_ check: () -> Bool, _ message: String) async throws {
        for _ in 0..<150 {
            if check() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(check(), message)
    }

    func testWrappedPermissionHeadingsKeepRequestIdentity() throws {
        for agent in [AgentKind.codex, .claude] {
            let original = recoveryPrompt("echo fixture", agent: agent)
            let heading = agent == .codex ? "Would you like to run the following command?" : "Do you want to proceed?"
            let variants = agent == .codex
                ? ["Would you like to run\nthe following command?", "Would you like to run the following\ncommand?", "Would you like to run the following comm\nand?"]
                : ["Do you want to\nproceed?", "Do you want to pro\nceed?"]
            let identity = PromptDetector.detect(original, agent: agent)!.requestIdentity
            for wrapped in variants {
                let frame = original.replacingOccurrences(of: heading, with: wrapped)
                let prompt = PromptDetector.detect(frame, agent: agent)
                try expectEqual(prompt?.answer, "1", "A wrapped \(agent) heading must remain detectable")
                try expectEqual(prompt?.requestIdentity, identity, "Window reflow is not a new permission")
                try expectEqual(prompt?.dialog, frame, "Delivery still checks the exact complete dialog")
                let context = JSContext()!
                context.setObject("Earlier output\n" + frame, forKeyedSubscript: "current" as NSString)
                context.evaluateScript("""
                var writes = [];
                const tab = {tty: () => '/dev/fixture', contents: () => current, processes: () => ['\(agent.rawValue)']};
                function Application(id) { return {running: () => true, windows: () => [{tabs: () => [tab]}], doScript: value => writes.push(value)}; }
                """)
                let expected = agent == .claude ? "Earlier output\n" + frame : frame
                try expectEqual(context.evaluateScript(try TerminalAdapter.approvalScript(tty: "/dev/fixture", expectedScreen: expected, agent: agent))?.toString(), "sent")
                try expectNil(context.exception)
                let selectedNo = frame.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "› 2.")
                try expectNil(PromptDetector.detect(selectedNo, agent: agent))
                try expectEqual(QuestionDetector.detect(selectedNo, agent: agent)?.phase, .approval)
                try expectNil(PromptDetector.detect(frame + "\n› Another input", agent: agent))
            }
            try expect(PromptDetector.detect(original.replacingOccurrences(of: heading, with: heading.components(separatedBy: " ").dropLast().joined(separator: " ") + "…"), agent: agent) == nil, "Missing title text cannot be invented")
        }
    }

    func testNextPermissionResumesWhenPreviousInputCompletes() async throws {
        let probe = ApprovalRecoveryProbe()
        let (engine, sessions, directory) = try recoveryEngine(probe, agents: [.codex, .codex])
        defer { probe.release(); engine.stop(); try? FileManager.default.removeItem(at: directory) }
        probe.blockedTTY = sessions[0].tty
        let first = recoveryPrompt("echo first"), next = recoveryPrompt("echo next")
        engine.receiveScreen(sessionID: sessions[0].id, raw: first, generation: "same-process")
        try await waitForRecovery({ probe.inputs.count == 1 }, "The first input must start")
        engine.receiveScreen(sessionID: sessions[0].id, raw: next, generation: "same-process")
        engine.receiveScreen(sessionID: sessions[1].id, raw: first, generation: "another-process")
        try await waitForRecovery({ probe.inputs.count == 2 }, "A different terminal cannot be blocked by the first")
        probe.release()
        try await waitForRecovery({ probe.inputs.count == 3 }, "The next permission must resume without resizing or another frame")
        try expectEqual(probe.inputs.filter { $0.0.tty == sessions[0].tty }.map { $0.1 }, [first, next])
        engine.receiveScreen(sessionID: sessions[0].id, raw: next.replacingOccurrences(of: "  $ echo next", with: "  $ echo\nnext"), generation: "same-process")
        try await Task.sleep(nanoseconds: 100_000_000)
        try expectEqual(probe.inputs.count, 3, "Reflow of an answered request cannot send again")
    }

    func testCodexTerminalInputApprovalIsolatedAndSingleUse() async throws {
        let probe = ApprovalRecoveryProbe()
        let (engine, sessions, directory) = try recoveryEngine(probe, agents: [.codex, .codex])
        defer { probe.release(); engine.stop(); try? FileManager.default.removeItem(at: directory) }
        probe.blockedTTY = sessions[0].tty
        let first = codexTerminalInputPermissionFixture
        let second = first.replacingOccurrences(of: "75522?", with: "85523?")
        let wrapped = first.replacingOccurrences(of: "terminal 75522?", with: "terminal\n75522?")
        engine.receiveScreen(sessionID: sessions[0].id, raw: first, generation: "first-process")
        try await waitForRecovery({ probe.inputs.count == 1 }, "The terminal input permission must enter the approval adapter")
        engine.receiveScreen(sessionID: sessions[1].id, raw: second, generation: "second-process")
        try await waitForRecovery({ probe.inputs.count == 2 }, "Another session's terminal input request cannot be blocked")
        engine.receiveScreen(sessionID: sessions[0].id, raw: wrapped, generation: "first-process")
        probe.release()
        try await waitForRecovery({ engine.snapshot.events.filter { $0.outcome == "승인 입력 전달" }.count == 2 }, "Both exact requests must complete")
        engine.receiveScreen(sessionID: sessions[0].id, raw: "Earlier output\n" + wrapped, generation: "first-process")
        try await Task.sleep(nanoseconds: 100_000_000)
        try expectEqual(probe.inputs.count, 2, "Reflow and polling cannot repeat approval")
        let next = first.replacingOccurrences(of: #"\u{4}"#, with: "fixture text")
        engine.receiveScreen(sessionID: sessions[0].id, raw: next, generation: "first-process")
        try await waitForRecovery({ probe.inputs.count == 3 }, "Different input to the same terminal is a new request")
        try expectEqual(probe.inputs.filter { $0.0.tty == sessions[0].tty }.map { $0.1 }, [first, next])
        try expectEqual(probe.inputs.filter { $0.0.tty == sessions[1].tty }.map { $0.1 }, [second])
    }

    func testCodexMCPToolPermissionConcurrentAndSingleUse() async throws {
        let probe = ApprovalRecoveryProbe()
        let (engine, sessions, directory) = try recoveryEngine(probe, agents: [.codex, .codex])
        defer { probe.release(); engine.stop(); try? FileManager.default.removeItem(at: directory) }
        probe.blockedTTY = sessions[0].tty
        let first = codexMCPToolPermissionFixture
        let second = first.replacingOccurrences(of: "fixture_tool", with: "another_tool")
        engine.receiveScreen(sessionID: sessions[0].id, raw: first, generation: "first-process")
        try await waitForRecovery({ probe.inputs.count == 1 }, "The two-choice Allow permission must dispatch")
        engine.receiveScreen(sessionID: sessions[1].id, raw: second, generation: "second-process")
        try await waitForRecovery({ probe.inputs.count == 2 }, "A concurrent Allow in another session must dispatch independently")
        let reflow = first.replacingOccurrences(of: "fixture MCP server", with: "fixture MCP\n  server")
        engine.receiveScreen(sessionID: sessions[0].id, raw: "Earlier output\n" + reflow, generation: "first-process")
        probe.release()
        try await waitForRecovery({ engine.snapshot.events.filter { $0.outcome == "승인 입력 전달" }.count == 2 }, "Both independent approvals must complete")
        engine.receiveScreen(sessionID: sessions[0].id, raw: reflow, generation: "first-process")
        try await Task.sleep(nanoseconds: 100_000_000)
        try expectEqual(probe.inputs.count, 2, "Reflow and polling cannot repeat the same approval")
        let next = first.replacingOccurrences(of: #"\u{4}"#, with: #"\u{3}"#)
        engine.receiveScreen(sessionID: sessions[0].id, raw: next, generation: "first-process")
        try await waitForRecovery({ probe.inputs.count == 3 }, "A changed literal argument identifies the next request")
        try expectEqual(probe.inputs.filter { $0.0.tty == sessions[0].tty }.map { $0.1 }, [first, next])
        try expectEqual(probe.inputs.filter { $0.0.tty == sessions[1].tty }.map { $0.1 }, [second])
    }

    func testCodexOneTimeAllowAutomationPreservesPolicyAndSingleUse() async throws {
        let probe = ApprovalRecoveryProbe()
        let (engine,sessions,directory) = try recoveryEngine(probe)
        defer {engine.stop();try? FileManager.default.removeItem(at:directory)}
        let id = sessions[0].id
        let first = codexMCPToolPermissionFixture.replacingOccurrences(of:"Allow   Run the tool and continue",with:"Allow once   Run the tool and continue")
        try engine.setAutomatic(id,enabled:false)
        engine.receiveScreen(sessionID:id,raw:first,generation:"one-time-allow")
        try await Task.sleep(for:.milliseconds(100));try expectEqual(probe.inputs.count,0,"OFF remains manual")
        try expectEqual(engine.snapshot.sessions.first?.phase,.approval)
        try engine.setAutomatic(id,enabled:true)
        try await waitForRecovery({probe.inputs.count == 1},"A supported one-time Allow must dispatch when enabled")
        engine.receiveScreen(sessionID:id,raw:"Earlier output\n"+first,generation:"one-time-allow")
        try await Task.sleep(for:.milliseconds(100));try expectEqual(probe.inputs.count,1,"An unchanged Allow remains single use")
        let next = first.replacingOccurrences(of:"fixture_tool",with:"another_tool").replacingOccurrences(of:"Allow the fixture",with:"Allow\u{00a0}the fixture")
        try engine.setPaused(true);engine.receiveScreen(sessionID:id,raw:next,generation:"one-time-allow")
        try await Task.sleep(for:.milliseconds(100));try expectEqual(probe.inputs.count,1,"Pause keeps the next permission pending")
        try engine.setPaused(false)
        try await waitForRecovery({probe.inputs.count == 2},"Unpause resumes only the next exact permission")
        try expectEqual(probe.inputs.map{$0.1},[first,next])
    }

    func testPermissionDetectionAcrossTerminalGridSizes() throws {
        func wrapWords(_ text: String, width: Int) -> String {
            var rows = [String](), row = ""
            for word in text.split(separator: " ") {
                if !row.isEmpty && row.count + 1 + word.count > width { rows.append(row); row = "" }
                row += (row.isEmpty ? "" : " ") + word
            }
            return (rows + [row]).joined(separator: "\n")
        }
        for agent in [AgentKind.codex, .claude] {
            let original = recoveryPrompt("echo '한글 🧪 fixture'", agent: agent)
            let heading = agent == .codex ? "Would you like to run the following command?" : "Do you want to proceed?"
            let identity = PromptDetector.detect(original, agent: agent)!.requestIdentity
            for columns in [20, 24, 32, 40, 56, 80, 120] {
                let raw = original.replacingOccurrences(of: heading, with: wrapWords(heading, width: columns))
                    .replacingOccurrences(of: "Enter to confirm or esc to cancel", with: wrapWords("Enter to confirm or esc to cancel", width: columns))
                let ansi = "\u{1B}[33m" + raw.replacingOccurrences(of: "\n", with: "\r\n") + "\u{1B}[0m"
                for rows in [16, 24, 40] {
                    let grid = try OriginalTerminalScreen.render(ansi: ansi, columns: columns, rows: rows, tty: "/dev/fixture")
                    let prompt = PromptDetector.detect(grid.contents, agent: agent)
                    try expectEqual(prompt?.answer, "1", "\(agent) \(columns)×\(rows) terminal cells")
                    try expectEqual(prompt?.requestIdentity, identity, "The grid size cannot change request identity")
                }
                let clipped = try OriginalTerminalScreen.render(ansi: ansi, columns: columns, rows: 4, tty: "/dev/fixture")
                try expectNil(PromptDetector.detect(clipped.contents, agent: agent))
            }
        }
    }

    func testClaudeConsecutivePanelsAndHistoryReflow() async throws {
        let probe = ApprovalRecoveryProbe()
        let (engine, sessions, directory) = try recoveryEngine(probe, agents: [.claude])
        defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
        let id = sessions[0].id, first = recoveryPrompt("echo first", agent: .claude), next = recoveryPrompt("echo next", agent: .claude)
        engine.receiveScreen(sessionID: id, raw: first, generation: "claude-process")
        try await waitForRecovery({ probe.inputs.count == 1 }, "The first Claude panel must be approved")
        for rendering in ["Old output\n" + first, first.replacingOccurrences(of: "echo first", with: "echo\nfirst")] {
            engine.receiveScreen(sessionID: id, raw: rendering, generation: "claude-process")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        try expectEqual(probe.inputs.count, 1, "History and wrapping cannot replay the same Claude panel")
        engine.receiveScreen(sessionID: id, raw: "Old output\n" + next, generation: "claude-process")
        try await waitForRecovery({ probe.inputs.count == 2 }, "A different Claude command cannot inherit the previous reservation")
    }

    func testConfirmedNonWriteRecoversWithoutAnotherOutputEvent() async throws {
        let probe = ApprovalRecoveryProbe(); probe.rejectFirst = true
        let (engine, sessions, directory) = try recoveryEngine(probe)
        defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
        engine.receiveScreen(sessionID: sessions[0].id, raw: recoveryPrompt("echo settled"), generation: "unchanged-process")
        try await waitForRecovery({ probe.inputs.count == 2 }, "A definitive non-write must retry after backoff without a resize")
        try await Task.sleep(nanoseconds: 100_000_000)
        try expectEqual(probe.inputs.count, 2, "The successful retry is still single use")
        try expectEqual(engine.snapshot.events.filter { $0.outcome == "승인 입력 전달" }.count, 1)
    }

    func testApprovalTargetsTabWithoutFrontmostAppOrKeyboardFocus() throws {
        let context = JSContext()!, dialog = recoveryPrompt("echo focus-fixture")
        context.setObject(dialog, forKeyedSubscript: "dialog" as NSString)
        context.evaluateScript("""
        var writes = [], frontmostApp = 'other.app', notifications = 0;
        const targetTab = {tty: () => '/dev/fixture', contents: () => dialog, processes: () => ['codex']};
        const otherTab = {tty: () => '/dev/other', contents: () => { throw Error('Unrelated tab'); }};
        function Application(identifier) {
          if (identifier !== 'com.apple.Terminal') throw Error('Global keyboard access is forbidden');
          return {running: () => true, windows: () => [{tabs: () => [otherTab, targetTab]}],
            frontmost: () => { throw Error('Must not depend on focus'); }, activate: () => { throw Error('Must not steal focus'); },
            doScript: (text, options) => { if (options.in !== targetTab) throw Error('Wrong tab'); writes.push(text); }};
        }
        """)
        for app in ["other.app", "notification.center", "another.app"] {
            context.setObject(app, forKeyedSubscript: "frontmostApp" as NSString)
            context.evaluateScript("notifications++")
            try expectEqual(context.evaluateScript(try TerminalAdapter.approvalScript(tty: "/dev/fixture", expectedScreen: dialog, agent: .codex))?.toString(), "sent")
            try expectNil(context.exception)
        }
        try expectEqual(context.evaluateScript("writes.join(',')")?.toString(), "1,1,1")
    }

    func testUncertainApprovalDoesNotRetryAfterReflow() async throws {
        let probe = ApprovalRecoveryProbe(); probe.throwFirst = true
        let (engine, sessions, directory) = try recoveryEngine(probe)
        defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
        let id = sessions[0].id, original = recoveryPrompt("echo uncertain")
        engine.receiveScreen(sessionID: id, raw: original, generation: "uncertain-process")
        try await waitForRecovery({ engine.snapshot.events.first?.outcome.hasPrefix("입력 확인 필요") == true }, "An uncertain write must request review")
        engine.receiveScreen(sessionID:id,raw:"Done\n› Draft 한글\nGPT-6.1-Sol max · ~/fixture · Ready · Context 35% left\n⚠ 1 warning · f2 to view",generation:"uncertain-process")
        engine.receiveScreen(sessionID: id, raw: original.replacingOccurrences(of: "following command?", with: "following\ncommand?"), generation: "uncertain-process")
        try engine.setPaused(true); try engine.setPaused(false)
        try await Task.sleep(nanoseconds: 350_000_000)
        try expectEqual(probe.inputs.count, 1, "Uncertain input cannot be retried by reflow, a timer or resume")
        try expect(engine.snapshot.sessions.first?.pendingInTerminal == true, "The original review reservation remains visible")
    }
}
