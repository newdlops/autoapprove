import Foundation
import AutoApproveCore

private final class CodexGroupScreen: @unchecked Sendable {
    let lock = NSLock(), id = UUID().uuidString.lowercased()
    private var value = "Codex\n› Ask Codex to do anything\n  ? for shortcuts"
    private var writes: [String] = []
    private var rollout: String?
    init(_ initial: String? = nil) { if let initial { value = initial } }
    func setRollout(_ id: String) { lock.lock(); defer { lock.unlock() }; rollout = id }
    func location() -> CodexThreadLocation? {
        lock.lock(); defer { lock.unlock() }
        return rollout.map { .init(threadID: $0, database: "/fixture/home/thread_history_1.sqlite") }
    }
    var screen: String { lock.lock(); defer { lock.unlock() }; return value }
    var inputs: [String] { lock.lock(); defer { lock.unlock() }; return writes }
    func send(_ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }; writes.append(input.bytes)
        if input.bytes.contains("/status") {
            value = ">_ OpenAI Codex (v0.169.0)\nModel: fixture\nDirectory: /project\nPermissions: Read Only\nAgents.md: none\nSession: \(id)\n› Ask Codex to do anything\n  ? for shortcuts"
        }
        return .sent
    }
}

extension ApprovalTests {
    @MainActor func testCodexGroupDiscoversIdleTerminalFromStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-screen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("100591 1 fixture40 100591 100591 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .iterm)
        session.phase = .idle; session.channel = .itermScreen
        let screen = CodexGroupScreen()
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter],
            codexGroupReader: { _ in screen.location() }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
        let unresolved = SessionGroupLiveSession(session: session, conversationID: nil, providerHome: "/fixture/home")
        try SessionGroupStore(directory: directory).save([SessionGroup(name: "fixture", members: [unresolved.member])])
        _ = try await engine.sessionGroupSessions()
        var found: String?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            found = try await engine.sessionGroupSessions().first?.conversationID
            if found != nil { break }
        }
        if found == nil {
            let group = try SessionGroupStore(directory: directory).load()[0]
            try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: group.members[0].id)
            throw AppError.message("Automatic discovery did not run; inputs=\(screen.inputs.count), phase=\(engine.snapshot.sessions.first?.phase.rawValue ?? "missing")")
        }
        try expectEqual(found, screen.id)
        try expectEqual(screen.inputs.filter { $0.contains("/status") }.count, 1)
        try expectEqual(try SessionGroupStore(directory: directory).load()[0].members[0].conversationID, screen.id)
        let new = UUID().uuidString.lowercased()
        screen.setRollout(new)
        try expectEqual(try await engine.sessionGroupSessions().first?.conversationID, new, "Fresh process evidence must win over cached status")
        try expectEqual(try SessionGroupStore(directory: directory).load()[0].members[0].conversationID, new)
    }

    @MainActor func testCodexGroupDiscoveryPreservesBusyScreensAndDrafts() async throws {
        for text in ["Codex\n• Working (esc to interrupt)\n› \n  ? for shortcuts", "Codex\n› my unfinished draft\n  ? for shortcuts"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-busy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100592 1 fixture41 100592 100592 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .iterm)
            let screen = CodexGroupScreen(text)
            let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter],
                codexGroupReader: { _ in nil }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
            defer { engine.stop() }
            engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
            _ = try await engine.sessionGroupSessions()
            try await Task.sleep(for: .milliseconds(500))
            try expectEqual(screen.inputs.count, 0)
            try expectEqual(screen.screen, text)
        }
    }
    func testCodexGroupMCPMetadata() throws {
        let id = UUID().uuidString, other = UUID().uuidString
        let message: JSONObject = ["params": ["arguments": ["conversationID": other], "_meta": [
            "threadId": id, "x-codex-turn-metadata": ["thread_id": id.lowercased(), "session_id": id]]]]
        try expectEqual(try CodexGroupIdentity.conversationID(in: message), id.lowercased())
        try expectNil(try CodexGroupIdentity.conversationID(in: ["params": ["arguments": ["_meta": ["threadId": id]]]]))
        for meta: JSONObject in [["threadId": "bad"], ["threadId": id, "x-codex-turn-metadata": ["thread_id": other]]] {
            do { _ = try CodexGroupIdentity.conversationID(in: ["params": ["_meta": meta]]); throw AppError.message("Accepted ambiguous metadata") }
            catch let error as AppError { try expect(error.localizedDescription.contains("서로 다릅니다")) }
        }
    }

    func testCodexGroupRefreshIsolatedFromClaude() throws {
        let old = UUID().uuidString, new = UUID().uuidString
        let session = AgentSession(id: "process:123:start", agent: .codex, pid: 123, started: "start", tty: "/dev/ttys001", cwd: "/project", terminal: .terminal)
        let live = SessionGroupLiveSession(session: session, conversationID: new, providerHome: "/home/codex")
        var member = live.member; member.conversationID = old
        var claude = member; claude.id = UUID(); claude.agent = .claude
        let group = SessionGroup(name: "fixture", members: [member, claude]).settingLeader(member.id)
        let updated = CodexGroupIdentity.refreshed([group], live: [live])[0]
        try expectEqual(updated.members[0].conversationID, new.lowercased())
        try expectEqual(updated.members[1], claude)
        try expectEqual(updated.leaderMemberID, member.id)
        var restarted = live; restarted.session.id = "process:456:new-start"; restarted.session.pid = 456
        try expectEqual(CodexGroupIdentity.refreshed([updated], live: [restarted])[0].members[0].runtimeID, restarted.id)
        try expectEqual(CodexGroupIdentity.refreshed([group], live: [live, restarted]), [group])
        var foreign = live; foreign.providerHome = "/home/other"
        try expectEqual(CodexGroupIdentity.refreshed([group], live: [foreign]), [group])
        var unknown = live; unknown.conversationID = nil
        try expectEqual(CodexGroupIdentity.refreshed([group], live: [unknown]), [group])
    }

    @MainActor func testCodexSharedMCPFindsSavedGroupWithoutTerminalGuess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-metadata-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString, home = "/fixture/codex"
        let member = SessionGroupMember(agent: .codex, title: "fixture", cwd: "/project", conversationID: id, providerHome: home)
        try SessionGroupStore(directory: directory).save([SessionGroup(name: "owned", members: [member])])
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        var params: JSONObject = ["owner": UUID().uuidString, "tool": "get_session_groups", "agentKind": "codex",
            "sessionID": "shared-daemon", "conversationID": id, "codexCallerConversationID": id, "codexCallerHome": home]
        let result = try await engine.mcpAction(params)
        let groups = result["groups"] as? [JSONObject]
        try expectEqual(groups?.count, 1)
        let peer = (groups?.first?["members"] as? [JSONObject])?.first
        try expectEqual(peer?["isCaller"] as? Bool, true)
        try expectEqual(peer?["connected"] as? Bool, false, "MCP identity must not invent a terminal connection")
        params["codexCallerHome"] = "/fixture/other"
        try expectEqual((try await engine.mcpAction(params)["groups"] as? [JSONObject])?.count, 0)
    }

    @MainActor func testCodexMetadataParentCanDirectConfirmedWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-parent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentID = UUID().uuidString, workerID = UUID().uuidString, home = "/fixture/home"
        let parent = SessionGroupMember(agent: .codex, title: "parent", cwd: "/project", conversationID: parentID, providerHome: home)
        let record = ProcessDiscovery.parse("100593 1 fixture42 100593 100593 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .iterm)
        let screen = CodexGroupScreen()
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter],
            codexGroupReader: { _ in .init(threadID: workerID, database: home + "/thread_history_1.sqlite") })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
        let worker = SessionGroupLiveSession(session: session, conversationID: workerID, providerHome: home).member
        let group = SessionGroup(name: "fixture", members: [parent, worker], leaderMemberID: parent.id)
        try SessionGroupStore(directory: directory).save([group])
        let params: JSONObject = ["owner": UUID().uuidString, "tool": "assign_group_task", "agentKind": "codex",
            "sessionID": "shared-daemon", "conversationID": parentID, "codexCallerConversationID": parentID, "codexCallerHome": home,
            "groupID": group.id.uuidString, "memberID": worker.id.uuidString, "task": "Inspect the fixture"]
        _ = try await engine.mcpAction(params)
        try expectEqual(screen.inputs.count, 1)
        try expect(screen.inputs[0].contains("Inspect the fixture"))
        let task = try engine.sessionGroupAssignments().first
        try expectEqual(task?.workerSessionID, session.id)
        try expect(task?.parentSessionID.hasPrefix("codex-mcp:") == true, "Never route reports to an unverified parent terminal")
    }

    @MainActor func testCodexGroupRejectsStaleApprovalBinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-binding-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("100531 1 fixture4 100531 100531 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .terminal)
        session.codexApprovalBinding = .init(threadID: UUID().uuidString, title: "old")
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, codexGroupReader: { _ in nil })
        defer { engine.stop() }; engine.updateDiscovery([session], records: [record])
        try expectNil(try await engine.sessionGroupSessions().first?.conversationID)
    }
}
