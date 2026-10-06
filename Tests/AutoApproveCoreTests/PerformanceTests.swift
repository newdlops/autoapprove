import Foundation
import Combine
import Darwin
import AutoApproveCore

private final class PollingScreens: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = TerminalSnapshot()
    func set(_ value: TerminalSnapshot) { lock.lock(); defer { lock.unlock() }; snapshot = value }
    func read() -> TerminalSnapshot { lock.lock(); defer { lock.unlock() }; return snapshot }
}

extension ApprovalTests {
    func testRepeatedScreensPreserveTimeGenerationAndChangedRequests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-screen-time-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] })
        defer { engine.stop() }
        var session = AgentSession(id: "process:42:screen-time", agent: .codex, pid: 42, started: "screen-time",
            tty: "/dev/fixture-time", cwd: root.path, terminal: .vscode)
        session.channel = .vscodeScreen
        engine.updateDiscovery([session], records: [])
        let idle = "›\n? for shortcuts", now = Date()
        func frame(_ raw: String, seconds: Double, generation: String = "one") {
            engine.receiveScreen(sessionID: session.id, raw: raw, generation: generation, at: now.addingTimeInterval(seconds))
        }
        frame(idle, seconds: 0)
        try expectEqual(engine.snapshot.sessions[0].phase, .unknown)
        frame(idle, seconds: 1)
        try expectEqual(engine.snapshot.sessions[0].phase, .unknown)
        frame(idle, seconds: 2)
        try expectEqual(engine.snapshot.sessions[0].phase, .idle, "Identical text must still advance idle confirmation")
        frame(idle, seconds: 3, generation: "two")
        try expectEqual(engine.snapshot.sessions[0].phase, .unknown, "A new generation must start its own confirmation")
        frame(idle, seconds: 5, generation: "two")
        try expectEqual(engine.snapshot.sessions[0].phase, .idle)
        frame("› 새 지시\n? for shortcuts", seconds: 6)
        try expectEqual(engine.snapshot.sessions[0].phase, .input, "Changed text must be observed immediately")
        frame("Running\nesc to interrupt", seconds: 7)
        try expectEqual(engine.snapshot.sessions[0].phase, .working)
        let question = "Which test?\n› 1. First\n  2. Second\nEnter to select"
        frame(question, seconds: 8)
        let first = engine.snapshot.sessions[0].pendingRequestID
        frame(question, seconds: 9)
        try expectEqual(engine.snapshot.sessions[0].pendingRequestID, first)
        frame(question.replacingOccurrences(of: "Which test?", with: "Which other test?"), seconds: 10)
        try expect(engine.snapshot.sessions[0].pendingRequestID != first, "A new request cannot inherit an old parsed result")
        frame(String(repeating: "synthetic history\n", count: 10_000) + question, seconds: 11)
        try expectEqual(engine.snapshot.sessions[0].phase, .input, "Screens above the cache limit must keep their normal behavior")
        engine.updateDiscovery([], records: [])
        try expectEqual(engine.snapshot.sessions[0].phase, .ended)
        frame(idle, seconds: 12)
        try expectEqual(engine.snapshot.sessions[0].phase, .ended, "An observation cannot revive an ended process")
    }

    func testScreenPollsPublishTogetherAndKeepImmediateUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-screen-batch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = PollingScreens()
        let adapter = ScreenHostAdapter(screens: { _ in frames.read() }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        let sessions = (0..<16).map { index in
            AgentSession(id: "process:\(900_000 + index):batch", agent: index.isMultiple(of: 2) ? .codex : .claude,
                pid: Int32(900_000 + index), started: "batch", tty: "/dev/fixture-batch-\(index)", cwd: root.path, terminal: .terminal)
        }
        engine.updateDiscovery(sessions, records: [])
        frames.set(TerminalSnapshot(screens: sessions.map { TerminalScreen(tty: $0.tty, contents: "Working\nesc to interrupt") }))
        await engine.connectScreenHost(.terminal)
        var publications: [[SessionPhase]] = []
        let subscription = engine.$snapshot.dropFirst().sink { publications.append($0.sessions.map(\.phase)) }
        defer { subscription.cancel() }
        for _ in 0..<20 { await engine.refreshScreenHost(.terminal) }
        try expectEqual(publications.count, 0, "Healthy unchanged polls must not wake UI or notification subscribers")
        frames.set(TerminalSnapshot(screens: sessions.map { session in
            let heading = session.agent == .codex ? "Would you like to run the following command?" : "Do you want to proceed?"
            return TerminalScreen(tty: session.tty, contents: heading + "\n$ fixture-test\n› 1. Yes\n  2. No\nEsc to cancel")
        }))
        await engine.refreshScreenHost(.terminal)
        try expectEqual(publications.count, 1, "One host result must publish all simultaneous requests together")
        try expect(publications[0].allSatisfy { $0 == .approval })
        try expectEqual(engine.snapshot.attentionCount, 16)
        engine.receiveScreen(sessionID: sessions[0].id, raw: "Which test?\n› 1. First\n  2. Second\nEnter to select", generation: "terminal:" + sessions[0].id)
        try expectEqual(publications.count, 2, "An independent stream update must still publish immediately")
        try expectEqual(engine.snapshot.sessions.first { $0.id == sessions[0].id }?.phase, .input)
        frames.set(TerminalSnapshot())
        await engine.refreshScreenHost(.terminal)
        try expect(engine.snapshot.sessions.allSatisfy { $0.phase == .unknown && $0.channel == .none })
        try expect(publications.allSatisfy { phases in phases.filter { $0 == .unknown }.count == 0 || phases.allSatisfy { $0 == .unknown } }, "Missing tabs must not publish a partially cleared inventory")
        frames.set(TerminalSnapshot(screens: sessions.map { TerminalScreen(tty: $0.tty, contents: "Working\nesc to interrupt") }))
        await engine.connectScreenHost(.terminal)
        try expect(engine.snapshot.sessions.allSatisfy { $0.phase == .working && $0.channel == .terminalScreen })
        try expectFalse(engine.snapshot.health.screen(.terminal).connecting)
        try expectEqual(engine.snapshot.events.count, 0, "Polling must never send an answer")
    }

    func testWorkingDirectoryReadsKeepValidPathsWithDuplicateAndMissingPIDs() throws {
        let pid = getpid()
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        let paths = ProcessDiscovery.workingDirectories(pids: [pid, pid, Int32.max, -1])
        try expectEqual(paths[pid], expected)
        try expectEqual(paths.count, 1, "Missing or invalid processes must not erase a valid cwd or add another process")
        try expectEqual(ProcessDiscovery.cwd(pid: pid), expected)
        try expectEqual(ProcessDiscovery.workingDirectories(pids: []), [:])
    }

    func testUnchangedObservationsDoNotPublishSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-quiet-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] })
        defer { engine.stop() }
        let session = AgentSession(id: "process:42:quiet", agent: .codex, pid: 42, started: "quiet",
            tty: "/dev/fixture-quiet", cwd: "/tmp", terminal: .vscode)
        engine.updateDiscovery([session], records: [])
        var publications = 0
        let subscription = engine.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<100 { engine.refreshNotices() }
        try expectEqual(publications, 0, "Unchanged observations should not invalidate UI or notification subscribers")
        try engine.setCustomization(session.id, value: SessionCustomization(title: "새 이름"))
        try expectEqual(publications, 1, "A changed session must publish immediately")
        try engine.setPaused(true)
        try expect(engine.snapshot.paused)
        try expectEqual(publications, 2, "Pause must still notify subscribers immediately")
    }

    func testQuestionDuplicateIndexPreservesCanonicalAndThreadIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-duplicates-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] })
        defer { engine.stop() }
        let session = AgentSession(id: "process:42:duplicates", agent: .codex, pid: 42, started: "duplicates",
            tty: "/dev/fixture-duplicates", cwd: "/tmp", terminal: .vscode)
        engine.updateDiscovery([session], records: [])
        var questions = (0..<100).map {
            QueuedQuestion(id: "unique-\($0)", threadID: "one", title: "질문 \($0)을 진행할까요?", options: ["예", "아니오"])
        }
        questions += [
            .init(id: "first", threadID: "one", title: "계속 진행할까요?", options: ["예", "아니오"]),
            .init(id: "second", threadID: "one", title: "  계속\n진행할까요?  ".decomposedStringWithCanonicalMapping, options: ["예", "아니오"]),
            .init(id: "other-thread", threadID: "two", title: "계속 진행할까요?", options: ["예", "아니오"])
        ]
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: questions, threadID: "one")])
        try expectEqual(Set(engine.snapshot.sessions[0].questions.filter { $0.automation?.phase == .duplicate }.map(\.id)), Set(["first", "second"]))
        try engine.beginQuestionReply(sessionID: session.id, questionID: "second")
        engine.refreshNotices()
        try expectEqual(engine.snapshot.sessions[0].questions.first { $0.id == "second" }?.automation?.phase, .editing)
        questions.removeAll { $0.id == "second" }
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: questions, threadID: "one")])
        try expectFalse(engine.snapshot.sessions[0].questions.contains { $0.automation?.phase == .duplicate }, "Removing a duplicate must invalidate the per-pass index")
    }
}
