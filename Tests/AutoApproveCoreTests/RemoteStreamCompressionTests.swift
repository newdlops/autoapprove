import Foundation
import zlib
import AutoApproveCore

private final class StreamInflateProbe {
    private let stream: UnsafeMutablePointer<z_stream>
    private(set) var ended = false
    init() throws {
        let pointer = UnsafeMutablePointer<z_stream>.allocate(capacity:1);pointer.initialize(to:z_stream())
        guard inflateInit2_(pointer,31,zlibVersion(),Int32(MemoryLayout<z_stream>.size)) == Z_OK else { pointer.deinitialize(count:1);pointer.deallocate();throw AppError.message("QA gzip decoder unavailable") }
        stream = pointer
    }
    deinit { inflateEnd(stream);stream.deinitialize(count:1);stream.deallocate() }
    func read(_ data: Data) throws -> Data {
        var result = Data(), scratch = [UInt8](repeating:0,count:32_768)
        try data.withUnsafeBytes { input in
            stream.pointee.next_in = UnsafeMutablePointer(mutating:input.bindMemory(to:UInt8.self).baseAddress)
            stream.pointee.avail_in = uInt(input.count)
            defer {stream.pointee.next_in=nil;stream.pointee.next_out=nil}
            repeat {
                let status = scratch.withUnsafeMutableBytes { buffer -> Int32 in
                    stream.pointee.next_out=buffer.bindMemory(to:UInt8.self).baseAddress;stream.pointee.avail_out=uInt(buffer.count)
                    let status=inflate(stream,Z_NO_FLUSH)
                    result.append(buffer.bindMemory(to:UInt8.self).baseAddress!,count:buffer.count-Int(stream.pointee.avail_out));return status
                }
                guard [Z_OK,Z_STREAM_END,Z_BUF_ERROR].contains(status),result.count<=2_200_000 else {throw AppError.message("Invalid or oversized QA gzip result")}
                if status == Z_STREAM_END {ended=true;break}
            } while stream.pointee.avail_in>0 || stream.pointee.avail_out==0
        }
        return result
    }
}

extension ApprovalTests {
    func testSSEGzipFlushesEachEventAndPreservesExactBytes() throws {
        let encoder=try RemoteGzipEncoder(),decoder=try StreamInflateProbe()
        let screen=String(repeating:"원본 ANSI \u{1b}[32m색상\u{1b}[0m /fixture/project · 한글🙂\n",count:1500)
        var before=0,after=0
        for index in 0..<16 {
            let body=try RemoteHTTPResponse.object(["sessionID":"fixture/original","revision":"frame-\(index)","screen":screen+"\n› \(index)","keys":["characters","enter","escape"],"cursor":["offset":screen.utf16.count],"question":["question":"배포할 환경을 고르세요.","options":["개발","검증"]]]).body
            let event=Data("event: screen\ndata: ".utf8)+body+Data("\n\n".utf8)
            let compressed=try encoder.encode(event)
            before+=event.count;after+=compressed.count
            try expectEqual(try decoder.read(compressed),event,"Each individual flush must be readable before another frame or EOF")
            try expect(!decoder.ended)
        }
        let failure=Data("event: failure\ndata: {\"error\":\"검증용 종료\"}\n\n".utf8)
        try expectEqual(try decoder.read(encoder.encode(failure,final:true)),failure)
        try expect(decoder.ended);try expect(after*10<before,"Repeated terminal text must shrink substantially without changing the event schema")
        try expectThrows(try encoder.encode(Data("late".utf8)))
    }
    func testSSEGzipNegotiationBoundsAndEmptyStart() throws {
        for header in [nil,"","br, deflate","gzip;q=0","gzip;q=0, *;q=1","gzip;q=invalid","gzip;q=-1","gzip;q=2","gzip;q=1;q=0","gzip, gzip;q=0"] as [String?] {try expect(!RemoteGzipEncoder.accepts(header))}
        for header in ["gzip","GZIP; q=0.5, br","*;q=0.5","gzip;q=1,identity;q=0"] {try expect(RemoteGzipEncoder.accepts(header))}
        let encoder=try RemoteGzipEncoder(),decoder=try StreamInflateProbe()
        try expectEqual(try decoder.read(encoder.encode(Data())),Data())
        let heartbeat=Data(": keepalive\n\n".utf8)
        try expectEqual(try decoder.read(encoder.encode(heartbeat)),heartbeat)
        try expectEqual(try decoder.read(encoder.encode(Data(),final:true)),Data());try expect(decoder.ended)
        let bounded=try RemoteGzipEncoder()
        try expectThrows(try bounded.encode(Data(repeating:0,count:2_100_001)))
    }
}
