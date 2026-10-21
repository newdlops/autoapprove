import Foundation
import AutoApproveCore

private actor DashboardEncodingGate {
    private var calls = 0
    private var waiting: CheckedContinuation<Void, Never>?
    func prepare() async throws {
        calls += 1
        if calls == 1 { await withCheckedContinuation { waiting = $0 } }
        // Deliberately ignore cancellation here: the HTTP owner must still
        // reject a cancelled or obsolete result supplied by a custom encoder.
    }
    func isWaiting() -> Bool { waiting != nil }
    func count() -> Int { calls }
    func release() { let value = waiting; waiting = nil; value?.resume() }
}

private actor DashboardEncodingCompletion {
    private var status: Int?
    func finish(_ value: Int) { status = value }
    func value() -> Int? { status }
}

@MainActor private func waitForDashboardCompletion(_ completion: DashboardEncodingCompletion) async throws -> Int {
    for _ in 0..<500 {
        if let value = await completion.value() { return value }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AppError.message("HTTP caller did not wake while its cancelled producer was held")
}

@MainActor private func waitForDashboardEncoding(_ gate: DashboardEncodingGate) async throws {
    for _ in 0..<500 {
        if await gate.isWaiting() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AppError.message("Synthetic encoder did not reach its gate")
}

private func dashboardEncodingRequest(_ headers: String = "") throws -> RemoteHTTPRequest {
    try RemoteHTTPRequest.parse(Data("GET /api/network HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\(headers)\r\n".utf8))!
}

private func decodedDashboard(_ response: RemoteHTTPResponse) throws -> RemoteDashboard {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(RemoteDashboard.self, from: response.body)
}

extension ApprovalTests {
    @MainActor func testDashboardCancellationWakesBeforeHeldProducerAndAllowsNewRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-cancel-wake-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let gate = DashboardEncodingGate(), completion = DashboardEncodingCompletion()
        let service = RemoteNetworkService(engine: engine, nodeID: "encoding-fixture", bonjourEnabled: false, loopbackOnly: true,
            discoveryAddresses: { [] }, dashboardEncodingPreparation: { try await gate.prepare() }, onStatus: { _ in })
        defer { service.stop(); Task { await gate.release() } }
        let request = try dashboardEncodingRequest()
        let old = Task { let response = await service.handle(request); await completion.finish(response.status); return response }
        try await waitForDashboardEncoding(gate)
        old.cancel()
        let status = try await waitForDashboardCompletion(completion)
        try expect(status != 200 && status != 304)
        try expect(await gate.isWaiting(), "The cancelled producer must still be held when its HTTP caller finishes")
        let fresh = await service.handle(request); try expectEqual(fresh.status, 200)
        try expectEqual(await gate.count(), 2)
        await gate.release(); _ = await old.value
        try expectEqual(service.dashboardEncodingWaiterCount, 0)
    }

    @MainActor func testDashboardStopWakesBeforeHeldPreparationIsReleased() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-stop-wake-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let gate = DashboardEncodingGate(), completion = DashboardEncodingCompletion()
        let service = RemoteNetworkService(engine: engine, nodeID: "encoding-fixture", bonjourEnabled: false, loopbackOnly: true,
            discoveryAddresses: { [] }, dashboardEncodingPreparation: { try await gate.prepare() }, onStatus: { _ in })
        defer { service.stop(); Task { await gate.release() } }
        let old = Task { let response = await service.handle(try dashboardEncodingRequest()); await completion.finish(response.status); return response }
        try await waitForDashboardEncoding(gate)
        service.stop()
        try expectEqual(try await waitForDashboardCompletion(completion), 503)
        try expect(await gate.isWaiting(), "Stop wakes HTTP before a cancellation-ignoring hook completes")
        try expectEqual(service.dashboardEncodingWaiterCount, 0)
        await gate.release(); _ = try await old.value
    }

    @MainActor func testDashboardCancellationRacesNeverFailSurvivingConsumers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-races-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let service = RemoteNetworkService(engine: engine, nodeID: "encoding-fixture", bonjourEnabled: false, loopbackOnly: true,
            discoveryAddresses: { [] }, onStatus: { _ in })
        defer { service.stop() }
        let request = try dashboardEncodingRequest()
        for round in 0..<32 {
            try engine.setPaused(round.isMultiple(of: 2))
            let tasks = (0..<8).map { _ in Task { await service.handle(request) } }
            let cancel = Task.detached { for index in [0,2,4,6] { tasks[index].cancel(); await Task.yield() } }
            await cancel.value
            for index in tasks.indices {
                let response = await tasks[index].value
                if !index.isMultiple(of: 2) {
                    try expectEqual(response.status, 200, "A new surviving consumer cannot inherit an abandoned producer's failure")
                    try expectEqual(try decodedDashboard(response).nodes[0].state?.snapshot.paused, round.isMultiple(of: 2))
                }
            }
            try expectEqual(service.dashboardEncodingWaiterCount, 0)
        }
    }

    @MainActor private func waitForDashboardConsumers(_ count: Int, service: RemoteNetworkService) async throws {
        for _ in 0..<500 {
            if service.dashboardEncodingWaiterCount == count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Synthetic dashboard consumers did not join the shared work")
    }

    @MainActor func testDashboardConcurrentRequestsShareOnlyActiveEncoding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-share-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let gate = DashboardEncodingGate()
        let service = RemoteNetworkService(engine: engine, nodeID: "encoding-fixture", bonjourEnabled: false, loopbackOnly: true,
            discoveryAddresses: { [] }, dashboardEncodingPreparation: { try await gate.prepare() }, onStatus: { _ in })
        defer { service.stop(); Task { await gate.release() } }
        let request = try dashboardEncodingRequest()
        let tasks = (0..<8).map { _ in Task { await service.handle(request) } }
        try await waitForDashboardEncoding(gate)
        try await waitForDashboardConsumers(8, service: service)
        await gate.release()
        var tag: String?
        for task in tasks {
            let response = await task.value
            try expectEqual(response.status, 200); try expect(response.observedAt != nil)
            let observed = try decodedDashboard(response).updatedAt
            try expect(abs(observed.timeIntervalSince(response.observedAt!)) < 1,
                "Every shared consumer must receive its own observation timestamp in the body and header")
            try expect(abs(observed.timeIntervalSinceNow) < 5, "The canonical epoch date must never reach an HTTP body")
            if let tag { try expectEqual(response.entityTag, tag) } else { tag = response.entityTag }
        }
        let firstCount = await gate.count()
        try expectEqual(firstCount, 1, "Equivalent live consumers need only one projection and canonical encoding")
        try expectEqual(service.dashboardEncodingWaiterCount, 0)
        let next = await service.handle(request)
        try expectEqual(next.status, 200)
        let nextCount = await gate.count()
        try expectEqual(nextCount, 2, "A later unconditional request cannot use a retained completed-body cache")
        try expectEqual(service.dashboardEncodingWaiterCount, 0)
    }

    @MainActor func testDashboardOneCancelledConsumerKeepsSharedEncodingAlive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-share-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let gate = DashboardEncodingGate()
        let service = RemoteNetworkService(engine: engine, nodeID: "encoding-fixture", bonjourEnabled: false, loopbackOnly: true,
            discoveryAddresses: { [] }, dashboardEncodingPreparation: { try await gate.prepare() }, onStatus: { _ in })
        defer { service.stop(); Task { await gate.release() } }
        let request = try dashboardEncodingRequest()
        let cancelled = Task { await service.handle(request) }
        try await waitForDashboardEncoding(gate)
        let surviving = Task { await service.handle(request) }
        try await waitForDashboardConsumers(2, service: service)
        cancelled.cancel(); await gate.release()
        let cancelledResponse = await cancelled.value, validResponse = await surviving.value
        try expect(cancelledResponse.status != 200 && cancelledResponse.status != 304)
        try expectEqual(validResponse.status, 200)
        let calls = await gate.count(); try expectEqual(calls, 1)
        try expectEqual(service.dashboardEncodingWaiterCount, 0)
        guard let tag = validResponse.entityTag else { throw AppError.message("Missing surviving response validator") }
        let fresh = await service.handle(try dashboardEncodingRequest("If-None-Match: \(tag)\r\n"))
        try expectEqual(fresh.status, 304)
        let after = await gate.count(); try expectEqual(after, 1)
    }

    @MainActor func testDashboardDefaultEncodingPreservesWireAndFreshControls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-encoding-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let service = RemoteNetworkService(engine: engine, nodeID: "encoding-fixture", name: "한글 e\u{301} 🤖 /fixture",
            bonjourEnabled: false, loopbackOnly: true, discoveryAddresses: { [] }, onStatus: { _ in })
        defer { service.stop() }
        var oldTag: String?
        for paused in [false, true, false, true] {
            try engine.setPaused(paused)
            let expected = try await service.dashboard().response(ifNoneMatch: nil)
            let response = await service.handle(try dashboardEncodingRequest(oldTag.map { "If-None-Match: \($0)\r\n" } ?? ""))
            try expectEqual(response.status, 200)
            try expectEqual(response.entityTag, expected.entityTag)
            try expectEqual(try decodedDashboard(response).nodes[0].state?.snapshot.paused, paused)
            var actualObject = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
            var expectedObject = try JSONSerialization.jsonObject(with: expected.body) as! [String: Any]
            actualObject.removeValue(forKey: "updatedAt"); expectedObject.removeValue(forKey: "updatedAt")
            try expectEqual(actualObject as NSDictionary, expectedObject as NSDictionary, "Every non-observation JSON field must match the original encoder")
            var independent = try await service.dashboard()
            independent.updatedAt = response.observedAt!
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try expectEqual(response.body, try encoder.encode(independent),
                "The worker-prepared body must match a complete independent encoding, including the root date")
            guard let tag = response.entityTag else { throw AppError.message("Missing actor encoder validator") }
            let unchanged = await service.handle(try dashboardEncodingRequest("If-None-Match: \(tag)\r\n"))
            try expectEqual(unchanged.status, 304); try expect(unchanged.body.isEmpty)
            oldTag = tag
        }
    }

    @MainActor func testDashboardLateEncodingCannotDisplaceNewValidator() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-late-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let gate = DashboardEncodingGate()
        let service = RemoteNetworkService(engine: engine, nodeID: "encoding-fixture", bonjourEnabled: false, loopbackOnly: true,
            discoveryAddresses: { [] }, dashboardEncodingPreparation: { try await gate.prepare() }, onStatus: { _ in })
        defer { service.stop() }
        let old = Task { await service.handle(try dashboardEncodingRequest()) }
        try await waitForDashboardEncoding(gate)
        try engine.setPaused(true)
        let newer = await service.handle(try dashboardEncodingRequest())
        try expectEqual(try decodedDashboard(newer).nodes[0].state?.snapshot.paused, true)
        await gate.release()
        let earlier = try await old.value
        try expectEqual(try decodedDashboard(earlier).nodes[0].state?.snapshot.paused, false, "A queued input must be an immutable value snapshot")
        guard let tag = newer.entityTag else { throw AppError.message("Missing newer validator") }
        let same = await service.handle(try dashboardEncodingRequest("If-None-Match: \(tag)\r\n"))
        try expectEqual(same.status, 304)
        let calls = await gate.count()
        try expectEqual(calls, 2, "A late old result cannot overwrite the current fast-path validator")
    }

    @MainActor func testDashboardCancellationCannotPublishOrCacheLateEncoding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let gate = DashboardEncodingGate()
        let service = RemoteNetworkService(engine: engine, nodeID: "encoding-fixture", bonjourEnabled: false, loopbackOnly: true,
            discoveryAddresses: { [] }, dashboardEncodingPreparation: { try await gate.prepare() }, onStatus: { _ in })
        defer { service.stop() }
        let snapshot = try await service.dashboard(), tag = try snapshot.response(ifNoneMatch: nil).entityTag!
        let request = try dashboardEncodingRequest()
        let task = Task { await service.handle(request) }
        try await waitForDashboardEncoding(gate)
        task.cancel(); await gate.release()
        let response = await task.value
        try expect(response.status != 200 && response.status != 304)
        let next = await service.handle(try dashboardEncodingRequest("If-None-Match: \(tag)\r\n"))
        try expectEqual(next.status, 304)
        let calls = await gate.count()
        try expectEqual(calls, 2, "Cancelled encoding cannot seed a validator fast path")
    }

    @MainActor func testDashboardStopRejectsLateEncodingFromOldGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-stop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let gate = DashboardEncodingGate()
        let service = RemoteNetworkService(engine: engine, nodeID: "encoding-fixture", bonjourEnabled: false, loopbackOnly: true,
            discoveryAddresses: { [] }, dashboardEncodingPreparation: { try await gate.prepare() }, onStatus: { _ in })
        defer { service.stop() }
        let old = Task { await service.handle(try dashboardEncodingRequest()) }
        try await waitForDashboardEncoding(gate)
        service.stop(); await gate.release()
        let response = try await old.value
        try expectEqual(response.status, 503, "A previous service generation must not publish a late dashboard")
        let fresh = await service.handle(try dashboardEncodingRequest())
        try expectEqual(fresh.status, 200)
    }

    @MainActor func testDashboardEncodingNeverPrecedesOriginAndNodeChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-auth-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [] })
        defer { engine.stop() }
        let gate = DashboardEncodingGate()
        let service = RemoteNetworkService(engine: engine, nodeID: "encoding-fixture", bonjourEnabled: false, loopbackOnly: true,
            discoveryAddresses: { [] }, dashboardEncodingPreparation: { try await gate.prepare() }, onStatus: { _ in })
        defer { service.stop() }
        let foreign = await service.handle(try dashboardEncodingRequest("Origin: http://foreign.example\r\n"))
        let wrong = await service.handle(try dashboardEncodingRequest("X-AutoApprove-Node: another\r\n"))
        try expectEqual(foreign.status, 403); try expectEqual(wrong.status, 409)
        let calls = await gate.count(); try expectEqual(calls, 0)
    }
}
