import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testTerminalReadRecoveryIsBoundedAndNeverRetriesIdentityOrPermission() async throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let frame = try decoder.decode(RemoteTerminalFrame.self,from:RemoteHTTPResponse.object(["sessionID":"fixture","screen":"READY> ","revision":"verified","observedAt":"2026-10-15T00:00:00Z","keys":[]]).body)
        let invalidated = RemoteHTTPError(409,"Synthetic invalidated read",diagnostics:["failureKind":"observationChanged"])
        var reads = 0
        let recovered = try await RemoteTerminalReadRecovery.read {
            reads += 1; if reads < 3 { throw invalidated }; return frame
        }
        try expectEqual(reads,3); try expectEqual(recovered.revision,frame.revision)
        reads = 0
        do { _ = try await RemoteTerminalReadRecovery.read { reads += 1; throw invalidated }; throw AppError.message("Expected bounded failure") }
        catch let error as RemoteHTTPError { try expectEqual(error.status,503); try expectEqual(reads,3) }
        for failure in [RemoteHTTPError(403,"Permission denied"),RemoteHTTPError(409,"Different original",diagnostics:["failureKind":"identity"]),RemoteHTTPError(409,"Unclassified conflict")] {
            reads = 0
            do { _ = try await RemoteTerminalReadRecovery.read { reads += 1; throw failure }; throw AppError.message("Expected original failure") }
            catch let error as RemoteHTTPError { try expectEqual(error.status,failure.status); try expectEqual(reads,1) }
        }
        reads = 0
        let cancelled = Task { @MainActor in try await RemoteTerminalReadRecovery.read { reads += 1; return frame } }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw AppError.message("Expected cancellation") } catch is CancellationError {}
        try expectEqual(reads,0)
    }

    func testTerminalScreenPatchPreservesUTF16AndExactUnicode() throws {
        let head = String(repeating:"한글 e\u{301} /fixture/src/🙂\n",count:90)
        let tail = String(repeating:"\n원본 색상·커서·질문 그대로 👩‍💻",count:80)
        let pairs: [(String,String)] = [
            (head+"READY> "+tail,head+"READY> 새 입력🙂"+tail),
            (head+"🙂"+tail,head+"🙃"+tail), // Common high surrogate, different low.
            (head+"\u{1F600}"+tail,head+"\u{1F200}"+tail), // Common low surrogate.
            (head+"삭제할 문자열"+tail,head+tail),
            (head+"é"+tail,head+"e\u{301}"+tail), // No canonical normalization.
            (head+"abcdef"+tail,head+"ab새 내용ef"+tail),
            (head+tail,head+tail+"\n새 출력"),
            (head+tail,"첫 출력\n"+head+tail),
            (head+tail,head+tail)
        ]
        for (before,after) in pairs {
            guard let patch = RemoteTerminalScreenPatch.make(previous:before,current:after,baseRevision:"base-original") else { throw AppError.message("A large shared screen should produce a patch") }
            let string = before as NSString
            let restored = string.substring(to:patch.prefix)+patch.text+string.substring(from:string.length-patch.suffix)
            try expectEqual(Array(restored.utf8),Array(after.utf8),"Protocol coordinates must restore exact bytes, including combining characters")
            try expectEqual(patch.baseLength,string.length); try expectEqual(patch.length,(after as NSString).length)
            try expectEqual(patch.baseRevision,"base-original")
        }
        try expect(RemoteTerminalScreenPatch.make(previous:"short",current:"short edit",baseRevision:"base") == nil)
        try expect(RemoteTerminalScreenPatch.make(previous:String(repeating:"a",count:5000),current:String(repeating:"b",count:5000),baseRevision:"base") == nil)
    }

    func testPeerGzipDecoderHandlesFragmentsAndBoundedPulls() throws {
        let encoder = try RemoteGzipEncoder(), decoder = try RemoteGzipDecoder()
        var plain = Data(), wire = Data()
        for index in 0..<4 {
            let event = Data(("event: screen\ndata: "+String(repeating:"한글🙂 원본 /fixture/path ",count:9000)+" \(index)\n\n").utf8)
            plain.append(event); wire.append(try encoder.encode(event))
        }
        wire.append(try encoder.encode(Data(),final:true))
        var restored = Data(), position = 0, pulls = 0
        while position < wire.count {
            let count = min([1,7,4096,65_536][position%4],wire.count-position)
            try decoder.append(wire.subdata(in:position..<position+count)); position += count
            while !decoder.needsInput && !decoder.ended {
                let chunk = try decoder.read(maximum:1024); try expect(chunk.count <= 1024)
                restored.append(chunk); pulls += 1
                try expect(pulls < 100_000,"Decoder must progress or request more input")
            }
        }
        try decoder.finish(); try expect(decoder.ended); try expectEqual(restored,plain)
        try expect(pulls > 1000,"Coalesced compressed events must still be pulled in bounded output chunks")
    }

    func testPeerGzipDecoderRejectsCorruptionTruncationAndTrailingBytes() throws {
        let encoder = try RemoteGzipEncoder()
        var wire = try encoder.encode(Data("event: screen\ndata: {\"screen\":\"원본🙂\"}\n\n".utf8))
        wire.append(try encoder.encode(Data(),final:true))
        func decode(_ data: Data) throws {
            let decoder = try RemoteGzipDecoder(); try decoder.append(data)
            while !decoder.needsInput && !decoder.ended { _ = try decoder.read() }
            try decoder.finish()
        }
        try decode(wire)
        try expectThrows(try decode(wire.dropLast(5)))
        var corrupt = wire; corrupt[corrupt.count-5] ^= 0xFF
        try expectThrows(try decode(corrupt))
        try expectThrows(try decode(Data("not a gzip stream".utf8)))
        try expectThrows(try decode(wire+Data("trailing".utf8)))
        let bounded = try RemoteGzipDecoder()
        try expectThrows(try bounded.append(Data(repeating:0,count:65_537)))
        try expectThrows(try bounded.read(maximum:0)); try expectThrows(try bounded.read(maximum:32_769))
        try bounded.append(wire); try expectThrows(try bounded.append(wire))
        while !bounded.needsInput && !bounded.ended { _ = try bounded.read() }
        try bounded.finish()
        try expectThrows(try bounded.append(Data([0])))
    }
}
