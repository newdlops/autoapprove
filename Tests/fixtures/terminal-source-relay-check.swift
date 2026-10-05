// Persistent private Bridge mock. No installed VS Code, TCC, window or CLI writes.
import Foundation
import Darwin
import AutoApproveCore

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw AppError.message(message) }
}

private final class OriginalRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [ProcessRecord]
    init(_ records: [ProcessRecord]) { self.records = records }
    func read() -> [ProcessRecord] { lock.lock(); defer { lock.unlock() }; return records }
    func replace(_ value: [ProcessRecord]) { lock.lock(); records = value; lock.unlock() }
}

private final class SourceBridge: @unchecked Sendable {
    let lock = NSLock(), wire = NSLock()
    private let fd: Int32
    var generation = "private-generation-1", windowToken = UUID().uuidString
    var selected = true, duplicateName = true, changeWindowOnReveal = false
    var writes = [JSONObject](), reveals = [JSONObject](), acknowledged = Set<String>()
    var captureRequests = 0, metadataReads = 0, captures = 0, inputRPCs = 0
    func read<T>(_ body: (SourceBridge) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    func mutate(_ body: (SourceBridge) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
    init(path: String) throws {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AppError.message("Private socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError.message("Private socket creation failed") }
        var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { Darwin.close(fd); throw AppError.message("Private Bridge connection failed") }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.receive() }
    }
    func close() { Darwin.shutdown(fd, SHUT_RDWR) }
    deinit { close(); Darwin.close(fd) }
    func send(_ object: JSONObject) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10); wire.lock(); defer { wire.unlock() }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                guard count > 0 else { return }; offset += count
            }
        }
    }
    private func registrations() -> [JSONObject] {
        read { probe in
            let first: JSONObject = ["id": "private-original", "shellPID": 85015, "name": "same title", "remoteInputVersion": 3,
                "nativeWindowVersion": probe.duplicateName ? 0 : 2, "ownerPID": 90016, "windowToken": probe.windowToken,
                "selected": probe.selected, "nativeGeneration": probe.generation]
            return probe.duplicateName ? [first, ["id": "private-other", "shellPID": 85017, "name": "same title", "remoteInputVersion": 3,
                "nativeWindowVersion": 0, "ownerPID": 90016, "windowToken": probe.windowToken,
                "selected": false, "nativeGeneration": "private-other-generation"]] : [first]
        }
    }
    func register() async throws {
        let id = UUID().uuidString
        send(["id": id, "method": "register", "params": ["terminals": registrations()]])
        for _ in 0..<200 {
            if read({ $0.acknowledged.contains(id) }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppError.message("Private registration acknowledgement timed out")
    }
    private func receive() {
        var buffer = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: bytes.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? JSONObject else { continue }
                if let id = object["id"] as? String, object["result"] != nil { mutate { $0.acknowledged.insert(id) } }
                guard let method = object["method"] as? String else { continue }
                if method == "remoteInput" {
                    mutate { $0.inputRPCs += 1 }
                    let valid = read { object["native"] as? Bool == true && object["relay"] as? Bool == true && object["terminalID"] as? String == "private-original"
                        && object["generation"] as? String == $0.generation && $0.selected && (object["expiresAt"] as? Double ?? 0) > Date().timeIntervalSince1970 * 1000 }
                    if valid { mutate { $0.writes.append(object) } }
                    send(["method": "remoteInputResult", "params": ["actionID": object["id"]!, "success": valid]])
                } else if method == "reveal" {
                    mutate { $0.reveals.append(object); $0.selected = true; $0.generation = UUID().uuidString
                        if $0.changeWindowOnReveal { $0.windowToken = UUID().uuidString } }
                    send(["method": "register", "params": ["terminals": registrations()]])
                    send(["method": "revealResult", "params": ["actionID": object["id"]!, "terminalID": "private-original", "success": true, "nativeGeneration": read { $0.generation }]])
                }
            }
        }
    }
}

