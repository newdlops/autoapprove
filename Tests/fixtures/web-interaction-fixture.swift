import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AutoApproveCore

private actor FixtureQueue {
    var items = [CodexQueuedInput(id: "queued-first", text: "첫 번째 대기 입력 · 한글🧪"), CodexQueuedInput(id: "queued-second", text: "두 번째 대기 입력")]
    func list() -> [CodexQueuedInput] { items }
    func add(_ text: String) -> String { let id = UUID().uuidString; items.append(CodexQueuedInput(id:id,text:text)); return id }
    func remove(_ ids: [String]) -> CodexQueueDeletion {
        let removed = items.filter { ids.contains($0.id) }.map(\.id); items.removeAll { ids.contains($0.id) }
        return CodexQueueDeletion(removed:removed)
    }
}
@main struct WebInteractionFixture {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), paths = AppPaths(directory: directory.appendingPathComponent("profile"))
        let messagesOnly = CommandLine.arguments.contains("--messages-only")
        let records = ProcessDiscovery.parse("1 0 ?? 1 0 Mon Oct 5 09:00:00 2026 /sbin/launchd\n20 1 ?? 20 0 Mon Oct 5 09:00:00 2026 /fixture/iTerm2/iTermServer\n40 20 ttys080 40 41 Mon Oct 5 09:00:00 2026 /bin/zsh\n41 40 ttys080 41 41 Mon Oct 5 09:00:00 2026 codex\n50 20 ttys081 50 51 Mon Oct 5 09:00:00 2026 /bin/zsh\n51 50 ttys081 51 51 Mon Oct 5 09:00:00 2026 claude")
        let codex = records.first { $0.pid == 41 }!, claude = records.first { $0.pid == 51 }!
        let thread = "00000000-0000-4000-8000-000000000001"
        let queue = FixtureQueue()
        let transport = CodexReplyTransport(prepare: { _, _ in
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("reply-failure").path) { throw AppError.message("합성 응답 경로 오류 · 연결을 확인해주세요.") }
            return CodexReplyTarget(executable: "/fixture/codex", home: "/fixture", threadID: thread)
        }, send: { _, message in
            try (message + "\n").append(to: directory.appendingPathComponent("messages.txt")); return await queue.add(message)
        }, prepareMessage: { _ in
            if messagesOnly || FileManager.default.fileExists(atPath: directory.appendingPathComponent("queue-unbound").path) { throw AppError.message("이 Codex 세션의 질문 기록을 찾지 못했습니다.") }
            return CodexReplyTarget(executable: "/fixture/codex", home: "/fixture", threadID: thread)
        }, queueHome: { _ in CodexReplyTarget(executable: "/fixture/codex", home: "/fixture", threadID: "") }, prepareQueue: { _, selected in
            guard selected == thread else { throw RemoteHTTPError(409, "다른 대화입니다.") }
            return CodexReplyTarget(executable: "/fixture/codex", home: "/fixture", threadID: thread)
        })
        let screen = TestScreenSharing(permission: { _ in !FileManager.default.fileExists(atPath: directory.appendingPathComponent("screen-denied").path) }, sources: { [TestScreenSource(id: 1, scope: "display", title: "합성 Mac 시험 화면", width: 640, height: 480)] }, capture: { _ in
            try "capture\n".append(to: directory.appendingPathComponent("captures.txt"))
            let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            context.setFillColor(CGColor(red: 0.18, green: 0.45, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 40, y: 40, width: 560, height: 80))
            let data = NSMutableData(), destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil); guard CGImageDestinationFinalize(destination) else { throw AppError.message("Fixture JPEG failed") }
            return TerminalNativeImage(data: (data as Data).base64EncodedString(), width: 640, height: 480)
        })
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "합성 시험 세션 · 실제 사용자 터미널이 아닙니다.\nREADY> ") }) }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { target, _, _, input in
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("message-preflight-failure").path) { return .screenChanged }
            let route: JSONObject = ["tty": target.tty, "pid": target.sourcePID ?? 0, "text": input.text]
            try (String(decoding: JSONSerialization.data(withJSONObject: route), as: UTF8.self) + "\n").append(to: directory.appendingPathComponent("message-routes.jsonl"))
            try (input.kind.rawValue + ":" + input.text + "\n").append(to: directory.appendingPathComponent("inputs.txt")); return .sent
        })
        let engine = try ApprovalEngine(paths: paths, questionTransport: transport, claudeRegistryReader: { _ in [] }, processReader: { records }, screenAdapters: [.iterm: adapter], testScreenSharing: screen,
            codexQueue: CodexQueueTransport(list: { _ in await queue.list() }, delete: { _, ids in await queue.remove(ids) },
                conversations: { _, _ in [CodexQueueConversation(id: thread, title: "합성 실행 중 대화 · 한글과 긴 제목")] }))
        let sessions = [codex, claude].map { record -> AgentSession in
            var session = AgentSession(id: record.key, agent: record.agent!, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/fixture/mobile-test", terminal: .iterm)
            session.phase = .working; session.channel = .itermScreen; session.terminalTitle = record.agent == .codex ? "합성 Codex 세션" : "합성 Claude 세션"; return session
        }
        engine.updateDiscovery(sessions, records: records)
        await engine.connectScreenHost(.iterm)
        try engine.start(poll: false); try engine.setWebEnabled(true, port: 0, bonjourEnabled: false, discoveryAddresses: { [] })
        while !engine.webStatus.ready { try await Task.sleep(nanoseconds: 20_000_000) }
        try engine.setAutomatic(codex.key, enabled: true); try engine.setAutomatic(claude.key, enabled: true)
        // Keep the synthetic yes/no prompt pending while the browser inspects
        // three viewports. Manual replies must still work during an auto pause.
        try engine.setPaused(true)
        if messagesOnly {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(["port":String(engine.webStatus.port!), "codex":codex.key, "claude":claude.key]).write(to: directory.appendingPathComponent("ready.json"))
            while !Task.isCancelled { try await Task.sleep(nanoseconds: 400_000_000) }
            engine.stop(); return
        }
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: codex.key, questions: [], threadID: thread)])
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: codex.key, questions: [QueuedQuestion(id: "fixture-q1", threadID: thread, title: "합성 모바일 테스트를 진행할까요?", options: ["예", "아니요"]), QueuedQuestion(id: "fixture-q2", threadID: thread, title: "한글·이모지·긴 선택지의 줄바꿈과 전송 결과를 함께 확인할까요?", options: ["질문을 먼저 확인", "긴 선택지와 추가 설명을 함께 보내기"])] )])
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
