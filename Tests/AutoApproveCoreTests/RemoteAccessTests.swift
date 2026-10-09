import Foundation
import JavaScriptCore
import AutoApproveCore
import Network
import Darwin
import TerminalInputSupport

private final class RemoteTestScreen: @unchecked Sendable {
    private let lock = NSLock()
    private var raw = "검증용 터미널\n› "
    private var writes = 0
    func read() -> String { lock.lock(); defer { lock.unlock() }; return raw }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return writes }
    func replace(_ value: String) { lock.lock(); defer { lock.unlock() }; raw = value }
    func change() { lock.lock(); defer { lock.unlock() }; raw += "changed" }
    func input(_ expected: String, _ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        guard input.isRelay || raw == expected else { return .screenChanged }
        writes += 1; raw += "\n" + input.bytes; return .sent
    }
}

private final class RemoteResumeGate: @unchecked Sendable {
    private let lock = NSLock(), signal = DispatchSemaphore(value: 0)
    private var active = false
    func wait() -> ResumeDelivery {
        lock.lock(); active = true; lock.unlock()
        _ = signal.wait(timeout: .now() + 5); return .missingTarget
    }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func release() { signal.signal() }
}

private final class RemoteReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var raw = String(repeating: "✓ 합성 데이터 · 화면 갱신 검증\n", count: 300)
    func read(_ tty: String) -> TerminalScreen {
        lock.lock(); reads += 1; let value = raw; lock.unlock()
        Thread.sleep(forTimeInterval: 0.08)
        return TerminalScreen(tty: tty, contents: value, title: "검증용")
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
    func change() { lock.lock(); raw += "\n새 출력"; lock.unlock() }
}

@MainActor private final class RemotePermissionProbe {
    var full = 0, automation = 0, keyboard = 0
    var automationAllowed = true
}

private final class RemoteCursorProbe: @unchecked Sendable {
    private let lock = NSLock()
    let raw = "원본 입력 검증 화면\nREADY> "
    private var display = TerminalTextSnapshot(screen: "Working 10%\n› abc\nCodex footer", cursor: TerminalCursor(offset: 17))
    private var writes = 0
    func screen(_ tty: String) -> TerminalScreen {
        lock.lock(); defer { lock.unlock() }
        return TerminalScreen(tty: tty, contents: raw, display: display)
    }
    func change(_ screen: String, cursor: Int) { lock.lock(); display = TerminalTextSnapshot(screen: screen, cursor: TerminalCursor(offset: cursor)); lock.unlock() }
    func input(_ expected: String) -> TerminalDelivery { lock.lock(); defer { lock.unlock() }; guard expected == raw else { return .screenChanged }; writes += 1; return .sent }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return writes }
}

extension ApprovalTests {
    func testNativeTextSnapshotKeepsCodexCursorOnSameViewport() throws {
        let history = "이전 출력\n", visible = "Working 20%\n› 한글🧪ab\nCodex footer"
        let insertion = history.utf16.count + "Working 20%\n› 한글🧪".utf16.count
        let snapshot = TerminalTextSnapshot.fromAccessibility(value: history + visible, insertion: insertion,
            visible: NSRange(location: history.utf16.count, length: visible.utf16.count))
        try expectEqual(snapshot?.screen, visible)
        try expectEqual(snapshot?.cursor.offset, "Working 20%\n› 한글🧪".utf16.count)
        try expectNil(TerminalTextSnapshot.fromAccessibility(value: visible, insertion: -1, visible: NSRange(location: 0, length: visible.utf16.count)))
        try expectNil(TerminalTextSnapshot.fromAccessibility(value: visible, insertion: visible.utf16.count + 1, visible: NSRange(location: 0, length: visible.utf16.count)))
        try expectNil(TerminalTextSnapshot.fromAccessibility(value: visible, insertion: 0, visible: NSRange(location: NSNotFound, length: 3)))
        try expectNil(TerminalTextSnapshot.fromAccessibility(value: "🧪", insertion: 1, visible: NSRange(location: 1, length: 1)))
        try expectNil(TerminalTextSnapshot.fromAccessibility(value: "🧪", insertion: 0, visible: NSRange(location: 0, length: 1)))
        try expectNil(TerminalTextSnapshot(screen: "🧪", cursor: TerminalCursor(offset: 1)).validated())
    }

