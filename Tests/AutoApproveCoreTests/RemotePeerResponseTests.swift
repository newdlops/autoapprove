import Foundation
import Network
import AutoApproveCore

extension ApprovalTests {
    func testPeerLocalNetworkDenialIsExplicitAndDoesNotReplaceTemporaryLoss() async throws {
        for status: NWPath.Status in [.satisfied,.requiresConnection,.unsatisfied] {
            for reason: NWPath.UnsatisfiedReason in [.notAvailable,.cellularDenied,.wifiDenied,.localNetworkDenied,.vpnInactive] {
                let error = RemoteLAN.localNetworkError(status:status,reason:reason)
                if status == .unsatisfied, reason == .localNetworkDenied {
                    try expectEqual(error?.status,403)
                    try expectEqual(error?.diagnostics?["failureKind"],"permission")
                    try expect(error?.message.contains("AutoApprove") == true)
                    var reads = 0
                    do {
                        _ = try await RemoteTerminalReadRecovery.read { reads += 1; throw error! }
                        throw AppError.message("Explicit OS denial must reach the caller")
                    } catch let value as RemoteHTTPError { try expectEqual(value.status,403) }
                    try expectEqual(reads,1,"A privacy denial cannot be retried as an observation race")
                } else { try expect(error == nil,"Temporary loss, VPN/Wi-Fi policy and satisfied paths keep existing behavior") }
            }
        }
    }
    func testPeerHTTPResponseDecodesFragmentedIdentityAndGzipExactly() throws {
        let body = Data((String(repeating:"원본🙂 e\u{301} /fixture/file.swift\r\n",count:4000)+"\u{0}").utf8)
        for compressed in [false,true] {
            let payload = compressed ? try RemoteGzipEncoder(level:6).encode(body,final:true) : body
            let wire = Data("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\nContent-Type: application/octet-stream\r\nX-AutoApprove-Node: owner\r\nX-AutoApprove-Observed-At: 2026-10-27T06:00:00Z\r\nETag: \"current\"\r\n\(compressed ? "Content-Encoding: gzip\r\n" : "")\r\n".utf8)+payload
            for chunk in [1,17,64_000] {
                let decoder = RemotePeerResponseDecoder(expectedNodeID:"owner",acceptsGzip:true)
                var response: RemoteHTTPResponse?
                for offset in stride(from:0,to:wire.count,by:chunk) { response = try decoder.append(wire.subdata(in:offset..<min(wire.count,offset+chunk))) ?? response }
                try decoder.finish(); try expectEqual(response?.body,body); try expectEqual(response?.nodeID,"owner")
                try expectEqual(response?.entityTag,"\"current\""); try expectEqual(response?.contentType,"application/octet-stream")
                try expectEqual(response?.observedAt?.ISO8601Format(),"2026-10-27T06:00:00Z")
                try expectEqual(decoder.expectedBytes,payload.count); try expectEqual(decoder.receivedBytes,wire.count)
                try expectThrows(try decoder.append(Data()))
            }
        }
        let legacy = RemotePeerResponseDecoder(expectedNodeID:"owner")
        let response = try legacy.append(Data("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8))
        try expectEqual(response?.body,Data("{}".utf8)); try legacy.finish()
        try expectNil(response?.observedAt)
        let conditional = RemotePeerResponseDecoder(expectedNodeID:"owner",acceptsGzip:true)
        let unchanged = try conditional.append(Data("HTTP/1.1 304 Not Modified\r\nX-AutoApprove-Node: owner\r\nETag: \"current\"\r\n\r\n".utf8))
        try expectEqual(unchanged?.status,304); try expectEqual(unchanged?.body,Data()); try conditional.finish()
    }

    func testPeerHTTPResponseRejectsAmbiguousHeadersAndWrongIdentity() throws {
        let invalid = [
            "HTTP/2 200 OK\r\nContent-Length: 0", "HTTP/1.1 200 OK", "HTTP/1.1 200 OK\r\nContent-Length: -1",
            "HTTP/1.1 200 OK\r\nContent-Length: 1x", "HTTP/1.1 200 OK\r\nContent-Length: 4000001",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\ncontent-length: 0", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Encoding: br", "HTTP/1.1 304 Not Modified\r\nContent-Length: 1",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nETag: a\r\nETag: b",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-AutoApprove-Observed-At: yesterday",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Type: text/plain\ninjected: value",
            "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nBad Header: value"
        ]
        for header in invalid {
            let decoder = RemotePeerResponseDecoder(expectedNodeID:"owner",acceptsGzip:true)
            do { _ = try decoder.append(Data((header+"\r\n\r\n").utf8)); throw AppError.message("Expected protocol rejection") }
            catch let error as RemoteHTTPError { try expectEqual(error.status,502); try expectEqual(error.diagnostics?["failureKind"],"protocol") }
        }
        let wrong = RemotePeerResponseDecoder(expectedNodeID:"owner",acceptsGzip:true)
        do { _ = try wrong.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nX-AutoApprove-Node: other\r\n\r\n".utf8)); throw AppError.message("Expected early identity rejection") }
        catch let error as RemoteHTTPError { try expectEqual(error.diagnostics?["failureKind"],"identity") }
        try expectThrows(try RemotePeerResponseDecoder().append(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Encoding: gzip\r\n\r\n".utf8)))
        try expectThrows(try RemotePeerResponseDecoder().append(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nextra".utf8)))
        try expectThrows(try RemotePeerResponseDecoder().append(Data(repeating:65,count:16_385)))
        try expectThrows(try RemotePeerResponseDecoder().append(Data(repeating:65,count:64_001)))
    }

    func testPeerHTTPResponseRequiresCompleteBoundedGzipAndBody() throws {
        let plain = Data(String(repeating:"원본🙂",count:3000).utf8), compressed = try RemoteGzipEncoder().encode(plain,final:true)
        func decode(_ data: Data) throws {
            let decoder = RemotePeerResponseDecoder(acceptsGzip:true)
            _ = try decoder.append(Data("HTTP/1.1 200 OK\r\nContent-Length: \(data.count)\r\nContent-Encoding: gzip\r\n\r\n".utf8)+data)
            try decoder.finish()
        }
        try decode(compressed)
        var corrupt = compressed; corrupt[corrupt.count-5] ^= 255
        try expectThrows(try decode(corrupt)); try expectThrows(try decode(compressed.dropLast(5)))
        try expectThrows(try decode(compressed+Data([0])))
        let incomplete = RemotePeerResponseDecoder()
        try expect(try incomplete.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort".utf8)) == nil)
        do { try incomplete.finish(); throw AppError.message("Expected truncated body") }
        catch let error as RemoteHTTPError { try expectEqual(error.status,503) }
        let encoder = try RemoteGzipEncoder(), half = Data(repeating:120,count:2_000_000)
        var exact = try encoder.encode(half); exact.append(try encoder.encode(half,final:true))
        try expectEqual(try RemoteGzipDecoder.complete(exact).count,4_000_000)
        let oversized = try RemoteGzipEncoder(); var bomb = try oversized.encode(half)
        bomb.append(try oversized.encode(half)); bomb.append(try oversized.encode(Data([120]),final:true))
        do { _ = try RemoteGzipDecoder.complete(bomb); throw AppError.message("Expected decompression limit") }
        catch let error as RemoteHTTPError { try expectEqual(error.diagnostics?["failureKind"],"protocol") }
        try expectThrows(try RemoteGzipDecoder.complete(compressed,maximum:100))
    }
}
