import Foundation
import AutoApproveCore

extension ApprovalTests {
    @MainActor func testGroupDependencyWaits() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aa-waits-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(directory: directory)
        try paths.prepare()
        let records = ProcessDiscovery.parse("""
        109101 1 fixture901 109101 109101 Wed Oct 28 12:00:00 2026 /fixture/codex
        109102 1 fixture902 109102 109102 Wed Oct 28 12:00:00 2026 /fixture/codex
        109104 1 fixture904 109104 109104 Wed Oct 28 12:00:00 2026 /fixture/codex
        109103 1 fixture903 109103 109103 Wed Oct 28 12:00:00 2026 /fixture/claude
        """).sorted { $0.pid < $1.pid }
        let sessions = records.map { AgentSession(id: $0.key, agent: $0.agent!, pid: $0.pid, started: $0.started, tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm) }
        let identities = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, UUID().uuidString.lowercased()) })
        let members = sessions.map { session -> SessionGroupMember in
            var member = SessionGroupMember(agent: session.agent, title: "fixture", cwd: "/project", conversationID: identities[session.pid]!,
                providerHome: session.agent == .codex ? "/fixture/home" : nil)
            member.runtimeID = session.id
            return member
        }
        let group = SessionGroup(name: "dependency tests", members: members, leaderMemberID: members[0].id)
        try SessionGroupStore(directory: directory).save([group])
        let tasks = [1,2,3].map { SessionGroupAssignment(groupID: group.id, workerMemberID: members[$0].id, parentMemberID: members[0].id,
            workerSessionID: sessions[$0].id, parentSessionID: sessions[0].id, task: "work") }
        var seeded = SessionGroupOrchestration(assignments: tasks)
        for task in tasks { seeded.markDelivered(task.id) }
        try AuditStore(path: paths.database).set(SessionGroupOrchestration.storeKey, String(decoding: JSONEncoder().encode(seeded), as: UTF8.self))
        func create() throws -> ApprovalEngine {
            let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { rows in rows.filter { $0.agent == .claude }.map {
                .init(processID: $0.key, kind: "interactive", sessionID: identities[$0.pid], status: "busy") } }, processReader: { records },
                codexGroupReader: { r in identities[r.pid].map { .init(threadID: $0, database: "/fixture/home/thread_history_1.sqlite") } }, isolateByDefault: true)
            engine.updateDiscovery(sessions, records: records)
            return engine
        }
        var engine = try create()
        defer { engine.stop() }
        func arguments(_ name: String, _ member: Int, _ args: JSONObject) -> JSONObject {
            var input: JSONObject = ["tool": name, "owner": UUID().uuidString, "groupID": group.id.uuidString, "sessionID": sessions[member].id]
            input.merge(args) { _, new in new }
            return input
        }
        @MainActor func call(_ name: String, _ member: Int, _ args: JSONObject) async throws -> JSONObject {
            try await engine.mcpAction(arguments(name, member, args))
        }
        let box = try SessionGroupMailbox(directory: directory)
        let a = tasks[0].id.uuidString, b = tasks[1].id.uuidString
        let w1 = UUID().uuidString, w2 = UUID().uuidString
        let initial = engine
        let left = arguments("wait_group_dependencies", 1, ["waitID": w1, "taskIDs": [b]])
        let right = arguments("wait_group_dependencies", 2, ["waitID": w2, "taskIDs": [a]])
        async let first = initial.mcpAction(left)
        async let second = initial.mcpAction(right)
        let outcomes = try await [first, second]
        try expectEqual(Set(outcomes.compactMap { $0["state"] as? String }), Set(["waiting","cycle"]))
        let cycle = outcomes.first { $0["state"] as? String == "cycle" }?["detail"] as? String ?? ""
        try expect(cycle.contains(a) && cycle.contains(b))
        for (idx, id) in [w1,w2].enumerated() { _ = try await call("update_group_wait", idx+1, ["waitID": id, "action": "cancel"]) }

        let wa = UUID().uuidString, wb = UUID().uuidString
        _ = try await call("wait_group_dependencies", 1, ["waitID": wa, "taskIDs": [b]])
        let alternative = try await call("wait_group_dependencies", 2, ["waitID": wb, "taskIDs": [a], "mode": "any", "external": true])
        try expectEqual(alternative["state"] as? String, "waiting")
        try expectEqual(try await call("update_group_wait", 2, ["waitID": wb, "action":"externalReady"])["state"] as? String, "ready")
        _ = try await call("update_group_wait", 1, ["waitID": wa, "action": "cancel"])

        let c = tasks[2].id.uuidString
        let anyID = UUID().uuidString, hold = UUID().uuidString
        _ = try await call("wait_group_dependencies", 1, ["waitID":anyID, "taskIDs":[b,c], "mode":"any"])
        try expectEqual(try await call("wait_group_dependencies", 2, ["waitID":hold, "taskIDs":[a]])["state"] as? String, "waiting")
        let closed = try await call("wait_group_dependencies", 3, ["waitID":UUID().uuidString, "taskIDs":[a]])
        try expectEqual(closed["state"] as? String, "cycle")
        // A Claude Stop at the end of a waiting turn must not close its assignment.
        for event in ["UserPromptSubmit","Stop"] {
            _ = engine.handleHook(["hook_event_name":event, "session_id":identities[sessions[2].pid]!, "requestID":UUID().uuidString,
                                   "agentPID": sessions[2].pid, "agentStarted":sessions[2].started, "last_assistant_message":"Waiting"])
        }
        try expect(try engine.sessionGroupAssignments().contains { $0.id == tasks[1].id && $0.status == .working })
        let groups = try await call("get_group_status", 0, ["includeWaitGraph":true])["groups"] as? [JSONObject]
        try expect((groups?.first?["waitGraph"] as? String)?.contains("-->|any|") == true)
        _ = try await call("update_group_wait", 1, ["waitID":anyID, "action":"cancel"])
        _ = try await call("update_group_wait", 2, ["waitID":hold, "action":"cancel"])

        let root = UUID().uuidString, question = UUID().uuidString
        _ = try await call("wait_group_dependencies", 0, ["waitID": root, "taskIDs": [a]])
        let ask: JSONObject = ["messageID": question, "blocksProgress": true, "memberID": members[0].id.uuidString, "text": "decision?"]
        let receipt = try await call("ask_group_question", 1, ask)
        try expectEqual((receipt["wait"] as? JSONObject)?["state"] as? String, "waiting")
        _ = try await call("ack_group_messages", 0, ["messageIDs":[question]])
        do { _ = try await call("complete_group_task", 1, ["taskID": a, "summary":"premature"]); throw AppError.message("ACK completed wait") }
        catch is RemoteHTTPError {}
        let decision = try await call("wait_group_dependencies", 0, ["waitID": UUID().uuidString, "forQuestionID": question, "taskIDs":[a]])
        try expectEqual(decision["state"] as? String, "cycle")
        let reply: JSONObject = ["memberID":members[1].id.uuidString, "text":"answer", "inReplyTo":question]
        do { _ = try await call("reply_group_question", 2, reply); throw AppError.message("Wrong author answered") }
        catch is RemoteHTTPError {}
        let linked = try await call("reply_group_question", 0, reply)
        try expectEqual(try await call("reply_group_question", 0, reply)["messageID"] as? String, linked["messageID"] as? String)
        try expectEqual((try await call("ask_group_question", 1, ask)["wait"] as? JSONObject)?["state"] as? String, "ready")
        _ = try await call("complete_group_task", 1, ["taskID": a, "summary":"final"])
        try expectEqual(try await call("wait_group_dependencies", 0, ["waitID":root, "taskIDs":[a]])["state"] as? String, "ready")

        let batchID = UUID().uuidString
        let questionIDs = [UUID().uuidString, UUID().uuidString]
        for (index, id) in questionIDs.enumerated() {
            _ = try await call("ask_group_question", 0, ["messageID": id, "memberID": members[index + 1].id.uuidString, "text": "batch question"])
        }
        let batch: JSONObject = ["waitID": batchID, "questionIDs": questionIDs]
        try expectEqual(try await call("wait_group_dependencies", 0, batch)["state"] as? String, "waiting")
        for (index, id) in questionIDs.enumerated() {
            _ = try await call("reply_group_question", index + 1, [
                "inReplyTo": id, "memberID": members[0].id.uuidString, "text": "fixture result \(index)"
            ])
            if index == 0 {
                try expectEqual(try await call("wait_group_dependencies", 0, batch)["state"] as? String, "waiting")
                try expect(!(try box.heads()).contains { $0.sourceKey == "answer:" + id })
            }
        }
        let batchKey = "wait:\(batchID):ready:\(members[0].id.uuidString)"
        let ready = try box.message(sourceKey: batchKey)
        try expectEqual(try await call("wait_group_dependencies", 0, batch)["state"] as? String, "ready")
        try expect(ready?.text.contains("fixture result 0") == true)
        try expect(ready?.text.contains("fixture result 1") == true)
        for id in questionIDs {
            try expectEqual(try box.message(sourceKey: "answer:" + id)?.lastResult, "batched")
        }

        let unanswered = try box.enqueue(groupID: group.id, senderID: members[1].id,
                                         recipientID: members[0].id, kind: .question, text: "unanswered graph edge")
        try box.acknowledge([unanswered.id], groupID: group.id, recipientID: members[0].id)
        _ = try box.enqueue(groupID: UUID(), senderID: members[1].id, recipientID: members[0].id,
                            kind: .question, text: "unrelated group")
        let saved = try box.enqueue(groupID: group.id, senderID: members[0].id, recipientID: members[1].id,
                                    kind: .message, text: "saved group message")
        let graph = try box.conversations(groupID: group.id)
        try expectEqual(graph.conversations.first?.question.id, unanswered.id)
        try expectNil(graph.conversations.first?.answer)
        try expectEqual(graph.conversations.first { $0.id.uuidString == question }?.answer?.text, "answer")
        try expect(!graph.conversations.contains { $0.question.text == "unrelated group" })
        try expectEqual(graph.messages.first?.id, saved.id)
        try expect(!graph.messages.contains { $0.sourceKey?.hasPrefix("answer:") == true })

        let timeout = UUID().uuidString
        let request: JSONObject = ["waitID": timeout, "external":true, "timeoutSeconds":1]
        _ = try await call("wait_group_dependencies", 2, request)
        engine.stop()
        try await Task.sleep(for: .milliseconds(1150))
        engine = try create()
        try engine.start(poll: false)
        try expectEqual(try await call("wait_group_dependencies", 2, request)["state"] as? String, "expired")
        try expectEqual(try await call("update_group_wait", 2, ["waitID":timeout, "action":"externalReady"])["state"] as? String, "ready")
        let notices = try box.list(groupID: group.id, memberID: members[2].id).filter { $0.kind == .waitNotice && $0.text.contains(timeout) }
        try expectEqual(notices.filter { $0.text.contains(" · ready · ") }.count, 0)
        try expectEqual(notices.filter { $0.text.contains(" · expired · ") }.count, 1)
    }
}
