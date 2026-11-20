import Foundation
import AutoApproveCore

extension ApprovalTests {
    /// A sender learns once that its message is stuck; reports sent on a worker's behalf and the
    /// notice itself never produce another notice, so blocked senders cannot start a loop.
    @MainActor func testStalledGroupMessageNotifiesItsSenderOnce() async throws {
        // Short path: the engine opens a Unix socket inside it.
        let directory = URL(fileURLWithPath: "/private/tmp/aa-stall-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory); try paths.prepare()
        func member(_ title: String) -> SessionGroupMember {
            SessionGroupMember(agent: .claude, title: title, cwd: "/fixture", conversationID: UUID().uuidString.lowercased(), providerHome: nil)
        }
        let leader = member("결제 총괄"), worker = member("api 정리")
        let group = SessionGroup(name: "fixture stall", members: [leader, worker], leaderMemberID: leader.id)
        try SessionGroupStore(directory: directory).save([group])
        let box = try SessionGroupMailbox(directory: directory)
        let old = Date().addingTimeInterval(-20 * 60)
        // No live terminal matches these members, so nothing can be typed: the messages stay held.
        let question = try box.enqueue(groupID: group.id, senderID: worker.id, recipientID: leader.id, kind: .question, text: "fixture question", at: old)
        let report = try box.enqueue(groupID: group.id, senderID: worker.id, recipientID: leader.id, kind: .report, text: "fixture report",
                                     sourceKey: "report:" + UUID().uuidString, at: old)
        let fresh = try box.enqueue(groupID: group.id, senderID: leader.id, recipientID: worker.id, kind: .message, text: "fixture fresh")
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { [] }, isolateByDefault: true)
        defer { engine.stop() }
        engine.groupMailboxPollInterval = 0.1
        try engine.start(poll: false)
        func notices() throws -> [SessionGroupMessage] {
            try box.list(groupID: group.id, memberID: worker.id).filter { $0.kind == .notice } +
                (try box.list(groupID: group.id, memberID: leader.id).filter { $0.kind == .notice })
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, try notices().isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let first = try notices()
        try expectEqual(first.count, 1, "Only the agent-sent question that waited past the threshold is reported")
        try expectEqual(first.first?.recipientID, worker.id, "The notice goes to the sender")
        try expect(first.first?.text.contains(question.id.uuidString) == true && first.first?.text.contains("결제 총괄") == true)
        try expect(first.first?.text.contains("다시 보내지 마세요") == true)
        try expect(!(first.first?.text.contains(report.id.uuidString) ?? true) && !(first.first?.text.contains(fresh.id.uuidString) ?? true))
        try await Task.sleep(for: .milliseconds(600))
        try expectEqual(try notices().count, 1, "Each stuck message is reported once, and a notice is never reported itself")
        try expectEqual(try box.inboxOperations(groupID: group.id)[worker.id]?.unacknowledgedCount ?? 0, 1,
                        "The notice does not add to the worker's unacknowledged group messages")
    }
}
