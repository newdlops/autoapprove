import Foundation
private import zlib

/// One encoder per SSE connection, confined to the connection's serial queue.
/// Every event is flushed immediately; the dictionary survives between events.
public final class RemoteGzipEncoder {
    private let stream: UnsafeMutablePointer<z_stream>
    private var finished = false
    private var scratch = [UInt8](repeating:0,count:32_768)
    public init(level: Int32 = 1) throws {
        guard (1...9).contains(level) else { throw RemoteHTTPError(500,"올바르지 않은 전송 압축 설정입니다.") }
        let pointer = UnsafeMutablePointer<z_stream>.allocate(capacity:1); pointer.initialize(to:z_stream())
        let result = deflateInit2_(pointer,level,Z_DEFLATED,31,8,Z_DEFAULT_STRATEGY,zlibVersion(),Int32(MemoryLayout<z_stream>.size))
        guard result == Z_OK else {
            pointer.deinitialize(count:1); pointer.deallocate()
            throw RemoteHTTPError(503,"터미널 전송 압축을 준비하지 못했습니다. 다시 연결해주세요.")
        }
        stream = pointer
    }
    deinit { deflateEnd(stream); stream.deinitialize(count:1); stream.deallocate() }
    public func encode(_ data: Data, final: Bool = false) throws -> Data {
        guard !finished, data.count <= 2_100_000 else { throw RemoteHTTPError(502,"터미널 전송 압축 상태를 확인하지 못했습니다.") }
        var output = Data()
        try data.withUnsafeBytes { input in
            stream.pointee.next_in = UnsafeMutablePointer(mutating:input.bindMemory(to:UInt8.self).baseAddress)
            stream.pointee.avail_in = uInt(input.count)
            defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
            while true {
                let result = scratch.withUnsafeMutableBytes { buffer -> Int32 in
                    stream.pointee.next_out = buffer.bindMemory(to:UInt8.self).baseAddress
                    stream.pointee.avail_out = uInt(buffer.count)
                    let status = deflate(stream,final ? Z_FINISH : Z_SYNC_FLUSH)
                    output.append(buffer.bindMemory(to:UInt8.self).baseAddress!,count:buffer.count-Int(stream.pointee.avail_out))
                    return status
                }
                guard output.count <= 2_200_000 else { throw RemoteHTTPError(502,"터미널 전송 데이터가 너무 큽니다.") }
                if result == Z_STREAM_END { finished = true; break }
                if !final, stream.pointee.avail_in == 0, stream.pointee.avail_out > 0, result == Z_OK || result == Z_BUF_ERROR { break }
                guard result == Z_OK else { throw RemoteHTTPError(502,"터미널 전송을 압축하지 못했습니다. 다시 연결해주세요.") }
            }
        }
        return output
    }
    public static func accepts(_ header: String?) -> Bool {
        guard let header else { return false }
        var gzip: Double?, wildcard: Double?
        for token in header.lowercased().split(separator:",") {
            let parts = token.split(separator:";",omittingEmptySubsequences:false).map { $0.trimmingCharacters(in:.whitespaces) }
            guard let name = parts.first, name == "gzip" || name == "*" else { continue }
            var quality = 1.0
            let parameters = parts.dropFirst().filter { $0.hasPrefix("q=") }
            if let parameter = parameters.first { quality = Double(parameter.dropFirst(2)).flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil } ?? 0 }
            if parameters.count > 1 { quality = 0 }
            if name == "gzip" { gzip = min(gzip ?? 1,quality) }
            else { wildcard = min(wildcard ?? 1,quality) }
        }
        return (gzip ?? wildcard ?? 0) > 0
    }
}
