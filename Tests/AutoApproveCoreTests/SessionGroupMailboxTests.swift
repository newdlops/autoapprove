import Foundation
import AutoApproveCore

extension ApprovalTests {
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
        try box!.noteAttempt(id, result: "attempting", retryAt: .distantPast, increment: true)
        box = nil // Restart after an uncertain terminal write, before any ACK.
        box = try SessionGroupMailbox(directory: directory, maximumPending: 2)
        try expectEqual(try box!.pendingCount, 2)
        let reopened = try box!.list(groupID: group, memberID: receiver)
        try expectEqual(reopened.map(\.id), [id, second.id])
        try expectEqual(reopened[0].lastResult, "attempting")
        try expectNil(reopened[0].acknowledgedAt)
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