    func testNativePresentationAndCursorPreserveOriginalInput() async throws {
        for agent in ["codex", "claude"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-cursor-source-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let records = ProcessDiscovery.parse("88 1 ttys080 88 88 Tue Sep 22 15:00:00 2026 /fixture/" + agent)
            var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .iterm
            let probe = RemoteCursorProbe()
            let adapter = ScreenHostAdapter(screens: { TerminalSnapshot(screens: $0.map { TerminalScreen(tty: $0.tty, contents: probe.raw) }) },
                approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { _,expected,_,_ in probe.input(expected) },
                presentationScreens: { TerminalSnapshot(screens: $0.map { probe.screen($0.tty) }) })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.iterm: adapter])
            defer { engine.stop() }
            engine.updateDiscovery([session], records: records); await engine.connectScreenHost(.iterm)
            try engine.setAutomatic(session.id, enabled: true)
            let first = try await engine.remoteTerminal(sessionID: session.id)
            try expectEqual(first.screen, "Working 10%\n› abc\nCodex footer"); try expectEqual(first.cursor?.offset, 17)
            try expect((first.sequence ?? 0) > 0, "First snapshot carries its source ordering token")
            let current = "Working 20%\n› 한글🧪abc\nCodex footer"
            let at = "Working 20%\n› 한글🧪a".utf16.count
            probe.change(current, cursor: at)
            // The first presentation read uses the same bounded live-read cache.
            try await Task.sleep(for: .milliseconds(220))
            let typed = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
            try expectEqual(typed.screen, current); try expectEqual(typed.cursor?.offset, at)
            try expectEqual(typed.streamID, first.streamID); try expect(typed.revision != first.revision)
            try expect(typed.sequence! > first.sequence!, "HTTP and SSE readers can order simultaneous source observations")
            _ = try await engine.remoteInput(["requestID": UUID().uuidString, "sessionID": session.id, "revision": typed.revision,
                "streamID": typed.streamID!, "relay": true, "kind": "characters", "text": "웹 입력 한글🧪"])
            try expectEqual(probe.count(), 1, "Displayed text must never replace the raw source used at input")
            probe.change(current, cursor: at - 1)
            let moved = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
            try expectEqual(moved.screen, current); try expectEqual(moved.cursor?.offset, at - 1)
            try expect(moved.revision != typed.revision, "Cursor movement without text change must publish a frame")
            try expectEqual(moved.streamID, first.streamID)
            try expect(moved.sequence! > typed.sequence!, "Consuming an input frame must not reset display ordering")
            engine.updateDiscovery([], records: [])
            do { _ = try await engine.remoteTerminal(sessionID: session.id); throw AppError.message("Ended source was displayed") }
            catch { try expect(error is RemoteHTTPError) }
        }
    }

    func testTargetedOriginalProcessReadMatchesDiscovery() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let all = try ProcessDiscovery.read()
        let selected = try ProcessDiscovery.read(pid: pid)
        try expectEqual(selected.count, 1)
        try expectEqual(selected.first, all.first { $0.pid == pid }, "Targeted verification retains the original PID/start/TTY/executable fields")
        let ended = Process(); ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run(); ended.waitUntilExit()
        try expect(try ProcessDiscovery.read(pid: ended.processIdentifier).isEmpty, "A process that ended cannot supply a replacement identity")
        try expectThrows(ProcessDiscovery.read(pid: 0))
    }

    func testCommandRunnerExitTimeoutAndConcurrentPipes() throws {
        for _ in 0..<20 {
            let result = try CommandRunner.run("/usr/bin/true", [])
            try expectEqual(result.status, 0); try expectEqual(result.output, ""); try expectEqual(result.error, "")
        }
        let text = "한글 🧪\n" + String(repeating: "pipe-data", count: 20_000)
        let echoed = try CommandRunner.run("/bin/cat", [], input: Data(text.utf8))
        try expectEqual(echoed.output, text); try expectEqual(echoed.status, 0)
        let both = try CommandRunner.run("/bin/sh", ["-c", "i=0; while [ $i -lt 10000 ]; do printf stdout; printf stderr >&2; i=$((i+1)); done; exit 7"])
        try expectEqual(both.status, 7); try expectEqual(both.output.count, 60_000); try expectEqual(both.error.count, 60_000)
        let started = ProcessInfo.processInfo.systemUptime
        do { _ = try CommandRunner.run("/bin/sleep", ["2"], timeout: 0.05); throw AppError.message("Child timeout was ignored") }
        catch let error as AppError { try expect(error.localizedDescription.contains("초과")) }
        try expect(ProcessInfo.processInfo.systemUptime - started < 1.5, "Waiting for completion must still enforce the command's timeout")
    }

    func testRemotePreferredPeerAddressKeepsSharedWiFiRoute() throws {
        let wifi = RemoteLANInterface(name: "en0", address: "192.168.43.2", netmask: "255.255.255.0", kind: .wifi)
        let ethernet = RemoteLANInterface(name: "en7", address: "10.2.3.4", netmask: "255.255.255.0", kind: .ethernet)
        let bonjour = NWEndpoint.service(name: UUID().uuidString, type: RemoteNetworkService.serviceType, domain: "local.", interface: nil)
        let wifiPeer = try RemoteNetworkAddress.endpoint("http://192.168.43.8:8765")
        let ethernetPeer = try RemoteNetworkAddress.endpoint("http://10.2.3.8:8765")
        let advertised = ["http://10.2.3.8:8765", "http://192.168.43.8:8765"]
        let chosen = RemoteLAN.preferredEndpoint(bonjour, addresses: advertised, port: 8765, interfaces: [ethernet, wifi])
        try expectEqual(chosen, wifiPeer, "An Ethernet-first advertisement must still use the shared Wi-Fi subnet")
        let parameters = try RemoteLAN.tcpParameters(to: chosen, interfaces: [ethernet, wifi])
        try expect((parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay == true,
            "LAN terminal traffic must not wait to batch small TCP writes")
        try expectEqual(parameters.requiredInterfaceType, .wifi)
        try expectEqual(parameters.requiredLocalEndpoint, .hostPort(host: "192.168.43.2", port: .any))
        let wiredParameters = try RemoteLAN.tcpParameters(to:ethernetPeer,interfaces:[wifi,ethernet])
        try expectEqual(wiredParameters.requiredInterfaceType,.wiredEthernet)
        try expectEqual(wiredParameters.requiredLocalEndpoint,.hostPort(host:"10.2.3.4",port:.any))
        try expectEqual(RemoteLAN.preferredEndpoint(bonjour, addresses: advertised, port: 8765, interfaces: [ethernet]), ethernetPeer)
        try expectEqual(RemoteLAN.preferredEndpoint(bonjour, addresses: ["http://192.168.43.8:8765"], port: 8765, interfaces: [ethernet]), bonjour,
                        "A cached address on a disconnected subnet cannot select that route")
        let rejected = ["http://8.8.8.8:8765", "http://192.168.43.8:9999", "https://192.168.43.8:8765",
                        "http://user@192.168.43.8:8765", "http://127.0.0.1:8765", "http://192.168.43.2:8765",
                        "http://192.168.43.8:8765/path", "http://10.1.2.3:8765", "http://[fe80::123]:8765"]
        try expectEqual(RemoteLAN.preferredEndpoint(bonjour, addresses: rejected, port: 8765, interfaces: [ethernet, wifi]), bonjour,
                        "Only a peer's matching port on a connected physical IPv4 subnet is preferred")
    }

    func testRemoteInputSerializesNativeApproval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoapprove-input-order-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("81001 1 ttys081 81001 81001 Mon Sep 21 09:00:01 2026 /usr/local/bin/codex")
        var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .iterm
        let screen = RemoteTestScreen(), gate = RemoteResumeGate()
        defer { gate.release() }
        screen.replace("Would you like to run the following command?\n\n  $ echo test\n\n› 1. Yes, proceed (y)\n  2. No (esc)\nPress enter to confirm or esc to cancel")
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.read()) }) },
            approve: { _, _, _ in _ = gate.wait(); return .missingTarget }, reveal: { _ in nil }, input: { _, expected, _, input in screen.input(expected, input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.iterm: adapter])
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records); await engine.connectScreenHost(.iterm)
        try engine.setAutomatic(session.id, enabled: true)
        for _ in 0..<100 where !gate.started { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(gate.started, "Native approval is already writing")
        let frame = try await engine.remoteTerminal(sessionID: session.id)
        let queued = Task { try await engine.remoteInput(["sessionID": session.id, "revision": frame.revision, "streamID": frame.streamID!, "relay": true, "kind": "characters", "text": "manual"] as JSONObject) }
        try await Task.sleep(nanoseconds: 50_000_000)
        try expectEqual(screen.count(), 0, "The live keyboard queues behind the native approval")
        try engine.setPaused(true); try engine.setPaused(false)
        gate.release(); _ = try await queued.value
        try expectEqual(screen.count(), 1); try expect(engine.snapshot.sessions.first?.automatic == true)
    }

    func testRemoteRelayWithAutomaticApprovalAndChangedOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoapprove-live-relay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("81001 1 ttys081 81001 81001 Mon Sep 21 09:00:01 2026 /usr/local/bin/codex")
        var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .iterm
        let screen = RemoteTestScreen()
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.read()) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { target, expected, _, input in
                guard target.tty == "/dev/ttys081", target.jobPIDs.contains(81001) else { return .missingTarget }
                return screen.input(expected, input)
            })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.iterm: adapter])
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records); await engine.connectScreenHost(.iterm)
        try engine.setAutomatic(session.id, enabled: true)
        let frame = try await engine.remoteTerminal(sessionID: session.id)
        try expectNil(frame.inputReason); try expectNotNil(frame.streamID)
        screen.change()
        let input: JSONObject = ["sessionID": session.id, "revision": frame.revision, "streamID": frame.streamID!, "relay": true, "kind": "characters", "text": "한글 🧪"]
        _ = try await engine.remoteInput(input)
        try expectEqual(screen.count(), 1, "Live keys survive unrelated output while automation stays on")
        let refreshed = try await engine.remoteTerminal(sessionID: session.id)
        try expect(refreshed.revision != frame.revision); try expectEqual(refreshed.streamID, frame.streamID)
        _ = try await engine.remoteInput(input)
        try expectEqual(screen.count(), 2, "A newer screen does not replace the identity of the live stream")
        var wrong = input; wrong["streamID"] = UUID().uuidString
        do { _ = try await engine.remoteInput(wrong); throw AppError.message("Expected wrong-stream refusal") }
        catch { try expect(error is RemoteHTTPError) }
        session.tty = "/dev/ttys082"; engine.updateDiscovery([session], records: records)
        do { _ = try await engine.remoteInput(input); throw AppError.message("Expected moved-target refusal") }
        catch { try expect(error is RemoteHTTPError) }
        try expectEqual(screen.count(), 2)
        try expect(engine.snapshot.sessions.first?.automatic == true)
    }

    func testRemoteOriginalTerminalAttributesAndColorOnlyFrames() async throws {
        let raw = "한글 🧪 Codex\nClaude"
        let original = TerminalAppearance(runs: [.init(offset: 3, length: 2, fg: "#d97757", bg: "#303030", bold: true)])
        try expectNil(TerminalCursor(offset: 4).validated(for: raw))
        try expectNil(TerminalCursor(offset: -1).validated(for: raw))
        try expectNil(TerminalCursor(offset: 0, padding: 501).validated(for: raw))
        try expectEqual(TerminalCursor.fromAccessibility(value: "history\n" + raw, insertion: 13, screen: raw)?.offset, 5)
        try expectNil(TerminalCursor.fromAccessibility(value: raw, insertion: 999, screen: raw))
        try expectNotNil(original.validated(for: raw))
        for invalid in [TerminalAppearance(runs: [.init(offset: 4, length: 1, fg: "#ffffff")]),
                        TerminalAppearance(runs: [.init(offset: 0, length: 999)]),
                        TerminalAppearance(runs: [.init(offset: -1, length: 1)]),
                        TerminalAppearance(runs: [.init(offset: 0, length: 2), .init(offset: 1, length: 1)]),
                        TerminalAppearance(runs: [.init(offset: 0, length: 1, fg: "url(https://example.com)")]),
                        TerminalAppearance(runs: [], background: "red;display:none"),
                        TerminalAppearance(runs: Array(repeating: .init(offset: 0, length: 1), count: 8001))] {
            try expectNil(invalid.validated(for: raw))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoapprove-original-colors-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        var session = ProcessDiscovery.sessions(ProcessDiscovery.parse("81001 1 ttys081 81001 81001 Mon Sep 21 09:00:01 2026 /usr/local/bin/codex"))[0]
        session.terminal = .vscode; session.channel = .vscodeScreen; session.bridgeID = "color-test"; session.terminalID = "color-terminal"
        engine.updateDiscovery([session], records: [])
        engine.receiveScreen(sessionID: session.id, raw: raw, generation: "color-generation", appearance: original)
        let first = try await engine.remoteTerminal(sessionID: session.id)
        try expectEqual(first.screen, raw); try expectEqual(first.appearance, original)
        let repeated = try await engine.remoteTerminal(sessionID: session.id)
        try expectEqual(first.revision, repeated.revision)
        let cursor = TerminalCursor(offset: 3)
        engine.receiveScreen(sessionID: session.id, raw: raw, generation: "color-generation", appearance: original, cursor: cursor)
        let cursorFrame = try await engine.remoteTerminal(sessionID: session.id)
        try expectEqual(cursorFrame.cursor, cursor); try expect(cursorFrame.revision != first.revision, "Cursor movement alone publishes a frame")
        let recolored = TerminalAppearance(runs: [.init(offset: 3, length: 2, fg: "#87d7ff", underline: true)])
        engine.receiveScreen(sessionID: session.id, raw: raw, generation: "color-generation", appearance: recolored)
        let next = try await engine.remoteTerminal(sessionID: session.id)
        try expectEqual(next.screen, first.screen); try expect(next.revision != first.revision)
        try expectEqual(next.appearance, recolored)
        let service = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, onStatus: { _ in })
        var query = URLComponents(); query.path = "/api/terminal"
        query.queryItems = [URLQueryItem(name: "session", value: session.id), URLQueryItem(name: "revision", value: next.revision)]
        let request = try RemoteHTTPRequest.parse(Data("GET \(query.string!) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))!
        let compact = await service.handle(request)
        try expectEqual(compact.status, 200)
        let object = try JSONSerialization.jsonObject(with: compact.body) as! JSONObject
        try expectNil(object["screen"]); try expectNil(object["appearance"])
        query.path = "/api/terminal/stream"; query.queryItems = [URLQueryItem(name: "session", value: session.id)]
        let streamRequest = try RemoteHTTPRequest.parse(Data("GET \(query.string!) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))!
        let streamed = await service.handle(streamRequest)
        try expectEqual(streamed.status, 200)
        let event = String(decoding: streamed.body, as: UTF8.self)
        try expect(event.hasPrefix("event: screen\n"), "The prepared first screen must be part of the HTTP response's initial write")
        guard let dataLine = event.components(separatedBy: "\n").first(where: { $0.hasPrefix("data: ") }) else {
            throw AppError.message("First screen event has no JSON data")
        }
        let initial = try JSONSerialization.jsonObject(with: Data(dataLine.dropFirst(6).utf8)) as! JSONObject
        try expectEqual(initial["sessionID"] as? String, session.id); try expectEqual(initial["screen"] as? String, raw)
        try expectEqual(initial["revision"] as? String, next.revision)
        engine.receiveScreen(sessionID: session.id, raw: raw, generation: "color-generation")
        let plain = try await engine.remoteTerminal(sessionID: session.id)
        try expectNil(plain.appearance); try expect(plain.revision != next.revision)
    }

    func testRemoteTerminalCoalescingExpiryAndConditionalPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoapprove-remote-fast-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("81001 1 ttys081 81001 81001 Mon Sep 21 09:00:01 2026 /usr/local/bin/codex")
        var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .terminal
        let probe = RemoteReadProbe()
        let adapter = ScreenHostAdapter(screens: { TerminalSnapshot(screens: $0.map { probe.read($0.tty) }) }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records); await engine.connectTerminal()
        let baseline = probe.count(), id = session.id
        async let first = engine.remoteTerminal(sessionID: id)
        async let second = engine.remoteTerminal(sessionID: id)
        async let third = engine.remoteTerminal(sessionID: id)
        let (a, b, c) = try await (first, second, third)
        try expectEqual(probe.count() - baseline, 1, "Concurrent browsers share one screen read")
        try expectEqual(a.revision, b.revision); try expectEqual(a.revision, c.revision)
        try engine.setAutomatic(session.id, enabled: true)
        let controls = try await engine.remoteTerminal(sessionID: session.id)
        try expectNil(controls.inputReason)
        try expectEqual(controls.observedAt, a.observedAt, "Cached reads retain the real observation time")
        try expectEqual(probe.count() - baseline, 1)
        let service = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, onStatus: { _ in })
        func request(_ revision: String? = nil) throws -> RemoteHTTPRequest {
            var query = URLComponents(); query.path = "/api/terminal"; query.queryItems = [URLQueryItem(name: "session", value: session.id)]
            if let revision { query.queryItems?.append(URLQueryItem(name: "revision", value: revision)) }
            return try RemoteHTTPRequest.parse(Data("GET \(query.string!) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))!
        }
        let full = await service.handle(try request()), compact = await service.handle(try request(a.revision))
        let fullObject = try JSONSerialization.jsonObject(with: full.body) as! JSONObject
        let compactObject = try JSONSerialization.jsonObject(with: compact.body) as! JSONObject
        try expectEqual(full.status, 200); try expectEqual(compact.status, 200)
        try expectEqual(fullObject["screen"] as? String, a.screen); try expectNil(compactObject["screen"])
        try expectEqual(compactObject["revision"] as? String, a.revision)
        try expectNil(compactObject["inputReason"])
        try expect(compact.body.count < full.body.count / 10, "An unchanged frame omits the screen payload")
        probe.change(); try await Task.sleep(nanoseconds: 700_000_000)
        let changed = try await engine.remoteTerminal(sessionID: session.id)
        try expect(changed.revision != a.revision); try expect(changed.screen.contains("새 출력"))
        try expectEqual(probe.count() - baseline, 2, "Expired cache reads the host again")
        session.tty = "/dev/ttys082"; engine.updateDiscovery([session], records: records)
        let moved = try await engine.remoteTerminal(sessionID: session.id)
        try expect(moved.revision != changed.revision, "A changed target always consumes the old frame")
        try expectEqual(probe.count() - baseline, 3)
        probe.change(); try await Task.sleep(nanoseconds: 700_000_000)
        let pending = Task { try await engine.remoteTerminal(sessionID: session.id) }
        for _ in 0..<50 where probe.count() - baseline < 4 { try await Task.sleep(nanoseconds: 5_000_000) }
        engine.disconnectTerminal()
        do { _ = try await pending.value; throw AppError.message("Expected disconnected read refusal") }
        catch { try expect(error is RemoteHTTPError, "An old in-flight read cannot restore a disconnected frame") }
    }

    func testInitialTerminalReusesOnlyVerifiedRecentMonitor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-terminal-entry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("88 1 ttys080 88 88 Tue Sep 22 15:00:00 2026 /usr/local/bin/codex")
        var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .terminal
        let probe = RemoteReadProbe()
        let adapter = ScreenHostAdapter(screens: { TerminalSnapshot(screens: $0.map { probe.read($0.tty) }) },
            approve: { _,_,_ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records)
        let before = Date(); await engine.connectTerminal()
        let baseline = probe.count()
        let first = try await engine.remoteTerminal(sessionID: session.id, realtime: true, initial: true)
        try expectEqual(probe.count(), baseline, "First subscription must reuse the monitor's actual screen without another host read")
        try expect(first.observedAt >= before && first.observedAt.timeIntervalSinceNow < -0.06, "Retain the real conservative observation time")
        probe.change()
        let live = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        try expectEqual(probe.count(), baseline + 1, "The live stream must immediately read current output")
        try expect(live.screen.contains("새 출력")); try expect(live.revision != first.revision)
        try await Task.sleep(for: .milliseconds(2100))
        _ = try await engine.remoteTerminal(sessionID: session.id, initial: true)
        try expectEqual(probe.count(), baseline + 2, "Expired monitoring cannot stand in for a fresh first frame")
        session.tty = "/dev/ttys081"; engine.updateDiscovery([session], records: records)
        _ = try await engine.remoteTerminal(sessionID: session.id, initial: true)
        try expectEqual(probe.count(), baseline + 3, "A different TTY must not inherit monitoring")
        engine.disconnectTerminal()
        do { _ = try await engine.remoteTerminal(sessionID: session.id, initial: true); throw AppError.message("Disconnected monitor accepted") }
        catch { try expect(error is RemoteHTTPError) }
    }

    func testInitialTerminalRejectsChangedOriginalProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-terminal-entry-life-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("88 1 ttys080 88 88 Tue Sep 22 15:00:00 2026 /usr/local/bin/codex")
        var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .terminal
        let probe = RemoteReadProbe()
        let adapter = ScreenHostAdapter(screens: { TerminalSnapshot(screens: $0.map { probe.read($0.tty) }) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records); await engine.connectTerminal()
        let baseline = probe.count()
        do { _ = try await engine.remoteTerminal(sessionID: session.id, initial: true); throw AppError.message("Ended process's monitored screen accepted") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
        try expectEqual(probe.count(), baseline, "An old binding cannot read or expose a replacement terminal")
        engine.updateDiscovery([], records: [])
        do { _ = try await engine.remoteTerminal(sessionID: session.id, initial: true); throw AppError.message("Ended session accepted") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
    }

    func testTextTerminalChecksOnlyRequiredPermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-text-permissions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("88 1 ttys080 88 88 Tue Sep 22 15:00:00 2026 /usr/local/bin/codex")
        var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .terminal
        let probe = RemotePermissionProbe(), screens = RemoteReadProbe()
        let capture = TerminalWindowCapture(permissions: {
            probe.full += 1
            return TerminalWindowPermissions(screen: false, keyboard: false, automation: probe.automationAllowed)
        }, automationPermission: { probe.automation += 1; return probe.automationAllowed },
           keyboardPermission: { probe.keyboard += 1; return false })
        let adapter = ScreenHostAdapter(screens: { TerminalSnapshot(screens: $0.map { screens.read($0.tty) }) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records },
            screenAdapters: [.terminal: adapter], terminalWindowCapture: capture, terminalInputAvailable: { false })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records); await engine.connectTerminal()
        probe.full = 0; probe.automation = 0; probe.keyboard = 0
        let first = try await engine.remoteTerminal(sessionID: session.id, initial: true)
        try expect(!first.screen.isEmpty); try expectNil(first.nativeDisplay)
        try expectEqual(probe.full, 0, "Text streaming must not query screen recording or accessibility")
        try expectEqual(probe.automation, 1); try expectEqual(probe.keyboard, 0)
        probe.automationAllowed = false
        let denied = try await engine.remoteTerminal(sessionID: session.id, initial: true)
        try expect(denied.keys.isEmpty); try expectEqual(denied.screen, "")
        try expectEqual(probe.full, 0); try expectEqual(probe.automation, 2, "Recheck live Automation permission even on a cached screen")
        probe.automationAllowed = true
        let native = try await engine.remoteTerminal(sessionID: session.id, renderWindow: true)
        try expectEqual(native.nativeDisplay?.state, .permissionRequired)
        try expect(probe.full > 0, "Explicit native preview must retain all capture permission checks")
        try expect(!capture.keyboardPermissionGranted); try expectEqual(probe.keyboard, 1)
        let legacy = TerminalWindowCapture(permissions: { TerminalWindowPermissions(screen: false, keyboard: false, automation: false) })
        try expect(!legacy.nonpromptAutomationGranted); try expect(!legacy.keyboardPermissionGranted)
    }

    func testRemoteTerminalReadStopsAtExactTarget() throws {
        let context = JSContext()!
        context.evaluateScript("""
        var reads = 0;
        function Application() { return {running:()=>true, windows:()=>[
          {tabs:()=>[{tty:()=>'/dev/ttys081',customTitle:()=>'',contents:()=>{reads++;return '✓ frame';}}],name:()=> 'Codex'},
          {tabs:()=>{throw Error('unrelated window must not be visited');}}
        ]}; }
        """)
        let script = try TerminalAdapter.screenScript(ttys: ["/dev/ttys081"])
        let data = Data(context.evaluateScript(script)!.toString()!.utf8)
        let result = try JSONDecoder().decode(TerminalSnapshot.self, from: data)
        try expectEqual(result.screens.count, 1); try expect(result.failures.isEmpty)
        try expectEqual(context.evaluateScript("reads")?.toInt32(), 1)
    }

    func testRemoteHTTPBoundsOriginAndPrivateAddresses() throws {
        let older = RemoteWebVersion(version: "0.2.9", build: 20), newer = RemoteWebVersion(version: "0.2.10", build: 1)
        try expect(older < newer, "Compare numeric version components, not strings or build alone")
        try expect(newer < RemoteWebVersion(version: "0.2.10", build: 2))
        try expect(RemoteWebVersion.current?.isCompatible == true, "Packaged and CLI web resources publish the same release")
        for version in ["", "v0.2.10", "0.02.10", "0.2", "0.2.10-beta", "99.2.10\r\nLocation: http://example.com", "０.2.10", "1000000.2.10"] {
            try expect(!RemoteWebVersion(version: version, build: 1).isCompatible, version)
        }
        try expect(!RemoteWebVersion(version: "0.2.10", build: 1, api: 2).isCompatible)
        try expect(!RemoteWebVersion(version: "0.2.10", build: 0).isCompatible)
        for site in ["same-site", "cross-site"] {
            let navigation = "GET /?webNode=fixture HTTP/1.1\r\nHost: 192.168.43.2:8765\r\nSec-Fetch-Site: \(site)\r\nSec-Fetch-Mode: navigate\r\nSec-Fetch-Dest: document\r\n\r\n"
            try RemoteHTTPRequest.parse(Data(navigation.utf8))!.validateOrigin()
            for denied in [navigation.replacingOccurrences(of: "GET /?webNode=fixture", with: "GET /api/state"),
                           navigation.replacingOccurrences(of: "Dest: document", with: "Dest: iframe"),
                           navigation.replacingOccurrences(of: "Mode: navigate", with: "Mode: cors"),
                           navigation.replacingOccurrences(of: "\r\n\r\n", with: "\r\nOrigin: https://unrelated.example\r\n\r\n")] {
                try expectThrows(try RemoteHTTPRequest.parse(Data(denied.utf8))!.validateOrigin())
            }
        }
        let up = UInt32(IFF_UP)
        try expect(RemoteLAN.isPhysicalInterface(name: "en0", flags: up))
        try expect(RemoteLAN.isPhysicalInterface(name: "en7", flags: up))
        for name in ["utun0", "ipsec0", "ppp0", "lo0", "bridge100", "awdl0"] {
            try expect(!RemoteLAN.isPhysicalInterface(name: name, flags: up), "Exclude tunnel and virtual addresses: " + name)
        }
        try expect(!RemoteLAN.isPhysicalInterface(name: "en0", flags: 0))
        try expect(!RemoteLAN.isPhysicalInterface(name: "en0", flags: up | UInt32(IFF_POINTOPOINT)))
        let wifi = RemoteLANInterface(name: "en1", address: "172.20.10.2", netmask: "255.255.255.240", kind: .wifi)
        let ethernet = RemoteLANInterface(name: "en0", address: "10.2.3.4", netmask: "255.255.255.0", kind: .ethernet)
        let interfaces = [ethernet, wifi]
        try expectEqual(RemoteLAN.ordered(interfaces).first, wifi, "Wi-Fi is offered before Ethernet regardless of BSD name")
        try expectEqual(RemoteLAN.route(to: "172.20.10.1", interfaces: interfaces), wifi)
        try expectEqual(RemoteLAN.route(to: "10.2.3.8", interfaces: interfaces), ethernet)
        try expectNil(RemoteLAN.route(to: "10.200.1.8", interfaces: interfaces))
        let broader = RemoteLANInterface(name: "en9", address: "172.20.1.2", netmask: "255.255.0.0", kind: .ethernet)
        try expectEqual(RemoteLAN.route(to: "172.20.10.1", interfaces: [broader, wifi]), wifi, "Use the most specific connected subnet")
        let overlap = RemoteLANInterface(name: "en0", address: "172.20.10.3", netmask: wifi.netmask, kind: .ethernet)
        try expectEqual(RemoteLAN.route(to: "172.20.10.1", interfaces: [overlap, wifi]), wifi, "Prefer Wi-Fi when two LANs overlap")
        func parameters(_ address: String, _ interfaces: [RemoteLANInterface]) throws -> NWParameters {
            try RemoteLAN.tcpParameters(to: RemoteNetworkAddress.endpoint(address), interfaces: interfaces)
        }
        let wifiParameters = try parameters("172.20.10.1:8765", interfaces)
        try expectEqual(wifiParameters.requiredInterfaceType, .wifi)
        try expectEqual(wifiParameters.requiredLocalEndpoint, .hostPort(host: "172.20.10.2", port: .any))
        try expect(wifiParameters.prohibitedInterfaceTypes?.contains(.other) == true)
        try expectEqual(try parameters("10.2.3.8:8765", interfaces).requiredInterfaceType, .wiredEthernet)
        try expectNil(try parameters("127.0.0.1:8765", []).requiredLocalEndpoint)
        try expectNil(try parameters("172.20.10.2:8765", interfaces).requiredLocalEndpoint)
        try expectThrows(try parameters("10.200.1.8:8765", interfaces))
        try expectThrows(try parameters("172.20.10.1:8765", [ethernet]))
        let hotspot = RemoteNetworkAddress.discoveryURLs(address: "172.20.10.2", netmask: "255.255.255.240")
        try expectEqual(hotspot.count, 13)
        try expect(hotspot.contains("http://172.20.10.1:8765") && hotspot.contains("http://172.20.10.14:8765"))
        try expect(!hotspot.contains("http://172.20.10.2:8765") && !hotspot.contains("http://172.20.10.15:8765"))
        try expectEqual(RemoteNetworkAddress.discoveryURLs(address: "192.168.43.8", netmask: "255.255.255.0").count, 253)
        try expectEqual(RemoteNetworkAddress.discoveryURLs(address: "10.2.3.4", netmask: "255.0.0.0").count, 253, "Large private networks are bounded to the local /24")
        for (ip, mask) in [("8.8.8.8", "255.255.255.0"), ("127.0.0.1", "255.0.0.0"), ("10.0.0.2", "255.0.255.0"), ("10.0.0.2", "255.255.255.255")] {
            try expect(RemoteNetworkAddress.discoveryURLs(address: ip, netmask: mask).isEmpty)
        }
        var status = RemoteNetworkStatus()
        status.urls = ["http://autoapprove.local:8765", "http://autoapprove-example.local:8765", "http://172.20.10.2:8765", "http://192.168.43.2:54321"]
        try expectEqual(status.directURLs, ["http://172.20.10.2:8765", "http://192.168.43.2:54321"], "Phone QR addresses must bypass .local and preserve the actual port")
        status.urls = ["http://autoapprove.local:8765"]
        try expect(status.directURLs.isEmpty, "An unresolved phone address must not silently fall back to Bonjour")
        let bytes = Data("POST /api/action?node=example HTTP/1.1\r\nHost: 192.168.43.2:8765\r\nOrigin: http://192.168.43.2:8765\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        try expectNil(try RemoteHTTPRequest.parse(bytes.dropLast()))
        let request = try RemoteHTTPRequest.parse(bytes)!
        try request.validateOrigin(); try expectEqual(request.path, "/api/action"); try expectEqual(request.parameter("node"), "example")
        try expectEqual(try request.json().count, 0)
        // A phone still needs DNS to resolve this name; accepting it is only the HTTP step.
        for host in ["approve:8765", "APPROVE:8765", "approve.:8765"] {
            let named = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "192.168.43.2:8765", with: host)
            try RemoteHTTPRequest.parse(Data(named.utf8))!.validateOrigin()
            let foreignOrigin = named.replacingOccurrences(of: "Origin: http://" + host, with: "Origin: https://unrelated.example")
            try expectThrows(try RemoteHTTPRequest.parse(Data(foreignOrigin.utf8))!.validateOrigin())
        }
        for host in ["approve.attacker.example:8765", "other:8765", "approve@attacker.example:8765"] {
            let named = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "192.168.43.2:8765", with: host)
            try expectThrows(try RemoteHTTPRequest.parse(Data(named.utf8))!.validateOrigin())
        }
        try expect(!RemoteNetworkAddress.isLocalHost("approve"), "A permitted HTTP name must not bypass peer address restrictions")
        let browserQuery = try RemoteHTTPRequest.parse(Data("GET /api/terminal?session=process%3Adate+with+spaces%2Band HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))!
        try expectEqual(browserQuery.parameter("session"), "process:date with spaces+and")
        let invalid = [
            String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Origin: http://192.168.43.2:8765", with: "Origin: https://unrelated.example"),
            String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Host: 192.168.43.2:8765", with: "Host: attacker.example"),
            String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "Origin: http://192.168.43.2:8765", with: "Sec-Fetch-Site: cross-site")
        ]
        for value in invalid { try expectThrows(try RemoteHTTPRequest.parse(Data(value.utf8))!.validateOrigin()) }
        try expectThrows(try RemoteHTTPRequest.parse(bytes + Data("GET / HTTP/1.1\r\n\r\n".utf8)))
        try expectThrows(try RemoteHTTPRequest.parse(Data(("GET / HTTP/1.1\r\n" + String(repeating: "x", count: 20_000)).utf8)))
        try expectThrows(try RemoteHTTPRequest.parse(Data("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n".utf8)))
        try expectThrows(try RemoteHTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 2\r\n\r\n".utf8)))
        for address in ["192.168.43.1", "10.0.0.2", "172.20.10.2", "169.254.1.2", "127.0.0.1", "fe80::1", "fd00::1", "::1", "::ffff:192.168.1.2", "mac.local"] {
            try expect(RemoteNetworkAddress.isLocalHost(address), address)
        }
        for address in ["8.8.8.8", "172.32.0.1", "192.169.0.1", "example.com", "2001:4860:4860::8888", "::ffff:8.8.8.8", "192.168.1.2.attacker.example"] {
            try expect(!RemoteNetworkAddress.isLocalHost(address), address)
        }
        _ = try RemoteNetworkAddress.endpoint("http://192.168.43.2:8765")
        for value in ["https://192.168.1.2", "http://user@192.168.1.2", "http://example.com", "http://192.168.1.2:999999", "http://192.168.1.2/path", "http://192.168.1.2?url=example.com"] {
            try expectThrows(try RemoteNetworkAddress.endpoint(value))
        }
    }

    func testRemoteTerminalExactTargetStaleFrameAndDurableReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autoapprove-remote-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        81000 1 ?? 81000 0 Mon Sep 21 09:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        81001 81000 ttys081 81001 81001 Mon Sep 21 09:00:01 2026 /usr/local/bin/codex
        """)
        let screen = RemoteTestScreen(), resume = RemoteResumeGate()
        defer { resume.release() }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let originalIdentity = TTYInputIdentity(pid: 81001, processGroup: 81001, uid: getuid(), effectiveUID: geteuid(), device: 42,
            startSeconds: UInt64(formatter.date(from: records[1].started)!.timeIntervalSince1970), startMicroseconds: 71)
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.read(), title: "검증용 터미널") }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, resume: { _, _, _ in resume.wait() }, input: { target, expected, agent, input in
                guard target.tty == "/dev/ttys081", target.jobPIDs.contains(81001), agent == .codex else { return .missingTarget }
                return screen.input(expected, input)
            })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.terminal: adapter],
            terminalInputAvailable: { true }, terminalInputIdentity: { pid in pid == originalIdentity.pid ? originalIdentity : nil })
        let session = ProcessDiscovery.sessions(records)[0]
        engine.updateDiscovery([session], records: records); await engine.connectTerminal()
        let frame = try await engine.remoteTerminal(sessionID: session.id)
        try expect(frame.keys.contains("submit") && frame.keys.contains("enter"))
        try expect(frame.keys.contains("characters"), "The injected original input service is available independently of Mac permissions")
        let secondViewer = try await engine.remoteTerminal(sessionID: session.id)
        try expectEqual(secondViewer.revision, frame.revision)
        let latest = try await engine.remoteTerminal(sessionID: session.id)
        let service = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, onStatus: { _ in })
        let pauseBody = try JSONSerialization.data(withJSONObject: ["action": "pause", "paused": true, "requestID": UUID().uuidString] as JSONObject)
        let wrongMac = try RemoteHTTPRequest.parse(Data("POST /api/action HTTP/1.1\r\nHost: localhost\r\nX-AutoApprove-Node: \(UUID().uuidString)\r\nContent-Type: application/json\r\nContent-Length: \(pauseBody.count)\r\n\r\n".utf8) + pauseBody)!
        try expectEqual(await service.handle(wrongMac).status, 409)
        try expect(!engine.snapshot.paused, "A reused address must not control a different Mac")
        func request(_ object: JSONObject) throws -> RemoteHTTPRequest {
            let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let head = Data("POST /api/input HTTP/1.1\r\nHost: localhost:8765\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
            return try RemoteHTTPRequest.parse(head + body)!
        }
        let requestID = UUID().uuidString
        let input = try request(["sessionID": session.id, "revision": latest.revision, "kind": "submit", "text": "한글 · exact target", "requestID": requestID])
        let first = await service.handle(input), duplicate = await service.handle(input)
        try expectEqual(first.status, 200); try expectEqual(duplicate.body, first.body); try expectEqual(screen.count(), 1)
        try expect(screen.read().hasSuffix("한글 · exact target\r"), "Text and Return must use one target-validated write")
        let restored = RemoteNetworkService(engine: engine, nodeID: service.nodeID, onStatus: { _ in })
        let replay = await restored.handle(input); try expectEqual(replay.status, 200); try expectEqual(screen.count(), 1)
        let conflict = await restored.handle(try request(["sessionID": session.id, "revision": latest.revision, "kind": "text", "text": "different", "requestID": requestID]))
        try expectEqual(conflict.status, 409); try expectEqual(screen.count(), 1)
        let stale = try await engine.remoteTerminal(sessionID: session.id); screen.change()
        let changed = await service.handle(try request(["sessionID": session.id, "revision": stale.revision, "kind": "enter", "text": "", "requestID": UUID().uuidString]))
        try expectEqual(changed.status, 409); try expectEqual(screen.count(), 1)
        let changedFrame = try await engine.remoteTerminal(sessionID: session.id)
        try expect(changedFrame.revision != stale.revision)
        let events = engine.snapshot.events.filter { $0.source == "같은 네트워크 웹" }
        try expect(events.contains { $0.answer == "한글 · exact target" && $0.outcome == "웹 입력 전달" })
        let unavailable = await service.handle(try RemoteHTTPRequest.parse(Data("GET /api/hook HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))!)
        try expectEqual(unavailable.status, 404)

        // Pausing automation cannot interrupt a host write already in progress.
        // A phone must wait for that write before manually entering anything.
        let rows: [Int: String] = [1: "  >_ OpenAI Codex (v0.158.0)", 2: "     /private/tmp/web-qa",
            7: "› 작업을 시작하자.", 10: "■ Selected model is at capacity. Please try a different model.",
            26: "› Ask Codex to do anything", 28: "  mock-model default · /private/tmp/web-qa",
            29: "  ← for agents · ? for shortcuts                                                               ⚠ 1 warning · f2 to view"]
        let stopped = (0..<30).map { rows[$0] ?? "" }.joined(separator: "\n")
        screen.replace(stopped); engine.capacityResumeDelays = [0]
        try engine.setAutomatic(session.id, enabled: true)
        engine.receiveScreen(sessionID: session.id, raw: stopped, generation: "web-capacity", source: .terminalScreen)
        for _ in 0..<200 where !resume.started { try await Task.sleep(nanoseconds: 10_000_000) }
        try expect(resume.started, "The existing host write must be in progress")
        try engine.setPaused(true)
        let busyFrame = try await engine.remoteTerminal(sessionID: session.id)
        do {
            _ = try await engine.remoteInput(["sessionID": session.id, "revision": busyFrame.revision, "kind": "enter", "text": ""])
            throw AppError.message("Expected existing host input exclusion")
        } catch {
            try expect((error as? RemoteHTTPError)?.message.contains("이어서 진행") == true)
            try expectEqual(screen.count(), 1)
        }
        try expectNil(busyFrame.inputReason)
        let queued = Task { try await engine.remoteInput(["sessionID": session.id, "revision": busyFrame.revision,
            "streamID": busyFrame.streamID!, "relay": true, "kind": "enter", "text": ""] as JSONObject) }
        try await Task.sleep(nanoseconds: 50_000_000)
        try expectEqual(screen.count(), 1, "User input waits for the already dispatched automatic write")
        resume.release()
        _ = try await queued.value
        try expectEqual(screen.count(), 2)
        try expect(engine.snapshot.sessions.first?.automatic == true)
        for _ in 0..<100 where engine.snapshot.sessions.first?.capacityResume?.phase == .sending { try await Task.sleep(nanoseconds: 10_000_000) }
        engine.stop()
    }

    func testRemoteTerminalScriptValidationAndKeys() throws {
        let context = JSContext()!
        context.evaluateScript("""
        var writes = []; var contents = 'screen'; var processes = ['codex'];
        function Application() { return {running:()=>true, windows:()=>[
          {tabs:()=>{throw Error('closed tab');}},
          {tabs:()=>[{tty:()=>'/dev/ttys081', contents:()=>contents, processes:()=>processes}]}
        ], doScript:(text)=>writes.push(text)}; }
        """)
        let target = ScreenTarget(tty: "/dev/ttys081", jobPIDs: [81001])
        let script = try RemoteTerminalAdapter.script(host: .terminal, target: target, expected: "screen", agent: .codex, input: .init(kind: .text, text: "한글 ` $(anything)"))
        try expectEqual(context.evaluateScript(script)?.toString(), "sent")
        try expectEqual(context.evaluateScript("writes.length")?.toInt32(), 1)
        context.evaluateScript("contents = 'changed';")
        try expectEqual(context.evaluateScript(script)?.toString(), "screenChanged")
        context.evaluateScript("contents = 'screen'; processes = ['zsh'];")
        try expectEqual(context.evaluateScript(script)?.toString(), "agentMissing")
        try expectEqual(context.evaluateScript("writes.length")?.toInt32(), 1)
        context.evaluateScript("processes = ['codex'];")
        let submit = try RemoteTerminalAdapter.script(host: .terminal, target: target, expected: "screen", agent: .codex, input: .init(kind: .submit, text: "한글"))
        try expectEqual(context.evaluateScript(submit)?.toString(), "sent")
        try expectEqual(context.evaluateScript("writes.pop()")?.toString(), "한글", "Terminal doScript supplies its own Return")
        try expectThrows(try RemoteTerminalInput(kind: .text, text: "bad\u{1b}").validate())
        try expectThrows(try RemoteTerminalInput(kind: .text, text: "bad\u{7f}").validate())
        try expectThrows(try RemoteTerminalInput(kind: .text, text: String(repeating: "한", count: 3000)).validate())
        try expectThrows(try RemoteTerminalInput(kind: .characters, text: "hidden\nReturn").validate())
        try expectThrows(try RemoteTerminalInput(kind: .backspace, text: "hidden text").validate())

        // JXA prepares only the exact tab/window. Native CGEvent delivery is
        // checked by the isolated keyboard fixture, with no real event posts.
        let keyboard = JSContext()!
        keyboard.evaluateScript("""
        var keys = [], contents = 'screen', front = true, wrongTab = false, changeOnActivate = false, childAXChecks = 0;
        var ObjC = {import:()=>{}}; var $ = {AXIsProcessTrusted:()=>{childAXChecks++; return false;}};
        var tab = {tty:()=>'/dev/ttys081', contents:()=>contents, processes:()=>['codex']};
        var win = {id:()=>96, tabs:()=>[tab]};
        Object.defineProperty(win, 'selectedTab', {set:()=>{}, get:()=>()=>wrongTab ? {tty:()=>'/dev/other'} : tab});
        function Application(id) {
          if (id === 'com.apple.systemevents') return {keystroke:text=>keys.push(text), keyCode:(code,options)=>keys.push([code,options])};
          return {running:()=>true, windows:()=>[win], frontmost:()=>front, activate:()=>{if(changeOnActivate) contents='changed';}};
        }
        """)
        for input in [RemoteTerminalInput(kind: .characters, text: "한글 🧪"), .init(kind: .backspace), .init(kind: .left), .init(kind: .right), .init(kind: .interrupt)] {
            let keyScript = try RemoteTerminalAdapter.script(host: .terminal, target: target, expected: "screen", agent: .codex, input: input)
            try expectEqual(keyboard.evaluateScript(keyScript)?.toString(), "ready:96")
        }
        try expectEqual(keyboard.evaluateScript("keys.length + childAXChecks")?.toInt32(), 0)
        let raw = try RemoteTerminalAdapter.script(host: .terminal, target: target, expected: "screen", agent: .codex, input: .init(kind: .characters, text: "never send"))
        keyboard.evaluateScript("wrongTab=true;")
        try expectEqual(keyboard.evaluateScript(raw)?.toString(), "missingTarget")
        keyboard.evaluateScript("wrongTab=false; front=false;")
        try expectEqual(keyboard.evaluateScript(raw)?.toString(), "missingTarget")
        keyboard.evaluateScript("front=true; changeOnActivate=true;")
        try expectEqual(keyboard.evaluateScript(raw)?.toString(), "screenChanged")
        try expectEqual(keyboard.evaluateScript("keys.length")?.toInt32(), 0)
        let liveKey = try RemoteTerminalAdapter.script(host: .terminal, target: target, expected: "screen", agent: .codex, input: .init(kind: .left, relay: true))
        try expectEqual(keyboard.evaluateScript(liveKey)?.toString(), "ready:96", "Live keys prepare the exact tab while output changes")
        keyboard.evaluateScript("wrongTab=true;")
        try expectEqual(keyboard.evaluateScript(liveKey)?.toString(), "missingTarget")

        let iterm = JSContext()!
        iterm.evaluateScript("""
        var writes = []; var job = 81001; var contents = 'scrollback\\nscreen   \\n';
        function Application() { return {running:()=>true, windows:()=>[
          {tabs:()=>{throw Error('closed tab');}},
          {tabs:()=>[{sessions:()=>[
            {tty:()=>'/dev/other', write:()=>{throw Error('wrong target');}},
            {tty:()=>'/dev/ttys081', contents:()=>contents, rows:()=>1, variable:()=>String(job), write:(command)=>writes.push(command)}
          ]}]}
        ]}; }
        """)
        for input in [RemoteTerminalInput(kind: .text, text: "한글"), .init(kind: .submit, text: "한글"), .init(kind: .characters, text: "완성한 한글"), .init(kind: .enter), .init(kind: .escape), .init(kind: .interrupt), .init(kind: .up), .init(kind: .down), .init(kind: .left), .init(kind: .right), .init(kind: .backspace), .init(kind: .delete), .init(kind: .home), .init(kind: .end), .init(kind: .tab)] {
            let rawKeys = try RemoteTerminalAdapter.script(host: .iterm, target: target, expected: "screen", agent: .codex, input: input)
            try expectEqual(iterm.evaluateScript(rawKeys)?.toString(), "sent")
            try expectFalse(iterm.evaluateScript("writes[0].newline")!.toBool())
            try expectEqual(iterm.evaluateScript("writes.pop().text")?.toString(), input.bytes)
        }
        let interrupt = try RemoteTerminalAdapter.script(host: .iterm, target: target, expected: "screen", agent: .codex, input: .init(kind: .interrupt))
        iterm.evaluateScript("job = 99999;")
        try expectEqual(iterm.evaluateScript(interrupt)?.toString(), "agentMissing")
        iterm.evaluateScript("contents = 'changed';")
        try expectEqual(iterm.evaluateScript(interrupt)?.toString(), "screenChanged")
        try expectEqual(iterm.evaluateScript("writes.length")?.toInt32(), 0)
        let liveInterrupt = try RemoteTerminalAdapter.script(host: .iterm, target: target, expected: "screen", agent: .codex, input: .init(kind: .interrupt, relay: true))
        try expectEqual(iterm.evaluateScript(liveInterrupt)?.toString(), "agentMissing")
        iterm.evaluateScript("job = 81001;")
        try expectEqual(iterm.evaluateScript(liveInterrupt)?.toString(), "sent")
    }
}
