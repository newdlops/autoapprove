import Foundation
import CryptoKit
import AutoApproveCore

extension ApprovalTests {
    func testCompleteSuffixReuseKeepsExactPermissionBoundaries() throws {
        for agent in [AgentKind.codex, .claude] {
            for count in [0,1,292,293,294,295,296,297,298,299,300,301,384,4096] {
                for payload in ["fixture ASCII", "e\u{301} 한글 👩🏽‍💻 \\\"\\u{4}\\\""] {
                    let history = String(repeating: "Old normalized row: " + payload + "\r\n", count: count)
                    let heading = agent == .codex ? "Would you like to run the following command?" : "Do you want to proceed?"
                    let context = heading + "\n  $ echo " + payload
                    let body = context + "\n› 1. Yes\n  2. No\nEsc to cancel"
                    let raw = history + body
                    for text in [raw, NSAppleEventDescriptor(string: raw).stringValue!] {
                        let bytes = Array(text.utf8), storage = text.isContiguousUTF8
                        guard let prompt = PromptDetector.detect(text, agent: agent) else {
                            throw AppError.message("Missing original permission at the complete-suffix boundary")
                        }
                        let expectedDialog = PromptDetector.normalizedLines(agent == .codex ? body : text).joined(separator: "\n")
                        let expectedContext = PromptDetector.normalizedLines(agent == .codex ? context : history + context).joined(separator: "\n")
                        try expect(prompt.dialog.utf8.elementsEqual(expectedDialog.utf8), "Keep the complete original dialog and earlier Claude history")
                        try expectEqual(prompt.requestIdentity, PromptDetector.fingerprint(expectedContext.filter { !$0.isWhitespace }))
                        try expectEqual(prompt.fingerprint, PromptDetector.fingerprint(text))
                        try expectEqual(prompt.hasRequestBoundary, agent == .codex)
                        try expectEqual(prompt.answer, "1")
                        try expect(text.utf8.elementsEqual(bytes) && text.isContiguousUTF8 == storage)
                    }
                    for fence in ["```\n", "  ```\n", "\u{1fef}\u{1fef}\u{1fef}\n"] {
                        try expect(PromptDetector.detect(fence + raw, agent: agent) == nil, "An earlier open fence is preserved across300 rows")
                    }
                }
            }
        }
    }

    func testFingerprintKeepsRepairedCocoaAndChunkBoundaries() throws {
        for count in [0,1,4095,4096,16380,16383,16384,16385,32767,65535] {
            for ending: [UInt16] in [[0xd800],[0xdc00],[0xd800,0xd800,0xdc00],[0xdc00,0xd800],[0xd800,10,0xdc00],[0xd800,0xdc00],[0xffff,0xfffd,0,27]] {
                let units = Array(repeating: UInt16(120), count: count) + ending + [13,10,0xac00]
                let cocoa = units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) as String }
                let native = String(decoding: units, as: UTF16.self)
                for text in [native, cocoa] {
                    let storage = text.isContiguousUTF8, bytes = Array(text.utf8)
                    let original = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
                    try expectEqual(PromptDetector.fingerprint(text), original, "Saved identities use exact repaired UTF-8, without normalization")
                    try expect(text.utf8.elementsEqual(bytes) && text.isContiguousUTF8 == storage)
                }
            }
        }
        let large = NSAppleEventDescriptor(string: String(repeating: "원문 e\u{301} 👩🏽‍💻\r\n", count: 65536)).stringValue!
        try expect(!large.isContiguousUTF8)
        let original = SHA256.hash(data: Data(large.utf8)).map { String(format: "%02x", $0) }.joined()
        try expectEqual(PromptDetector.fingerprint(large), original)
    }

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

    func testRequestIdentityKeepsCharacterWhitespaceAndExactDialog() throws {
        let payloads = ["", " \t\u{000B}\u{000C}\r\n", "\u{0085}\u{00A0}\u{1680}",
            "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}",
            "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}", " \u{301}", "\t\u{301}", " \u{200D}",
            "\t\u{200D}\n", "\r\u{301}\n", "\u{0000}\u{200B}\u{2060}\u{FEFF}",
            "e\u{301} é 한글 👩🏽‍💻 A\u{FE0F}"]
        for agent in [AgentKind.codex, .claude] {
            for payload in payloads {
                let context = agent == .codex
                    ? "Would you like to run the following command?\n  $ echo prefix\(payload)suffix"
                    : "Bash command\n  echo prefix\(payload)suffix\nDo you want to proceed?"
                let screen = context + "\n\n› 1. Yes\n  2. No\n\nEnter to confirm or esc to cancel"
                // Reference the previous Character filter. Scalar filtering would drop
                // whitespace from combined graphemes and change saved reservations.
                let oldIdentity = PromptDetector.fingerprint(PromptDetector.normalizedLines(context).joined(separator: "\n").filter { !$0.isWhitespace })
                for frame in [screen, screen.decomposedStringWithCanonicalMapping,
                              NSAppleEventDescriptor(string: screen).stringValue!] {
                    guard let prompt = PromptDetector.detect(frame, agent: agent) else {
                        throw AppError.message("Missing \(agent) permission in whitespace identity fixture")
                    }
                    try expectEqual(prompt.requestIdentity, oldIdentity, "Existing approval reservations must keep their identity")
                    try expectEqual(Data(prompt.dialog.utf8), Data(PromptDetector.normalizedLines(frame).joined(separator: "\n").utf8),
                        "Final validation must retain the complete normalized dialog bytes")
                    try expectEqual(prompt.fingerprint, PromptDetector.fingerprint(frame), "The full source fingerprint is unchanged")
                    try expectEqual(prompt.answer, "1")
                }
            }
        }
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
