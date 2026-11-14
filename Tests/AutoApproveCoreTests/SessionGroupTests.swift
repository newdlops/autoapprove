import Foundation
import AutoApproveCore

private func unwrapGroup<T>(_ value: T?) throws -> T {
    guard let value else { throw AppError.message("Expected session group test value") }
    return value
}

private final class GroupProcessChange: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let records: [ProcessRecord]
    init(_ records: [ProcessRecord]) { self.records = records }
    func read() -> [ProcessRecord] {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return calls == 1 ? records : []
    }
}

private final class GroupTerminalWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var output: [(tty: String, bytes: String)] = []
    private var rejections = 0
    private var screens: [String: String] = [:]
    var writes: [String] { lock.lock(); defer { lock.unlock() }; return output.map(\.bytes) }
    func writes(to tty: String) -> [String] { lock.lock(); defer { lock.unlock() }; return output.filter { $0.tty == tty }.map(\.bytes) }
    func screen(_ tty: String) -> String { lock.lock(); defer { lock.unlock() }; return screens[tty] ?? "검사 원본\n› " }
    func show(_ text: String, on tty: String) { lock.lock(); defer { lock.unlock() }; screens[tty] = text }
    func reject(_ count: Int) { lock.lock(); defer { lock.unlock() }; rejections = count }
    func send(_ target: ScreenTarget, _ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        if rejections > 0 { rejections -= 1; return .screenChanged }
        output.append((target.tty, input.bytes)); return .sent
    }
}

@MainActor private func waitForGroup(_ seconds: Double, _ condition: () async -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}

extension ApprovalTests {
    func testSessionGroupIdentityValidation() throws {
        let conversation = UUID()
        let member = SessionGroupMember(agent: .codex, title: "Codex", cwd: "/tmp/project",
                                        conversationID: conversation.uuidString, providerHome: "/tmp/codex")
        let group = try SessionGroup(name: "  작업 그룹  ", members: [member]).validated()
        try expectEqual(group.name, "작업 그룹")
        try expectEqual(group.members[0].conversationID, conversation.uuidString.lowercased())
        let data = try JSONEncoder().encode(group)
        try expectEqual(try JSONDecoder().decode(SessionGroup.self, from: data).validated(), group)
        var duplicate = member; duplicate.id = UUID()
        do {
            _ = try SessionGroup(name: "중복", members: [member, duplicate]).validated()
            throw AppError.message("Duplicate conversation must be rejected")
        } catch let error as AppError {
            try expect(error.localizedDescription.contains("중복"))
        }
        var firstRuntime = member; firstRuntime.runtimeID = "process:10:start"
        var secondRuntime = member; secondRuntime.id = UUID(); secondRuntime.conversationID = ""; secondRuntime.runtimeID = firstRuntime.runtimeID
        do {
            _ = try SessionGroup(name: "중복 실행", members: [firstRuntime, secondRuntime]).validated()
            throw AppError.message("Duplicate process must be rejected")
        } catch let error as AppError {
            try expect(error.localizedDescription.contains("중복"))
        }
        var invalid = member; invalid.conversationID = "process:123"
        do {
            _ = try SessionGroup(name: "잘못된 ID", members: [invalid]).validated()
            throw AppError.message("Process identifiers must not be used as conversation IDs")
        } catch let error as AppError {
            try expect(error.localizedDescription.contains("대화 ID"))
        }
    }

