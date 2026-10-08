// Private original-Orca contract. No live Orca socket, permissions, CLI or PTY.
import Foundation
import AutoApproveCore

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw AppError.message(message) }
}

private final class OrcaProbe: @unchecked Sendable {
    let lock = NSLock()
    var records = ProcessDiscovery.parse("""
    85002 85003 ttys086 85002 85002 Mon Oct 5 09:00:02 2026 /private/fixture/codex
    85003 1 ttys086 85003 85002 Mon Oct 5 09:00:01 2026 /bin/zsh
    85004 1 ttys099 85004 85004 Mon Oct 5 09:00:04 2026 /bin/zsh
    """)
    var ansi = "\u{1b}[2J\u{1b}[H\u{1b}[38;2;18;52;86mORCA READY\u{1b}[0m\u{1b}[2;5H\u{1b}[?25h"
    var sequence: Int64 = 1
    var incarnation = "private-original-incarnation"
    var ownerPID: Int32 = 85003
    var snapshots = 0, legacyReads = 0, approvals = 0
    var writes = [(ScreenTarget, RemoteTerminalInput)]()
    var failRead = false, replaceProcessDuringRead = false
    var rejectEnter = false
    func mutate(_ body: (OrcaProbe) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
    func read<T>(_ body: (OrcaProbe) throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body(self) }
    func snapshot(handle: String) async throws -> OrcaTerminalSnapshot {
        guard handle == "private-orca-original" else { throw AppError.message("Another Orca handle must never be queried") }
        mutate { $0.snapshots += 1 }
        try await Task.sleep(nanoseconds: 40_000_000)
        return try read {
            if $0.failRead { throw AppError.message("Private daemon source unavailable") }
            if $0.replaceProcessDuringRead { $0.records[0].started = "replacement during snapshot" }
            return OrcaTerminalSnapshot(ansi: $0.ansi, columns: 24, rows: 4, sequence: $0.sequence,
                runtimeID: "private-runtime", ptyID: "private-original-pty", incarnationID: $0.incarnation,
                ownerPID: $0.ownerPID, observedAt: Date(), alternateScreen: false)
        }
    }
    var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { [self] targets in
            mutate { $0.legacyReads += 1 }
            return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "private legacy approval text") })
        }, approve: { [self] _, _, _ in mutate { $0.approvals += 1 }; return .missingTarget }, reveal: { _ in nil },
        input: { [self] target, _, _, input in
            if input.kind == .enter, read({ $0.rejectEnter }) { return .screenChanged }
            mutate { $0.writes.append((target, input)) }; return .sent
        })
    }
}

