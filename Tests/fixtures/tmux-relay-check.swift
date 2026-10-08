import Foundation
import AutoApproveCore

@main struct TmuxRelayChecks {
    @MainActor static func main() async throws {
        let socket = CommandLine.arguments[1], tmux = CommandLine.arguments[2], record = CommandLine.arguments[3]
        func call(_ args: [String]) throws -> String {
            let result = try CommandRunner.run(tmux, ["-S", socket] + args)
            precondition(result.status == 0, result.error); return result.output
        }
        let metadata = try call(["list-panes", "-a", "-F", "#{pid}|#{pane_pid}|#{pane_id}|#{pane_tty}|#{pane_width}|#{pane_height}"]).trimmingCharacters(in: .newlines).components(separatedBy: "|")
        let records = try ProcessDiscovery.read(), server = records.first { $0.pid == Int32(metadata[0]) }!
        let process = records.first { $0.pid == Int32(metadata[1]) }!
        let sessions = ProcessDiscovery.sessions(records)
        let session = sessions.first { $0.pid == process.pid }!
        precondition(session.terminal == .tmux && session.tmuxHandle != nil, "Actual tmux ancestry/environment must bind the CLI to its pane")
        let handle = TmuxPaneHandle(encoded: session.tmuxHandle!)!
        precondition(handle.socket == socket && handle.serverPID == server.pid && handle.pane == metadata[2])
        print("PASS actual tmux CLI discovery and original server/pane identity")
        let target = ScreenTarget(tty: session.tty, handle: session.tmuxHandle, jobPIDs: [session.pid], sourcePID: session.pid, sourceStarted: session.started)
        let relay = TmuxRelay(); defer { relay.stop() }
        let initial = try relay.screen(target)
        let observer = try relay.observe(target)
        await observer.waitForChange()
        precondition(initial.contents.hasPrefix("TMUX QA\n\n"), "Capture must preserve the actual rows")
        precondition(initial.appearance?.runs.contains { $0.fg == "#46a0dc" } == true, "Actual RGB output must survive capture")
        precondition(initial.cursor?.offset == "TMUX QA\n\n".utf16.count && initial.cursor?.padding == 5 && initial.cursor?.style == .bar && initial.cursor?.blink == false)
        print("PASS actual RGB, blank rows, cursor position/shape/blinking")
        let input = RemoteTerminalInput(kind: .characters, text: "한글🧪", relay: true)
        let started = Date()
        let typed = try relay.adapter.input(target, initial.contents, .codex, input)
        let arrow = try relay.adapter.input(target, initial.contents, .codex, RemoteTerminalInput(kind: .left, relay: true))
        precondition(typed == .sent && arrow == .sent)
        await observer.waitForChange()
        var updated = initial
        while !updated.contents.contains("한글🧪"), Date().timeIntervalSince(started) < 2 {
            usleep(10_000); updated = try relay.screen(target)
        }
        precondition(updated.contents.contains("한글🧪"))
        let received = try Data(contentsOf: URL(fileURLWithPath: record))
        precondition(received == Data(("한글🧪" + "\u{1b}[D").utf8))
        print("PASS exact composed UTF-8 and cursor-key bytes; visible update in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        _ = try call(["set-window-option", "-t", "qa:0", "synchronize-panes", "on"])
        do { _ = try relay.adapter.input(target, updated.contents, .codex, input); fatalError("Broadcast input accepted") } catch {}
        _ = try call(["set-window-option", "-t", "qa:0", "synchronize-panes", "off"])
        var stale = target; stale.sourceStarted = "Mon Sep 21 09:00:03 2026"
        let staleResult = try relay.adapter.input(stale, updated.contents, .codex, input)
        precondition(staleResult == .agentMissing)
        var wrong = target; wrong.tty = "/dev/ttys999"
        do { _ = try relay.screen(wrong); fatalError("Other TTY accepted") } catch {}
        print("PASS stale process, wrong TTY and synchronize-panes input rejected")
        var wrongServer = handle; wrongServer.serverStarted = "Mon Sep 21 09:00:03 2026"
        var replaced = target; replaced.handle = wrongServer.encoded
        do { _ = try relay.screen(replaced); fatalError("Reused server identity accepted") } catch {}

        let profile = URL(fileURLWithPath: record).deletingLastPathComponent().appendingPathComponent("profile")
        let engine = try ApprovalEngine(paths: AppPaths(directory: profile), processReader: { try ProcessDiscovery.read() },
            terminalInputAvailable: { false })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records)
        await engine.connectScreenHost(.tmux)
        try engine.setAutomatic(session.id, enabled: true)
        let frame = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        precondition(frame.streamID != nil && frame.keys.contains("characters") && frame.cursor != nil && frame.nativeDisplay == nil)
        precondition(engine.managedPTY.inventory.isEmpty && engine.snapshot.sessions.first?.automatic == true)
        let startedHTTP = Date()
        let receipt = try await engine.remoteInput(["sessionID": session.id, "revision": frame.revision,
            "streamID": frame.streamID!, "relay": true, "kind": "characters", "text": "WEB"])
        precondition(receipt["sent"] as? Bool == true)
        var reflected = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        while !reflected.screen.contains("WEB"), Date().timeIntervalSince(startedHTTP) < 2 {
            try await Task.sleep(nanoseconds: 5_000_000)
            reflected = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        }
        precondition(reflected.screen.contains("WEB") && reflected.streamID == frame.streamID && engine.managedPTY.inventory.isEmpty)
        print("PASS real engine/frame/relay input while automatic ON and privileged input unavailable; \(Int(Date().timeIntervalSince(startedHTTP) * 1000)) ms round trip; no PTY created")
        let edge = "\u{1b}[10;1H" + String(repeating: "W", count: 80)
        _ = try call(["send-keys", "-H", "-t", handle.pane] + edge.utf8.map { String(format: "%02x", $0) })
        for _ in 0..<100 {
            if try call(["display-message", "-p", "-t", handle.pane, "#{cursor_x}"]).trimmingCharacters(in: .newlines) == "80" { break }
            usleep(10_000)
        }
        let edgeColumn = try call(["display-message", "-p", "-t", handle.pane, "#{cursor_x}"]).trimmingCharacters(in: .newlines)
        precondition(edgeColumn == "80", "Fixture must reproduce tmux's pending autowrap cursor")
        let edgeFrame = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        precondition(edgeFrame.screen.contains(String(repeating: "W", count: 80)) && edgeFrame.streamID == frame.streamID)
        print("PASS pending autowrap at x == pane width keeps the original stream readable")
        engine.disconnectScreenHost(.tmux)
        do { _ = try await engine.remoteTerminal(sessionID: session.id); fatalError("Disconnected tmux readable") } catch {}
        await engine.connectScreenHost(.tmux)
        let reconnected = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        precondition(reconnected.screen.contains("WEB") && engine.managedPTY.inventory.isEmpty)
        print("PASS disconnect/reconnect shares the same original pane and state")
        relay.stop()
        let after = try call(["list-panes", "-a", "-F", "#{pane_pid}|#{pane_tty}|#{pane_width}|#{pane_height}"]).trimmingCharacters(in: .newlines)
        precondition(after == metadata[1] + "|" + metadata[3] + "|80|25")
        precondition(kill(process.pid, 0) == 0)
        print("PASS observer disconnect preserves the same original PID, TTY and dimensions")
    }
}
