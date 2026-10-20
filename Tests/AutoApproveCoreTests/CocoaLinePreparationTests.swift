import Foundation
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif

extension ApprovalTests {
    func testCocoaNormalizationRetainsUnicodeBoundariesAndCurrentDialogs() throws {
        let padding = String(repeating: "x", count: 4100) + "\n"
        let histories = [String(repeating: "é\r\n", count: 63), String(repeating: "é\r\n", count: 64),
            String(repeating: "é\r\n", count: 65), String(repeating: "e\u{301}", count: 1365) + "\né\né",
            String(repeating: "e\u{301}", count: 1366) + "\né\né", "é\n\né\ré\r\né\n",
            "é\né\nASCII\né\né\n", " \u{301}\n\u{2028}\u{2029}\né\n\u{0000}é\n"]
        for agent in [AgentKind.codex, .claude] {
            let panel = agent == .codex ? "Would you like to run the following command?\n  $ echo e\u{301}"
                : "Bash command\n  echo e\u{301}\nDo you want to proceed?"
            let body = panel + "\n› 1. Yes\n  2. No\nEsc to cancel"
            for history in histories {
                let cocoa = NSAppleEventDescriptor(string: padding + history + "\n" + body).stringValue!
                let original = Array(cocoa.utf8), storage = cocoa.isContiguousUTF8
                let native = String(decoding: original, as: UTF8.self)
                guard let expected = PromptDetector.detect(native, agent: agent),
                      let actual = PromptDetector.detect(cocoa, agent: agent) else {
                    throw AppError.message("Missing active permission at a Cocoa normalization boundary")
                }
                try expectEqual(actual, expected)
                try expect(actual.dialog.utf8.elementsEqual(expected.dialog.utf8))
                try expect(actual.summary.utf8.elementsEqual(expected.summary.utf8))
                try expectEqual(actual.fingerprint, PromptDetector.fingerprint(cocoa))
                let selectedNo = cocoa.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "› 2.")
                try expectNil(PromptDetector.detect(NSAppleEventDescriptor(string: selectedNo).stringValue!, agent: agent))
                try expect(cocoa.utf8.elementsEqual(original) && cocoa.isContiguousUTF8 == storage)
                let quoted = NSAppleEventDescriptor(string: padding + "```text\n" + history + "\n" + body).stringValue!
                try expect(PromptDetector.detect(quoted, agent: agent) == nil, "Normalized code fences still exclude quoted permissions")
            }
        }
    }

    func testCocoaLinePreparationPreservesPromptIdentityAndQuotedQuestions() throws {
        for agent: AgentKind in [.codex, .claude] {
            let heading = agent == .codex ? "Would you like to run the following command?" : "Do you want to proceed?"
            for separator in ["\n", "\r", "\r\n"] {
                let history = String(repeating: "old e\u{301} 한글 👩🏽‍💻" + separator, count: 200)
                let body = [heading, "$ echo fixture", "❯ 1. Yes", "  2. No", "Esc to cancel"].joined(separator: separator)
                let cocoa = NSAppleEventDescriptor(string: history + body).stringValue!
                let bytes = Array(cocoa.utf8), storage = cocoa.isContiguousUTF8
                let native = String(decoding: bytes, as: UTF8.self)
                let before = PromptDetector.detect(native, agent: agent)
                let after = PromptDetector.detect(cocoa, agent: agent)
                try expectNotNil(before); try expectNotNil(after)
                try expectEqual(after, before)
                try expect(after!.dialog.utf8.elementsEqual(before!.dialog.utf8), "Dialog bytes must remain exact")
                try expect(after!.summary.utf8.elementsEqual(before!.summary.utf8), "Context normalization must remain exact")
                try expectEqual(after!.fingerprint, PromptDetector.fingerprint(cocoa), "Validation fingerprints use the original source")
                try expect(cocoa.utf8.elementsEqual(bytes), "Parsing cannot mutate original input")
                try expectEqual(cocoa.isContiguousUTF8, storage)
            }
            let menu = "환경 e\u{301}?\n❯ 1. 개발\n  2. 운영\nEnter to select"
            let cocoa = NSAppleEventDescriptor(string: menu).stringValue!
            try expectEqual(QuestionDetector.detect(cocoa, agent: agent)?.phase, .input)
            try expectNil(PromptDetector.detect(cocoa, agent: agent))
            for opening in ["```text\n", "```text\n"] {
                let quoted = NSAppleEventDescriptor(string: opening + String(repeating: "old 한글 output\n", count: 400) + menu).stringValue!
                try expectNil(QuestionDetector.detect(quoted, agent: agent))
                try expectNil(PromptDetector.detect(quoted, agent: agent))
            }
        }
    }

