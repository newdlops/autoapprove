import Foundation
import JavaScriptCore
import AutoApproveCore

/// Real Codex 0.158 frames from a 120×30 Terminal tab: an isolated CODEX_HOME whose model provider
/// is a local server answering `503 server_is_overloaded`. Unlisted rows are blank.
private func codexFrame(_ rows: [Int: String], height: Int = 30) -> String {
    (0..<height).map { rows[$0] ?? "" }.joined(separator: "\n")
}
private let capacityCell = "■ Selected model is at capacity. Please try a different model."
private let header: [Int: String] = [1: "  >_ OpenAI Codex (v0.158.0)", 2: "     /private/tmp/aa-cx-1/work", 4: "  Take your time. The cursor can wait."]
private let footer: [Int: String] = [26: "› Ask Codex to do anything", 28: "  mock-model default · /private/tmp/aa-cx-1/work",
    29: "  ← for agents · ? for shortcuts                                                               ⚠ 1 warning · f2 to view"]
private let stoppedFrame = codexFrame(header.merging(footer) { a, _ in a }.merging([7: "› 작업을 시작하자.", 10: capacityCell]) { a, _ in a })
/// `do script` typed the text and Return together: Codex kept it as a taller draft.
private let draftFrame = codexFrame(header.merging([7: "› 작업을 시작하자.", 10: capacityCell, 25: "› 이어서 진행하자.",
    28: "  mock-model default · /private/tmp/aa-cx-1/work",
    29: "                                                                                               ⚠ 1 warning · f2 to view"]) { a, _ in a })
/// A separate Return submitted it, and the next request succeeded.
private let continuedFrame = codexFrame(header.merging(footer) { a, _ in a }.merging([7: "› 작업을 시작하자.", 10: capacityCell,
    13: "› 이어서 진행하자.", 16: "• 모의 응답: 이어서 진행했습니다.", 18: "  1:57 AM"]) { a, _ in a })
/// The continue was submitted and failed again within a second, with no working frame in between.
private let refailedFrame = codexFrame(header.merging(footer) { a, _ in a }.merging([7: "› 작업을 시작하자.", 10: capacityCell,
    13: "› 이어서 진행하자.", 16: capacityCell]) { a, _ in a })
/// The same Codex at 44 columns wraps the error cell without indentation.
private let narrowFrame = codexFrame([0: "이어서 진행하자.", 1: "  1:57 AM", 4: "› 다시 해보자",
    7: "■ Selected model is at capacity. Please try", 8: "a different model.", 11: "› 이어서 진행하자.", 14: "• 모의 응답: 이어서 진행했습니다.",
    16: "  1:58 AM", 19: "› 다시 해보자", 22: "■ Selected model is at capacity. Please try", 23: "a different model.",
    26: "› Ask Codex to do anything", 28: "  mock-model default · /private/tmp/aa-cx-1…", 29: "  ← for agents · ? for shortcuts   ⚠ 1 · f2"])

private func unwrap<T>(_ value: T?, _ message: String = "Expected a value") throws -> T {
    guard let value else { throw AppError.message(message) }
    return value
}

private final class ResumeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(ScreenTarget, String, String)] = []
    private var replies: [ResumeDelivery]
    init(_ replies: [ResumeDelivery]) { self.replies = replies }
    func resume(_ target: ScreenTarget, _ region: String, _ text: String) -> ResumeDelivery {
        lock.lock(); defer { lock.unlock() }
        calls.append((target, region, text))
        return replies.isEmpty ? .sent : replies.removeFirst()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    var last: (ScreenTarget, String, String)? { lock.lock(); defer { lock.unlock() }; return calls.last }
}

