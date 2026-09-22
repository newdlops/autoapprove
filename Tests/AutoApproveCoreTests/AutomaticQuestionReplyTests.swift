import Foundation
import AutoApproveCore

private actor AutomaticReplyProbe {
    struct Delivery {
        var thread: String
        var message: String
        var date: Date
    }
    var deliveries: [Delivery] = []
    var preparations = 0
    private var heldQuestions = Set<String>()
    private var gates: [CheckedContinuation<Void, Never>] = []
    func prepare(_ question: QueuedQuestion, hold: Bool = false) async -> CodexReplyTarget {
        preparations += 1
        if hold, heldQuestions.insert(question.id).inserted { await withCheckedContinuation { gates.append($0) } }
        return CodexReplyTarget(executable: "/unused", home: "/fixture", threadID: question.threadID)
    }
    func release() {
        let waiting = gates; gates = []
        for gate in waiting { gate.resume() }
    }
    func send(_ target: CodexReplyTarget, _ message: String) -> String {
        deliveries.append(Delivery(thread: target.threadID, message: message, date: Date()))
        return UUID().uuidString
    }
    var count: Int { deliveries.count }
}

@MainActor private struct AutomaticReplyFixture {
    var engine: ApprovalEngine
    var session: AgentSession
    var question: QueuedQuestion
    var paths: AppPaths
    init(root: URL, name: String, transport: CodexReplyTransport, enabled: Bool = true, restored: Bool = false) throws {
        paths = AppPaths(directory: root.appendingPathComponent(name))
        engine = try ApprovalEngine(paths: paths, questionTransport: transport)
        session = AgentSession(id: "process:\(name):first", agent: .codex, pid: 42, started: name,
            tty: "/dev/fixture-\(name)", cwd: "/tmp/reply", terminal: .terminal)
        session.phase = .working; session.channel = .terminalScreen
        question = QueuedQuestion(id: "codex:\(name):question:0", threadID: name,
            title: "\(name) 작업을 진행할까요?", options: ["No", "Yes (Recommended)"])
        engine.updateDiscovery([session], records: [])
        if !restored { engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: session.id, questions: [], threadID: name)]) }
        observe()
        if enabled { try engine.setAutomatic(session.id, enabled: true) }
    }
    func observe() {
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: session.id, questions: [question])])
    }
    var reply: QuestionReply? { engine.snapshot.sessions.first?.questions.first?.reply }
    var automation: QuestionAutomation? { engine.snapshot.sessions.first?.questions.first?.automation }
}

