// Injected native-window contract checks. No TCC prompts, capture APIs or user CLI.
import Foundation
import AutoApproveCore

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AppError.message(message) }
}

@main struct TerminalWindowChecks {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let records = ProcessDiscovery.parse("85001 1 ttys085 85001 85001 Mon Oct 5 09:00:01 2026 /private/fixture/codex")
        var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .terminal
        let adapter = ScreenHostAdapter(screens: { targets in
            TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "same original screen", title: "Private visual fixture") })
        }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records); await engine.connectTerminal()
        let service = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, onStatus: { _ in })
        let body = try JSONSerialization.data(withJSONObject: ["requestID": UUID().uuidString, "sessionID": session.id, "view": "screen"])
        let head = Data("POST /api/terminal/connect HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        let response = await service.handle(try RemoteHTTPRequest.parse(head + body)!)
        try require(response.status == 200, "Explicit original-window connect must exist and return200; received\(response.status)")
        try require(engine.managedPTY.inventory.isEmpty, "Original-window connect must never create an owned PTY")
        print("Native Terminal window connect contract PASS")
    }
}
