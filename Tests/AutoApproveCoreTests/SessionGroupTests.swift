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
}