@MainActor private func waitForAutomaticReply(timeout: TimeInterval = 7, _ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        try expect(Date() < deadline, "Timed out waiting for automatic question response")
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

extension ApprovalTests {
    func testAutomaticAllowQuestionReply() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-auto-allow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AutomaticReplyProbe()
        let transport = CodexReplyTransport(prepare: { _, question in await probe.prepare(question) },
            send: { target, message in await probe.send(target, message) })
        var fixture = try AutomaticReplyFixture(root: root, name: "allow", transport: transport)
        defer { fixture.engine.stop() }
        fixture.question.options = ["Don’t allow", "Always allow", "Allow once (Recommended)"]
        let observed = Date()
        fixture.observe()
        try expectEqual(fixture.automation?.answer, "Allow once (Recommended)")
        try await waitForAutomaticReply { await probe.count == 1 }
        try expect((await probe.deliveries[0].date).timeIntervalSince(observed) >= 5)
        try expect((await probe.deliveries[0].message).hasSuffix("\n\nAllow once (Recommended)"))
        try expectEqual(fixture.reply?.phase, .queued)
        try expectEqual(fixture.engine.snapshot.events.first?.answer, "Allow once (Recommended)")
    }

    func testAutomaticQuestionReplyWaitsFiveSecondsPerQuestion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-auto-delay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AutomaticReplyProbe()
        let transport = CodexReplyTransport(prepare: { _, question in await probe.prepare(question) }, send: { target, message in
            let store = try AuditStore(path: root.appendingPathComponent("delay/state.sqlite").path, readOnly: true)
            let audit = store.recent().first
            try expectEqual(audit?.source, "Codex 질문 자동 응답")
            try expectEqual(audit?.outcome, "답변 전송 준비")
            try expect(audit?.answer.map { message.hasSuffix($0) } == true)
            try expect(store.value("questionReply:codex:delay:question:\(message.contains("다음 질문") ? 1 : 0)")?.contains("sending") == true)
            return await probe.send(target, message)
        })
        let firstObserved = Date()
        let fixture = try AutomaticReplyFixture(root: root, name: "delay", transport: transport)
        defer { fixture.engine.stop() }
        let originalDeadline = fixture.automation?.deadline
        try expectEqual(fixture.automation?.phase, .scheduled)
        try expect((originalDeadline?.timeIntervalSince(firstObserved) ?? 0) >= 5)
        do {
            try await fixture.engine.replyToQuestion(sessionID: "unrelated", questionID: fixture.question.id, answer: "No")
            throw AppError.message("An unrelated session must not answer this question")
        } catch {
            try expectEqual(error.localizedDescription, "이미 전송 중이거나 처리한 질문입니다. 현재 상태를 확인해주세요.")
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try expectEqual(await probe.count, 0, "The response must wait five seconds")
        let secondObserved = Date()
        let second = QueuedQuestion(id: "codex:delay:question:1", threadID: "delay", title: "다음 질문도 진행할까요?",
            options: ["Yes, don’t ask again (a)", "No (esc)", "Yes, proceed (y)"])
        let update = CodexQuestionUpdate(sessionID: fixture.session.id, questions: [fixture.question, second])
        fixture.engine.updateCodexQuestions([update])
        try expectEqual(fixture.automation?.deadline, originalDeadline, "Repeated reads keep the displayed deadline")
        try await waitForAutomaticReply(timeout: 4) { await probe.count == 1 }
        let first = await probe.deliveries[0]
        try expect(first.date.timeIntervalSince(firstObserved) >= 5)
        try expectEqual(first.message, "> delay 작업을 진행할까요?\n\nYes (Recommended)")
        try expectNil(fixture.engine.snapshot.sessions[0].questions[1].reply)
        fixture.engine.updateCodexQuestions([update])
        try await waitForAutomaticReply(timeout: 4) { await probe.count == 2 }
        let next = await probe.deliveries[1]
        try expect(next.date.timeIntervalSince(secondObserved) >= 5, "Each question owns its wait interval")
        try expectEqual(next.message, "> 다음 질문도 진행할까요?\n\nYes, proceed (y)")
        try expectEqual(fixture.engine.snapshot.sessions[0].phase, .working)
        try expect(fixture.engine.snapshot.sessions[0].unansweredQuestions.isEmpty)
        fixture.engine.updateCodexQuestions([update])
        let reopened = try ApprovalEngine(paths: fixture.paths, questionTransport: transport)
        defer { reopened.stop() }
        reopened.updateDiscovery([fixture.session], records: []); reopened.updateCodexQuestions([update])
        try await Task.sleep(nanoseconds: 5_100_000_000)
        try expectEqual(await probe.count, 2, "Repeated reads and app restart cannot resubmit queued answers")
        try expectEqual(try AuditStore(path: fixture.paths.database).history(result: .queued).total, 2)
    }

    func testAutomaticQuestionReplyCancellationAndResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-auto-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AutomaticReplyProbe()
        let transport = CodexReplyTransport(prepare: { _, question in await probe.prepare(question) },
            send: { target, message in await probe.send(target, message) })
        var fixtures: [String: AutomaticReplyFixture] = [:]
        defer { fixtures.values.forEach { $0.engine.stop() } }
        for name in ["off", "disabled", "paused", "ended", "dismissed", "resolved", "error", "pending-read", "disconnected", "stopped", "manual", "choices", "resumed", "changed"] {
            var fixture = try AutomaticReplyFixture(root: root, name: name, transport: transport, enabled: name != "off")
            switch name {
            case "disabled": try fixture.engine.setAutomatic(fixture.session.id, enabled: false)
            case "paused", "resumed": try fixture.engine.setPaused(true)
            case "ended": fixture.engine.updateDiscovery([], records: [])
            case "dismissed": try fixture.engine.dismissQuestion(sessionID: fixture.session.id, questionID: fixture.question.id)
            case "resolved": fixture.engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: fixture.session.id, questions: [])])
            case "error": fixture.engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: fixture.session.id, error: "읽기 실패")])
            case "pending-read": fixture.engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: fixture.session.id, questions: nil)])
            case "disconnected": fixture.engine.disconnectTerminal()
            case "stopped": fixture.engine.stop(); fixture.observe()
            case "manual":
                try fixture.engine.setPaused(true)
                try await fixture.engine.replyToQuestion(sessionID: fixture.session.id, questionID: fixture.question.id, answer: "No")
                try fixture.engine.setPaused(false)
            case "choices":
                fixture.question.options = ["프로젝트 A", "프로젝트 B", "No"]
                fixture.observe()
            default: break
            }
            fixtures[name] = fixture
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let resumedAt = Date()
        try fixtures["resumed"]!.engine.setPaused(false)
        fixtures["changed"]!.question.title = "변경된 질문을 진행할까요?"
        fixtures["changed"]!.observe()
        try await Task.sleep(nanoseconds: 3_200_000_000)
        try expectEqual(await probe.count, 1, "Cancelled waits cannot send Yes; manual No remains available while paused")
        try await waitForAutomaticReply(timeout: 4) { await probe.count == 3 }
        let deliveries = await probe.deliveries
        try expectEqual(Set(deliveries.map(\.thread)), Set(["manual", "resumed", "changed"]))
        try expect(deliveries.filter { $0.thread != "manual" }.allSatisfy { $0.date.timeIntervalSince(resumedAt) >= 5 })
        try expect(deliveries.first(where: { $0.thread == "changed" })?.message.contains("변경된 질문") == true)
        try expect(deliveries.first(where: { $0.thread == "manual" })?.message.hasSuffix("No") == true)
    }

    func testAutomaticQuestionReplyRevalidatesAfterPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-auto-preflight-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AutomaticReplyProbe()
        let transport = CodexReplyTransport(prepare: { _, question in await probe.prepare(question, hold: true) },
            send: { target, message in await probe.send(target, message) })
        var fixtures: [String: AutomaticReplyFixture] = [:]
        defer { fixtures.values.forEach { $0.engine.stop() } }
        for name in ["pause", "disable", "change", "dismiss", "stop", "read-error", "stable"] {
            fixtures[name] = try AutomaticReplyFixture(root: root, name: name, transport: transport)
        }
        try await waitForAutomaticReply { await probe.preparations == fixtures.count }
        for (name, var fixture) in fixtures {
            switch name {
            case "pause": try fixture.engine.setPaused(true); try fixture.engine.setPaused(false)
            case "disable": try fixture.engine.setAutomatic(fixture.session.id, enabled: false); try fixture.engine.setAutomatic(fixture.session.id, enabled: true)
            case "change":
                fixture.question.title = "새 질문입니다."; fixture.question.options = ["새 작업", "다른 작업"]
                fixture.observe()
            case "dismiss": try fixture.engine.dismissQuestion(sessionID: fixture.session.id, questionID: fixture.question.id)
            case "stop": fixture.engine.stop()
            case "read-error": fixture.engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: fixture.session.id, questions: nil)])
            default: fixture.observe()
            }
        }
        let resumedAt = Date()
        await probe.release()
        try await waitForAutomaticReply {
            fixtures["stable"]!.reply?.phase == .queued && ["pause", "disable", "stop", "read-error"].allSatisfy { fixtures[$0]!.reply?.phase == .cancelled }
        }
        try expectEqual(await probe.count, 1)
        try expectEqual(await probe.deliveries.first?.thread, "stable")
        try expect(fixtures["change"]!.reply == nil, "A stale preflight cannot overwrite the replacement question")
        try expect(fixtures["dismiss"]!.engine.snapshot.sessions[0].questions.isEmpty)
        for name in ["pause", "disable"] {
            try expectEqual(fixtures[name]!.automation?.phase, .scheduled)
            try expect((fixtures[name]!.automation?.deadline?.timeIntervalSince(resumedAt) ?? 0) >= 5)
        }
        try await waitForAutomaticReply { await probe.count == 3 }
        let resumed = await probe.deliveries.filter { $0.thread != "stable" }
        try expectEqual(Set(resumed.map(\.thread)), Set(["pause", "disable"]))
        try expect(resumed.allSatisfy { $0.date.timeIntervalSince(resumedAt) >= 5 })
    }

    func testAutomaticQuestionReplyFailuresAreNotRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-auto-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AutomaticReplyProbe()
        let transport = CodexReplyTransport(prepare: { _, question in
            let target = await probe.prepare(question)
            if question.threadID == "preflight" { throw AppError.message("질문 검증 실패") }
            return target
        }, send: { target, message in
            _ = await probe.send(target, message)
            throw AppError.message("전송 후 접수 확인 실패")
        })
        var fixtures: [AutomaticReplyFixture] = []
        defer { fixtures.forEach { $0.engine.stop() } }
        for name in ["preflight", "audit", "uncertain", "message"] {
            var fixture = try AutomaticReplyFixture(root: root, name: name, transport: transport)
            if name == "audit" {
                try expectEqual(try CommandRunner.run("/usr/bin/sqlite3", [fixture.paths.database, "DROP TABLE events;"]).status, 0)
            }
            if name == "message" {
                fixture.question.title = String(repeating: "x", count: 32_001)
                fixture.observe()
            }
            fixtures.append(fixture)
        }
        try await waitForAutomaticReply { fixtures.allSatisfy { $0.reply?.phase == .failed || $0.reply?.phase == .uncertain } }
        try expectEqual(await probe.preparations, 3)
        try expectEqual(await probe.count, 1, "No dispatch without successful preflight and a durable audit")
        try expectEqual(fixtures[2].reply?.phase, .uncertain)
        var reopened: [ApprovalEngine] = []
        defer { reopened.forEach { $0.stop() } }
        for fixture in fixtures {
            fixture.observe()
            let engine = try ApprovalEngine(paths: fixture.paths, questionTransport: transport)
            engine.updateDiscovery([fixture.session], records: [])
            engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: fixture.session.id, questions: [fixture.question])])
            reopened.append(engine)
        }
        try await Task.sleep(nanoseconds: 5_100_000_000)
        try expectEqual(await probe.preparations, 3, "Failed or uncertain answers require manual review, also after restart")
        try expectEqual(await probe.count, 1)
    }

    func testQuestionDraftAndIndividualCancellationPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-auto-draft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AutomaticReplyProbe()
        let transport = CodexReplyTransport(prepare: { _, question in await probe.prepare(question) }, send: { target, text in await probe.send(target, text) })
        var fixtures: [String: AutomaticReplyFixture] = [:]
        var reopened: [ApprovalEngine] = []
        defer { fixtures.values.forEach { $0.engine.stop() }; reopened.forEach { $0.stop() } }
        for name in ["draft", "cancel", "sibling", "save-error"] {
            let fixture = try AutomaticReplyFixture(root: root, name: name, transport: transport)
            fixtures[name] = fixture
            if name == "save-error" {
                try expectEqual(try CommandRunner.run("/usr/bin/sqlite3", [fixture.paths.database, "DROP TABLE settings;"]).status, 0)
                try expectThrows(try fixture.engine.beginQuestionReply(sessionID: fixture.session.id, questionID: fixture.question.id))
                try expectEqual(fixture.automation?.phase, .editing, "A save failure still stops the current timer")
            } else if name == "draft" {
                try fixture.engine.beginQuestionReply(sessionID: fixture.session.id, questionID: fixture.question.id)
                try expectEqual(fixture.automation?.phase, .editing)
            } else if name == "cancel" {
                try fixture.engine.cancelQuestionAutomaticReply(sessionID: fixture.session.id, questionID: fixture.question.id)
                try expectEqual(fixture.automation?.phase, .cancelled)
            } else {
                try fixture.engine.beginQuestionReply(sessionID: "unrelated", questionID: fixture.question.id)
                try expectEqual(fixture.automation?.phase, .scheduled)
            }
            if ["draft", "cancel"].contains(name) {
                try fixture.engine.setPaused(true); try fixture.engine.setPaused(false)
                fixture.observe()
                let engine = try ApprovalEngine(paths: fixture.paths, questionTransport: transport)
                engine.updateDiscovery([fixture.session], records: [])
                engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: fixture.session.id, questions: [fixture.question])])
                try expectEqual(engine.snapshot.sessions[0].questions[0].automation?.phase, fixture.automation?.phase)
                reopened.append(engine)
            }
        }
        try await waitForAutomaticReply { fixtures["sibling"]!.reply?.phase == .queued }
        try expectEqual(await probe.count, 1, "Only the untouched sibling may send after the five-second wait")
        try expectEqual(await probe.deliveries.first?.thread, "sibling")
        let draft = fixtures["draft"]!
        try draft.engine.setPaused(true)
        try await draft.engine.replyToQuestion(sessionID: draft.session.id, questionID: draft.question.id, answer: "No")
        try expectEqual(await probe.count, 2, "Draft protection preserves explicit manual replies while paused")
        try expectEqual(draft.reply?.answer, "No")
    }

    func testQuestionHistoryGuardsAutomaticResponses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-auto-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AutomaticReplyProbe()
        let transport = CodexReplyTransport(prepare: { _, question in await probe.prepare(question) }, send: { target, text in await probe.send(target, text) })
        var fixtures: [AutomaticReplyFixture] = []
        defer { fixtures.forEach { $0.engine.stop() } }
        let restored = try AutomaticReplyFixture(root: root, name: "restored", transport: transport, restored: true)
        fixtures.append(restored)
        try expectEqual(restored.automation?.phase, .restored)
        restored.engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: restored.session.id, questions: nil)])
        restored.observe()
        try expectEqual(restored.automation?.phase, .restored, "Recovery cannot turn old history into new questions")
        let duplicate = try AutomaticReplyFixture(root: root, name: "duplicate", transport: transport)
        fixtures.append(duplicate)
        var copy = duplicate.question; copy.id += ":copy"; copy.title = "  " + copy.title + "\n"
        duplicate.engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: duplicate.session.id, questions: [duplicate.question, copy])])
        try expect(duplicate.engine.snapshot.sessions[0].questions.allSatisfy { $0.automation?.phase == .duplicate })
        let later = try AutomaticReplyFixture(root: root, name: "later", transport: transport)
        fixtures.append(later)
        let rows: [CodexQuestionHistory.Item] = [
            .init(ordinal: 1, json: ["type": "agentMessage", "id": "question", "delivery": "async", "questions": [["title": later.question.title, "options": later.question.options]]]),
            .init(ordinal: 2, json: ["type": "userMessage", "content": [["type": "text", "text": "No"]]])
        ]
        let pending = CodexQuestionHistory.pending(threadID: "later", items: rows)
        try expectEqual(pending.count, 1, "An unquoted answer remains visible for manual resolution")
        later.engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: later.session.id, questions: pending)])
        try expectEqual(later.automation?.phase, .needsReview)
        let switched = try AutomaticReplyFixture(root: root, name: "switched", transport: transport)
        fixtures.append(switched)
        var other = switched.question; other.threadID = "other-root"; other.id = "other-root-question"
        switched.engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: switched.session.id, questions: [other], threadID: other.threadID)])
        try expectEqual(switched.automation?.phase, .restored, "Each new root establishes its own history baseline")
        try await Task.sleep(nanoseconds: 5_300_000_000)
        try expectEqual(await probe.count, 0)
        let decoded = try JSONDecoder().decode(EngineSnapshot.self, from: JSONEncoder().encode(duplicate.engine.snapshot))
        try expectEqual(decoded.sessions[0].questions[0].automation?.phase, .duplicate)
    }

    func testAutomaticReplyHonorsFreshTransportHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-auto-history-preflight-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AutomaticReplyProbe()
        let transport = CodexReplyTransport(prepare: { _, question in
            CodexReplyTarget(executable: "/unused", home: "/fixture", threadID: question.threadID,
                automaticReplyUnavailableReason: "전송 직전 같은 질문 또는 후속 답변을 확인했습니다.")
        }, send: { target, text in await probe.send(target, text) })
        let fixture = try AutomaticReplyFixture(root: root, name: "late-history", transport: transport)
        defer { fixture.engine.stop() }
        try await waitForAutomaticReply { fixture.reply?.phase == .failed }
        try expectEqual(await probe.count, 0)
        try await fixture.engine.replyToQuestion(sessionID: fixture.session.id, questionID: fixture.question.id, answer: "No")
        try expectEqual(await probe.count, 1, "A user can explicitly resolve an ambiguous question")
    }
}