@main struct OrcaEngineChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks = [String]()
        let records = ProcessDiscovery.parse("85002 1 ttys086 85002 85002 Mon Oct 5 09:00:02 2026 /private/fixture/codex")
        var discovered = ProcessDiscovery.sessions(records)[0]
        discovered.terminal = .orca; discovered.orcaHandle = "private-orca-original"
        let session = discovered
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records)
        let service = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, onStatus: { _ in })
        var query = URLComponents(); query.path = "/api/terminal"
        query.queryItems = [URLQueryItem(name: "session", value: session.id)]
        let initialRequest = try RemoteHTTPRequest.parse(Data("GET \(query.string!) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))!
        let response = await service.handle(initialRequest)
        try require(response.status == 200, "An unconnected original Orca must report an unavailable frame without querying a daemon; received \(response.status)")
        let value = try JSONSerialization.jsonObject(with: response.body) as! JSONObject
        let outputReason = value["outputReason"] as? String
        let keys = value["keys"] as? [String], screen = value["screen"] as? String
        try require(outputReason?.isEmpty == false && value["nativeDisplay"] == nil, "Default Orca needs an honest output reason before source connection without starting window preview")
        try require(keys?.isEmpty == true && screen == "", "Unconnected original Orca must not expose stale text or input keys")
        try require(engine.managedPTY.inventory.isEmpty, "Reading the original Orca must never create any PTY")
        checks.append("unconnected original Orca has an explicit unavailable frame without daemon queries, keys or PTY creation")

        let ownerProbe = OrcaProbe()
        ownerProbe.mutate { $0.ownerPID = 85004 }
        let ownerEngine = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("owner-fence")),
            processReader: { ownerProbe.read { $0.records } }, screenAdapters: [.orca: ownerProbe.adapter],
            orcaSnapshotReader: { try await ownerProbe.snapshot(handle: $0) })
        defer { ownerEngine.stop() }
        ownerEngine.updateDiscovery([session], records: records); await ownerEngine.connectScreenHost(.orca)
        let wrongOwner = try await ownerEngine.remoteTerminal(sessionID: session.id, realtime: true)
        try require(wrongOwner.outputReason != nil && wrongOwner.nativeDisplay == nil && wrongOwner.screen.isEmpty && wrongOwner.keys.isEmpty,
            "A handle already mapped to another TTY must fail before its first snapshot can become the original binding")
        ownerProbe.mutate { $0.ownerPID = 85003 }
        let boundOwner = try await ownerEngine.remoteTerminal(sessionID: session.id, realtime: true)
        try require(boundOwner.screen.contains("ORCA READY") && boundOwner.streamID != nil,
            "The original daemon shell may have a different PID when its TTY matches the selected CLI")
        ownerProbe.mutate { $0.ownerPID = 85002 }
        do {
            _ = try await ownerEngine.remoteInput(["sessionID": session.id, "revision": boundOwner.revision,
                "streamID": boundOwner.streamID!, "relay": true, "kind": "left", "text": ""])
            throw AppError.message("A changed daemon owner in the same incarnation must reject input")
        } catch let error as RemoteHTTPError { try require(error.status == 409, "A changed daemon owner must be409") }
        let changedOwner = try await ownerEngine.remoteTerminal(sessionID: session.id, realtime: true)
        try require(changedOwner.outputReason != nil && changedOwner.nativeDisplay == nil && changedOwner.keys.isEmpty,
            "The daemon owner PID is part of the immutable original snapshot generation")
        ownerProbe.mutate { $0.ownerPID = 85003 }
        let restoredOwner = try await ownerEngine.remoteTerminal(sessionID: session.id, realtime: true)
        ownerProbe.mutate { probe in
            let index = probe.records.firstIndex { $0.pid == 85003 }!
            probe.records[index].tty = "ttys099"
        }
        do {
            _ = try await ownerEngine.remoteInput(["sessionID": session.id, "revision": restoredOwner.revision,
                "streamID": restoredOwner.streamID!, "relay": true, "kind": "characters", "text": "must remain unsent"])
            throw AppError.message("A daemon owner whose TTY changed must reject input")
        } catch let error as RemoteHTTPError { try require(error.status == 409, "A changed daemon owner TTY must be409") }
        try require(ownerProbe.read { $0.writes.isEmpty } && ownerEngine.managedPTY.inventory.isEmpty,
            "Owner identity failures must never write to or create another CLI/PTY")
        checks.append("daemon owner PID is bound to the original CLI TTY before the first frame and every relay write")

        let probe = OrcaProbe()
        let live = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("injected")), processReader: { probe.read { $0.records } },
            screenAdapters: [.orca: probe.adapter], orcaSnapshotReader: { try await probe.snapshot(handle: $0) })
        defer { live.stop() }
        live.updateDiscovery([session], records: records); await live.connectScreenHost(.orca)
        try live.setAutomatic(session.id, enabled: true)
        let legacyBaseline = probe.read { $0.legacyReads }
        async let firstRead = live.remoteTerminal(sessionID: session.id, realtime: true)
        async let secondRead = live.remoteTerminal(sessionID: session.id, realtime: true)
        let (first, second) = try await (firstRead, secondRead)
        try require(first.screen.contains("ORCA READY") && !first.screen.contains("legacy"), "Orca web frames must restore the complete owner ANSI snapshot")
        try require(first.appearance?.runs.contains { $0.fg == "#123456" } == true && first.cursor?.visible == true && first.cursor?.padding == 4,
            "Original Orca RGB cells and actual cursor must survive native restoration")
        try require(first.nativeDisplay == nil, "ANSI cells must not claim a live native JPEG display")
        try require(first.keys.contains("characters") && !first.keys.contains("text") && !first.keys.contains("submit"), "Native Orca advertises only direct relay characters and special keys")
        try require(first.revision == second.revision && probe.read({ $0.snapshots }) == 1, "Concurrent viewers must share one original snapshot and its revision")
        _ = try await live.remoteTerminal(sessionID: session.id, realtime: true)
        try require(probe.read { $0.snapshots == 1 && $0.legacyReads == legacyBaseline }, "The shared short cache must avoid duplicate snapshots and legacy CLI text reads")
        checks.append("fresh complete Orca ANSI restores exact RGB/cursor and concurrent viewers share one snapshot")

        probe.mutate { $0.ansi = $0.ansi.replacingOccurrences(of: "18;52;86", with: "171;205;239"); $0.sequence += 1 }
        try await Task.sleep(nanoseconds: 220_000_000)
        let recolored = try await live.remoteTerminal(sessionID: session.id, realtime: true)
        try require(recolored.screen == first.screen && recolored.revision != first.revision && recolored.streamID == first.streamID,
            "Color-only owner output changes revision while preserving the original relay generation")
        probe.mutate { $0.ansi = $0.ansi.replacingOccurrences(of: "[2;5H", with: "[3;9H"); $0.sequence += 1 }
        try await Task.sleep(nanoseconds: 220_000_000)
        let moved = try await live.remoteTerminal(sessionID: session.id, realtime: true)
        try require(moved.screen == recolored.screen && moved.cursor != recolored.cursor && moved.revision != recolored.revision,
            "Cursor-only owner output changes the authoritative revision")
        checks.append("color-only and cursor-only changes update revision without replacing the original input stream")

        let gateway = RemoteNetworkService(engine: live, nodeID: UUID().uuidString, onStatus: { _ in })
        func request(_ method: String, _ route: String, _ body: JSONObject? = nil) throws -> RemoteHTTPRequest {
            let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
            let header = "Host: localhost\r\n" + (body == nil ? "" : "Content-Type: application/json\r\nContent-Length: \(data.count)\r\n")
            return try RemoteHTTPRequest.parse(Data("\(method) \(route) HTTP/1.1\r\n\(header)\r\n".utf8) + data)!
        }
        var compactURL = URLComponents(); compactURL.path = "/api/terminal"
        compactURL.queryItems = [URLQueryItem(name: "session", value: session.id), URLQueryItem(name: "revision", value: moved.revision)]
        let compact = await gateway.handle(try request("GET", compactURL.string!))
        let compactJSON = try JSONSerialization.jsonObject(with: compact.body) as! JSONObject
        try require(compact.status == 200 && compactJSON["screen"] == nil && compactJSON["appearance"] == nil && compactJSON["cursor"] != nil,
            "An unchanged original ANSI frame omits text/styles while retaining exact cursor and controls")
        checks.append("compact original frames preserve cursor and controls without retransmitting cells")

        let input: JSONObject = ["requestID": UUID().uuidString, "sessionID": session.id, "revision": moved.revision, "streamID": moved.streamID!,
            "relay": true, "kind": "characters", "text": "한글 원본"]
        let sent = await gateway.handle(try request("POST", "/api/input", input))
        let duplicate = await gateway.handle(try request("POST", "/api/input", input))
        try require(sent.status == 200 && duplicate.status == 200 && probe.read({ $0.writes.count }) == 1, "A Unicode direct input receipt must write to the original exactly once")
        let write = probe.read { $0.writes[0] }
        try require(write.0.tty == session.tty && write.0.handle == session.orcaHandle && write.1.isRelay && write.1.text == "한글 원본",
            "Native Orca input must preserve the exact original TTY/handle and Unicode")
        let submit = await gateway.handle(try request("POST", "/api/input", ["requestID": UUID().uuidString, "sessionID": session.id, "revision": moved.revision, "kind": "submit", "text": "unsafe composer comparison"]))
        try require(submit.status == 409 && probe.read({ $0.writes.count }) == 1, "Renderer text must never authorize a composed submit against a different legacy CLI screen")
        try require(probe.read { $0.approvals == 0 && $0.legacyReads == legacyBaseline }, "Web ANSI reads/input must preserve the independent automatic approval text source")
        checks.append("receipt-protected Unicode relay reaches the exact original and ANSI renderer cannot authorize compose or approvals")

        let messageProbe = OrcaProbe()
        let messageEngine = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("messages")),
            processReader: { messageProbe.read { $0.records } }, screenAdapters: [.orca: messageProbe.adapter],
            orcaSnapshotReader: { try await messageProbe.snapshot(handle: $0) })
        defer { messageEngine.stop() }
        messageEngine.updateDiscovery([session], records: messageProbe.read { $0.records }); await messageEngine.connectScreenHost(.orca)
        let messageGateway = RemoteNetworkService(engine: messageEngine, nodeID: UUID().uuidString, bonjourEnabled: false, onStatus: { _ in })
        let messageFrame = try await messageEngine.remoteTerminal(sessionID: session.id, realtime: true)
        let messageRequest: JSONObject = ["requestID": UUID().uuidString, "action": "sendMessage", "transport": "terminal", "sessionID": session.id,
            "revision": messageFrame.revision, "streamID": messageFrame.streamID!, "text": "대화 기록 없이 한글 메시지"]
        let messageSent = await messageGateway.handle(try request("POST", "/api/action", messageRequest))
        let messageReplay = await messageGateway.handle(try request("POST", "/api/action", messageRequest))
        try require(messageSent.status == 200 && messageReplay.status == 200 && messageProbe.read({ $0.writes.map { $0.1.kind } }) == [.characters, .enter],
            "A characters-only source must receive one message and one Enter without a queue binding or duplicate writes")
        var multiline = messageRequest; multiline["requestID"] = UUID().uuidString; multiline["text"] = "한 줄\n두 줄"
        let multilineResult = await messageGateway.handle(try request("POST", "/api/action", multiline))
        try require(multilineResult.status == 400 && messageProbe.read({ $0.writes.count }) == 2, "Unsupported multiline input must be rejected before writing")
        messageProbe.mutate { $0.rejectEnter = true }
        var partial = messageRequest; partial["requestID"] = UUID().uuidString; partial["text"] = "문자는 쓰고 Enter는 거부"
        let partialResult = await messageGateway.handle(try request("POST", "/api/action", partial))
        let partialJSON = try JSONSerialization.jsonObject(with: partialResult.body) as! JSONObject
        try require(partialResult.status == 409 && (partialJSON["diagnostics"] as? [String:String])?["delivery"] == "unknown" && messageProbe.read({ $0.writes.count }) == 3,
            "After characters were sent, an Enter refusal is uncertain and must not retype the message")
        checks.append("characters-only original messages, duplicate receipts, multiline rejection and uncertain Enter never replay text")

        probe.mutate { $0.incarnation = "replacement-incarnation" }
        let refused = await gateway.handle(try request("POST", "/api/input", ["requestID": UUID().uuidString, "sessionID": session.id, "revision": moved.revision,
            "streamID": moved.streamID!, "relay": true, "kind": "left", "text": ""]))
        try require(refused.status == 409 && probe.read({ $0.writes.count }) == 1, "A reused handle/new PTY incarnation must be rejected before any relay write")
        let replaced = try await live.remoteTerminal(sessionID: session.id, realtime: true)
        try require(replaced.outputReason != nil && replaced.nativeDisplay == nil && replaced.screen.isEmpty && replaced.keys.isEmpty && replaced.streamID == nil,
            "A replacement incarnation must clear stale colors/text/cursor/input rather than silently select another PTY")
        probe.mutate { $0.incarnation = "private-original-incarnation"; $0.failRead = true }
        let unavailable = try await live.remoteTerminal(sessionID: session.id, realtime: true)
        try require(unavailable.outputReason != nil && unavailable.nativeDisplay == nil && unavailable.appearance == nil && unavailable.cursor == nil && unavailable.keys.isEmpty,
            "A failed native source must remain explicitly unavailable without plain-text color/cursor fallback")
        probe.mutate { $0.failRead = false; $0.ansi = "\u{1b}[2J\u{1b}[HONLY SECOND FRAME\u{1b}[?25h"; $0.sequence += 1 }
        let recovered = try await live.remoteTerminal(sessionID: session.id, realtime: true)
        try require(recovered.screen.contains("ONLY SECOND FRAME") && !recovered.screen.contains("ORCA READY") && recovered.streamID != moved.streamID,
            "Complete snapshots must replace cells and recovery must create a fresh input stream without replay")
        checks.append("incarnation changes and source failure disable input, clear stale cells and recover without raw-delta stitching")

        probe.mutate { $0.replaceProcessDuringRead = true }
        try await Task.sleep(nanoseconds: 220_000_000)
        do { _ = try await live.remoteTerminal(sessionID: session.id, realtime: true); throw AppError.message("Original process replacement during a snapshot must reject the frame") }
        catch let error as RemoteHTTPError { try require(error.status == 409, "Original PID/start/TTY replacement must be409") }
        try require(live.managedPTY.inventory.isEmpty && live.snapshot.sessions.count == 1 && live.snapshot.sessions[0].pid == session.pid && live.snapshot.sessions[0].tty == session.tty,
            "Orca synchronization never creates a new CLI/PTY or changes the original inventory")
        checks.append("original process identity is fenced around snapshot reads and no CLI/PTY is created")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["checks": checks, "liveDaemonQueries": 0, "ownedPTYCreations": 0]), as: UTF8.self))
    }
}
