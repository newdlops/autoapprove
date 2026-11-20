import Foundation
import AutoApproveCore

extension ApprovalTests {
    /// A message for a member that left the group stays in the mailbox but leaves the delivery queue,
    /// and the result is reported once: to the sender, or to the leader when the sender left too.
    @MainActor func testMessagesForRemovedMemberAreKeptAndReported() async throws {
        // Short path: the engine opens a Unix socket inside it.
        let directory = URL(fileURLWithPath: "/private/tmp/aa-removed-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory); try paths.prepare()
        func member(_ title: String) -> SessionGroupMember {
            SessionGroupMember(agent: .claude, title: title, cwd: "/fixture", conversationID: UUID().uuidString.lowercased(), providerHome: nil)
        }
        let leader = member("결제 총괄"), worker = member("api 정리"), gone = member("문서 검토"), goneSender = member("화면 점검")
        let group = SessionGroup(name: "fixture removed", members: [leader, worker], leaderMemberID: leader.id)
        try SessionGroupStore(directory: directory).save([group])
        let box = try SessionGroupMailbox(directory: directory)
        let toGone = try box.enqueue(groupID: group.id, senderID: worker.id, recipientID: gone.id, kind: .report, text: "fixture report",
                                     sourceKey: "report:" + UUID().uuidString)
        let orphan = try box.enqueue(groupID: group.id, senderID: goneSender.id, recipientID: gone.id, kind: .message, text: "fixture orphan")
        let live = try box.enqueue(groupID: group.id, senderID: leader.id, recipientID: worker.id, kind: .message, text: "fixture live")
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { [] }, isolateByDefault: true)
        defer { engine.stop() }
        engine.groupMailboxPollInterval = 0.1
        try engine.start(poll: false)
        func notices(_ id: UUID) throws -> [SessionGroupMessage] { try box.list(groupID: group.id, memberID: id).filter { $0.kind == .notice } }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, try notices(worker.id).isEmpty || notices(leader.id).isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        try expectEqual(try notices(worker.id).count, 1, "The sender that stayed is told")
        try expect(try notices(worker.id).first?.text.contains(toGone.id.uuidString) == true)
        try expectEqual(try notices(leader.id).count, 1, "When the sender left too, the leader is told")
        try expect(try notices(leader.id).first?.text.contains(orphan.id.uuidString) == true)
        for id in [toGone.id, orphan.id] {
            let kept = try box.message(id)
            try expect(kept != nil && kept?.acknowledgedAt == nil, "The message is kept, not deleted or acknowledged")
            try expectEqual(kept?.lastResult, "undelivered", "It leaves the delivery queue")
        }
        try expect(try box.message(live.id)?.lastResult != "undelivered", "A message for a current member is not parked")
        try await Task.sleep(for: .milliseconds(600))
        try expectEqual(try notices(worker.id).count + notices(leader.id).count, 2, "Each result is reported once")
    }
}