#if DEBUG
    func testCocoaNormalizationKeepsExactRowsAndSourceBudget() throws {
        let endings: [[UInt16]] = [[0xd83d, 0xde00, 13, 10, 0x65, 0x301],
            [0xd800, 0x61, 10, 0xdc00], [0xdc00, 0xd800], [0xdc00, 0xdc00, 0xd800]]
        let prefix = String(repeating: "x", count: 4100) + "\n" + String(repeating: "é\r\n", count: 65)
        for length in [0, 4094, 4095, 4096, 8191] {
            for ending in endings {
                let units = Array(prefix.utf16) + [UInt16](repeating: 120, count: length) + ending + Array("\né\ré\n \t".utf16)
                let cocoa = units.withUnsafeBufferPointer { String(NSString(characters: $0.baseAddress!, length: $0.count)) }
                let repaired = String(decoding: units, as: UTF16.self)
                let expected = PromptDetector.normalizedLines(repaired)
                let actual = PromptDetector.normalizedLinesAndUTF8ByteCount(cocoa)
                try expectEqual(actual.byteCount, repaired.utf8.count, "Budgets count the original source before NFC")
                try expectEqual(actual.lines.count, expected.count)
                try expect(zip(actual.lines, expected).allSatisfy { $0.utf8.elementsEqual($1.utf8) })
                let lines = DetectionLines(cocoa)
                _ = lines.normalizedSuffix(18)
                try expectEqual(lines.sourceByteCount, repaired.utf8.count)
            }
        }
    }

    func testCocoaLinePreparationPreservesUTF16ChunkBoundariesAndSourceBudget() throws {
        let endings: [[UInt16]] = [
            [0xd83d, 0xde00, 0x0d, 0x0a, 0x65, 0x301],
            [0x0d, 0x0a, 0x0d, 0x0a], [0xd800, 0x61, 0x0a, 0xdc00], [0xdc00, 0xd800]
        ]
        for padding in [0, 4094, 4095, 4096, 8191] {
            for ending in endings {
                let units = [UInt16](repeating: 0x78, count: padding) + ending
                let repaired = String(decoding: units, as: UTF16.self)
                let cocoa = units.withUnsafeBufferPointer { String(NSString(characters: $0.baseAddress!, length: $0.count)) }
                let original = Array(cocoa.utf8), storage = cocoa.isContiguousUTF8
                let actual = PromptDetector.normalizedLinesAndUTF8ByteCount(cocoa)
                let expected = PromptDetector.normalizedLines(repaired)
                try expectEqual(actual.byteCount, repaired.utf8.count)
                try expectEqual(actual.lines.count, expected.count)
                try expect(zip(actual.lines, expected).allSatisfy { $0.utf8.elementsEqual($1.utf8) })
                let lines = DetectionLines(cocoa)
                _ = lines.normalizedSuffix(18)
                try expectEqual(lines.sourceByteCount, repaired.utf8.count)
                if !storage { try expectNil(lines.normalizedSuffix(18).byteStarts) }
                try expect(cocoa.utf8.elementsEqual(original)); try expectEqual(cocoa.isContiguousUTF8, storage)
            }
        }
    }
#endif
}
