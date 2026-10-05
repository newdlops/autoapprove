// Real engine/schema with injected pixels and window identity. Never calls live TCC or capture APIs.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import JavaScriptCore
import AutoApproveCore

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw AppError.message(message) }
}

private final class VisualProbe: @unchecked Sendable {
    let lock = NSLock()
    var permissions = TerminalWindowPermissions(screen: false, keyboard: false, automation: false)
    var metadata = TerminalWindowMetadata(tty: "/dev/ttys085", windowID: 91, ownerPID: 900, ownerBundleID: "com.apple.Terminal", selected: true, minimized: false)
    var records = ProcessDiscovery.parse("85001 1 ttys085 85001 85001 Mon Oct 5 09:00:01 2026 /private/fixture/codex")
    var captures = 0, permissionRequests = 0, reveals = 0, screenReads = 0
    var pixel: UInt8 = 0
    var changeWindowDuringCapture = false, loseIdentityDuringCapture = false, changeProcessDuringPermission = false
    var invalidDimensions = false
    func mutate(_ body: (VisualProbe) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
    func read<T>(_ body: (VisualProbe) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    func image() throws -> TerminalNativeImage {
        let shade = read { $0.pixel }
        let bytes = Data((0..<64).map { $0 % 4 == 3 ? UInt8(255) : shade })
        guard let provider = CGDataProvider(data: bytes as CFData), let image = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw AppError.message("Fixture CGImage failed") }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { throw AppError.message("Fixture JPEG destination failed") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AppError.message("Fixture JPEG encoding failed") }
        return TerminalNativeImage(data: (encoded as Data).base64EncodedString(), width: read { $0.invalidDimensions ? 4096 : 4 }, height: 4)
    }
    @MainActor func capture() -> TerminalWindowCapture {
        TerminalWindowCapture(permissions: { [self] in read { $0.permissions } }, requestPermissions: { [self] in
            mutate { $0.permissionRequests += 1; $0.permissions = TerminalWindowPermissions(screen: true, keyboard: true, automation: true)
                if $0.changeProcessDuringPermission { $0.records[0].started = "different original process" } }
        }, metadata: { [self] tty in read { $0.metadata.tty == tty ? $0.metadata : nil } }, capture: { [self] _ in
            mutate { $0.captures += 1 }
            try await Task.sleep(nanoseconds: 40_000_000)
            let image = try self.image()
            mutate { if $0.changeWindowDuringCapture { $0.metadata.windowID += 1 }; if $0.loseIdentityDuringCapture { $0.records[0].started = "exited during capture" } }
            return image
        })
    }
    var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { [self] targets in
            mutate { $0.screenReads += 1 }
            return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "stable terminal text", title: "Private original window") })
        }, approve: { _, _, _ in .missingTarget }, reveal: { [self] target in
            guard target.tty == read({ $0.metadata.tty }) else { return nil }
            mutate { $0.reveals += 1; $0.metadata.selected = true; $0.metadata.minimized = false }; return nil
        })
    }
}

