import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AutoApproveCore

@main struct WebInteractionFixture {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), paths = AppPaths(directory: directory.appendingPathComponent("profile"))
        let records = ProcessDiscovery.parse("1 0 ?? 1 0 Mon Oct 5 09:00:00 2026 /sbin/launchd\n20 1 ?? 20 0 Mon Oct 5 09:00:00 2026 /fixture/iTerm2/iTermServer\n40 20 ttys080 40 41 Mon Oct 5 09:00:00 2026 /bin/zsh\n41 40 ttys080 41 41 Mon Oct 5 09:00:00 2026 codex\n50 20 ttys081 50 51 Mon Oct 5 09:00:00 2026 /bin/zsh\n51 50 ttys081 51 51 Mon Oct 5 09:00:00 2026 claude")
        let codex = records.first { $0.pid == 41 }!, claude = records.first { $0.pid == 51 }!
        let thread = "00000000-0000-4000-8000-000000000001"
        let transport = CodexReplyTransport(prepare: { _, _ in CodexReplyTarget(executable: "/fixture/codex", home: "/fixture", threadID: thread) }, send: { _, message in
            try (message + "\n").append(to: directory.appendingPathComponent("messages.txt")); return UUID().uuidString
        }, prepareMessage: { _ in CodexReplyTarget(executable: "/fixture/codex", home: "/fixture", threadID: thread) })
        let screen = TestScreenSharing(permission: { _ in true }, sources: { [TestScreenSource(id: 1, scope: "display", title: "합성 Mac 시험 화면", width: 640, height: 480)] }, capture: { _ in
            try "capture\n".append(to: directory.appendingPathComponent("captures.txt"))
            let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            context.setFillColor(CGColor(red: 0.18, green: 0.45, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 40, y: 40, width: 560, height: 80))
            let data = NSMutableData(), destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil); guard CGImageDestinationFinalize(destination) else { throw AppError.message("Fixture JPEG failed") }
            return TerminalNativeImage(data: (data as Data).base64EncodedString(), width: 640, height: 480)
        })
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "합성 시험 세션 · 실제 사용자 터미널이 아닙니다.\nREADY> ") }) }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in
            try (input.kind.rawValue + ":" + input.text + "\n").append(to: directory.appendingPathComponent("inputs.txt")); return .sent
        })
        let engine = try ApprovalEngine(paths: paths, questionTransport: transport, claudeRegistryReader: { _ in [] }, processReader: { records }, screenAdapters: [.iterm: adapter], testScreenSharing: screen)
        let sessions = [codex, claude].map { record -> AgentSession in
            var session = AgentSession(id: record.key, agent: record.agent!, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/fixture/mobile-test", terminal: .iterm)
            session.phase = .working; session.channel = .itermScreen; session.terminalTitle = record.agent == .codex ? "합성 Codex 세션" : "합성 Claude 세션"; return session
        }
        engine.updateDiscovery(sessions, records: records)
        await engine.connectScreenHost(.iterm)
        try engine.start(poll: false); try engine.setWebEnabled(true, port: 0, bonjourEnabled: false, discoveryAddresses: { [] })
        while !engine.webStatus.ready { try await Task.sleep(nanoseconds: 20_000_000) }
        try engine.setAutomatic(codex.key, enabled: true); try engine.setAutomatic(claude.key, enabled: true)
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: codex.key, questions: [QueuedQuestion(id: "fixture-q1", threadID: thread, title: "어떤 모바일 화면을 확인할까요?", options: ["질문과 답변", "테스트 화면", "원본 터미널"]), QueuedQuestion(id: "fixture-q2", threadID: thread, title: "한글·이모지·긴 선택지의 줄바꿈과 전송 결과를 함께 확인할까요?", options: ["질문을 먼저 확인", "긴 선택지와 추가 설명을 함께 보내기"])] )])
        let now = Date()
        let payload: JSONObject = ["autoapproveProtocol":1, "requestID":UUID().uuidString, "autoapproveExpiresAt":now.addingTimeInterval(600).timeIntervalSince1970,
            "hook_event_name":"PreToolUse", "session_id":"fixture-claude", "agentPID":51, "agentStarted":claude.started, "tty":"/dev/ttys081", "cwd":"/fixture/mobile-test", "tool_name":"AskUserQuestion", "tool_use_id":"fixture-tool",
            "tool_input":["questions":[["question":"어떤 환경을 확인할까요?", "options":[["label":"개발", "description":"격리된 개발 환경에서 동작을 확인합니다."],["label":"운영", "description":"현재 서비스 상태를 확인합니다."]]], ["question":"어떤 기능을 테스트할까요?", "multiSelect":true, "options":[["label":"휴대폰 질문 폼"],["label":"메시지 입력"],["label":"Mac 전체 화면 공유"]]]]]]
        _ = try engine.handleClaudeHook(payload)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(["port":String(engine.webStatus.port!), "codex":codex.key, "claude":claude.key]).write(to: directory.appendingPathComponent("ready.json"))
        while !Task.isCancelled {
            let result = try engine.handleClaudeHook(payload)
            if let response = (result["autoapproveBridge"] as? JSONObject)?["response"] as? JSONObject, !response.isEmpty {
                try JSONSerialization.data(withJSONObject: response, options: .sortedKeys).write(to: directory.appendingPathComponent("claude-answer.json"))
                try engine.acknowledgeClaudeHook(payload)
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        engine.stop()
    }
}
private extension String {
    func append(to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }; try file.seekToEnd(); try file.write(contentsOf: Data(utf8))
    }
}
