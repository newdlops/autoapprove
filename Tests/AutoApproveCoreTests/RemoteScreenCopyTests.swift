import Foundation
import Network
import AutoApproveCore

extension ApprovalTests {
    func testScrollCopyPreservesExactUnicodeInBothDirections() throws {
        let lines = (0..<120).map { "[\($0)] 한글🙂 e\u{301} é 👩‍💻 \u{0} \r\n" }
        let before = lines.joined()
        let pairs = [(before,lines.dropFirst(5).joined()+"새 마지막 줄🙃\n"),
                     (before,"새 첫 줄🙂\r\n"+lines.dropLast(7).joined()),
                     (before,before),
                     (String(repeating:"aba🙂e\u{301}",count:3000),String(repeating:"aba🙂e\u{301}",count:2999)+"다음")]
        for (old,current) in pairs {
            guard let span = RemoteTerminalScreenCopy.make(previous:old,current:current,baseRevision:"verified-base") else { throw AppError.message("Expected a long scroll overlap") }
            let units = Array(old.utf16)
            let restored = span.head + String(decoding:units[span.start..<(span.start+span.count)],as:UTF16.self) + span.tail
            try expectEqual(Array(restored.utf8),Array(current.utf8),"No normalization, surrogate splitting or whitespace loss")
            try expectEqual(span.baseLength,units.count); try expectEqual(span.length,current.utf16.count)
            try expectEqual(span.baseRevision,"verified-base"); try expect(span.count>=1024)
        }
    }
    func testScrollCopyBoundsWorkAndRejectsUnrelatedScreens() throws {
        for (before,current) in [("", ""),("short","short"),(String(repeating:"a",count:4000),String(repeating:"b",count:4000)),
                                  (String(repeating:"a",count:131_073),String(repeating:"a",count:131_072))] {
            try expect(RemoteTerminalScreenCopy.make(previous:before,current:current,baseRevision:"base") == nil)
        }
        try expect(RemoteTerminalScreenCopy.make(previous:String(repeating:"a",count:4000),current:String(repeating:"a",count:4000),baseRevision:String(repeating:"b",count:513)) == nil)
        let before = String(repeating:"ab",count:65_000)+"c", current = String(repeating:"ab",count:64_999)+"cd"
        guard let span = RemoteTerminalScreenCopy.make(previous:before,current:current,baseRevision:"base") else { throw AppError.message("Periodic near-limit input must progress") }
        let units = Array(before.utf16)
        try expectEqual(span.head+String(decoding:units[span.start..<(span.start+span.count)],as:UTF16.self)+span.tail,current)
    }
    @MainActor func testPeerReplacementCancelsOldReadAndRejectsLateCompletion() async throws {
        let cache = RemotePeerStateCache(), oldEndpoint = NWEndpoint.hostPort(host:"127.0.0.1",port:8765), newEndpoint = NWEndpoint.hostPort(host:"127.0.0.1",port:8766)
        let value = try JSONDecoder().decode(RemoteNodeView.self,from:Data("{\"id\":\"peer\",\"name\":\"QA\",\"local\":false,\"online\":true}".utf8))
        let old = Task { try? await Task.sleep(for:.seconds(30)); return value }
        let fresh = Task { value }, oldToken = UUID(), token = UUID()
        cache.insert(old,id:"peer",token:oldToken,endpoint:oldEndpoint)
        cache.insert(fresh,id:"peer",token:token,endpoint:newEndpoint)
        try expect(old.isCancelled); try expect(!fresh.isCancelled)
        try expect(!cache.isCurrent(id:"peer",token:oldToken)); try expect(cache.isCurrent(id:"peer",token:token))
        cache.finish(id:"peer",token:token,endpoint:newEndpoint,expires:Date().addingTimeInterval(30),value:value)
        _ = await old.value
        cache.finish(id:"peer",token:oldToken,endpoint:oldEndpoint,expires:.distantPast)
        try expect(cache.value(for:"peer",endpoint:newEndpoint)?.online == true,"A late failure cannot expire or replace the new read")
        try expectNil(cache.value(for:"peer",endpoint:oldEndpoint)); try expectEqual(cache.count,1)
        cache.removeAll(); try expect(!cache.isCurrent(id:"peer",token:token))
    }
}
