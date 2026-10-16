import Foundation
import Darwin

/// NDJSON framing with a bounded partial line. Oversized frames are drained to
/// their delimiter without retaining their contents, then reported once.
final class MCPInputReader {
    enum Frame { case message(Data), invalid }
    private let descriptor: Int32
    private let maximum: Int
    private var chunk = [UInt8](repeating: 0, count: 8192)
    private var offset = 0, length = 0
    private var line = Data()
    private var dropping = false, ended = false

    init(descriptor: Int32, maximum: Int = 256_000) {
        precondition(maximum >= 0 && maximum <= 256_000)
        self.descriptor = descriptor; self.maximum = maximum
    }

    func next() throws -> Frame? {
        guard !ended else { return nil }
        while true {
            if offset == length {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if count == 0 {
                    ended = true
                    return line.isEmpty && !dropping ? nil : finish()
                }
                offset = 0; length = count
            }
            let newline = chunk[offset..<length].firstIndex(of: 10)
            let end = newline ?? length
            if !dropping {
                // One extra byte permits a maximum-sized CRLF frame. The CR
                // is stripped at the delimiter before checking the wire limit.
                if end - offset <= maximum + 1 - line.count {
                    line.append(contentsOf: chunk[offset..<end])
                } else {
                    line = Data(); dropping = true
                }
            }
            offset = newline.map { $0 + 1 } ?? end
            if newline != nil { return finish() }
        }
    }

    private func finish() -> Frame {
        defer { line = Data(); dropping = false }
        guard !dropping else { return .invalid }
        if line.last == 13 { line.removeLast() }
        guard line.count <= maximum else { return .invalid }
        return .message(line)
    }
}
