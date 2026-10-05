// Injected original transport checks. No live window, permission prompt or CLI.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AutoApproveCore
import Darwin
import TerminalInputSupport

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw AppError.message(message) }
}

private final class ViewProbe: @unchecked Sendable {
    let lock = NSLock()
    var records = ProcessDiscovery.parse("85006 1 ttys088 85006 85006 Mon Oct 5 09:00:06 2026 /private/fixture/codex")
    var permissions = TerminalWindowPermissions(screen: true, keyboard: false, automation: true)
    var identity: TTYInputIdentity = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return TTYInputIdentity(pid: 85006, processGroup: 85006, uid: getuid(), effectiveUID: geteuid(), device: 42,
            startSeconds: UInt64(formatter.date(from: "Mon Oct 5 09:00:06 2026")!.timeIntervalSince1970), startMicroseconds: 71)
    }()
    var captures = 0, requests = 0, keyboardRequests = 0, reveals = 0, writes = [RemoteTerminalInput]()
    var failMetadata = false
    func read<T>(_ body: (ViewProbe) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    func mutate(_ body: (ViewProbe) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
    func image() throws -> TerminalNativeImage {
        let pixels = Data(repeating: 255, count: 64)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw AppError.message("Private image creation failed") }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw AppError.message("Private image encoder failed") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppError.message("Private JPEG encoding failed") }
        return TerminalNativeImage(data: (bytes as Data).base64EncodedString(), width: 4, height: 4)
    }
    @MainActor func capture() -> TerminalWindowCapture {
        TerminalWindowCapture(permissions: { [self] in read { $0.permissions } }, requestPermissions: { [self] in
            mutate { $0.requests += 1; $0.permissions.screen = true }
        }, metadata: { [self] tty in
            if read({ $0.failMetadata }) { throw AppError.message("Private window metadata unavailable") }
            return TerminalWindowMetadata(tty: tty, windowID: 96, ownerPID: 906, ownerBundleID: "com.apple.Terminal", selected: true, minimized: false)
        }, capture: { [self] _ in mutate { $0.captures += 1 }; return try image() })
    }
    var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map {
            TerminalScreen(tty: $0.tty, contents: "original terminal output", cursor: TerminalCursor(offset: 24, style: .bar))
        }) }, approve: { _, _, _ in .missingTarget }, reveal: { [self] target in
            guard target.tty == "/dev/ttys088" else { throw AppError.message("Another original must never be revealed") }
            mutate { $0.reveals += 1 }; return nil
        }, input: { [self] target, _, _, value in
            guard target.tty == "/dev/ttys088", target.jobPIDs.contains(85006), target.sourceIdentity == read({ $0.identity }) else { return .missingTarget }
            mutate { $0.writes.append(value) }; return .sent
        })
    }
}

