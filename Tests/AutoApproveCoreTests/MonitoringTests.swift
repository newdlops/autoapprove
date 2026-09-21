import Foundation
import AutoApproveCore

private let codexMonitoringScreen = "Monitor output 1\n›\n1 background terminal running · /ps to view\n? for shortcuts"
private let claudeMonitoringScreen = "1 background task\n────────\n❯\n────────\n⏵⏵ accept edits on (shift+tab to cycle)"

extension ApprovalTests {
    func testMonitoringRequiresReadyComposer() throws {
        for (agent, screen) in [(AgentKind.codex, codexMonitoringScreen), (.claude, claudeMonitoringScreen)] {
            let ready = ActivityDetector.detect(screen, agent: agent)
            try expectEqual(ready.phase, .idle)
            try expect(ready.monitoring)
            for active in ["• Working (esc to interrupt)\n" + screen, screen + "\ntab to queue"] {
                let busy = ActivityDetector.detect(active, agent: agent)
                try expectEqual(busy.phase, .working)
                try expectFalse(busy.monitoring)
            }
            let noComposer = ActivityDetector.detect("1 background task\nReading logs…", agent: agent)
            try expectEqual(noComposer.phase, .working)
            try expectFalse(noComposer.monitoring, "A background job alone is not evidence of input readiness")
            try expectFalse(ActivityDetector.detect("```\n" + screen + "\n```", agent: agent).monitoring)
        }
        let typed = ActivityDetector.detect(codexMonitoringScreen.replacingOccurrences(of: "›\n", with: "› Explain this result\n"), agent: .codex)
        try expectEqual(typed.phase, .input); try expectFalse(typed.monitoring)
        let stopped = ActivityDetector.detect(codexMonitoringScreen.replacingOccurrences(of: "1 background", with: "0 background"), agent: .codex)
        try expectEqual(stopped.phase, .idle); try expectFalse(stopped.monitoring)
        try expectFalse(ActivityDetector.detect(codexMonitoringScreen, agent: .shell).monitoring)
    }

    func testMonitoringTracksReadinessAcrossOutputChanges() throws {
        var tracker = ActivityTracker()
        let now = Date(timeIntervalSince1970: 1_000)
        try expectEqual(tracker.observe(codexMonitoringScreen, agent: .codex, generation: "one", at: now).phase, .unknown)
        let changed = codexMonitoringScreen.replacingOccurrences(of: "output 1", with: "output 2")
        try expectEqual(tracker.observe(changed, agent: .codex, generation: "one", at: now.addingTimeInterval(1)).phase, .unknown)
        let ready = tracker.observe(changed + "\n", agent: .codex, generation: "one", at: now.addingTimeInterval(2))
        try expectEqual(ready.phase, .idle); try expect(ready.monitoring)
        try expectEqual(tracker.observe(changed, agent: .codex, generation: "two", at: now.addingTimeInterval(3)).phase, .unknown)
        try expectEqual(tracker.observe("Working (esc to interrupt)\n" + changed, agent: .codex, generation: "two", at: now.addingTimeInterval(4)).phase, .working)
        try expectEqual(tracker.observe(changed, agent: .codex, generation: "two", at: now.addingTimeInterval(5)).phase, .unknown)
        try expect(tracker.observe(changed, agent: .codex, generation: "two", at: now.addingTimeInterval(7)).monitoring)
    }

