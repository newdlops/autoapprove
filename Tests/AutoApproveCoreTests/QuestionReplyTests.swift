import Foundation
import AutoApproveCore

private actor ReplyRecorder {
    var messages: [(String, String)] = []
    func add(_ target: CodexReplyTarget, _ message: String) { messages.append((target.threadID, message)) }
    var count: Int { messages.count }
    var lastMessage: String? { messages.last?.1 }
}

extension ApprovalTests {
    private func replyFixture(_ engine: ApprovalEngine) -> (AgentSession, QueuedQuestion) {
        var session = AgentSession(id: "process:reply:first", agent: .codex, pid: 42, started: "first", tty: "/dev/fixture", cwd: "/tmp/reply", terminal: .terminal)
        session.phase = .working
        engine.updateDiscovery([session], records: [])
        let question = QueuedQuestion(id: "codex:thread:question:0", threadID: "00000000-0000-4000-8000-000000000001", title: "어느 작업을 할까요?", options: ["상태 확인", "PR 점검", "지정할 작업"])
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: session.id, questions: [question])])
        return (session, question)
    }

    func testReplyMessageAndReceipt() throws {
        let question = QueuedQuestion(id: "id", threadID: "00000000-0000-4000-8000-000000000001", title: "첫 줄\n둘째 줄")
        try expectEqual(try CodexReplyTransport.message(question: question, answer: "  A\nB; $(literal) `text` \"quote\"  "), "> 첫 줄\n> 둘째 줄\n\nA\nB; $(literal) `text` \"quote\"")
        try expectThrows(try CodexReplyTransport.message(question: question, answer: " \n "))
        try expectThrows(try CodexReplyTransport.message(question: question, answer: "a\0b"))
        let queueID = "00000000-0000-4000-8000-000000000002"
        let output = "Queued message \(queueID) for thread \(question.threadID).\n"
        try expectEqual(try CodexReplyTransport.receipt(output: output, status: 0, threadID: question.threadID), queueID)
        try expectThrows(try CodexReplyTransport.receipt(output: output, status: 1, threadID: question.threadID))
        try expectThrows(try CodexReplyTransport.receipt(output: output, status: 0, threadID: "different"))
        try expectThrows(try CodexReplyTransport.receipt(output: "ok", status: 0, threadID: question.threadID))
    }

    func testQuestionReplyAuditAndDuplicateProtection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reply-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory), recorder = ReplyRecorder()
        let transport = CodexReplyTransport(prepare: { _, question in
            CodexReplyTarget(executable: "/unused", home: "/fixture", threadID: question.threadID)
        }, send: { target, message in
            let store = try AuditStore(path: paths.database, readOnly: true)
            guard store.recent().first?.answer == "상태 확인\nPR 점검\n설명을 추가합니다.",
                  store.recent().first?.outcome == "답변 전송 준비",
                  store.value("questionReply:codex:thread:question:0")?.contains("sending") == true else {
                throw AppError.message("Audit and reservation must exist before dispatch")
            }
            await recorder.add(target, message)
            return "00000000-0000-4000-8000-000000000002"
        })
        let engine = try ApprovalEngine(paths: paths, questionTransport: transport)
        let (session, question) = replyFixture(engine)
        var tracker = AttentionTracker()
        try expectEqual(tracker.update(engine.snapshot).count, 1)
        try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "상태 확인\nPR 점검\n설명을 추가합니다.")
        try expectEqual(await recorder.count, 1)
        try expectEqual(await recorder.lastMessage, "> 어느 작업을 할까요?\n\n상태 확인\nPR 점검\n설명을 추가합니다.")
        try expectEqual(engine.snapshot.sessions[0].questions[0].reply?.phase, .queued)
        try expect(tracker.update(engine.snapshot).isEmpty)
        try expectEqual(engine.snapshot.events[0].outcome, "답변 대기열 등록")
        try expectEqual(engine.snapshot.events[0].result, .queued)
        try expectEqual(try AuditStore(path: paths.database, readOnly: true).history(result: .queued).total, 1)
        try expectEqual(try AuditStore(path: paths.database, readOnly: true).history(result: .review).total, 0)
        do { try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "중복"); throw TestReplyFailure.unexpectedSuccess } catch TestReplyFailure.unexpectedSuccess { throw TestReplyFailure.unexpectedSuccess } catch {}
        let reopened = try ApprovalEngine(paths: paths, questionTransport: transport)
        _ = replyFixture(reopened)
        try expectEqual(reopened.snapshot.sessions[0].questions[0].reply?.phase, .queued)
        do { try await reopened.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "재실행 중복"); throw TestReplyFailure.unexpectedSuccess } catch TestReplyFailure.unexpectedSuccess { throw TestReplyFailure.unexpectedSuccess } catch {}
        try expectEqual(await recorder.count, 1)
    }

    func testQuestionReplyUncertainAndPreflightFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reply-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory), recorder = ReplyRecorder()
        let transport = CodexReplyTransport(prepare: { _, question in
            CodexReplyTarget(executable: "/unused", home: "/fixture", threadID: question.threadID)
        }, send: { target, message in
            await recorder.add(target, message)
            throw AppError.message("전송 후 응답 시간 초과")
        })
        let engine = try ApprovalEngine(paths: paths, questionTransport: transport)
        let (session, question) = replyFixture(engine)
        do { try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "답변"); throw TestReplyFailure.unexpectedSuccess } catch TestReplyFailure.unexpectedSuccess { throw TestReplyFailure.unexpectedSuccess } catch {}
        try expectEqual(engine.snapshot.sessions[0].questions[0].reply?.phase, .uncertain)
        try expectEqual(engine.snapshot.events[0].outcome, "답변 접수 확인 필요")
        try expectEqual(await recorder.count, 1)
        let reopened = try ApprovalEngine(paths: paths, questionTransport: transport)
        _ = replyFixture(reopened)
        do { try await reopened.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "중복"); throw TestReplyFailure.unexpectedSuccess } catch TestReplyFailure.unexpectedSuccess { throw TestReplyFailure.unexpectedSuccess } catch {}
        try expectEqual(await recorder.count, 1)
        // A process killed during the dispatch is equally uncertain after restart.
        let sending = QuestionReply(phase: .sending, answer: "답변", message: "전송 중")
        try AuditStore(path: paths.database).set("questionReply:\(question.id)", String(decoding: JSONEncoder().encode(sending), as: UTF8.self))
        let crashed = try ApprovalEngine(paths: paths, questionTransport: transport)
        _ = replyFixture(crashed)
        try expectEqual(crashed.snapshot.sessions[0].questions[0].reply?.phase, .uncertain)
    }

    func testQuestionReplyRequiresCorrectThreadAndSavedAudit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-reply-preflight-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory), recorder = ReplyRecorder()
        let wrong = CodexReplyTransport(prepare: { _, _ in CodexReplyTarget(executable: "/unused", home: "/fixture", threadID: "wrong") }, send: { target, text in await recorder.add(target, text); return "unused" })
        let engine = try ApprovalEngine(paths: paths, questionTransport: wrong)
        let (session, question) = replyFixture(engine)
        do { try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "답변"); throw TestReplyFailure.unexpectedSuccess } catch TestReplyFailure.unexpectedSuccess { throw TestReplyFailure.unexpectedSuccess } catch {}
        try expectEqual(engine.snapshot.sessions[0].questions[0].reply?.phase, .failed)
        try expectEqual(await recorder.count, 0)
        let transport = CodexReplyTransport(prepare: { _, question in CodexReplyTarget(executable: "/unused", home: "/fixture", threadID: question.threadID) }, send: { target, text in await recorder.add(target, text); return "unused" })
        let withBrokenAudit = try ApprovalEngine(paths: paths, questionTransport: transport)
        _ = replyFixture(withBrokenAudit)
        let result = try CommandRunner.run("/usr/bin/sqlite3", [paths.database, "DROP TABLE events;"])
        try expectEqual(result.status, 0)
        do { try await withBrokenAudit.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "답변"); throw TestReplyFailure.unexpectedSuccess } catch TestReplyFailure.unexpectedSuccess { throw TestReplyFailure.unexpectedSuccess } catch {}
        try expectEqual(await recorder.count, 0, "No reply without a durable audit")
    }
}

private enum TestReplyFailure: Error { case unexpectedSuccess }
