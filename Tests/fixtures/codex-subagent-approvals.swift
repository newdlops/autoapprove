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
        let safety: JSONObject = ["id": "protected", "method": "item/commandExecution/requestApproval", "params": ["threadId": child, "turnId": "turn", "itemId": "command", "cwd": "/fixture", "command": "sudo launchctl bootstrap system /Library/LaunchDaemons/fixture.plist", "availableDecisions": ["accept", "cancel"]]]
        precondition(CodexServerApproval.parse(safety, threads: [child: rows[1]])?.result["decision"] as? String == "cancel")
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
        try await engine.connectCodexApprovals(sessionID: session.id, threadID: root)
        try await Task.sleep(for: .milliseconds(200))
        let before = engine.snapshot.events.filter { $0.source == "Codex 부모·서브에이전트" }.count
        try await Task.sleep(for: .milliseconds(200))
        precondition(engine.snapshot.events.filter { $0.source == "Codex 부모·서브에이전트" }.count == before)
        try engine.setPaused(false)
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
        precondition(engine.snapshot.sessions[0].codexApprovalBinding == nil)
        engine.stop()
        print("PASS: hidden child RPCs, exact ancestry, human/unrelated/resolved rejection, pause, resume, replay deduplication and disconnect")
    }
}
actor Counter { var value = 0; func add() { value += 1 } }
