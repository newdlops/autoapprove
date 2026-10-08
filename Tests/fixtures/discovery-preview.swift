// Isolated discovery service: no Bonjour, physical subnet scan, user session or input.
import Foundation
import AutoApproveCore

@main struct DiscoveryPreview {
    static func addresses(_ directory: URL, _ file: String) -> [String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory))
        defer { engine.stop() }
        let node = UUID().uuidString
        let service = RemoteNetworkService(engine: engine, nodeID: node, name: "격리 검색 검사", bonjourEnabled: false,
            discoveryAddresses: { Self.addresses(directory, "candidates.json") }, discoveryHints: { Self.addresses(directory, "hints.json") },
            webVersion: RemoteWebVersion(version: "0.2.40", build: 46)) { status in
                if status.ready, let port = status.port {
                    let value: JSONObject = ["url":"http://127.0.0.1:\(port)","id":node]
                    try? JSONSerialization.data(withJSONObject: value).write(to: directory.appendingPathComponent("ready.json"))
                }
            }
        defer { service.stop() }
        try service.start(port: 0)
        while !Task.isCancelled { try await Task.sleep(for: .seconds(1)) }
    }
}
