import Foundation
import CoreFoundation
import CryptoKit

enum ProbeError: Error { case mismatch(String) }
@main struct FusedPreparationProbe {
    static var digest = SHA256(), cases = 0, foreignCases = 0
    static func equal(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a,b).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
    static func check(_ units: [UniChar], index: Int, count: Int, order: Int) throws {
        func text() -> String { unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault, units, units.count)!, to: NSString.self) as String }
        let a = BaselineLines(text()), b = CandidateLines(text())
        if !text().isContiguousUTF8 { foreignCases += 1 }
        if order == 1 { guard equal(a.raw,b.raw) else { throw ProbeError.mismatch("raw first") } }
        if order == 2 { guard a.sourceByteCount == b.sourceByteCount else { throw ProbeError.mismatch("bytes first") } }
        if order == 3 { guard equal(a.trimmed,b.trimmed) else { throw ProbeError.mismatch("trim first") } }
        let x = a.normalizedSuffix(count), y = b.normalizedSuffix(count)
        guard equal(x.rows,y.rows), x.normalizedLineOffset == y.normalizedLineOffset,
              a.sourceByteCount == b.sourceByteCount else { throw ProbeError.mismatch("suffix/offset/bytes case\(index) count\(count) order\(order)") }
        for row in [-1,0,x.rows.count/2,x.rows.count,x.rows.count+2] {
            guard a.hasOpenCodeFence(beforeSuffixRow:row,in:x) == b.hasOpenCodeFence(beforeSuffixRow:row,in:y) else {
                throw ProbeError.mismatch("fence case\(index) count\(count) row\(row)")
            }
        }
        guard equal(a.raw,b.raw), equal(a.trimmed,b.trimmed) else { throw ProbeError.mismatch("later raw/trim case\(index)") }
        digest.update(data: Data("\(index):\(count):\(order):\(a.sourceByteCount):\(x.normalizedLineOffset):".utf8))
        for row in x.rows { digest.update(data:Data(row.utf8)); digest.update(data:Data([0])) }
        cases += 1
    }
    static func whitespaceProof() throws -> Int {
        let set = CharacterSet.whitespaces
        var checked = 0
        for block in stride(from: 0, to: 0x110000, by: 4096) {
            try autoreleasepool {
                for value in block..<min(block+4096,0x110000) {
                    guard let scalar = Unicode.Scalar(value) else { continue }
                    let text = String(scalar), raw = set.contains(scalar)
                    let nfc = text.precomposedStringWithCanonicalMapping.unicodeScalars.allSatisfy { set.contains($0) }
                    let nfd = text.decomposedStringWithCanonicalMapping.unicodeScalars.allSatisfy { set.contains($0) }
                    guard raw == nfc && raw == nfd else { throw ProbeError.mismatch("whitespace NFC/NFD U+\(String(value,radix:16))") }
                    checked += 1
                }
            }
        }
        return checked
    }
    static func main() throws {
        let scalarProof = try whitespaceProof()
        var values = ["", "\n", "\r", "\r\n", " \t\n\u{2000}\u{2001}\n", "a\r\nb\rc\n", "한글 e\u{301} 👩🏽‍💻 🇰🇷\n› ",
            "```\nQuestion 1/2 (1 unanswered)\n› 1. One\n2. Two\n```\n", "```\nbody\n", "```\u{301}\nbody\n"]
        for count in [0,1,2,299,300,301,511,1024,4200] {
            for kind in ["ASCII ordinary row", "한글 e\u{301} 👩🏽‍💻", " \t\u{2000}"] {
                values.append(String(repeating:kind+"\n",count:count)+"end\n"+String(repeating:" \t\n",count:count))
                values.append("```\n"+String(repeating:kind+"\r\n",count:count)+"› 1. One\n2. Two\nEsc to cancel\n")
            }
        }
        for length in [4094,4095,4096,4097,8191,8192,8193] {
            values.append(String(repeating:"x",count:length)+"👩🏽‍💻\r\nnext\n"+String(repeating:"\u{2001}",count:length))
        }
        var banks = values.map { Array($0.utf16) }
        let fragments: [[UniChar]] = [[0xd800],[0xdc00],[0xd800,0xd800,0xdc00],[0xdc00,0xd800],[0xd800,10,0xdc00],[0xd800,0xdc00],[0xffff,0xfffd,0,27]]
        for prefix in [0,1,4095,4096,4097] { for fragment in fragments {
            banks.append(Array(repeating:UInt16(120),count:prefix)+fragment+[13,10]+Array("body\n \t\n".utf16))
        } }
        var random: UInt64 = 0x169c0c0a
        let alphabet: [UniChar] = [0,9,10,13,27,32,96,97,0x85,0xa0,0x300,0x301,0x1fef,0x2000,0x2001,0x200b,0x2028,0x2029,0x3000,0xac00,0xd800,0xdc00,0xdfff,0xfffd]
        for i in 0..<128 {
            var units: [UniChar] = []
            for _ in 0..<(64+i*5) { random = random &* 6364136223846793005 &+ 1442695040888963407; units.append(alphabet[Int((random>>32)%UInt64(alphabet.count))]) }
            banks.append(units)
        }
        for (index,units) in banks.enumerated() { for count in [-1,0,1,2,3,20,299,300,301,1000] { for order in 0..<4 {
            try autoreleasepool { try check(units,index:index,count:count,order:order) }
        } } }
        let history = String(repeating: "Completed synthetic step: retained original 한글 e\u{301} context and no input.\n", count: 1200)
        var extra: [[UniChar]] = []
        for opening in ["```", "```", "```\u{301}", "```", "  ```", "x```", "\u{feff}```", "`\u{300}``", "\u{301}```", "```\u{200d}"] {
            for closed in [false, true] {
                extra.append(Array((opening + "\n" + history + (closed ? "```\n" : "") + "Which result?\n› 1. One\n2. Two\nEnter to select").utf16))
            }
        }
        for value in UInt32(0)...UInt32(127) {
            let opening = String(Unicode.Scalar(value)!) + (value.isMultiple(of: 2) ? "\u{301}``" : "```")
            extra.append(Array((opening + "\n" + history + "Which result?\n› 1. One\n2. Two\nEnter to select").utf16))
        }
        for length in 65532...65539 {
            let tail = "\n한글 e\u{301}\nWhich result?\n› 1. One\n2. Two\nEnter to select"
            extra.append(Array((String(repeating: "x", count: length - tail.utf16.count) + tail).utf16))
        }
        for (index, units) in extra.enumerated() { for order in 0..<4 {
            try autoreleasepool { try check(units, index: banks.count + index, count: 300, order: order) }
        } }
        let checksum = digest.finalize().map { String(format:"%02x",$0) }.joined()
        print(String(decoding:try JSONSerialization.data(withJSONObject:["matched":true,"cases":cases,"foreignCases":foreignCases,"scalarNFCNFDProof":scalarProof,
            "banks":banks.count + extra.count,"digest":checksum,"originalInputs":0,"captures":0,"listeners":0],options:[.sortedKeys]),as:UTF8.self))
    }
}