extension ApprovalTests {
    func testCodexCapacityStopDetection() throws {
        let stop = try unwrap(CodexCapacityStop.detect(stoppedFrame, agent: .codex))
        try expect(stop.region.hasPrefix(capacityCell) && stop.region.hasSuffix("› Ask Codex to do anything"), "The region runs from the error cell to the empty composer")
        let narrow = try unwrap(CodexCapacityStop.detect(narrowFrame, agent: .codex), "A wrapped cell is the same stop")
        try expect(narrow.region.hasPrefix("■ Selected model is at capacity. Please try\na different model."))
        let refailed = try unwrap(CodexCapacityStop.detect(refailedFrame, agent: .codex))
        try expect(refailed.identity != stop.identity, "A failure after the continue is a new stop")
        try expect(CodexCapacityStop.detect(draftFrame, agent: .codex) == nil, "A composer with text is not ready")
        try expect(CodexCapacityStop.detect(continuedFrame, agent: .codex) == nil, "A later answer ends the stop")
        try expectNil(CodexCapacityStop.detect(stoppedFrame, agent: .claude))
        for changed in [
            stoppedFrame.replacingOccurrences(of: "? for shortcuts", with: "? for shortcuts · Vim: Normal"),
            stoppedFrame.replacingOccurrences(of: "  Take your time.", with: "• Working (3s • esc to interrupt)\n  Take your time.")
                .replacingOccurrences(of: "  mock-model default", with: "  • Working (3s • esc to interrupt)\n  mock-model default"),
            stoppedFrame.replacingOccurrences(of: "at capacity.", with: "unavailable."),
            stoppedFrame.replacingOccurrences(of: "› Ask Codex to do anything", with: "• Ran npm test\n\n› Ask Codex to do anything"),
            stoppedFrame.replacingOccurrences(of: capacityCell, with: "Note: " + capacityCell),
        ] { try expectNil(CodexCapacityStop.detect(changed, agent: .codex)) }

        // Orca applies the same checks from Swift.
        try expect(CodexResumeCheck.ready(stoppedFrame, region: stop.region))
        try expectFalse(CodexResumeCheck.ready(draftFrame, region: stop.region))
        try expectFalse(CodexResumeCheck.ready(stoppedFrame.replacingOccurrences(of: "› Ask Codex", with: "› x Ask Codex"), region: stop.region))
        let text = CodexCapacityStop.resumeText
        func state(_ before: String, _ after: String, _ region: String? = nil) -> CodexResumeCheck.TypedState {
            CodexResumeCheck.state(before: before, after: after, region: region ?? stop.region, text: text)
        }
        try expectEqual(state(stoppedFrame, draftFrame), .draft)
        try expectEqual(state(stoppedFrame, continuedFrame), .submitted)
        try expectEqual(state(stoppedFrame, refailedFrame), .submitted, "Our message above a new error cell was submitted")
        try expectEqual(state(refailedFrame, refailedFrame, refailed.region), .typed, "An earlier continue on screen is not evidence of a new one")
        try expectEqual(state(stoppedFrame, stoppedFrame), .typed)
        try expectEqual(state(stoppedFrame, draftFrame.replacingOccurrences(of: "› 이어서 진행하자.", with: "› 메모 이어서 진행하자.")), .typed,
            "A mixed draft is never submitted")
        // A full screen scrolls the oldest continue away while a new one fails below; the count stays the same.
        let scrolled = refailedFrame.replacingOccurrences(of: "› 작업을 시작하자.", with: "")
            .replacingOccurrences(of: "› Ask Codex to do anything", with: "› 이어서 진행하자.\n\n" + capacityCell + "\n\n› Ask Codex to do anything")
            .replacingOccurrences(of: "     › 이어서 진행하자.", with: "")
        try expectEqual(state(refailedFrame, scrolled, refailed.region), .submitted)
        try expect(CodexResumeCheck.draftVisible(draftFrame, text: text)); try expectFalse(CodexResumeCheck.draftVisible(continuedFrame, text: text))
    }

