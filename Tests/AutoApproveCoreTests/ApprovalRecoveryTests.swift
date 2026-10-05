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

extension ApprovalTests {
    private func recoveryEngine(_ probe: ApprovalRecoveryProbe, agents: [AgentKind] = [.codex]) throws -> (ApprovalEngine, [AgentSession], URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-approval-recovery-" + UUID().uuidString)
        let records = ProcessDiscovery.parse(agents.enumerated().map { index, agent in
            "\(82001 + index) 1 ttys\(891 + index) \(82001 + index) \(82001 + index) Mon Sep 21 09:00:0\(index) 2026 /usr/local/bin/\(agent.rawValue)"
        }.joined(separator: "\n"))
        let sessions = records.map { record -> AgentSession in
            var session = AgentSession(id: record.key, agent: record.agent!, pid: record.pid, started: record.started,
                tty: "/dev/" + record.tty, cwd: "/tmp/approval-fixture", terminal: .iterm)
            session.channel = .itermScreen; return session
        }
        let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot() }, approve: { target, raw, _ in try probe.approve(target, raw) }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.iterm: adapter])
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
        engine.receiveScreen(sessionID: id, raw: original.replacingOccurrences(of: "following command?", with: "following\ncommand?"), generation: "uncertain-process")
        try engine.setPaused(true); try engine.setPaused(false)
        try await Task.sleep(nanoseconds: 350_000_000)
        try expectEqual(probe.inputs.count, 1, "Uncertain input cannot be retried by reflow, a timer or resume")
        try expect(engine.snapshot.sessions.first?.pendingInTerminal == true, "The original review reservation remains visible")
    }
}
