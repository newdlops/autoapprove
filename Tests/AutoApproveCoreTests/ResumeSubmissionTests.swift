import Foundation
import JavaScriptCore
import AutoApproveCore

private func submissionFrame(agent: AgentKind = .codex, goal: Bool = false) -> String {
    let error = agent == .codex ? "■ stream disconnected before completion: network error" : "API Error: Connection error."
    return "QA original conversation\n\n\(error)\n\n\(agent == .codex ? "› Ask Codex to do anything" : "❯ ")\n\n\(agent == .codex ? "mock-model · /tmp/qa\n" : "")? for shortcuts\(goal ? " · Goal stalled (/goal resume)" : "")"
}
private func submissionDraft(_ before: String, _ stop: CodexCapacityStop) -> String {
    before.replacingOccurrences(of: stop.agent == .codex ? "› Ask Codex to do anything" : "❯ ",
        with: "\(stop.agent == .codex ? "›" : "❯") \(stop.continuationText)\n\n")
}
private final class SubmissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var typed = 0, submitted = 0
    private var returns: [ResumeDelivery]
    init(_ returns: [ResumeDelivery] = [.sent]) { self.returns = returns }
    func type() -> ResumeDelivery { lock.lock(); defer { lock.unlock() }; typed += 1; return .draft }
    func enter() -> ResumeDelivery {
        lock.lock(); defer { lock.unlock() }; submitted += 1
        return returns.isEmpty ? .sent : returns.removeFirst()
    }
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return [typed, submitted] }
    var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { _ in TerminalSnapshot() }, approve: { _,_,_ in .sent }, reveal: { _ in nil },
            resume: { _,_,_ in self.type() }, completeResume: { _,_ in self.enter() })
    }
}
private let submissionRecord = ProcessDiscovery.parse("42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0]
@MainActor private func submissionEngine(_ root: URL, _ probe: SubmissionProbe) throws -> ApprovalEngine {
    let engine = try ApprovalEngine(paths: AppPaths(directory: root), processReader: { [submissionRecord] }, screenAdapters: [.terminal: probe.adapter])
    engine.interruptionResumeDelays = [0.01]; engine.goalBlockedResumeDelays = [0.01]; engine.capacityUnsentRetryDelay = 0.03
    var session = AgentSession(id: submissionRecord.key, agent: .codex, pid: submissionRecord.pid, started: submissionRecord.started,
        tty: "/dev/ttys901", cwd: "/tmp/qa", terminal: .terminal)
    session.channel = .terminalScreen; engine.updateDiscovery([session], records: [submissionRecord])
    return engine
}
@MainActor private func waitSubmission(_ check: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !check(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try expect(check(), "Expected the scheduled submission to finish")
}

extension ApprovalTests {
    func testOwnedResumeDraftRequiresEntireComposer() throws {
        for (agent, goal) in [(AgentKind.codex, false), (.codex, true), (.claude, false)] {
            let before = submissionFrame(agent: agent, goal: goal), stop = CodexCapacityStop.detect(before, agent: agent)!
            let draft = submissionDraft(before, stop)
            try expect(CodexResumeCheck.draftReady(draft, stop: stop), "Trailing newlines still belong to the original request")
            try expectFalse(CodexResumeCheck.draftReady(draft.replacingOccurrences(of: "? for shortcuts", with: "extra user note\n? for shortcuts"), stop: stop))
            try expectFalse(CodexResumeCheck.draftReady(draft.replacingOccurrences(of: "QA original conversation", with: "another conversation"), stop: stop))
            try expectFalse(CodexResumeCheck.draftReady(draft.replacingOccurrences(of: "? for shortcuts", with: "a different footer"), stop: stop))
            try expectFalse(CodexResumeCheck.draftReady(draft.replacingOccurrences(of: stop.continuationText, with: stop.continuationText + stop.continuationText), stop: stop))
            if goal {
                try expectFalse(CodexResumeCheck.draftReady(draft.replacingOccurrences(of: "Goal stalled", with: "Goal paused"), stop: stop))
                try expectFalse(CodexResumeCheck.draftReady(draft.replacingOccurrences(of: "Goal stalled", with: "Goal achieved"), stop: stop))
            } else if agent == .codex {
                try expect(CodexResumeCheck.draftReady(draft.replacingOccurrences(of: "? for shortcuts", with: ""), stop: stop), "Codex hides the empty-composer hint in a draft")
                try expect(CodexResumeCheck.draftReady(draft.replacingOccurrences(of: stop.continuationText, with: "이어서\n진행하자."), stop: stop), "Wrapped text is checked as a complete body")
            }
        }
    }

    @MainActor func testResumeSubmissionSurvivesNewlinesAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-submit-restart-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = submissionFrame(), stop = CodexCapacityStop.detect(before, agent: .codex)!, draft = submissionDraft(before, stop)
        let probe = SubmissionProbe([.draft, .sent])
        var engine = try submissionEngine(root, probe); defer { engine.stop() }
        try engine.setAutomatic(submissionRecord.key, enabled: true)
        engine.receiveScreen(sessionID: submissionRecord.key, raw: before, generation: "QA")
        try await waitSubmission { probe.counts == [1, 0] && engine.snapshot.sessions.first?.interruption?.resumeStop != nil }
        engine.receiveScreen(sessionID: submissionRecord.key, raw: draft, generation: "QA")
        try await waitSubmission { probe.counts == [1, 1] && engine.snapshot.sessions.first?.capacityResume?.phase == .scheduled }
        engine.stop(); engine = try submissionEngine(root, probe)
        engine.receiveScreen(sessionID: submissionRecord.key, raw: draft, generation: "QA")
        try await waitSubmission { probe.counts == [1, 2] && engine.snapshot.sessions.first?.interruption?.resumeUncertain == false }
        try expectNotNil(engine.snapshot.sessions.first?.interruption?.resumeConfirmedAt)
        try expectEqual(probe.counts[0], 1, "Restart and repeated newline responses never retype the request")
    }

    @MainActor func testResumeSubmissionPreservesUserControls() async throws {
        for control in ["cancel", "pause", "off", "edited"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-submit-controls-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let before = submissionFrame(), stop = CodexCapacityStop.detect(before, agent: .codex)!
            var draft = submissionDraft(before, stop)
            let probe = SubmissionProbe(); var engine = try submissionEngine(root, probe); defer { engine.stop() }
            try engine.setAutomatic(submissionRecord.key, enabled: true)
            engine.receiveScreen(sessionID: submissionRecord.key, raw: before, generation: "QA")
            try await waitSubmission { probe.counts[0] == 1 && engine.snapshot.sessions.first?.capacityResume?.phase == .scheduled }
            switch control {
            case "cancel": engine.cancelCapacityResume(submissionRecord.key)
            case "pause": try engine.setPaused(true)
            case "off": try engine.setAutomatic(submissionRecord.key, enabled: false)
            default: draft = draft.replacingOccurrences(of: "mock-model", with: "user note\nmock-model")
            }
            engine.stop(); engine = try submissionEngine(root, probe)
            engine.receiveScreen(sessionID: submissionRecord.key, raw: draft, generation: "QA")
            try await Task.sleep(for: .milliseconds(120))
            try expectEqual(probe.counts, [1, 0], "\(control) survives restart and prevents automatic submission")
        }
    }

    @MainActor func testResumeSubmissionRetriesRejectedEnterWithoutRetyping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-submit-nonwrites-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = submissionFrame(), stop = CodexCapacityStop.detect(before, agent: .codex)!, draft = submissionDraft(before, stop)
        let probe = SubmissionProbe([.missingTarget, .screenChanged, .agentMissing, .missingTarget, .sent])
        let engine = try submissionEngine(root, probe); defer { engine.stop() }
        try engine.setAutomatic(submissionRecord.key, enabled: true)
        engine.receiveScreen(sessionID: submissionRecord.key, raw: before, generation: "QA")
        try await waitSubmission { probe.counts[0] == 1 && engine.snapshot.sessions.first?.capacityResume?.phase == .scheduled }
        for attempt in 1...5 {
            engine.receiveScreen(sessionID: submissionRecord.key, raw: draft, generation: "QA")
            try await waitSubmission { probe.counts[1] == attempt && engine.snapshot.sessions.first?.capacityResume?.phase == (attempt == 5 ? .awaiting : .scheduled) }
        }
        try expectEqual(probe.counts, [1, 5], "Rejected Return retries keep the original typed request without replay")
        try expectEqual(engine.snapshot.sessions.first?.interruption?.resumeUncertain, false)
    }

    func testOwnedResumeReturnScriptDoesNotRetype() throws {
        let before = submissionFrame(), stop = CodexCapacityStop.detect(before, agent: .codex)!, draft = submissionDraft(before, stop)
        let working = "› 이어서 진행하자.\n\nWorking · esc to interrupt"
        for (initial, after, expected, count) in [(draft, working, "sent", 1), (draft, draft + "\n", "draft", 1),
            (draft.replacingOccurrences(of: "mock-model", with: "user note\nmock-model"), draft, "typed", 0)] {
            let context = JSContext()!
            context.setObject(initial, forKeyedSubscript: "initial" as NSString)
            context.setObject(after, forKeyedSubscript: "after" as NSString)
            context.evaluateScript("""
            var writes = [], clock = 0; Date.now = () => clock; function delay(seconds) { clock += seconds * 1000; }
            var tab = {tty: () => '/dev/ttys901', contents: () => writes.length ? after : initial, processes: () => ['codex']};
            function Application(id) { return {running: () => true, windows: () => [{tabs: () => [tab]}], doScript: value => writes.push(value)}; }
            """)
            let result = context.evaluateScript(try TerminalAdapter.completeResumeScript(tty: "/dev/ttys901", stop: stop))
            try expectNil(context.exception); try expectEqual(result?.toString(), expected)
            try expectEqual(context.evaluateScript("writes.length")?.toInt32(), Int32(count))
            try expectEqual(context.evaluateScript("writes.every(value => value === '')")?.toBool(), true, "Completing a saved draft writes only Return")
        }
    }

    @MainActor func testLegacyGoalDraftRecoversOnlyExactAuditReceipt() async throws {
        for mismatch in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-submit-legacy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let before = "QA original conversation\n\n• External dependency unavailable\n\n› Ask Codex to do anything\n\nmock-model · /tmp/qa\n? for shortcuts · Goal blocked (/goal resume)"
            let stop = CodexCapacityStop.detect(before, agent: .codex)!
            var draft = submissionDraft(before, stop)
            if mismatch { draft = draft.replacingOccurrences(of: "mock-model", with: "user note\nmock-model") }
            let probe = SubmissionProbe(); var engine = try submissionEngine(root, probe); defer { engine.stop() }
            try engine.setAutomatic(submissionRecord.key, enabled: true)
            engine.stop()
            let store = try AuditStore(path: AppPaths(directory: root).database)
            var receipt = SessionInterruption(id: "legacy", kind: .goalBlocked, detail: "Goal blocked")
            receipt.resumeUncertain = true; receipt.resumeCommand = stop.continuationText
            receipt.resumeIdentity = "goal:" + stop.continuationIdentity!
            try store.set("interruption:" + submissionRecord.key, String(decoding: JSONEncoder().encode(receipt), as: UTF8.self))
            try store.append(AuditEvent(sessionID: submissionRecord.key, summary: "Goal blocked retry", outcome: "입력 확인 필요", source: "QA", request: stop.region, answer: stop.continuationText))
            engine = try submissionEngine(root, probe)
            engine.receiveScreen(sessionID: submissionRecord.key, raw: draft, generation: "QA")
            if mismatch {
                try await Task.sleep(for: .milliseconds(120)); try expectEqual(probe.counts, [0, 0]); try expectNil(engine.snapshot.sessions.first?.interruption?.resumeStop)
            } else {
                try await waitSubmission { probe.counts == [0, 1] && engine.snapshot.sessions.first?.interruption?.resumeUncertain == false }
                try expectNotNil(engine.snapshot.sessions.first?.interruption?.resumeStop)
            }
        }
    }
}
