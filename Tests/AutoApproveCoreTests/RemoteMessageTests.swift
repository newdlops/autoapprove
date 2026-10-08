import Foundation
import AutoApproveCore

private final class MessageWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = 0
    private var attempted = 0
    private var output: [String] = []
    private var screenText = "검사 원본\n› "
    var screen: String {
        get { lock.lock(); defer { lock.unlock() }; return screenText }
        set { lock.lock(); defer { lock.unlock() }; screenText = newValue }
    }
    var ambiguous = false
    init(reject: Int = 0) { rejected = reject }
    var writes: [String] { lock.lock(); defer { lock.unlock() }; return output }
    var attempts: Int { lock.lock(); defer { lock.unlock() }; return attempted }
    func send(_ input: RemoteTerminalInput) throws -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }; attempted += 1
        if rejected > 0 { rejected -= 1; return .screenChanged }
        if ambiguous { throw RemoteHTTPError(409, "부분 입력 결과 미확인") }
        output.append(input.bytes); return .sent
    }
}

@MainActor private final class FailedAdvertisement: RemoteServiceAdvertising {
    var attempts = 0
    var stopped = false
    func publish(name: String, type: String, port: UInt16, txt: Data, onChange: @escaping @MainActor (Bool) -> Void) {
        attempts += 1; onChange(false)
    }
    func stop() { stopped = true }
}