    func testMonitoringSessionLifecycleAndCompatibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-monitor-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        var session = AgentSession(id: "process:42:start", agent: .codex, pid: 42, started: "start", tty: "/dev/test", cwd: "/tmp/monitor", terminal: .terminal)
        session.channel = .terminalScreen
        engine.updateDiscovery([session], records: [])
        let now = Date()
        engine.receiveScreen(sessionID: session.id, raw: codexMonitoringScreen, generation: "one", at: now)
        engine.receiveScreen(sessionID: session.id, raw: codexMonitoringScreen, generation: "one", at: now.addingTimeInterval(2))
        let ready = engine.snapshot.sessions[0]
        try expectEqual(ready.phaseTitle, "대기 중 · 모니터링")
        try expectEqual(engine.snapshot.idleCount, 1); try expectEqual(engine.snapshot.monitoringCount, 1)
        try expectNotNil(ready.idleSince)
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty, "Monitoring detection is not a completion event")
        engine.receiveScreen(sessionID: session.id, raw: "Working (esc to interrupt)\n" + codexMonitoringScreen, generation: "one", at: now.addingTimeInterval(3))
        try expectEqual(engine.snapshot.sessions[0].phase, .working)
        try expectEqual(engine.snapshot.monitoringCount, 0)
        try expectNil(engine.snapshot.sessions[0].idleSince)
        let idle = "›\n? for shortcuts"
        engine.receiveScreen(sessionID: session.id, raw: idle, generation: "one", at: now.addingTimeInterval(4))
        engine.receiveScreen(sessionID: session.id, raw: idle, generation: "one", at: now.addingTimeInterval(6))
        try expectEqual(engine.snapshot.sessions[0].phaseTitle, "대기 중")
        try expectEqual(engine.snapshot.idleCount, 1); try expectEqual(engine.snapshot.monitoringCount, 0)
        engine.receiveScreen(sessionID: session.id, raw: codexMonitoringScreen, generation: "one", at: now.addingTimeInterval(7))
        engine.receiveScreen(sessionID: session.id, raw: codexMonitoringScreen, generation: "one", at: now.addingTimeInterval(9))
        engine.disconnectTerminal()
        try expectEqual(engine.snapshot.sessions[0].phase, .unknown)
        try expectNil(engine.snapshot.sessions[0].backgroundMonitoring)
        try expectEqual(engine.snapshot.monitoringCount, 0)
        engine.updateDiscovery([], records: [])
        try expectEqual(engine.snapshot.sessions[0].phase, .ended)
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ready)) as! JSONObject
        oldJSON.removeValue(forKey: "backgroundMonitoring")
        let restored = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        try expectEqual(restored.phase, .idle); try expectFalse(restored.isMonitoring)
    }

    func testClaudeMonitoringHookLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-monitor-hook-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        func hook(_ event: String, _ extra: JSONObject = [:]) {
            var payload: JSONObject = ["session_id": "monitor", "hook_event_name": event, "requestID": UUID().uuidString]
            payload.merge(extra) { _, new in new }; _ = engine.handleHook(payload)
        }
        hook("UserPromptSubmit")
        hook("Stop", ["background_tasks": [["id": "watch", "status": "running"]]])
        let since = engine.snapshot.sessions[0].idleSince
        try expect(engine.snapshot.sessions[0].isMonitoring)
        try expectEqual(engine.snapshot.idleCount, 1)
        try expect(AttentionRequest.completions(engine.snapshot).isEmpty)
        hook("Notification", ["notification_type": "idle_prompt"])
        try expect(engine.snapshot.sessions[0].isMonitoring)
        try expectEqual(engine.snapshot.sessions[0].idleSince, since)
        hook("UserPromptSubmit")
        try expectEqual(engine.snapshot.sessions[0].phase, .working)
        try expectFalse(engine.snapshot.sessions[0].isMonitoring)
        hook("Stop", ["session_crons": [["id": "watch-ci"]]])
        try expect(engine.snapshot.sessions[0].isMonitoring)
        hook("PreToolUse", ["tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Which task?", "options": [["label": "A"], ["label": "B"]]]]]])
        hook("Stop", ["background_tasks": [["id": "watch"]]])
        try expectEqual(engine.snapshot.sessions[0].phase, .input)
        try expectFalse(engine.snapshot.sessions[0].isMonitoring)
        hook("PostToolUse")
        hook("Stop", ["background_tasks": [], "session_crons": []])
        try expectEqual(engine.snapshot.sessions[0].phaseTitle, "대기 중")
        try expectNil(engine.snapshot.sessions[0].backgroundMonitoring)
        try expectEqual(AttentionRequest.completions(engine.snapshot).count, 1)
        hook("SessionEnd")
        try expectEqual(engine.snapshot.monitoringCount, 0)
    }
}