@main struct TerminalWindowVisualChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = [String]()
        let context = JSContext()!
        context.evaluateScript("""
        var activations=0,reads=0;
        var wanted={tty:()=>'/dev/ttys085',selected:()=>true};
        var target={id:()=>91,miniaturized:()=>false,selectedTab:()=>wanted,tabs:()=>[{tty:()=>'/dev/other'},wanted]};
        function Application(){return {running:()=>true,windows:()=>[{tabs:()=>{throw Error('closed window')}},target,{tabs:()=>{throw Error('must stop at exact tty')}}],activate:()=>{activations++}}}
        """)
        let selection = context.evaluateScript(try TerminalAdapter.windowMetadataScript(tty: "/dev/ttys085"))!
        try require(context.exception == nil, "Window metadata must tolerate closed unrelated windows")
        let selectionJSON = try JSONSerialization.jsonObject(with: Data(selection.toString().utf8)) as! JSONObject
        try require(selectionJSON["windowID"] as? Int == 91 && selectionJSON["selected"] as? Bool == true, "Read-only metadata must return the exact selected native window ID")
        try require(context.evaluateScript("activations")!.toInt32() == 0, "GET metadata must not activate or reveal any tab")
        context.evaluateScript("target.selectedTab=()=>({tty:()=>'/dev/other'});wanted.selected=()=>false;")
        let inactive = context.evaluateScript(try TerminalAdapter.windowMetadataScript(tty: "/dev/ttys085"))!
        let inactiveJSON = try JSONSerialization.jsonObject(with: Data(inactive.toString().utf8)) as! JSONObject
        try require(inactiveJSON["selected"] as? Bool == false, "An inactive exact tab must be reported without selecting it")
        let iterm = JSContext()!
        iterm.evaluateScript("""
        var activations=0;
        var wanted={tty:()=>'/dev/ttys085'},other={tty:()=>'/dev/other'};
        var tab={id:()=>5,sessions:()=>[other,wanted],currentSession:()=>wanted};
        var target={id:()=>92,miniaturized:()=>false,currentTab:()=>tab,tabs:()=>[tab]};
        function Application(){return {running:()=>true,windows:()=>[target],activate:()=>{activations++}}}
        """)
        let itermJSON = try JSONSerialization.jsonObject(with: Data(iterm.evaluateScript(try TerminalAdapter.windowMetadataScript(tty: "/dev/ttys085", host: .iterm))!.toString().utf8)) as! JSONObject
        try require(iterm.exception == nil && itermJSON["windowID"] as? Int == 92 && itermJSON["selected"] as? Bool == true, "iTerm metadata must verify its exact selected tab/session")
        iterm.evaluateScript("tab.currentSession=()=>other;")
        let otherSessionJSON = try JSONSerialization.jsonObject(with: Data(iterm.evaluateScript(try TerminalAdapter.windowMetadataScript(tty: "/dev/ttys085", host: .iterm))!.toString().utf8)) as! JSONObject
        try require(otherSessionJSON["selected"] as? Bool == false && iterm.evaluateScript("activations")!.toInt32() == 0, "Another selected iTerm session must be inactive without selecting or activating anything")
        checks.append("Terminal/iTerm native metadata is read-only and verifies the exact selected TTY/tab/session")
        try require(VSCodeWindowAdapter.terminalInputMatches(role: "AXTextArea", label: "Terminal 2, Codex\nAccessibility help", terminalName: "Codex"), "Exact English native terminal label must match")
        try require(VSCodeWindowAdapter.terminalInputMatches(role: "AXTextArea", label: "터미널 2, 원래 작업", terminalName: "원래 작업"), "Exact Korean native terminal label must match")
        try require(!VSCodeWindowAdapter.terminalInputMatches(role: "AXTextArea", label: "Terminal 2, Codex-other", terminalName: "Codex"), "A shared name prefix must not match another terminal")
        try require(!VSCodeWindowAdapter.terminalInputMatches(role: "AXTextArea", label: "Editor Codex", terminalName: "Codex") && !VSCodeWindowAdapter.terminalInputMatches(role: "AXButton", label: "Terminal 2, Codex", terminalName: "Codex"), "Editor input or a hidden terminal button must not qualify as native terminal input")
        try require(VSCodeWindowAdapter.ownerBundleID(ownerPID: 0) == nil && VSCodeWindowAdapter.ownerBundleID(ownerPID: -1) == nil, "Invalid editor owner PID must fail without inspecting another app")
        let sourceWindow = UUID().uuidString
        try require(VSCodeWindowAdapter.windowMarkerMatches(label: "AutoApprove window " + sourceWindow, token: sourceWindow), "The bridge's exact accessibility marker must bind its own editor window")
        try require(!VSCodeWindowAdapter.windowMarkerMatches(label: "AutoApprove window " + UUID().uuidString, token: sourceWindow), "An identically named terminal in another editor window must not bind to the source peer")
        try require(!VSCodeWindowAdapter.windowMarkerMatches(label: "AutoApprove window " + sourceWindow + " other", token: sourceWindow) && !VSCodeWindowAdapter.windowMarkerMatches(label: "AutoApprove window ", token: ""), "Partial or empty source markers must not qualify")
        checks.append("VSCode native terminal labels require exact visible input identity and invalid owner PID is refused")

        let probe = VisualProbe(), capture = probe.capture()
        let record = probe.read { $0.records[0] }
        let target = TerminalCaptureTarget(pid: record.pid, started: record.started, tty: "/dev/" + record.tty, agent: .codex)
        let identity: @Sendable () throws -> Bool = { probe.read { $0.records.contains { $0.pid == target.pid && $0.started == target.started && "/dev/" + $0.tty == target.tty } } }
        let denied = try await capture.read(target, validateIdentity: identity)
        try require(denied.state == .permissionRequired && denied.image == nil, "Missing grants must return a bounded permission state, never pixels")
        try require(probe.read { $0.permissionRequests == 0 && $0.captures == 0 }, "A read must not request permission or capture without grants")
        probe.mutate { $0.permissions = TerminalWindowPermissions(screen: true, keyboard: true, automation: true); $0.metadata.selected = false }
        capture.invalidate()
        let notSelected = try await capture.read(target, validateIdentity: identity)
        try require(notSelected.state == .inactive && notSelected.image == nil && probe.read({ $0.captures }) == 0, "An inactive tab must never be captured")
        probe.mutate { $0.metadata.selected = true; $0.metadata.ownerBundleID = "com.example.other" }; capture.invalidate()
        let wrongOwner = try await capture.read(target, validateIdentity: identity)
        try require(wrongOwner.state == .unavailable && wrongOwner.image == nil && probe.read({ $0.captures }) == 0, "A different bundle owner must never be captured")
        checks.append("permission denial, inactive tab and wrong owner never produce another window's pixels or permission prompts")

        probe.mutate { $0.metadata.ownerBundleID = "com.apple.Terminal"; $0.permissions.keyboard = false }; capture.invalidate()
        let screenWithoutKeys = try await capture.read(target, validateIdentity: identity)
        try require(screenWithoutKeys.state == .live && screenWithoutKeys.image != nil && screenWithoutKeys.message != nil && !capture.keyboardPermissionGranted,
            "Terminal screen capture must remain live when only keyboard Accessibility permission is missing")
        probe.mutate { $0.permissions.screen = false }
        let revoked = try await capture.read(target, validateIdentity: identity)
        try require(revoked.state == .permissionRequired && revoked.image == nil,
            "A revoked screen grant must not reuse an otherwise cached live image")
        probe.mutate { $0.permissions = TerminalWindowPermissions(screen: true, keyboard: true, automation: true) }
        checks.append("Terminal image permission is independent of keyboard access and revoked screen grants discard live pixels")

        probe.mutate { $0.metadata.ownerBundleID = "com.apple.Terminal"; $0.changeWindowDuringCapture = true }; capture.invalidate()
        let changedWindow = try await capture.read(target, validateIdentity: identity)
        try require(changedWindow.state != .live && changedWindow.image == nil, "A window or selected-tab change during capture must discard its pixels")
        probe.mutate { $0.changeWindowDuringCapture = false; $0.loseIdentityDuringCapture = true }; capture.invalidate()
        do { _ = try await capture.read(target, validateIdentity: identity); throw AppError.message("A replaced original PID/start/TTY must refuse capture") }
        catch let error as RemoteHTTPError { try require(error.status == 409, "Lost original identity must be409") }
        probe.mutate { $0.loseIdentityDuringCapture = false; $0.records = [record]; $0.invalidDimensions = true }; capture.invalidate()
        let invalidImage = try await capture.read(target, validateIdentity: identity)
        try require(invalidImage.state == .unavailable && invalidImage.image == nil, "Oversized or inconsistent JPEG metadata must be discarded")
        checks.append("capture rechecks window and original process identity and rejects unsafe image dimensions")

        probe.mutate { $0.invalidDimensions = false }; capture.invalidate()
        let baseline = probe.read { $0.captures }
        async let a = capture.read(target, validateIdentity: identity)
        async let b = capture.read(target, validateIdentity: identity)
        let (firstImage, secondImage) = try await (a, b)
        try require(firstImage.state == .live && firstImage.image == secondImage.image, "Concurrent reads must return one exact native image")
        try require(probe.read { $0.captures } == baseline + 1, "Concurrent browsers must share an in-flight image capture")
        _ = try await capture.read(target, validateIdentity: identity)
        try require(probe.read { $0.captures } == baseline + 1, "A short cache must reuse the actual captured pixels")
        checks.append("concurrent viewers share one bounded in-flight capture and its short cache")

        probe.mutate { $0.metadata.selected = false }
        let cachedInactive = try await capture.read(target, validateIdentity: identity)
        try require(cachedInactive.state == .inactive && cachedInactive.image == nil,
            "A cached live image must be discarded when the exact original tab is no longer selected")
        probe.mutate { $0.metadata.selected = true }; capture.invalidate()
        _ = try await capture.read(target, validateIdentity: identity)
        probe.mutate { $0.metadata.bindingToken = "another exact source generation" }
        let changedBinding = try await capture.read(target, validateIdentity: identity)
        try require(changedBinding.state == .inactive && changedBinding.image == nil, "A cached image must retain the same frozen exact source binding")
        probe.mutate { $0.metadata.bindingToken = nil }; capture.invalidate()
        _ = try await capture.read(target, validateIdentity: identity)
        probe.mutate { $0.records[0].started = "replaced within cache lifetime" }
        do { _ = try await capture.read(target, validateIdentity: identity); throw AppError.message("A cached image must not survive original process replacement") }
        catch let error as RemoteHTTPError { try require(error.status == 409, "Cached process replacement must be409") }
        probe.mutate { $0.records = [record] }; capture.invalidate()
        checks.append("cached frames recheck current selected tab and original process identity before returning pixels")

        var session = ProcessDiscovery.sessions([record])[0]; session.terminal = .terminal
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { probe.read { $0.records } }, screenAdapters: [.terminal: probe.adapter], terminalWindowCapture: capture)
        defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectTerminal()
        let initial = try await engine.remoteTerminal(sessionID: session.id, realtime: true, renderWindow: true)
        try require(initial.nativeDisplay?.state == .live && initial.nativeDisplay?.image != nil, "Original Terminal frames must carry its exact native image")
        probe.mutate { $0.pixel = 255 }; capture.invalidate()
        let cursorBlink = try await engine.remoteTerminal(sessionID: session.id, realtime: true, renderWindow: true)
        try require(cursorBlink.screen == initial.screen && cursorBlink.revision != initial.revision, "Pixel-only/cursor-blink changes must advance the terminal revision")
        let service = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, onStatus: { _ in })
        func request(_ method: String, _ path: String, _ body: JSONObject? = nil, origin: String? = nil) throws -> RemoteHTTPRequest {
            let bytes = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
            let headers = "Host: localhost\r\n" + (origin.map { "Origin: \($0)\r\n" } ?? "") + (body == nil ? "" : "Content-Type: application/json\r\nContent-Length: \(bytes.count)\r\n")
            return try RemoteHTTPRequest.parse(Data("\(method) \(path) HTTP/1.1\r\n\(headers)\r\n".utf8) + bytes)!
        }
        var query = URLComponents(); query.path = "/api/terminal"; query.queryItems = [URLQueryItem(name: "session", value: session.id), URLQueryItem(name: "revision", value: cursorBlink.revision), URLQueryItem(name: "view", value: "screen")]
        let compact = await service.handle(try request("GET", query.string!))
        let compactJSON = try JSONSerialization.jsonObject(with: compact.body) as! JSONObject
        let compactDisplay = compactJSON["nativeDisplay"] as? JSONObject
        try require(compact.status == 200 && compactDisplay?["state"] as? String == "live" && compactDisplay?["image"] == nil, "Compact frames must retain native state without retransmitting image bytes")
        try require(compact.body.count < 2_000_000, "The complete original frame must stay bounded")
        checks.append("pixel-only changes advance revision and compact frames retain state while omitting the JPEG")

        probe.mutate { $0.permissions = TerminalWindowPermissions(screen: false, keyboard: false, automation: false) }; capture.invalidate()
        let get = await service.handle(try request("GET", "/api/terminal?session=" + session.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!))
        try require(get.status == 200 && probe.read({ $0.permissionRequests }) == 0 && probe.read({ $0.reveals }) == 0, "GET must not request grants or reveal an original tab")
        let connectBody: JSONObject = ["requestID": UUID().uuidString, "sessionID": session.id, "view": "screen"]
        let forbidden = await service.handle(try request("POST", "/api/terminal/connect", connectBody, origin: "https://example.com"))
        try require(forbidden.status == 403 && probe.read({ $0.permissionRequests }) == 0, "Cross-origin connect must not request permissions")
        let connected = await service.handle(try request("POST", "/api/terminal/connect", connectBody))
        try require(connected.status == 200 && probe.read({ $0.permissionRequests }) == 1 && probe.read({ $0.reveals }) == 1, "Only explicit original connect may request grants and reveal the same tab")
        let repeated = await service.handle(try request("POST", "/api/terminal/connect", connectBody))
        try require(repeated.status == 200 && probe.read({ $0.permissionRequests }) == 1 && probe.read({ $0.reveals }) == 1, "The same request receipt must not repeat native side effects")
        try require(engine.managedPTY.inventory.isEmpty, "Native connect and reads must never create or fork any PTY")
        let active = engine.snapshot.sessions.filter { $0.phase != .ended }
        try require(active.count == 1 && active[0].pid == session.pid && active[0].tty == session.tty, "Connect must preserve the original PID/TTY and inventory")
        probe.mutate { $0.changeProcessDuringPermission = true }; capture.invalidate()
        let replaced = await service.handle(try request("POST", "/api/terminal/connect", ["requestID": UUID().uuidString, "sessionID": session.id, "view": "screen"]))
        try require(replaced.status == 409 && probe.read({ $0.reveals }) == 1, "A process change while permission is requested must prevent revealing any tab")
        checks.append("explicit same-session connect is origin-protected, receipt-deduplicated, preserves PID/TTY and never creates a PTY")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["checks": checks, "realPermissionPrompts": 0, "ownedPTYCreations": 0]), as: UTF8.self))
    }
}
