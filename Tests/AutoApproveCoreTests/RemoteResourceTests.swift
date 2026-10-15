import Foundation
import AutoApproveCore

extension ApprovalTests {
    @MainActor func testDashboardValidatorIncludesAllContentButNotObservationTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-validator-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let service = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, bonjourEnabled: false, discoveryAddresses: { [] }, onStatus: { _ in })
        defer { service.stop() }
        let original = try await service.dashboard()
        let first = try original.response(ifNoneMatch: nil)
        try expectEqual(first.status, 200)
        guard let tag = first.entityTag else { throw AppError.message("Missing inventory validator") }
        var observed = original; observed.updatedAt = original.updatedAt.addingTimeInterval(10)
        let same = try observed.response(ifNoneMatch: tag)
        try expectEqual(same.status, 304); try expect(same.body.isEmpty)
        try expectEqual(same.observedAt, observed.updatedAt)
        try expectEqual(try observed.response(ifNoneMatch: "\"another\", " + tag).status, 304)
        try expectEqual(try observed.response(ifNoneMatch: String(tag.dropFirst(2))).status, 304)
        let changes: [(inout RemoteDashboard) -> Void] = [
            { $0.gatewayID += "-new-process" },
            { $0.discovery = "Discovery failed" },
            { $0.partial = true },
            { $0.gatewayRelease = RemoteWebVersion(version: "9.8.7", build: 999) },
            { $0.nodes[0].online = false; $0.nodes[0].error = "Unreachable" },
            { $0.nodes[0].loading = true },
            { $0.nodes[0].state?.snapshot.paused.toggle() },
            { $0.nodes[0].state?.name = "Changed node" },
            { $0.nodes[0].state?.webURLs = ["http://192.168.0.22:8765"] },
            { $0.nodes[0].state?.historyDeferred = false }
        ]
        for change in changes {
            var value = original; change(&value)
            let response = try value.response(ifNoneMatch: tag)
            try expectEqual(response.status, 200, "A real control, identity or reachability change must carry a full fresh body")
            try expect(response.entityTag != tag)
        }
    }

    @MainActor func testConditionalDashboardRevalidatesIdentityOriginAndControls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-conditional-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let service = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, bonjourEnabled: false, discoveryAddresses: { [] }, onStatus: { _ in })
        defer { service.stop() }
        func request(_ extra: String = "") throws -> RemoteHTTPRequest {
            try RemoteHTTPRequest.parse(Data("GET /api/network HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\(extra)\r\n".utf8))!
        }
        let first = await service.handle(try request())
        guard let tag = first.entityTag else { throw AppError.message("Missing inventory validator") }
        let unchanged = await service.handle(try request("If-None-Match: \(tag)\r\n"))
        try expectEqual(unchanged.status, 304); try expect(unchanged.body.isEmpty)
        let wrongNode = await service.handle(try request("If-None-Match: \(tag)\r\nX-AutoApprove-Node: other\r\n"))
        try expectEqual(wrongNode.status, 409)
        let foreign = await service.handle(try request("If-None-Match: \(tag)\r\nOrigin: http://foreign.example\r\n"))
        try expectEqual(foreign.status, 403)
        try engine.setPaused(true)
        let changed = await service.handle(try request("If-None-Match: \(tag)\r\n"))
        try expectEqual(changed.status, 200)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(RemoteDashboard.self, from: changed.body)
        try expectEqual(value.nodes.first?.state?.snapshot.paused, true)
        let noValidator = await service.handle(try request())
        try expectEqual(noValidator.status, 200, "Old clients still receive the complete inventory")
    }

    @MainActor func testRepeatedDashboardReadsDoNotRepublishNativeWebStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-status-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        var emissions = 0
        let service = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, bonjourEnabled: false, discoveryAddresses: { [] }, onStatus: { _ in emissions += 1 })
        defer { service.stop() }
        _ = try await service.dashboard()
        let first = emissions
        for _ in 0..<20 { _ = try await service.dashboard() }
        try expectEqual(first, 1); try expectEqual(emissions, first, "Unchanged polling must not invalidate native windows or rewrite webPort")
        try service.start(port: 0)
        for _ in 0..<100 { if emissions > first { break }; try await Task.sleep(for: .milliseconds(10)) }
        try expect(emissions > first, "A real listener transition must still publish")
        service.stop(); let stopped = emissions
        service.stop(); try expectEqual(emissions, stopped)
    }
}
