enum NormalizationOracle {
    static var cases = 0, foreign = 0, scalars = 0
    static func same(_ lhs: [String], _ rhs: [String], _ context: String) throws {
        guard lhs.count == rhs.count, zip(lhs, rhs).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else {
            throw ProbeError.mismatch("normalization exact bytes " + context)
        }
    }
    static func check(_ units: [UniChar], name: String) throws {
        let native = String(decoding: units, as: UTF16.self)
        let cocoa = unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault, units, units.count)!, to: NSString.self) as String
        for (kind, screen) in [("native", native), ("cocoa", cocoa)] {
            if !screen.isContiguousUTF8 { foreign += 1 }
            let expected = BaselineNormalize.normalizedLines(screen)
            try same(expected, CandidateNormalize.normalizedLines(screen), name + "/" + kind)
            let old = BaselineNormalize.normalizedLinesAndUTF8ByteCount(screen)
            let new = CandidateNormalize.normalizedLinesAndUTF8ByteCount(screen)
            try same(old.lines, new.lines, name + "/" + kind + "/bytecount rows")
            guard old.byteCount == new.byteCount else { throw ProbeError.mismatch("original byte count " + name) }
            FusedPreparationProbe.digest.update(data: Data("normalizer:\(name):\(kind):\(old.byteCount):".utf8))
            for row in new.lines { FusedPreparationProbe.digest.update(data: Data(row.utf8)); FusedPreparationProbe.digest.update(data: Data([0])) }
            cases += 2
        }
    }
    static func run() throws -> [String: Int] {
        // Both sides of the row threshold and the exact half-byte density gate.
        for count in [0,1,30,31,32,33,64] {
            let dense = String(repeating: "é\n", count: count)
            for asciiLength in [0,1,30,31,32,33,34,127,4095,65537] {
                try check(Array((dense + String(repeating: "x", count: asciiLength) + "\r\n\t \n").utf16), name: "density\(count)/\(asciiLength)")
            }
        }
        let endings = ["", "\n", "\r", "\r\n", "\n\r", "\r\r\n", "\n\r\n\r", "\u{2000}\t\r\n"]
        let fragments: [[UniChar]] = [[],[0xd800],[0xdc00],[0xd800,0xd800,0xdc00],[0xdc00,0xd800],
            [0xd800,13,10,0xdc00],[0xd800,0xdc00],[0xffff,0xfffd,0,27],Array("한글 e\u{301} 👩🏽‍💻\u{200d}\u{1fef}``\u{301}".utf16)]
        for padding in Array(0...17) + [4093,4094,4095,4096,4097,8191,8192,8193] {
            for (number, fragment) in fragments.enumerated() {
                let prefix = Array(repeating: UInt16(120), count: padding)
                for (endIndex, ending) in endings.enumerated() {
                    let row = prefix + fragment + Array((ending + "é\n").utf16)
                    var dense: [UniChar] = []
                    for _ in 0..<33 { dense += row }
                    dense += [13,10,32,9,10]
                    try autoreleasepool { try check(dense, name: "lanes\(padding)/\(number)/\(endIndex)") }
                }
            }
        }
        var random: UInt64 = 0xb169cafe
        let alphabet: [UniChar] = [0,9,10,13,27,32,96,97,0x85,0xa0,0x300,0x301,0x327,0x1fef,0x2000,0x2001,0x200b,0x2028,0x2029,0x3000,0xac00,0xd800,0xdc00,0xdfff,0xfffd]
        for index in 0..<128 {
            var units = Array(String(repeating: "한글 e\u{301}\n", count: 33).utf16)
            for _ in 0..<(256 + index * 7) {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                units.append(alphabet[Int((random >> 32) % UInt64(alphabet.count))])
            }
            try autoreleasepool { try check(units, name: "random\(index)") }
        }
        // Every valid scalar in two combining contexts, densely separated by
        // LF. This checks batch boundaries without one process per scalar.
        for block in stride(from: 0, to: 0x110000, by: 4096) {
            try autoreleasepool {
                var text = ""
                for value in block..<min(block + 4096,0x110000) {
                    guard let scalar = Unicode.Scalar(value) else { continue }
                    text.unicodeScalars.append(scalar); text += "\u{301}\n\u{327}"
                    text.unicodeScalars.append(scalar); text += "\u{300}\n"
                    scalars += 1
                }
                try check(Array(text.utf16), name: "scalars\(block)")
            }
        }
        guard scalars == 1112064, foreign > 0 else { throw ProbeError.mismatch("normalizer proof coverage") }
        return ["cases":cases,"foreign":foreign,"scalars":scalars]
    }
}
