import AutoApproveCore
import Foundation

extension ApprovalTests {
    @MainActor func testManagedSubgroupLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-subgroup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("codex").path
        let people = ["Root", "Branch", "Worker", "Peer", "Outside"].map {
            SessionGroupMember(agent: .codex, title: $0, cwd: "/project", conversationID: UUID().uuidString.lowercased(), providerHome: home)
        }
        let root = SessionGroup(name: "Root", members: Array(people.prefix(4)), leaderMemberID: people[0].id)
        let linked = try SessionGroup(name: "Linked").linkingGroupParent(root.id, connected: true)
        let engine = try ApprovalEngine(paths: .init(directory: directory), processReader: { [] }, isolateByDefault: true)
        defer { engine.stop() }
        let store = SessionGroupStore(directory: directory)
        try store.save([root, linked])
        func call(_ actor: Int, _ parent: UUID, _ args: JSONObject, tool: String = "manage_group_subgroup") async throws -> JSONObject {
            let session = people[actor].conversationID
            var request: JSONObject = ["tool": tool, "owner": UUID().uuidString, "agentKind": "codex", "conversationID": session,
                "codexCallerConversationID": session, "codexCallerSource": "codex_mcp_metadata", "codexCallerHome": home, "groupID": parent.uuidString]
            request.merge(args) { _, new in new }
            return try await engine.mcpAction(request)
        }
        func rejected(_ status: Int, _ actor: Int, _ group: UUID, _ args: JSONObject) async throws {
            do { _ = try await call(actor, group, args); throw AppError.message("Unexpected subgroup access") }
            catch let error as RemoteHTTPError { try expectEqual(error.status, status) }
        }
        func createdID(_ result: JSONObject) throws -> UUID {
            guard let id = (result["subgroupID"] as? String).flatMap(UUID.init(uuidString:)) else { throw AppError.message("Missing subgroup ID") }
            return id
        }
        let create: JSONObject = ["action": "create", "name": "Delivery", "memberIDs": people[1...3].map { $0.id.uuidString }, "leaderMemberID": people[1].id.uuidString]
        try await rejected(403, 2, root.id, create)
        try await rejected(403, 0, root.id, ["action": "create", "name": "Outside", "memberIDs": [people[4].id.uuidString]])
        let child = try createdID(await call(0, root.id, create))
        try expectEqual(try await call(0, root.id, create)["changed"] as? Bool, false)
        try await rejected(409, 0, root.id, create.merging(["memberIDs": [people[1].id.uuidString]]) { _, new in new })
        let persisted = try store.load()
        try expectEqual(persisted.first { $0.id == root.id }, root)
        try expectEqual(persisted.first { $0.id == child }?.leaderMemberIDs, [people[1].id])
        let topology = try await call(0, root.id, [:], tool: "get_group_topology")["groups"] as? [JSONObject]
        try expectEqual(topology?.first { $0["id"] as? String == child.uuidString }?["canManageSubgroup"] as? Bool, true)
        try expectEqual(topology?.first { $0["id"] as? String == linked.id.uuidString }?["canManageSubgroup"] as? Bool, false)
        let grand = try createdID(await call(1, child, ["action": "create", "name": "Nested", "memberIDs": people[2...3].map { $0.id.uuidString }]))
        let appoint: JSONObject = ["action": "appoint", "subgroupID": grand.uuidString, "leaderMemberID": people[2].id.uuidString]
        try expectEqual(try await call(0, root.id, appoint)["changed"] as? Bool, true)
        try expectEqual(try await call(1, child, appoint)["changed"] as? Bool, false)
        let dismiss = appoint.merging(["action": "dismiss"]) { _, new in new }
        try expectEqual(try await call(1, child, dismiss)["changed"] as? Bool, true)
        try expectEqual(try await call(0, root.id, dismiss)["changed"] as? Bool, false)
        try expectEqual(try await call(0, root.id, appoint)["changed"] as? Bool, true)
        let mailbox = try SessionGroupMailbox(directory: directory)
        func message(_ group: UUID) throws -> UUID {
            try mailbox.enqueue(groupID: group, senderID: people[1].id, recipientID: people[2].id, kind: .message, text: "fixture").id
        }
        let old = try message(child), kept = try message(grand)
        let dissolve: JSONObject = ["action": "dissolve", "subgroupID": child.uuidString]
        try await rejected(403, 0, root.id, ["action": "dissolve", "subgroupID": linked.id.uuidString])
        try expectEqual(try await call(0, root.id, dissolve)["changed"] as? Bool, true)
        try expectEqual(try await call(0, root.id, dissolve)["changed"] as? Bool, false)
        let after = try store.load()
        try expectEqual(after.first { $0.id == grand }?.subgroupParentID, root.id)
        try expectEqual(after.first { $0.id == grand }?.parentGroupIDs, [root.id])
        try expectEqual(after.first { $0.id == grand }?.leaderMemberIDs, [people[2].id])
        try expectEqual(after.first { $0.id == linked.id }, linked)
        try expectNil(after.first { $0.id == child })
        try expectEqual(try mailbox.message(old)?.lastResult, "superseded")
        try expect(try mailbox.message(kept)?.lastResult != "superseded")
    }
}
