import AutoApproveCore
import CSQLite
import Foundation

extension ApprovalTests {
    @MainActor func testCodexGroupDelegatedMCP() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("delegated-mcp-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.resolvingSymlinksInPath().path
        var connection: OpaquePointer?
        try expectEqual(sqlite3_open(home + "/state_5.sqlite", &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        func update(_ sql: String) throws {
            try expectEqual(sqlite3_exec(connection, sql, nil, nil, nil), SQLITE_OK)
        }
        try update("""
            CREATE TABLE threads(id TEXT PRIMARY KEY, thread_source TEXT, source TEXT, archived INTEGER DEFAULT 0);
            CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY, status TEXT);
            """)
        func spawn(_ parent: String) throws -> String {
            let id = UUID().uuidString.lowercased()
            try update("""
                INSERT INTO threads(id,thread_source,source) VALUES('\(id)','subagent','{"subagent":{"thread_spawn":{"parent_thread_id":"\(parent)"}}}');
                INSERT INTO thread_spawn_edges VALUES('\(parent)','\(id)','open');
                """)
            return id
        }
        let root = UUID().uuidString.lowercased(), worker = UUID().uuidString.lowercased()
        try update("INSERT INTO threads(id,thread_source,source) VALUES('\(root)',NULL,'vscode'),('\(worker)','user','cli')")
        let child = try spawn(root), nested = try spawn(child), workerChild = try spawn(worker)
        let record = ProcessDiscovery.parse("141843 1 fixture843 141843 141843 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
                                   tty: "/dev/" + record.tty, cwd: "/fixture", terminal: .iterm)
        let prompt = "Codex\n› Ask Codex to do anything\n  ? for shortcuts"
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: prompt) }) },
                                        approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, _ in .sent })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter],
                                        codexGroupReader: { _ in .init(threadID: worker, database: home + "/thread_history_1.sqlite") }, isolateByDefault: true)
        defer { engine.stop() }
        engine.updateDiscovery([session], records: [record])
        await engine.connectScreenHost(.iterm)
        let leader = SessionGroupMember(agent: .codex, title: "Leader", cwd: "/fixture", conversationID: root, providerHome: home)
        let member = SessionGroupLiveSession(session: session, conversationID: worker, providerHome: home).member
        let peerID = UUID().uuidString.lowercased()
        let peer = SessionGroupMember(agent: .codex, title: "Peer", cwd: "/fixture", conversationID: peerID, providerHome: home)
        try update("INSERT INTO threads(id,thread_source,source) VALUES('\(peerID)','user','cli')")
        let peerChild = try spawn(peerID)
        let group = SessionGroup(name: "Managed", members: [leader, member, peer], leaderMemberID: leader.id)
        let other = SessionGroup(name: "Peer", members: [leader, member], leaderMemberID: member.id)
        let store = SessionGroupStore(directory: directory)
        try store.save([group, other])
        func call(_ tool: String, _ id: String, _ args: JSONObject = [:]) async throws -> JSONObject {
            var request: JSONObject = ["tool": tool, "owner": UUID().uuidString, "agentKind": "codex", "conversationID": id,
                                        "codexCallerConversationID": id, "codexCallerSource": "codex_mcp_metadata", "codexCallerHome": home]
            request.merge(args) { _, supplied in supplied }
            return try await engine.mcpAction(request)
        }
        func denied(_ tool: String, _ id: String, _ args: JSONObject = [:], status: Int = 403) async throws {
            do { _ = try await call(tool, id, args); throw AppError.message("Unexpected delegation for " + tool) }
            catch let error as RemoteHTTPError { try expectEqual(error.status, status) }
        }
        for descendant in [child, nested] {
            let result = try await call("get_session_groups", descendant, ["codexCallerRuntimeID": session.id, "codexCallerSessionID": root,
                                                                           "codexCallerParentID": descendant == child ? root : child])
            try expectEqual(result["attribution"] as? String, "codex_subagent_metadata")
            try expectEqual(result["callerConversationID"] as? String, descendant)
            try expectEqual((result["actingAsConversationID"] as? String)?.lowercased(), root)
            let groups = result["groups"] as? [JSONObject]
            try expectEqual(Set(groups?.compactMap { $0["id"] as? String } ?? []), Set([group.id.uuidString, other.id.uuidString]))
            let caller = (groups?.first?["members"] as? [JSONObject])?.first { $0["isCaller"] as? Bool == true }
            try expectEqual(caller?["conversationID"] as? String, root)
            try expectEqual(caller?["connected"] as? Bool, false)
        }
        let target: JSONObject = ["groupID": group.id.uuidString, "memberID": member.id.uuidString]
        let frame = try await call("get_group_member_terminal", nested, target)
        try expectEqual(frame["screen"] as? String, prompt)
        let assigned = try await call("assign_group_task", child, target.merging(["task": "Inspect the test fixture", "requestID": UUID().uuidString]) { _, new in new })
        try expect(assigned["taskID"] is String)
        try expectEqual(try engine.sessionGroupAssignments().first?.parentMemberID, leader.id)
        let id = UUID().uuidString
        _ = try await call("send_group_message", nested, target.merging(["text": "Fixture ready", "messageID": id]) { _, new in new })
        let outbox = try await call("get_group_messages", child, ["groupID": group.id.uuidString, "messageID": id, "direction": "outbox"])
        try expectEqual((outbox["messages"] as? [JSONObject])?.first?["senderMemberID"] as? String, leader.id.uuidString)
        let workerGrandchild = try spawn(workerChild)
        let leaderTarget: JSONObject = ["groupID": group.id.uuidString, "memberID": leader.id.uuidString]
        let questionID = UUID().uuidString
        let question: JSONObject = ["text": "Which fixture should be checked?", "messageID": questionID]
        _ = try await call("ask_group_question", workerGrandchild, leaderTarget.merging(question) { _, new in new })
        let reply: JSONObject = ["text": "Use the owned fixture", "messageID": UUID().uuidString, "inReplyTo": questionID]
        _ = try await call("reply_group_question", nested, target.merging(reply) { _, new in new })
        let response = try await call("get_group_messages", workerChild, ["groupID": group.id.uuidString, "messageID": reply["messageID"]!])
        try expectEqual((response["messages"] as? [JSONObject])?.first?["inReplyTo"] as? String, questionID)
        let workerMessage: JSONObject = ["text": "Checks finished", "messageID": UUID().uuidString]
        let outgoing = leaderTarget.merging(workerMessage) { _, new in new }
        _ = try await call("send_group_message", workerChild, outgoing)
        _ = try await call("send_group_message", workerChild, outgoing)
        let inbox = try await call("get_group_messages", child, ["groupID": group.id.uuidString, "messageID": workerMessage["messageID"]!])
        let sent = inbox["messages"] as? [JSONObject]
        try expectEqual(sent?.count, 1)
        try expectEqual(sent?.first?["senderMemberID"] as? String, member.id.uuidString)
        let peerMessageID = UUID().uuidString
        _ = try await call("send_group_message", workerGrandchild, ["groupID": group.id.uuidString, "memberID": peer.id.uuidString,
                                                                    "messageID": peerMessageID, "text": "Second worker is ready"])
        let peerInbox = try await call("get_group_messages", peerChild, ["groupID": group.id.uuidString, "messageID": peerMessageID])
        try expectEqual((peerInbox["messages"] as? [JSONObject])?.first?["senderMemberID"] as? String, member.id.uuidString)
        try await denied("get_group_messages", workerChild, ["groupID": group.id.uuidString, "mailboxMemberID": leader.id.uuidString])
        try await denied("send_group_message", workerChild, outgoing.merging(["asTask": true]) { _, new in new })
        try await denied("send_group_message", workerChild, outgoing.merging(["groupID": UUID().uuidString]) { _, new in new })
        try await denied("get_group_member_terminal", workerChild, target)
        try await denied("get_group_member_terminal", child, ["groupID": other.id.uuidString, "memberID": member.id.uuidString])
        for tool in ["clear_group_member", "answer_group_question", "set_group_relationship"] { try await denied(tool, child, target) }
        try await denied("get_session_groups", nested, ["codexCallerParentID": root])
        try await denied("get_session_groups", child, ["codexCallerSessionID": worker])
        try await denied("get_session_groups", child, ["conversationID": root], status: 409)
        try await denied("get_session_groups", child, ["codexCallerHome": home + "/missing", "codexCallerSource": "codex_subagent_metadata"])
        try expectEqual((try await call("get_session_groups", child, ["codexCallerSource": "codex_exec_context"])["groups"] as? [JSONObject])?.count, 0)
        try expectEqual((try await call("get_session_groups", root)["groups"] as? [JSONObject])?.count, 2)
        try update("UPDATE thread_spawn_edges SET status='closed' WHERE child_thread_id='\(child)'")
        try await denied("get_group_member_terminal", nested, target)
        try update("UPDATE thread_spawn_edges SET status='open',parent_thread_id='\(worker)' WHERE child_thread_id='\(child)'")
        try await denied("get_session_groups", child)
        try update("UPDATE thread_spawn_edges SET parent_thread_id='\(root)' WHERE child_thread_id='\(child)'; UPDATE threads SET archived=1 WHERE id='\(root)'")
        try await denied("get_session_groups", nested)
        try update("UPDATE threads SET archived=0 WHERE id='\(root)'")
        try update("UPDATE threads SET thread_source='user' WHERE id='\(root)'")
        try expectEqual((try await call("get_session_groups", child)["groups"] as? [JSONObject])?.count, 2)
        try store.save([other])
        try expectEqual((try await call("get_session_groups", child)["groups"] as? [JSONObject])?.count, 1)
        try await denied("get_group_member_terminal", child, ["groupID": other.id.uuidString, "memberID": member.id.uuidString])
        try store.save([SessionGroup(name: "Removed", members: [member], leaderMemberID: member.id)])
        try expectEqual((try await call("get_session_groups", child)["groups"] as? [JSONObject])?.count, 0)
        try expectEqual(try store.load().first?.members.first?.conversationID, worker)
    }
}
