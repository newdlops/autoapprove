import Foundation
import CoreFoundation
import Darwin
import CryptoKit

@main struct ScreenMatchCheck {
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "ScreenMatchCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func foreign(_ units: [UniChar]) -> String {
        let value = CFStringCreateWithCharacters(kCFAllocatorDefault, units, units.count)!
        return unsafeBitCast(value, to: NSString.self) as String
    }
    static func foreign(_ text: String) -> String { foreign(Array(text.utf16)) }
    static func cocoa(_ text: String) -> String { NSAppleEventDescriptor(string: text).stringValue! }
    static func native(_ text: String) -> String { String(decoding: Array(text.utf8), as: UTF8.self) }
    static func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    @inline(never) static func match(_ previous: ScreenMatchProbe, _ current: String, _ agent: AgentKind = .codex) -> Bool {
        previous.matches(current, agent: agent)
    }
    static func correctness() throws -> (Int, String) {
        let prefix = "Synthetic frame 한글 👨‍👩‍👧‍👦: "
        let examples: [(String, String, Bool)] = [
            ("", "", true), ("same", "same", true), ("lower", "LOWER", false),
            ("é", "e\u{301}", false), ("가", "\u{1100}\u{1161}", false),
            ("K", "K", false), ("Å", "A\u{30A}", false), ("Ａ", "A", false),
            ("👩🏽‍💻", "👩‍💻", false), ("♥", "♥️", false),
            ("x\u{0000}a", "x\u{0000}b", false), ("x\u{0000}", "x", false),
            ("line\n", "line\r\n", false), ("line\n", "line\u{2028}", false),
            (#"\u{4}"#, "\u{0004}", false), (#"\n"#, "\n", false),
            ("\u{001B}[31mtext", "\u{001B}[32mtext", false),
            (" ", "\u{00A0}", false), ("", "\u{200B}", false),
            ("quoted \\\" text", "quoted \\\" text", true)
        ]
        var cases = 0, digest = SHA256()
        let stores: [(String) -> String] = [native, foreign, cocoa]
        for prefix in ["", prefix] { for suffix in ["", String(repeating: " unchanged footer 🙂", count: 16)] { for (left, right, expected) in examples {
            for lhsStore in stores { for rhsStore in stores {
                for agent in AgentKind.allCases {
                    let previous = ScreenMatchProbe(raw: lhsStore(prefix + left + suffix), agent: agent)
                    let input = rhsStore(prefix + right + suffix)
                    for currentAgent in AgentKind.allCases {
                        let actual = match(previous, input, currentAgent)
                        try check(actual == (expected && agent == currentAgent), "Literal bytes or agent identity changed at case \(cases)")
                        digest.update(data: Data([actual ? 1 : 0])); cases += 1
                    }
                }
            }}
        }}}
        // Actual foreign UTF-16 strings can contain unpaired surrogates. The contract
        // remains the existing UTF-8 projection, including the runtime's error repair.
        let units: [UniChar] = [0, 0xA, 0x61, 0x301, 0xD7FF, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000, 0xFFFD, 0xFFFF]
        let variants: [[UniChar]] = [[]] + units.map { [$0] } + units.flatMap { a in units.map { b in [a, b] } }
        for suffix in ["", String(repeating: " unchanged footer 🙂", count: 16)] {
            let padded = variants.map { foreign(Array(prefix.utf16) + $0 + Array(suffix.utf16)) }
            let bytes = padded.map { Data($0.utf8) }
            let repaired = bytes.map { String(decoding: $0, as: UTF8.self) }
            for (i, left) in padded.enumerated() { for (j, right) in padded.enumerated() {
                for (previous, current) in [(left, right), (left, repaired[j]), (repaired[i], right)] {
                    let actual = match(ScreenMatchProbe(raw: previous, agent: .codex), current)
                    try check(actual == (bytes[i] == bytes[j]), "Foreign UTF-16 projection changed at \(i)/\(j)")
                    digest.update(data: Data([actual ? 1 : 0])); cases += 1
                }
            }}
        }
        // Exercise paired and unpaired surrogates on either side of every
        // bulk-read boundary, with an unchanged footer beyond the fast suffix.
        let boundaryUnits: [[UniChar]] = [[], [0xd800], [0xdfff], [0xfffd], [0xd800, 0xdc00],
            [0xdbff, 0xdfff], [0xd800, 0xd800], [0xdc00, 0xd800], [0xd800, 0x61], [0x61, 0xdfff]]
        for offset in [0, 1, 510, 511, 512, 513, 1022, 1023, 1024] {
            let before = Array(String(repeating: "x", count: offset).utf16)
            let after = Array(String(repeating: " unchanged footer 🙂", count: 16).utf16)
            let values = boundaryUnits.map { foreign(before + $0 + after) }
            let bytes = values.map { Data($0.utf8) }
            let repaired = bytes.map { String(decoding: $0, as: UTF8.self) }
            for (i, left) in values.enumerated() { for (j, right) in values.enumerated() {
                for (previous, current) in [(left, right), (left, repaired[j]), (repaired[i], right)] {
                    let actual = match(ScreenMatchProbe(raw: previous, agent: .codex), current)
                    try check(actual == (bytes[i] == bytes[j]), "UTF-16 boundary changed at \(offset)/\(i)/\(j)")
                    digest.update(data: Data([actual ? 1 : 0])); cases += 1
                }
            }}
        }
        // Tail rejection reads at most 129 UTF-16 units, including the
        // predecessor of the first compared unit. Preserve the independent
        // complete UTF-8 projection on both sides of every tail boundary.
        for tailLength in [0, 1, 2, 125, 126, 127, 128, 129, 130, 255, 256] {
            let before = Array(String(repeating: "stable body ", count: 70).utf16)
            let after = Array(String(repeating: "x", count: tailLength).utf16)
            let values = boundaryUnits.map { foreign(before + $0 + after) }
            let bytes = values.map { Data($0.utf8) }
            let repaired = bytes.map { String(decoding: $0, as: UTF8.self) }
            for (i, left) in values.enumerated() { for (j, right) in values.enumerated() {
                for (previous, current) in [(left, right), (left, repaired[j]), (repaired[i], right)] {
                    let actual = match(ScreenMatchProbe(raw: previous, agent: .codex), current)
                    try check(actual == (bytes[i] == bytes[j]), "Tail repair changed at \(tailLength)/\(i)/\(j)")
                    digest.update(data: Data([actual ? 1 : 0])); cases += 1
                }
            }}
        }
        try check(!ScreenTextEquality.identical(nil, ""), "A missing observation cannot reuse analysis")
        return (cases, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func run() throws {
        let (cases, digest) = try correctness()
        let rows = ["Synthetic compiler output /fixture/path.swift: checked step 1234 and preserved original source.\n",
                    "Synthetic output 한글 👩🏽‍💻 e\u{301} preserved exact bytes and the original source.\n"]
        let representations: [(String, (String) -> String, (String) -> String)] = [
            ("native", native, native), ("cocoa", cocoa, cocoa), ("foreign", foreign, foreign),
            ("native-cocoa", native, cocoa), ("cocoa-native", cocoa, native)
        ]
        var workloads: [[String: Any]] = [], checksum = 0
        let rounds = 128
        for (pattern, row) in rows.enumerated() { for lines in [24, 768] {
            let body = String(repeating: row, count: lines) + "› synthetic draft\n? for shortcuts"
            for (storage, lhsStore, rhsStore) in representations {
                for change in ["none", "tail", "body"] {
                    let changed = change != "none"
                    let previous = ScreenMatchProbe(raw: lhsStore(body), agent: .codex)
                    var next = body
                    if change == "tail" { next = String(body.dropLast()) + "!" }
                    else if change == "body" {
                        let middle = next.index(next.startIndex, offsetBy: next.count / 2)
                        next.replaceSubrange(middle...middle, with: "!")
                    }
                    let input = rhsStore(next)
                    var trials: [[String: Double]] = []
                    for _ in 0..<3 { autoreleasepool {
                        let startCPU = cpu(), startWall = ProcessInfo.processInfo.systemUptime
                        for _ in 0..<rounds { checksum += match(previous, input) ? 1 : 0 }
                        trials.append(["cpuSeconds": cpu() - startCPU, "wallSeconds": ProcessInfo.processInfo.systemUptime - startWall])
                    }}
                    try check(match(previous, input) == !changed, "Benchmark returned the wrong result")
                    workloads.append(["pattern": pattern == 0 ? "ascii" : "unicode", "lines": lines, "bytes": body.utf8.count,
                        "storage": storage, "lhsContiguousUTF8": previous.raw.isContiguousUTF8, "rhsContiguousUTF8": input.isContiguousUTF8,
                        "changed": changed, "change": change, "rounds": rounds, "trials": trials])
                }
            }
        }}
        let report: [String: Any] = ["correctnessCases": cases, "resultSHA256": digest, "workloads": workloads, "checksum": checksum,
            "inputPosts": 0, "scope": "Exact production ScreenTextEquality helper, actual Core AgentKind; fixed synthetic native, CF UTF-16 and local AppleEvent descriptor strings. No process event is sent. Not whole-app performance."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
    }
    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
