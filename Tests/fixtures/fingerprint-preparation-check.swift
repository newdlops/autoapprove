import Foundation
import CryptoKit
import CoreFoundation

enum FingerprintProbeError: Error { case mismatch(Int) }
@main struct FingerprintPreparationCheck {
    static func native(_ units: [UInt16]) -> String { String(decoding: units, as: UTF16.self) }
    static func foreign(_ units: [UInt16]) -> String {
        units.withUnsafeBufferPointer { buffer in
            unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault, buffer.baseAddress, buffer.count)!, to: NSString.self) as String
        }
    }
    static func main() throws {
        precondition(CandidateFingerprint.fingerprint("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        precondition(CandidateFingerprint.fingerprint("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        precondition(CandidateFingerprint.fingerprint("é") != CandidateFingerprint.fingerprint("e\u{301}"))
        var values = ["", "abc", "\0\u{1b}[31mred\r\n", "한글 e\u{301} 👩🏽‍💻 🇰🇷", "\u{feff} leading BOM\n", "\r\n\n\r", "é", "e\u{301}"]
        for count in [0,1,2,3,15,16,17,4095,4096,16380,16381,16382,16383,16384,16385,32767,32768,32769,65535,65536,65537,1_048_576] {
            for tail in ["ascii", "한글\r\n", "e\u{301}👩🏽‍💻"] { values.append(String(repeating: "x", count: count) + tail) }
        }
        var cases = 0, foreignCases = 0, digest = SHA256()
        func check(_ text: String) throws {
            let storage = text.isContiguousUTF8, raw = Array(text.utf8)
            let baseline = BaselineFingerprint.fingerprint(text), candidate = CandidateFingerprint.fingerprint(text)
            guard baseline == candidate, text.utf8.elementsEqual(raw), text.isContiguousUTF8 == storage else { throw FingerprintProbeError.mismatch(cases) }
            if !storage { foreignCases += 1 }
            digest.update(data: Data(candidate.utf8)); cases += 1
        }
        for value in values {
            try autoreleasepool {
                try check(value)
                try check(NSAppleEventDescriptor(string: value).stringValue!)
                try check(foreign(Array(value.utf16)))
            }
        }
        for count in [0,1,2,4095,4096,16383,16384,16385] {
            for ending: [UInt16] in [[0xd800],[0xdc00],[0xd800,0xd800,0xdc00],[0xdc00,0xd800],[0xd800,10,0xdc00],[0xd800,0xdc00],[0xffff,0xfffd,0,27]] {
                let units = Array(repeating: UInt16(120), count: count) + ending + [13,10,0xac00]
                try autoreleasepool { try check(native(units)); try check(foreign(units)) }
            }
        }
        var random: UInt64 = 0x169f1a9e
        for bank in 0..<256 {
            var units: [UInt16] = []
            for _ in 0..<(32 + bank * 3) { random = random &* 6364136223846793005 &+ 1442695040888963407; units.append(UInt16(truncatingIfNeeded: random >> 24)) }
            try autoreleasepool { try check(native(units)); try check(foreign(units)) }
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["matched": true, "cases": cases, "foreignCases": foreignCases,
            "digest": digest.finalize().map { String(format: "%02x", $0) }.joined(),
            "originalInputs": 0, "captures": 0, "listeners": 0], options: [.sortedKeys]), as: UTF8.self))
    }
}
