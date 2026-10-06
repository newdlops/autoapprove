import Foundation
import AutoApproveCore

private actor QueueRecorder {
    var items = [CodexQueuedInput(id: "first", text: "첫 번째"), CodexQueuedInput(id: "second", text: "두 번째")]
    var deleted: [String] = []
    var failure: String?
    var messages: [String] = []
    func list() -> [CodexQueuedInput] { items }
    func add(_ item: CodexQueuedInput) { items.append(item) }
    func consume(_ id: String) { items.removeAll { $0.id == id } }
    func fail() { failure = "합성 삭제 실패" }
    func send(_ thread: String, _ text: String) -> String { messages.append(thread + ":" + text); return "queue-receipt" }
    func validate() throws { if failure != nil { throw RemoteHTTPError(409, "선택한 대화가 바뀌었습니다.") } }
    func sent() -> [String] { messages }
    func remove(_ ids: [String]) -> CodexQueueDeletion {
        let removed = ids.filter { id in items.contains { $0.id == id } }.prefix(failure == nil ? ids.count : 1)
        deleted.append(contentsOf: removed); items.removeAll { removed.contains($0.id) }
        return CodexQueueDeletion(removed: Array(removed), error: failure)
    }
}

extension ApprovalTests {
    func testExplicitCodexConversationMessagePreservesOriginalAndRejectsStaleTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-codex-selected-message-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("42 1 ttys099 42 42 Mon Oct 5 09:00:00 2026 codex")[0]
        var session = AgentSession(id:record.key, agent:.codex, pid:record.pid, started:record.started, tty:"/dev/ttys099", cwd:"/fixture", terminal:.iterm)
        session.phase = .working; session.channel = .itermScreen
        let recorder = QueueRecorder(), thread = "00000000-0000-4000-8000-000000000001"
        let target = CodexReplyTarget(executable:"/fixture",home:"/fixture",threadID:thread)
        let transport = CodexReplyTransport(prepare:{_,_ in target},send:{ target,text in await recorder.send(target.threadID,text) },prepareMessage:{_ in throw AppError.message("No open rollout")},prepareQueue:{_,_ in target})
        let queue = CodexQueueTransport(list:{_ in []},delete:{_,_ in CodexQueueDeletion(removed:[])},validate:{_,cwd in
            guard cwd == "/fixture" else { throw RemoteHTTPError(409,"Wrong folder") }; try await recorder.validate()
        })
        let engine = try ApprovalEngine(paths:AppPaths(directory:directory),questionTransport:transport,processReader:{[record]},codexQueue:queue)
        engine.updateDiscovery([session],records:[record]);try engine.setAutomatic(session.id,enabled:true)
        let result = try await engine.remoteAction(["action":"sendMessage","sessionID":session.id,"threadID":thread,"text":"자동 테스트를 실행해주세요."])
        try expectEqual(result["queueID"] as? String,"queue-receipt");try expectEqual(await recorder.sent(),[thread + ":자동 테스트를 실행해주세요."])
        try expectEqual(engine.snapshot.sessions[0].pid,session.pid);try expectEqual(engine.snapshot.sessions[0].tty,session.tty);try expect(engine.snapshot.sessions[0].automatic);try expect(engine.managedPTY.inventory.isEmpty)
        do { _ = try await engine.remoteAction(["action":"sendMessage","sessionID":session.id,"threadID":UUID().uuidString,"text":"Wrong target"]);throw AppError.message("Wrong selected target accepted") } catch let error as RemoteHTTPError { try expectEqual(error.status,409) }
        await recorder.fail()
        do { _ = try await engine.remoteAction(["action":"sendMessage","sessionID":session.id,"threadID":thread,"text":"Stale target"]);throw AppError.message("Stale target accepted") } catch let error as RemoteHTTPError { try expectEqual(error.status,409) }
        let ended = try ApprovalEngine(paths:AppPaths(directory:directory),questionTransport:transport,processReader:{[]},codexQueue:queue)
        ended.updateDiscovery([session],records:[record])
        do { _ = try await ended.remoteAction(["action":"sendMessage","sessionID":session.id,"threadID":thread,"text":"Ended process"]);throw AppError.message("Ended process accepted") } catch let error as RemoteHTTPError { try expectEqual(error.status,409) }
        try expectEqual(await recorder.sent().count,1)
    }
    func testCodexQueueSnapshotDeletionPreservesNewAndConsumedInputs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-codex-queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("42 1 ttys099 42 42 Mon Oct 5 09:00:00 2026 codex")[0]
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/ttys099", cwd: "/fixture", terminal: .iterm)
        session.phase = .working; session.channel = .itermScreen
        let recorder = QueueRecorder(), thread = "00000000-0000-4000-8000-000000000001"
        let transport = CodexReplyTransport(prepare: { _, _ in CodexReplyTarget(executable: "/fixture", home: "/fixture", threadID: thread) }, send: { _, _ in "first" }, prepareMessage: { _ in CodexReplyTarget(executable: "/fixture", home: "/fixture", threadID: thread) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), questionTransport: transport, processReader: { [record] }, codexQueue: CodexQueueTransport(list: { _ in await recorder.list() }, delete: { _, ids in await recorder.remove(ids) }))
        engine.updateDiscovery([session], records: [record]); try engine.setAutomatic(session.id, enabled: true)
        let question = QueuedQuestion(id: "fixture-question", threadID: thread, title: "선택해주세요.", options: ["첫 번째"])
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: session.id, questions: [question])])
        try await engine.replyToQuestion(sessionID: session.id, questionID: question.id, answer: "첫 번째")
        let initial = try await engine.remoteCodexQueue(sessionID: session.id)
        await recorder.consume("second"); await recorder.add(CodexQueuedInput(id: "later", text: "새로 들어온 입력"))
        let result = try await engine.remoteAction(["action":"clearQueuedInputs", "sessionID":session.id, "threadID":thread, "queueIDs":initial.items.map(\.id)])
        try expectEqual(result["removed"] as? Int, 1); try expectEqual(result["skipped"] as? Int, 1)
        try expectEqual(await recorder.list().map(\.id), ["later"])
        let current = engine.snapshot.sessions[0]
        try expectEqual(current.pid, session.pid); try expectEqual(current.started, session.started); try expectEqual(current.tty, session.tty)
        try expect(current.automatic); try expectEqual(current.questions[0].reply?.phase, .cancelled)
        try expectEqual(current.questions[0].automation?.phase, .cancelled)
        try expect(engine.managedPTY.inventory.isEmpty)
        try expect(engine.snapshot.events.contains { $0.outcome == "대기 입력 1개 삭제" })
        do {
            _ = try await engine.remoteAction(["action":"clearQueuedInputs", "sessionID":session.id, "threadID":"wrong", "queueIDs":["later"]]); throw AppError.message("Wrong conversation accepted")
        } catch let error as RemoteHTTPError { try expectEqual(error.status,409) }
        try expectEqual(await recorder.list().map(\.id), ["later"])
    }

    func testCodexQueuePartialFailureKeepsUndeletedInputsAndAudit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-codex-queue-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("42 1 ttys099 42 42 Mon Oct 5 09:00:00 2026 codex")[0]
        let session = AgentSession(id:record.key, agent:.codex, pid:record.pid, started:record.started, tty:"/dev/ttys099", cwd:"/fixture", terminal:.iterm)
        let recorder = QueueRecorder(), thread = "00000000-0000-4000-8000-000000000001"
        let transport = CodexReplyTransport(prepare:{_,_ in CodexReplyTarget(executable:"/fixture",home:"/fixture",threadID:thread)},send:{_,_ in "unused"},prepareMessage:{_ in CodexReplyTarget(executable:"/fixture",home:"/fixture",threadID:thread)})
        let engine = try ApprovalEngine(paths:AppPaths(directory:directory),questionTransport:transport,processReader:{[record]},codexQueue:CodexQueueTransport(list:{_ in await recorder.list()},delete:{_,ids in await recorder.remove(ids)}))
        engine.updateDiscovery([session],records:[record]); await recorder.fail()
        do {
            _ = try await engine.remoteAction(["action":"clearQueuedInputs","sessionID":session.id,"threadID":thread,"queueIDs":["first","second"]]); throw AppError.message("Partial failure ignored")
        } catch let error as RemoteHTTPError { try expectEqual(error.status,503); try expect(error.message.contains("1개")) }
        try expectEqual(await recorder.list().map(\.id),["second"])
        try expect(engine.snapshot.events.contains{$0.outcome == "대기 입력 1개 삭제 · 나머지 확인 필요"})
        let ended = try ApprovalEngine(paths:AppPaths(directory:directory),questionTransport:transport,processReader:{[]},codexQueue:CodexQueueTransport(list:{_ in await recorder.list()},delete:{_,ids in await recorder.remove(ids)}))
        ended.updateDiscovery([session],records:[record])
        do { _ = try await ended.remoteCodexQueue(sessionID:session.id); throw AppError.message("Exited process accepted") } catch let error as RemoteHTTPError { try expectEqual(error.status,409) }
    }
}
