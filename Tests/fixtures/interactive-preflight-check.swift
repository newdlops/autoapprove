import Foundation
import Darwin
import AutoApproveCore

@main struct InteractivePreflightOracle {
    static var probes = 0, rejected = 0, needed = 0, frames = 0, foreign = 0, accepted = 0
    static var checksum: UInt64 = 1469598103934665603
    static func require(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
    static func same(_ a: [String], _ b: [String]) -> Bool { a.count == b.count && zip(a,b).allSatisfy { $0.utf8.elementsEqual($1.utf8) } }
    static func primitive(_ text: String) throws {
        let original = ReferencePromptDetector.normalizedLines(text)
        let necessary = original.suffix(300).contains { raw in
            let row = raw.trimmingCharacters(in: .whitespaces)
            return row.hasPrefix("Question") || row.range(of: #"^[›❯»>]\s*[1-9][0-9]?\.\s+"#, options: .regularExpression) != nil
        }
        let candidate = CandidateDetectionLines(text).mayContainInteractiveRows(agent: .codex)
        try require(candidate || !necessary, "False-negative preflight: " + text.debugDescription)
        probes += 1; if !candidate { rejected += 1 }; if necessary { needed += 1 }
        checksum = (checksum ^ UInt64((candidate ? 1 : 0) + (necessary ? 2 : 0))) &* 1099511628211
    }
    
    static func reference(_ text:String,agent:AgentKind)throws->[String]{
        let prepared=ReferenceDetectionLines(text)
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


    static func candidate(_ text:String,agent:AgentKind)throws->[String]{
        let prepared=CandidateDetectionLines(text)
        let possible=prepared.mayContainInteractiveRows(agent:agent)
        let prompt: CandidateApprovalPrompt? = possible ? CandidatePromptDetector.detect(text,agent:agent,prepared:prepared):nil
        let request: CandidatePendingScreenRequest? = possible ? CandidateQuestionDetector.detect(agent:agent,prepared:prepared):nil
        let overlay=possible && CandidateTerminalChoiceQuestion.hasCodexOverlay(prepared:prepared)
        let choice: CandidateTerminalChoiceQuestion? = possible ? CandidateTerminalChoiceQuestion.detect(text,agent:agent,prepared:prepared,permissionPrompt:prompt,request:request):nil
        var result=[String(overlay),request?.phase.rawValue ?? "nil",request?.summary ?? "nil"]
        if let prompt{result += [prompt.summary,prompt.answer,prompt.fingerprint,prompt.dialog,prompt.requestIdentity,String(prompt.hasRequestBoundary),prompt.identity]}else{result.append("nil prompt")}
        if let choice{let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];result.append(try encoder.encode(choice).base64EncodedString())}else{result.append("nil choice")}
        return result
    }

    static func main() throws {
        var scalarCount = 0
        for number in UInt32(0)...0x10ffff {
            guard let scalar = UnicodeScalar(number) else { continue }
            let value = String(scalar)
            for text in [value, value + "› 1. Yes", ">" + value + "1. Yes", value + "Question 1/1 (1 unanswered)"] { try primitive(text) }
            scalarCount += 1
            if scalarCount % 262144 == 0 { print("SCALARS \(scalarCount)"); fflush(stdout) }
        }
        for left in UInt8(0)...127 { for right in UInt8(0)...127 {
            try primitive(String(decoding: [left,right], as: UTF8.self) + "› 1. Yes")
            try primitive(">" + String(decoding: [left,right], as: UTF8.self) + "1. Yes")
        }}
        for number in UInt32(0)...0x10ffff {
            guard let scalar = UnicodeScalar(number), CharacterSet.nonBaseCharacters.contains(scalar) else { continue }
            for prefix in UInt8(33)...126 {
                try primitive(String(decoding: [prefix], as: UTF8.self) + String(scalar) + " 1. Yes")
            }
        }
        let bodies = ["ordinary output\n• Working (esc to interrupt)","›\n? for shortcuts",
            "Which result?\n› 1. First e\u{301}\n  2. Second 한글\nEnter to select",
            "Would you like to run the following command?\n$ fixture\n› 1. Allow for this session\n  2. Deny\nEsc to cancel",
            "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel",
            "Question 1/2 (2 unanswered)\nWhich result?\n› 1. First\n  2. Second\ntab to add notes | enter to submit all | ←/→ to navigate questions | esc to interrupt",
            "Question 1/1 (1 unanswered)\nWhich result?\n› notes\ntab or esc to clear notes | enter to submit all",
            "Select a model\n› 1. gpt-6 (current)\n  2. claude-opus-4\nEnter to select",
            "■ Selected model is at capacity. Please try a different model.\n\n›\n? for shortcuts",
            "■ stream disconnected before completion\n\n›\n? for shortcuts",
            "›\n? for shortcuts\nGoal blocked (/goal resume)",
            "Which result?\n›\u{200D} 1. First\n  2. Second\nEnter to select"]
        for rows in [0,1,292,299,300,301,384] {
            for ending in ["\n","\r","\r\n"] {
                for fence in ["","```\n","\u{1fef}\u{1fef}\u{1fef}\n"] {
                    for (index, body) in bodies.enumerated() {
                        let raw = String(repeating: " old e\u{301} 한글 👩🏽‍💻 " + ending, count: rows) + fence + body + ending + " \t\u{2000}"
                        for text in [raw, NSAppleEventDescriptor(string: raw).stringValue!] {
                            let bytes = Array(text.utf8), storage = text.isContiguousUTF8
                            if !storage { foreign += 1 }
                            let agent: AgentKind = index == 4 ? .claude : .codex
                            let a = try reference(text, agent: agent), b = try candidate(text, agent: agent)
                            try require(same(a,b), "Full parser fields changed")
                            if a[1] != "nil" { accepted += 1 }
                            for value in b { for byte in value.utf8 { checksum = (checksum ^ UInt64(byte)) &* 1099511628211 } }
                            try require(text.utf8.elementsEqual(bytes) && text.isContiguousUTF8 == storage, "Changed caller bytes/storage")
                            frames += 1
                        }
                    }
                }
            }
        }
        for rows in [0,1,294,295,296,297,298,299,300,301,302,1000] {
            for ending in ["\n","\r","\r\n"] {
                for blank in [" \t", "\u{00a0}\u{2000}", "\u{200b}"] {
                    let raw = "Question 1/1 (1 unanswered)" + ending + String(repeating: "ordinary output" + ending, count: rows) + "› notes" + ending + String(repeating: blank + ending, count: 1500)
                    for text in [raw, NSAppleEventDescriptor(string: raw).stringValue!] {
                        let a = try reference(text, agent: .codex), b = try candidate(text, agent: .codex)
                        try require(same(a,b), "Trailing blanks or300-row window changed"); frames += 1
                    }
                }
            }
        }
        for count in [0,1,299,300,301,4095,4096] {
            for fragment: [UInt16] in [[0xd800],[0xdc00],[0xd800,0xd800,0xdc00],[0xdc00,0xd800],[0xd800,10,0xdc00],[0xd800,0xdc00],[0xffff,0]] {
                let units = Array(String(repeating: " \n", count: count).utf16) + fragment + Array("\nWhich result?\n› 1. First\n2. Second\nEnter to select".utf16)
                let text = units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) as String }
                try require(same(try reference(text,agent:.codex), try candidate(text,agent:.codex)), "RepairedUTF16 parser changed"); frames += 1
            }
        }
        try require(scalarCount == 1112064 && rejected > 1000000 && needed > 0 && foreign > 0 && accepted > 0, "Incomplete coverage")
        print("INTERACTIVE_PREFLIGHT scalars \(scalarCount); probes \(probes); rejected \(rejected); necessary \(needed); frames \(frames); foreign \(foreign); accepted \(accepted); checksum \(checksum)")
    }
}
