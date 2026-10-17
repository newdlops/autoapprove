import Foundation
import CoreFoundation
import CryptoKit
import Darwin

@main struct ScreenDisplayEqualityCheck {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "ScreenDisplayEqualityCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func foreign(_ units: [UniChar]) -> String {
        let text = CFStringCreateWithCharacters(kCFAllocatorDefault, units, units.count)!
        return unsafeBitCast(text, to: NSString.self) as String
    }
    static func foreign(_ text: String) -> String { foreign(Array(text.utf16)) }
    static func native(_ text: String) -> String { String(decoding: Array(text.utf8), as: UTF8.self) }
    static func cocoa(_ text: String) -> String { NSAppleEventDescriptor(string: text).stringValue! }
    @inline(never) static func equal(_ previous: String?, _ current: String) -> Bool {
        ScreenTextEquality.equal(previous, current)
    }
    static func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    static func correctness() throws -> (Int, String) {
        // This is display equality: canonical equivalents remain equal. The
        // detector/permission cache's distinct byte-equality contract is untouched.
        var examples: [(String, String, Bool)] = [
            ("", "", true), ("same", "same", true), ("same", "Same", false),
            ("é", "e\u{301}", true), ("가", "\u{1100}\u{1161}", true),
            ("K", "K", true), ("Å", "A\u{30A}", true), ("Ａ", "A", false),
            ("👩🏽‍💻", "👩‍💻", false), ("♥", "♥️", false),
            ("x\u{0000}a", "x\u{0000}b", false), ("x\u{0000}", "x", false),
            ("line\n", "line\r\n", false), ("line\n", "line\u{2028}", false),
            (#"\u{4}"#, "\u{0004}", false), (#"\n"#, "\n", false),
            ("\u{001B}[31mtext", "\u{001B}[32mtext", false),
            (" ", "\u{00A0}", false), ("", "\u{200B}", false),
            ("a\u{301}", "b\u{301}", false), ("S", "s", false),
            ("\u{0000}", "\u{0001}", false), ("K\u{301}", "K\u{301}", true)
        ]
        for length in [0, 1, 127, 128, 129, 256] {
            let shared = String(repeating: "🇰🇷👩🏽‍💻e\u{301}\r\n", count: length)
            examples += [("left" + shared, "right" + shared, false),
                         (shared + "last-a", shared + "last-b", false),
                         ("é" + shared + "가", "e\u{301}" + shared + "\u{1100}\u{1161}", true)]
        }
        // Exercise the actual 128-Character boundary: at 128 and 129 the
        // differing prefix falls outside the suffix and must reach full equality.
        for length in [127, 128, 129] {
            let shared = String(repeating: "z", count: length)
            examples += [("left-a" + shared, "left-b" + shared, false),
                         ("é" + shared, "e\u{301}" + shared, true)]
        }
        let cluster = "e" + String(repeating: "\u{301}", count: 1_024)
        examples += [("first" + cluster, "first" + cluster.precomposedStringWithCanonicalMapping, true),
                     ("first-a" + cluster, "first-b" + cluster, false)]
        let stores: [(String) -> String] = [native, foreign, cocoa]
        var cases = 0, digest = SHA256()
        func record(_ actual: Bool, expected: Bool) throws {
            try check(actual == expected, "Display equality changed at case \(cases)")
            digest.update(data: Data([actual ? 1 : 0])); cases += 1
        }
        for prefix in ["", "Synthetic display 한글 👨‍👩‍👧‍👦: "] {
            for (lhs, rhs, expected) in examples {
                for lhsStore in stores { for rhsStore in stores {
                    let left = lhsStore(prefix + lhs), right = rhsStore(prefix + rhs)
                    try record(equal(left, right), expected: expected)
                    try record(equal(right, left), expected: expected)
                }}
            }
        }
        for text in ["", "same", "한글 e\u{301} 🙂"] { for store in stores {
            try record(equal(nil, store(text)), expected: false)
        }}
        // Exercise the full production notification expression, including the
        // caller's negation and every independent metadata-change trigger.
        for lhsStore in stores { for rhsStore in stores {
            let raw = "Synthetic display e\u{301} 한글", previous = FrameChangeProbe(raw: lhsStore(raw),
                generation: "one", cursor: "position1", appearance: "style1", display: "display1")
            let current = rhsStore(raw)
            let frames: [(FrameChangeProbe?, String, String, String?, String?, String?, Bool)] = [
                (nil, current, "one", "position1", "style1", "display1", true),
                (previous, current, "one", "position1", "style1", "display1", false),
                (previous, rhsStore(raw.precomposedStringWithCanonicalMapping), "one", "position1", "style1", "display1", false),
                (previous, current + " changed", "one", "position1", "style1", "display1", true),
                (previous, current, "two", "position1", "style1", "display1", true),
                (previous, current, "one", "position2", "style1", "display1", true),
                (previous, current, "one", "position1", "style2", "display1", true),
                (previous, current, "one", "position1", "style1", "display2", true),
                (previous, current, "one", nil, "style1", "display1", true),
                (previous, current, "one", "position1", nil, "display1", true),
                (previous, current, "one", "position1", "style1", nil, true)
            ]
            for (before, text, generation, cursor, appearance, display, expected) in frames {
                try record(notificationChanged(before, raw: text, generation: generation, cursor: cursor,
                    appearance: appearance, display: display), expected: expected)
            }
        }}
        // The independent oracle first repairs the UTF-8 projection into a native
        // string and then compares NFC bytes, rather than using the tested helper.
        let units: [UniChar] = [0, 0xA, 0xD, 0x61, 0x301, 0xE1, 0x1100, 0x1161, 0xAC00, 0xD800, 0xDC00, 0xFFFD]
        let variants: [[UniChar]] = [[]] + units.map { [$0] } + units.flatMap { a in units.map { b in [a, b] } }
        let strings = variants.map { foreign(Array("Synthetic display 한글: ".utf16) + $0) }
        let repaired = strings.map(native)
        let normalized = repaired.map { Data($0.precomposedStringWithCanonicalMapping.utf8) }
        for (i, left) in strings.enumerated() { for (j, right) in strings.enumerated() {
            for (a, b) in [(left, right), (left, repaired[j]), (repaired[i], right)] {
                try record(equal(a, b), expected: normalized[i] == normalized[j])
            }
        }}
        return (cases, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func run() throws {
        let (cases, digest) = try correctness()
        let rows = ["Synthetic normalized output 한글 👩🏽‍💻 café preserved the original source.\n",
                    "Synthetic decomposed output \u{1100}\u{1161} 👩🏽‍💻 cafe\u{301} preserved the original source.\n"]
        let stores: [(String, (String) -> String, (String) -> String)] = [
            ("native", native, native), ("cocoa", cocoa, cocoa), ("foreign", foreign, foreign),
            ("native-cocoa", native, cocoa), ("cocoa-native", cocoa, native)
        ]
        var workloads: [[String: Any]] = [], checksum = 0
        let rounds = 64
        for (pattern, row) in rows.enumerated() { for lines in [24, 512] {
            let body = String(repeating: row, count: lines) + "› synthetic draft\n? for shortcuts"
            for (storage, lhsStore, rhsStore) in stores { for change in ["none", "tail", "head", "canonical"] {
                let changed = change == "tail" || change == "head"
                // Distinct inputs prevent an optimized pure comparison from being
                // hoisted out of a loop that repeatedly passes identical arguments.
                let pairs = (0..<rounds).map { index -> (String, String) in
                    let frame = body + "\nSynthetic frame \(index)"
                    switch change {
                    case "tail": return (lhsStore(frame), rhsStore(String(frame.dropLast()) + "!"))
                    case "head": return (lhsStore(frame), rhsStore("!" + String(frame.dropFirst())))
                    case "canonical": return (lhsStore(frame.precomposedStringWithCanonicalMapping), rhsStore(frame.decomposedStringWithCanonicalMapping))
                    default: return (lhsStore(frame), rhsStore(frame))
                    }
                }
                var trials: [[String: Double]] = []
                for _ in 0..<3 { autoreleasepool {
                    let beforeCPU = cpu(), beforeWall = ProcessInfo.processInfo.systemUptime
                    for pair in pairs { checksum += equal(pair.0, pair.1) ? 1 : 0 }
                    trials.append(["cpuSeconds": cpu() - beforeCPU, "wallSeconds": ProcessInfo.processInfo.systemUptime - beforeWall])
                }}
                try check(pairs.allSatisfy { equal($0.0, $0.1) == !changed }, "Benchmark returned the wrong result")
                workloads.append(["pattern": pattern == 0 ? "nfc" : "nfd", "lines": lines, "bytes": pairs[0].0.utf8.count,
                    "storage": storage, "lhsContiguousUTF8": pairs[0].0.isContiguousUTF8, "rhsContiguousUTF8": pairs[0].1.isContiguousUTF8,
                    "changed": changed, "change": change, "rounds": rounds, "trials": trials])
            }}
        }}
        let report: [String: Any] = ["correctnessCases": cases, "resultSHA256": digest, "workloads": workloads, "checksum": checksum,
            "inputPosts": 0, "scope": "Actual notification comparison or complete production helper; canonical display equality only. Synthetic native, CF UTF-16 and local AppleEvent descriptor strings. No event sent; not permission identity or whole-app performance."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
    }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
