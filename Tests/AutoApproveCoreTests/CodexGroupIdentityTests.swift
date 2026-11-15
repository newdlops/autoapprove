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

private final class ClippedGroupStatus: @unchecked Sendable {
    let lock = NSLock(), id = UUID().uuidString.lowercased()
    let repeated: Bool, append: Bool
    private var sent = false, reads = 0
    init(repeated: Bool, append: Bool = true) { self.repeated = repeated; self.append = append }
    private var card: String { ">_ OpenAI Codex (v0.169.0)\nModel: fixture\nDirectory: /project\nPermissions: Read Only\nAgents.md: none\nSession: \(id)\n› \n ? for shortcuts" }
    var screen: String {
        lock.lock(); defer { lock.unlock() }
        return repeated ? card : sent ? "Session: \(id)\n› \n ? for shortcuts" : "Codex\n• Working (esc to interrupt)\n› \n ? for shortcuts"
    }
    var history: String {
        lock.lock(); defer { lock.unlock() }; reads += 1
        return card + (sent && append ? "\n" + card : "")
    }
    var historyReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func send(_ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        if input.bytes == "/status\r" { sent = true }
        return .sent
    }
}

extension ApprovalTests {
    @MainActor func testCodexGroupStatusUsesFreshHistoryWhenFrameClips() async throws {
        for (repeated, append) in [(false, true), (true, true), (false, false)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-status-history-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100596 1 fixture45 100596 100596 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .terminal)
            let screen = ClippedGroupStatus(repeated: repeated, append: append)
            let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) },
                history: { target in try expectEqual(target.tty, session.tty); return screen.history })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.terminal: adapter],
                codexGroupReader: { _ in nil }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
            defer { engine.stop() }
            engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.terminal)
            let group = SessionGroup(name: "fixture", members: [SessionGroupLiveSession(session: session, conversationID: nil, providerHome: "/fixture/home").member])
            try SessionGroupStore(directory: directory).save([group])
            _ = try await engine.sessionGroupSessions()
            try expectEqual(screen.historyReads, 0, "Discovery never reads scrollback")
            var refreshed = false
            do { try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: group.members[0].id); refreshed = true }
            catch { if append { throw error } }
            try expectEqual(refreshed, append, "An unchanged historical card must never establish freshness")
            let saved = try SessionGroupStore(directory: directory).load()[0]
            try expectEqual(saved.members[0].conversationID, append ? screen.id : "")
            try expect(screen.historyReads <= 4, "History fallback is bounded per explicit query")
        }
    }
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
        for useTerminal in [false,true] {
        for working in [false,true] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-screen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("100591 1 fixture40 100591 100591 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        let host:ScreenHost=useTerminal ? .terminal:.iterm
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: useTerminal ? .terminal:.iterm)
        session.phase = working ? .working:.idle; session.channel = host.channel
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone = .current;formatter.dateFormat="EEE MMM d HH:mm:ss yyyy"
        let identity=TTYInputIdentity(pid:record.pid,processGroup:record.pid,uid:getuid(),effectiveUID:geteuid(),device:42,
            startSeconds:UInt64(formatter.date(from:record.started)!.timeIntervalSince1970),startMicroseconds:71)
        let screen = CodexGroupScreen(working ? "Codex\n• Working (esc to interrupt)\n› \n ? for shortcuts":nil)
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [host: adapter],
            terminalInputAvailable:{true},terminalInputIdentity:{_ in identity},
            codexGroupReader: { _ in screen.location() }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(host)
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
        }
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
        try expectEqual(try CodexGroupIdentity.conversationID(in: message, environment: ["CODEX_THREAD_ID": other]), id.lowercased(), "Per-call metadata wins over inherited context")
        try expectEqual(try CodexGroupIdentity.conversationID(in: [:], environment: ["CODEX_THREAD_ID": id]), id.lowercased())
        try expectNil(try CodexGroupIdentity.conversationID(in: [:], environment: ["CODEX_THREAD_ID": "invalid"]))
        try expectNil(try CodexGroupIdentity.conversationID(in: ["params": ["arguments": ["CODEX_THREAD_ID": id]]]))
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
        try expectEqual(peer?["connectionState"] as? String, "disconnected")
        params["codexCallerHome"] = "/fixture/other"
        try expectEqual((try await engine.mcpAction(params)["groups"] as? [JSONObject])?.count, 0)
    }

    @MainActor func testCodexMetadataParentCanDirectConfirmedWorker() async throws {
        for (useTerminal, textUnavailable, backgroundAvailable) in [(false, false, true), (false, true, true), (true, false, true), (true, false, false)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-parent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentID = UUID().uuidString, workerID = UUID().uuidString, home = "/fixture/home"
        let parent = SessionGroupMember(agent: .codex, title: "parent", cwd: "/project", conversationID: parentID, providerHome: home)
        let record = ProcessDiscovery.parse("100593 1 fixture42 100593 100593 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        let host: ScreenHost = useTerminal ? .terminal : .iterm
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let identity = TTYInputIdentity(pid: record.pid, processGroup: record.pid, uid: getuid(), effectiveUID: geteuid(), device: 42,
            startSeconds: UInt64(formatter.date(from: record.started)!.timeIntervalSince1970), startMicroseconds: 71)
        let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: useTerminal ? .terminal : .iterm)
        let screen = CodexGroupScreen()
        var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in
                if useTerminal { throw AppError.message("Focus-dependent input must never be used for group traffic") }
                return screen.send(input)
            },
            presentationScreens: { _ in throw AppError.message("Cursor/window lookup timed out") },
            validationScreens: { targets in
                if textUnavailable { throw AppError.message("Text channel unavailable") }
                return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) })
            })
        if useTerminal, backgroundAvailable {
            adapter.backgroundInput = { target, raw, agent, input in
                try TerminalDeviceInput.deliverBackground(target: target, screen: raw, agent: agent, input: input,
                    captureIdentity: { _ in identity }, run: { script in
                        try expect(!script.contains("activate") && !script.contains("selectedTab") && !script.contains("System Events"), "Group delivery must not select or focus any window")
                        try expect(script.contains("app.doScript(target.text, {in: tab})"))
                        _ = screen.send(input)
                        return "sent"
                    })
            }
        }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [host: adapter],
            terminalInputAvailable: { true }, terminalInputIdentity: { _ in identity },
            codexGroupReader: { _ in .init(threadID: workerID, database: home + "/thread_history_1.sqlite") })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(host)
        let worker = SessionGroupLiveSession(session: session, conversationID: workerID, providerHome: home).member
        let group = SessionGroup(name: "fixture", members: [parent, worker], leaderMemberID: parent.id)
        try SessionGroupStore(directory: directory).save([group])
        let params: JSONObject = ["owner": UUID().uuidString, "tool": "assign_group_task", "agentKind": "codex",
            "sessionID": "shared-daemon", "conversationID": parentID, "codexCallerConversationID": parentID, "codexCallerHome": home,
            "groupID": group.id.uuidString, "memberID": worker.id.uuidString, "task": "Inspect the fixture"]
        if textUnavailable || !backgroundAvailable {
            do { _ = try await engine.mcpAction(params); throw AppError.message("Unreadable text accepted a task") }
            catch let error as RemoteHTTPError {
                try expectEqual(error.diagnostics?["delivery"], "not_started")
                try expect(error.localizedDescription.contains(textUnavailable ? "Text channel unavailable" : "포커스 없는"), "Unexpected rejection (Terminal: \(useTerminal)): \(error.localizedDescription)")
            }
            try expectEqual(screen.inputs.count, 0)
            try expect(try engine.sessionGroupAssignments().isEmpty)
            continue
        }
        _ = try await engine.mcpAction(params)
        try expectEqual(screen.inputs.count, 1)
        try expect(screen.inputs[0].contains("Inspect the fixture"))
        let task = try engine.sessionGroupAssignments().first
        try expectEqual(task?.workerSessionID, session.id)
        try expect(task?.parentSessionID.hasPrefix("codex-mcp:") == true, "Never route reports to an unverified parent terminal")
        }
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