extension ApprovalTests {
    @MainActor func testBonjourFailureKeepsWebMessagesAvailable() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aa-advertisement-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: home))
        defer { engine.stop() }
        let advertisement = FailedAdvertisement(), node = UUID().uuidString
        var status = RemoteNetworkStatus()
        let service = RemoteNetworkService(engine: engine, nodeID: node, name: "격리 DNS 오류 검사", discoveryAddresses: { [] }, advertisement: advertisement, onStatus: { status = $0 })
        defer { service.stop() }
        try service.start(port: 0)
        for _ in 0..<100 where !status.ready { try await Task.sleep(for: .milliseconds(20)) }
        try expect(status.ready); try expect(advertisement.attempts > 0)
        let url = URL(string: "http://127.0.0.1:\(status.port!)/api/action")!
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["requestID": UUID().uuidString, "action": "pause", "paused": true])
        let (body,response) = try await URLSession.shared.data(for: request)
        try expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
        try expectEqual((try JSONSerialization.jsonObject(with: body) as? JSONObject)?["paused"] as? Bool, true)
        try expect(status.ready, "Advertisement failure never stops the HTTP command path")
        service.stop(); try expect(advertisement.stopped)
    }

    @MainActor func testOriginalWebMessageWithoutQueue() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aa-message-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let records = ProcessDiscovery.parse("81001 1 ttys081 81001 81001 Mon Sep 21 09:00:01 2026 /usr/local/bin/codex\n81002 1 ttys082 81002 81002 Mon Sep 21 09:00:02 2026 /usr/local/bin/claude")
        var sessions = ProcessDiscovery.sessions(records)
        for index in sessions.indices { sessions[index].terminal = .iterm; sessions[index].phase = .working }
        let writer = MessageWriter(reject: 2)
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: writer.screen) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in try writer.send(input) })
        let transport = CodexReplyTransport(prepare: { _, _ in throw AppError.message("대화 연결 없음") }, send: { _, _ in throw AppError.message("대기열 전송 금지") }, prepareMessage: { _ in throw AppError.message("질문 기록 없음") })
        let engine = try ApprovalEngine(paths: AppPaths(directory: home), questionTransport: transport, processReader: { records }, screenAdapters: [.iterm: adapter])
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        for session in sessions {
            let frame = try await engine.remoteTerminal(sessionID: session.id)
            let text = "원본에 한글 🧪 메시지\n다음 줄"
            let result = try await engine.remoteAction(["action": "sendMessage", "transport": "terminal", "sessionID": session.id,
                "revision": frame.revision, "streamID": frame.streamID!, "text": text])
            try expectEqual(result["ok"] as? Bool, true); try expectEqual(result["transport"] as? String, "terminal")
        }
        try expectEqual(writer.writes, Array(repeating: "원본에 한글 🧪 메시지\n다음 줄\r", count: 2))
        try expectEqual(writer.attempts, 4, "Only proven screen rejections are retried; each message is written once")
        let original = sessions[0], frame = try await engine.remoteTerminal(sessionID: original.id)
        do {
            _ = try await engine.remoteAction(["action": "sendMessage", "transport": "terminal", "sessionID": original.id,
                "revision": frame.revision, "streamID": UUID().uuidString, "text": "다른 연결"])
            throw AppError.message("Changed stream accepted")
        } catch let error as RemoteHTTPError { try expectEqual(error.diagnostics?["delivery"], "not_started") }
        try expectEqual(writer.writes.count, 2)
        for menu in ["Background server has incompatible feature settings\n1. Run without daemon this time\n2. Restart with these settings\n› 3. Cancel", "Choose a setup mode\n› 1. Default\n2. Custom\nPress enter to confirm or esc to cancel", "Update available\n› 1. Update now\n2. Skip\n3. Skip until next version\nenter continue · esc skip"] {
            writer.screen = menu
            try await Task.sleep(for: .milliseconds(200))
            do {
                _ = try await engine.remoteAction(["action": "sendMessage", "transport": "terminal", "sessionID": original.id,
                    "revision": frame.revision, "streamID": frame.streamID!, "text": "메뉴에 새 메시지를 보내지 않습니다"])
                throw AppError.message("Setup menu accepted a message")
            } catch let error as RemoteHTTPError { try expectEqual(error.diagnostics?["delivery"], "not_started") }
        }
        try expectEqual(writer.attempts, 4, "Fresh setup menus are rejected before any input")
        let claude = sessions.first { $0.agent == .claude }!
        writer.screen = "Accessing workspace:\n/private/tmp/fixture\n\n❯ No, exit\nYes, I trust this folder\n\nEnter to confirm · Esc to cancel"
        try await Task.sleep(for: .milliseconds(200))
        do {
            _ = try await engine.remoteAction(["action": "sendMessage", "transport": "terminal", "sessionID": claude.id,
                "revision": frame.revision, "text": "시작 메뉴의 확인을 대신하지 않습니다"])
            throw AppError.message("Workspace menu accepted a message")
        } catch let error as RemoteHTTPError { try expectEqual(error.diagnostics?["delivery"], "not_started") }
        try expectEqual(writer.attempts, 4)
        writer.screen = "지난 메뉴\n› 1. Default\n2. Custom\nPress enter to confirm or esc to cancel\n\n› \n? for shortcuts"
        try await Task.sleep(for: .milliseconds(200))
        writer.ambiguous = true
        do {
            _ = try await engine.remoteAction(["action": "sendMessage", "transport": "terminal", "sessionID": original.id,
                "revision": frame.revision, "streamID": frame.streamID!, "text": "결과 미확인"])
            throw AppError.message("Ambiguous write accepted")
        } catch let error as RemoteHTTPError { try expectEqual(error.diagnostics?["delivery"], "unknown") }
        try expectEqual(writer.attempts, 5, "Partial or ambiguous writes must never be retried")
    }

    func testMessagePasteProtocolAndTTYLimit() throws {
        let text = "한글 🧪\n두 줄\t메시지"
        let message = RemoteTerminalInput(kind: .message, text: text, relay: true)
        try message.validate(); try expect(message.isRelay)
        try expectEqual(message.bytes, "\u{1b}[200~" + text + "\u{1b}[201~\r")
        let maximum = RemoteTerminalInput(kind: .message, text: String(repeating: "a", count: 7_987), relay: true)
        try maximum.validate(); try expectEqual(maximum.bytes.utf8.count, 8_000)
        try expectThrows(try RemoteTerminalInput(kind: .message, text: String(repeating: "a", count: 7_988), relay: true).validate())
        try expectThrows(try RemoteTerminalInput(kind: .message, text: "\u{1b}[201~escape", relay: true).validate())
        try expectThrows(try RemoteTerminalInput(kind: .message, text: "\0", relay: true).validate())
    }
}
