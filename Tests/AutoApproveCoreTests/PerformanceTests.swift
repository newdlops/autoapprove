import Foundation
import Combine
import AutoApproveCore

extension ApprovalTests {
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
