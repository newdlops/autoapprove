// Only the caller's private tmux socket is exposed. Never enrolls other user sessions.
import Foundation
import AutoApproveCore

@main struct LiveWebMessages {
    @MainActor static func main() async throws {
        let socket = CommandLine.arguments[1], tmux = CommandLine.arguments[2], directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let result = try CommandRunner.run(tmux, ["-S", socket, "list-panes", "-a", "-F", "#{pane_tty}"])
        let ttys = Set(result.output.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { $0.replacingOccurrences(of: "/dev/", with: "") })
        let reader: @Sendable () throws -> [ProcessRecord] = { try ProcessDiscovery.read().filter { ttys.contains($0.tty) || TmuxPaneHandle.isServer($0.executable) } }
        var sessions = [AgentSession](), records = [ProcessRecord]()
        for _ in 0..<100 {
            records = try reader(); sessions = ProcessDiscovery.sessions(records).filter { ttys.contains($0.tty.replacingOccurrences(of: "/dev/", with: "")) && $0.terminal == .tmux }
            if Set(sessions.map(\.agent)) == Set([AgentKind.codex, .claude]) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard sessions.count == 2 else { throw AppError.message("Private real CLI sessions were not discovered") }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("profile")), processReader: reader, terminalInputAvailable: { false })
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.tmux); try engine.setPaused(true)
        let node = UUID().uuidString
        let service = RemoteNetworkService(engine: engine, nodeID: node, name: "실제 CLI 메시지 격리 검사", bonjourEnabled: false, discoveryAddresses: { [] }) { status in
            if status.ready, let port = status.port {
                let rows = sessions.map { ["id": $0.id, "pid": String($0.pid), "tty": $0.tty, "started": $0.started, "agent": $0.agent.rawValue] }
                let data: JSONObject = ["url": "http://127.0.0.1:\(port)", "node": node, "sessions": rows]
                try? JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("ready.json"))
            }
        }
        defer { service.stop() }
        try service.start(port: 0)
        while !Task.isCancelled { await engine.refresh(); try await Task.sleep(for: .milliseconds(500)) }
    }
}
