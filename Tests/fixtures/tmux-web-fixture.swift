// Publishes only the isolated QA pane. No Bonjour advertisement or user input.
import Foundation
import AutoApproveCore

@main struct TmuxWebFixture {
    @MainActor static func main() async throws {
        let socket = CommandLine.arguments[1], tmux = CommandLine.arguments[2]
        let directory = URL(fileURLWithPath: CommandLine.arguments[3])
        let result = try CommandRunner.run(tmux, ["-S", socket, "list-panes", "-a", "-F", "#{pane_pid}"])
        let pid = Int32(result.output.trimmingCharacters(in: .whitespacesAndNewlines))!
        let records = try ProcessDiscovery.read()
        guard var session = ProcessDiscovery.sessions(records).first(where: { $0.pid == pid && $0.terminal == .tmux }) else {
            throw AppError.message("Private QA pane not discovered")
        }
        session.cwd = "/fixture/tmux-browser"; session.terminalTitle = "tmux QA · 실제 격리 터미널"
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("profile")), terminalInputAvailable: { false })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: records)
        await engine.connectScreenHost(.tmux)
        try engine.setAutomatic(session.id, enabled: true)
        let service = RemoteNetworkService(engine: engine, nodeID: "tmux-qa", name: "tmux QA · 격리 검증용 Mac", bonjourEnabled: false, discoveryAddresses: { [] }) { status in
            if status.ready, let port = status.port {
                try? Data(String(port).utf8).write(to: directory.appendingPathComponent("port"))
            }
        }
        defer { service.stop() }
        try service.start(port: 0)
        while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
    }
}