    func testSessionGroupStoragePreservesInvalidData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-groups-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionGroupStore(directory: directory)
        let group = SessionGroup(name: "작업")
        try expectEqual(try store.load(), [])
        try store.save([group])
        try expectEqual(try store.load(), [group])
        do {
            try store.save([], expected: [])
            throw AppError.message("Stale group list must not overwrite changes")
        } catch let error as AppError {
            try expect(error.localizedDescription.contains("다른 곳"))
        }
        try expectEqual(try store.load(), [group])
        let file = directory.appendingPathComponent("session-groups.json")
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: file)
        do {
            try store.save([])
            throw AppError.message("Corrupt data must not be overwritten")
        } catch let error as AppError {
            try expect(error.localizedDescription.contains("읽지 못했습니다"))
        }
        try expectEqual(try Data(contentsOf: file), corrupt)
    }

    func testSessionGroupMatchingRejectsAmbiguousAndChangedConversations() throws {
        let id = UUID().uuidString, other = UUID().uuidString
        var session = AgentSession(id: "process:42:start", agent: .codex, pid: 42, started: "start", tty: "/dev/ttys001", cwd: "/tmp/project", terminal: .terminal)
        session.phase = .working
        let live = SessionGroupLiveSession(session: session, conversationID: id, providerHome: "/tmp/home")
        let member = live.member
        try expectEqual(SessionGroupMatching.match(member, in: [live])?.id, session.id)
        var changed = live; changed.conversationID = other
        try expectNil(SessionGroupMatching.match(member, in: [changed]))
        changed = live; changed.providerHome = "/tmp/other-home"
        try expectNil(SessionGroupMatching.match(member, in: [changed]))
        changed = live; changed.session.id = "process:43:start"
        try expectNil(SessionGroupMatching.match(member, in: [live, changed]))
        var unresolved = member; unresolved.conversationID = ""
        try expectEqual(SessionGroupMatching.match(unresolved, in: [live])?.id, session.id)
        changed.session.id = "process:43:start"
        try expectNil(SessionGroupMatching.match(unresolved, in: [changed]))
        changed = live; changed.session.phase = .ended
        try expectNil(SessionGroupMatching.match(member, in: [changed]))
    }

    @MainActor func testSessionGroupMCPOnlyReturnsCallersGroupsAndSameAgent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-mcp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        100521 1 fixture1 100521 100521 Wed Oct 28 12:00:00 2026 /fixture/claude
        100522 1 fixture2 100522 100522 Wed Oct 28 12:00:00 2026 /fixture/claude
        100523 1 fixture3 100523 100523 Wed Oct 28 12:00:00 2026 /fixture/codex
        """)
        let sessions = records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/tmp/group-fixture", terminal: .terminal) }
        let claudeID = UUID().uuidString
        let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { records in
            records.filter { $0.pid == 100522 }.map { .init(processID: $0.key, kind: "interactive", activity: .init(providerID: claudeID, status: "idle", changedAt: Date()), peerName: "fixture-claude-peer") }
        }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: registry, processReader: { records })
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: records)
        let observations = try await engine.sessionGroupSessions()
        try expectEqual(observations.count, 3)
        let caller = try unwrapGroup(observations.first { $0.id == records[0].key })
        let second = try unwrapGroup(observations.first { $0.id == records[1].key })
        let third = try unwrapGroup(observations.first { $0.id == records[2].key })
        let store = SessionGroupStore(directory: directory)
        try store.save([SessionGroup(name: "함께", members: [caller.member, second.member, third.member]),
                        SessionGroup(name: "다른 그룹", members: [second.member])])
        let result = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "get_session_groups", "sessionID": caller.id])
        let groups = try unwrapGroup(result["groups"] as? [JSONObject])
        try expectEqual(groups.count, 1)
        try expectEqual(groups[0]["name"] as? String, "함께")
        let peers = try unwrapGroup(groups[0]["members"] as? [JSONObject])
        try expectEqual(peers.count, 3)
        try expectEqual(peers.filter { $0["sameAgent"] as? Bool == true }.count, 2)
        try expectEqual(peers.first { $0["agent"] as? String == "codex" }?["sameAgent"] as? Bool, false)
        try expectEqual(peers.first { $0["conversationID"] as? String == claudeID.lowercased() }?["messagingName"] as? String, "fixture-claude-peer")
        try expectEqual(peers.filter { $0["isCaller"] as? Bool == true }.count, 1)
        do {
            _ = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "get_session_groups", "sessionID": "invalid"])
            throw AppError.message("Unknown caller must be rejected")
        } catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
    }

    @MainActor func testSessionGroupObservationsUseExactBindingWithoutThreadList() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-binding-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("100531 1 fixture4 100531 100531 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        let thread = UUID().uuidString
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
                                   tty: "/dev/" + record.tty, cwd: "/tmp/group-fixture", terminal: .terminal)
        session.codexApprovalBinding = CodexApprovalBinding(threadID: thread, title: "fixture")
        let transport = CodexReplyTransport(prepare: { _, _ in throw AppError.message("not used") },
            send: { _, _ in throw AppError.message("must not send") },
            queueHome: { _ in .init(executable: "", home: "/tmp/group-home", threadID: "") })
        let queue = CodexQueueTransport(list: { _ in throw AppError.message("must not list queue") },
            delete: { _, _ in throw AppError.message("must not delete") },
            conversations: { _, _ in throw AppError.message("must not list threads") },
            validate: { target, cwd in
                guard target.threadID == thread, target.home == "/tmp/group-home", cwd == "/tmp/group-fixture" else {
                    throw AppError.message("wrong target")
                }
            })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), questionTransport: transport,
                                        processReader: { [record] }, codexQueue: queue)
        defer { engine.stop() }; engine.updateDiscovery([session], records: [record])
        let observation = try unwrapGroup(try await engine.sessionGroupSessions().first)
        try expectEqual(observation.conversationID, thread)
        try expectEqual(observation.providerHome, "/tmp/group-home")
        try SessionGroupStore(directory: directory).save([SessionGroup(name: "공유 서버", members: [observation.member])])
        let owner = UUID().uuidString
        let response = try await engine.mcpAction(["owner": owner, "tool": "get_session_groups", "sessionID": "shared-server",
                                                    "agentKind": "codex", "conversationID": thread])
        try expectEqual(response["attribution"] as? String, "provided_conversation_id")
        try expectEqual((response["groups"] as? [JSONObject])?.count, 1)
        for params: JSONObject in [
            ["owner": owner, "tool": "get_session_groups", "sessionID": "shared-server", "agentKind": "claude", "conversationID": thread],
            ["owner": owner, "tool": "get_session_groups", "sessionID": "shared-server", "agentKind": "codex", "conversationID": UUID().uuidString],
            ["owner": owner, "tool": "get_session_groups", "sessionID": session.id, "agentKind": "codex", "conversationID": UUID().uuidString]
        ] {
            do { _ = try await engine.mcpAction(params); throw AppError.message("Wrong caller must be rejected") }
            catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
        }
    }

    @MainActor func testSessionGroupObservationRejectsExitedProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-exit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("100541 1 fixture5 100541 100541 Wed Oct 28 12:00:00 2026 /fixture/claude")[0]
        let session = AgentSession(id: record.key, agent: .claude, pid: record.pid, started: record.started,
                                   tty: "/dev/" + record.tty, cwd: "/tmp/group-fixture", terminal: .terminal)
        let reads = GroupProcessChange([record])
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { _ in [] }, processReader: { reads.read() })
        defer { engine.stop() }; engine.updateDiscovery([session], records: [record])
        try expectEqual(try await engine.sessionGroupSessions().count, 0)
    }

    func testSessionGroupTreeValidationAndEdits() throws {
        func member(_ title: String) -> SessionGroupMember {
            SessionGroupMember(agent: .claude, title: title, cwd: "/tmp/project", conversationID: UUID().uuidString, providerHome: "/tmp/claude")
        }
        let a = member("A"), b = member("B"), c = member("C"), d = member("D")
        let valid = try SessionGroup(name: "트리", members: [a, b, c, d]).settingLeader(a.id)
            .settingParent(b.id, for: c.id).settingParent(c.id, for: d.id).validated()
        try expectEqual(valid.treeOrder.map(\.id), [a.id, b.id, c.id, d.id])
        try expectEqual(valid.treeOrder.map(\.depth), [0, 1, 2, 3])
        try expectNil(valid.parentID(of: a.id))
        try expectEqual(valid.parentID(of: b.id), a.id, "A top-level member reports to the leader")
        try expectEqual(valid.parentID(of: d.id), c.id)
        try expect(!valid.parentCandidates(for: b.id).contains { $0.id == d.id }, "A member never moves under its own descendant")
        try expectEqual(valid.settingParent(d.id, for: b.id), valid)
        try expect(valid.settingParent(a.id, for: c.id).members[2].parentMemberID == nil, "Under the leader is stored as nil")

        var cyclic = valid; cyclic.members[1].parentMemberID = d.id
        do { _ = try cyclic.validated(); throw AppError.message("A cycle must be rejected") }
        catch let error as AppError { try expect(error.localizedDescription.contains("상위 구성원")) }
        var flat = SessionGroup(name: "평면", members: [a, c]); flat.members[1].parentMemberID = a.id
        do { _ = try flat.validated(); throw AppError.message("A parent without a leader must be rejected") }
        catch let error as AppError { try expect(error.localizedDescription.contains("상위 구성원")) }

        let withoutC = try valid.removing(c.id).validated()
        try expectEqual(withoutC.parentID(of: d.id), b.id, "A removed member's reports move to its parent")
        let withoutLeader = try valid.removing(a.id).validated()
        try expectNil(withoutLeader.leaderMemberID)
        try expect(withoutLeader.members.allSatisfy { $0.parentMemberID == nil })
        let newLeader = try valid.settingLeader(d.id).validated()
        try expectEqual(newLeader.treeOrder.first?.id, d.id)
        try expectEqual(newLeader.treeOrder.count, 4, "Changing the leader keeps every member in the tree")

        let legacy = Data(#"[{"id":"\#(UUID().uuidString)","name":"기존","members":[{"id":"\#(UUID().uuidString)","agent":"claude","title":"기존","cwd":"/tmp","conversationID":""}]}]"#.utf8)
        let decoded = try JSONDecoder().decode([SessionGroup].self, from: legacy)
        try expect(decoded[0].leaderMemberID == nil, "A saved group from an older version stays flat")
        try expectNil(decoded[0].members[0].parentMemberID)
    }

    func testSessionGroupOrchestrationReportsOnlyTheAssignedTurn() throws {
        let now = Date(), group = UUID(), worker = UUID(), parent = UUID()
        func assignment(_ sentAt: Date, _ task: String) -> SessionGroupAssignment {
            SessionGroupAssignment(groupID: group, workerMemberID: worker, parentMemberID: parent,
                                   workerSessionID: "process:1:a", parentSessionID: "process:2:b", task: task, sentAt: sentAt)
        }
        var state = SessionGroupOrchestration()
        let first = assignment(now, "1. 빌드\n2. 테스트")
        state.begin(first)
        try expect(state.complete(workerSessionID: "process:1:a", completion: WorkCompletion(id: "old", date: now.addingTimeInterval(-10), summary: "이전 턴")) == nil,
                   "A turn that ended before the task is not its result")
        let second = assignment(now.addingTimeInterval(1), "다시 실행")
        state.begin(second)
        try expectEqual(state.assignments.first { $0.id == first.id }?.status, .superseded, "A new task replaces the unfinished one")
        let done = state.complete(workerSessionID: "process:1:a", completion: WorkCompletion(id: "new", date: now.addingTimeInterval(5), summary: "완료\n세부 내용"))
        try expectEqual(done?.id, second.id)
        try expectEqual(state.undelivered.map(\.id), [second.id])
        try expect(state.complete(workerSessionID: "process:1:a", completion: WorkCompletion(id: "later", date: now.addingTimeInterval(9))) == nil,
                   "Only the first completion after a task is reported")

        let report = SessionGroupOrchestration.report(for: state.undelivered, titles: [worker: "빌드\n작업자"])
        try expect(!report.contains("\n"), "Reports are one line so every terminal connection can submit them")
        try expect(report.contains("'빌드 작업자'") && report.contains(second.shortID) && report.contains("완료 세부 내용"))
        let task = SessionGroupOrchestration.taskMessage(first, parentTitle: "그룹장")
        try expect(!task.contains("\n") && task.contains("1. 빌드 2. 테스트") && task.contains("사용자에게 확인을 구하지 말고"))

        state.noteDeliveryFailure([second.id], "busy")
        try expectEqual(state.undelivered.first?.deliveryError, "busy")
        state.markReported([second.id])
        try expect(state.undelivered.isEmpty)
        try expectEqual(state.current(groupID: group, workerMemberID: worker)?.status, .reported)

        var asking = SessionGroupOrchestration()
        let open = assignment(now, "질문하는 작업")
        asking.begin(open)
        try expect(asking.needsWatching)
        let question = GroupWorkerQuestion(id: "q1", text: "어느 환경을\n쓸까요?", options: ["개발", "운영"])
        try expect(asking.noteQuestion(open.id, question))
        try expect(!asking.noteQuestion(open.id, question), "The same question is reported once")
        try expectEqual(asking.undeliveredQuestions.map(\.id), [open.id])
        let asked = SessionGroupOrchestration.report(for: [], questions: asking.undeliveredQuestions, titles: [worker: "작업자"])
        try expect(!asked.contains("\n") && asked.contains("어느 환경을 쓸까요?") && asked.contains("1) 개발 2) 운영") && asked.contains("answer_group_question"))
        try expect(!asked.contains("assign_group_task"), "A question alone does not ask for the next task")
        asking.markQuestionsReported([open.id])
        try expect(asking.undeliveredQuestions.isEmpty)
        try expect(asking.noteQuestion(open.id, GroupWorkerQuestion(id: "q2", text: "다음 질문?", options: ["예", "아니오"])),
                   "A different question is reported again")
        asking.clearQuestion(open.id)
        try expectNil(asking.assignments[0].question)

        var crowded = SessionGroupOrchestration()
        for index in 0..<(SessionGroupOrchestration.limit + 5) {
            crowded.begin(SessionGroupAssignment(groupID: group, workerMemberID: UUID(), parentMemberID: parent,
                workerSessionID: "process:\(index):a", parentSessionID: "process:2:b", task: "작업"))
        }
        try expectEqual(crowded.assignments.count, SessionGroupOrchestration.limit + 5, "Pending tasks are never dropped for space")
    }

    @MainActor func testGroupTaskTurnsOnWorkerAutomaticApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-assign-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        100551 1 fixture6 100551 100551 Wed Oct 28 12:00:00 2026 /fixture/claude
        100552 1 fixture7 100552 100552 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        var sessions = records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/tmp/group-fixture", terminal: .iterm) }
        for index in sessions.indices { sessions[index].phase = .idle }
        let ids = [records[0].pid: UUID().uuidString, records[1].pid: UUID().uuidString]
        let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { records in
            records.compactMap { record in ids[record.pid].map { .init(processID: record.key, kind: "interactive", activity: .init(providerID: $0, status: "idle", changedAt: Date())) } }
        }
        let writer = GroupTerminalWriter()
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: writer.screen($0.tty)) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { target, _, _, input in writer.send(target, input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: registry, processReader: { records }, screenAdapters: [.iterm: adapter])
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        let observed = try await engine.sessionGroupSessions()
        let leader = try unwrapGroup(observed.first { $0.id == records[0].key })
        let worker = try unwrapGroup(observed.first { $0.id == records[1].key })
        let leaderMember = leader.member, workerMember = worker.member
        let group = SessionGroup(name: "자동 승인", members: [leaderMember, workerMember], leaderMemberID: leaderMember.id)
        try SessionGroupStore(directory: directory).save([group])
        func automatic() -> Bool? { engine.snapshot.sessions.first { $0.id == worker.id }?.automatic }
        try expectEqual(automatic(), false)
        func assign(_ task: String) async throws -> JSONObject {
            try await engine.mcpAction(["owner": UUID().uuidString, "tool": "assign_group_task", "sessionID": leader.id,
                                        "groupID": group.id.uuidString, "memberID": workerMember.id.uuidString, "task": task])
        }

        // A task that never reaches the terminal restores the user's previous choice.
        writer.reject(10)
        do { _ = try await assign("전달 실패"); throw AppError.message("A rejected screen accepted the task") }
        catch let error as RemoteHTTPError { try expectEqual(error.diagnostics?["delivery"], "not_started") }
        try expectEqual(automatic(), false, "An undelivered task must not leave automatic approval on")
        try expect(try engine.sessionGroupAssignments().allSatisfy { $0.status != .working })

        writer.reject(0)
        let result = try await assign("빌드를 확인하세요")
        try expectEqual(result["automaticApproval"] as? String, "enabled")
        try expectEqual(automatic(), true, "A group worker must not stop at a permission prompt")
        try expect((result["message"] as? String)?.contains("자동 승인을 켰습니다") == true)
        try expectEqual(writer.writes.count, 1)
        try expect(writer.writes[0].contains("빌드를 확인하세요"))
        let again = try await assign("다시 확인하세요")
        try expectEqual(again["automaticApproval"] as? String, "already")

        try engine.setPaused(true); defer { try? engine.setPaused(false) }
        let paused = try await assign("일시정지 중 작업")
        try expectEqual(paused["automaticApproval"] as? String, "paused", "The global pause stays the user's decision")
        try expect(engine.snapshot.paused)
    }

    @MainActor func testGroupWorkerChoiceQuestionReachesParentAndIsAnswered() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-question-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        100561 1 fixture8 100561 100561 Wed Oct 28 12:00:00 2026 /fixture/claude
        100562 1 fixture9 100562 100562 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        var sessions = records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/tmp/group-fixture", terminal: .iterm) }
        for index in sessions.indices { sessions[index].phase = .idle; sessions[index].channel = .itermScreen }
        let ids = [records[0].pid: UUID().uuidString, records[1].pid: UUID().uuidString]
        let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { records in
            records.compactMap { record in ids[record.pid].map { .init(processID: record.key, kind: "interactive", activity: .init(providerID: $0, status: "idle", changedAt: Date())) } }
        }
        let writer = GroupTerminalWriter()
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: writer.screen($0.tty)) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { target, _, _, input in writer.send(target, input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: registry, processReader: { records }, screenAdapters: [.iterm: adapter])
        defer { engine.stop() }
        engine.groupQuestionGrace = 0.2
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        let observed = try await engine.sessionGroupSessions()
        let leader = try unwrapGroup(observed.first { $0.id == records[0].key })
        let worker = try unwrapGroup(observed.first { $0.id == records[1].key })
        let leaderMember = leader.member, workerMember = worker.member
        let group = SessionGroup(name: "질문 전달", members: [leaderMember, workerMember], leaderMemberID: leaderMember.id)
        try SessionGroupStore(directory: directory).save([group])
        func call(_ tool: String, from caller: String, _ extra: JSONObject = [:]) async throws -> JSONObject {
            var params: JSONObject = ["owner": UUID().uuidString, "tool": tool, "sessionID": caller,
                                      "groupID": group.id.uuidString, "memberID": workerMember.id.uuidString]
            extra.forEach { params[$0.key] = $0.value }
            return try await engine.mcpAction(params)
        }
        func question() async throws -> JSONObject? {
            let status = try await call("get_group_status", from: leader.id)
            let members = (status["groups"] as? [JSONObject])?.first?["members"] as? [JSONObject]
            return (members?.first { $0["id"] as? String == workerMember.id.uuidString }?["task"] as? JSONObject)?["question"] as? JSONObject
        }
        func phase(_ id: String) -> SessionPhase? { engine.snapshot.sessions.first { $0.id == id }?.phase }
        _ = try await call("assign_group_task", from: leader.id, ["task": "환경을 정해 배포 준비"])
        let workerTTY = "/dev/" + records[1].tty, leaderTTY = "/dev/" + records[0].tty
        try expectEqual(writer.writes(to: workerTTY).count, 1)

        writer.show("결과 정리\n\n❯ Try “다음 작업”\n? for shortcuts", on: leaderTTY)
        try expect(try await waitForGroup(10) { await engine.refreshScreens(); return phase(leader.id) == .idle }, "The parent must be idle to receive reports")

        // A permission prompt is never sent to the parent, even after the grace period.
        writer.show("Do you want to proceed?\n$ echo fixture\n❯ 1. Yes\n  2. No\nEsc to cancel", on: workerTTY)
        try expect(try await waitForGroup(10) {
            await engine.refreshScreens()
            return phase(worker.id) == .approval
        }, "The worker must be waiting on the permission prompt")
        try await Task.sleep(for: .seconds(4.5))
        try expect(writer.writes(to: leaderTTY).isEmpty, "A permission prompt must not reach the parent")
        try expect(try await question() == nil)

        writer.show("어느 환경에 배포할까요?\n\n❯ 1. 개발\n  2. 운영\n  3. 둘 다\n\nEnter to select", on: workerTTY)
        let reported = try await waitForGroup(20) {
            await engine.refreshScreens()
            return writer.writes(to: leaderTTY).contains { $0.contains("[AutoApprove 그룹 질문") }
        }
        try expect(reported, "The worker's choice question must reach the parent's terminal")
        let typed = try unwrapGroup(writer.writes(to: leaderTTY).first { $0.contains("[AutoApprove 그룹 질문") })
        try expect(typed.contains("어느 환경에 배포할까요?") && typed.contains("2) 운영"))
        try expectEqual(try await question()?["options"] as? [String], ["개발", "운영", "둘 다"])

        for (caller, choice, status) in [(worker.id, 2, 403), (leader.id, 4, 400)] {
            do { _ = try await call("answer_group_question", from: caller, ["choice": choice]); throw AppError.message("Invalid answer accepted") }
            catch let error as RemoteHTTPError { try expectEqual(error.status, status) }
        }
        let before = writer.writes(to: workerTTY).count
        let answered = try await call("answer_group_question", from: leader.id, ["choice": 2])
        try expectEqual(answered["answer"] as? String, "운영")
        try expectEqual(writer.writes(to: workerTTY).count, before + 1)
        try expect(try await question() == nil)
        do { _ = try await call("answer_group_question", from: leader.id, ["choice": 2]); throw AppError.message("An answered question accepted a second answer") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
    }
}
