import Foundation
import JavaScriptCore
import AutoApproveCore

private func blockedGoalFrame(_ status: String = "Goal stalled (/goal resume)") -> String {
    "• Waiting for the external condition to change.\n\n› Ask Codex to do anything\n\n? for shortcuts · " + status
}

private final class BlockedGoalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [String] = []
    var result: ResumeDelivery = .sent
    func send(_ text: String) -> ResumeDelivery { lock.lock(); defer { lock.unlock() }; inputs.append(text); return result }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return inputs }
}

extension ApprovalTests {
    func testBlockedGoalWithoutAPIErrorIsRecoverable() throws {
        for status in ["Goal stalled (/goal resume)", "Goal blocked (/goal resume)", "Goal stalled (/goal\nresume)"] {
            let frame = blockedGoalFrame(status)
            guard let stop = CodexCapacityStop.detect(frame, agent: .codex) else {
                throw AppError.message("A blocked Goal without an API error must be detected: \(status)")
            }
            try expectEqual(stop.kind.rawValue, "goalBlocked")
            try expectEqual(stop.continuationText, "/goal resume")
            try expect(CodexResumeCheck.ready(frame, region: stop.region, text: stop.continuationText))
            try expectFalse(CodexResumeCheck.ready(frame, region: stop.region, text: CodexCapacityStop.resumeText))
            let draft = frame.replacingOccurrences(of: "› Ask Codex to do anything", with: "› /goal resume")
            let pursuing = frame.replacingOccurrences(of: status, with: "Pursuing goal")
            try expectEqual(CodexResumeCheck.state(before: frame, after: draft, region: stop.region, text: stop.continuationText), .draft)
            try expectEqual(CodexResumeCheck.state(before: frame, after: pursuing, region: stop.region, text: stop.continuationText), .submitted)
            try expectEqual(CodexResumeCheck.state(before: frame, after: pursuing.replacingOccurrences(of: "Pursuing goal", with: "Pursuing\ngoal"), region: stop.region, text: stop.continuationText), .submitted)
            try expectEqual(CodexResumeCheck.state(before: frame, after: "", region: stop.region, text: stop.continuationText), .typed)
            for held in ["Goal paused (/goal resume)", "Goal hit usage limits (/goal resume)", "Goal budget reached", "Goal achieved (2m)", "Goal abandoned"] {
                let changed = frame.replacingOccurrences(of: status, with: held)
                try expectNil(CodexCapacityStop.detect(changed, agent: .codex))
                try expectFalse(CodexResumeCheck.ready(changed, region: stop.region, text: stop.continuationText))
                try expectEqual(CodexResumeCheck.state(before: frame, after: changed, region: stop.region, text: stop.continuationText), .typed)
            }
        }
        let stopped = blockedGoalFrame()
        for frame in [stopped.replacingOccurrences(of: "› Ask Codex to do anything", with: "› 사용자 초안"),
                      stopped + " · esc to interrupt", stopped + " · Vim: Normal",
                      "Goal stalled (/goal resume)\n\n• Finished\n\n› Ask Codex to do anything\n\n? for shortcuts"] {
            try expectNil(CodexCapacityStop.detect(frame, agent: .codex))
        }
        try expectNil(CodexCapacityStop.detect(stopped.replacingOccurrences(of: "›", with: "❯"), agent: .claude))
    }

    func testBlockedGoalScriptsVerifyTheLifecycleFooter() throws {
        let before = blockedGoalFrame(), stop = CodexCapacityStop.detect(before, agent: .codex)!
        let draft = before.replacingOccurrences(of: "› Ask Codex to do anything", with: "› /goal resume")
        let pursuing = before.replacingOccurrences(of: "Goal stalled (/goal resume)", with: "Pursuing goal")
        for host in [ScreenHost.terminal, .iterm] {
            for (frames, expected, count) in [([before, draft, pursuing], "sent", 2),
                                             ([before, draft, pursuing.replacingOccurrences(of: "Pursuing goal", with: "Pursuing\ngoal")], "sent", 2),
                                             ([before, draft, before], "typed", 2),
                                             ([before.replacingOccurrences(of: "Goal stalled", with: "Goal paused")], "screenChanged", 0),
                                             ([before.replacingOccurrences(of: "› Ask Codex to do anything", with: "› user draft")], "screenChanged", 0)] {
                let context = JSContext()!
                context.setObject(frames, forKeyedSubscript: "frames" as NSString)
                context.evaluateScript("""
                var writes = [], reads = 0, clock = 0;
                Date.now = () => clock; function delay(seconds) { clock += seconds * 1000; }
                var tab = {tty: () => '/dev/ttys901', contents: () => frames[Math.min(writes.length, frames.length - 1)],
                  processes: () => ['login','zsh','codex'], rows: () => 30, variable: () => 42,
                  write: options => writes.push(options)};
                function Application(id) { return {running: () => true, windows: () => [{tabs: () => [Object.assign(tab, {sessions: () => [tab]})]}],
                  doScript: value => writes.push(value)}; }
                """)
                let script = host == .terminal
                    ? try TerminalAdapter.resumeScript(tty: "/dev/ttys901", region: stop.region, text: stop.continuationText)
                    : try ITermAdapter.resumeScript(target: ScreenTarget(tty: "/dev/ttys901", jobPIDs: [42]), region: stop.region, text: stop.continuationText)
                let result = context.evaluateScript(script)
                try expectNil(context.exception)
                try expectEqual(result?.toString(), expected)
                try expectEqual(context.evaluateScript("writes.length")?.toInt32(), Int32(count))
            }
        }
    }

