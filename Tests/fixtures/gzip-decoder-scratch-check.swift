import Foundation
import Dispatch
import Darwin
import zlib
import AutoApproveCore

@main enum GzipDecoderScopedScratchCheck {
    typealias Base = GzipScopedScratchCheck
    static func require(_ value: Bool, _ message: String) throws { try Base.require(value, message) }
    static func pointers(_ decoder: RemoteGzipDecoder) throws {
        guard let stream = Mirror(reflecting: decoder).children.first(where: { $0.label == "stream" })?.value as? UnsafeMutablePointer<z_stream> else { throw Base.Failure.invalid("Missing actual decoder C stream") }
        try require(stream.pointee.next_in == nil && stream.pointee.next_out == nil, "Decoder C pointers escaped a read")
    }
    static func state(_ decoder: RemoteGzipDecoder) -> [String: Any] {
        let fields = Dictionary(uniqueKeysWithValues: Mirror(reflecting: decoder).children.compactMap { child -> (String, Any)? in child.label.map { ($0, child.value) } })
        return ["needsInput": decoder.needsInput, "ended": decoder.ended, "offset": fields["offset"] as! Int, "drain": fields["drain"] as! Bool, "inputBytes": (fields["input"] as! Data).count]
    }
    static func error(_ status: Int, decoder: RemoteGzipDecoder? = nil, _ body: () throws -> Void) throws -> [String: Any] {
        do { try body(); throw Base.Failure.invalid("Expected decoder rejection") }
        catch let value as RemoteHTTPError {
            try require(value.status == status, "Wrong decoder error status")
            var result: [String: Any] = ["status": value.status, "message": value.message, "diagnostics": value.diagnostics ?? [:]]
            if let decoder { try pointers(decoder); result["state"] = state(decoder) }
            return result
        }
    }
    static func drain(_ decoder: RemoteGzipDecoder, maximum: Int, retained: inout [Data], signature: inout UInt64) throws -> Data {
        var data = Data(), reads = 0
        while !decoder.needsInput && !decoder.ended {
            let chunk = try decoder.read(maximum: maximum); try pointers(decoder)
            try require(chunk.count <= maximum, "Output bound changed")
            data.append(chunk); retained.append(chunk); reads += 1
            signature = signature &* 1099511628211 ^ UInt64(chunk.count) ^ (decoder.needsInput ? 1 : 0) ^ (decoder.ended ? 2 : 0)
            try require(reads <= 5_000_000, "Decoder stopped making progress")
        }
        return data
    }
    static func retainedExact(_ chunks: [Data], _ expected: Data) throws {
        var offset = 0
        for chunk in chunks {
            try require(offset + chunk.count <= expected.count && chunk == expected.subdata(in: offset..<(offset + chunk.count)), "Earlier returned Data changed")
            offset += chunk.count
        }
        try require(offset == expected.count, "Returned data lost bytes")
    }
    static func decode(_ wire: Data, expected: Data, receive: Int, maximum: Int) throws -> [String: Any] {
        let decoder = try RemoteGzipDecoder(); var retained: [Data] = [], output = Data(), signature: UInt64 = 0
        for offset in stride(from: 0, to: wire.count, by: receive) {
            try require(decoder.needsInput, "Compressed input not consumed")
            try decoder.append(wire.subdata(in: offset..<min(offset + receive, wire.count)))
            output.append(try drain(decoder, maximum: maximum, retained: &retained, signature: &signature))
        }
        try decoder.finish(); try pointers(decoder); try require(output == expected, "Fragmented decode changed bytes"); try retainedExact(retained, expected)
        return ["receive": receive, "maximum": maximum, "bytes": output.count, "reads": retained.count, "signature": String(signature), "state": state(decoder)]
    }
    static func compressed(_ data: Data, level: Int32 = 1, final: Bool = true) throws -> Data { try RemoteGzipEncoder(level: level).encode(data, final: final) }
    static func guards() throws -> [String: Any] {
        let input = Data((0..<1024).map { UInt8(truncatingIfNeeded: $0 &* 29) }), wire = try compressed(input)
        var result: [String: Any] = [:]
        let empty = try RemoteGzipDecoder()
        for maximum in [-1, 0, 32769, Int.max] { result["maximum/\(maximum)"] = try error(502, decoder: empty) { _ = try empty.read(maximum: maximum) } }
        try require(try empty.read().isEmpty, "Empty read changed")
        result["oversize"] = try error(503, decoder: empty) { try empty.append(Data(repeating: 0, count: 65537)) }
        try empty.append(wire); result["appendOrder"] = try error(503, decoder: empty) { try empty.append(Data()) }
        var retained: [Data] = [], signature: UInt64 = 0
        try require(try drain(empty, maximum: 17, retained: &retained, signature: &signature) == input, "Append rejection changed decoder state")
        try empty.finish(); try retainedExact(retained, input)
        result["appendAfterEnd"] = try error(503, decoder: empty) { try empty.append(Data()) }
        result["invalidAfterEnd"] = try error(502, decoder: empty) { _ = try empty.read(maximum: 0) }
        try require(try empty.read().isEmpty, "Ended read changed")
        let truncated = try RemoteGzipDecoder(); try truncated.append(wire.dropLast())
        retained = []; signature = 0; _ = try drain(truncated, maximum: 32768, retained: &retained, signature: &signature)
        result["truncated"] = try error(503, decoder: truncated) { try truncated.finish() }
        let corrupt = try RemoteGzipDecoder(); try corrupt.append(Data([0, 1, 2, 3, 4, 5]))
        result["corrupt"] = try error(503, decoder: corrupt) { _ = try corrupt.read() }
        let trailing = try RemoteGzipDecoder(); try trailing.append(wire + Data([0x78]))
        result["trailing"] = try error(503, decoder: trailing) { _ = try trailing.read() }
        result["completeLimit"] = try error(502) { _ = try RemoteGzipDecoder.complete(wire, maximum: input.count - 1) }
        result["invalidCompleteLimit"] = try error(502) { _ = try RemoteGzipDecoder.complete(wire, maximum: 0) }
        result["oversizeComplete"] = try error(502) { _ = try RemoteGzipDecoder.complete(Data(repeating: 0, count: 4_000_001)) }
        return result
    }
    static func cases(_ corpusPath: String, _ referencePath: String) throws {
        let corpus = try Base.load(corpusPath, "AGZ1"), compressedGroups = try Base.load(referencePath, "AGZ2")
        try require(corpus.count == compressedGroups.count, "Corpus metadata mismatch")
        var rows: [[String: Any]] = [], events = 0
        for (index, group) in corpus.enumerated() {
            let reference = compressedGroups[index], decoder = try RemoteGzipDecoder()
            try require(group.name == reference.name && group.events.count == reference.events.count, "Group mismatch")
            var originals = Data(), wire = Data(), retained: [Data] = [], signature: UInt64 = 0
            for event in group.events.indices {
                let expected = group.events[event], chunk = reference.events[event]
                try require(expected.0 == chunk.0, "Final flag changed"); var decoded = Data()
                for offset in stride(from: 0, to: chunk.1.count, by: 65536) {
                    try decoder.append(chunk.1.subdata(in: offset..<min(offset + 65536, chunk.1.count)))
                    decoded.append(try drain(decoder, maximum: 32768, retained: &retained, signature: &signature))
                }
                try require(decoded == expected.1 && decoder.ended == expected.0, "Event bytes/footer state changed")
                originals.append(expected.1); wire.append(chunk.1); events += 1
            }
            try decoder.finish(); try pointers(decoder); try retainedExact(retained, originals)
            try require(try RemoteGzipDecoder.complete(wire) == originals, "Complete decode changed bytes")
            rows.append(["name": group.name, "events": group.events.count, "bytes": originals.count, "reads": retained.count, "signature": String(signature), "state": state(decoder)])
        }
        var fragmented: [[String: Any]] = []
        let inputs = [Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 17) }), Data(String(repeating: "\u{1b}[32m한글🙂 e\u{301}\u{1b}[0m\n", count: 90).utf8)]
        for (index, input) in inputs.enumerated() { let wire = try compressed(input)
            for receive in [1, 7, 257, 65536] { for maximum in [1, 17, 4096, 32768] { var row = try decode(wire, expected: input, receive: receive, maximum: maximum); row["input"] = index; fragmented.append(row) } }
        }
        for (index, input) in [Data(repeating: 0x78, count: 131073), Data((0..<131073).map { UInt8(truncatingIfNeeded: $0 &* 31) })].enumerated() { let wire = try compressed(input)
            for receive in [257, 65536] { for maximum in [17, 4096, 32768] { var row = try decode(wire, expected: input, receive: receive, maximum: maximum); row["input"] = index + 2; fragmented.append(row) } }
        }
        try require(events == 527 && fragmented.count == 44, "Coverage count changed")
        try Base.emit(["passed": true, "actualCompiledCore": true, "groups": corpus.count, "events": events, "rows": rows, "fragmentedCases": fragmented, "guards": try guards(), "retainedOutputsChecked": true, "pointerCleanupChecked": true, "originalTerminalActions": 0, "realPowerCommands": 0])
    }
    static func memory(_ level: Int32, _ count: Int) throws {
        try require((0...64).contains(count), "Invalid live decoder count")
        let original = Data("event: alive\ndata: {\"streamID\":\"fixture\",\"revision\":\"fixed\"}\n\n".utf8), wire = try compressed(original, level: level, final: false)
        func ready() throws -> RemoteGzipDecoder {
            let value = try RemoteGzipDecoder(); try value.append(wire); var output = Data()
            while !value.needsInput && !value.ended { output.append(try value.read()) }
            try require(output == original && !value.ended, "Idle decoder fixture not drained"); try pointers(value); return value
        }
        for _ in 0..<8 { try autoreleasepool { _ = try ready() } }
        var values: [RemoteGzipDecoder] = []; values.reserveCapacity(count)
        let before = Base.heap(), rssBefore = Base.resident()
        for _ in 0..<count { values.append(try ready()) }
        let live = withExtendedLifetime(values) { Base.heap() }, rssLive = withExtendedLifetime(values) { Base.resident() }
        for value in values { try pointers(value) }; values.removeAll(keepingCapacity: false); let after = Base.heap()
        try require(live >= before && (count == 0 || live - before > count * 20000), "Heap metric does not cover decoder state")
        try Base.emit(["passed": true, "actualCompiledCore": true, "level": level, "count": count, "beforeHeap": before, "liveHeap": live, "retainedHeap": live - before, "afterReleaseHeap": after, "afterReleaseGrowth": after - before, "rssBefore": rssBefore, "rssLive": rssLive, "encodedBytes": count * wire.count, "pointerCleanupChecked": true, "memoryScope": "Live malloc heap while drained decoders wait for input; RSS diagnostic only."])
    }
    static func stack() throws {
        let box = Base.ThreadResult(), done = DispatchSemaphore(value: 0), thread = Thread {
            defer { done.signal() }
            do {
                let size = Int(pthread_get_stacksize_np(pthread_self())); try require(size <= 256 * 1024, "Limited stack was not applied")
                let input = Data((0..<131073).map { UInt8(truncatingIfNeeded: $0 &* 17) }), wire = try compressed(input)
                _ = try decode(wire, expected: input, receive: 65536, maximum: 32768)
                box.set(.success(["requestedStackBytes": 128 * 1024, "actualStackBytes": size, "bytes": input.count]))
            } catch { box.set(.failure(error)) }
        }
        thread.stackSize = 128 * 1024; thread.start(); try require(done.wait(timeout: .now() + 30) == .success, "Limited decoder stack timed out")
        try Base.emit(["passed": true, "actualCompiledCore": true, "limitedStack": try box.get(), "pointerCleanupChecked": true])
    }
    final class Workload {
        let source: Base.Workload, decoder: RemoteGzipDecoder
        init(_ source: Base.Workload) throws { self.source = source; decoder = try RemoteGzipDecoder() }
        func prepare(_ count: Int) throws -> ([Data], Int) {
            var values: [Data] = []; values.reserveCapacity(count); var bytes = 0
            for _ in 0..<count { let input = source.frames[source.index % source.frames.count]; source.index += 1; values.append(try source.encoder.encode(input)); bytes += input.count }
            return (values, bytes)
        }
    }
    @inline(never) static func measure(_ value: Workload, _ frames: [Data]) throws -> (UInt64, Int, Int) {
        var checksum: UInt64 = 0, bytes = 0, reads = 0
        for frame in frames {
            try value.decoder.append(frame)
            while !value.decoder.needsInput && !value.decoder.ended {
                let chunk = try value.decoder.read(); bytes += chunk.count; reads += 1
                checksum = checksum &* 1099511628211 ^ UInt64(chunk.count) ^ UInt64(chunk.first ?? 0) ^ UInt64(chunk.last ?? 0)
            }
        }
        try pointers(value.decoder); return (checksum, bytes, reads)
    }
    static func bench() throws {
        let values = try Base.workloads().mapValues { try Workload($0) }
        for value in values.values { let frames = try value.prepare(32); _ = try measure(value, frames.0) }
        try Base.emit(["ready": true, "actualCompiledCore": true, "pointerCleanupChecked": true, "compressedFramesPreparedOutsideWindow": true, "originalTerminalActions": 0, "realPowerCommands": 0])
        while let line = readLine() {
            let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]; if request["command"] as? String == "stop" { break }
            let mode = request["mode"] as! String, count = request["iterations"] as! Int; guard let value = values[mode] else { throw Base.Failure.invalid("Unknown decoder workload") }
            let frames = try value.prepare(count), compressedBytes = frames.0.reduce(0) { $0 + $1.count }, before = try Base.metrics(), start = ProcessInfo.processInfo.systemUptime
            let result = try autoreleasepool { try measure(value, frames.0) }, wall = ProcessInfo.processInfo.systemUptime - start, after = try Base.metrics()
            try require(result.1 == frames.1, "Measured decode lost bytes")
            try Base.emit(["id": request["id"]!, "mode": mode, "iterations": count, "checksum": String(result.0), "compressedBytes": compressedBytes, "decodedBytes": result.1, "decodeReads": result.2, "before": before, "after": after, "wall": wall])
        }
    }
    static func main() throws {
        let args = CommandLine.arguments
        switch args[1] {
        case "cases": try cases(args[2], args[3])
        case "memory": try memory(Int32(args[2])!, Int(args[3])!)
        case "memory-batch":
            let pair = Int(args[2])!, levels = pair.isMultiple(of: 2) ? [1, 6] : [6, 1], counts = pair.isMultiple(of: 2) ? [0, 1, 8, 32, 64] : [64, 32, 8, 1, 0]
            for level in levels { for count in counts { try memory(Int32(level), count) } }
        case "stack": try stack()
        case "bench": try bench()
        default: throw Base.Failure.invalid("Unknown decoder check command")
        }
    }
}
