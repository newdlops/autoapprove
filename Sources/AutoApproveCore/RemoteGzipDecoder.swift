import Foundation
private import zlib

/// Incremental peer decoder, confined to the peer stream's serial queue.
/// It retains at most one 64KiB compressed receive. Callers pull bounded output
/// until they have a whole SSE event, then stop until downstream is ready.
public final class RemoteGzipDecoder {
    private let stream: UnsafeMutablePointer<z_stream>
    private var input = Data()
    private var offset = 0
    private var drain = false
    public private(set) var ended = false
    public var needsInput: Bool { !ended && offset == input.count && !drain }
    public init() throws {
        let pointer = UnsafeMutablePointer<z_stream>.allocate(capacity:1); pointer.initialize(to:z_stream())
        guard inflateInit2_(pointer,31,zlibVersion(),Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            pointer.deinitialize(count:1); pointer.deallocate()
            throw RemoteHTTPError(503,"Mac의 압축 스트림을 준비하지 못했습니다. 다시 연결합니다.")
        }
        stream = pointer
    }
    deinit { inflateEnd(stream); stream.deinitialize(count:1); stream.deallocate() }
    public func append(_ data: Data) throws {
        guard needsInput, data.count <= 65_536 else { throw RemoteHTTPError(503,"Mac의 압축 스트림 순서를 확인하지 못했습니다. 다시 연결합니다.") }
        input = data; offset = 0
    }
    public func read(maximum: Int = 32_768) throws -> Data {
        guard (1...32_768).contains(maximum) else { throw RemoteHTTPError(502,"Mac의 압축 해제 크기가 올바르지 않습니다.") }
        if ended || needsInput { return Data() }
        // A read owns its scratch storage; idle decoders retain no output buffer.
        return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity:maximum) { buffer in
            var consumed = 0, produced = 0
            let result = input.withUnsafeBytes { bytes -> Int32 in
                stream.pointee.next_in = UnsafeMutablePointer(mutating:bytes.bindMemory(to:UInt8.self).baseAddress?.advanced(by:offset))
                stream.pointee.avail_in = uInt(input.count-offset)
                defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
                let available = stream.pointee.avail_in
                stream.pointee.next_out = buffer.baseAddress; stream.pointee.avail_out = uInt(maximum)
                let result = inflate(stream,Z_NO_FLUSH)
                consumed = Int(available-stream.pointee.avail_in); produced = maximum-Int(stream.pointee.avail_out)
                return result
            }
            offset += consumed; drain = produced == maximum
            guard [Z_OK,Z_BUF_ERROR,Z_STREAM_END].contains(result) else { throw RemoteHTTPError(503,"Mac의 압축 스트림이 손상되었습니다. 다시 연결합니다.") }
            if result == Z_STREAM_END {
                guard offset == input.count else { throw RemoteHTTPError(503,"Mac의 압축 스트림 뒤에 잘못된 데이터가 있습니다. 다시 연결합니다.") }
                ended = true; drain = false
            } else if consumed == 0 && produced == 0 {
                guard offset == input.count else { throw RemoteHTTPError(503,"Mac의 압축 스트림을 해제하지 못했습니다. 다시 연결합니다.") }
                drain = false
            }
            if offset == input.count && !drain { input = Data(); offset = 0 }
            return Data(bytes:buffer.baseAddress!,count:produced)
        }
    }
    public func finish() throws {
        guard ended else { throw RemoteHTTPError(503,"Mac의 압축 스트림이 전송 중 끊겼습니다. 다시 연결합니다.") }
    }
    /// Finite peer GETs use the same bounded inflater and require the footer.
    public static func complete(_ data: Data, maximum: Int = 4_000_000) throws -> Data {
        guard (1...4_000_000).contains(maximum), data.count <= 4_000_000 else {
            throw RemoteHTTPError(502,"Mac의 응답 크기가 올바르지 않습니다.",diagnostics:["failureKind":"protocol"])
        }
        let decoder = try Self(); var output = Data()
        for offset in stride(from:0,to:data.count,by:65_536) {
            try decoder.append(data.subdata(in:offset..<min(data.count,offset+65_536)))
            while !decoder.needsInput, !decoder.ended {
                let chunk = try decoder.read(maximum:min(32_768,maximum-output.count+1))
                guard output.count+chunk.count <= maximum else {
                    throw RemoteHTTPError(502,"Mac의 압축 해제 응답이 너무 큽니다.",diagnostics:["failureKind":"protocol"])
                }
                output.append(chunk)
            }
        }
        try decoder.finish(); return output
    }
}
