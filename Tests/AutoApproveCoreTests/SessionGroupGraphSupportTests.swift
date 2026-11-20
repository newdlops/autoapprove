import Foundation
import AutoApproveCore

private final class RegistryStatus: @unchecked Sendable { var value = "idle" }

extension ApprovalTests {
    /// A custom Claude status line hides the idle composer. Claude's own registry fills in idle and
    /// busy, but never a waiting request, which must still be read from the screen.
    @MainActor func testClaudeRegistryStatusFillsUnreadableScreen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-registry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        1 0 ?? 1 0 Tue Sep 22 09:00:00 2026 /sbin/launchd
        20 1 ttys041 20 20 Tue Sep 22 09:00:00 2026 claude
        """)
        let status = RegistryStatus()
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { rows in
            rows.filter { $0.agent == .claude }.map { .init(processID: $0.key, kind: "interactive", sessionID: "fixture-conversation", status: status.value) }
        }, processReader: { records })
        defer { engine.stop() }
        guard let record = records.first(where: { $0.pid == 20 }) else { throw AppError.message("fixture record missing") }
        var session = AgentSession(id: record.key, agent: .claude, pid: 20, started: record.started, tty: "/dev/ttys041", cwd: "/fixture", terminal: .iterm)
        session.channel = .terminalScreen
        let unreadable = "fixture | main | model | ctx 12%\n⏵⏵ auto mode on (shift+tab to cycle)"
        try expectEqual(ActivityDetector.detect(unreadable, agent: .claude).phase, .unknown, "The fixture screen must be unreadable")
        func observe(_ value: String, _ generation: String) -> SessionPhase? {
            status.value = value
            engine.updateDiscovery([session], records: records)
            engine.receiveScreen(sessionID: session.id, raw: unreadable, generation: generation, source: .terminalScreen)
            return engine.snapshot.sessions.first { $0.id == session.id }?.phase
        }
        try expectEqual(observe("idle", "g1"), .idle)
        try expectEqual(observe("busy", "g2"), .working)
        try expectEqual(observe("waiting", "g3"), .unknown, "A waiting request is never inferred from the registry")
        try expectEqual(observe("shell", "g4"), .unknown)
    }

    /// Naming is asked once: the leader names everyone, or each member names itself without a leader.
    /// The request is a system notice, so it never counts as an unacknowledged group message.
    @MainActor func testGroupNicknameRequestIsSentOncePerMember() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-nickname-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { _ in [] }, processReader: { [] })
        defer { engine.stop() }
        func member(_ title: String) -> SessionGroupMember {
            SessionGroupMember(agent: .claude, title: title, cwd: "/fixture/fundservice", conversationID: UUID().uuidString.lowercased(), providerHome: nil)
        }
        let led = [member("터미널 제목 미확인"), member("터미널 제목 미확인"), member("결제 PR 리뷰")]
        let leaderless = [member("터미널 제목 미확인"), member("터미널 제목 미확인")]
        let withLeader = SessionGroup(name: "fixture led", members: led, leaderMemberID: led[0].id)
        let peers = SessionGroup(name: "fixture peers", members: leaderless)
        try SessionGroupStore(directory: directory).save([withLeader, peers])
        let box = try SessionGroupMailbox(directory: directory)

        try expectEqual(try engine.requestSessionGroupNicknames(groupID: withLeader.id, memberIDs: led.map(\.id)), 1)
        let notices = try box.list(groupID: withLeader.id, memberID: led[0].id).filter { $0.kind == .notice }
        try expectEqual(notices.count, 1)
        try expect(led.allSatisfy { notices[0].text.contains($0.id.uuidString) }, "The leader's request lists every member")
        try expect(notices[0].text.contains("set_group_member_title"))
        try expectEqual(try engine.requestSessionGroupNicknames(groupID: withLeader.id, memberIDs: led.map(\.id)), 0, "Asked members are not asked again")
        let added = member("터미널 제목 미확인")
        var grown = withLeader; grown.members.append(added)
        try SessionGroupStore(directory: directory).save([grown, peers], expected: [withLeader, peers])
        try expectEqual(try engine.requestSessionGroupNicknames(groupID: grown.id, memberIDs: grown.members.map(\.id)), 1)
        let second = try box.list(groupID: grown.id, memberID: led[0].id).filter { $0.kind == .notice }.last
        try expect(second?.text.contains(added.id.uuidString) == true && second?.text.contains(led[1].id.uuidString) == false,
                   "A later request lists only the new member")

        try expectEqual(try engine.requestSessionGroupNicknames(groupID: peers.id, memberIDs: leaderless.map(\.id)), 2)
        for peer in leaderless {
            let own = try box.list(groupID: peers.id, memberID: peer.id).filter { $0.kind == .notice }
            try expectEqual(own.count, 1); try expect(own[0].text.contains(peer.id.uuidString))
        }
        try expectEqual(try box.inboxOperations(groupID: withLeader.id)[led[0].id]?.unacknowledgedCount ?? 0, 0,
                        "A naming notice is not an unacknowledged group message")
    }

    func testMailboxDataVersionChangesOnlyAfterAnotherConnectionCommits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-data-version-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try SessionGroupMailbox(directory: directory), reader = try SessionGroupMailbox(directory: directory)
        let initial = try reader.dataVersion
        try expectEqual(try reader.dataVersion, initial, "Reading alone does not change the version")
        _ = try writer.enqueue(groupID: UUID(), senderID: UUID(), recipientID: UUID(), kind: .message, text: "fixture")
        try expect(try reader.dataVersion != initial, "A commit on another connection changes the version")
    }
}
