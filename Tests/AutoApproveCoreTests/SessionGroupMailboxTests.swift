import Foundation
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif
import CSQLite

extension ApprovalTests {
    @MainActor func testUnconfirmedGroupMessagesExpireWithoutRemovingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = try SessionGroupMailbox(directory: directory, maximumPending: 3)
        let engine = try ApprovalEngine(paths: .init(directory: directory))
        defer { engine.stop() }
        try expectEqual(engine.groupMessageTTLMinutes, 120)
        try expectThrows(engine.setGroupMessageTTLMinutes(0))
        try engine.setGroupMessageTTLMinutes(180)
        let reopened = try ApprovalEngine(paths: .init(directory: directory))
        defer { reopened.stop() }
        try expectEqual(reopened.groupMessageTTLMinutes, 180)
        let group = UUID(), sender = UUID(), recipient = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let cutoff = now.addingTimeInterval(-7200)
        let old = try box.enqueue(groupID: group, senderID: sender, recipientID: recipient, kind: .question, text: "old", at: cutoff)
        let read = try box.enqueue(groupID: group, senderID: sender, recipientID: recipient, kind: .message, text: "read", at: cutoff)
        let fresh = try box.enqueue(groupID: group, senderID: sender, recipientID: recipient, kind: .message, text: "fresh", at: cutoff.addingTimeInterval(1))
        #if DEBUG
        let conversation = UUID().uuidString
        try box.recordSubmission(fresh.id, conversation: conversation, prompt: "original", at: now)
        try expectEqual(try box.pendingEnterPrompt(fresh.id, conversation: conversation), "original")
        try expectEqual(try box.claimSubmitEnter(fresh.id, conversation: conversation, prompt: "edited", manualQuestion: false), false)
        try expectEqual(try box.claimSubmitEnter(fresh.id, conversation: conversation, prompt: "original", manualQuestion: false), true)
        let reopenedBox = try SessionGroupMailbox(directory: directory)
        try expectNil(try reopenedBox.pendingEnterPrompt(fresh.id, conversation: conversation))
        try expectEqual(try reopenedBox.claimSubmitEnter(fresh.id, conversation: conversation, prompt: "original", manualQuestion: false), false)
        try box.releaseSubmitEnter(fresh.id, conversation: conversation, prompt: "original")
        try expectEqual(try reopenedBox.pendingEnterPrompt(fresh.id, conversation: conversation), "original")
        #endif
        try box.acknowledge([read.id], groupID: group, recipientID: recipient, at: now)
        try expectEqual(try box.nextExpiration(ttl: 7200), now)
        try box.expireUnconfirmed(createdThrough: cutoff)
        try box.noteAttempt(old.id, result: "direct_submitted", retryAt: now)
        try expectEqual(try box.pendingCount, 1)
        try expectEqual(try box.heads().map(\.id), [fresh.id])
        try expectEqual(try box.list(groupID: group, memberID: recipient).map(\.id), [fresh.id])
        let history = try box.list(groupID: group, memberID: recipient, includeAcknowledged: true)
        try expectEqual(history.map(\.id), [old.id, read.id, fresh.id])
        try expectEqual(history[0].json["state"] as? String, "expired")
        try expectEqual(history[1].acknowledgedAt, now)
        try expectEqual(try box.conversations(groupID: group).conversations.first?.waitExpired, true)
    }

    @MainActor func testSummaryMailboxPagesAndReceipts() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("aa-report-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory); try paths.prepare()
        let records = ProcessDiscovery.parse("""
        101121 1 fixture211 101121 101121 Wed Oct 28 12:00:00 2026 /fixture/codex
        101122 1 fixture212 101122 101122 Wed Oct 28 12:00:00 2026 /fixture/codex
        """)
        let sessions = records.map { AgentSession(id: $0.key, agent: .codex, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm) }
        let ids = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, UUID().uuidString.lowercased()) })
        let members = sessions.map { session -> SessionGroupMember in
            var member = SessionGroupMember(agent: .codex, title: "fixture", cwd: "/project", conversationID: ids[session.pid]!, providerHome: "/fixture/home")
            member.runtimeID = session.id; return member
        }
        let group = SessionGroup(name: "reports", members: members, leaderMemberID: members[0].id)
        try SessionGroupStore(directory: directory).save([group])
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { records },
            codexGroupReader: { record in ids[record.pid].map { .init(threadID: $0, database: "/fixture/home/state.sqlite") } })
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: records)
        let box = try SessionGroupMailbox(directory: directory)
        func call(_ tool: String, _ args: JSONObject = [:], caller: Int = 0) async throws -> JSONObject {
            var object: JSONObject = ["owner": UUID().uuidString, "tool": tool, "groupID": group.id.uuidString, "sessionID": sessions[caller].id]
            object.merge(args) { _, value in value }
            return try await engine.mcpAction(object)
        }
        func mailbox(_ args: JSONObject) async throws -> JSONObject {
            let status = try await call("get_group_status", args)
            guard let result = (status["groups"] as? [JSONObject])?.first?["mailbox"] as? JSONObject else {
                throw AppError.message("missing mailbox")
            }
            return result
        }
        func bytes(_ value: JSONObject) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        var messages: [SessionGroupMessage] = []
        var sent: [SessionGroupMessage] = []
        for count in [0, 3, 4, 10, 20, 21] {
            while messages.count < count {
                let index = messages.count
                let body = "결과 \(index)\n" + String(repeating: "👩🏽‍💻한글 ", count: 120) + "보류"
                messages.append(try box.enqueue(groupID: group.id, senderID: members[1].id, recipientID: members[0].id,
                    kind: index == 3 ? .question : .message, text: body))
                sent.append(try box.enqueue(groupID: group.id, senderID: members[0].id, recipientID: members[1].id, kind: .message, text: body))
            }
            let full = try await mailbox(["mailboxView": "full"])
            let normal = try await mailbox([:])
            let summary = try await mailbox(["mailboxView": "summary"])
            try expectEqual(try bytes(normal), try bytes(full))
            for (key, source) in [("inbox", messages), ("outbox", sent)] {
                let page = summary[key] as? [JSONObject] ?? []
                try expectEqual(page.compactMap { $0["messageID"] as? String }, source.prefix(3).map { $0.id.uuidString })
                try expectEqual(summary[key + "HasMore"] as? Bool, count > 3)
                try expectEqual((full[key] as? [JSONObject])?.count, min(20, count))
                try expectEqual(full[key + "HasMore"] as? Bool, count > 20)
                if let row = page.first, let message = source.first {
                    let preview = row["preview"] as? String ?? ""
                    try expect(!preview.isEmpty && preview.utf8.count <= 120 && !preview.contains("\n"))
                    try expectEqual(row["textBytes"] as? Int, message.text.utf8.count)
                    try expectEqual(row["truncated"] as? Bool, true)
                    try expectNil(row["text"])
                    try expectEqual(row[key == "inbox" ? "senderMemberID" : "memberID"] as? String, members[1].id.uuidString)
                }
            }
            if count == 10 { print("Mailbox fixture UTF-8 bytes full=\(try bytes(full).count) summary=\(try bytes(summary).count)") }
            try expectEqual(try box.pendingCount, count * 2)
        }
        for invalid: Any in ["extra" as Any, 1, NSNull()] {
            do { _ = try await mailbox(["mailboxView": invalid]); throw AppError.message("accepted invalid mailboxView") }
            catch let error as RemoteHTTPError { try expectEqual(error.status, 400) }
        }
        let answer = try await call("get_group_messages", ["unansweredOnly": true])
        try expectEqual((answer["messages"] as? [JSONObject])?.first?["messageID"] as? String, messages[3].id.uuidString)
        for (direction, source) in [("inbox",messages), ("outbox",sent)] {
            let next = try await call("get_group_messages", ["direction": direction, "afterSequence": source[2].sequence])
            try expectEqual((next["messages"] as? [JSONObject])?.first?["messageID"] as? String, source[3].id.uuidString)
        }
        let id = messages[3].id.uuidString
        _ = try await call("ack_group_messages", ["messageIDs": [id]])
        let original = try await call("get_group_messages", ["messageID": id])
        try expectEqual((original["messages"] as? [JSONObject])?.first?["text"] as? String, messages[3].text)
        do { _ = try await call("get_group_messages", ["messageID": id], caller: 1); throw AppError.message("read another inbox") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 404) }
        let outbox = try await call("get_group_messages", ["messageID": id, "direction": "outbox"], caller: 1)
        try expectEqual((outbox["messages"] as? [JSONObject])?.first?["text"] as? String, messages[3].text)
        #if DEBUG
        try compareReportDelivery(box, group: group, members: members)
        #endif
    }

    #if DEBUG
    private func compareReportDelivery(_ box: SessionGroupMailbox, group: SessionGroup, members: [SessionGroupMember]) throws {
        let result = "결과: 테스트 실패 · 배포 보류"
        let conversation = UUID().uuidString
        func store(_ body: String) throws -> SessionGroupMessage {
            try box.enqueue(groupID: group.id, senderID: members[1].id, recipientID: members[0].id, kind: .report, text: body)
        }
        let delimiter = " · 그룹 메시지 본문 · "
        func firstLineReference(_ message: SessionGroupMessage, direct: String) -> String {
            guard message.kind == .report, let first = message.text.split(whereSeparator: \.isNewline).first,
                  first.hasPrefix("결과: "), let range = direct.range(of: delimiter) else { return direct }
            let reference = "원문 " + String(message.text.utf8.count) + "바이트 · get_group_messages(groupID: " +
                group.id.uuidString + ", messageID: " + message.id.uuidString + ", includeAcknowledged: true)"
            let candidate = String(direct[..<range.lowerBound]) + " · " + first + delimiter + reference
            return candidate.utf8.count <= 4096 ? candidate : direct
        }
        let seed = result + "\n테스트 👩🏽‍💻\n보류"
        let overhead = try store(seed).terminalPrompt(senderTitle: "fixture").utf8.count
        for length in [1500, 1501, 4096, 4097] {
            let body = seed + String(repeating: "x", count: length - overhead)
            let message = try store(body)
            let direct = message.terminalPrompt(senderTitle: "fixture")
            let candidate = firstLineReference(message, direct: direct)
            let claude = message.terminalPrompt(senderTitle: String(repeating: "👩🏽‍💻", count: 100), recipientAgent: .claude)
            try expect(claude.utf16.count <= 500 && message.isReferencePrompt(claude))
            try expectEqual(SessionGroupMessage.terminalMessageID(claude), message.id)
            try expectEqual(message.isReferencePrompt(direct), length > 4096)
            if length <= 4096 { try expectEqual(direct.utf8.count, length) }
            try expect(candidate.utf8.count <= 4096 && message.isReferencePrompt(candidate))
            for prompt in [direct, candidate] {
                try expectEqual(SessionGroupMessage.terminalMessageID(prompt), message.id)
                try box.recordSubmission(message.id, conversation: conversation, prompt: prompt)
                try expect(try box.confirmedPrompt(message.id, conversation: conversation, prompt: prompt))
                try expect(!(try box.confirmedPrompt(message.id, conversation: conversation, prompt: prompt + "\n")))
                try expect(try box.claimSubmitEnter(message.id, conversation: conversation, prompt: prompt, manualQuestion: false))
                try expect(try box.confirmedPrompt(message.id, conversation: conversation, prompt: prompt + "\n"))
                try expect(!(try box.confirmedPrompt(message.id, conversation: conversation, prompt: prompt + "\n추가")))
                try expect(!(try box.confirmedPrompt(message.id, conversation: conversation, prompt: prompt + "\n\n")))
            }
            let stored = try box.message(message.id)
            try expectEqual(stored?.text, body)
            try expectEqual(stored?.acknowledgedAt, nil)
            print("Report fixture bytes boundary=\(length) current=\(direct.utf8.count) firstLineReference=\(candidate.utf8.count) bodyLookup=\(body.utf8.count)")
        }
        for body in [String(repeating: "테스트\n", count: 300) + "마지막 결과: 실패", "결과: " + String(repeating: "👩🏽‍💻", count: 500)] {
            let message = try store(body)
            let direct = message.terminalPrompt(senderTitle: "fixture")
            try expectEqual(firstLineReference(message, direct: direct), direct)
            try expectEqual(try box.message(message.id)?.text, body)
        }
    }
    #endif

    @MainActor func testGroupReportRequiresRecipientAcknowledgement() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("aa-report-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory); try paths.prepare()
        let records = ProcessDiscovery.parse("""
        101121 1 fixture211 101121 101121 Wed Oct 28 12:00:00 2026 /fixture/codex
        101122 1 fixture212 101122 101122 Wed Oct 28 12:00:00 2026 /fixture/codex
        """)
        let sessions = records.map { AgentSession(id: $0.key, agent: .codex, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm) }
        let ids = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, UUID().uuidString.lowercased()) })
        let members = sessions.map { session -> SessionGroupMember in
            var member = SessionGroupMember(agent: .codex, title: "fixture", cwd: "/project", conversationID: ids[session.pid]!, providerHome: "/fixture/home")
            member.runtimeID = session.id; return member
        }
        let group = SessionGroup(name: "reports", members: members, leaderMemberID: members[0].id)
        try SessionGroupStore(directory: directory).save([group])
        let assignment = SessionGroupAssignment(groupID: group.id, workerMemberID: members[1].id, parentMemberID: members[0].id,
            workerSessionID: sessions[1].id, parentSessionID: sessions[0].id, task: "fixture", sentAt: Date().addingTimeInterval(-5))
        var state = SessionGroupOrchestration(assignments: [assignment]); state.markDelivered(assignment.id)
        state.complete(workerSessionID: sessions[1].id, completion: .init(id: "finished", summary: "작업 완료"))
        try AuditStore(path: paths.database).set(SessionGroupOrchestration.storeKey, String(decoding: JSONEncoder().encode(state), as: UTF8.self))
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { records },
            codexGroupReader: { record in ids[record.pid].map { .init(threadID: $0, database: "/fixture/home/thread_history_1.sqlite") } }, isolateByDefault: true)
        defer { engine.stop() }
        engine.groupDeliveryInterval = 0.05
        engine.updateDiscovery(sessions, records: records); try engine.start(poll: false)
        let box = try SessionGroupMailbox(directory: directory)
        for _ in 0..<100 {
            if try box.pendingCount == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let messages = try box.list(groupID: group.id, memberID: members[0].id)
        try expectEqual(messages.count, 1); let message = messages[0]
        try expectEqual(message.kind, .report); try expect(message.text.contains("작업 완료"))
        func call(_ tool: String, caller: Int = 0, extra: JSONObject = [:]) async throws -> JSONObject {
            var args: JSONObject = ["owner": UUID().uuidString, "tool": tool, "sessionID": sessions[caller].id, "groupID": group.id.uuidString]
            args.merge(extra) { _, new in new }; return try await engine.mcpAction(args)
        }
        for invalid: Any in ["extra" as Any, 1, NSNull()] {
            do { _ = try await call("get_group_status", extra: ["reportView": invalid]); throw AppError.message("Invalid reportView accepted") }
            catch let error as RemoteHTTPError { try expectEqual(error.status, 400) }
        }
        for mailbox in ["full", "summary"] {
            func report(_ view: String?) async throws -> JSONObject {
                var args: JSONObject = ["mailboxView": mailbox]
                if let view { args["reportView"] = view }
                let status = try await call("get_group_status", extra: args)
                let groups = status["groups"] as! [JSONObject]
                return (groups[0]["reports"] as! [JSONObject])[0]
            }
            let full = try await report(nil), explicit = try await report("full"), compact = try await report("compact")
            try expectEqual(Set(full.keys), Set(explicit.keys))
            try expectEqual(Set(compact.keys), Set(["taskID", "workerMemberID"]))
            try expectEqual(compact["taskID"] as? String, full["taskID"] as? String)
            try expectEqual(full["summary"] as? String, "작업 완료")
        }
        var sample = assignment
        sample.summary = nil
        let worker = sample.workerMemberID.uuidString
        let current: JSONObject = ["id": sample.id.uuidString, "task": sample.task, "summary": NSNull()]
        try expectNil(sample.statusReport(currentTasks: [worker: current])["task"])
        for changed: JSONObject in [["id":UUID().uuidString], ["summary":""], ["task":"different"]] {
            let item = sample.statusReport(currentTasks: [worker: current.merging(changed) { _, new in new }])
            try expectEqual(item["task"] as? String, sample.task)
            try expect(item["summary"] is NSNull)
        }
        try expect(sample.statusReport(currentTasks: [UUID().uuidString: current])["summary"] is NSNull)
        sample.summary = "가"
        try expectEqual(sample.statusReport(currentTasks: [worker: current.merging(["summary":"가".decomposedStringWithCanonicalMapping]) { _, new in new }])["summary"] as? String, "가")
        _ = try await call("get_group_status"); _ = try await call("get_group_messages")
        try expectEqual(try engine.sessionGroupAssignments().first?.status, .completed, "Reading is not a receipt")
        do { _ = try await call("ack_group_messages", caller: 1, extra: ["messageIDs": [message.id.uuidString]]); throw AppError.message("Worker acknowledged its own report") }
        catch is RemoteHTTPError { }
        for _ in 0..<2 { _ = try await call("ack_group_messages", extra: ["messageIDs": [message.id.uuidString]]) }
        try expectEqual(try engine.sessionGroupAssignments().first?.status, .reported)
        try await Task.sleep(for: .milliseconds(150))
        try expectEqual(try box.list(groupID: group.id, memberID: members[0].id, includeAcknowledged: true).count, 1)
        try expectEqual(try box.pendingCount, 0)
    }

    func testGroupMailboxDurabilityReceiptsAndOrdering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-mailbox-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let group = UUID(), sender = UUID(), peer = UUID(), receiver = UUID(), id = UUID()
        var box: SessionGroupMailbox? = try SessionGroupMailbox(directory: directory, maximumPending: 2)
        let first = try box!.enqueue(id: id, groupID: group, senderID: sender, recipientID: receiver, kind: .question, text: "first")
        let second = try box!.enqueue(groupID: group, senderID: peer, recipientID: receiver, kind: .reply, text: "second")
        try expect(first.sequence < second.sequence)
        try expectEqual(try box!.heads().map(\.id), [id])
        try expectEqual(try box!.enqueue(id: id, groupID: group, senderID: sender, recipientID: receiver, kind: .question, text: "first").id, id)
        try expectEqual(try box!.enqueue(groupID: group, senderID: peer, recipientID: receiver, kind: .reply, text: "second").id, second.id)
        for (key, body) in [(id, "changed"), (UUID(), "full")] {
            do { _ = try box!.enqueue(id: key, groupID: group, senderID: sender, recipientID: receiver, kind: .question, text: body); throw AppError.message("Conflicting/full mailbox accepted a message") }
            catch is RemoteHTTPError { }
        }
        try box!.noteAttempt(id, result: "direct_attempting", retryAt: .distantPast, increment: true)
        box = nil // Restart after an uncertain terminal write, before any ACK.
        box = try SessionGroupMailbox(directory: directory, maximumPending: 2)
        try expectEqual(try box!.pendingCount, 2)
        let reopened = try box!.list(groupID: group, memberID: receiver)
        try expectEqual(reopened.map(\.id), [id, second.id])
        try expectEqual(reopened[0].lastResult, "direct_attempting")
        try expectNil(reopened[0].acknowledgedAt)
        try expectEqual(try box!.heads().map(\.id), [second.id],
                        "An uncertain direct submission stays readable without blocking later delivery or being retried")
        // A lost read response and repeated read cannot consume messages.
        _ = try box!.list(groupID: group, memberID: receiver)
        try expectEqual(try box!.pendingCount, 2)
        do { try box!.acknowledge([id, UUID()], groupID: group, recipientID: receiver); throw AppError.message("Partial ACK committed") }
        catch is RemoteHTTPError { }
        do { try box!.acknowledge([id], groupID: group, recipientID: sender); throw AppError.message("Sender ACKed its receiver") }
        catch is RemoteHTTPError { }
        try expectEqual(try box!.pendingCount, 2)
        try box!.acknowledge([id], groupID: group, recipientID: receiver)
        try box!.acknowledge([id], groupID: group, recipientID: receiver)
        try expectEqual(try box!.heads().map(\.id), [second.id])
        // An in-flight notifier finishing after the ACK cannot resurrect it.
        try box!.noteAttempt(id, result: "unknown", retryAt: .distantPast)
        try expect(try box!.message(id)?.acknowledgedAt != nil)
        box = nil; box = try SessionGroupMailbox(directory: directory)
        let repeated = try box!.enqueue(id: id, groupID: group, senderID: sender, recipientID: receiver, kind: .question, text: "first")
        try expect(repeated.acknowledgedAt != nil)
        try expectEqual(try box!.pendingCount, 1)
        try expectEqual(try box!.list(groupID: group, memberID: receiver, includeAcknowledged: true, after: first.sequence).map(\.id), [second.id])
        try expect(try box!.list(groupID: UUID(), memberID: receiver).isEmpty)
        let report = try box!.enqueue(groupID: group, senderID: sender, recipientID: receiver, kind: .report, text: "report", sourceKey: "report:fixture")
        let retry = try box!.enqueue(groupID: group, senderID: sender, recipientID: receiver, kind: .report, text: "renamed title", sourceKey: "report:fixture")
        try expectEqual(retry.id, report.id); try expectEqual(retry.text, "report")
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("group-messages.sqlite").path)[.posixPermissions] as? NSNumber
        try expectEqual(permissions?.intValue, 0o600)
    }

    @MainActor func testGroupClaudeReplyWithoutMCP() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("aa-reply-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { _ in [] },
                                        processReader: { [] }, isolateByDefault: true)
        defer { engine.stop() }
        let box = try SessionGroupMailbox(directory: directory)
        let group = UUID(), sender = UUID(), recipient = UUID(), conversation = UUID().uuidString.lowercased()
        let question = try box.enqueue(groupID: group, senderID: sender, recipientID: recipient, kind: .question, text: "test")
        let prompt = "[AutoApprove 그룹 전달 " + question.id.uuidString + "] fixture question"
        var db: OpaquePointer?
        try expectEqual(sqlite3_open(directory.appendingPathComponent("group-messages.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func addSubmission(id: UUID, prompt: String) throws {
            let insert = "INSERT INTO group_submissions VALUES ('\(id.uuidString)','\(conversation)','\(prompt)',0)"
            try expectEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        }
        try addSubmission(id: question.id, prompt: prompt)

        func hook(_ event: String, conversation: String, field: String, value: String) {
            _ = engine.handleHook(["hook_event_name": event, "session_id": conversation,
                                   "requestID": UUID().uuidString, field: value])
        }
        let other = UUID().uuidString
        hook("UserPromptSubmit", conversation: other, field: "prompt", value: prompt)
        hook("Stop", conversation: other, field: "last_assistant_message", value: "wrong conversation")
        try expectNil(try box.message(sourceKey: "answer:" + question.id.uuidString))
        hook("UserPromptSubmit", conversation: conversation, field: "prompt", value: prompt)
        try expect(try box.message(question.id)?.acknowledgedAt != nil)
        hook("UserPromptSubmit", conversation: conversation, field: "prompt", value: "local user input")
        hook("Stop", conversation: conversation, field: "last_assistant_message", value: "private")
        try expectNil(try box.message(sourceKey: "answer:" + question.id.uuidString))
        hook("UserPromptSubmit", conversation: conversation, field: "prompt", value: prompt)
        hook("Stop", conversation: conversation, field: "last_assistant_message", value: "replayed input")
        try expectNil(try box.message(sourceKey: "answer:" + question.id.uuidString))
        let second = try box.enqueue(groupID: group, senderID: sender, recipientID: recipient, kind: .question, text: "next")
        let secondPrompt = "[AutoApprove 그룹 전달 " + second.id.uuidString + "] second"
        try addSubmission(id: second.id, prompt: secondPrompt)
        let body = "첫 번째 줄\n" + String(repeating: "보존 ", count: 1600)
        hook("UserPromptSubmit", conversation: conversation, field: "prompt", value: secondPrompt)
        hook("Stop", conversation: conversation, field: "last_assistant_message", value: body)
        hook("Stop", conversation: conversation, field: "last_assistant_message", value: "duplicate")
        let replies = try box.list(groupID: group, memberID: sender)
        try expectEqual(replies.count, 1)
        try expectEqual(replies.first?.text, body)
        try expectEqual(replies.first?.sourceKey, "answer:" + second.id.uuidString)
        try expect(try box.remindIfDue(question, before: Date()))
        let reopened = try SessionGroupMailbox(directory: directory)
        try expect(!(try reopened.remindIfDue(question, before: Date())))
        try expect(!(try reopened.remindIfDue(second, before: Date())))
        let followup = try reopened.message(sourceKey: "followup:" + question.id.uuidString)
        guard let followup else { throw AppError.message("Missing question follow-up") }
        try reopened.noteAttempt(followup.id, result: "not_started", retryAt: .distantFuture)
        let currentSender = UUID()
        let next = try reopened.enqueue(groupID: group, senderID: currentSender, recipientID: recipient, kind: .question, text: "queued behind reminder")
        try reopened.reconcileSenders(group: group, members: [currentSender, recipient])
        try expectEqual(try reopened.message(followup.id)?.lastResult, "superseded")
        try expectNil(try reopened.message(followup.id)?.acknowledgedAt)
        try expectEqual(try reopened.heads().first { $0.recipientID == recipient }?.id, next.id)
        try expectEqual(try reopened.pendingReplies(group: group, member: recipient, senders: [currentSender]).map(\.id), [next.id])
        try reopened.acknowledge([next.id], groupID: group, recipientID: recipient)
        try expect(try reopened.remindIfDue(next, before: Date()))
        try reopened.reconcileSenders(group: group, members: [currentSender, sender, recipient])
        try expectNil(try reopened.message(sourceKey: "followup:" + question.id.uuidString))
        let stale = try reopened.enqueue(groupID: group, senderID: sender, recipientID: sender, kind: .notice, text: "delay", sourceKey: "stalled:" + second.id.uuidString)
        try reopened.reconcileSenders(group: group, members: [currentSender, sender, recipient])
        try expectEqual(try reopened.message(stale.id)?.lastResult, "superseded")
        let uncertain = try reopened.enqueue(groupID: group, senderID: currentSender, recipientID: recipient, kind: .message, text: "uncertain input")
        try addSubmission(id: uncertain.id, prompt: "fixture")
        try reopened.noteAttempt(uncertain.id, result: "direct_unknown", retryAt: .distantFuture)
        try expect(!(try reopened.stalledForSenders(createdBefore: .distantPast, uncertainBefore: .distantPast)).contains { $0.id == uncertain.id })
        try expect((try reopened.stalledForSenders(createdBefore: .distantPast, uncertainBefore: .distantFuture)).contains { $0.id == uncertain.id })
        let warning = try reopened.enqueue(groupID: group, senderID: currentSender, recipientID: currentSender, kind: .notice, text: "uncertain", sourceKey: "uncertain:" + uncertain.id.uuidString)
        try expect(!(try reopened.stalledForSenders(createdBefore: .distantPast, uncertainBefore: .distantFuture)).contains { $0.id == uncertain.id })
        try reopened.acknowledge([uncertain.id], groupID: group, recipientID: recipient)
        try reopened.reconcileSenders(group: group, members: [currentSender, sender, recipient])
        try expectEqual(try reopened.message(warning.id)?.lastResult, "superseded")
        let nextReminder = try reopened.message(sourceKey: "followup:" + next.id.uuidString)
        if let nextReminder { try reopened.acknowledge([nextReminder.id], groupID: group, recipientID: recipient) }
        try expect(try reopened.remindIfDue(question, before: Date()))
        guard let renewed = try reopened.message(sourceKey: "followup:" + question.id.uuidString) else { throw AppError.message("Missing renewed reminder") }
        let retryPrompt = "[AutoApprove 그룹 전달 " + renewed.id.uuidString + "] follow up"
        try addSubmission(id: renewed.id, prompt: retryPrompt)
        hook("UserPromptSubmit", conversation: conversation, field: "prompt", value: retryPrompt)
        hook("Stop", conversation: conversation, field: "last_assistant_message", value: "Recovered answer")
        let resolved = try reopened.conversations(groupID: group).conversations
        try expectEqual(resolved.first { $0.id == question.id }?.answer?.text, "Recovered answer")
        try expectEqual(resolved.filter { $0.answer == nil }.map(\.id), [next.id])
        try expectEqual(try reopened.inboxOperations(groupID: group)[recipient]?.unacknowledgedCount, 0)
    }

    func testGroupMailboxRefusesCorruptStorage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-mailbox-corrupt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("group-messages.sqlite"), original = Data("not a database".utf8)
        try original.write(to: path)
        var rejected = false
        do { _ = try SessionGroupMailbox(directory: directory) } catch { rejected = true }
        try expect(rejected); try expectEqual(try Data(contentsOf: path), original)
    }
}