@main struct TerminalViewChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), probe = ViewProbe(), capture = probe.capture()
        var source = ProcessDiscovery.sessions(probe.read { $0.records })[0]; source.terminal = .terminal
        let session = source
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { probe.read { $0.records } },
            screenAdapters: [.terminal: probe.adapter], terminalWindowCapture: capture,
            requestTerminalKeyboardPermission: { probe.mutate { $0.keyboardRequests += 1; $0.permissions.keyboard = true } },
            terminalInputAvailable: { true }, terminalInputIdentity: { pid in probe.read { $0.identity.pid == pid ? $0.identity : nil } })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: probe.read { $0.records }); await engine.connectTerminal()
        let nodeID = UUID().uuidString
        var status = RemoteNetworkStatus()
        let service = RemoteNetworkService(engine: engine, nodeID: nodeID, bonjourEnabled: false, discoveryAddresses: { [] }, onStatus: { status = $0 })
        defer { service.stop() }
        func request(_ method: String, _ route: String, _ body: JSONObject? = nil) throws -> RemoteHTTPRequest {
            let bytes = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
            let headers = "Host: localhost\r\n" + (body == nil ? "" : "Content-Type: application/json\r\nContent-Length: \(bytes.count)\r\n")
            return try RemoteHTTPRequest.parse(Data("\(method) \(route) HTTP/1.1\r\n\(headers)\r\n".utf8) + bytes)!
        }
        func route(_ path: String = "/api/terminal", view: String? = nil, node: String? = nil) -> String {
            var value = URLComponents(); value.path = path
            value.queryItems = [URLQueryItem(name: "session", value: session.id)]
            if let view { value.queryItems!.append(URLQueryItem(name: "view", value: view)) }
            if let node { value.queryItems!.append(URLQueryItem(name: "node", value: node)) }
            return value.string!
        }
        func json(_ response: RemoteHTTPResponse) throws -> JSONObject {
            try require(response.status == 200, "Private HTTP request failed: \(response.status) \(String(decoding: response.body, as: UTF8.self))")
            return try JSONSerialization.jsonObject(with: response.body) as! JSONObject
        }
        var checks = [String]()
        let normal = try json(await service.handle(try request("GET", route())))
        try require(probe.read { $0.captures == 0 && $0.requests == 0 && $0.reveals == 0 }, "Default original GET must never capture an image, request screen permission or reveal a window")
        try require(normal["nativeDisplay"] == nil && normal["screen"] as? String == "original terminal output" && normal["cursor"] != nil,
            "Default original frames must retain actual text/cursor and omit nativeDisplay")
        let keys = normal["keys"] as? [String] ?? []
        try require(keys.contains("characters") && keys.contains("left"), "Normal direct keys must depend on the TTY service and work with Accessibility off independently of screen capture")
        let streamID = normal["streamID"] as! String
        checks.append("default original HTTP preserves text/cursor/direct keys and performs zero image or permission operations")
        probe.mutate { $0.identity.startMicroseconds += 1 }
        let reused = await service.handle(try request("POST", "/api/input", ["requestID": UUID().uuidString,
            "sessionID": session.id, "revision": normal["revision"]!, "streamID": streamID, "relay": true, "kind": "left"]))
        try require(reused.status == 409 && probe.read({ $0.writes.isEmpty }), "Same-second PID reuse must reject input before the original adapter")
        let reusedFrame = await service.handle(try request("GET", route()))
        try require(reusedFrame.status == 409, "An existing stream must not silently rebind a replacement's microsecond identity")
        probe.mutate { $0.permissions.automation = false }
        let changedPresentation = await service.handle(try request("GET", route()))
        try require(changedPresentation.status == 409, "Presentation generation changes must not replace the frozen original identity")
        probe.mutate { $0.permissions.automation = true }
        let restoredPresentation = await service.handle(try request("GET", route()))
        try require(restoredPresentation.status == 409, "Restoring Automation must not rebind the replacement")
        probe.mutate { $0.identity.startMicroseconds -= 1 }
        checks.append("original stream freezes precise lifetime and rejects same-second replacement without rebinding or input")

        try service.start(port: 0)
        for _ in 0..<100 where !status.ready { try await Task.sleep(nanoseconds: 30_000_000) }
        guard let port = status.port, status.ready else { throw AppError.message("Private SSE listener failed") }
        func firstEvent(_ path: String, at port: UInt16) async throws -> JSONObject {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!); request.timeoutInterval = 6
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            defer { bytes.task.cancel() }
            try require((response as? HTTPURLResponse)?.statusCode == 200 && response.mimeType == "text/event-stream", "Original stream must be an actual SSE response")
            for try await line in bytes.lines where line.hasPrefix("data: ") {
                return try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! JSONObject
            }
            throw AppError.message("Private stream ended before its initial frame")
        }
        let normalEvent = try await firstEvent(route("/api/terminal/stream"), at: port)
        try require(normalEvent["nativeDisplay"] == nil && normalEvent["streamID"] as? String == streamID && probe.read({ $0.captures }) == 0,
            "Default SSE must carry the same original generation without capturing images")
        checks.append("default SSE starts with the same original identity and never captures a window")

        let screen = try json(await service.handle(try request("GET", route(view: "screen"))))
        let display = screen["nativeDisplay"] as? JSONObject
        try require(display?["state"] as? String == "live" && display?["image"] != nil && probe.read({ $0.captures }) == 1,
            "Only explicit view=screen may capture the verified original window")
        try require(screen["streamID"] as? String == streamID && screen["screen"] as? String == normal["screen"] as? String,
            "Opting into screen preview must preserve source output and stream identity")
        let screenEvent = try await firstEvent(route("/api/terminal/stream", view: "screen"), at: port)
        try require((screenEvent["nativeDisplay"] as? JSONObject)?["image"] != nil && screenEvent["streamID"] as? String == streamID,
            "Opt-in SSE must carry bounded JPEG while preserving the original source stream")
        checks.append("explicit HTTP/SSE preview captures only the same original and preserves its source generation")

        probe.mutate { $0.failMetadata = true }; capture.invalidate()
        let failedPreview = try json(await service.handle(try request("GET", route(view: "screen"))))
        try require((failedPreview["nativeDisplay"] as? JSONObject)?["state"] as? String == "unavailable"
            && failedPreview["screen"] as? String == normal["screen"] as? String && failedPreview["streamID"] as? String == streamID,
            "A thrown image metadata error must leave the valid original output and input stream usable")
        let failedPreviewEvent = try await firstEvent(route("/api/terminal/stream", view: "screen"), at: port)
        try require((failedPreviewEvent["nativeDisplay"] as? JSONObject)?["state"] as? String == "unavailable"
            && failedPreviewEvent["screen"] as? String == normal["screen"] as? String && failedPreviewEvent["streamID"] as? String == streamID,
            "A preview-only failure must retain a valid original SSE frame instead of ending its source connection")
        _ = try json(await service.handle(try request("POST", "/api/input", ["requestID": UUID().uuidString, "sessionID": session.id,
            "revision": failedPreview["revision"]!, "streamID": streamID, "relay": true, "kind": "left", "text": ""])))
        try require(probe.read { $0.writes.count == 1 && $0.writes[0].kind == .left }, "Original input must work immediately after the thrown preview fault without replay or a new CLI")
        probe.mutate { $0.failMetadata = false; $0.records[0].started = "private replaced original" }; capture.invalidate()
        let replacedOriginal = await service.handle(try request("GET", route(view: "screen")))
        try require(replacedOriginal.status == 409, "A genuine original process replacement must still reject the frame")
        probe.mutate { $0.records[0].started = session.started }; capture.invalidate()
        checks.append("thrown preview metadata affects only image state while genuine original process replacement remains rejected")

        probe.mutate { $0.permissions.screen = false }; capture.invalidate()
        let denied = try json(await service.handle(try request("GET", route(view: "screen"))))
        try require((denied["nativeDisplay"] as? JSONObject)?["state"] as? String == "permissionRequired", "Opt-in missing screen permission must be explicit")
        let resumed = try json(await service.handle(try request("GET", route())))
        try require(resumed["nativeDisplay"] == nil && resumed["streamID"] as? String == streamID && (resumed["keys"] as? [String])?.contains("characters") == true,
            "Switching back to normal must retain input and generation despite failed image permission")
        let input: JSONObject = ["requestID": UUID().uuidString, "sessionID": session.id, "revision": resumed["revision"]!, "streamID": streamID,
            "relay": true, "kind": "characters", "text": "한글 same original"]
        _ = try json(await service.handle(try request("POST", "/api/input", input)))
        _ = try json(await service.handle(try request("POST", "/api/input", input)))
        try require(probe.read { $0.writes.count == 2 && $0.writes[1].text == "한글 same original" }, "Normal input after preview failure must reach the exact original once without replay")
        checks.append("missing screen grant never blocks normal input and receipt deduplication prevents replay")

        let normalConnect: JSONObject = ["requestID": UUID().uuidString, "sessionID": session.id]
        probe.mutate { $0.permissions.keyboard = false }
        let connected = try json(await service.handle(try request("POST", "/api/terminal/connect", normalConnect)))
        try require(connected["nativeDisplay"] == nil && probe.read { $0.requests == 0 && $0.keyboardRequests == 0 && $0.reveals == 1 }, "Default connect must reveal the same original without requesting Accessibility or screen permission")
        let screenConnect: JSONObject = ["requestID": UUID().uuidString, "sessionID": session.id, "view": "screen"]
        _ = try json(await service.handle(try request("POST", "/api/terminal/connect", screenConnect)))
        _ = try json(await service.handle(try request("POST", "/api/terminal/connect", screenConnect)))
        try require(probe.read { $0.requests == 1 && $0.reveals == 2 }, "Explicit screen connect alone may request window permissions, once per receipt")
        checks.append("default and opt-in connect separate window permission requests while revealing the same terminal once")

        probe.mutate { $0.permissions.screen = false; $0.permissions.keyboard = false }
        var itermSession = session; itermSession.terminal = .iterm
        let itermEngine = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("iterm")),
            processReader: { probe.read { $0.records } }, screenAdapters: [.iterm: probe.adapter], itermWindowCapture: probe.capture())
        defer { itermEngine.stop() }
        itermEngine.updateDiscovery([itermSession], records: probe.read { $0.records }); await itermEngine.connectScreenHost(.iterm)
        let beforeITerm = probe.read { $0.captures }
        let iterm = try await itermEngine.remoteTerminal(sessionID: itermSession.id, realtime: true)
        try require(iterm.nativeDisplay == nil && iterm.keys.contains("characters") && iterm.keys.contains("left") && probe.read({ $0.captures }) == beforeITerm,
            "iTerm normal direct keys must remain available independently of JPEG/screen/AX grants")
        probe.mutate { $0.permissions.screen = true; $0.permissions.keyboard = true }; capture.invalidate()
        checks.append("iTerm normal direct input remains independent of screen capture and Accessibility grants")

        let gatewayEngine = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("gateway")), processReader: { [] }, screenAdapters: [.terminal: probe.adapter, .iterm: probe.adapter, .orca: probe.adapter])
        defer { gatewayEngine.stop() }
        var gatewayStatus = RemoteNetworkStatus()
        let gateway = RemoteNetworkService(engine: gatewayEngine, nodeID: UUID().uuidString, bonjourEnabled: false, discoveryAddresses: { [] }, onStatus: { gatewayStatus = $0 })
        defer { gateway.stop() }; try gateway.start(port: 0)
        for _ in 0..<100 where !gatewayStatus.ready { try await Task.sleep(nanoseconds: 30_000_000) }
        guard let gatewayPort = gatewayStatus.port, gatewayStatus.ready else { throw AppError.message("Private peer gateway failed") }
        _ = try json(await gateway.handle(try request("POST", "/api/peers", ["address": "http://127.0.0.1:\(port)"])))
        let beforePeer = probe.read { $0.captures }
        let peerNormal = try await firstEvent(route("/api/terminal/stream", node: nodeID), at: gatewayPort)
        try require(peerNormal["nativeDisplay"] == nil && peerNormal["streamID"] as? String == streamID && probe.read({ $0.captures }) == beforePeer,
            "Peer forwarding must preserve ordinary mode without turning on capture")
        let peerScreen = try await firstEvent(route("/api/terminal/stream", view: "screen", node: nodeID), at: gatewayPort)
        try require((peerScreen["nativeDisplay"] as? JSONObject)?["image"] != nil && peerScreen["streamID"] as? String == streamID,
            "Peer forwarding must retain the explicit preview flag and the exact source generation")
        checks.append("peer SSE forwards explicit view only and retains the same original stream without extra source creation")
        try require(engine.managedPTY.inventory.isEmpty && gatewayEngine.managedPTY.inventory.isEmpty && engine.snapshot.sessions.count == 1 && engine.snapshot.sessions[0].pid == session.pid && engine.snapshot.sessions[0].tty == session.tty,
            "View changes and connect must never fork or replace the original CLI/TTY")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["checks": checks, "realPermissionPrompts": 0, "ownedPTYCreations": 0]), as: UTF8.self))
    }
}
