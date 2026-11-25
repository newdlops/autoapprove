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
        if input.kind == .eraseLine { screens[target.tty] = "────────\n❯ \n────────\n? for shortcuts" }
        output.append((target.tty, input.bytes)); return .sent
    }
}

private final class GroupLineTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(tty: String, text: String)] = []
    private var pendingInputs: [String: String] = [:]
    func screen(_ tty: String, fallback: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let text = pendingInputs[tty] else { return fallback }
        return "────────\n❯ " + text + "\n\n────────\n? for shortcuts"
    }
    private var statuses: [Int32: String] = [:]
    var needsEnter = true
    var ignoresInput = false
    var typed: [String] { lock.lock(); defer { lock.unlock() }; return lines.map(\.text) }
    func status(_ pid: Int32) -> String { lock.lock(); defer { lock.unlock() }; return statuses[pid] ?? "idle" }
    func setStatus(_ pid: Int32, _ value: String) { lock.lock(); defer { lock.unlock() }; statuses[pid] = value }
    func type(_ target: ScreenTarget, _ text: String, pid: Int32) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        lines.append((target.tty, text))
        pendingInputs[target.tty] = !ignoresInput && needsEnter && !text.isEmpty ? text : nil
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
        let request: JSONObject = ["owner": UUID().uuidString, "sessionID": sessions[0].id,
            "groupID": group.id.uuidString, "memberID": members[1].id.uuidString]
        func inspect(_ tool: String, _ overrides: JSONObject = [:]) async throws -> JSONObject {
            var params = request.merging(overrides) { _, new in new }
            params["tool"] = tool
            if tool == "get_group_messages" { params["mailboxMemberID"] = params.removeValue(forKey: "memberID") }
            return try await engine.mcpAction(params)
        }
        let overview = try await inspect("get_group_status", ["view": "overview"])
        let compact = try unwrapGroup((overview["groups"] as? [JSONObject])?.first)
        let workerRow = try unwrapGroup((compact["members"] as? [JSONObject])?.first { $0["id"] as? String == members[1].id.uuidString })
        try expectNil(compact["reports"]); try expectNil(compact["mailbox"]); try expectNil(workerRow["task"])
        try expectEqual(workerRow["contextUsedPercent"] as? Int, 32)
        try expectEqual(workerRow["fiveHourUsedPercent"] as? Int, 12)
        try expectEqual(workerRow["queued"] as? Int, 1)
        let first = UUID(), second = UUID(), newest = UUID()
        for id in [first, second] {
            _ = try box.enqueue(id: id, groupID: group.id, senderID: members[0].id, recipientID: members[1].id, kind: .message, text: "old")
        }
        let replacing: JSONObject = ["text": "latest", "messageID": newest.uuidString, "supersedes": [first.uuidString, second.uuidString]]
        _ = try await inspect("send_group_message", replacing)
        _ = try await inspect("send_group_message", replacing)
        try expectEqual(try box.message(first)?.json["supersededBy"] as? String, newest.uuidString)
        try expectEqual(try box.message(second)?.lastResult, "superseded")
        do {
            _ = try await inspect("cancel_group_messages", ["messageIDs": [newest.uuidString, waiting.uuidString]])
            throw AppError.message("Partial queue cancellation committed")
        } catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
        try expect(try box.message(newest)?.lastResult != "superseded")
        _ = try await inspect("cancel_group_messages", ["messageIDs": [newest.uuidString]])
        try expectEqual(try box.message(newest)?.json["state"] as? String, "cancelled")
        let inbox = try await inspect("get_group_messages", ["messageID": waiting.uuidString])
        try expectEqual((inbox["messages"] as? [JSONObject])?.count, 1)
        try expectNil(try box.message(waiting)?.acknowledgedAt)
        for screen in ["first live output", "updated live output"] {
            writer.show(screen, on: sessions[1].tty)
            let frame = try await inspect("get_group_member_terminal")
            try expectEqual(frame["screen"] as? String, screen)
            try expectNotNil(frame["observedAt"] as? String)
        }
        for tool in ["get_group_messages", "get_group_member_terminal"] {
            for overrides: JSONObject in [["sessionID": sessions[1].id, "memberID": members[0].id.uuidString],
                                           ["memberID": UUID().uuidString], ["groupID": UUID().uuidString]] {
                do {
                    _ = try await inspect(tool, overrides)
                    throw AppError.message("Group evidence escaped its leader or member scope")
                } catch let error as RemoteHTTPError { try expectEqual(error.status, 403) }
            }
        }
        writer.show(custom, on: sessions[1].tty)
        try expect(terminal.typed.isEmpty)
        terminal.setStatus(records[1].pid, "idle")
        try box.noteAttempt(waiting, result: "not_started", retryAt: Date().addingTimeInterval(45))
        _ = engine.handleHook(["hook_event_name": "Notification", "notification_type": "idle_prompt",
            "requestID": UUID().uuidString, "session_id": ids[records[1].pid]!, "agentPID": records[1].pid,
            "agentStarted": records[1].started])
        try expect(try await waitForGroup(5) { (try? box.message(waiting)?.lastResult) == "direct_submitted" })
        try expectEqual(terminal.typed.count, 1)
        try expect(terminal.typed[0].contains("busy then idle"))
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
        engine.updateDiscovery([sessions[0]], records: [records[0]])
        let archived = try await inspect("get_group_messages", ["includeAcknowledged": true])
        try expectEqual((archived["messages"] as? [JSONObject])?.count, 8)
        let outbox = try await inspect("get_group_messages", ["direction": "outbox", "includeAcknowledged": true])
        try expectEqual((outbox["messages"] as? [JSONObject])?.count, 0)
        do {
            _ = try await inspect("get_group_member_terminal")
            throw AppError.message("Offline member returned a live terminal")
        } catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
    }

    /// A message held for a busy recipient waits for the recipient to turn idle instead of a short
    /// timer, and the idle state seen on the screen or in Claude's registry, not only a Claude hook,
    /// types it right away.
    @MainActor func testGroupMailboxWaitsForRecipientIdleWithoutHook() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aa-idle-wake-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        104501 1 fixture501 104501 104501 Wed Oct 28 12:00:00 2026 /fixture/claude
        104502 1 fixture502 104502 104502 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        let sessions = records.map { AgentSession(id: $0.key, agent: .claude, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/fixture", terminal: .iterm) }
        let ids = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, UUID().uuidString) })
        let writer = GroupTerminalWriter(), terminal = GroupLineTerminal()
        terminal.needsEnter = false
        let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { rows in
            rows.map { .init(processID: $0.key, kind: "interactive", sessionID: ids[$0.pid], status: terminal.status($0.pid)) }
        }
        let rule = String(repeating: "─", count: 30)
        let custom = "answer\n\(rule)\n❯ \n\(rule)\nuser@host project (main) | fixture status line"
        for session in sessions { writer.show(custom, on: session.tty) }
        var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: writer.screen($0.tty)) }) },
            approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { _,_,_,_ in .missingTarget })
        let firstAdmission = DispatchSemaphore(value:0)
        firstAdmission.signal()
        adapter.typeLine = { target, text in
            if firstAdmission.wait(timeout:.now()) == .success { throw AutomationIPC.InputNotStarted(.busy) }
            return terminal.type(target, text, pid: target.sourcePID ?? 0)
        }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: registry, processReader: { records }, screenAdapters: [.iterm: adapter], isolateByDefault: true)
        defer { engine.stop() }
        engine.groupMailboxPollInterval = 0.05; engine.groupMailboxHeldFallback = 300
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        let live = try await engine.sessionGroupSessions()
        let members = try sessions.map { session in try unwrapGroup(live.first { $0.id == session.id }).member }
        let group = SessionGroup(name: "fixture idle wake", members: members, leaderMemberID: members[0].id)
        try SessionGroupStore(directory: directory).save([group])
        let box = try SessionGroupMailbox(directory: directory)
        terminal.setStatus(records[1].pid, "busy")
        engine.updateDiscovery(sessions, records: records); await engine.refreshScreens()
        let receipt = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "send_group_message", "sessionID": sessions[0].id,
            "groupID": group.id.uuidString, "memberID": members[1].id.uuidString, "text": "fixture held for busy"])
        let id = try unwrapGroup((receipt["messageID"] as? String).flatMap(UUID.init(uuidString:)))
        try expect(try await waitForGroup(5) { (try? box.message(id)?.lastResult) == "not_started" })
        let retryIn = try unwrapGroup(try box.message(id)?.nextAttemptAt).timeIntervalSinceNow
        try expect(retryIn > 200, "A busy recipient is not retried on the short timer (next try in \(Int(retryIn))s)")
        try expect(terminal.typed.isEmpty)
        terminal.setStatus(records[1].pid, "idle")
        engine.updateDiscovery(sessions, records: records); await engine.refreshScreens()
        try expect(try await waitForGroup(5) { (try? box.message(id)?.lastResult) == "direct_submitted" },
                   "Turning idle types the held message without waiting for the timer")
        try expectEqual(terminal.typed.count, 1)
        try expect(terminal.typed[0].contains("fixture held for busy"))
        try box.acknowledge([id], groupID: group.id, recipientID: members[1].id)
        let question = try box.enqueue(groupID: group.id, senderID: members[0].id, recipientID: members[1].id,
                                       kind: .question, text: "earlier question")
        _ = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "ack_group_messages", "sessionID": sessions[1].id,
            "groupID": group.id.uuidString, "messageIDs": [question.id.uuidString]])
        engine.groupMailboxReminderInterval = 0.1
        terminal.setStatus(records[1].pid, "idle")
        engine.updateDiscovery(sessions, records: records); await engine.refreshScreens()
        try expect(try await waitForGroup(12) { terminal.typed.contains { $0.contains(question.id.uuidString) && $0.contains("inReplyTo") } })

    }

    /// A rename request from the graph button is typed as the user's own short request, with no relay
    /// header, and the trailing request ID still lets the observed prompt count as its receipt.
    @MainActor func testGroupRenameButtonTypesUserRequestWithReceipt() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aa-rename-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        104601 1 fixture601 104601 104601 Wed Oct 28 12:00:00 2026 /fixture/claude
        104602 1 fixture602 104602 104602 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        let sessions = records.map { AgentSession(id: $0.key, agent: .claude, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/fixture", terminal: .iterm) }
        let ids = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, UUID().uuidString) })
        let writer = GroupTerminalWriter(), terminal = GroupLineTerminal()
        terminal.needsEnter = false
        let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { rows in
            rows.map { .init(processID: $0.key, kind: "interactive", sessionID: ids[$0.pid], status: terminal.status($0.pid)) }
        }
        let rule = String(repeating: "─", count: 30)
        for session in sessions { writer.show("answer\n\(rule)\n❯ \n\(rule)\nuser@host project (main) | fixture status line", on: session.tty) }
        var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: writer.screen($0.tty)) }) },
            approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { target, _, _, input in writer.send(target, input) })
        adapter.typeLine = { target, text in terminal.type(target, text, pid: target.sourcePID ?? 0) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: registry, processReader: { records }, screenAdapters: [.iterm: adapter], isolateByDefault: true)
        defer { engine.stop() }
        engine.groupMailboxPollInterval = 0.05
        for record in records { terminal.setStatus(record.pid, "idle") }
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        let live = try await engine.sessionGroupSessions()
        let members = try sessions.map { session in try unwrapGroup(live.first { $0.id == session.id }).member }
        let group = SessionGroup(name: "fixture rename", members: members, leaderMemberID: members[0].id)
        try SessionGroupStore(directory: directory).save([group])
        let box = try SessionGroupMailbox(directory: directory)
        try engine.setPaused(true)
        let backlog = try box.enqueue(groupID: group.id, senderID: members[1].id, recipientID: members[0].id, kind: .message, text: "earlier message")
        try expectEqual(try engine.requestSessionGroupNicknames(groupID: group.id, memberIDs: [members[1].id], byUser: true), 1)
        let earlier = try unwrapGroup(try box.heads().first { $0.recipientID == members[1].id })
        try expectEqual(try engine.requestSessionGroupNicknames(groupID: group.id, memberIDs: nil, byUser: true), members.count)
        let requests = try box.heads()
        try expectEqual(Set(requests.map(\.recipientID)), Set(members.map(\.id)))
        let request = try unwrapGroup(requests.first { $0.recipientID == members[0].id })
        try expect(request.id != earlier.id && request.sequence > backlog.sequence)
        try expectEqual(try box.message(earlier.id)?.lastResult, "superseded")
        try expectEqual(Set(try box.conversations(groupID: group.id).messages.prefix(members.count).map(\.id)), Set(requests.map(\.id)))
        try box.acknowledge([backlog.id], groupID: group.id, recipientID: members[0].id)
        try engine.setPaused(false)
        for (i, member) in members.enumerated() {
            let own = try unwrapGroup(requests.first { $0.recipientID == member.id })
            try expect(try await waitForGroup(8) { (try? box.message(own.id)?.lastResult) == "direct_submitted" })
            let typed = try unwrapGroup(terminal.typed.first { $0.hasSuffix("(AutoApprove 요청 ID " + own.id.uuidString + ")") })
            try expect(typed.hasPrefix("AutoApprove 대화 그래프에서 '전체 다시 정하기' 버튼을 눌러 보내는 내 요청이야.") && typed.contains(member.id.uuidString))
            _ = engine.handleHook(["hook_event_name": "UserPromptSubmit", "session_id": ids[records[i].pid]!, "requestID": UUID().uuidString,
                                   "agentPID": records[i].pid, "agentStarted": records[i].started, "prompt": typed])
            try expectEqual(try box.message(own.id)?.lastResult, "observed")
        }
        try expectEqual(terminal.typed.count, members.count)
        let question = try box.enqueue(groupID: group.id, senderID: members[0].id, recipientID: members[1].id,
                                       kind: .question, text: "first pending question")
        let later = try box.enqueue(groupID: group.id, senderID: members[0].id, recipientID: members[1].id,
                                    kind: .question, text: "second pending question")
        try box.acknowledge([question.id], groupID: group.id, recipientID: members[1].id)
        terminal.setStatus(records[1].pid, "busy")
        writer.show("Working… (esc to interrupt)\n❯ ", on: sessions[1].tty)
        let feedback = try await engine.prioritizeSessionGroupReplies(groupID: group.id, memberID: members[1].id)
        try expect(feedback.contains("작업 중단을 요청"), feedback)
        try expectEqual(writer.writes(to: sessions[1].tty), ["\u{1b}"])
        _ = try await engine.prioritizeSessionGroupReplies(groupID: group.id, memberID: members[1].id)
        try expectEqual(writer.writes(to: sessions[1].tty).count, 1)
        let list = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "get_group_messages", "sessionID": sessions[1].id,
            "groupID": group.id.uuidString, "unansweredOnly": true])
        try expectEqual((list["messages"] as? [JSONObject])?.compactMap { $0["messageID"] as? String }, [question.id.uuidString, later.id.uuidString])
        _ = engine.handleHook(["hook_event_name": "Stop", "session_id": ids[records[1].pid]!, "requestID": UUID().uuidString,
                               "agentPID": records[1].pid, "agentStarted": records[1].started])
        terminal.setStatus(records[1].pid, "idle")
        writer.show("done\n" + rule + "\n❯ \n" + rule + "\nfixture status", on: sessions[1].tty)
        engine.updateDiscovery(sessions, records: records); await engine.refreshScreens()
        try expect(try await waitForGroup(12) { terminal.typed.contains { $0.contains("unansweredOnly") && $0.contains("이어서 진행") } })
        for item in [question, later] {
            _ = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "reply_group_question", "sessionID": sessions[1].id,
                "groupID": group.id.uuidString, "memberID": members[0].id.uuidString, "inReplyTo": item.id.uuidString, "text": "fixture reply"])
        }
        try expect(try box.pendingReplies(group: group.id, member: members[1].id, senders: members.map(\.id)).isEmpty)
        try expectEqual(try box.conversations(groupID: group.id).conversations.filter { $0.answer != nil }.count, 2)


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
        var claude = live
        claude.session.agent = .claude
        claude.providerHome = NSHomeDirectory() + "/.claude"
        var saved = claude.member
        saved.providerHome = nil
        claude.session.id = "resumed"
        claude.session.cwd = "/different/project"
        try expectEqual(SessionGroupMatching.match(saved, in: [claude])?.id, claude.id)
        let group = SessionGroup(name: "Resumed", members: [saved], leaderMemberID: saved.id)
        let repaired = SessionGroupMatching.refreshedClaude([group], live: [claude])[0]
        try expectEqual(repaired.members[0].runtimeID, claude.id)
        try expectEqual(repaired.members[0].providerHome, claude.providerHome)
        try expectNil(SessionGroupMatching.match(saved, in: [claude, claude]))
        var restarted = claude
        restarted.conversationID = UUID().uuidString
        restarted.session.cwd = saved.cwd
        try expectNil(SessionGroupMatching.match(saved, in: [restarted]))
        try expectNil(SessionGroupMatching.replacement(saved, in: [restarted], selected: nil))
        try expectEqual(SessionGroupMatching.replacement(saved, in: [restarted], selected: restarted.id)?.id, restarted.id)
        try expectNil(SessionGroupMatching.replacement(saved, in: [restarted, claude], selected: restarted.id))
        var peer = restarted
        peer.session.id = "peer"
        peer.conversationID = UUID().uuidString
        let team = SessionGroup(name: "team", members: [saved, peer.member], leaderMemberID: saved.id)
        func remaining(_ rows: [SessionGroupLiveSession], _ others: [SessionGroup] = []) -> String? {
            SessionGroupMatching.remainingLeaderCandidate(saved.id, group: team, groups: [team] + others, live: rows)?.id
        }
        try expectEqual(remaining([peer, restarted]), restarted.id)
        try expectNil(remaining([restarted]))
        let assigned = SessionGroup(name: "other", members: [restarted.member])
        try expectNil(remaining([peer, restarted], [assigned]))
        var extra = restarted
        extra.session.id = "other"
        extra.conversationID = UUID().uuidString
        try expectNil(remaining([peer, restarted, extra]))
        try expectEqual(remaining([peer, restarted, extra], [SessionGroup(name: "other", members: [extra.member])]), restarted.id)
        extra.conversationID = nil
        try expectNil(remaining([peer, restarted, extra]))
        try expectNil(remaining([peer, extra]))
        claude.providerHome = "/different/claude-config"
        try expectNil(SessionGroupMatching.match(saved, in: [claude]))
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
        100524 1 fixture4 100524 100524 Wed Oct 28 12:00:00 2026 /fixture/claude
        100525 1 fixture5 100525 100525 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        let sessions = records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/tmp/group-fixture", terminal: $0.pid == 100524 ? .claudeBackground : .terminal) }
        let claudeID = UUID().uuidString
        let registry: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { records in
            records.filter { [100522, 100524, 100525].contains($0.pid) }.map { .init(processID: $0.key, kind: $0.pid == 100525 ? "bg" : "interactive", activity: .init(providerID: claudeID, status: "idle", changedAt: Date()), peerName: "fixture-claude-peer") }
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
        for child in sessions.suffix(2) {
            do {
                _ = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "get_session_groups",
                    "sessionID": child.id, "conversationID": claudeID, "agentKind": "claude"])
                throw AppError.message("Background Claude claimed its parent's group")
            } catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
        }
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
        let saved = try store.load()
        let children = Array(sessions.suffix(2))
        engine.updateDiscovery(children, records: Array(records.suffix(2)))
        let remaining = try await engine.sessionGroupSessions()
        try expect(remaining.isEmpty)
        try expectNil(SessionGroupMatching.connection(second.member, in: remaining))
        try expectEqual(try store.load(), saved)
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
        let ranked = try peers.settingParent(c.id, for: a.id).validated()
        try expectEqual(ranked.treeOrder.map(\.id), [c.id, a.id, b.id, d.id])
        try expectEqual(ranked.treeOrder.map(\.depth), [0, 1, 2, 1])
        try expect(ranked.canDirect(c.id, worker: a.id) && ranked.canDirect(a.id, worker: b.id))
        try expect(!ranked.canDirect(a.id, worker: c.id) && !ranked.canDirect(a.id, worker: d.id))
        try expect(ranked.settingParent(b.id, for: a.id) == ranked && ranked.settingParent(a.id, for: c.id) == ranked)
        try expectEqual(ranked.settingParent(nil, for: a.id), peers)
        try expectEqual(try JSONDecoder().decode(SessionGroup.self, from: JSONEncoder().encode(ranked)).validated(), ranked)
        let third = ranked.addingLeader(d.id)
        try expect(!third.canDirect(d.id, worker: a.id))
        try expect(!third.canManage(d.id, member: a.id) && !third.canManage(a.id, member: c.id))
        let chain = try third.settingParent(a.id, for: d.id).validated()
        try expectEqual(chain.parentID(of: d.id), a.id)
        try expect(!chain.canDirect(c.id, worker: d.id))
        try expectNil(try chain.removingLeader(a.id).validated().parentID(of: d.id))
        var broken = chain
        broken.members[2].parentMemberID = d.id
        try expectThrows(try broken.validated())
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

        try expect(state.noteDeliveryFailure([second.id], "busy"))
        try expect(!state.noteDeliveryFailure([second.id], "busy"))
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

    @MainActor func testBackgroundJobOversight() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let rows = ProcessDiscovery.parse("""
            104651 1 fixture1 104651 104651 Wed Oct 28 12:00:00 2026 /fixture/codex
            104652 1 fixture2 104652 104652 Wed Oct 28 12:00:00 2026 /fixture/codex
            104653 1 fixture3 104653 104653 Wed Oct 28 12:00:00 2026 /fixture/codex
            """)
        let sessions = rows.map { AgentSession(id:$0.key,agent:.codex,pid:$0.pid,started:$0.started,tty:"/dev/"+$0.tty,cwd:"/fixture",terminal:.iterm) }
        let threads = Dictionary(uniqueKeysWithValues:rows.map { ($0.pid,UUID().uuidString.lowercased()) })
        final class Fixture: @unchecked Sendable {
            let lock = NSLock()
            var stopped = Set<String>()
            var calls: [String] = []
            var failed = false
            func list(_ key:String) -> [String] {
                lock.lock(); defer { lock.unlock() }
                return (stopped.contains(key) ? [] : ["server"]) + (failed ? [] : ["tests"])
            }
            func stop(_ key:String) {
                lock.lock(); defer { lock.unlock() }
                stopped.insert(key); calls.append(key)
            }
        }
        let fixture = Fixture()
        func engine() throws -> ApprovalEngine {
            let e = try ApprovalEngine(paths:AppPaths(directory:dir),processReader:{ rows },codexGroupReader:{ r in
                threads[r.pid].map { .init(threadID:$0,database:"/fixture/home/state_5.sqlite") }
            },isolateByDefault:true)
            e.groupJobProvider = .init(inventory:{ live,g,m in
                .init(server:"fixture",jobs:fixture.list(live.id).map {
                    .init(group:g,member:m,session:live.id,conversation:live.conversationID!,server:"fixture",process:$0,item:"item-"+$0,command:$0)
                })
            },evidence:{ _,job in
                .init(output:"fixture output",exitCode:job.process == "tests" ? 42 : nil,failed:job.process == "tests")
            },stop:{ live,_,authorize in
                try await authorize()
                fixture.stop(live.id)
                return true
            })
            e.updateDiscovery(sessions,records:rows)
            return e
        }
        var e = try engine()
        defer { e.stop() }
        let live = try await e.sessionGroupSessions()
        let members = try sessions.map { session in try unwrapGroup(live.first { $0.id == session.id }).member }
        let group = SessionGroup(name:"jobs",members:members,leaderMemberID:members[0].id)
        try SessionGroupStore(directory:dir).save([group])
        func call(_ tool:String,_ fields:JSONObject = [:]) async throws -> JSONObject {
            try await e.mcpAction(["tool":tool,"owner":UUID().uuidString,"sessionID":sessions[0].id,"groupID":group.id.uuidString].merging(fields) { _,new in new })
        }
        let all = try unwrapGroup(try await call("list_group_background_jobs")["members"] as? [JSONObject])
        try expectEqual(all.count,3)
        let worker = try unwrapGroup(all.first { $0["memberID"] as? String == members[1].id.uuidString })
        let jobs = try unwrapGroup(worker["jobs"] as? [JSONObject])
        try expectEqual(jobs.count,2)
        let job = try unwrapGroup(jobs.first { $0["providerJobID"] as? String == "server" })
        try expect(job["recentOutput"] == nil)
        let fields: JSONObject = ["memberID":members[1].id.uuidString,"jobID":try unwrapGroup(job["jobID"] as? String)]
        let detail = try await call("list_group_background_jobs",fields)
        try expectEqual(detail["recentOutput"] as? String,"fixture output")
        for invalid in [["sessionID":sessions[1].id],["memberID":members[2].id.uuidString]] {
            do {
                _ = try await call("stop_group_background_job",fields.merging(invalid) { _,new in new })
                throw AppError.message("unrelated caller or member stopped a job")
            } catch is RemoteHTTPError {}
        }
        let stopped = try await call("stop_group_background_job",fields)
        try expectEqual(stopped["status"] as? String,"stopped")
        e.stop(); e = try engine()
        try expectEqual(try await call("stop_group_background_job",fields)["status"] as? String,"stopped")
        try expectEqual(fixture.calls,[sessions[1].id])
        fixture.failed = true
        _ = try await call("list_group_background_jobs",["memberID":members[1].id.uuidString])
        let events = try unwrapGroup(try await call("watch_group_events")["events"] as? [JSONObject])
        try expect(events.contains { $0["event"] as? String == "backgroundJobFailed" && $0["exitCode"] as? Int == 42 })
        try expectEqual(events.filter { $0["event"] as? String == "backgroundJobEnded" }.count,1)
        try expectEqual(ActivityDetector.backgroundCount("❯ \n⏵⏵ auto mode on · 2 shells",agent:.claude),2)
        try expectEqual(ActivityDetector.backgroundCount("• 7 background tasks\n› \n? for shortcuts",agent:.codex),nil)
    }

    @MainActor func testLargeGroupOverviewPayload() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = AppPaths(directory: dir); try paths.prepare()
        let records = ProcessDiscovery.parse((0..<11).map { n in
            let pid = 104600 + n
            return "\(pid) 1 fixture\(n) \(pid) \(pid) Wed Oct 28 12:00:00 2026 /fixture/claude"
        }.joined(separator: "\n"))
        let sessions = records.map { AgentSession(id: $0.key, agent: .claude, pid: $0.pid, started: $0.started,
            tty: "/dev/" + $0.tty, cwd: "/fixture", terminal: .iterm) }
        let ids = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, UUID().uuidString) })
        let members = sessions.map { session -> SessionGroupMember in
            var member = SessionGroupMember(agent: .claude, title: session.id, cwd: session.cwd, conversationID: ids[session.id]!)
            member.runtimeID = session.id
            return member
        }
        let group = SessionGroup(name: "overview", members: members, leaderMemberID: members[0].id)
        try SessionGroupStore(directory: dir).save([group])
        let body = String(repeating: "Review the proposed change. ", count: 125)
        var state = SessionGroupOrchestration()
        let earlier = SessionGroupAssignment(groupID:group.id,workerMemberID:members[1].id,parentMemberID:members[0].id,workerSessionID:sessions[1].id,parentSessionID:sessions[0].id,task:"이전 작업")
        state.begin(earlier)
        state.markDelivered(earlier.id)
        _ = state.complete(workerSessionID:sessions[1].id,completion:WorkCompletion(id:"old",summary:"리베이스 충돌로 멈춤"))
        for i in 1..<members.count {
            let assignment = SessionGroupAssignment(groupID: group.id, workerMemberID: members[i].id, parentMemberID: members[0].id,
                workerSessionID: sessions[i].id, parentSessionID: sessions[0].id, task: body)
            state.begin(assignment); state.markDelivered(assignment.id)
        }
        try AuditStore(path: paths.database).set(SessionGroupOrchestration.storeKey, String(decoding: JSONEncoder().encode(state), as: UTF8.self))
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { rows in rows.map {
            .init(processID: $0.key, kind: "interactive", sessionID: ids[$0.key], status: "idle")
        } }, processReader: { records }, isolateByDefault: true)
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: records)
        let args: JSONObject = ["owner": UUID().uuidString, "sessionID": sessions[0].id, "tool": "get_group_status"]
        let full = try await engine.mcpAction(args)
        let overview = try await engine.mcpAction(args.merging(["view": "overview"]) { _, new in new })
        let rows = try unwrapGroup((overview["groups"] as? [JSONObject])?.first?["members"] as? [JSONObject])
        try expectEqual(rows.count, 11)
        let history = try unwrapGroup(rows.first { $0["id"] as? String == members[1].id.uuidString })
        try expectEqual(history["previousReport"] as? String,"리베이스 충돌로 멈춤")
        try expectNil(history["lastReport"])
        try expectEqual(history["lastReportTaskID"] as? String,earlier.id.uuidString)
        try expectEqual(history["lastReportScope"] as? String,"history")
        let shortBytes = try JSONSerialization.data(withJSONObject: overview).count
        let fullBytes = try JSONSerialization.data(withJSONObject: full).count
        try expect(shortBytes * 5 < fullBytes)
        print("11-member status fixture: overview=\(shortBytes) bytes, full=\(fullBytes) bytes")
    }

    @MainActor func testOverdueGroupAssignmentNotifiesOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = AppPaths(directory: dir); try paths.prepare()
        let members = ["leader", "worker"].map { SessionGroupMember(agent: .claude, title: $0, cwd: "/fixture", conversationID: UUID().uuidString) }
        let group = SessionGroup(name: "missing reports", members: members, leaderMemberID: members[0].id)
        try SessionGroupStore(directory: dir).save([group])
        let old = SessionGroupAssignment(groupID: group.id, workerMemberID: members[1].id, parentMemberID: members[0].id,
            workerSessionID: "worker", parentSessionID: "leader", task: "review", sentAt: Date().addingTimeInterval(-1810))
        var state = SessionGroupOrchestration(assignments: [old]); state.markDelivered(old.id)
        try AuditStore(path: paths.database).set(SessionGroupOrchestration.storeKey, String(decoding: JSONEncoder().encode(state), as: UTF8.self))
        let box = try SessionGroupMailbox(directory: dir)
        for _ in 0..<2 {
            let engine = try ApprovalEngine(paths: paths, processReader: { [] }, isolateByDefault: true)
            try engine.start(poll: false)
            try expect(try await waitForGroup(5) { (try? box.message(sourceKey: "missingReport:" + old.id.uuidString)) != nil })
            engine.stop()
        }
        let notices = try box.list(groupID: group.id, memberID: members[0].id, includeAcknowledged: true)
        try expectEqual(notices.count, 1); try expectEqual(notices.first?.kind, .notice)
    }

    @MainActor func testGroupTaskTurnsOnWorkerAutomaticApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-assign-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        100551 1 fixture6 100551 100551 Wed Oct 28 12:00:00 2026 /fixture/claude
        100552 1 fixture7 100552 100552 Wed Oct 28 12:00:00 2026 /fixture/claude
        100553 1 fixture0 100553 100553 Wed Oct 28 12:00:00 2026 /fixture/claude
        """)
        var sessions = records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/tmp/group-fixture", terminal: .iterm) }
        for index in sessions.indices { sessions[index].phase = .idle }
        let ids = [records[0].pid: UUID().uuidString, records[1].pid: UUID().uuidString, records[2].pid: UUID().uuidString]
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
        let other = try unwrapGroup(observed.first { $0.id == records[2].key }).member
        let group = SessionGroup(name: "자동 승인", members: [leaderMember, workerMember, other], leaderMemberID: leaderMember.id)
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
        try expectEqual(badge(leader.id)?.role, .leader); try expectEqual(badge(leader.id)?.childCount, 2)
        try expectEqual(badge(worker.id)?.role, .member); try expectEqual(badge(worker.id)?.task, .working)
        try expectEqual(badge(worker.id)?.parentTitle, leaderMember.title)

        let batchID = UUID().uuidString
        let batch: JSONObject = ["owner": UUID().uuidString, "tool": "assign_group_tasks", "sessionID": leader.id,
            "groupID": group.id.uuidString, "task": "다시 리뷰하세요", "assignments": [
                ["memberID": workerMember.id.uuidString, "workScope": "PR#339", "requestID": batchID],
                ["memberID": other.id.uuidString, "task": "Review independently", "workScope": "PR#339"]]]
        let results = try unwrapGroup(try await engine.mcpAction(batch)["results"] as? [JSONObject])
        try expectEqual(results.first?["taskID"] as? String, batchID)
        try expect((results.last?["error"] as? String)?.contains(workerMember.id.uuidString) == true)
        do { _ = try await assign("#356 수정"); throw AppError.message("Command prefix was accepted") }
        catch let error as RemoteHTTPError { try expect(error.localizedDescription.contains("#356 수정")) }
        let repeated = try unwrapGroup(try await engine.mcpAction(batch)["results"] as? [JSONObject])
        try expectEqual(repeated.first?["alreadyRecorded"] as? Bool, true)
        let interrupt: JSONObject = ["owner": UUID().uuidString, "tool": "interrupt_group_task", "sessionID": leader.id,
            "groupID": group.id.uuidString, "memberID": workerMember.id.uuidString, "taskID": batchID]
        writer.show("Compiling packages…\n❯ \nEsc to interrupt", on: worker.session.tty)
        let before = writer.writes.count
        for invalid: JSONObject in [["taskID": UUID().uuidString], ["sessionID": worker.id]] {
            do {
                _ = try await engine.mcpAction(interrupt.merging(invalid) { _, new in new })
                throw AppError.message("An unrelated task or caller sent an interrupt")
            } catch is RemoteHTTPError { }
        }
        try expectEqual(writer.writes.count, before)
        let stopped = try await engine.mcpAction(interrupt)
        try expectEqual(stopped["escapeSent"] as? Bool, true)
        try expect((stopped["checkpoint"] as? String)?.contains("Compiling") == true)
        try expectEqual(writer.writes.last, "\u{1b}")
        let retry = try await engine.mcpAction(interrupt)
        try expectEqual(retry["alreadyRequested"] as? Bool, true)
        try expectEqual(writer.writes.count, before + 1)
        func action(_ tool: String, _ fields: JSONObject = [:]) async throws -> JSONObject {
            var request = interrupt.merging(fields) { _, new in new }
            request["tool"] = tool
            return try await engine.mcpAction(request)
        }
        let waitingID = UUID().uuidString
        let replacement: JSONObject = ["requestID":waitingID, "task":"새 설계를 검토하세요"]
        let waiting = try await action("replace_group_task", replacement)
        try expectEqual(waiting["stage"] as? String, "awaitingStop")
        try expectEqual(writer.writes.count, before + 1)
        let empty = "────────\n❯ \n────────\n? for shortcuts"
        writer.show(empty, on:worker.session.tty)
        let changed = try await action("replace_group_task", replacement)
        try expectEqual(changed["taskID"] as? String, waitingID)
        let sent = writer.writes.count
        let replay = try await action("replace_group_task", replacement)
        try expectEqual(replay["alreadyRecorded"] as? Bool, true)
        try expectEqual(writer.writes.count, sent)
        let box = try SessionGroupMailbox(directory:directory)
        let message = try box.enqueue(groupID:group.id,senderID:leaderMember.id,recipientID:workerMember.id,kind:.message,text:"상태 확인")
        let details: JSONObject = ["messageID":message.id.uuidString]
        try expectEqual(try await action("explain_group_delivery",details)["stage"] as? String,"queued")
        try box.noteAttempt(message.id,result:"direct_unknown",retryAt:Date.distantFuture)
        try expectEqual(try await action("explain_group_delivery",details)["stage"] as? String,"submissionUnknown")
        let prompt = message.terminalPrompt(senderTitle:"leader",recipientAgent:.claude)
        try box.recordSubmission(message.id,conversation:workerMember.conversationID,prompt:prompt)
        writer.show("────────\n❯ " + prompt + "\n────────\n? for shortcuts",on:worker.session.tty)
        try expectEqual(try await action("explain_group_delivery",details)["stage"] as? String,"draftVisible")
        try expectEqual(try await action("retry_group_submission",details)["stage"] as? String,"enterSent")
        let enterCount = writer.writes.count
        do { _ = try await action("retry_group_submission",details); throw AppError.message("submitted a duplicate Enter") }
        catch is RemoteHTTPError {}
        try expectEqual(writer.writes.count,enterCount)
        let preview = try await action("clear_group_composer")
        let token = try unwrapGroup(preview["draftToken"] as? String)
        writer.show("────────\n❯ #updated\n────────\n? for shortcuts",on:worker.session.tty)
        do { _ = try await action("clear_group_composer",["draftToken":token]); throw AppError.message("stale draft erased") }
        catch is RemoteHTTPError {}
        let latest = try unwrapGroup(try await action("clear_group_composer")["draftToken"] as? String)
        let cleared = try await action("clear_group_composer",["draftToken":latest])
        try expectEqual(cleared["stage"] as? String,"cleared")
        try expectEqual(writer.writes.last,"\u{05}\u{15}")
        try box.noteAttempt(message.id,result:"direct_submitted",retryAt:Date.distantFuture)
        try expectEqual(try await action("explain_group_delivery",details)["stage"] as? String,"enterSent")
        try box.acknowledge([message.id],groupID:group.id,recipientID:workerMember.id)
        try expectEqual(try await action("explain_group_delivery",details)["stage"] as? String,"acknowledged")
        let page = try await action("watch_group_events")
        let events = try unwrapGroup(page["events"] as? [JSONObject])
        try expect(events.contains { $0["event"] as? String == "direct_unknown" && $0["referenceID"] as? String == message.id.uuidString })
        let cursor = try unwrapGroup(page["cursor"] as? Int)
        try expect(try SessionGroupMailbox(directory:directory).events(group:group.id,after:cursor).isEmpty)
        for tool in ["watch_group_events","explain_group_delivery","replace_group_task","clear_group_composer"] {
            do { _ = try await action(tool,details.merging(["sessionID":worker.id]) { _,new in new }); throw AppError.message("unverified caller accepted") }
            catch is RemoteHTTPError {}
        }
        writer.show("검사 원본\n› ", on: worker.session.tty)

        let next = UUID().uuidString
        let queued: JSONObject = ["task":"후속 검증","afterTaskID":waitingID,"requestID":next]
        try expectEqual(try await action("assign_group_task",queued)["stage"] as? String,"queued")
        try expectEqual(try await action("assign_group_task",queued)["taskID"] as? String,next)
        let management: JSONObject = ["taskID":waitingID,"action":"takeOwnership"]
        do {
            _ = try await action("manage_group_task",management.merging(["sessionID":worker.id]) { _,new in new })
            throw AppError.message("worker took ownership")
        } catch is RemoteHTTPError {}
        _ = try await action("manage_group_task",management)
        _ = try await action("manage_group_task",["taskID":waitingID,"action":"closeWithoutReport"])
        try expect(try await waitForGroup(20) { (try? engine.sessionGroupAssignments().contains { $0.id.uuidString == next && $0.isDelivered }) == true })
        try expectEqual(try engine.sessionGroupAssignments().first { $0.id.uuidString == waitingID }?.status,.reported)
        try expectEqual(writer.writes.filter { $0.contains("후속 검증") }.count,1)
        let command = try await action("send_group_message",["text":"다음 검증","asTask":true,"messageID":UUID().uuidString])
        try expectNotNil(command["taskID"])
        let currentID = try unwrapGroup(command["taskID"] as? String)
        let recovery: JSONObject = ["taskID":currentID]
        writer.show("────────\n❯ \n────────\n2 shells still running",on:worker.session.tty)
        let multiple = try await action("interrupt_group_task",recovery)
        try expectEqual(multiple["stage"] as? String,"selectBackgroundJob")
        writer.show("Waiting for git fetch\n✻ Worked for 4m · 1 shell still running\n────────\n❯ \n────────\n? for shortcuts",on:worker.session.tty)
        let priorWrites = writer.writes.count
        let managed = "────────\n❯ \n────────\n1 shell · ← 2 agents · ↓ to manage"
        writer.show(managed,on:worker.session.tty)
        _ = try await action("get_group_member_terminal")
        for mode in ["overview","full"] {
            let status = try await action("get_group_status",["view":mode])
            let row = try unwrapGroup((status["groups"] as? [JSONObject])?.first.flatMap { ($0["members"] as? [JSONObject])?.first { $0["id"] as? String == workerMember.id.uuidString } })
            try expectEqual(row["phase"] as? String,"waitingOnBackground")
            try expectEqual(row["backgroundRunning"] as? Int,1)
            try expectEqual(row["taskStatus"] as? String,"waitingOnBackground")
            try expectEqual(row["assignmentStatus"] as? String,"working")
        }
        try expectEqual(ActivityDetector.backgroundCount(managed,agent:.claude),1)
        try expectEqual(ActivityDetector.backgroundCount(managed.replacingOccurrences(of:"1 shell",with:"3 shells"),agent:.claude),3)
        try expectEqual(ActivityDetector.detect(managed.replacingOccurrences(of:"❯ ",with:"❯ draft"),agent:.claude).phase,.input)
        let recoveryResult = try await action("interrupt_group_task",recovery)
        try expectEqual(recoveryResult["stage"] as? String,"workerStopRequested")
        try expectEqual(recoveryResult["escapeSent"] as? Bool,false)
        try expect(writer.writes.last?.contains("TaskStop") == true)
        try expectEqual(try await action("interrupt_group_task",recovery)["alreadyRequested"] as? Bool,true)
        try expectEqual(writer.writes.count,priorWrites + 1)
        try expectEqual(ActivityDetector.backgroundCount("❯ \n1 shell still running",agent:.claude),1)
        try expectEqual(ActivityDetector.detect("❯ \n1 shell still running",agent:.claude).phase,.idle)
        try expectEqual(ActivityDetector.detect("❯ draft\n1 shell still running",agent:.claude).phase,.input)
        try expectEqual(ActivityDetector.detect("Esc to interrupt\n❯ \n1 shell still running",agent:.claude).phase,.working)

        try engine.setPaused(true); defer { try? engine.setPaused(false) }
        let paused = try await assign("일시정지 중 작업")
        try expectEqual(paused["automaticApproval"] as? String, "paused", "The global pause stays the user's decision")
        try expect(engine.snapshot.paused)
    }

    func testMailboxPriorityRoutingAndInterruptReservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let box = try SessionGroupMailbox(directory:root)
        let group = UUID(), worker = UUID(), leader = UUID()
        let normal = try box.enqueue(groupID:group, senderID:worker, recipientID:leader, kind:.message, text:"normal")
        let urgent = try box.enqueue(groupID:group, senderID:worker, recipientID:leader, kind:.message, text:"urgent", priority:.urgent)
        let request = try box.enqueue(groupID:group, senderID:worker, recipientID:leader, kind:.choiceQuestion, text:"permission",
                                      sourceKey:"question:fixture:approval", priority:.urgent, category:.permissionRequest)
        try expectEqual(try box.heads().map(\.id), [request.id])
        try expectEqual(try box.list(groupID:group, memberID:leader, priority:.urgent, category:.message).map(\.id), [urgent.id])
        try expectFalse(try box.reservePermissionInterrupt(urgent.id))
        try expect(try box.reservePermissionInterrupt(request.id))
        let reopened = try SessionGroupMailbox(directory:root)
        try expectFalse(try reopened.reservePermissionInterrupt(request.id))
        try reopened.releaseUnsentPermissionInterrupt(request.id)
        try expect(try box.reservePermissionInterrupt(request.id))
        _ = try box.setPriority(.normal, id:request.id, group:group, recipient:leader)
        try expectEqual(try box.heads().first?.id, urgent.id)
        try expectEqual(try box.list(groupID:group, memberID:leader, priority:.normal, category:.permissionRequest).first?.id, request.id)
        _ = try box.setPriority(.urgent, id:normal.id, group:group, recipient:leader)
        try expectEqual(try box.heads().first?.id, normal.id)
        let retried = try box.enqueue(id:normal.id, groupID:group, senderID:worker, recipientID:leader, kind:.message, text:"normal")
        try expectEqual(retried.priority,.urgent)
        try expectFalse(try reopened.reservePermissionInterrupt(normal.id))
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
        engine.groupQuestionGrace = 0.2; engine.groupDeliveryInterval = 0.2; engine.groupMailboxPollInterval = 0.2
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

        let workingScreen = "Working… (esc to interrupt)\n────────────\n❯ \n────────────\n ? for shortcuts"
        writer.show(workingScreen.replacingOccurrences(of:"❯ ", with:"❯ my draft"), on:leaderTTY)
        await engine.refreshScreens()
        let approvalScope = "Yes, and don't ask again for commands that start with `python3 -B /tmp/" +
            String(repeating: "fixture-directory/", count: 12) + "verify.py`"
        let approvalOptions = ["Yes", approvalScope, "No"]
        let recorded = GroupWorkerQuestion(id: "approval-fixture", text: "Allow?", options: approvalOptions, permission: true)
        let restored = try JSONDecoder().decode(GroupWorkerQuestion.self, from: JSONEncoder().encode(recorded))
        let changedScope = approvalScope.replacingOccurrences(of: "verify.py", with: "ver ify.py")
        let changed = GroupWorkerQuestion(id: recorded.id, text: recorded.text, options: ["Yes", changedScope, "No"],
                                          seenAt: recorded.seenAt, permission: true)
        try expectEqual(restored, recorded)
        try expectEqual(changed.options, recorded.options)
        try expect(restored != changed)
        writer.show("Do you want to proceed?\n$ echo fixture\n❯ 1. Yes\n  2. \(approvalScope)\n  3. No\nEsc to cancel", on: workerTTY)
        let delegated = try await waitForGroup(20) {
            await engine.refreshScreens()
            return messages().contains { $0.text.contains("[AutoApprove 그룹 승인 요청") }
        }
        try expect(delegated, "The worker's permission prompt must reach the parent")
        let permissionMessage = try unwrapGroup(messages().first { $0.text.contains("[AutoApprove 그룹 승인 요청") })
        try expectEqual(permissionMessage.category, .permissionRequest)
        try expectEqual(permissionMessage.priority, .urgent)
        try await Task.sleep(for:.milliseconds(650))
        try expectFalse(writer.writes(to:leaderTTY).contains("\u{1b}"))
        writer.show(workingScreen, on:leaderTTY)
        let interrupted = try await waitForGroup(10) {
            await engine.refreshScreens()
            return writer.writes(to:leaderTTY).contains("\u{1b}")
        }
        if !interrupted {
            let current = try mailbox.message(permissionMessage.id)
            let phases = engine.snapshot.sessions.map { $0.phase.rawValue + ":pending=" + String($0.pendingInTerminal) }
            throw AppError.message("Expected one parent Escape, phases=\(phases), empty=\(ClaudeComposerReadiness.isEmpty(writer.screen(leaderTTY))), result=\(current?.lastResult ?? "-"), detail=\(current?.lastError ?? "-"), claimAvailable=\(try mailbox.reservePermissionInterrupt(permissionMessage.id))")
        }
        try expectEqual(writer.writes(to:leaderTTY).filter { $0 == "\u{1b}" }.count,1)
        writer.show("Finished\n❯ \n ? for shortcuts", on:leaderTTY)
        await engine.refreshScreens()
        let request = permissionMessage.text
        _ = try await call("ack_group_messages", from: leader.id, ["messageIDs": [permissionMessage.id.uuidString]])
        try expect(request.contains("echo fixture") && request.contains("1) Yes") && request.contains("사용자 승인으로 처리"))
        try expect(approvalScope.count > 200)
        try expectEqual(try await question()?["options"] as? [String], ["Yes", String(approvalScope.prefix(200)), "No"])
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
        var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: terminal.screen($0.tty, fallback: "상태 줄이 있는 화면")) }) },
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
        var adapter = ScreenHostAdapter(screens: { targets in .init(screens: targets.map { .init(tty: $0.tty, contents: terminal.screen($0.tty, fallback: writer.screen($0.tty))) }) },
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
            .addingLeader(worker.id).settingParent(parent.id, for: worker.id)
        try SessionGroupStore(directory: directory).save([group])
        func call(_ tool: String, extra: JSONObject = [:]) async throws -> JSONObject {
            var args: JSONObject = ["owner": UUID().uuidString, "tool": tool, "agentKind": "codex", "conversationID": parentID,
                "codexCallerConversationID": parentID, "codexCallerHome": home, "groupID": group.id.uuidString, "memberID": worker.id.uuidString]
            args.merge(extra) { _, new in new }; return try await engine.mcpAction(args)
        }
        let relationStore = SessionGroupStore(directory: directory)
        let subA = SessionGroupMember(agent: .claude, title: "A", cwd: "/project", conversationID: UUID().uuidString)
        let subB = SessionGroupMember(agent: .codex, title: "B", cwd: "/project", conversationID: UUID().uuidString)
        var sub = SessionGroup(name: "Downstream", members: [subA, subB], leaderMemberID: subA.id)
        sub = try sub.linkingGroupParent(group.id, connected: true)
        let other = SessionGroup(name: "Independent")
        try relationStore.save([group, sub, other])
        let request: JSONObject = ["targetGroupID":sub.id.uuidString, "memberID":subA.id.uuidString, "parentMemberID":subB.id.uuidString, "action":"connect"]
        let linked = try await call("set_group_relationship", extra:request)
        try expectEqual(linked["changed"] as? Bool, true)
        let repeated = try await call("set_group_relationship", extra:request)
        try expectEqual(repeated["changed"] as? Bool, false)
        let cycle = try unwrapGroup(try relationStore.load().first { $0.id == sub.id })
        try expect(cycle.canDirect(subA.id, worker:subB.id) && cycle.canDirect(subB.id, worker:subA.id))
        try expectEqual(Set(cycle.treeOrder.map(\.id)).count, 2)
        let diamond = try group.linkingParent(worker.id, to:codex.id, connected:true)
        try expectEqual(diamond.parentIDs(of:codex.id), [parent.id,worker.id])
        try expectEqual(try JSONDecoder().decode(SessionGroup.self, from: JSONEncoder().encode(diamond)), diamond)
        try expectEqual(try diamond.linkingParent(parent.id, to:codex.id, connected:false).parentIDs(of:codex.id), [worker.id])
        try expectEqual(diamond.removing(worker.id).parentIDs(of:codex.id), [parent.id])
        let relation: JSONObject = ["groupID":group.id.uuidString, "targetGroupID":group.id.uuidString, "parentGroupID":sub.id.uuidString, "action":"connect"]
        var groupCall: JSONObject = ["owner":UUID().uuidString, "tool":"set_group_relationship", "agentKind":"codex", "conversationID":parentID, "codexCallerConversationID":parentID, "codexCallerHome":home]
        groupCall.merge(relation) { _, new in new }
        _ = try await engine.mcpAction(groupCall)
        let topology = try await call("get_group_topology")
        try expectEqual(Set((topology["groups"] as? [JSONObject] ?? []).compactMap { $0["id"] as? String }), [group.id.uuidString,sub.id.uuidString])
        groupCall["targetGroupID"] = other.id.uuidString
        do { _ = try await engine.mcpAction(groupCall); throw AppError.message("Unrelated group claimed") }
        catch let error as RemoteHTTPError { try expectEqual(error.status,403) }
        var subordinate = request
        subordinate.merge(["owner":UUID().uuidString, "tool":"set_group_relationship", "groupID":group.id.uuidString, "sessionID":sessions[0].id]) { _,new in new }
        do { _ = try await engine.mcpAction(subordinate); throw AppError.message("Subordinate claimed cross-group authority") }
        catch let error as RemoteHTTPError { try expectEqual(error.status,403) }
        subordinate["targetGroupID"] = group.id.uuidString
        subordinate["memberID"] = parent.id.uuidString
        subordinate["parentMemberID"] = worker.id.uuidString
        do { _ = try await engine.mcpAction(subordinate); throw AppError.message("Subordinate reassigned its superior") }
        catch let error as RemoteHTTPError { try expectEqual(error.status,403) }
        try relationStore.save([group])
        for tool in ["get_session_groups", "get_group_status"] {
            let response = try await call(tool)
            let rows = (response["groups"] as? [JSONObject])?.first?["members"] as? [JSONObject] ?? []
            let claude = rows.first { $0["id"] as? String == worker.id.uuidString }
            try expectEqual(claude?["isLeader"] as? Bool, true)
            try expectEqual(claude?["parentMemberID"] as? String, parent.id.uuidString)
            try expectEqual(claude?["model"] as? String, "claude-opus-5-5")
            try expectEqual(claude?["reasoningEffort"] as? String, "medium")
            try expectEqual(claude?["modelSettingsSource"] as? String, "owned_fixture")
            try expectNotNil(claude?["modelSettingsRecordedAt"] as? String)
            try expectEqual(rows.first { $0["id"] as? String == codex.id.uuidString }?["reasoningEffort"] as? String, "xhigh")
            for id in [parent.id, disconnected.id] { try expect(rows.first { $0["id"] as? String == id.uuidString }?["model"] is NSNull) }
            if tool == "get_group_status" { try expectEqual(claude?["canAssign"] as? Bool, true) }
        }
        do {
            _ = try await engine.mcpAction(["owner": UUID().uuidString, "tool": "assign_group_task", "sessionID": sessions[0].id,
                "groupID": group.id.uuidString, "memberID": parent.id.uuidString, "task": "Inspect a fixture"])
            throw AppError.message("A subordinate leader assigned work to its supervisor")
        } catch let error as RemoteHTTPError { try expectEqual(error.status, 403) }
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
        try expectEqual(messages.count, 1)
        try expectEqual(messages[0].kind, .report)
        try expectEqual(messages[0].text, "Recovered fixture final response")
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
        var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: terminal.screen($0.tty, fallback: writer.screen($0.tty))) }) },
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
        // A busy Codex with an empty composer must not receive another turn.
        try engine.setPaused(false)
        try expect(try await waitForGroup(5) { (try? box.message(first.id)?.lastResult) == "not_started" })
        try expectEqual(writer.writes.count, 0)
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
        let peerID = try unwrapGroup((peer["messageID"] as? String).flatMap(UUID.init(uuidString:)))
        let originalACK = try box.message(peerID)?.acknowledgedAt
        let beforeManualDelivery = count()
        do {
            try await engine.deliverSessionGroupQuestion(groupID: group.id, questionID: peerID)
            throw AppError.message("A busy Claude accepted manual input")
        } catch is RemoteHTTPError {}
        try expectEqual(count(), beforeManualDelivery)
        showReady(1)
        try await engine.deliverSessionGroupQuestion(groupID: group.id, questionID: peerID)
        let manualInput = Array(terminal.typed.suffix(2))
        try expectEqual(count(), beforeManualDelivery + 2, "The fixture requires one paste and one Enter")
        try expect(manualInput.first?.contains("[AutoApprove 그룹 전달 \(peerID.uuidString)]") == true)
        try expect(manualInput.first?.contains("peer question") == true)
        try expectEqual(manualInput.last, "")
        try expectEqual(try box.message(peerID)?.acknowledgedAt, originalACK)
        try expectEqual(try box.message(peerID)?.lastResult, "direct_submitted")
        try expectEqual(try box.pendingCount, 0)

        terminal.setStatus(records[1].pid, "shell")
        _ = try await engine.sessionGroupSessions()
        let queuedAt = Date()
        let blocked = try box.enqueue(groupID: group.id, senderID: members[0].id, recipientID: members[1].id,
                                      kind: .question, text: "blocked fixture question", at: queuedAt)
        try box.noteAttempt(blocked.id, result: "not_started", error: "fixture shell state", retryAt: .distantFuture)
        let following = try box.enqueue(groupID: group.id, senderID: members[2].id, recipientID: members[1].id,
                                        kind: .message, text: "queued behind question")
        let beforeInspection = count()
        let operation = try unwrapGroup(engine.sessionGroupOperations(group)[members[1].id])
        try expectEqual(operation.phase, .working, "Background shell work is visible on the node")
        try expectEqual(operation.input, .deferred("Claude Code에서 셸 명령 실행 중"))
        try expectEqual(operation.unacknowledgedCount, 2)
        try expect(operation.isDeliveryBlocked)
        try expectEqual(operation.lastDeliveryFailure, "fixture shell state")
        try expectNotNil(operation.lastAcknowledgedAt)
        try expectEqual(operation.firstPendingAt, blocked.createdAt)
        var changedConversation = group
        changedConversation.members[1].conversationID = UUID().uuidString
        try expectNil(try engine.sessionGroupOperations(changedConversation)[members[1].id]?.phase)
        try expectEqual(count(), beforeInspection, "Reading graph status must not send terminal input")
        try box.acknowledge([blocked.id, following.id], groupID: group.id, recipientID: members[1].id)
        try expectEqual(try engine.sessionGroupOperations(group)[members[1].id]?.isDeliveryBlocked, false)
        terminal.setStatus(records[1].pid, "busy")

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
        // Submission uncertainty survives app restart. The terminal ignored the first typing, so after
        // restart the recipient is idle with an empty composer and no trace of the prompt: that is proof
        // of loss, and the same message (same ID) is typed exactly once more, then waits for its receipt.
        showReady(1); terminal.ignoresInput = true; engine.groupMailboxReminderInterval = 30
        let uncertain = try await call("reply_group_question", "retained after restart", caller: 2, target: 1)
        let uncertainID = try unwrapGroup((uncertain["messageID"] as? String).flatMap(UUID.init(uuidString:)))
        try expect(try await waitForGroup(12) { (try? box.message(uncertainID)?.lastResult) == "direct_unknown" })
        engine.stop(); terminal.ignoresInput = false; showReady(1)
        let submittedBeforeRestart = count()
        try box.noteAttempt(uncertainID, result: "direct_unknown", retryAt: .distantPast)
        engine = try makeEngine(); engine.groupMailboxReminderInterval = 30
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        try engine.start(poll: false)
        try expect(try await waitForGroup(8) { (try? box.message(uncertainID)?.lastResult) == "direct_submitted" }, "The lost message is typed again")
        let redelivered = Array(terminal.typed.suffix(2))
        try expect(redelivered.first?.contains("[AutoApprove 그룹 전달 \(uncertainID.uuidString)]") == true, "Redelivery keeps the message ID")
        try expectEqual(count(), submittedBeforeRestart + 2, "One paste and one Enter")
        try await Task.sleep(for: .milliseconds(450))
        try expectEqual(count(), submittedBeforeRestart + 2, "Waiting for the receipt types nothing more")
        try expectEqual(try box.message(uncertainID)?.text, "retained after restart")
        try expectEqual(try box.pendingCount, 1)
        try await acknowledge([uncertainID], caller: 1)
        try expectEqual(try box.pendingCount, 0)
        // A recipient that never takes the typed prompt is not typed at forever: after the
        // attempt limit the message is parked, kept in the inbox and shown as blocked.
        // Each ignored typing waits ~10 s for Claude to accept it, so the fixture uses a limit of two.
        engine.groupMailboxReminderInterval = 120
        engine.groupMailboxReceiptGrace = 0.3; engine.groupMailboxPollInterval = 0.2; engine.groupMailboxDirectAttemptLimit = 2
        showReady(1); terminal.ignoresInput = true
        let beforeParking = count()
        let parkedReceipt = try await call("reply_group_question", "never reaches the model", caller: 2, target: 1)
        let parkedID = try unwrapGroup((parkedReceipt["messageID"] as? String).flatMap(UUID.init(uuidString:)))
        let parkedInTime = try await waitForGroup(40) { (try? box.message(parkedID)?.lastResult) == "undelivered" }
        let parkedState = try box.message(parkedID)
        try expect(parkedInTime, "The message is parked after the attempt limit: \(parkedState?.lastResult ?? "nil") attempts=\(parkedState?.attempts ?? -1) error=\(parkedState?.lastError ?? "") typed=\(terminal.typed.filter { $0.contains(parkedID.uuidString) }.count)")
        let typings = terminal.typed.filter { $0.contains("[AutoApprove 그룹 전달 \(parkedID.uuidString)]") }.count
        try expectEqual(typings, engine.groupMailboxDirectAttemptLimit, "Each typing was proven lost before the next one")
        try await Task.sleep(for: .milliseconds(800))
        try expectEqual(terminal.typed.filter { $0.contains(parkedID.uuidString) }.count, typings, "A parked message is never typed again")
        try expect(count() > beforeParking)
        try expectNil(try box.message(parkedID)?.acknowledgedAt)
        let parkedOperation = try unwrapGroup(engine.sessionGroupOperations(group)[members[1].id])
        try expect(parkedOperation.isDeliveryBlocked, "The graph shows the parked message as blocked")
        try expect(parkedOperation.lastDeliveryFailure?.contains("자동 입력을 멈췄습니다") == true)
        try expect(engine.snapshot.events.contains { $0.outcome == "그룹 메시지 자동 전달 중단" }, "Parking is recorded in history")
        terminal.ignoresInput = false
        // The recipient can still pull and ACK it; that clears the blocked state.
        try await acknowledge([parkedID], caller: 1)
        try expectEqual(try engine.sessionGroupOperations(group)[members[1].id]?.isDeliveryBlocked, false)
        // A summary report is typed with its body and IDs, and the observed prompt commits it:
        // no pointer line, no lookup or ACK call, and no reminder afterwards.
        engine.groupMailboxReceiptGrace = 30; engine.groupMailboxDirectAttemptLimit = 3; showReady(1)
        let report = try box.enqueue(groupID: group.id, senderID: members[0].id, recipientID: members[1].id,
                                     kind: .report, text: "요약 보고 본문", sourceKey: "report:" + UUID().uuidString)
        try expect(try await waitForGroup(8) { (try? box.message(report.id)?.lastResult) == "direct_submitted" }, "The report is typed directly")
        guard let typedReport = terminal.typed.last(where: { $0.contains(report.id.uuidString) }) else { throw AppError.message("No typed report") }
        try expect(typedReport.contains("요약 보고 본문") && typedReport.contains("groupID " + group.id.uuidString) &&
                   typedReport.contains("senderMemberID " + members[0].id.uuidString), "Body and reply IDs are in the prompt: \(typedReport)")
        try expect(!typedReport.contains("미확인 메시지가 있습니다"), "No pointer line")
        _ = engine.handleHook(["hook_event_name": "UserPromptSubmit", "session_id": ids[records[1].pid]!, "requestID": UUID().uuidString,
                               "agentPID": records[1].pid, "agentStarted": records[1].started, "prompt": typedReport])
        try expectEqual(try box.message(report.id)?.lastResult, "observed", "The observed prompt is the receipt")
        try expectNotNil(try box.message(report.id)?.acknowledgedAt)
        let afterReceipt = count()
        try await Task.sleep(for: .milliseconds(450))
        try expectEqual(count(), afterReceipt, "A committed message is never typed again")
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
            try expectEqual(try box.list(groupID: group.id, memberID: members[1].id).map(\.text), ["첫 번째 줄\n두 번째 줄"])
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
