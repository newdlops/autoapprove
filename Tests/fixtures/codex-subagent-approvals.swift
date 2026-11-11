import Foundation
@testable import AutoApproveCore

@main struct Check {
    @MainActor static func main() async throws {
        let home = CommandLine.arguments[1], root = CommandLine.arguments[2]
        let uncertain = CommandLine.arguments.contains("--uncertain")
        let target = CodexReplyTarget(executable: "", home: home, threadID: root)
        let child = "00000000-0000-4000-8000-000000000002"
        let other = "00000000-0000-4000-8000-000000000003"
        let rows: [JSONObject] = [
            ["id": root, "cwd": "/fixture", "status": ["type": "active"]],
            ["id": child, "parentThreadId": root, "cwd": "/fixture", "status": ["type": "active"]],
            ["id": other, "parentThreadId": other, "cwd": "/fixture", "status": ["type": "active"]]
        ]
        precondition(Set(CodexSubagentApprovals.ownedThreads(root: root, rows: rows).keys) == Set([root, child]))
        var idleRows = rows
        idleRows[0]["status"] = ["type": "idle"]
        idleRows[1]["status"] = ["type": "idle"]
        let idleActivity = try CodexSubagentApprovals.activity(root: root, rows: idleRows)
        precondition(idleActivity.phase == .idle && idleActivity.children.count == 1 && idleActivity.children[0].phase == .idle)
        idleRows[0]["status"] = ["type": "active"]
        let parentWorking = try CodexSubagentApprovals.activity(root: root, rows: idleRows)
        precondition(parentWorking.phase == .working && parentWorking.children[0].phase == .idle)
        idleRows[1]["status"] = ["type": "systemError"]
        idleRows[0]["status"] = ["type": "idle"]
        let unknownActivity = try CodexSubagentApprovals.activity(root: root, rows: idleRows)
        precondition(unknownActivity.phase == .unknown)
        idleRows[0]["status"] = ["type":"systemError"]
        precondition(CodexSubagentApprovals.rootConversations(rows:idleRows,cwd:"/fixture").map(\.id)==[root])
        idleRows[0]["status"] = ["type":"notLoaded"]
        precondition(CodexSubagentApprovals.rootConversations(rows:idleRows,cwd:"/fixture").isEmpty)
        let mode=URL(fileURLWithPath:home).appendingPathComponent("activity-mode")
        try Data("parent-error".utf8).write(to:mode)
        let failedParentObservations=Counter()
        let noEffects=try await CodexSubagentApprovals.poll(target:target,cwd:"/fixture",
            observed:{activity in
                precondition(activity.parent.phase == .unknown && activity.children.count==1)
                await failedParentObservations.add()
            },authorize:{_ in fatalError("Failed parent cannot authorize approvals")},
            completed:{_,_ in fatalError("Status refresh cannot send responses")})
        let observedFailedParent=await failedParentObservations.value
        precondition(observedFailedParent==1 && noEffects.responded==0 && noEffects.review==0)
        try FileManager.default.removeItem(at:mode)
        let readOnly = Counter()
        _ = try await CodexSubagentApprovals.poll(target: target, cwd: "/fixture", approvalsEnabled: false,
            observed: { activity in
                precondition(activity.children.count == 1 && activity.children[0].phase == .approval)
                await readOnly.add()
            }, authorize: { _ in fatalError("Read-only status must never approve") },
            completed: { _, _ in fatalError("Read-only status must never respond") })
        let observations = await readOnly.value
        precondition(observations == 1)
        let safety: JSONObject = ["id": "protected", "method": "item/commandExecution/requestApproval", "params": ["threadId": child, "turnId": "turn", "itemId": "command", "cwd": "/fixture", "command": "sudo launchctl bootstrap system /Library/LaunchDaemons/fixture.plist", "availableDecisions": ["accept", "cancel"]]]
        precondition(CodexServerApproval.parse(safety, threads: [child: rows[1]])?.result["decision"] as? String == "cancel")
        for key in ["subAgent", "subagent"] {
            let row: JSONObject = ["parentThreadId": root, "source": [key: ["thread_spawn": ["parent_thread_id": root, "agent_path": "/root/worker"]]]]
            precondition(CodexSubagentApprovals.taskPath(row) == "/root/worker")
            var mismatch = row; mismatch["parentThreadId"] = other
            precondition(CodexSubagentApprovals.taskPath(mismatch) == nil)
        }
        let children = try CodexSubagentApprovals.children(target: target, cwd: "/fixture")
        precondition(children.count == 1 && children[0].id == child && children[0].title == "/root/worker")
        if !uncertain {
        let authorized = Counter(), confirmed = Counter()
        let count = try await Task.detached {
            try await CodexSubagentApprovals.poll(target: target, cwd: "/fixture", authorize: { approval in
                precondition(approval.threadID == child)
                precondition(approval.summary.contains("worker"))
                await authorized.add(); return true
            }, completed: { approval, acknowledged in
                precondition(acknowledged)
                await confirmed.add()
            })
        }.value
        precondition(count.responded == 3 && count.review == 2)
        let a = await authorized.value, c = await confirmed.value
        precondition(a == 3 && c == 3)
        }

        let paths = AppPaths(directory: URL(fileURLWithPath: home).appendingPathComponent(uncertain ? "engine-uncertain" : "engine"))
        let record = ProcessDiscovery.parse("92001 1 ttys891 92001 92001 Mon Sep 21 09:00:00 2026 /usr/local/bin/codex")[0]
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/fixture", terminal: .iterm)
        session.channel = .itermScreen
        let transport = CodexReplyTransport(prepare: { _, _ in target }, send: { _, _ in fatalError("No user message") },
            prepareMessage: { _ in target }, queueHome: { _ in target }, prepareQueue: { _, _ in target })
        let engine = try ApprovalEngine(paths: paths, questionTransport: transport, processReader: { [record] })
        engine.updateDiscovery([session], records: [record])
        try engine.setPaused(true)
        try engine.setAutomatic(session.id, enabled: true)
        try Data("parent-error".utf8).write(to:mode)
        try await engine.connectCurrentCodexApprovals(sessionID: session.id)
        try await Task.sleep(for: .milliseconds(200))
        precondition(engine.snapshot.sessions[0].codexApprovalBinding?.threadID==root)
        precondition(engine.snapshot.sessions[0].codexActivity?.children.count==1)
        precondition(engine.snapshot.sessions[0].codexActivity?.parent.phase == .unknown)
        try FileManager.default.removeItem(at:mode)
        _ = try await engine.codexApprovalSubagents(sessionID:session.id)
        precondition(engine.snapshot.sessions[0].codexActivity?.children.first?.phase == .approval)
        precondition(engine.snapshot.sessions[0].phase == .approval)
        let before = engine.snapshot.events.filter { $0.source == "Codex 부모·서브에이전트" }.count
        try await Task.sleep(for: .milliseconds(200))
        precondition(engine.snapshot.events.filter { $0.source == "Codex 부모·서브에이전트" }.count == before)
        let modeFile = URL(fileURLWithPath: home).appendingPathComponent("activity-mode")
        for (mode, parentPhase, childPhase, phase) in [("all-idle", SessionPhase.idle, SessionPhase.idle, SessionPhase.idle),
            ("parent-working", .working, .idle, .working), ("child-working", .idle, .working, .working)] {
            try Data(mode.utf8).write(to: modeFile)
            _ = try await engine.codexApprovalSubagents(sessionID: session.id)
            precondition(engine.snapshot.sessions[0].codexActivity?.parent.phase == parentPhase)
            precondition(engine.snapshot.sessions[0].codexActivity?.children.first?.phase == childPhase)
            precondition(engine.snapshot.sessions[0].phase == phase)
        }
        try engine.setAutomatic(session.id, enabled: false)
        try Data("all-idle".utf8).write(to: modeFile)
        try engine.setPaused(false)
        for _ in 0..<60 {
            if engine.snapshot.sessions[0].phase == .idle { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(engine.snapshot.sessions[0].phase == .idle)
        try Data("error".utf8).write(to: modeFile)
        for _ in 0..<60 {
            if engine.snapshot.sessions[0].codexActivity == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(engine.snapshot.sessions[0].phase == .unknown && engine.snapshot.sessions[0].codexActivity == nil)
        try FileManager.default.removeItem(at: modeFile)
        try engine.setAutomatic(session.id, enabled: true)
        for _ in 0..<80 {
            if engine.snapshot.events.contains(where: { $0.outcome == "서버 승인 확인" }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(engine.snapshot.events.contains(where: { $0.outcome == "서버 승인 확인" }))
        try await Task.sleep(for: .seconds(4)) // The same replay must not be sent twice.
        let attempts = engine.snapshot.events.filter { $0.outcome == "서버 승인 응답 시도 · 결과 미확인" }.count
        precondition(attempts == 3)
        if uncertain { precondition(engine.snapshot.events.contains { $0.outcome == "서버 응답 결과 미확인 · 중복 전송하지 않음" }) }
        try await engine.connectCodexApprovals(sessionID: session.id, threadID: nil)
        precondition(engine.snapshot.sessions[0].codexApprovalBinding == nil && engine.snapshot.sessions[0].codexActivity == nil)
        engine.stop()
        print("PASS: hidden child RPCs, exact ancestry, human/unrelated/resolved rejection, pause, resume, replay deduplication and disconnect")
    }
}
actor Counter { var value = 0; func add() { value += 1 } }
