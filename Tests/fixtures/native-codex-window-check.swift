import Foundation
import Darwin
import AutoApproveCore

@main struct NativeCodexWindowOracle {
    static var primitives = 0, frames = 0, foreign = 0, approvals = 0
    static var checksum: UInt64 = 1469598103934665603
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw AppError.message(message) }
    }
    static func mix(_ value: UInt64) { checksum = (checksum ^ value) &* 1099511628211 }
    static func primitive(_ text: String) throws {
        let expected = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces).first
        let initial = text.utf8.withContiguousStorageIfAvailable {
            CandidatePromptDetector.nativeASCIIRowInitial($0, start: 0, end: $0.count)
        }!
        if let initial, initial != 65, initial != 87 {
            try require(expected != "A" && expected != "W", "Rejected a possible heading: " + text.debugDescription)
        }
        let fenced = text + "\n"
        let actual = fenced.utf8.withContiguousStorageIfAvailable {
            CandidatePromptDetector.nativeCodexPrefixHasOpenFence($0, before: $0.count)
        }!
        let count = ReferencePromptDetector.normalizedLines(fenced)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
        try require(actual == (count % 2 == 1), "Changed normalized/trimmed fence: " + text.debugDescription)
        primitives += 1; mix(UInt64(initial ?? 255)); mix(actual ? 1 : 0)
    }
    static func frame(_ raw: String, agent: AgentKind = .codex) throws {
        for text in [raw, NSAppleEventDescriptor(string: raw).stringValue!] {
            let bytes = Array(text.utf8), storage = text.isContiguousUTF8
            if !storage { foreign += 1 }
            let before = try InteractivePreflightOracle.reference(text, agent: agent)
            let after = try InteractivePreflightOracle.candidate(text, agent: agent)
            try require(InteractivePreflightOracle.same(before, after), "Changed complete prompt/question/choice fields: " + text.prefix(100).debugDescription)
            let left = ReferenceDetectionLines(text), right = CandidateDetectionLines(text)
            try require(left.sourceByteCount == right.sourceByteCount, "Changed original byte budget")
            let a = left.normalizedSuffix(300), b = right.normalizedSuffix(300)
            try require(InteractivePreflightOracle.same(a.rows,b.rows) && a.byteStarts == b.byteStarts && a.normalizedLineOffset == b.normalizedLineOffset, "Changed shared suffix")
            try require(text.utf8.elementsEqual(bytes) && text.isContiguousUTF8 == storage, "Changed caller bytes/storage")
            if before[3] != "nil prompt" { approvals += 1 }
            for value in after { for byte in value.utf8 { mix(UInt64(byte)) } }
            frames += 1
        }
    }
    static func referenceFields(_ prompt: ReferenceApprovalPrompt?) -> [String] {
        guard let p = prompt else { return ["nil"] }
        return [p.summary,p.answer,p.fingerprint,p.dialog,p.requestIdentity,String(p.hasRequestBoundary),p.identity]
    }
    static func candidateFields(_ prompt: CandidateApprovalPrompt?) -> [String] {
        guard let p = prompt else { return ["nil"] }
        return [p.summary,p.answer,p.fingerprint,p.dialog,p.requestIdentity,String(p.hasRequestBoundary),p.identity]
    }
    static func main() throws {
        var scalarCount = 0
        for number in UInt32(0)...0x10ffff {
            guard let scalar = UnicodeScalar(number) else { continue }
            let s = String(scalar)
            for text in [s,s + "Would"," \t" + s + "Allow",s + "```"] { try primitive(text) }
            scalarCount += 1
            if scalarCount % 262144 == 0 { print("PREFIX_SCALARS \(scalarCount)"); fflush(stdout) }
        }
        for left in UInt8(0)...127 { for right in UInt8(0)...127 {
            let s = String(decoding: [left,right], as: UTF8.self)
            for text in [s,s + "Would"," \t" + s + "Allow",s + "```"] { try primitive(text) }
        }}
        for number in UInt32(0)...0x10ffff {
            guard let scalar = UnicodeScalar(number), CharacterSet.nonBaseCharacters.contains(scalar) else { continue }
            for initial in UInt8(33)...126 {
                try primitive(String(decoding: [initial], as: UTF8.self) + String(scalar) + "```")
            }
        }
        let prefixes = ["", "old e\u{301} 한글 👩🏽‍💻\n", "```\n", " \t```swift\n", "```\nclosed\n```\n",
            "\u{1fef}\u{1fef}\u{1fef}\n", "```\u{200d}\n", "\u{feff}```\n", "\u{000b}```\n",
            "\u{00a0}```\n", "``\u{1fef}\n", "```\nWould you like to run the following command?\n```\n"]
        let headings = ["Would you like to run the following command?", "Would you like to make the following edits?",
            "Would you like to send input to terminal 75522?", "Approve app tool call?", "Allow fixture tool?",
            "Would you like to send input to\nterminal 75522?", "Would\nyou like to\nrun the following\ncommand?",
            "Would you like to send input to terminal ", "Allowing fixture tool?", "W\no\nu\nl\nd\n you like to run the following command?",
            "A\nl\nl\no\nw\n fixture tool?", "Would you like to run the following command?\nAllowing unrelated output"]
        for rows in [0,1,289,292,293,294,295,296,297,298,299,300,301,1000] {
            for ending in ["\n","\r","\r\n"] {
                for prefix in prefixes {
                    for heading in headings {
                        let body = heading + "\n$ fixture e\u{301} 한글\n› 1. Allow for this session\n  2. Deny\nEsc to cancel"
                        try frame(String(repeating: " old e\u{301} 한글 " + ending, count: rows)
                            + prefix.replacingOccurrences(of:"\n",with:ending)
                            + body.replacingOccurrences(of:"\n",with:ending) + ending + " \t\u{2000}")
                    }
                }
            }
        }
        for prefix in prefixes {
            let body = "Would you like to run the following command?\n$ first\n› 1. Yes\n2. No\nEsc to cancel\n"
                + "Would you like to send input to terminal 75522?\nInput: “\\u{4}”\n› 1. Yes, proceed (y)\n2. No, and tell Codex what to do differently (esc)\nPress enter to confirm or esc to cancel"
            try frame(prefix + body)
            try frame(prefix + "$ old command\nBash command\n$ fixture\nDo you want to proceed?\n❯ 1. Yes\n2. No\nEsc to cancel", agent:.claude)
            for blank in [" \t", "\u{00a0}\u{2000}", "\u{200b}"] {
                try frame(prefix + body + String(repeating: "\n" + blank, count: 1500))
            }
        }
        for count in [4 * 1024 * 1024 - 1,4 * 1024 * 1024,4 * 1024 * 1024 + 1] {
            try frame(String(repeating: "x", count:count) + "\nWould you like to run the following command?\n$ fixture\n› 1. Yes\n2. No\nEsc to cancel")
        }
        let input = "unchanged fingerprint source"
        let preparedText = "old e\u{301} 한글\nWould you like to run the following command?\n$ fixture\n› 1. Yes\n2. No\nEsc to cancel"
        try require(InteractivePreflightOracle.same(
            referenceFields(ReferencePromptDetector.detect(input,agent:.codex,prepared:ReferenceDetectionLines(preparedText))),
            candidateFields(CandidatePromptDetector.detect(input,agent:.codex,prepared:CandidateDetectionLines(preparedText)))), "Prepared-source ownership changed")
        try require(scalarCount == 1112064 && frames > 10000 && foreign > 0 && approvals > 0, "Incomplete custom coverage")
        print("NATIVE_CODEX_WINDOW scalars \(scalarCount); primitives \(primitives); frames \(frames); foreign \(foreign); approvals \(approvals); checksum \(checksum)")
        try CompleteSuffixCheck.main()
        try InteractivePreflightOracle.main()
    }
}
