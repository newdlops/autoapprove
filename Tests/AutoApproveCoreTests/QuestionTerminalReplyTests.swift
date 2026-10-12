import Foundation
import AutoApproveCore

private final class TerminalReplyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    var decline = false
    var uncertain = false
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return sent }
    func input(_ value: RemoteTerminalInput) throws -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        if decline { return .screenChanged }
        sent.append(value.bytes)
        if uncertain { throw AppError.message("합성 전송 후 응답 미확인") }
        return .sent
    }
}

extension ApprovalTests {
    @MainActor private func terminalReplyFixture(_ directory: URL, probe: TerminalReplyProbe) async throws -> (ApprovalEngine, AgentSession, QueuedQuestion) {
        let record = ProcessDiscovery.parse("42 1 ttys099 42 42 Mon Oct 5 09:00:00 2026 codex")[0]
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/ttys099", cwd: "/fixture", terminal: .iterm)
        session.channel = .itermScreen
        let thread = "00000000-0000-4000-8000-000000000001"
        let target = CodexReplyTarget(executable: "", home: "/fixture", threadID: thread, queueAvailable: false)
        let transport = CodexReplyTransport(prepare: { _,_ in target }, send: { _,_ in throw AppError.message("An unavailable queue must never receive a submission") }, prepareMessage: { _ in target })
        let adapter = ScreenHostAdapter(screens: { _ in TerminalSnapshot(screens: [TerminalScreen(tty: "/dev/ttys099", contents: "검사 원본\n› ")]) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { _,_,_,input in try probe.input(input) })
        let queue = CodexQueueTransport(list: { _ in throw AppError.message("Unavailable queue read") }, delete: { _,_ in throw AppError.message("Unavailable queue delete") }, conversations: { _,_ in throw AppError.message("Unavailable conversation read") })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), questionTransport: transport, processReader: { [record] }, screenAdapters: [.iterm: adapter], codexQueue: queue)
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
        let question = QueuedQuestion(id: "choice-without-server", threadID: thread, title: "어떤 화면을 점검할까요?", options: ["모바일 화면", "데스크톱 화면", "두 화면 모두"])
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: session.id, questions: [question])])
        return (engine, session, question)
    }

    @MainActor func testCodexQuestionReplyWithoutServerUsesOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reply-original-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = TerminalReplyProbe(), (engine, session, question) = try await terminalReplyFixture(directory, probe: probe)
        defer { engine.stop() }
        try engine.setPaused(true)
        try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "두 화면 모두\n한글 🧪 추가 설명")
        try expectEqual(probe.messages, ["> 어떤 화면을 점검할까요?\n\n두 화면 모두\n한글 🧪 추가 설명\r"])
        let actual = engine.snapshot.sessions.first { $0.id == session.id }!
        try expectEqual(actual.questions[0].reply?.phase, .queued); try expectEqual(actual.questions[0].reply?.transport, .terminal)
        try expectNil(actual.questions[0].reply?.queueID)
        try expectEqual(actual.pid, session.pid); try expectEqual(actual.started, session.started); try expectEqual(actual.tty, session.tty)
        try expect(engine.snapshot.events.contains { $0.outcome == "답변 원본 터미널 전달" && $0.answer == "두 화면 모두\n한글 🧪 추가 설명" })
        try expect(engine.managedPTY.inventory.isEmpty)
        var rejected = false
        do { try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "중복") } catch { rejected = true }
        try expect(rejected); try expectEqual(probe.messages.count, 1)
    }

    @MainActor func testCodexOriginalQuestionReplyFailureAndUnknownReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reply-original-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for unknown in [false, true] {
            let probe = TerminalReplyProbe(); probe.decline = !unknown; probe.uncertain = unknown
            let (engine, session, question) = try await terminalReplyFixture(directory.appendingPathComponent(unknown ? "unknown" : "rejected"), probe: probe)
            defer { engine.stop() }
            var rejected = false
            do { try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "모바일 화면") } catch { rejected = true }
            try expect(rejected)
            let reply = engine.snapshot.sessions.first { $0.id == session.id }?.questions.first?.reply
            try expectEqual(reply?.phase, unknown ? .uncertain : .failed)
            try expectEqual(probe.messages.count, unknown ? 1 : 0)
            if unknown {
                do { try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "중복") } catch {}
                try expectEqual(probe.messages.count, 1)
            }
        }
    }

    @MainActor func testLegacyMissingServerReplyIsProvenNonWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reply-legacy-missing-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = TerminalReplyProbe(), (original, _, savedQuestion) = try await terminalReplyFixture(directory, probe: probe)
        let store = try AuditStore(path: AppPaths(directory: directory).database)
        let missing = QuestionReply(phase: .uncertain, answer: "데스크톱 화면", message: CodexQueueTransport.unavailableMessage)
        try store.set("questionReply:\(savedQuestion.id)", String(decoding: JSONEncoder().encode(missing), as: UTF8.self)); original.stop()
        let (engine, session, question) = try await terminalReplyFixture(directory, probe: probe)
        defer { engine.stop() }
        try expectEqual(engine.snapshot.sessions.first?.questions.first?.reply?.phase, .failed)
        try expect(probe.messages.isEmpty)
        try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "데스크톱 화면")
        try expectEqual(probe.messages.count, 1)
        let timeout = QuestionReply(phase: .uncertain, answer: "모바일 화면", message: "전송 후 응답 시간 초과")
        try store.set("questionReply:\(question.id)", String(decoding: JSONEncoder().encode(timeout), as: UTF8.self)); engine.stop()
        let (uncertain, _, _) = try await terminalReplyFixture(directory, probe: probe); defer { uncertain.stop() }
        try expectEqual(uncertain.snapshot.sessions.first?.questions.first?.reply?.phase, .uncertain)
        try expectEqual(probe.messages.count, 1)
    }

    @MainActor func testUnavailableCodexQueueDoesNotBlockQuestionsOrReadServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-queue-unavailable-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = TerminalReplyProbe(), (engine, session, question) = try await terminalReplyFixture(directory, probe: probe)
        defer { engine.stop() }
        let queue = try await engine.remoteCodexQueue(sessionID: session.id), conversations = try await engine.remoteCodexConversations(sessionID: session.id)
        try expectEqual(queue.available, false); try expect(queue.items.isEmpty); try expectEqual(conversations.available, false)
        try expectEqual(engine.snapshot.sessions.first?.questions.first?.id, question.id)
        try expect(probe.messages.isEmpty)
        var rejected = false
        do { _ = try await engine.remoteAction(["action": "clearQueuedInputs", "sessionID": session.id, "threadID": question.threadID, "queueIDs": ["old"]]) } catch { rejected = true }
        try expect(rejected); try expect(probe.messages.isEmpty)
    }
}
