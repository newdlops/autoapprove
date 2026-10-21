import Foundation
import Network
import AutoApproveCore

@MainActor final class UnavailablePeerStub {
    let listener: NWListener
    var port: UInt16 = 0
    var inventoryReads = 0
    var discoveryReads = 0
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.port = self?.listener.port?.rawValue ?? 0 }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                Task { @MainActor in
                    let text = String(decoding: data ?? Data(), as: UTF8.self)
                    if text.hasPrefix("GET /api/discovery ") { self?.discoveryReads += 1 }
                    if text.hasPrefix("GET /api/inventory ") || text.hasPrefix("GET /api/state ") { self?.inventoryReads += 1 }
                    let response = Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        listener.start(queue: .main)
    }
}

@main struct UnavailableDashboardBench {
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw AppError.message(message) }
    }
    static func request(_ tag: String? = nil, selected: String? = nil) throws -> RemoteHTTPRequest {
        let target = "/api/network" + (selected.map { "?node=" + $0 } ?? "")
        let headers = tag.map { "If-None-Match: " + $0 + "\r\n" } ?? ""
        return try RemoteHTTPRequest.parse(Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\(headers)\r\n".utf8))!
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-unavailable-dashboard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = try UnavailablePeerStub()
        defer { stub.listener.cancel() }
        for _ in 0..<200 where stub.port == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try check(stub.port != 0, "Fixture listener did not start")
        var engines: [ApprovalEngine] = [], services: [RemoteNetworkService] = [], peerIDs: [String] = []
        defer { services.forEach { $0.stop() }; engines.forEach { $0.stop() } }
        let counts = [0, 12, 96]
        for count in counts {
            let directory = root.appendingPathComponent(String(count))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ids = (0..<count).map { _ in UUID().uuidString }
            let address = "http://127.0.0.1:\(stub.port)"
            let peers: [JSONObject] = ids.enumerated().map { index, id in
                ["id": id, "name": "Unavailable fixture \(index)", "address": address, "urls": [address],
                 "port": Int(stub.port), "release": ["version": "0.2.154", "build": 181, "api": 1],
                 "lastSeen": ISO8601DateFormatter().string(from: Date())]
            }
            try JSONSerialization.data(withJSONObject: peers).write(to: directory.appendingPathComponent("web-known-peers.json"))
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
            var ready = false
            let service = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, name: "Synthetic gateway", bonjourEnabled: false,
                discoveryAddresses: { [] }, discoveryHints: { [] }, onStatus: { ready = $0.ready })
            engines.append(engine); services.append(service)
            try service.start(port: 0)
            for _ in 0..<200 where !ready { try await Task.sleep(for: .milliseconds(5)) }
            try check(ready, "Synthetic gateway did not start")
            if count == 12 { peerIDs = ids }
        }
        var results: [[String: Any]] = [], checksum = 0
        for epoch in 0..<3 {
            if epoch > 0 { try await Task.sleep(for: .milliseconds(2100)) }
            for (index, count) in counts.enumerated() {
                let service = services[index]
                let startCPU = cpu(), startWall = ProcessInfo.processInfo.systemUptime
                let dashboard = try await service.dashboard()
                let coldCPU = cpu() - startCPU, coldWall = ProcessInfo.processInfo.systemUptime - startWall
                try check(dashboard.nodes.count == count + 1, "Known peer disappeared")
                for node in dashboard.nodes where !node.local {
                    try check(!node.online && node.loading != true && node.error == "이 Mac이 네트워크에서 연결 해제되었습니다.", "Unavailable state changed")
                }
                var response = await service.handle(try request())
                for _ in 0..<2 { response = await service.handle(try request()) }
                try check(response.status == 200 && response.entityTag != nil, "Missing network snapshot")
                let conditional = try request(response.entityTag)
                let warmCPU = cpu(), warmWall = ProcessInfo.processInfo.systemUptime
                for _ in 0..<128 {
                    let unchanged = await service.handle(conditional)
                    try check(unchanged.status == 304 && unchanged.body.isEmpty, "Unchanged dashboard did not validate")
                    checksum += unchanged.status
                }
                results.append(["peers": count, "epoch": epoch, "coldCPUSeconds": coldCPU, "coldWallSeconds": coldWall,
                    "warmCPUSeconds": cpu() - warmCPU, "warmWallSeconds": ProcessInfo.processInfo.systemUptime - warmWall, "warmRounds": 128])
            }
        }
        try check(stub.inventoryReads == 0, "Background dashboard contacted a known unavailable peer")
        // A user-selected unavailable peer must still attempt an actual read.
        let before = stub.inventoryReads
        let selected = await services[1].handle(try request(selected: peerIDs[0]))
        try check(selected.status == 200 && stub.inventoryReads > before, "Selected peer lost its foreground reconnect")
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print(String(decoding: try JSONSerialization.data(withJSONObject: [
            "results": results, "checksum": checksum, "peakRSSBytes": usage.ru_maxrss,
            "backgroundInventoryReads": before, "selectedInventoryReads": stub.inventoryReads - before,
            "discoveryReads": stub.discoveryReads, "inputPosts": 0, "captures": 0,
            "scope": "Actual running release Core; 0/12/96 saved unavailable synthetic peers on owned loopback stub. Cold and TTL-expired dashboards plus 128 conditional reads per epoch. Not whole-app CPU or physical-phone latency."
        ], options: [.sortedKeys]), as: UTF8.self))
    }
}