@main struct TerminalSourceRelayChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let records = ProcessDiscovery.parse("""
        85016 85015 ttys098 85016 85016 Mon Oct 5 09:00:16 2026 /private/fixture/codex
        85015 1 ttys098 85015 85016 Mon Oct 5 09:00:15 2026 /bin/zsh
        """)
        var discovered = ProcessDiscovery.sessions(records)[0]; discovered.terminal = .vscode
        let session = discovered
        let recordStore = OriginalRecords(records)
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { recordStore.read() },
            bridgeOwnerBundle: { $0 == 90016 ? "com.microsoft.VSCode" : nil })
        try engine.start(poll: false); defer { engine.stop() }
        engine.updateDiscovery([session], records: records)
        let bridge = try SourceBridge(path: engine.paths.socket); defer { bridge.close() }
        try await bridge.register()
        let gateway = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, onStatus: { _ in })
        func request(_ body: JSONObject) throws -> RemoteHTTPRequest {
            let bytes = try JSONSerialization.data(withJSONObject: body)
            return try RemoteHTTPRequest.parse(Data("POST /api/input HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\n\r\n".utf8) + bytes)!
        }
        func input(_ frame: RemoteTerminalFrame, text: String) -> JSONObject {
            ["requestID": UUID().uuidString, "sessionID": session.id, "revision": frame.revision, "streamID": frame.streamID!, "relay": true, "kind": "characters", "text": text]
        }
        var checks = [String]()
        let original = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        try require(original.nativeDisplay == nil && original.screen.isEmpty && original.outputReason != nil && original.inputReason == nil && original.keys.contains("characters"),
            "Exact selected native-only source must allow ordinary relay without JPEG/AX and honestly report missing historical output")
        let preview = try await engine.remoteTerminal(sessionID: session.id, realtime: true, renderWindow: true)
        try require(preview.nativeDisplay?.state == .unavailable && preview.streamID == original.streamID && preview.keys.contains("characters"),
            "Duplicate window labels may disable preview but never the exact terminalID source relay")
        let restored = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        try require(restored.nativeDisplay == nil && restored.streamID == original.streamID, "Turning preview off must preserve the original source generation")
        let unicode = input(restored, text: "한글 original only")
        let sent = await gateway.handle(try request(unicode)), repeated = await gateway.handle(try request(unicode))
        try require(sent.status == 200 && repeated.status == 200 && bridge.read({ $0.writes.count }) == 1,
            "Native-only ordinary Unicode input must be routed to the same exact source exactly once")
        checks.append("duplicate-name native-only source retains exact Unicode relay without JPEG/AX and reports unavailable history honestly")

        let duplicateConnect = try await engine.connectRemoteTerminal(["sessionID": session.id])
        try require(duplicateConnect.nativeDisplay == nil && bridge.read({ $0.reveals.last?["view"] }) == nil,
            "Default duplicate-name connect must reveal only the exact Terminal object without window mode")
        checks.append("default connect permits the exact duplicate-name source and omits the screen reveal flag")

        bridge.mutate { $0.duplicateName = false }; try await bridge.register()
        let deniedCapture = TerminalWindowCapture(host: .orca, ownerBundleID: "com.microsoft.VSCode", requiresAccessibilityForMetadata: true,
            permissions: { TerminalWindowPermissions(screen: false, keyboard: false, automation: true) },
            requestPermissions: { bridge.mutate { $0.captureRequests += 1 } },
            metadata: { _ in bridge.mutate { $0.metadataReads += 1 }; throw AppError.message("Denied grants must not query window metadata") },
            capture: { _ in bridge.mutate { $0.captures += 1 }; throw AppError.message("Denied grants must not capture any window") })
        engine.setNativeWindowCapture(sessionID: session.id, capture: deniedCapture)
        let normal = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        let denied = try await engine.remoteTerminal(sessionID: session.id, realtime: true, renderWindow: true)
        try require(denied.nativeDisplay?.state == .permissionRequired && denied.streamID == normal.streamID && denied.keys.contains("characters"),
            "Missing screen/AX permission must affect only opt-in preview, never exact normal Bridge relay")
        let afterDenial = await gateway.handle(try request(input(normal, text: "still same original")))
        try require(afterDenial.status == 200 && bridge.read({ $0.writes.count }) == 2, "Nonlive preview in another viewer must not disable normal source input")
        _ = try await engine.connectRemoteTerminal(["sessionID": session.id, "view": "screen"])
        try require(bridge.read { $0.captureRequests == 1 && $0.metadataReads == 0 && $0.captures == 0 && $0.reveals.last?["view"] as? String == "screen" },
            "Only explicit screen connect may request window permission and send the screen reveal flag")
        checks.append("denied opt-in preview preserves source input and only explicit connect requests window permissions")

        let stable = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        bridge.mutate { $0.windowToken = UUID().uuidString }; try await bridge.register()
        let staleWindow = await gateway.handle(try request(input(stable, text: "must remain unsent")))
        try require(staleWindow.status == 409 && bridge.read({ $0.writes.count == 2 && $0.inputRPCs == 2 }), "Changed owner-window binding must reject the old source stream before relay")
        let fresh = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        bridge.mutate { $0.selected = false }; try await bridge.register()
        let inactive = await gateway.handle(try request(input(fresh, text: "must remain unsent")))
        try require(inactive.status == 409 && bridge.read({ $0.writes.count == 2 && $0.inputRPCs == 2 }), "An unselected source must refuse direct input even when old output/revision exists")
        let inactiveFrame = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        try require(inactiveFrame.keys.isEmpty && inactiveFrame.streamID == nil && inactiveFrame.inputReason != nil,
            "Inactive source must expose read-only controls without pretending the exact source is selected")
        checks.append("window token generation and current source selection fence every original relay without replay")

        bridge.mutate { $0.selected = true }; try await bridge.register()
        let processFrame = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        var replacedRecords = records; replacedRecords[0].started = "private replaced process"; recordStore.replace(replacedRecords)
        let replaced = await gateway.handle(try request(input(processFrame, text: "must remain unsent")))
        try require(replaced.status == 409 && bridge.read({ $0.writes.count == 2 && $0.inputRPCs == 2 }), "Original process start identity must be rechecked before native relay")
        recordStore.replace(records)
        bridge.mutate { $0.changeWindowOnReveal = true }
        do { _ = try await engine.connectRemoteTerminal(["sessionID": session.id]); throw AppError.message("A reveal acknowledgement from another window must be rejected") }
        catch let error as RemoteHTTPError { try require(error.status == 409, "Changed reveal window must be409") }
        try require(engine.managedPTY.inventory.isEmpty && engine.snapshot.sessions.count == 1 && engine.snapshot.sessions[0].pid == session.pid && engine.snapshot.sessions[0].tty == session.tty,
            "Original source relay/connect must never replace or fork its PID/TTY")
        checks.append("original PID/start/TTY and post-reveal owner/window token remain exact without new CLI or PTY")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["checks": checks, "liveCLIInputs": 0, "realPermissionPrompts": 0, "ownedPTYCreations": 0]), as: UTF8.self))
    }
}
