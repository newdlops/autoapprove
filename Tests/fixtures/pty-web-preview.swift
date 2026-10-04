// Owns only test PTYs in a private profile; never sends input to a user's CLI.
import Foundation
import Darwin
import AutoApproveCore

@main struct PTYWebPreview {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let environment = ProcessInfo.processInfo.environment.merging(["HOME": directory.path, "ZDOTDIR": directory.path, "PATH": directory.path + ":/usr/bin:/bin:/usr/sbin:/sbin", "PS1": "QA> "]) { _, value in value }
        let original = try ManagedPTY(cwd: directory.path, program: "codex", command: [directory.appendingPathComponent("codex").path], environment: environment)
        defer { original.close() }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), claudeRegistryReader: { _ in [] }, processReader: { try ProcessDiscovery.read().filter { $0.executable.hasPrefix(directory.path + "/") } }, managedPTY: ManagedPTYManager(environment: environment))
        try engine.start()
        let discoveryDeadline = Date().addingTimeInterval(5)
        while !engine.snapshot.sessions.contains(where: { $0.pid == original.descriptor.pid }), Date() < discoveryDeadline {
            await engine.refresh()
            if !engine.snapshot.sessions.contains(where: { $0.pid == original.descriptor.pid }) { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        guard let session = engine.snapshot.sessions.first(where: { $0.pid == original.descriptor.pid }) else {
            throw AppError.message("PTY fixture did not discover its original inert CLI PID \(original.descriptor.pid) before startup deadline")
        }
        try engine.setCustomization(session.id, value: SessionCustomization(title: "기존 대화 · PTY 검증"))
        var status = RemoteNetworkStatus()
        let web = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, name: "PTY QA Mac", bonjourEnabled: false, discoveryAddresses: { [] }, onStatus: { status = $0 })
        try web.start(port: 0)
        for _ in 0..<100 {
            if status.ready { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let port = status.port, status.ready else { throw AppError.message("PTY fixture listener failed: " + status.detail) }
        let peerDirectory = directory.appendingPathComponent("peer")
        try FileManager.default.createDirectory(at: peerDirectory, withIntermediateDirectories: true)
        let peerEngine = try ApprovalEngine(paths: AppPaths(directory: peerDirectory), processReader: { [] }, managedPTY: ManagedPTYManager(environment: environment))
        var peerStatus = RemoteNetworkStatus(); let peerID = UUID().uuidString
        let peerWeb = RemoteNetworkService(engine: peerEngine, nodeID: peerID, name: "PTY QA Peer", bonjourEnabled: false, discoveryAddresses: { [] }, onStatus: { peerStatus = $0 })
        try peerWeb.start(port: 0)
        for _ in 0..<100 where !peerStatus.ready { try await Task.sleep(nanoseconds: 50_000_000) }
        guard let peerPort = peerStatus.port, peerStatus.ready else { throw AppError.message("PTY peer fixture listener failed") }
        print("{\"url\":\"http://127.0.0.1:\(port)\",\"peerURL\":\"http://127.0.0.1:\(peerPort)\",\"peerID\":\"\(peerID)\"}"); fflush(stdout)
        while !Task.isCancelled { try await Task.sleep(nanoseconds: 1_000_000_000) }
        web.stop(); engine.stop(); peerWeb.stop(); peerEngine.stop()
    }
}
