import Foundation
import Network
import AutoApproveCore

@MainActor private final class RecoverableDashboardPeer {
    let listener: NWListener
    var port: UInt16 = 0
    var discoveryEnabled = false
    var inventoryReads = 0
    var state: RemoteNodeState
    init(state: RemoteNodeState) throws {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        listener = try NWListener(using:parameters,on:.any)
        listener.stateUpdateHandler = { [weak self] status in Task { @MainActor [weak self] in
            if case .ready = status { self?.port = self?.listener.port?.rawValue ?? 0 }
        } }
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor [weak self] in
            connection.start(queue:.main); self?.receive(connection)
        } }
        listener.start(queue:.main)
    }
    private func receive(_ connection: NWConnection, prefix: Data = Data()) {
        connection.receive(minimumIncompleteLength:1,maximumLength:16_384) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                var bytes = prefix; bytes.append(data ?? Data())
                do {
                    guard let request = try RemoteHTTPRequest.parse(bytes) else {
                        if complete || error != nil { connection.cancel() }
                        else { self.receive(connection,prefix:bytes) }
                        return
                    }
                    let response: RemoteHTTPResponse
                    if request.path == "/api/discovery", self.discoveryEnabled {
                        response = try .object(["service":"autoapprove","version":1,"id":self.state.id,"name":self.state.name,
                            "port":Int(self.port),"urls":["http://127.0.0.1:\(self.port)"],
                            "release":["version":"0.2.154","build":181,"api":1]])
                    } else if ["/api/inventory","/api/state"].contains(request.path) {
                        self.inventoryReads += 1
                        response = try .json(self.state)
                    } else { response = RemoteHTTPResponse(status:503,body:Data("{}".utf8)) }
                    var output = Data("HTTP/1.1 \(response.status) Fixture\r\nContent-Type: application/json\r\nContent-Length: \(response.body.count)\r\nX-AutoApprove-Node: \(self.state.id)\r\nConnection: close\r\n\r\n".utf8)
                    output.append(response.body)
                    connection.send(content:output,completion:.contentProcessed { _ in connection.cancel() })
                } catch { connection.cancel() }
            }
        }
    }
}

extension ApprovalTests {
    @MainActor func testKnownUnavailableDashboardPreservesSelectionDiscoveryAndFreshReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-known-dashboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let paths = AppPaths(directory:directory); try paths.prepare()
        let engine = try ApprovalEngine(paths:paths,processReader:{[]}); defer { engine.stop() }
        let template = RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,bonjourEnabled:false,discoveryAddresses:{[]},onStatus:{_ in})
        defer { template.stop() }
        var state = try await template.dashboard().nodes[0].state!
        state.id = UUID().uuidString; state.name = "Selected fixture"
        let selected = try RecoverableDashboardPeer(state:state); defer { selected.listener.cancel() }
        state.id = UUID().uuidString; state.name = "Discovered fixture"
        let discovered = try RecoverableDashboardPeer(state:state); defer { discovered.listener.cancel() }
        for _ in 0..<100 where selected.port == 0 || discovered.port == 0 { try await Task.sleep(for:.milliseconds(10)) }
        try expect(selected.port > 0 && discovered.port > 0)
        let known: [JSONObject] = [selected,discovered].map { peer in
            let address = "http://127.0.0.1:\(peer.port)"
            return ["id":peer.state.id,"name":peer.state.name,"address":address,"urls":[address],"port":Int(peer.port),
                "release":["version":"0.2.154","build":181,"api":1],"lastSeen":ISO8601DateFormatter().string(from:Date())]
        }
        try JSONSerialization.data(withJSONObject:known).write(to:directory.appendingPathComponent("web-known-peers.json"))
        let service = RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,bonjourEnabled:false,discoveryAddresses:{[]},onStatus:{_ in})
        defer { service.stop() }; try service.start(port:0)
        func request(_ tag: String? = nil, node: String? = nil, extra: String = "") throws -> RemoteHTTPRequest {
            let target = "/api/network" + (node.map { "?node=" + $0 } ?? "")
            let validator = tag.map { "If-None-Match: " + $0 + "\r\n" } ?? ""
            return try RemoteHTTPRequest.parse(Data("GET \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n\(validator)\(extra)\r\n".utf8))!
        }
        var first = await service.handle(try request())
        for _ in 0..<2 { first = await service.handle(try request()) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(RemoteDashboard.self,from:first.body)
        try expectEqual(snapshot.nodes.filter {!$0.local && !$0.online && $0.loading != true}.count,2)
        try expectEqual(selected.inventoryReads + discovered.inventoryReads,0)
        let tag = first.entityTag!
        try await Task.sleep(for:.milliseconds(2100))
        try expectEqual((await service.handle(try request(tag))).status,304,"Expired unavailable backgrounds retain the same content")
        try expectEqual((await service.handle(try request(tag,extra:"Origin: http://foreign.example\r\n"))).status,403)
        try expectEqual((await service.handle(try request(tag,extra:"X-AutoApprove-Node: other\r\n"))).status,409)
        let chosen = await service.handle(try request(tag,node:selected.state.id))
        try expectEqual(chosen.status,200); try expect(selected.inventoryReads > 0,"Selecting a saved offline Mac must perform real I/O")
        try expect(try decoder.decode(RemoteDashboard.self,from:chosen.body).nodes.contains {$0.id == selected.state.id && $0.online})
        discovered.discoveryEnabled = true
        var recovered = false
        for _ in 0..<100 {
            let response = await service.handle(try request(tag))
            if response.status == 200, let dashboard = try? decoder.decode(RemoteDashboard.self,from:response.body),
               dashboard.nodes.contains(where:{$0.id == discovered.state.id && $0.online}) { recovered = true; break }
            try await Task.sleep(for:.milliseconds(50))
        }
        try expect(recovered,"An offline conditional validator must not hide discovery recovery")
        let before = selected.inventoryReads
        selected.state.snapshot.paused.toggle()
        try await Task.sleep(for:.milliseconds(3100))
        let refreshed = await service.handle(try request())
        try expect(selected.inventoryReads > before,"Successful inventories still expire and revalidate")
        try expect(try decoder.decode(RemoteDashboard.self,from:refreshed.body).nodes.first {$0.id == selected.state.id}?.state?.snapshot.paused == selected.state.snapshot.paused)
    }
}
