import Foundation
import AutoApproveCore

@MainActor private final class IsolationAdvertisement: RemoteServiceAdvertising {
    var publications = 0
    func publish(name: String, type: String, port: UInt16, txt: Data, onChange: @escaping @MainActor (Bool) -> Void) { publications += 1 }
    func stop() {}
}

extension ApprovalTests {
    @MainActor func testLoopbackServerDoesNotDiscoverAdvertiseOrRewritePeers() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aa-loopback-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let peer = UUID().uuidString, address = "http://192.168.43.8:8765"
        let manual: [JSONObject] = [["id": peer, "name": "Saved fixture", "address": address]]
        let known: [JSONObject] = [["id": peer, "name": "Saved fixture", "address": address, "urls": [address],
                                   "lastSeen": ISO8601DateFormatter().string(from: Date())]]
        let manualFile = home.appendingPathComponent("web-peers.json"), knownFile = home.appendingPathComponent("web-known-peers.json")
        let manualData = try JSONSerialization.data(withJSONObject: manual), knownData = try JSONSerialization.data(withJSONObject: known)
        try manualData.write(to: manualFile); try knownData.write(to: knownFile)
        let engine = try ApprovalEngine(paths: AppPaths(directory: home))
        defer { engine.stop() }
        var status = RemoteNetworkStatus(), discoveries = 0
        let advertisement = IsolationAdvertisement()
        let service = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, loopbackOnly: true,
            discoveryAddresses: { discoveries += 1; return [address] }, advertisement: advertisement, onStatus: { status = $0 })
        defer { service.stop() }
        try service.start(port: 0)
        for _ in 0..<100 where !status.ready { try await Task.sleep(for: .milliseconds(20)) }
        try expect(status.ready)
        let base = "http://127.0.0.1:\(status.port!)"
        try expectEqual(status.urls, [base])
        let (body, response) = try await URLSession.shared.data(from: URL(string: base + "/api/network")!)
        try expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let network = try JSONSerialization.jsonObject(with: body) as! JSONObject
        try expectEqual((network["nodes"] as? [JSONObject])?.count, 1, "Saved LAN peers must not be contacted or included")
        var request = URLRequest(url: URL(string: base + "/api/peers")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["address": address])
        let (_, rejected) = try await URLSession.shared.data(for: request)
        try expectEqual((rejected as? HTTPURLResponse)?.statusCode, 403, "Loopback execution must not add an outbound LAN connection")
        try await Task.sleep(for: .milliseconds(350))
        try expectEqual(advertisement.publications, 0); try expectEqual(discoveries, 0)
        var fallback = RemoteNetworkStatus()
        let rival = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, loopbackOnly: true,
            advertisement: advertisement, onStatus: { fallback = $0 })
        defer { rival.stop() }
        try rival.start(port: status.port!, allowPortFallback: true)
        for _ in 0..<250 where !fallback.ready { try await Task.sleep(for: .milliseconds(20)) }
        try expect(fallback.ready, "A busy fixed loopback endpoint must recover to an available port")
        try expect(fallback.port != status.port)
        try expectEqual(fallback.urls, ["http://127.0.0.1:\(fallback.port!)"])
        let (_, fallbackResponse) = try await URLSession.shared.data(from: URL(string: fallback.urls[0] + "/api/discovery")!)
        try expectEqual((fallbackResponse as? HTTPURLResponse)?.statusCode, 200, "The advertised fallback URL must reach the actual socket")
        try expectEqual(advertisement.publications, 0)
        rival.stop()
        service.stop()
        try expectEqual(try Data(contentsOf: manualFile), manualData)
        try expectEqual(try Data(contentsOf: knownFile), knownData, "A local-only run must preserve existing saved peers")
    }
}
