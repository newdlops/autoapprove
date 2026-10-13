import Foundation
import AutoApproveCore

private func ready(_ body: String = "") -> String {
    "합성 원본 대화 · 실제 사용자 터미널이 아닙니다.\n\n› " + body + "\n\nfixture-model · /fixture · 90% context left\n? for shortcuts"
}
private extension String {
    func append(to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(utf8))
    }
}
private final class FixtureInput: @unchecked Sendable {
    let root: URL, lock = NSLock()
    var text = "", enters = 0
    init(_ root: URL) { self.root = root }
    func write(_ target: ScreenTarget, expected: String, input: RemoteTerminalInput) throws -> TerminalDelivery {
        try lock.withLock {
            let file = root.appendingPathComponent("codex-screen")
            guard try String(contentsOf: file, encoding: .utf8) == expected else { return .screenChanged }
            let row: JSONObject = ["kind": input.kind.rawValue, "text": input.text, "pid": target.sourcePID ?? 0, "tty": target.tty]
            try (String(decoding: JSONSerialization.data(withJSONObject: row), as: UTF8.self) + "\n").append(to: root.appendingPathComponent("inputs.jsonl"))
            switch input.kind {
            case .escape: enters = 0; text = ""; try ready().write(to: file, atomically: true, encoding: .utf8)
            case .characters:
                text = input.text; try ready(text).write(to: file, atomically: true, encoding: .utf8)
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("uncertain-write").path) { throw AppError.message("합성 시험: 문자는 입력했지만 전달 확인이 끊겼습니다.") }
            case .enter:
                enters += 1
                if enters == 1 { try ready(text + "\n").write(to: file, atomically: true, encoding: .utf8) }
                else { try ("합성 원본 대화 · 실제 사용자 터미널이 아닙니다.\n\n› " + text + "\n\n• Working · esc to interrupt\n\n› \nfixture-model · /fixture · 89% context left").write(to: file, atomically: true, encoding: .utf8) }
            default: break
            }
            return .sent
        }
    }
}

@main struct SystemSafetyFixture {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), paths = AppPaths(directory: root.appendingPathComponent("profile"))
        let records = ProcessDiscovery.parse("1 0 ?? 1 0 Tue Oct 13 09:00:00 2026 /sbin/launchd\n20 1 ?? 20 0 Tue Oct 13 09:00:00 2026 /fixture/iTerm2/iTermServer\n40 20 ttys980 40 41 Tue Oct 13 09:00:00 2026 /bin/zsh\n41 40 ttys980 41 41 Tue Oct 13 09:00:00 2026 codex\n50 20 ttys981 50 51 Tue Oct 13 09:00:00 2026 /bin/zsh\n51 50 ttys981 51 51 Tue Oct 13 09:00:00 2026 claude")
        let codex = records.first { $0.pid == 41 }!, claude = records.first { $0.pid == 51 }!, input = FixtureInput(root)
        let request = "Would you like to run the following command?\n\nReason: 합성 시험 · 시스템 자동 실행 등록 요청의 긴 설명과 한글/emoji 🧪 줄바꿈 검사\n\n$ cp artifacts/" + String(repeating: "긴-경로/", count: 20) + "report.plist ~/Library/LaunchAgents/com.fixture.hourly.plist\n\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel"
        try request.write(to: root.appendingPathComponent("codex-screen"), atomically: true, encoding: .utf8)
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: try targets.map {
            TerminalScreen(tty: $0.tty, contents: $0.tty == "/dev/ttys980" ? try String(contentsOf: root.appendingPathComponent("codex-screen"), encoding: .utf8) : "합성 Claude 대화\n❯ \n? for shortcuts")
        }) }, approve: { _,_,_ in try "unexpected approval\n".append(to: root.appendingPathComponent("approvals.txt")); return .sent }, reveal: { _ in nil }, input: { target,expected,_,value in try input.write(target, expected: expected, input: value) })
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { records }, screenAdapters: [.iterm: adapter])
        let sessions = [codex,claude].map { record -> AgentSession in
            var session = AgentSession(id: record.key, agent: record.agent!, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/fixture/합성 보안 안내", terminal: .iterm)
            session.channel = .itermScreen; session.terminalTitle = record.pid == 41 ? "합성 Codex" : "합성 Claude"; return session
        }
        engine.updateDiscovery(sessions, records: records)
        await engine.connectScreenHost(.iterm); try engine.setPaused(true)
        try engine.setAutomatic(codex.key, enabled: true); try engine.setAutomatic(claude.key, enabled: true)
        try engine.start(poll: false); try engine.setWebEnabled(true, port: 0, bonjourEnabled: false, discoveryAddresses: { [] })
        let now = Date(), hook: JSONObject = ["autoapproveProtocol": 1, "requestID": UUID().uuidString, "autoapproveExpiresAt": now.addingTimeInterval(600).timeIntervalSince1970,
            "hook_event_name": "PermissionRequest", "session_id": "fixture-claude", "agentPID": claude.pid, "agentStarted": claude.started, "tty": "/dev/ttys981", "cwd": "/fixture",
            "tool_name": "Bash", "tool_use_id": UUID().uuidString, "tool_input": ["command": "launchctl bootstrap gui/501 ~/Library/LaunchAgents/com.fixture.plist"]]
        _ = try engine.handleClaudeHook(hook)
        engine.receiveScreen(sessionID: codex.key, raw: request, generation: "fixture-original")
        while !engine.webStatus.ready { try await Task.sleep(nanoseconds: 20_000_000) }
        try JSONSerialization.data(withJSONObject: ["port": engine.webStatus.port!]).write(to: root.appendingPathComponent("ready.json"))
        var pending = true
        while !Task.isCancelled {
            engine.receiveScreen(sessionID: codex.key, raw: try String(contentsOf: root.appendingPathComponent("codex-screen"), encoding: .utf8), generation: "fixture-original")
            if pending, let envelope = (try engine.handleClaudeHook(hook))["autoapproveBridge"] as? JSONObject, let response = envelope["response"] as? JSONObject {
                try JSONSerialization.data(withJSONObject: response).write(to: root.appendingPathComponent("claude-response.json"))
                try engine.acknowledgeClaudeHook(hook); pending = false
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
