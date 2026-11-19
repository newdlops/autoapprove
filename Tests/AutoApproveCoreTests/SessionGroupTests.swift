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

/// Terminal typing without focus, and the status Claude registers for itself.
private final class GroupLineTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(tty: String, text: String)] = []
    private var statuses: [Int32: String] = [:]
    /// When set, Claude becomes busy only after a separate Enter, as it does for a long pasted line.
    var needsEnter = true
    /// When set, Claude never becomes busy, as when the line was not accepted.
    var ignoresInput = false
    var typed: [String] { lock.lock(); defer { lock.unlock() }; return lines.map(\.text) }
    func status(_ pid: Int32) -> String { lock.lock(); defer { lock.unlock() }; return statuses[pid] ?? "idle" }
    func setStatus(_ pid: Int32, _ value: String) { lock.lock(); defer { lock.unlock() }; statuses[pid] = value }
    func type(_ target: ScreenTarget, _ text: String, pid: Int32) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        lines.append((target.tty, text))
        if !ignoresInput, text.isEmpty || !needsEnter { statuses[pid] = "busy" }
        return .sent
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
    @MainActor func testGroupClaudeMailboxCustomStatus() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aa-claude-mailbox-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        104401 1 fixture401 104401 104401 Wed Oct 28 12:00:00 2026 /fixture/claude
        104402 1 fixture402 104402 104402 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        let sessions = records.map { AgentSession(id: $0.key, agent: .claude, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/fixture", terminal: .iterm) }
        let ids = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, UUID().uuidString) })
        let writer = GroupTerminalWriter(), terminal = GroupLineTerminal()
        terminal.needsEnter = false
        let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { rows in
            rows.map { .init(processID: $0.key, kind: "interactive", sessionID: ids[$0.pid], status: terminal.status($0.pid)) }
        }
        let rule = String(repeating: "─", count: 30)
        let custom = "answer\n\(rule)\n❯ \n\(rule)\nuser@host project (main) | Opus 4.7 | ctx 32% | 5h 12% (resets 23:00)"
        for session in sessions { writer.show(custom, on: session.tty) }
        var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: writer.screen($0.tty)) }) },
            approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { _,_,_,_ in .missingTarget })
        adapter.typeLine = { target, text in terminal.type(target, text, pid: target.sourcePID ?? 0) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: registry, processReader: { records }, screenAdapters: [.iterm: adapter], isolateByDefault: true)
        defer { engine.stop() }
        engine.groupMailboxPollInterval = 0.05; engine.groupMailboxReminderInterval = 60
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        let live = try await engine.sessionGroupSessions()
        let members = try sessions.map { session in try unwrapGroup(live.first { $0.id == session.id }).member }
        let group = SessionGroup(name: "Claude inbox", members: members, leaderMemberID: members[0].id)
        try SessionGroupStore(directory: directory).save([group])
        let box = try SessionGroupMailbox(directory: directory)
        func send(_ text: String) async throws -> UUID {
            let receipt = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "ask_group_question", "sessionID": sessions[0].id,
                "groupID": group.id.uuidString, "memberID": members[1].id.uuidString, "text": text])
            try expectEqual(receipt["accepted"] as? Bool, true)
            return try unwrapGroup((receipt["messageID"] as? String).flatMap(UUID.init(uuidString:)))
        }
        func ack(_ id: UUID) async throws {
            _ = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "ack_group_messages", "sessionID": sessions[1].id,
                "groupID": group.id.uuidString, "messageIDs": [id.uuidString]])
        }
        terminal.setStatus(records[1].pid, "busy")
        let waiting = try await send("busy then idle")
        try expect(try await waitForGroup(5) { (try? box.message(waiting)?.lastResult) == "not_started" })
        try expect(terminal.typed.isEmpty); try expectEqual(try box.pendingCount, 1)
        terminal.setStatus(records[1].pid, "idle")
        try box.noteAttempt(waiting, result: "not_started", retryAt: Date().addingTimeInterval(45))
        _ = engine.handleHook(["hook_event_name": "Notification", "notification_type": "idle_prompt",
            "requestID": UUID().uuidString, "session_id": ids[records[1].pid]!, "agentPID": records[1].pid,
            "agentStarted": records[1].started])
        try expect(try await waitForGroup(5) { (try? box.message(waiting)?.lastResult) == "submitted" })
        try expectEqual(terminal.typed.count, 1)
        try expect(terminal.typed[0].contains("[AutoApprove 그룹 수신함]"))
        try expectEqual(try box.pendingCount, 1, "Terminal submission is not an ACK")
        try await ack(waiting)
        // A subsequent draft, continuation, question or approval must remain untouched.
        for (index, screen) in [custom.replacingOccurrences(of: "❯ ", with: "❯ user draft"),
                               custom.replacingOccurrences(of: "❯ ", with: "❯ \ncontinued draft"),
                               "Choose environment\n❯ 1. Development\n  2. Production\nEnter to select",
                               "Do you want to proceed?\n$ echo fixture\n❯ 1. Yes\n  2. No\nEsc to cancel"].enumerated() {
            terminal.setStatus(records[1].pid, "idle"); writer.show(screen, on: sessions[1].tty)
            await engine.refreshScreens()
            let held = try await send("held \(index)")
            try expect(try await waitForGroup(5) { (try? box.message(held)?.lastResult) == "not_started" })
            try expectEqual(terminal.typed.count, 1); try expectNil(try box.message(held)?.acknowledgedAt)
            try await ack(held)
        }
        try expect(try engine.sessionGroupAssignments().isEmpty)
        try expect(engine.snapshot.sessions.allSatisfy { !$0.automatic })
        try expect(engine.networkIsolated); try expectEqual(try box.pendingCount, 0)
    }

    func testSessionGroupTerminalStatusRequiresFreshCard() throws {
        let old = UUID().uuidString.lowercased(), next = UUID().uuidString.lowercased()
        func card(_ id: String) -> String {
            ">_ OpenAI Codex (v0.167.1)\nModel: fixture\nDirectory: /tmp/project\nPermissions: Read Only\nAgents.md: none\nSession: " + id + "\n› Ask anything"
        }
        try expectNil(SessionGroupTerminalStatus.freshConversationID(before: card(old), after: card(old) + "\n› /status", agent: .codex))
        try expectEqual(SessionGroupTerminalStatus.freshConversationID(before: card(old), after: card(old) + "\n" + card(next), agent: .codex), next)
        try expectNil(SessionGroupTerminalStatus.freshConversationID(before: "", after: "Session: " + next, agent: .codex))
        let claude = "Version: 2.1.0\nSession ID: " + next
        try expectEqual(SessionGroupTerminalStatus.freshConversationID(before: "", after: claude, agent: .claude), next)
        try expectNil(SessionGroupTerminalStatus.freshConversationID(before: claude, after: claude, agent: .claude))
    }
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

    func testSessionGroupRebindingPreservesHierarchy() throws {
        let session = AgentSession(id: "new-process", agent: .codex, pid: 123, started: "start", tty: "/dev/fixture", cwd: "/project", terminal: .terminal)
        let live = SessionGroupLiveSession(session: session, conversationID: UUID().uuidString, providerHome: "/fixture/home")
        let root = live.member, parent = live.member
        var child = live.member; child.parentMemberID = parent.id; child.runtimeID = "old-process"
        var group = SessionGroup(name: "tree", members: [root, parent, child], leaderMemberID: root.id)
        group.members[2] = child.updatingConnection(from: live)
        try expectEqual(group.leaderMemberID, root.id)
        try expectEqual(group.parentID(of: child.id), parent.id)
        try expectEqual(group.members[2].runtimeID, live.id)
        try expectEqual(group.treeOrder.map(\.depth), [0, 1, 2])
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
        try expectEqual(SessionGroupMatching.connection(member, in: [changed])?.id, session.id)
        changed.conversationID = nil
        try expectEqual(SessionGroupMatching.connection(member, in: [changed])?.id, session.id)
        try expectNil(SessionGroupMatching.match(member, in: [changed]))
        try expectNil(SessionGroupMatching.connection(member, in: [changed, changed]))
        changed = live; changed.providerHome = "/tmp/other-home"
        try expectNil(SessionGroupMatching.match(member, in: [changed]))
        try expectNil(SessionGroupMatching.connection(member, in: [changed]))
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
                                        processReader: { [record] }, codexQueue: queue,
                                        codexGroupReader: { _ in .init(threadID: thread, database: "/tmp/group-home/thread_history_1.sqlite") })
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

        let peers = try valid.addingLeader(c.id).validated()
        try expectEqual(peers.leaderMemberIDs, [a.id, c.id])
        try expectEqual(peers.treeOrder.map(\.depth), [0, 1, 0, 1])
        for leader in peers.leaderMemberIDs {
            try expect(peers.canDirect(leader, worker: b.id) && peers.canDirect(leader, worker: d.id))
            try expect(!peers.canDirect(leader, worker: a.id) && !peers.canDirect(leader, worker: c.id))
        }
        try expect(!peers.canDirect(b.id, worker: d.id))
        try expectEqual(try JSONDecoder().decode(SessionGroup.self, from: JSONEncoder().encode(peers)).validated(), peers)
        let remaining = try peers.removingLeader(a.id).validated()
        try expectEqual(remaining.leaderMemberIDs, [c.id])
        try expectEqual(remaining.parentID(of: a.id), c.id)
        try expectEqual(try peers.removing(c.id).validated().parentID(of: d.id), a.id)
        try expect(remaining.removingLeader(c.id).members.allSatisfy { $0.parentMemberID == nil })
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
        old.removeValue(forKey: "leaderMemberIDs")
        try expectEqual(try JSONDecoder().decode(SessionGroup.self, from: JSONSerialization.data(withJSONObject: old)), valid)

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
        try expectEqual(SessionGroupOrchestration.taskMessage(first), "1. 빌드 2. 테스트",
                        "The worker receives the instruction alone on one line, as if the user had typed it")
        try expectEqual(SessionGroupOrchestration.commandPrefix("  !rm -rf build"), "!")
        try expect(SessionGroupOrchestration.commandPrefix("/clear") == "/" && SessionGroupOrchestration.commandPrefix("빌드하세요") == nil)

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

        // A task is pending until it has been typed; one that never was is dropped when the app starts.
        var typing = SessionGroupOrchestration()
        let typed = assignment(now, "입력된 작업"), lost = SessionGroupAssignment(groupID: group, workerMemberID: UUID(), parentMemberID: parent,
            workerSessionID: "process:9:z", parentSessionID: "process:2:b", task: "입력되지 않은 작업", sentAt: now)
        typing.begin(typed); typing.begin(lost)
        try expect(!typing.assignments[0].isDelivered)
        typing.markDelivered(typed.id)
        try expectEqual(typing.removeUndelivered(), 1)
        try expectEqual(typing.assignments.map(\.id), [typed.id], "Only the task that never reached its worker is removed")
        try expect(typing.assignments[0].isDelivered)

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
        engine.refreshSessionGroupBadges()
        func badge(_ id: String) -> SessionGroupBadge? { engine.snapshot.sessions.first { $0.id == id }?.sessionGroup }
        try expect(try await waitForGroup(5) { badge(leader.id) != nil && badge(worker.id) != nil }, "Session list rows must show group roles")
        try expectEqual(badge(leader.id)?.role, .leader); try expectEqual(badge(leader.id)?.childCount, 1)
        try expectEqual(badge(worker.id)?.role, .member); try expectEqual(badge(worker.id)?.task, .working)
        try expectEqual(badge(worker.id)?.parentTitle, leaderMember.title)

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
        engine.groupQuestionGrace = 0.2; engine.groupDeliveryInterval = 0.2
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        let observed = try await engine.sessionGroupSessions()
        let leader = try unwrapGroup(observed.first { $0.id == records[0].key })
        let worker = try unwrapGroup(observed.first { $0.id == records[1].key })
        let leaderMember = leader.member, workerMember = worker.member
        let group = SessionGroup(name: "질문 전달", members: [leaderMember, workerMember], leaderMemberID: leaderMember.id)
        try SessionGroupStore(directory: directory).save([group])
        let mailbox = try SessionGroupMailbox(directory: directory)
        func messages() -> [SessionGroupMessage] { (try? mailbox.list(groupID: group.id, memberID: leaderMember.id, includeAcknowledged: true)) ?? [] }
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

        // Any other permission prompt is delegated: the parent's choice counts as the user's approval.
        writer.show("Do you want to proceed?\n$ echo fixture\n❯ 1. Yes\n  2. No\nEsc to cancel", on: workerTTY)
        let delegated = try await waitForGroup(20) {
            await engine.refreshScreens()
            return messages().contains { $0.text.contains("[AutoApprove 그룹 승인 요청") }
        }
        try expect(delegated, "The worker's permission prompt must reach the parent")
        let permissionMessage = try unwrapGroup(messages().first { $0.text.contains("[AutoApprove 그룹 승인 요청") })
        let request = permissionMessage.text
        _ = try await call("ack_group_messages", from: leader.id, ["messageIDs": [permissionMessage.id.uuidString]])
        try expect(request.contains("echo fixture") && request.contains("1) Yes") && request.contains("사용자 승인으로 처리"))
        let beforeApproval = writer.writes(to: workerTTY).count
        let approved = try await call("answer_group_question", from: leader.id, ["choice": 1])
        try expectEqual(approved["permission"] as? Bool, true)
        try expectEqual(writer.writes(to: workerTTY).count, beforeApproval + 1)
        try await Task.sleep(for: .seconds(1.2))
        try expectEqual(messages().filter { $0.text.contains("[AutoApprove 그룹 승인 요청") }.count, 1, "An answered request is not reported again")

        writer.show("어느 환경에 배포할까요?\n\n❯ 1. 개발\n  2. 운영\n  3. 둘 다\n\nEnter to select", on: workerTTY)
        let reported = try await waitForGroup(20) {
            await engine.refreshScreens()
            return messages().contains { $0.text.contains("[AutoApprove 그룹 질문") }
        }
        try expect(reported, "The worker's choice question must reach the parent's durable inbox")
        let choiceMessage = try unwrapGroup(messages().first { $0.text.contains("[AutoApprove 그룹 질문") })
        let typed = choiceMessage.text
        _ = try await call("ack_group_messages", from: leader.id, ["messageIDs": [choiceMessage.id.uuidString]])
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

        // A system change that AutoApprove never approves in the app is not delegated to the parent.
        // The command is assembled so that this source text is not itself a system change request.
        let persistence = "launch" + "ctl bootstrap gui/501 /fixture/test.plist"
        writer.show("Do you want to proceed?\n$ \(persistence)\n❯ 1. Yes\n  2. No\nEsc to cancel", on: workerTTY)
        try expect(try await waitForGroup(10) {
            await engine.refreshScreens()
            return phase(worker.id) == .approval
        }, "The worker must be waiting on the permission prompt")
        try await Task.sleep(for: .seconds(1.2))
        try expectEqual(messages().filter { $0.text.contains("[AutoApprove 그룹 승인 요청") }.count, 1, "A system change must stay with the user")
    }

    func testSessionGroupBadgesForSessionLists() throws {
        func live(_ pid: Int32, _ agent: AgentKind = .claude) -> SessionGroupLiveSession {
            let session = AgentSession(id: "process:\(pid):start", agent: agent, pid: pid, started: "start", tty: "/dev/ttys\(pid)", cwd: "/tmp/badge", terminal: .terminal)
            return SessionGroupLiveSession(session: session, conversationID: UUID().uuidString, providerHome: "/tmp/home")
        }
        let sessions = [live(1), live(2), live(3), live(4)]
        let members = sessions.map(\.member)
        var tree = SessionGroup(name: "배포", members: Array(members[0..<3]), leaderMemberID: members[0].id)
        tree = tree.settingParent(members[1].id, for: members[2].id)
        let flat = SessionGroup(name: "가나다 평면", members: [members[2], members[3]])
        let other = SessionGroup(name: "하위 트리", members: [members[1], members[2]], leaderMemberID: members[1].id)
        let badges = SessionGroupBadge.badges(groups: [flat, tree, other], live: sessions)
        try expectEqual(badges[sessions[0].id]?.role, .leader)
        try expectEqual(badges[sessions[0].id]?.childCount, 1)
        try expectEqual(badges[sessions[2].id]?.role, .member, "A member of a tree wins over a group without a leader")
        try expectEqual(badges[sessions[2].id]?.depth, 2)
        try expectEqual(badges[sessions[2].id]?.parentTitle, members[1].title)
        try expectEqual(badges[sessions[2].id]?.otherGroupCount, 2)
        try expectEqual(badges[sessions[1].id]?.role, .leader, "Leading a group wins over working in another")
        try expectEqual(badges[sessions[1].id]?.groupName, "하위 트리")
        try expectEqual(badges[sessions[3].id]?.role, .unranked)
        try expect(SessionGroupBadge.badges(groups: [tree], live: [sessions[3]])[sessions[3].id] == nil, "Sessions outside every group have no badge")
        var refreshing = sessions
        refreshing[1].conversationID = nil
        refreshing[2].conversationID = UUID().uuidString
        try expectEqual(SessionGroupBadge.badges(groups: [flat, tree, other], live: refreshing), badges,
                        "Refreshing conversation identities must preserve the original processes' group rows")
        try expect(SessionGroupMatching.match(members[1], in: refreshing) == nil, "Unknown identity still prevents task delivery")
        try expect(SessionGroupMatching.match(members[2], in: refreshing) == nil, "Changed identity still prevents task delivery")
        refreshing[1].session.id = "process:2:restarted"
        try expect(SessionGroupBadge.badges(groups: [tree], live: refreshing)[refreshing[1].id] == nil,
                      "A replacement process with no confirmed identity must not inherit membership")
    }

    func testSessionListTreeNestsGroupsAndKeepsOrder() throws {
        let tree = UUID(), flat = UUID()
        let leader = UUID(), lead = UUID(), worker = UUID(), orphanParent = UUID()
        func session(_ id: String, _ badge: SessionGroupBadge?) -> AgentSession {
            var value = AgentSession(id: id, agent: .claude, pid: 1, started: id, tty: "/dev/" + id, cwd: "/tmp/tree", terminal: .terminal)
            value.sessionGroup = badge; return value
        }
        let rows = [
            session("plain-1", nil),
            session("worker", .init(groupID: tree, groupName: "배포", memberID: worker, role: .member, parentMemberID: lead, task: .approval)),
            session("flat-1", .init(groupID: flat, groupName: "문서", memberID: UUID(), role: .unranked)),
            session("leader", .init(groupID: tree, groupName: "배포", memberID: leader, role: .leader)),
            session("lead", .init(groupID: tree, groupName: "배포", memberID: lead, role: .member, parentMemberID: leader)),
            session("orphan", .init(groupID: tree, groupName: "배포", memberID: UUID(), role: .member, parentMemberID: orphanParent)),
            session("plain-2", nil),
            session("flat-2", .init(groupID: flat, groupName: "문서", memberID: UUID(), role: .unranked))]
        let built = SessionListTree.build(rows)
        try expectEqual(built.ungrouped.map(\.id), ["plain-1", "plain-2"], "Ungrouped sessions keep their order")
        try expectEqual(built.groups.map(\.name), ["배포", "문서"], "Groups follow their first member's position")
        let deploy = built.groups[0]
        try expectEqual(deploy.roots.map(\.id), ["leader", "orphan"], "The leader comes first; a member whose parent is not listed stays visible")
        try expectEqual(deploy.roots[0].children.map(\.id), ["lead"])
        try expectEqual(deploy.roots[0].children[0].children.map(\.id), ["worker"])
        try expectEqual(deploy.sessionCount, 4); try expectEqual(deploy.attentionCount, 1)
        try expect(deploy.hasLeader && !built.groups[1].hasLeader)
        try expectEqual(built.groups[1].roots.map(\.id), ["flat-1", "flat-2"])

        // A parent loop must not hide either member.
        let a = UUID(), b = UUID()
        let loop = SessionListTree.build([
            session("a", .init(groupID: tree, groupName: "고리", memberID: a, role: .member, parentMemberID: b)),
            session("b", .init(groupID: tree, groupName: "고리", memberID: b, role: .member, parentMemberID: a))])
        func count(_ nodes: [SessionListTree.Node]) -> Int { nodes.reduce(0) { $0 + 1 + count($1.children) } }
        try expectEqual(count(loop.groups[0].roots), 2)
    }

    @MainActor func testGroupTaskReachesBackgroundClaudeWithoutFocus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-line-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        100801 1 ttys081 100801 100801 Wed Oct 28 12:00:00 2026 /fixture/claude
        100802 1 ttys082 100802 100802 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        var sessions = records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/tmp/group-fixture", terminal: .terminal) }
        for index in sessions.indices { sessions[index].channel = .terminalScreen }
        let terminal = GroupLineTerminal()
        let ids = [records[0].pid: UUID().uuidString, records[1].pid: UUID().uuidString]
        // The screen reading stays "unknown" here, as it does when Claude shows a status line; Claude's own status decides.
        let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { rows in
            rows.compactMap { row in ids[row.pid].map { .init(processID: row.key, kind: "interactive", sessionID: $0, status: terminal.status(row.pid)) } }
        }
        var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "상태 줄이 있는 화면") }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, _ in .missingTarget })
        adapter.typeLine = { target, text in terminal.type(target, text, pid: target.sourcePID ?? 0) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: registry, processReader: { records }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.terminal)
        let observed = try await engine.sessionGroupSessions()
        let leader = try unwrapGroup(observed.first { $0.id == records[0].key }), worker = try unwrapGroup(observed.first { $0.id == records[1].key })
        let leaderMember = leader.member, workerMember = worker.member
        let group = SessionGroup(name: "백그라운드 전달", members: [leaderMember, workerMember], leaderMemberID: leaderMember.id)
        try SessionGroupStore(directory: directory).save([group])
        func assign(_ task: String) async throws -> JSONObject {
            try await engine.mcpAction(["owner": UUID().uuidString, "tool": "assign_group_task", "sessionID": leader.id,
                                        "groupID": group.id.uuidString, "memberID": workerMember.id.uuidString, "task": task])
        }
        func working() throws -> [SessionGroupAssignment] { try engine.sessionGroupAssignments().filter { $0.status == .working } }

        // A busy worker is refused before anything is recorded or typed.
        terminal.setStatus(records[1].pid, "busy")
        do { _ = try await assign("바쁠 때 지시"); throw AppError.message("A busy worker accepted a task") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
        try expect(terminal.typed.isEmpty); try expect(try working().isEmpty)

        // A line that Claude never accepts leaves no task behind, so the leader can assign again.
        terminal.setStatus(records[1].pid, "idle"); terminal.ignoresInput = true
        do { _ = try await assign("제출되지 않는 지시"); throw AppError.message("An unsubmitted line was reported as delivered") }
        catch let error as RemoteHTTPError { try expectEqual(error.diagnostics?["delivery"], "unknown") }
        try expect(try working().isEmpty, "A task that was not submitted must not stay working")

        // A long line arrives as a paste: the text is typed, then a separate Enter submits it.
        terminal.ignoresInput = false
        let before = terminal.typed.count
        _ = try await assign("배포 상태를 확인하세요")
        let lines = Array(terminal.typed[before...])
        try expectEqual(lines, ["배포 상태를 확인하세요", ""], "The instruction is typed alone, as the user would type it; the second line is only Enter")
        do { _ = try await assign("!rm -rf build"); throw AppError.message("A shell command line was typed into the worker") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 400) }
        try expectEqual(terminal.typed.count, before + 2, "A command line is refused before anything is typed")
        try expectEqual(try working().count, 1); try expect(try working()[0].isDelivered)
        let status = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "get_group_status", "sessionID": leader.id])
        let members = (status["groups"] as? [JSONObject])?.first?["members"] as? [JSONObject]
        try expectEqual(members?.first { $0["id"] as? String == workerMember.id.uuidString }?["claudeStatus"] as? String, "busy")
    }
}