    func testRecoverableErrorVariantsAndAccountFailurePrecedence() throws {
        let examples: [(AgentKind, String, SessionInterruption.Kind)] = [
            (.codex, "■ error decoding response body", .transport),
            (.codex, "■ error sending request for url (https://api.example.test)", .transport),
            (.codex, "■ Connection reset by peer", .transport),
            (.codex, "■ Reconnect failed: stream closed", .transport),
            (.codex, "■ stream disconnected before com\npletion: network error", .transport),
            (.codex, "■ An error occurred while processing your request", .api),
            (.codex, "■ unexpected status 429 Too Many Requests", .api),
            (.codex, "■ unexpected status 504 Gateway Timeout", .api),
            (.claude, "API Error: 503 Service Unavailable", .api),
            (.claude, "⎿ API Error: Connection closed", .transport),
            (.claude, "API Error: rate_limit_error", .api),
            (.codex, "■ stream disconnected before completion: 401 Unauthorized", .authentication),
            (.codex, "■ transport error: 403 Forbidden", .authentication),
            (.claude, "API Error: 429 insufficient_quota", .configuration),
            (.claude, "API Error: billing_error", .configuration),
            (.codex, "■ unexpected status 400 invalid_request", .configuration)
        ]
        for (agent, error, kind) in examples {
            let composer = agent == .codex ? "› Ask Codex to do anything" : "❯ "
            let screen = error + "\n\n" + composer + "\n\n? for shortcuts"
            guard let stop = CodexCapacityStop.detect(screen, agent: agent) else { throw AppError.message("Expected current error: \(error)") }
            try expectEqual(stop.kind, kind)
            try expect(stop.kind.retryable, "Account failures can recover after an external fix without changing credentials")
            try expectNil(CodexCapacityStop.detect(screen.replacingOccurrences(of: error, with: "Note: " + error), agent: agent))
            try expectNil(CodexCapacityStop.detect(screen.replacingOccurrences(of: error, with: error + "\n\n• Later successful response"), agent: agent))
        }
    }