    func testCodexResumeScriptsTypeThenSubmit() throws {
        let stop = try unwrap(CodexCapacityStop.detect(stoppedFrame, agent: .codex))
        func terminal(_ frames: [String], processes: [String] = ["login", "-zsh", "codex"], windows: String = "[{tabs: () => [tab]}]", tty: String = "/dev/ttys901", region: String? = nil, input: String? = nil) throws -> (String?, [String]) {
            let context = JSContext()!
            context.setObject(frames, forKeyedSubscript: "frames" as NSString)
            context.setObject(processes, forKeyedSubscript: "processes" as NSString)
            context.setObject(tty, forKeyedSubscript: "tty" as NSString)
            context.evaluateScript("""
            var writes = [], reads = 0;
            var clock = 0; Date.now = () => clock; function delay(seconds) { clock += seconds * 1000; }
            var tab = {tty: () => tty, contents: () => frames[Math.min(reads++, frames.length - 1)], processes: () => processes};
            function Application(id) { return {running: () => true, windows: () => \(windows),
              doScript: (value, options) => { if (options.in !== tab) throw Error('wrong target'); writes.push(value); }}; }
            """)
            // Process hands osascript its arguments decomposed (NFD), Korean text included.
            let result = context.evaluateScript(try TerminalAdapter.resumeScript(tty: "/dev/ttys901", region: region ?? stop.region, text: input ?? CodexCapacityStop.resumeText)
                .decomposedStringWithCanonicalMapping)
            if let exception = context.exception { throw AppError.message(exception.toString()) }
            return (result?.toString(), context.evaluateScript("writes")?.toArray() as? [String] ?? [])
        }
        let text = CodexCapacityStop.resumeText
        var (delivery, writes) = try terminal([stoppedFrame, draftFrame, continuedFrame])
        try expectEqual(delivery, "sent"); try expectEqual(writes, [text, ""], "Return follows separately only for a visible draft")
        try expect(writes.first?.unicodeScalars.elementsEqual(text.precomposedStringWithCanonicalMapping.unicodeScalars) == true,
            "Composed Korean is typed even though the script arrives decomposed")
        (delivery, writes) = try terminal([stoppedFrame, stoppedFrame, stoppedFrame, draftFrame, continuedFrame])
        try expectEqual(delivery, "sent"); try expectEqual(writes, [text, ""], "A draft drawn several reads later is still found")
        (delivery, writes) = try terminal([stoppedFrame, draftFrame])
        try expectEqual(delivery, "typed"); try expectEqual(writes, [text, ""], "Return that leaves the draft in place is not a send")
        (delivery, writes) = try terminal([stoppedFrame, continuedFrame])
        try expectEqual(delivery, "sent"); try expectEqual(writes, [text], "An already submitted message gets no extra Return")
        (delivery, writes) = try terminal([stoppedFrame, refailedFrame])
        try expectEqual(delivery, "sent"); try expectEqual(writes, [text])
        (delivery, writes) = try terminal([stoppedFrame, stoppedFrame])
        try expectEqual(delivery, "typed"); try expectEqual(writes, [text], "An unverified write is reported, never followed by Return")
        (delivery, writes) = try terminal([stoppedFrame, draftFrame, ""])
        try expectEqual(delivery, "typed"); try expectEqual(writes, [text, ""], "A blank repaint after Return does not prove submission")
        let workingWithoutComposer = "› 이어서 진행하자.\n\n• Working (1s • esc to interrupt)"
        (delivery, writes) = try terminal([stoppedFrame, draftFrame, "", workingWithoutComposer])
        try expectEqual(delivery, "sent"); try expectEqual(writes, [text, ""], "A submitted message can be the last glyph while the composer is clipped")
        (delivery, writes) = try terminal([stoppedFrame, workingWithoutComposer])
        try expectEqual(delivery, "sent"); try expectEqual(writes, [text], "A working transcript is not an unsent draft")
        let stalled = stoppedFrame.replacingOccurrences(of:"? for shortcuts",with:"? for shortcuts · Goal stalled (/goal resume)")
        let goal = try unwrap(CodexCapacityStop.detect(stalled,agent:.codex))
        let goalDraft = stalled.replacingOccurrences(of:"› Ask Codex to do anything",with:"› /goal resume")
        let pursuing = stoppedFrame.replacingOccurrences(of:"? for shortcuts",with:"? for shortcuts · Pursuing goal")
        (delivery,writes) = try terminal([stalled,goalDraft,"",pursuing],region:goal.region,input:goal.continuationText)
        try expectEqual(delivery,"sent"); try expectEqual(writes,["/goal resume",""],"A slash command is acknowledged by its Goal state, without a user-message cell")
        (delivery,writes) = try terminal([stalled,goalDraft,stalled],region:goal.region,input:goal.continuationText)
        try expectEqual(delivery,"typed"); try expectEqual(writes,["/goal resume",""],"A Goal still stalled after Return has not resumed")
        (delivery,writes) = try terminal([stalled],region:goal.region,input:text)
        try expectEqual(delivery,"screenChanged"); try expectEqual(writes,[],"Do not substitute a plain prompt for a lifecycle command")
        (delivery,writes) = try terminal([stalled.replacingOccurrences(of:"Goal stalled",with:"Goal paused")],region:goal.region,input:goal.continuationText)
        try expectEqual(delivery,"screenChanged"); try expectEqual(writes,[],"A user pause between detection and delivery wins")
        (delivery, writes) = try terminal([draftFrame])
        try expectEqual(delivery, "screenChanged"); try expectEqual(writes, [])
        (delivery, writes) = try terminal([stoppedFrame.replacingOccurrences(of: "? for shortcuts", with: "? for shortcuts · Vim: Normal")])
        try expectEqual(delivery, "screenChanged"); try expectEqual(writes, [])
        (delivery, writes) = try terminal([stoppedFrame], processes: ["login", "-zsh"])
        try expectEqual(delivery, "agentMissing"); try expectEqual(writes, [])
        (delivery, writes) = try terminal([stoppedFrame], tty: "/dev/other")
        try expectEqual(delivery, "missingTarget"); try expectEqual(writes, [])
        let unresolved = "{tabs: () => { const error = Error('Can’t get object. (-1728)'); error.errorNumber = -1728; throw error; }}"
        (delivery, writes) = try terminal([stoppedFrame, draftFrame, continuedFrame], windows: "[\(unresolved), {tabs: () => [tab]}]")
        try expectEqual(delivery, "sent"); try expectEqual(writes, [text, ""])
        try expectThrows(try terminal([stoppedFrame], windows: "[{tabs: () => { const error = Error('not authorized (-1743)'); error.errorNumber = -1743; throw error; }}]"))

        // iTerm2 writes the text without a newline, then a newline alone, to the same session.
        let context = JSContext()!
        context.setObject([stoppedFrame, draftFrame, continuedFrame], forKeyedSubscript: "frames" as NSString)
        context.evaluateScript("""
        var writes = [], reads = 0;
        var clock = 0; Date.now = () => clock; function delay(seconds) { clock += seconds * 1000; }
        var session = {tty: () => '/dev/ttys902', rows: () => 30, contents: () => frames[Math.min(reads++, frames.length - 1)] + '\\n',
          variable: () => 77, write: (options) => writes.push(options)};
        function Application(id) { return {running: () => true, windows: () => [{tabs: () => [{sessions: () => [session]}]}]}; }
        """)
        let iterm = context.evaluateScript(try ITermAdapter.resumeScript(target: ScreenTarget(tty: "/dev/ttys902", jobPIDs: [77]), region: stop.region, text: text)
            .decomposedStringWithCanonicalMapping)
        try expectNil(context.exception)
        try expectEqual(iterm?.toString(), "sent")
        try expectEqual(context.evaluateScript("JSON.stringify(writes)")?.toString(), #"[{"text":"이어서 진행하자.","newline":false},{"text":""}]"#)
        context.setObject([stalled,goalDraft,pursuing],forKeyedSubscript:"frames" as NSString)
        context.evaluateScript("writes = []; reads = 0; clock = 0;")
        let goalITerm = context.evaluateScript(try ITermAdapter.resumeScript(target:ScreenTarget(tty:"/dev/ttys902",jobPIDs:[77]),region:goal.region,text:goal.continuationText))
        try expectNil(context.exception); try expectEqual(goalITerm?.toString(),"sent")
        try expectEqual(context.evaluateScript("JSON.stringify(writes)")?.toString(),#"[{"text":"/goal resume","newline":false},{"text":""}]"#)
    }

    func testCodexCapacityResumeRuns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-capacity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0]
        func engine(_ probe: ResumeProbe, delays: [TimeInterval] = [0.05, 0.1]) throws -> (ApprovalEngine, String) {
            let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot() }, approve: { _, _, _ in .sent }, reveal: { _ in nil },
                resume: { probe.resume($0, $1, $2) })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent(UUID().uuidString)),
                processReader: { [record] }, screenAdapters: [.terminal: adapter])
            engine.capacityResumeDelays = delays
            var session = AgentSession(id: record.key, agent: .codex, pid: 42, started: record.started, tty: "/dev/ttys901", cwd: "/tmp/capacity", terminal: .terminal)
            session.channel = .terminalScreen
            engine.updateDiscovery([session], records: [record])
            return (engine, session.id)
        }
        func settle(_ seconds: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func resume(_ engine: ApprovalEngine, _ id: String) -> CapacityResume? { engine.snapshot.sessions.first { $0.id == id }?.capacityResume }

        // Auto-approval off: nothing is scheduled or typed.
        var probe = ResumeProbe([])
        var (subject, id) = try engine(probe)
        subject.receiveScreen(sessionID: id, raw: stoppedFrame, generation: "terminal:\(id)")
        await settle()
        try expectNil(resume(subject, id)); try expectEqual(probe.count, 0)

        // On: one continue per stop, the next failure waits longer, and the limit asks for attention.
        try subject.setAutomatic(id, enabled: true)
        subject.receiveScreen(sessionID: id, raw: stoppedFrame, generation: "terminal:\(id)")
        try expectEqual(resume(subject, id)?.phase, .scheduled); try expectEqual(resume(subject, id)?.attempt, 1)
        await settle()
        try expectEqual(probe.count, 1)
        try expectEqual(probe.last?.1, CodexCapacityStop.detect(stoppedFrame, agent: .codex)?.region)
        try expectEqual(probe.last?.2, "이어서 진행하자.")
        try expectEqual(probe.last?.0.tty, "/dev/ttys901")
        try expectEqual(resume(subject, id)?.phase, .awaiting)
        try expectEqual(subject.snapshot.events.first?.outcome, "이어서 진행 요청 전달")
        try expectEqual(subject.snapshot.events.first?.result, .delivered)
        subject.receiveScreen(sessionID: id, raw: stoppedFrame, generation: "terminal:\(id)")
        await settle()
        try expectEqual(probe.count, 1, "A frame read before the send is not a new failure")
        subject.receiveScreen(sessionID: id, raw: refailedFrame, generation: "terminal:\(id)")
        try expectEqual(resume(subject, id)?.attempt, 2)
        await settle()
        try expectEqual(probe.count, 2)
        let third = refailedFrame.replacingOccurrences(of: "› Ask Codex to do anything", with: "› 이어서 진행하자.\n\n\n" + capacityCell + "\n\n\n› Ask Codex to do anything")
        subject.receiveScreen(sessionID: id, raw: third, generation: "terminal:\(id)")
        await settle()
        try expectEqual(probe.count, 2, "Two delays allow two automatic attempts")
        try expectEqual(resume(subject, id)?.phase, .exhausted)
        var session = try unwrap(subject.snapshot.sessions.first { $0.id == id })
        try expectEqual(session.phase, .input); try expect(AttentionRequest.needsAttention(session, paused: false))
        // A normal answer ends the run; a later stop starts over at the first attempt.
        subject.receiveScreen(sessionID: id, raw: continuedFrame, generation: "terminal:\(id)")
        try expectNil(resume(subject, id))

        // Cancel, pause and auto-approval off stop a scheduled continue.
        probe = ResumeProbe([])
        (subject, id) = try engine(probe, delays: [0.2])
        try subject.setAutomatic(id, enabled: true)
        subject.receiveScreen(sessionID: id, raw: stoppedFrame, generation: "terminal:\(id)")
        subject.cancelCapacityResume(id)
        await settle()
        try expectEqual(probe.count, 0); try expectEqual(resume(subject, id)?.phase, .cancelled)
        subject.receiveScreen(sessionID: id, raw: continuedFrame, generation: "terminal:\(id)")
        subject.receiveScreen(sessionID: id, raw: refailedFrame, generation: "terminal:\(id)")
        try subject.setPaused(true)
        await settle()
        try expectEqual(probe.count, 0); try expectEqual(resume(subject, id)?.phase, .paused)
        try subject.setAutomatic(id, enabled: false)
        try subject.setPaused(false)
        await settle()
        try expectEqual(probe.count, 0); try expectNil(resume(subject, id))

        // A user's draft cancels the countdown; an unverified write is never repeated.
        probe = ResumeProbe([.typed])
        (subject, id) = try engine(probe, delays: [0.1])
        try subject.setAutomatic(id, enabled: true)
        subject.receiveScreen(sessionID: id, raw: stoppedFrame, generation: "terminal:\(id)")
        subject.receiveScreen(sessionID: id, raw: draftFrame.replacingOccurrences(of: "이어서 진행하자.", with: "직접 쓰는 중"), generation: "terminal:\(id)")
        await settle()
        try expectEqual(probe.count, 0); try expectNil(resume(subject, id))
        subject.receiveScreen(sessionID: id, raw: stoppedFrame, generation: "terminal:\(id)")
        await settle()
        try expectEqual(probe.count, 1); try expectEqual(resume(subject, id)?.phase, .review)
        subject.receiveScreen(sessionID: id, raw: stoppedFrame, generation: "terminal:\(id)")
        await settle()
        try expectEqual(probe.count, 1)
        session = try unwrap(subject.snapshot.sessions.first { $0.id == id })
        try expect(AttentionRequest.needsAttention(session, paused: false))
        try expectEqual(subject.snapshot.events.first?.result, .review)
        subject.receiveScreen(sessionID: id, raw: draftFrame, generation: "terminal:\(id)")
        try expectEqual(resume(subject, id)?.phase, .review, "Our unsent draft keeps the request for review")
        session = try unwrap(subject.snapshot.sessions.first { $0.id == id })
        try expect(AttentionRequest.needsAttention(session, paused: false))

        // A screen filled with repeated failures looks unchanged; after the stale-frame window it is the next failure.
        probe = ResumeProbe([])
        (subject, id) = try engine(probe, delays: [0.05, 0.05])
        subject.capacityStaleFrameWindow = 0.5
        try subject.setAutomatic(id, enabled: true)
        subject.receiveScreen(sessionID: id, raw: refailedFrame, generation: "terminal:\(id)")
        await settle()
        try expectEqual(probe.count, 1)
        subject.receiveScreen(sessionID: id, raw: refailedFrame, generation: "terminal:\(id)")
        await settle()
        try expectEqual(probe.count, 1, "Too soon after the send to trust an identical frame")
        await settle()
        subject.receiveScreen(sessionID: id, raw: refailedFrame, generation: "terminal:\(id)")
        try expectEqual(resume(subject, id)?.attempt, 2)
        await settle()
        try expectEqual(probe.count, 2)

        // A continued turn that keeps working made progress; its next stop is a new run at attempt 1.
        probe = ResumeProbe([])
        (subject, id) = try engine(probe, delays: [0.05, 0.05])
        subject.capacityProgressWindow = 0.5
        try subject.setAutomatic(id, enabled: true)
        subject.receiveScreen(sessionID: id, raw: stoppedFrame, generation: "terminal:\(id)")
        await settle()
        try expectEqual(probe.count, 1)
        let working = continuedFrame.replacingOccurrences(of: "› Ask Codex to do anything", with: "• Working (2m 10s • esc to interrupt)\n\n› Ask Codex to do anything")
        subject.receiveScreen(sessionID: id, raw: working, generation: "terminal:\(id)")
        try expectEqual(resume(subject, id)?.phase, .awaiting)
        await settle()
        subject.receiveScreen(sessionID: id, raw: working, generation: "terminal:\(id)")
        try expectNil(resume(subject, id))
        subject.receiveScreen(sessionID: id, raw: refailedFrame, generation: "terminal:\(id)")
        try expectEqual(resume(subject, id)?.attempt, 1, "Hours of work between stops are not one run of failures")

        // Nothing typed: retried on fresh frames a few times, then left for review.
        probe = ResumeProbe([.screenChanged, .screenChanged, .screenChanged])
        (subject, id) = try engine(probe, delays: [0.05])
        subject.capacityUnsentRetryDelay = 0.05
        try subject.setAutomatic(id, enabled: true)
        for _ in 0..<5 {
            subject.receiveScreen(sessionID: id, raw: stoppedFrame, generation: "terminal:\(id)")
            await settle(0.3)
        }
        try expectEqual(probe.count, 3); try expectEqual(resume(subject, id)?.phase, .review)
    }
}