extension ApprovalTests {
    @MainActor func testCrossAgentMetadataParentAndMissingClaudeStopRecovery() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aa-cross-status-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        104511 1 fixture451 104511 104511 Wed Oct 28 12:00:00 2026 /fixture/claude
        104512 1 fixture452 104512 104512 Wed Oct 28 12:00:00 2026 /fixture/codex
        """)
        var sessions = records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm) }
        for index in sessions.indices { sessions[index].phase = .idle }
        let parentID = UUID().uuidString.lowercased(), workerID = UUID().uuidString.lowercased(), codexID = UUID().uuidString.lowercased()
        let home = "/fixture/home", terminal = GroupLineTerminal(), writer = GroupTerminalWriter()
        var adapter = ScreenHostAdapter(screens: { targets in .init(screens: targets.map { .init(tty: $0.tty, contents: writer.screen($0.tty)) }) },
            approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { target,_,_, input in writer.send(target, input) })
        adapter.typeLine = { target, text in terminal.type(target, text, pid: target.sourcePID ?? 0) }
        writer.show("fixture\n❯ \n ? for shortcuts", on: sessions[0].tty)
        writer.show("fixture\n› \n ? for shortcuts", on: sessions[1].tty)
        let engine = try ApprovalEngine(paths: .init(directory: directory), claudeRegistryReader: { rows in
            rows.filter { $0.agent == .claude }.map { .init(processID: $0.key, kind: "interactive", sessionID: workerID, status: terminal.status($0.pid)) }
        }, processReader: { records }, screenAdapters: [.iterm: adapter],
            codexGroupReader: { record in record.agent == .codex ? .init(threadID: codexID, database: home + "/thread_history_1.sqlite") : nil },
            groupModelSettingsReader: { live in .init(model: live.session.agent == .codex ? "gpt-6.1-sol" : "claude-opus-5-5",
                reasoningEffort: live.session.agent == .codex ? "xhigh" : "medium", source: "owned_fixture", recordedAt: Date(timeIntervalSince1970: 1794900000)) },
            groupClaudeCompletionReader: { _, _, _ in .init(id: "owned-final-turn", summary: "Recovered fixture final response") }, isolateByDefault: true)
        defer { engine.stop() }
        engine.groupDeliveryInterval = 0.05; engine.groupMailboxPollInterval = 0.05
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        let observed = try await engine.sessionGroupSessions()
        let parent = SessionGroupMember(agent: .codex, title: "metadata parent", cwd: "/project", conversationID: parentID, providerHome: home)
        let worker = try unwrapGroup(observed.first { $0.id == sessions[0].id }).member
        let codex = try unwrapGroup(observed.first { $0.id == sessions[1].id }).member
        let disconnected = SessionGroupMember(agent: .codex, title: "offline", cwd: "/project", conversationID: UUID().uuidString, providerHome: home)
        let group = SessionGroup(name: "cross-agent", members: [parent, worker, codex, disconnected], leaderMemberID: parent.id)
        try SessionGroupStore(directory: directory).save([group])
        func call(_ tool: String, extra: JSONObject = [:]) async throws -> JSONObject {
            var args: JSONObject = ["owner": UUID().uuidString, "tool": tool, "agentKind": "codex", "conversationID": parentID,
                "codexCallerConversationID": parentID, "codexCallerHome": home, "groupID": group.id.uuidString, "memberID": worker.id.uuidString]
            args.merge(extra) { _, new in new }; return try await engine.mcpAction(args)
        }
        for tool in ["get_session_groups", "get_group_status"] {
            let response = try await call(tool)
            let rows = (response["groups"] as? [JSONObject])?.first?["members"] as? [JSONObject] ?? []
            let claude = rows.first { $0["id"] as? String == worker.id.uuidString }
            try expectEqual(claude?["model"] as? String, "claude-opus-5-5")
            try expectEqual(claude?["reasoningEffort"] as? String, "medium")
            try expectEqual(claude?["modelSettingsSource"] as? String, "owned_fixture")
            try expectNotNil(claude?["modelSettingsRecordedAt"] as? String)
            try expectEqual(rows.first { $0["id"] as? String == codex.id.uuidString }?["reasoningEffort"] as? String, "xhigh")
            for id in [parent.id, disconnected.id] { try expect(rows.first { $0["id"] as? String == id.uuidString }?["model"] is NSNull) }
            if tool == "get_group_status" { try expectEqual(claude?["canAssign"] as? Bool, true) }
        }
        _ = try await call("assign_group_task", extra: ["task": "Inspect the owned fixture"])
        try expectEqual(terminal.status(records[0].pid), "busy")
        let box = try SessionGroupMailbox(directory: directory)
        try await Task.sleep(for: .milliseconds(250))
        try expectEqual(try box.pendingCount, 0, "Busy status cannot be mistaken for completion")
        try expectEqual(try engine.sessionGroupAssignments().first?.status, .working)
        // No Stop hook is sent. The verified idle conversation's final record recovers the report.
        terminal.setStatus(records[0].pid, "idle")
        _ = engine.handleHook(["hook_event_name": "StopFailure", "session_id": workerID, "requestID": UUID().uuidString,
            "agentPID": records[0].pid, "agentStarted": records[0].started, "error": "fixture_failure"])
        try await Task.sleep(for: .milliseconds(150))
        try expectEqual(try box.pendingCount, 0, "An unresolved failure cannot become a success report")
        _ = engine.handleHook(["hook_event_name": "UserPromptSubmit", "session_id": workerID, "requestID": UUID().uuidString,
            "agentPID": records[0].pid, "agentStarted": records[0].started])
        try expect(try await waitForGroup(5) { (try? box.pendingCount) == 1 })
        let messages = try box.list(groupID: group.id, memberID: parent.id)
        try expectEqual(messages.count, 1); try expect(messages[0].text.contains("Recovered fixture final response"))
        _ = try await call("get_group_messages")
        try expectEqual(try engine.sessionGroupAssignments().first?.status, .completed)
        _ = try await call("ack_group_messages", extra: ["messageIDs": [messages[0].id.uuidString]])
        try expectEqual(try engine.sessionGroupAssignments().first?.status, .reported)
        _ = engine.handleHook(["hook_event_name": "Stop", "session_id": workerID, "requestID": UUID().uuidString,
            "agentPID": records[0].pid, "agentStarted": records[0].started, "last_assistant_message": "Duplicate late Stop"])
        try await Task.sleep(for: .milliseconds(150))
        try expectEqual(try box.list(groupID: group.id, memberID: parent.id, includeAcknowledged: true).count, 1)
        try expectEqual(try box.pendingCount, 0); try expect(engine.networkIsolated)
    }

    @MainActor func testGroupDialogueAcrossAgentsAndHierarchy() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("group-dialogue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        101011 1 fixture201 101011 101011 Wed Oct 28 12:00:00 2026 /fixture/codex
        101012 1 fixture202 101012 101012 Wed Oct 28 12:00:00 2026 /fixture/claude
        101013 1 fixture203 101013 101013 Wed Oct 28 12:00:00 2026 /fixture/codex
        101014 1 fixture204 101014 101014 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        let sessions = records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm) }
        let ids = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, UUID().uuidString.lowercased()) })
        let writer = GroupTerminalWriter(), terminal = GroupLineTerminal()
        let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { rows in
            rows.filter { $0.agent == .claude }.compactMap { row in ids[row.pid].map { .init(processID: row.key, kind: "interactive", sessionID: $0, status: terminal.status(row.pid)) } }
        }
        var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: writer.screen($0.tty)) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { target, _, _, input in writer.send(target, input) })
        adapter.typeLine = { target, text in terminal.type(target, text, pid: target.sourcePID ?? 0) }
        func makeEngine() throws -> ApprovalEngine {
            let value = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: registry, processReader: { records },
                screenAdapters: [.iterm: adapter], codexGroupReader: { record in ids[record.pid].map { .init(threadID: $0, database: "/fixture/home/thread_history_1.sqlite") } }, isolateByDefault: true)
            value.groupMailboxPollInterval = 0.05; value.groupMailboxReminderInterval = 0.25
            return value
        }
        var engine = try makeEngine()
        defer { engine.stop() }
        func showReady(_ index: Int) {
            let glyph = sessions[index].agent == .claude ? "❯" : "›"
            writer.show("fixture\n" + (sessions[index].agent == .codex ? "• Working (esc to interrupt)\n" : "") + glyph + " \n ? for shortcuts", on: sessions[index].tty)
            terminal.setStatus(records[index].pid, "idle")
        }
        for index in sessions.indices { showReady(index) }
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        let observed = try await engine.sessionGroupSessions()
        let members = try sessions.map { session in try unwrapGroup(observed.first { $0.id == session.id }).member }
        let group = SessionGroup(name: "local dialogue", members: Array(members.prefix(3)), leaderMemberID: members[0].id)
        let store = SessionGroupStore(directory: directory); try store.save([group])
        let box = try SessionGroupMailbox(directory: directory)
        func call(_ tool: String = "ask_group_question", _ text: String = "검증 결과가 어떤가요?", caller: Int = 1, target: Int = 0, extra: JSONObject = [:]) async throws -> JSONObject {
            var args: JSONObject = ["owner": UUID().uuidString, "tool": tool, "sessionID": sessions[caller].id,
                "groupID": group.id.uuidString, "memberID": members[target].id.uuidString, "text": text]
            args.merge(extra) { _, new in new }
            return try await engine.mcpAction(args)
        }
        func acknowledge(_ ids: [UUID], caller: Int) async throws {
            _ = try await call("ack_group_messages", caller: caller, extra: ["messageIDs": ids.map(\.uuidString)])
        }
        func count() -> Int { writer.writes.count + terminal.typed.count }
        func rejects(line: Int = #line, _ operation: () async throws -> JSONObject) async throws {
            let before = try box.pendingCount
            do { _ = try await operation(); throw AppError.message("Invalid group dialogue accepted at line \(line)") }
            catch is RemoteHTTPError { }
            try expectEqual(try box.pendingCount, before)
        }
        let originalAutomatic = engine.snapshot.sessions.map(\.automatic)
        try engine.setPaused(true)
        // Two senders overlap while no terminal input is possible: both requests are durably accepted.
        let concurrentEngine = engine
        @Sendable @MainActor func simultaneous(_ caller: Int, _ text: String) async throws -> Bool {
            let receipt = try await concurrentEngine.mcpAction(["owner": UUID().uuidString, "tool": "ask_group_question", "sessionID": sessions[caller].id,
                "groupID": group.id.uuidString, "memberID": members[0].id.uuidString, "text": text])
            return receipt["accepted"] as? Bool == true && receipt["delivered"] as? Bool == false
        }
        async let left = simultaneous(1, "first")
        async let right = simultaneous(2, "second")
        let accepted = try await [left, right]
        try expect(accepted.allSatisfy { $0 })
        for index in 0..<10 { _ = try await call("ask_group_question", "queued \(index)", caller: index % 2 + 1) }
        try expectEqual(try box.pendingCount, 12); try expectEqual(count(), 0)
        let all = try box.list(groupID: group.id, memberID: members[0].id)
        try expectEqual(Set(all.map(\.id)).count, 12)
        try expectEqual(all.map(\.sequence), all.map(\.sequence).sorted())
        let first = all[0]
        _ = try await call("ask_group_question", first.text, caller: first.senderID == members[1].id ? 1 : 2, extra: ["messageID": first.id.uuidString])
        try expectEqual(try box.pendingCount, 12)
        // Reads, including a lost response, never consume the inbox. Pagination retains acceptance order.
        let page = try await call("get_group_messages", caller: 0, extra: ["limit": 3])
        try expectEqual(page["hasMore"] as? Bool, true)
        let next = try await call("get_group_messages", caller: 0, extra: ["afterSequence": all[2].sequence])
        try expectEqual((next["messages"] as? [JSONObject])?.count, 9)
        _ = try await call("get_group_status", caller: 0)
        try expectEqual(try box.pendingCount, 12)
        try await rejects { try await call("ack_group_messages", caller: 1, extra: ["messageIDs": [first.id.uuidString]]) }
        for tool in ["send_group_message", "ask_group_question", "reply_group_question"] {
            try await rejects { try await call(tool, caller: 3) }
            try await rejects { try await call(tool, target: 3) }
            try await rejects { try await call(tool, caller: 0) }
            try await rejects { try await call(tool, "\n\t") }
            try await rejects { try await call(tool, "bad\0text") }
            try await rejects { try await call(tool, String(repeating: "x", count: 4001)) }
        }
        try await rejects { try await call("get_group_messages", caller: 3) }
        // A busy Codex with an empty composer receives a hint, not duplicate executable message bodies.
        try engine.setPaused(false)
        try expect(try await waitForGroup(5) { writer.writes(to: sessions[0].tty).contains { $0.contains("그룹 수신함") } })
        try expect(writer.writes.allSatisfy { !$0.contains("queued 0") && !$0.contains("first") })
        try expectEqual(try box.pendingCount, 12)
        try await acknowledge(all.map(\.id), caller: 0)
        try await acknowledge(all.map(\.id), caller: 0)
        try expectEqual(try box.pendingCount, 0)
        // Codex -> Claude peer and leader replies are accepted during Claude work; pull receipt works without input.
        terminal.setStatus(records[1].pid, "busy")
        let peer = try await call("ask_group_question", "peer question", caller: 2, target: 1)
        let reply = try await call("reply_group_question", "answer", caller: 0, target: 1)
        try expectEqual(peer["accepted"] as? Bool, true); try expectEqual(reply["accepted"] as? Bool, true)
        let inbox = try await call("get_group_messages", caller: 1)
        let received = (inbox["messages"] as? [JSONObject] ?? []).compactMap { ($0["messageID"] as? String).flatMap(UUID.init(uuidString:)) }
        try expectEqual(received.count, 2); try await acknowledge(received, caller: 1)
        // General messages use the same durable cross-agent route, even with a leader.
        for (sender, recipient) in [(0, 1), (1, 0), (2, 1), (1, 2)] {
            let receipt = try await call("send_group_message", "cross-agent general \(sender)-\(recipient)", caller: sender, target: recipient)
            try expectEqual(receipt["accepted"] as? Bool, true)
            let messageID = try unwrapGroup((receipt["messageID"] as? String).flatMap(UUID.init(uuidString:)))
            let pulled = try await call("get_group_messages", caller: recipient)
            try expect((pulled["messages"] as? [JSONObject] ?? []).contains { $0["messageID"] as? String == messageID.uuidString })
            try await acknowledge([messageID], caller: recipient)
        }
        // Drafts and choice screens defer notification while retaining the message.
        for screen in ["fixture\n› unfinished draft\n ? for shortcuts", "Which option?\n› 1. First\n  2. Second\nPress enter to confirm"] {
            writer.show(screen, on: sessions[0].tty)
            let before = count()
            let pending = try await call("ask_group_question", "while blocked " + UUID().uuidString)
            try await Task.sleep(for: .milliseconds(350))
            try expectEqual(count(), before)
            let id = try unwrapGroup((pending["messageID"] as? String).flatMap(UUID.init(uuidString:)))
            try expectNil(try box.message(id)?.acknowledgedAt)
            try await acknowledge([id], caller: 0)
        }
        showReady(0)
        // A disconnected recipient is retained, without rerouting to another member.
        var disconnected = group; disconnected.members[0].conversationID = UUID().uuidString; disconnected.members[0].runtimeID = "missing"
        try store.save([disconnected])
        let disconnectedMessage = try await call("ask_group_question", "while disconnected")
        let disconnectedID = try unwrapGroup((disconnectedMessage["messageID"] as? String).flatMap(UUID.init(uuidString:)))
        try await Task.sleep(for: .milliseconds(350)); try expectNil(try box.message(disconnectedID)?.acknowledgedAt)
        try store.save([group]); try await acknowledge([disconnectedID], caller: 0)
        // Submission uncertainty survives app restart; repeating a hint never duplicates the message record.
        showReady(1); terminal.ignoresInput = true; engine.groupMailboxReminderInterval = 30
        let uncertain = try await call("reply_group_question", "retained after restart", caller: 2, target: 1)
        let uncertainID = try unwrapGroup((uncertain["messageID"] as? String).flatMap(UUID.init(uuidString:)))
        try expect(try await waitForGroup(12) { (try? box.message(uncertainID)?.lastResult) == "unknown" })
        engine.stop(); terminal.ignoresInput = false; showReady(1)
        try box.noteAttempt(uncertainID, result: "unknown", retryAt: .distantPast)
        engine = try makeEngine(); engine.groupMailboxReminderInterval = 30
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        try engine.start(poll: false)
        try expect(try await waitForGroup(6) { (try? box.message(uncertainID)?.lastResult) == "submitted" })
        try expectEqual(try box.message(uncertainID)?.text, "retained after restart")
        try expectEqual(try box.pendingCount, 1)
        try await acknowledge([uncertainID], caller: 1)
        try expectEqual(try box.pendingCount, 0)
        for tool in ["assign_group_task", "answer_group_question"] {
            try await rejects { try await call(tool, caller: 1, target: 0, extra: ["task": "invalid", "choice": 1]) }
        }
        try expectEqual(engine.snapshot.sessions.map(\.automatic), originalAutomatic)
        try expect(try engine.sessionGroupAssignments().isEmpty)
        try expectEqual(try store.load(), [group]); try expect(engine.networkIsolated); try expect(!engine.webStatus.ready)
    }

    @MainActor func testGroupOfflinePeerMessagesUseLocalTerminals() async throws {
        for agent in [AgentKind.codex, .claude] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-message-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let records = ProcessDiscovery.parse("""
            100911 1 fixture101 100911 100911 Wed Oct 28 12:00:00 2026 /fixture/\(agent.rawValue)
            100912 1 fixture102 100912 100912 Wed Oct 28 12:00:00 2026 /fixture/\(agent.rawValue)
            100913 1 fixture103 100913 100913 Wed Oct 28 12:00:00 2026 /fixture/\(agent.rawValue)
            """)
            let sessions = records.map { AgentSession(id: $0.key, agent: agent, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm) }
            let ids = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, UUID().uuidString.lowercased()) })
            let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { rows in
                rows.compactMap { row in ids[row.pid].map { .init(processID: row.key, kind: "interactive", sessionID: $0, status: "idle") } }
            }
            let writer = GroupTerminalWriter()
            let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: writer.screen($0.tty)) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { target, _, _, input in writer.send(target, input) })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: registry, processReader: { records },
                screenAdapters: [.iterm: adapter], codexGroupReader: { record in
                    ids[record.pid].map { .init(threadID: $0, database: "/fixture/home/thread_history_1.sqlite") }
                }, isolateByDefault: true)
            defer { engine.stop() }
            engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
            let observed = try await engine.sessionGroupSessions()
            let members = try sessions.map { session in try unwrapGroup(observed.first { $0.id == session.id }).member }
            var group = SessionGroup(name: "local peers", members: Array(members.prefix(2)))
            let store = SessionGroupStore(directory: directory); try store.save([group])
            func send(_ text: String, caller: Int = 0, target: Int = 1) async throws -> JSONObject {
                try await engine.mcpAction(["tool": "send_group_message", "owner": UUID().uuidString, "sessionID": sessions[caller].id,
                    "groupID": group.id.uuidString, "memberID": members[target].id.uuidString, "text": text])
            }
            try expect(engine.networkIsolated); try expect(!engine.webStatus.ready)
            let result = try await send("첫 번째 줄\n두 번째 줄")
            try expectEqual(result["transport"] as? String, "local_mailbox"); try expectEqual(result["accepted"] as? Bool, true)
            let box = try SessionGroupMailbox(directory: directory)
            try expectEqual(try box.list(groupID: group.id, memberID: members[1].id).map(\.text), ["첫 번째 줄 두 번째 줄"])
            _ = try await send("확인했습니다", caller: 1, target: 0)
            try expectEqual(try box.list(groupID: group.id, memberID: members[0].id).map(\.text), ["확인했습니다"])
            try expect(try engine.sessionGroupAssignments().isEmpty, "Peer messages must not create worker assignments")
            for (text, caller, target) in [("/status", 0, 1), ("hello", 2, 1), ("hello", 0, 0)] {
                do { _ = try await send(text, caller: caller, target: target); throw AppError.message("Invalid message was delivered") }
                catch is RemoteHTTPError { }
            }
            try engine.setPaused(true)
            _ = try await send("paused")
            try expectEqual(try box.pendingCount, 3)
            try engine.setPaused(false)
            group.leaderMemberID = members[0].id; try store.save([group])
            _ = try await send("그룹장 일반 메시지")
            try expectEqual(try box.pendingCount, 4)
            try expect(try engine.sessionGroupAssignments().isEmpty, "General dialogue never acquires task authority")
            try expect(engine.networkIsolated); try expect(!engine.webStatus.ready)
        }
    }
}
