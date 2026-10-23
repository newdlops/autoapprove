import Foundation
import Darwin
import AutoApproveCore

@main struct NativeQuestionWindowOracle {
    static var primitives = 0, frames = 0, foreign = 0, approvals = 0, orderCases = 0
    static var checksum: UInt64 = 1469598103934665603
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw AppError.message(message) }
    }
    static func mix(_ value: UInt64) { checksum = (checksum ^ value) &* 1099511628211 }
    static func primitive(_ text: String) throws {
        let trimmed = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
        let expected = trimmed.first
        let initial = text.utf8.withContiguousStorageIfAvailable {
            CandidatePromptDetector.nativeASCIIRowInitial($0, start: 0, end: $0.count)
        }!
        if let initial, initial != 65, initial != 87 {
            try require(expected != "A" && expected != "W", "Rejected a possible heading: " + text.debugDescription)
        }
        if let initial, initial != 62, !(49...57).contains(initial) {
            try require(!ReferencePromptDetector.isOption(trimmed), "Rejected possible option: " + text.debugDescription)
            try require(trimmed.range(of: #"^[›❯»>]\s*[1-9][0-9]?\.\s+"#, options: .regularExpression) == nil, "Rejected selected option")
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
            let before = try RawDetectorFields.reference(text, agent: agent)
            let after = try RawDetectorFields.candidate(text, agent: agent)
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
            for text in [s,s + "Would"," \t" + s + "Allow",s + "```",s + "1. item",">" + s + "1. item"] { try primitive(text) }
            scalarCount += 1
            if scalarCount % 262144 == 0 { print("PREFIX_SCALARS \(scalarCount)"); fflush(stdout) }
        }
        for left in UInt8(0)...127 { for right in UInt8(0)...127 {
            let s = String(decoding: [left,right], as: UTF8.self)
            for text in [s,s + "Would"," \t" + s + "Allow",s + "```",s + "1. item",">" + s + "1. item"] { try primitive(text) }
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
        let questions = [
            "Which result?\n› 1. First e\u{301}\n  2. Second 한글\nEnter to select",
            "How should this work?\n  1. First\n> 2. Second\nEnter to select",
            "Select a model\n› 1. gpt-6 (current)\n  2. claude-opus-4\nEnter to select",
            "Choose a model\n› 1. gpt-6\n  2. claude-opus-4\nEnter to select",
            "Would you like to run the following command?\nWhich result?\n› 1. First\n  2. Second\nEsc to cancel",
            "Question 1/2 (2 unanswered)\nWhich result?\n› 1. First\n  2. Second\ntab to add notes | enter to submit all | ←/→ to navigate questions | esc to interrupt",
            "Question 1/1 (1 unanswered)\nWhich result?\n› notes\ntab or esc to clear notes | enter to submit all",
            "Which result?\n› 1. First\n  2. Second\nEnter to select\nwork resumed",
            "Which result?\n› 1. First\nEnter to select"
        ]
        for rows in [0,1,289,292,293,294,295,296,297,298,299,300,301,1000] {
            for ending in ["\n","\r","\r\n"] {
                for prefix in prefixes {
                    for question in questions {
                        for agent: AgentKind in [.codex,.claude] {
                            try frame(String(repeating:" old e\u{301} 한글 " + ending,count:rows)
                                + prefix.replacingOccurrences(of:"\n",with:ending)
                                + question.replacingOccurrences(of:"\n",with:ending) + ending + " \t\u{2000}",agent:agent)
                        }
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
        for body in questions.prefix(3) {
            for rows in [0,299,301] {
                let raw=String(repeating:"old e\u{301} 한글\n",count:rows)+body
                for agent: AgentKind in [.codex,.claude] {
                    for text in [raw,NSAppleEventDescriptor(string:raw).stringValue!] {
                        for preparation in 0..<7 {
                            let a=try RawDetectorFields.reference(text,agent:agent,preparation:preparation)
                            let b=try RawDetectorFields.candidate(text,agent:agent,preparation:preparation)
                            try require(InteractivePreflightOracle.same(a,b),"Detector preparation order changed")
                            for value in b { for byte in value.utf8 { mix(UInt64(byte)) } }
                            orderCases += 1
                        }
                    }
                }
            }
        }
        try require(orderCases == 252,"Missing preparation-order cases")
        try require(scalarCount == 1112064 && frames == 30366 && foreign > 0 && approvals > 0, "Incomplete custom coverage")
        print("NATIVE_QUESTION_WINDOW scalars \(scalarCount); primitives \(primitives); frames \(frames); foreign \(foreign); approvals \(approvals); orders \(orderCases); checksum \(checksum)")
        try CompleteSuffixCheck.main()
        try InteractivePreflightOracle.main()
    }
}

struct RawDetectorFields {
    static func reference(_ text:String,agent:AgentKind,preparation:Int=0)throws->[String]{
        let prepared=ReferenceDetectionLines(text)
        switch preparation {
        case 1: _ = prepared.sourceByteCount
        case 2: _ = prepared.raw
        case 3: _ = prepared.trimmed
        case 4: _ = prepared.normalizedSuffix(300)
        case 5: _ = prepared.trimmedSuffix(300)
        case 6: _ = ReferenceTerminalChoiceQuestion.hasCodexOverlay(prepared:prepared)
        default: break
        }
        let possible=true
        let prompt: ReferenceApprovalPrompt? = possible ? ReferencePromptDetector.detect(text,agent:agent,prepared:prepared):nil
        let request: ReferencePendingScreenRequest? = possible ? ReferenceQuestionDetector.detect(agent:agent,prepared:prepared):nil
        let overlay=possible && ReferenceTerminalChoiceQuestion.hasCodexOverlay(prepared:prepared)
        let choice: ReferenceTerminalChoiceQuestion? = possible ? ReferenceTerminalChoiceQuestion.detect(text,agent:agent,prepared:prepared,permissionPrompt:prompt,request:request):nil
        var result=[String(overlay),request?.phase.rawValue ?? "nil",request?.summary ?? "nil"]
        if let prompt{result += [prompt.summary,prompt.answer,prompt.fingerprint,prompt.dialog,prompt.requestIdentity,String(prompt.hasRequestBoundary),prompt.identity]}else{result.append("nil prompt")}
        if let choice{let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];result.append(try encoder.encode(choice).base64EncodedString())}else{result.append("nil choice")}
        return result
    }


    static func candidate(_ text:String,agent:AgentKind,preparation:Int=0)throws->[String]{
        let prepared=CandidateDetectionLines(text)
        switch preparation {
        case 1: _ = prepared.sourceByteCount
        case 2: _ = prepared.raw
        case 3: _ = prepared.trimmed
        case 4: _ = prepared.normalizedSuffix(300)
        case 5: _ = prepared.trimmedSuffix(300)
        case 6: _ = CandidateTerminalChoiceQuestion.hasCodexOverlay(prepared:prepared)
        default: break
        }
        let possible=true
        let prompt: CandidateApprovalPrompt? = possible ? CandidatePromptDetector.detect(text,agent:agent,prepared:prepared):nil
        let request: CandidatePendingScreenRequest? = possible ? CandidateQuestionDetector.detect(agent:agent,prepared:prepared):nil
        let overlay=possible && CandidateTerminalChoiceQuestion.hasCodexOverlay(prepared:prepared)
        let choice: CandidateTerminalChoiceQuestion? = possible ? CandidateTerminalChoiceQuestion.detect(text,agent:agent,prepared:prepared,permissionPrompt:prompt,request:request):nil
        var result=[String(overlay),request?.phase.rawValue ?? "nil",request?.summary ?? "nil"]
        if let prompt{result += [prompt.summary,prompt.answer,prompt.fingerprint,prompt.dialog,prompt.requestIdentity,String(prompt.hasRequestBoundary),prompt.identity]}else{result.append("nil prompt")}
        if let choice{let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];result.append(try encoder.encode(choice).base64EncodedString())}else{result.append("nil choice")}
        return result
    }

}
