import Foundation
import AutoApproveCore
import TerminalInputSupport

private final class CodexGroupScreen: @unchecked Sendable {
    let lock = NSLock(), id = UUID().uuidString.lowercased()
    private var value = "Codex\n› Ask Codex to do anything\n  ? for shortcuts"
    private var writes: [String] = []
    private var resumeWrites = 0
    private var rollout: String?
    init(_ initial: String? = nil) { if let initial { value = initial } }
    func clearRollout() { lock.lock(); defer { lock.unlock() }; rollout = nil }
    func setRollout(_ id: String) { lock.lock(); defer { lock.unlock() }; rollout = id }
    func location() -> CodexThreadLocation? {
        lock.lock(); defer { lock.unlock() }
        return rollout.map { .init(threadID: $0, database: "/fixture/home/thread_history_1.sqlite") }
    }
    var screen: String { lock.lock(); defer { lock.unlock() }; return value }
    var inputs: [String] { lock.lock(); defer { lock.unlock() }; return writes }
    var resumes: Int { lock.lock(); defer { lock.unlock() }; return resumeWrites }
    func resume() -> ResumeDelivery { lock.lock(); defer { lock.unlock() }; resumeWrites += 1; return .typed }
    func send(_ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }; writes.append(input.bytes)
        if input.bytes.contains("/status") {
            let footer = value.contains("Goal stalled") ? " · Goal stalled (/goal resume)" : ""
            value = ">_ OpenAI Codex (v0.169.0)\nModel: fixture\nDirectory: /project\nPermissions: Read Only\nAgents.md: none\nSession: \(id)\n› Ask Codex to do anything\n  ? for shortcuts" + footer
        }
        return .sent
    }
}

extension ApprovalTests {
    @MainActor func testCodexGroupStatusRefreshDuringRecoveryReview() async throws {
        for useITerm in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-review-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100594 1 fixture43 100594 100594 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            let host: ScreenHost = useITerm ? .iterm : .terminal
            var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: useITerm ? .iterm : .terminal)
            session.channel = host.channel
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current; formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            let identity = TTYInputIdentity(pid: record.pid, processGroup: record.pid, uid: getuid(), effectiveUID: geteuid(), device: 42,
                startSeconds: UInt64(formatter.date(from: record.started)!.timeIntervalSince1970), startMicroseconds: 71)
            let text = "Codex\n› Ask Codex to do anything\n ? for shortcuts · Goal stalled (/goal resume)"
            let screen = CodexGroupScreen(text)
            let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, resume: { _, _, _ in screen.resume() }, input: { _, _, _, input in screen.send(input) })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [host: adapter],
                terminalInputAvailable: { true }, terminalInputIdentity: { _ in identity },
                codexGroupReader: { _ in nil }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
            defer { engine.stop() }
            engine.goalBlockedResumeDelays = [0.01]
            engine.updateDiscovery([session], records: [record]); try engine.setAutomatic(session.id, enabled: true)
            await engine.connectScreenHost(host)
            engine.receiveScreen(sessionID: session.id, raw: text, generation: "fixture")
            for _ in 0..<100 {
                if engine.snapshot.sessions.first?.capacityResume?.phase == .review { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            engine.receiveScreen(sessionID: session.id, raw: text, generation: "fixture")
            try expectEqual(screen.resumes, 1)
            try expectEqual(engine.snapshot.sessions.first?.interruption?.resumeUncertain, true)
            try expectEqual(engine.snapshot.sessions.first?.pendingInTerminal, true)
            try expect(engine.snapshot.sessions.first?.pendingRequestID?.hasPrefix("capacity:review:") == true)
            if !useITerm {
                let frame = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
                var rejected = false
                do {
                    _ = try await engine.remoteInput(["sessionID": session.id, "revision": frame.revision, "streamID": frame.streamID ?? "",
                        "relay": true, "kind": "message", "text": "/status", "codexStatusQuery": true])
                } catch { rejected = true }
                try expect(rejected, "Public JSON cannot grant the private status-query capability")
                try expectEqual(screen.inputs.count, 0)
            }
            let group = SessionGroup(name: "fixture", members: [SessionGroupLiveSession(session: session, conversationID: nil, providerHome: "/fixture/home").member])
            try SessionGroupStore(directory: directory).save([group])
            _ = try await engine.sessionGroupSessions()
            try expectEqual(screen.inputs.count, 0, "Observation must never queue a status command")
            try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: group.members[0].id)
            try expectEqual(try SessionGroupStore(directory: directory).load()[0].members[0].conversationID, screen.id)
            try expectEqual(screen.inputs, ["/status\r"])
            try expectEqual(screen.resumes, 1, "A read-only status query must never retry /goal resume")
            try expectEqual(engine.snapshot.sessions.first?.interruption?.resumeUncertain, true)
            try expectNil(engine.snapshot.sessions.first?.interruption?.recoveredAt)
        }
    }

    @MainActor func testCodexGroupStatusReviewDoesNotBypassRealInput() async throws {
        let screens = [
            "Codex\n• Working (esc to interrupt)\n› \n ? for shortcuts",
            "Codex\n› my unfinished draft\n ? for shortcuts · Goal stalled (/goal resume)",
            "Would you like to make the following edits?\n› 1. Yes, proceed (y)\n  2. No (esc)\nPress enter to confirm or esc to cancel"
        ]
        for text in screens {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-review-busy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100595 1 fixture44 100595 100595 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .iterm)
            session.phase = .idle; session.pendingInTerminal = true; session.pendingRequestID = "capacity:review:fixture"
            let screen = CodexGroupScreen(text)
            let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter])
            defer { engine.stop() }
            await engine.connectScreenHost(.iterm); engine.updateDiscovery([session], records: [record])
            let group = SessionGroup(name: "fixture", members: [SessionGroupLiveSession(session: session, conversationID: nil, providerHome: "/fixture/home").member])
            try SessionGroupStore(directory: directory).save([group])
            var rejected = false
            do { try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: group.members[0].id) } catch { rejected = true }
            try expect(rejected); try expectEqual(screen.inputs.count, 0)
            try expectEqual(try SessionGroupStore(directory: directory).load()[0].members[0].conversationID, "")
        }
    }

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
        for _ in 0..<3 { _ = try await engine.sessionGroupSessions() }
        try expectEqual(screen.inputs.count, 0, "Group reads must not type into idle terminals")
        let group = try SessionGroupStore(directory: directory).load()[0]
        try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: group.members[0].id)
        try expectEqual(try await engine.sessionGroupSessions().first?.conversationID, screen.id)
        // Repeated clicks reuse the verified identity, including while a task runs.
        session.phase = .working
        engine.updateDiscovery([session], records: [record])
        for _ in 0..<3 {
            _ = try await engine.sessionGroupSessions()
            try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: group.members[0].id)
        }
        try expectEqual(screen.inputs, ["/status\r"])
        try expectEqual(try SessionGroupStore(directory: directory).load()[0].members[0].conversationID, screen.id)
        let new = UUID().uuidString.lowercased()
        screen.setRollout(new)
        try expectEqual(try await engine.sessionGroupSessions().first?.conversationID, new, "Fresh process evidence must win over cached status")
        try expectEqual(try SessionGroupStore(directory: directory).load()[0].members[0].conversationID, new)
        try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: group.members[0].id)
        try expectEqual(screen.inputs, ["/status\r"], "Known process identity needs no terminal input")
        screen.clearRollout()
        try expectNil(try await engine.sessionGroupSessions().first?.conversationID)
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