    @MainActor func testBlockedGoalRecoveryBackoffCancellationAndRestart() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aa-blocked-goal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0]
        let probe = BlockedGoalProbe()
        let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot() }, approve: { _,_,_ in .sent }, reveal: { _ in nil }, resume: { _,_,text in probe.send(text) })
        func create() throws -> ApprovalEngine {
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.terminal: adapter])
            engine.goalBlockedResumeDelays = [0.03, 0.15]
            var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/ttys901", cwd: "/tmp/qa", terminal: .terminal)
            session.channel = .terminalScreen; engine.updateDiscovery([session], records: [record]); return engine
        }
        let frame = blockedGoalFrame(), first = try create()
        defer { first.stop() }
        try first.setAutomatic(record.key, enabled: true)
        first.receiveScreen(sessionID: record.key, raw: frame, generation: "QA")
        try expectEqual(first.snapshot.sessions.first?.capacityResume?.phase, .scheduled)
        let deliveredBy = ProcessInfo.processInfo.systemUptime + 3
        while (probe.texts.isEmpty || first.snapshot.sessions.first?.interruption?.resumeConfirmedAt == nil),
              ProcessInfo.processInfo.systemUptime < deliveredBy {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expectEqual(probe.texts, ["/goal resume"])
        try expectEqual(first.snapshot.events.first?.answer, "/goal resume")
        try expectNotNil(first.snapshot.sessions.first?.interruption?.resumeConfirmedAt)
        first.stop()
        let restored = try create(); defer { restored.stop() }
        restored.receiveScreen(sessionID: record.key, raw: frame, generation: "QA")
        try await Task.sleep(for: .milliseconds(120))
        try expectEqual(probe.texts, ["/goal resume"], "A confirmed resume cannot repeat just because the app restarted")
        let next = "• Rechecked dependency, still unavailable.\n\n" + frame
        restored.receiveScreen(sessionID: record.key, raw: next, generation: "QA")
        try expectEqual(restored.snapshot.sessions.first?.capacityResume?.attempt, 2)
        try await Task.sleep(for: .milliseconds(60)); try expectEqual(probe.texts.count, 1, "The repeated blocked run uses the second delay")
        let nextDeliveredBy = ProcessInfo.processInfo.systemUptime + 3
        while (probe.texts.count < 2 || restored.snapshot.sessions.first?.capacityResume?.phase != .awaiting),
              ProcessInfo.processInfo.systemUptime < nextDeliveredBy {
            try await Task.sleep(for: .milliseconds(10))
        }
        try expectEqual(probe.texts.count, 2)
        restored.receiveScreen(sessionID: record.key, raw: "• Rechecked again.\n\n" + next, generation: "QA")
        restored.cancelCapacityResume(record.key)
        try await Task.sleep(for: .milliseconds(250)); try expectEqual(probe.texts.count, 2)
    }

    @MainActor func testConcurrentBlockedRecoveryRespectsQuestionsPauseAndOptOut() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aa-blocked-isolation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex
        43 1 ttys902 43 43 Mon Sep 21 09:00:01 2026 /usr/local/bin/codex
        44 1 ttys903 44 44 Mon Sep 21 09:00:02 2026 /usr/local/bin/codex
        """)
        let probe = BlockedGoalProbe()
        let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot() }, approve: { _,_,_ in .sent }, reveal: { _ in nil },
            resume: { target,_,text in probe.send(target.tty + ":" + text) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        engine.goalBlockedResumeDelays = [0.02]
        let sessions = records.map { record -> AgentSession in
            var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/tmp/qa", terminal: .terminal)
            session.channel = .terminalScreen; return session
        }
        engine.updateDiscovery(sessions, records: records)
        try engine.setPaused(true)
        for session in sessions.prefix(2) { try engine.setAutomatic(session.id, enabled: true) }
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: sessions[0].id,
            questions: [QueuedQuestion(id: "pending", threadID: "QA", title: "어떤 계정으로 진행할까요?")])])
        for session in sessions { engine.receiveScreen(sessionID: session.id, raw: blockedGoalFrame(), generation: "QA") }
        try await Task.sleep(for: .milliseconds(100)); try expectEqual(probe.texts, [])
        try engine.setPaused(false)
        // Resuming global automation leaves the existing five-second cancellation grace.
        try await Task.sleep(for: .milliseconds(5250))
        try expectEqual(probe.texts, ["/dev/ttys902:/goal resume"], "Pending answers and a manual session cannot be resumed by another session")
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: sessions[0].id, questions: [])])
        engine.receiveScreen(sessionID: sessions[0].id, raw: blockedGoalFrame(), generation: "QA")
        try await Task.sleep(for: .milliseconds(150))
        try expectEqual(probe.texts, ["/dev/ttys902:/goal resume", "/dev/ttys901:/goal resume"])
    }

    @MainActor func testPlainRecoveryCanTransitionToGoalResumeWithoutReplayingEither() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aa-goal-command-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("42 1 ttys901 42 42 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0]
        let probe = BlockedGoalProbe()
        let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot() }, approve: { _,_,_ in .sent }, reveal: { _ in nil }, resume: { _,_,text in probe.send(text) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        engine.interruptionResumeDelays = [0.02]
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/ttys901", cwd: "/tmp/qa", terminal: .terminal)
        session.channel = .terminalScreen; engine.updateDiscovery([session], records: [record]); try engine.setAutomatic(session.id, enabled: true)
        let plain = "■ network error\n\n› Ask Codex to do anything\n\n? for shortcuts"
        engine.receiveScreen(sessionID: session.id, raw: plain, generation: "QA")
        try await Task.sleep(for: .milliseconds(120)); try expectEqual(probe.texts, ["이어서 진행하자."])
        let goal = plain + " · Goal stalled (/goal resume)"
        engine.receiveScreen(sessionID: session.id, raw: goal, generation: "QA")
        try await Task.sleep(for: .milliseconds(120)); try expectEqual(probe.texts, ["이어서 진행하자.", "/goal resume"])
        engine.receiveScreen(sessionID: session.id, raw: goal, generation: "QA")
        try await Task.sleep(for: .milliseconds(100)); try expectEqual(probe.texts.count, 2)
        try expectEqual(engine.snapshot.sessions.first?.interruption?.resumeCommand, "/goal resume")
    }
}
