import Foundation
import CryptoKit
import AutoApproveCore
import Network

extension ApprovalTests {
    @MainActor private func payloadState(_ suffix: String) async throws -> RemoteNodeState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-payload-"+suffix+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let records = ProcessDiscovery.parse("88200 1 ttys080 88200 88200 Mon Oct 12 09:00:00 2026 /fixture/codex")
        let engine = try ApprovalEngine(paths:AppPaths(directory:directory),processReader:{records})
        defer { engine.stop() }
        engine.updateDiscovery(ProcessDiscovery.sessions(records),records:records)
        let service = RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,bonjourEnabled:false,discoveryAddresses:{[]},onStatus:{_ in})
        defer { service.stop() }
        return try await service.dashboard().nodes[0].state!
    }

    @MainActor func testWebInventoryDropsOnlyUnusedNoticeHistory() async throws {
        var state = try await payloadState("notices")
        var inbox = SessionInbox()
        let start = Date(timeIntervalSince1970:1_800_000_000)
        for index in 0..<48 {
            let date = start.addingTimeInterval(Double(index)*5)
            let candidate = SessionInbox.Candidate(key:"history-\(index)",kind:.completion,summary:String(repeating:"과거 알림 /fixture/path ",count:40))
            inbox.update([candidate],at:date); inbox.update([candidate],at:date.addingTimeInterval(4))
        }
        let date = start.addingTimeInterval(300)
        inbox.update([.init(key:"old-warning",kind:.question,summary:"읽은 시스템 경고",isSystemSafety:true)],at:date)
        inbox.markRead()
        inbox.update([.init(key:"current-warning",kind:.question,summary:"현재 시스템 변경 경고",isSystemSafety:true)],at:date.addingTimeInterval(1))
        state.sessions[0].session.notices = inbox.entries
        var child = state.sessions[0].session; child.id += "-child"
        state.sessions[0].session.backgroundSessions = [child]
        let original = state.sessions[0].session
        let compact = state.inventory.sessions[0].session
        try expectEqual(compact.notices?.count,1); try expectEqual(compact.notices?.first?.summary,"현재 시스템 변경 경고")
        try expectEqual(compact.backgroundChildren.first?.notices,compact.notices)
        try expectEqual(state.sessions[0].session,original,"Inventory projection cannot edit the native inbox or its read receipts")
        var restored = compact; restored.notices = original.notices; restored.backgroundSessions = original.backgroundSessions
        try expectEqual(restored,original,"Every non-notice field, including questions, errors and safety controls, remains unchanged")
        var previous = state; previous.snapshot.sessions = []; previous.snapshot.events = []; previous.historyDeferred = true
        let before = try RemoteHTTPResponse.json(previous).body.count, after = try RemoteHTTPResponse.json(state.inventory).body.count
        try expect(after*5 < before,"Unused notice history must be excluded from both parent and background session payloads")
    }

    func testWireJSONPreservesStringsWithoutSlashEscapes() throws {
        let values = ["path":"/Users/합성/project/src/main.swift","literal":#"literal\/slash"#,"html":"</script><img src=x>","controls":"한글🙂\n\t\"\\\r", "base64":Data(repeating:255,count:4096).base64EncodedString()]
        let old = JSONEncoder(); old.dateEncodingStrategy = .iso8601
        let encoded = try RemoteHTTPResponse.json(values).body
        let object = try RemoteHTTPResponse.object(values).body
        try expectEqual(try JSONDecoder().decode([String:String].self,from:encoded),values)
        try expectEqual(try JSONDecoder().decode([String:String].self,from:object),values)
        try expect(encoded.count < old.encode(values).count)
        try expect(String(decoding:encoded,as:UTF8.self).contains("/Users/합성/project/src/main.swift"))
    }

    @MainActor func testPeerInventoryReusesOnlyFreshIdentityPinned304() async throws {
        let cache = RemotePeerInventoryCache(), endpoint = NWEndpoint.hostPort(host:"127.0.0.1",port:8765)
        let state = try await payloadState("validation").inventory
        let first = try state.response(ifNoneMatch:nil), start = Date()
        _ = try cache.resolve(first,requestedTag:nil,id:state.id,endpoint:endpoint,at:start)
        let tag = cache.requestTag(for:state.id,endpoint:endpoint,at:start.addingTimeInterval(1))
        let same = try state.response(ifNoneMatch:tag)
        try expectEqual(same.status,304)
        let reused = try cache.resolve(same,requestedTag:tag,id:state.id,endpoint:endpoint,at:start.addingTimeInterval(2))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let received = try decoder.decode(RemoteNodeState.self,from:first.body)
        try expectEqual(reused.sessions[0].session,received.sessions[0].session)
        var changed = state; changed.snapshot.paused = true
        let fresh = try cache.resolve(changed.response(ifNoneMatch:tag),requestedTag:tag,id:state.id,endpoint:endpoint,at:start.addingTimeInterval(3))
        try expect(fresh.snapshot.paused)
        let freshTag = cache.requestTag(for:state.id,endpoint:endpoint,at:start.addingTimeInterval(4))
        var wrong = try changed.response(ifNoneMatch:freshTag); wrong.nodeID = UUID().uuidString
        try expectThrows(try cache.resolve(wrong,requestedTag:freshTag,id:state.id,endpoint:endpoint,at:start.addingTimeInterval(4))); try expectEqual(cache.count,0)
        try expectThrows(try cache.resolve(same,requestedTag:tag,id:state.id,endpoint:endpoint))
        _ = try cache.resolve(first,requestedTag:nil,id:state.id,endpoint:endpoint,at:start)
        try expect(cache.requestTag(for:state.id,endpoint:.hostPort(host:"127.0.0.2",port:8765),at:start) == nil)
        _ = try cache.resolve(first,requestedTag:nil,id:state.id,endpoint:endpoint,at:start)
        try expectThrows(try cache.resolve(same,requestedTag:tag,id:state.id,endpoint:endpoint,at:start.addingTimeInterval(301)))
        var legacy = first; legacy.entityTag = nil
        _ = try cache.resolve(legacy,requestedTag:nil,id:state.id,endpoint:endpoint)
        try expectEqual(cache.count,0,"Legacy 200 stays supported without retaining unverifiable data")
    }

    @MainActor func testPeerInventoryValidationRetentionIsBounded() async throws {
        let cache = RemotePeerInventoryCache(), endpoint = NWEndpoint.hostPort(host:"127.0.0.1",port:8765)
        var state = try await payloadState("bounds").inventory
        let start = Date()
        for index in 0..<40 {
            state.id = "fixture-\(index)"
            _ = try cache.resolve(state.response(ifNoneMatch:nil),requestedTag:nil,id:state.id,endpoint:endpoint,at:start.addingTimeInterval(Double(index)))
        }
        try expectEqual(cache.count,32)
        cache.prune(liveIDs:[state.id],at:start.addingTimeInterval(41)); try expectEqual(cache.count,1)
        cache.removeAll()
        state.name = String(repeating:"x",count:600_000)
        for index in 0..<10 {
            state.id = "large-\(index)"
            _ = try cache.resolve(state.response(ifNoneMatch:nil),requestedTag:nil,id:state.id,endpoint:endpoint)
        }
        try expect(cache.retainedBytes <= 4_194_304); try expect(cache.count <= 6)
        state.name = String(repeating:"x",count:1_048_577)
        let large = try state.response(ifNoneMatch:nil)
        _ = try cache.resolve(large,requestedTag:nil,id:state.id,endpoint:endpoint)
        try expect(cache.requestTag(for:state.id,endpoint:endpoint) == nil)
        cache.prune(liveIDs:[state.id],at:Date().addingTimeInterval(301));try expectEqual(cache.count,0)
    }

    @MainActor func testPeerInventoryCompressionKeepsRepresentationValidatorsAndCache() async throws {
        var state = try await payloadState("compressed").inventory
        state.name = String(repeating:"합성 이름🙂 e\u{301} /fixture/path ",count:500)
        let identity = try state.response(ifNoneMatch:nil)
        let compressed = try await state.response(ifNoneMatch:nil,acceptsGzip:true)
        let json = JSONDecoder();json.dateDecodingStrategy = .iso8601
        let received = try json.decode(RemoteNodeState.self,from:identity.body)
        try expectEqual(compressed.status,200); try expectEqual(compressed.nodeID,state.id)
        try expect(compressed.body.count*4 < identity.body.count)
        try expectEqual(try RemoteGzipDecoder.complete(compressed.body),identity.body,"Compress the exact sorted JSON; preserve every field and Unicode byte")
        for response in [identity,compressed] {
            let hash = SHA256.hash(data:response.body).map { String(format:"%02x",$0) }.joined()
            try expectEqual(response.entityTag,"\""+hash+"\"","A strong validator identifies the selected wire bytes")
        }
        guard let tag = compressed.entityTag else { throw AppError.message("Missing compressed inventory validator") }
        try expect(tag != identity.entityTag)
        let endpoint = NWEndpoint.hostPort(host:"127.0.0.1",port:8765), cache = RemotePeerInventoryCache()
        let decoder = RemotePeerResponseDecoder(expectedNodeID:state.id,acceptsGzip:true)
        let wire = Data("HTTP/1.1 200 OK\r\nContent-Length: \(compressed.body.count)\r\nContent-Encoding: gzip\r\nETag: \(tag)\r\nX-AutoApprove-Node: \(state.id)\r\n\r\n".utf8)+compressed.body
        guard let decoded = try decoder.append(wire) else { throw AppError.message("Missing decoded inventory") }
        try decoder.finish()
        _ = try cache.resolve(decoded,requestedTag:nil,id:state.id,endpoint:endpoint)
        try expectEqual(cache.requestTag(for:state.id,endpoint:endpoint),tag)
        for condition in [tag,"W/"+tag,"\"another\", "+tag,"*"] {
            let same = try await state.response(ifNoneMatch:condition,acceptsGzip:true)
            try expectEqual(same.status,304); try expect(same.body.isEmpty); try expectEqual(same.entityTag,tag)
            if condition == tag {
                let reused = try cache.resolve(same,requestedTag:tag,id:state.id,endpoint:endpoint)
                try expectEqual(reused.name,received.name);try expectEqual(reused.sessions[0].session,received.sessions[0].session)
            }
        }
        try expectEqual(try await state.response(ifNoneMatch:identity.entityTag,acceptsGzip:true).status,200)
        try expectEqual(try state.response(ifNoneMatch:tag).status,200)
        state.snapshot.paused.toggle()
        let changed = try await state.response(ifNoneMatch:tag,acceptsGzip:true)
        try expectEqual(changed.status,200);try expect(changed.entityTag != tag)
        var decodedChanged = changed;decodedChanged.body = try RemoteGzipDecoder.complete(changed.body)
        let updated = try cache.resolve(decodedChanged,requestedTag:tag,id:state.id,endpoint:endpoint)
        try expectEqual(updated.snapshot.paused,state.snapshot.paused)
    }

    @MainActor func testPeerInventoryCompressionKeepsBoundsLegacyAndCancellation() async throws {
        var state = try await payloadState("compression-bounds").inventory
        let legacy = try state.response(ifNoneMatch:nil)
        let explicitIdentity = try await state.response(ifNoneMatch:nil,acceptsGzip:false)
        try expectEqual(explicitIdentity.body,legacy.body);try expectEqual(explicitIdentity.entityTag,legacy.entityTag)
        state.name = String(repeating:"x",count:2_100_001)
        let identity = try state.response(ifNoneMatch:nil), bounded = try await state.response(ifNoneMatch:nil,acceptsGzip:true)
        try expectEqual(bounded.body,identity.body);try expectEqual(bounded.entityTag,identity.entityTag,"Oversized responses retain identity without unbounded compression")
        let cancelled = Task { try await state.response(ifNoneMatch:nil,acceptsGzip:true) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw AppError.message("Cancelled inventory must not be published") }
        catch is CancellationError {}
    }

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