extension ApprovalTests {
    @MainActor func testGroupOfflineReconnectUsesOriginalTerminal() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("aa-group-offline-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        100901 1 fixture91 100901 100901 Wed Oct 28 12:00:00 2026 /fixture/codex
        100902 1 fixture92 100902 100902 Wed Oct 28 12:00:00 2026 /fixture/codex
        100903 1 fixture93 100903 100903 Wed Oct 28 12:00:00 2026 /fixture/codex
        """)
        let ids = records.map { _ in UUID().uuidString.lowercased() }
        let sessions = records.map { AgentSession(id: $0.key, agent: .codex, pid: $0.pid, started: $0.started,
            tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm) }
        let screen = CodexGroupScreen("Codex\n• Working (esc to interrupt)\n› \n ? for shortcuts")
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { target, _, _, input in
                try expectEqual(target.tty, sessions[1].tty, "Only the saved worker terminal may be queried")
                return screen.send(input)
            })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.iterm: adapter],
            codexGroupReader: { record in
                guard record.pid != records[1].pid, let index = records.firstIndex(where: { $0.key == record.key }) else { return nil }
                return .init(threadID: ids[index], database: "/fixture/home/thread_history_1.sqlite")
            }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] }, isolateByDefault: true)
        defer { engine.stop() }
        try engine.start(poll: false, webByDefault: true)
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        let members = sessions.enumerated().map { SessionGroupLiveSession(session: $0.element, conversationID: ids[$0.offset], providerHome: "/fixture/home").member }
        let group = SessionGroup(name: "offline", members: Array(members.prefix(2)), leaderMemberID: members[0].id)
        let store = SessionGroupStore(directory: directory); try store.save([group])
        func call(_ tool: String, caller: Int = 0, target: Int = 1) async throws -> JSONObject {
            let params: JSONObject = ["tool": tool, "owner": UUID().uuidString, "sessionID": sessions[caller].id,
                "conversationID": ids[caller], "groupID": group.id.uuidString, "memberID": members[target].id.uuidString, "task": "Check fixture"]
            return try await Task.detached {
                try SocketClient.request(path: AppPaths(directory: directory).socket, message: ["method": "mcp", "params": params], timeout: 20)
            }.value
        }
        try expect(engine.networkIsolated); try expect(!engine.webStatus.ready)
        let listed = try await call("get_session_groups", caller: 1)
        let rows = (listed["groups"] as? [JSONObject])?.first?["members"] as? [JSONObject]
        try expectEqual(rows?.first { $0["id"] as? String == members[1].id.uuidString }?["connected"] as? Bool, false)
        try expectEqual(rows?.first { $0["id"] as? String == members[1].id.uuidString }?["canReconnect"] as? Bool, true)
        try expectEqual(screen.inputs, [], "Read-only membership must not type /status")
        for (tool, caller, target) in [("reconnect_group_member", 2, 1), ("reconnect_group_member", 1, 0), ("assign_group_task", 0, 1), ("get_group_status", 1, 1)] {
            var rejected = false
            do { _ = try await call(tool, caller: caller, target: target) } catch { rejected = true }
            try expect(rejected, "Unverified or unauthorized operation succeeded")
        }
        try expectEqual(screen.inputs, [])
        let repaired = try await call("reconnect_group_member")
        try expectEqual(repaired["connected"] as? Bool, true)
        try expectEqual(repaired["conversationID"] as? String, screen.id)
        try expectEqual(repaired["transport"] as? String, "local_terminal")
        try expectEqual(screen.inputs, ["/status\r"])
        try expectEqual(try store.load()[0].members[1].conversationID, screen.id)
        _ = try await call("reconnect_group_member")
        try expectEqual(screen.inputs, ["/status\r"], "A verified ID is reused without adding terminal input")
        try expect(engine.networkIsolated); try expect(!engine.webStatus.ready)
        // An exited member may not be replaced with an unrelated process in the same project.
        engine.updateDiscovery([sessions[0], sessions[2]], records: [records[0], records[2]])
        var rejected = false
        do { _ = try await call("reconnect_group_member") } catch { rejected = true }
        try expect(rejected, "An exited terminal was guessed")
        try expectEqual(screen.inputs, ["/status\r"])
    }

    @MainActor func testGroupOfflineSelfReconnectProtectsDrafts() async throws {
        for text in ["Codex\n› unfinished draft\n ? for shortcuts", "Codex\n› Ask Codex to do anything\n ? for shortcuts"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-self-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100904 1 fixture94 100904 100904 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .iterm)
            let screen = CodexGroupScreen(text)
            let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter],
                codexGroupReader: { _ in nil }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] }, isolateByDefault: true)
            defer { engine.stop() }
            engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
            let member = SessionGroupLiveSession(session: session, conversationID: UUID().uuidString, providerHome: "/fixture/home").member
            let group = SessionGroup(name: "self", members: [member]); let store = SessionGroupStore(directory: directory); try store.save([group])
            let params: JSONObject = ["tool": "reconnect_group_member", "owner": UUID().uuidString, "sessionID": session.id,
                "conversationID": screen.id, "groupID": group.id.uuidString, "memberID": member.id.uuidString]
            if text.contains("unfinished") {
                var failed = false
                do { _ = try await engine.mcpAction(params) } catch { failed = true }
                try expect(failed); try expectEqual(screen.inputs, [])
                try expectEqual(try store.load()[0].members[0].conversationID, member.conversationID.lowercased())
            } else {
                let result = try await engine.mcpAction(params)
                try expectEqual(result["connected"] as? Bool, true); try expectEqual(screen.inputs, ["/status\r"])
            }
        }
    }
}
