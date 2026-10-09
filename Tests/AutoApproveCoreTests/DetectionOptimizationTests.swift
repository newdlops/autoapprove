import Foundation
import CryptoKit
import AutoApproveCore

extension ApprovalTests {
    func testFingerprintEncodingKeepsExistingReceipts() throws {
        try expectEqual(PromptDetector.fingerprint(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        try expectEqual(PromptDetector.fingerprint("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for input in ["한글 😀\n\u{0000}\\u{4}", "é", "e\u{301}", String(repeating: "ordinary output\n", count: 10_000)] {
            // Persisted receipts used Foundation's formatter. Their byte identity must
            // survive the faster encoding, including unnormalized and embedded-NUL text.
            let previous = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            try expectEqual(PromptDetector.fingerprint(input), previous)
        }
        try expect(PromptDetector.fingerprint("é") != PromptDetector.fingerprint("e\u{301}"), "Raw input identities must not silently normalize Unicode")
    }

    func testOptionPrecheckKeepsUnicodeMenusAndRejectsOrdinaryOutput() throws {
        let history = String(repeating: "Completed synthetic step: ordinary output.\n", count: 1000)
        let spaces = [" ", "\t", "\u{000B}", "\u{000C}", "\u{0085}", "\u{00A0}", "\u{1680}", "\u{2000}", "\u{2007}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}"]
        for agent in [AgentKind.codex, .claude] {
            for cursor in ["›", "❯", "»", ">"] {
                for space in spaces {
                    let screen = history + "Which result?\n" + cursor + space + "1. First\n" + space + "2. Second\nEnter to select"
                    let request = QuestionDetector.detect(screen, agent: agent)
                    try expectEqual(request?.phase, .input, "Unicode spacing must keep the existing selected menu")
                    try expect(request?.summary.contains("Second") == true)
                    try expect(PromptDetector.detect(screen, agent: agent) == nil, "A choice question is never an approval")
                }
            }
            try expectEqual(QuestionDetector.detect(history + "Which result?\n\u{200B}› 1. First\n2. Second\nEnter to select", agent: agent)?.phase, .input, "Preserve Foundation's existing leading zero-width-space trimming")
            for text in ["ordinary output", "01. First", "100. First", "１. First", "›\u{FE0F} 1. First", "\u{2060}› 1. First"] {
                let screen = history + "Which result?\n" + text + "\n2. Second\nEnter to select"
                try expectNil(QuestionDetector.detect(screen, agent: agent))
            }
        }
    }
}
