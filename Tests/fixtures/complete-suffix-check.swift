import Foundation
import Darwin
import CryptoKit
import AutoApproveCore

@main struct CompleteSuffixCheck {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw AppError.message(message) }
    }
    static func same(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a,b).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
    static func reference(_ text: String, agent: AgentKind) -> [String]? {
        guard let p = ReferencePromptDetector.detect(text, agent: agent) else { return nil }
        return [p.summary,p.answer,p.fingerprint,p.dialog,p.requestIdentity,p.hasRequestBoundary ? "1":"0",p.identity]
    }
    static func candidate(_ text: String, agent: AgentKind) -> [String]? {
        guard let p = CandidatePromptDetector.detect(text, agent: agent) else { return nil }
        return [p.summary,p.answer,p.fingerprint,p.dialog,p.requestIdentity,p.hasRequestBoundary ? "1":"0",p.identity]
    }
    static func actual(_ text: String, agent: AgentKind) -> [String]? {
        guard let p = PromptDetector.detect(text, agent: agent) else { return nil }
        return [p.summary,p.answer,p.fingerprint,p.dialog,p.requestIdentity,p.hasRequestBoundary ? "1":"0",p.identity]
    }
    static func main() throws {
        var scalarCases=0,storageCases=0,promptCases=0,accepted=0,foreign=0,checksum:UInt64=1469598103934665603
        func mix(_ rows:[String]) {
            for row in rows { for byte in row.utf8 { checksum=(checksum ^ UInt64(byte)) &* 1099511628211 }; checksum=(checksum ^ 255) &* 1099511628211 }
        }
        func scalar(_ text:String) throws {
            let a=ReferenceDetectionLines(text),b=CandidateDetectionLines(text)
            let left=a.normalizedSuffix(300),right=b.normalizedSuffix(300)
            try require(same(left.rows,right.rows)&&left.byteStarts==right.byteStarts&&left.normalizedLineOffset==right.normalizedLineOffset,"Scalar suffix changed")
            try require(same(a.raw,b.raw)&&same(a.raw,PromptDetector.normalizedLines(text)),"Full rows changed after complete scalar suffix")
            try require(a.sourceByteCount==b.sourceByteCount&&a.sourceByteCount==text.utf8.count,"Scalar source byte count changed")
            mix(b.raw);scalarCases+=1
        }
        for value in UInt32(0)...0x10ffff {
            guard let value=UnicodeScalar(value) else { continue }
            try scalar(String(value))
            if scalarCases % 262_144 == 0 { print("SCALARS \(scalarCases)");fflush(stdout) }
        }
        func storage(_ text:String) throws {
            let before=Array(text.utf8),wasNative=text.isContiguousUTF8
            for order in 0..<3 {
                let a=ReferenceDetectionLines(text),b=CandidateDetectionLines(text)
                if order==1 { try require(same(a.raw,b.raw),"Raw-first rows changed") }
                let counts=order==2 ? [1,18,300,0,299,301,512]:[300,0,1,18,299,301,512]
                for count in counts {
                    let left=a.normalizedSuffix(count),right=b.normalizedSuffix(count)
                    try require(same(left.rows,right.rows),"Suffix rows changed for count \(count)")
                    try require(left.byteStarts==right.byteStarts&&left.normalizedLineOffset==right.normalizedLineOffset,"Original suffix metadata changed")
                    for index in [0,left.rows.count/2,left.rows.count] {
                        try require(a.hasOpenCodeFence(beforeSuffixRow:index,in:left)==b.hasOpenCodeFence(beforeSuffixRow:index,in:right),"Fence parity changed")
                    }
                    try require(same(a.trimmedSuffix(count),b.trimmedSuffix(count)),"Trimmed suffix changed")
                }
                try require(same(a.raw,b.raw)&&same(a.trimmed,b.trimmed),"Raw/trimmed arrays changed after suffix order")
                try require(a.sourceByteCount==b.sourceByteCount&&b.sourceByteCount==text.utf8.count,"Source count changed")
                mix(b.raw);storageCases+=1
            }
            try require(text.utf8.elementsEqual(before)&&text.isContiguousUTF8==wasNative,"Changed original bytes/storage")
            if !wasNative { foreign+=1 }
        }
        for rows in [0,1,2,17,18,295,296,298,299,300,301,302,384] {
            for delimiter in ["\n","\r","\r\n"] {
                for trailing in [0,1,301] {
                    for line in ["ordinary ASCII row","합성 e\u{301} 👩🏽‍💻 row"," \u{00a0}\u{2000}\u{2003} "] {
                        let text=(0..<rows).map { index in index==1 ? "\u{1fef}\u{1fef}\u{1fef}" : line }.joined(separator:delimiter)+String(repeating:delimiter+" \t",count:trailing)
                        try storage(text);try storage(NSAppleEventDescriptor(string:text).stringValue!)
                    }
                }
            }
        }
        for count in [0,1,299,300,301,4095,4096] {
            for ending:[UInt16] in [[0xd800],[0xdc00],[0xd800,0xd800,0xdc00],[0xdc00,0xd800],[0xd800,10,0xdc00],[0xd800,0xdc00],[0xffff,0]] {
                let units=Array(String(repeating:" \n",count:count).utf16)+ending
                let source=units.withUnsafeBufferPointer { NSString(characters:$0.baseAddress!,length:$0.count) } as String
                try storage(source)
            }
        }
        for agent in [AgentKind.codex,.claude] {
            for rows in [0,1,292,294,295,296,297,298,299,300,301,384] {
                for detail in ["ASCII old output","한글 e\u{301} 👩🏽‍💻 old output"] {
                    for fence in ["","```\n","```\nold\n```\n","\u{1fef}\u{1fef}\u{1fef}\n","  ```\n"] {
                        for command in ["echo fixture","echo \\\"\\u{4}\\\"","echo e\u{301} 한글","sudo id"] {
                            let history=String(repeating:detail+"\r\n",count:rows)+fence
                            let body=agent == .codex ? "Would you like to run the following command?\n$ "+command+"\n› 1. Yes\n  2. No\nEsc to cancel" : "$ "+command+"\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel"
                            let raw=history+body
                            for text in [raw,NSAppleEventDescriptor(string:raw).stringValue!] {
                                let a=reference(text,agent:agent),b=candidate(text,agent:agent),c=actual(text,agent:agent)
                                try require((a==nil)==(b==nil)&&(a==nil)==(c==nil),"Permission presence changed")
                                if let a,let b,let c { try require(same(a,b)&&same(a,c),"Exact permission fields changed");accepted+=1;mix(b) }
                                promptCases+=1
                            }
                        }
                    }
                }
            }
        }
        try require(scalarCases==1_112_064&&foreign>0&&accepted>0,"Missing scalar/storage/permission coverage")
        print("COMPLETE_SUFFIX scalars \(scalarCases); storage \(storageCases); prompts \(promptCases); accepted \(accepted); foreign \(foreign); checksum \(checksum)")
    }
}
