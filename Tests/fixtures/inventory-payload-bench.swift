import Foundation
import AutoApproveCore

@main struct InventoryPayloadBench {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath:"/private/tmp/aa-payload-bench-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let records = ProcessDiscovery.parse((0..<24).map { "\(82000+$0) 1 ttys\(80+$0) \(82000+$0) \(82000+$0) Mon Oct 12 09:00:00 2026 /fixture/codex" }.joined(separator:"\n"))
        let engine = try ApprovalEngine(paths:AppPaths(directory:root),processReader:{records})
        defer { engine.stop() }
        engine.updateDiscovery(ProcessDiscovery.sessions(records),records:records)
        let service = RemoteNetworkService(engine:engine,nodeID:UUID().uuidString,bonjourEnabled:false,discoveryAddresses:{[]},onStatus:{_ in})
        defer { service.stop() }
        let request = try RemoteHTTPRequest.parse(Data("GET /api/state HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\r\n".utf8))!
        let response = await service.handle(request), decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var state = try decoder.decode(RemoteNodeState.self,from:response.body)
        let start = Date(timeIntervalSince1970:1_800_000_000)
        for index in state.sessions.indices {
            var inbox = SessionInbox()
            for item in 0..<40 {
                let date = start.addingTimeInterval(Double(item)*5)
                let candidate = SessionInbox.Candidate(key:"history-\(index)-\(item)",kind:.completion,summary:String(repeating:"합성 과거 작업 완료 · /fixture/project/src/main.swift · ",count:6))
                inbox.update([candidate],at:date);inbox.update([candidate],at:date.addingTimeInterval(4))
            }
            inbox.markRead()
            inbox.update([.init(key:"safety-\(index)",kind:.question,summary:"합성 현재 시스템 변경 경고",isSystemSafety:true)],at:start.addingTimeInterval(300))
            state.sessions[index].session.notices = inbox.entries
        }
        var previous = state
        previous.snapshot.sessions = [];previous.snapshot.events = [];previous.historyDeferred = true
        let legacy = JSONEncoder();legacy.dateEncodingStrategy = .iso8601
        let before = try legacy.encode(previous), current = state.inventory
        let after = try RemoteHTTPResponse.json(current).body
        guard current.sessions.allSatisfy({$0.session.notices?.count == 1}), state.sessions.allSatisfy({$0.session.notices?.count == 41}) else { throw AppError.message("Notice projection changed original data or lost safety") }
        let first = try current.response(ifNoneMatch:nil)
        let repeated = try current.response(ifNoneMatch:first.entityTag)
        guard repeated.status == 304, repeated.body.isEmpty else { throw AppError.message("Conditional inventory did not suppress repeated body") }
        let compressed = try await current.response(ifNoneMatch:nil,acceptsGzip:true)
        let compressedRepeated = try await current.response(ifNoneMatch:compressed.entityTag,acceptsGzip:true)
        guard try RemoteGzipDecoder.complete(compressed.body) == first.body,
              compressed.entityTag != first.entityTag, compressedRepeated.status == 304,
              compressedRepeated.body.isEmpty else { throw AppError.message("Negotiated inventory changed data or conditional semantics") }
        var timings = [String:[Double]]()
        // Alternate the encodings; this measures complete response preparation,
        // including encoding, task handoff, compression and hashing, not UI CPU.
        for index in 0..<30 {
            for gzip in index.isMultiple(of:2) ? [false,true] : [true,false] {
                let started = ProcessInfo.processInfo.systemUptime
                _ = try await current.response(ifNoneMatch:gzip ? compressed.entityTag : first.entityTag,acceptsGzip:gzip)
                timings[gzip ? "gzipMS" : "identityMS",default:[]].append((ProcessInfo.processInfo.systemUptime-started)*1000)
            }
        }
        let base64 = Data((0..<65536).map { UInt8($0 % 256) }).base64EncodedString()
        let sample = ["image":base64,"path":"/fixture/project/src/main.swift","text":"한글 🙂\n</script> /usr/bin/env"]
        let escaped = try legacy.encode(sample), wire = try RemoteHTTPResponse.json(sample).body
        guard try JSONDecoder().decode([String:String].self,from:wire) == sample else { throw AppError.message("Wire codec changed strings") }
        let report: [String:Any] = ["sessions":24,"nativeNotices":24*41,"webSafetyNotices":24,
            "previousInventoryBytes":before.count,"currentInventoryBytes":after.count,"unchangedPeerReads":20,"previousPeerBodyBytes":20*after.count,"conditionalPeerBodyBytes":20*repeated.body.count,
            "identityRepresentationBytes":first.body.count,"gzipRepresentationBytes":compressed.body.count,"unchangedGzipBodyBytes":compressedRepeated.body.count,"responsePreparation":timings,
            "slashSampleBefore":escaped.count,"slashSampleAfter":wire.count,"scope":"Same synthetic state, previous inventory projection/encoding versus current production projection/encoding; no user content or CPU claim"]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    }
}
