import Foundation
import CoreFoundation
import CryptoKit
import AutoApproveCore

/// Complete public detector output. Link once with each Core version and compare
/// the sorted JSON digests; all screens are generated locally, with no input.
@main struct CapacityStopCorpus {
    static func foreign(_ units: [UniChar]) -> String {
        let value = CFStringCreateWithCharacters(kCFAllocatorDefault, units, units.count)!
        return unsafeBitCast(value, to: NSString.self) as String
    }
    static func foreign(_ text: String) -> String { foreign(Array(text.utf16)) }
    static func native(_ text: String) -> String { String(decoding: Array(text.utf8), as: UTF8.self) }
    static func cocoa(_ text: String) -> String { NSAppleEventDescriptor(string: text).stringValue! }
    static func main() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var hash = SHA256(), cases = 0, detected = 0, counts = [String: Int]()
        func observe(_ screen: String, agent: AgentKind) throws {
            let result = CodexCapacityStop.detect(screen, agent: agent)
            hash.update(data: Data("\(cases):\(agent.rawValue):".utf8))
            if let result {
                hash.update(data: try encoder.encode(result)); detected += 1
                counts[result.kind.rawValue, default: 0] += 1
            } else { hash.update(data: Data("null".utf8)) }
            hash.update(data: Data([10])); cases += 1
        }
        let cells = [
            "Completed synthetic result /fixture/source.swift",
            String(repeating: "Completed synthetic result 한글 e\u{301} 👩🏽‍💻\n", count: 160),
            "■ Selected model is at capacity. Please try a different model.",
            "■Selected model is at ca\npacity.",
            "■ stream disconnected before completion: network error",
            "■ stream disconnected before completion: 403 unauthorized",
            "■ 402 billing_error", "■ 503 overloaded", "■ A new provider wording",
            "API Error: Connection error.", "⎿ API Error: 503 overloaded",
            "Error: 403 unauthorized", "⎿ Error: 402 billing_error",
            "Note: ■ Selected model is at capacity.",
            "■ network error › user draft", "■ ```network error```"
        ]
        let footers = ["? for shortcuts", "? for shortcuts · Goal stalled (/goal resume)",
            "? for shortcuts · Goal blocked (/goal resume)", "? for shortcuts · Goal paused (/goal resume)",
            "? for shortcuts · Goal achieved (1h)", "? for shortcuts · Vim: Normal"]
        let stores: [(String) -> String] = [native, foreign, cocoa]
        for agent in [AgentKind.codex, .claude, .shell] {
            let glyph = agent == .claude ? "❯" : "›"
            let composer = agent == .claude ? glyph : glyph + " Ask Codex to do anything"
            for cell in cells { for prefix in ["", "\t", "\u{3000}", " \u{301}"] { for footer in footers {
                for state in [0, 1, 2] {
                    let heading = "Synthetic task\n\n" + prefix + cell + "\n\n"
                    let body = state == 0 ? composer : state == 1 ? glyph + " private synthetic draft" : "Working · esc to interrupt\n" + composer
                    let screen = heading + body + "\n\n" + footer
                    for store in stores { try observe(store(screen), agent: agent) }
                }
            }}}
        }
        let broken: [[UniChar]] = [[0xd800], [0xdc00], [0xd800, 0xd800], [0xd800, 0xdc00], [0xfffd]]
        for units in broken { for prefix in ["", "■ ", "API Error:"] { for agent in [AgentKind.codex, .claude, .shell] {
            let suffix = agent == .claude ? "\n\n❯\n\n? for shortcuts" : "\n\n› Ask Codex to do anything\n\n? for shortcuts · Goal blocked (/goal resume)"
            try observe(foreign(Array(prefix.utf16) + units + Array(("network error 403" + suffix).utf16)), agent: agent)
        }}}
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["cases": cases, "detected": detected,
            "kinds": counts, "resultSHA256": digest, "originalInputs": 0, "captures": 0, "listeners": 0], options: .sortedKeys), as: UTF8.self))
    }
}
