import Foundation
import Network
import AutoApproveCore

private final class UnresponsiveDashboardPeer: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    init() throws {
        listener = try NWListener(using:.tcp,on:.any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {connection.cancel(); return}
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue:DispatchQueue.global(qos:.utility))
        }
        listener.start(queue:DispatchQueue.global(qos:.utility))
    }
    func stop() {
        listener.cancel(); lock.lock(); let values = connections; connections = []; lock.unlock()
        values.forEach {$0.cancel()}
    }
}

extension ApprovalTests {
    @MainActor func testColdDashboardPublishesHealthyPeerBeforeStalledReads() async throws {
        let directory = URL(fileURLWithPath:"/private/tmp/aa-dashboard-budget-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let stalled = try UnresponsiveDashboardPeer(); defer {stalled.stop()}
        for _ in 0..<100 {if (stalled.listener.port?.rawValue ?? 0) > 0 {break};try await Task.sleep(for:.milliseconds(10))}
        guard let stalledPort = stalled.listener.port?.rawValue, stalledPort > 0 else {throw AppError.message("QA listener unavailable")}
        let healthy = try ApprovalEngine(paths:AppPaths(directory:directory.appendingPathComponent("healthy")),processReader:{[]})
        defer {healthy.stop()}
        try healthy.setWebEnabled(true,port:0,bonjourEnabled:false,discoveryAddresses:{[]})
        for _ in 0..<100 {if healthy.webStatus.ready {break};try await Task.sleep(for:.milliseconds(10))}
        guard let healthyService = healthy.webService, let healthyPort = healthyService.port else {throw AppError.message("Healthy QA server unavailable")}
        let paths = AppPaths(directory:directory.appendingPathComponent("gateway"));try paths.prepare()
        let failedIDs = (0..<6).map {_ in UUID().uuidString}
        let peers: [JSONObject] = [["id":healthyService.nodeID,"name":"000 Healthy","address":"http://127.0.0.1:\(healthyPort)"]]
            + failedIDs.enumerated().map {["id":$0.element,"name":"ZZZ Dead \($0.offset)","address":"http://127.0.0.1:\(stalledPort)"]}
        try JSONSerialization.data(withJSONObject:peers).write(to:paths.directory.appendingPathComponent("web-peers.json"))
        let gateway = try ApprovalEngine(paths:paths,processReader:{[]});defer {gateway.stop()}
        try gateway.setWebEnabled(true,port:0,bonjourEnabled:false,discoveryAddresses:{[]})
        guard let service = gateway.webService else {throw AppError.message("Gateway unavailable")}
        let start = ProcessInfo.processInfo.systemUptime
        let first = try await service.dashboard()
        try expect(ProcessInfo.processInfo.systemUptime-start < 1,"Six stalled peers cannot impose their multi-second timeout on the page")
        try expect(first.nodes.contains {$0.id == healthyService.nodeID && $0.online})
        try expect(first.nodes.contains {$0.loading == true});try expectEqual(first.partial,true)
        let secondStart = ProcessInfo.processInfo.systemUptime
        let selected = try await service.dashboard(initial:true,selectedNode:failedIDs[0])
        try expect(ProcessInfo.processInfo.systemUptime-secondStart < 1,"An unavailable bookmarked Mac cannot delay the local page")
        try expect(selected.nodes.first?.local == true && selected.nodes.first?.online == true)
        let again = try await service.dashboard()
        try expect(again.nodes.contains {$0.id == healthyService.nodeID && $0.online},"A pending old address does not hide the healthy cached Mac")
    }
}
