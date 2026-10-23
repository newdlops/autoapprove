import Foundation
import AutoApproveCore

@main struct ConfirmationOracle {
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppError.message(message) }
    }
    static func main() throws {
        var normalizations = 0, fast = 0, foreign = 0, menus = 0, nonIdempotent = 0
        var digest: UInt64 = 14695981039346656037
        func absorb(_ text: String) { for byte in text.utf8 { digest = (digest ^ UInt64(byte)) &* 1099511628211 }; digest = (digest ^ 255) &* 1099511628211 }
        func check(_ raw: String) throws {
            let bytes = Array(raw.utf8), storage = raw.isContiguousUTF8
            let a = ReferenceConfirmation.oracleClean(raw), b = CandidateConfirmation.oracleClean(raw)
            try require(a.utf8.elementsEqual(b.utf8), "Cleanup bytes differ: " + raw.debugDescription)
            if CandidateConfirmation.oracleFast(raw) { fast += 1; try require(a.utf8.elementsEqual(bytes), "Fast return changed text") }
            if !storage { foreign += 1 }
            try require(raw.utf8.elementsEqual(bytes) && raw.isContiguousUTF8 == storage, "Caller bytes/storage changed")
            let aa = ReferenceConfirmation.oracleClean(a), bb = CandidateConfirmation.oracleClean(b)
            try require(aa.utf8.elementsEqual(bb.utf8), "Second cleanup bytes differ")
            if !a.utf8.elementsEqual(aa.utf8) { nonIdempotent += 1 }
            absorb(a); absorb(aa); normalizations += 2
        }
        for a in UInt8(0)..<128 { for b in UInt8(0)..<128 { try check(String(decoding: [a,b], as: UTF8.self)) } }
        let critical: [UInt8] = [0,9,10,11,12,13,32,33,40,41,46,65,91,93,127]
        for a in critical { for b in critical { for c in critical { try check(String(decoding: [a,b,c], as: UTF8.self)) } } }
        var random: UInt64 = 0x785da9ce24a1
        func next() -> UInt64 { random ^= random << 13; random ^= random >> 7; random ^= random << 17; return random }
        for index in 0..<100_000 {
            let length = Int(next() % 97), bytes = (0..<length).map { _ in UInt8(next() % 128) }
            let text = String(decoding: bytes, as: UTF8.self); try check(text)
            if index % 128 == 0 { try check(NSAppleEventDescriptor(string: text).stringValue!) }
        }
        var scalarExclusions = 0, scalarProbes = 0
        for value in 128...0x10FFFF {
            guard let scalar = UnicodeScalar(value) else { continue }
            let text = String(scalar)
            for probe in [text, "Allow " + text, "prefix " + text + " suffix"] {
                try require(!CandidateConfirmation.oracleFast(probe), "NonASCII entered fast return")
                scalarProbes += 1
            }
            scalarExclusions += 1
        }
        try require(scalarExclusions == 1_111_936 && scalarProbes == 3_335_808, "Scalar coverage incomplete")
        let labels = ["", "Yes", "No", "Allow", "Deny", "Cancel", "Allow for this session", "Always allow",
            "Yes, proceed", "Yes, use staging", "No, use production", "Other project", "Yes, don't ask again",
            "No, and tell Codex what to do differently", "Allow Run the tool and continue.", "Don't allow", "Do not allow",
            "허용", "거부", "예", "아니오", "yeſ", "e\u{301}", "한글 👩🏽‍💻", "Allow\u{0000}tail"]
        let prefixes = ["", " ", "!", ".", "\t", "\r\n", "[", "(", "\u{00a0}"]
        let suffixes = ["", "!", ".", " (y)", " [recommended]", " (y).", " [a]!", " (추천)", " (shift + tab)", "\n", "\u{2003}"]
        var corpus = labels
        for label in labels { for prefix in prefixes { for suffix in suffixes {
            let text = prefix + label + suffix; try check(text); corpus.append(text)
            if next() % 19 == 0 { try check(NSAppleEventDescriptor(string: text).stringValue!) }
        }}}
        let repairedInputs: [[UInt16]] = [[0xD800],[0xDC00],[0xD800,0x20],[0xD800,0xDC00],[0xD800,0x0065,0x0301]]
        for units in repairedInputs {
            let text = String(decoding: units, as: UTF16.self); try check(text); try check("Allow " + text)
        }
        func menu(_ labels: [String], descriptions: [String] = [], multi: Bool = false, extra: Bool = false) throws {
            let options: [JSONObject] = labels.enumerated().map { index,label in ["label":label,"description":descriptions.indices.contains(index) ? descriptions[index] : ""] }
            var input: JSONObject = ["questions":[["question":"Continue with this request?","multiSelect":multi,"options":options]]]
            if extra { input["answers"] = ["already":"answered"] }
            let a = ReferenceConfirmation.detect(input), b = CandidateConfirmation.detect(input)
            try require(a?.question == b?.question && a?.answer == b?.answer, "Selected answer differs")
            try require(ReferenceConfirmation.singleApprovalIndex(labels,descriptions:descriptions) == CandidateConfirmation.singleApprovalIndex(labels,descriptions:descriptions), "Menu index differs")
            try require(ReferenceConfirmation.isToolPermissionMenu(labels) == CandidateConfirmation.isToolPermissionMenu(labels), "Tool menu differs")
            if let a,let b {
                let aa = try JSONSerialization.data(withJSONObject:a.updatedInput(input),options:.sortedKeys),bb = try JSONSerialization.data(withJSONObject:b.updatedInput(input),options:.sortedKeys)
                try require(aa == bb, "Updated answer/question JSON differs");absorb(String(decoding:aa,as:UTF8.self))
            } else { absorb("nil") }
            menus += 1
        }
        for label in corpus { try menu([label,"No"]);try menu(["Yes",label]) }
        for _ in 0..<6000 {
            let count=Int(next()%3)+2,items=(0..<count).map{_ in corpus[Int(next()%UInt64(corpus.count))]}
            let descriptions=(0..<count).map{_ in ["","Allow all edits during this session.","Run the tool and continue.","Use staging instead."][Int(next()%4)]}
            try menu(items,descriptions:descriptions,multi:next()%13==0,extra:next()%23==0)
        }
        for items in [["Yes (y).","No"],["Yes [y].","Yes","No"],["Allow","Allow for this session","Always allow","Cancel"],["Yes, use staging","No, use production"]] { try menu(items) }
        let malformed: [JSONObject] = [[:],["questions":[]],["questions":[["question":"","options":[]]]],["questions":[["question":"q","options":[["label":1],["label":"No"]]]]]]
        for input in malformed {
            try require(ReferenceConfirmation.detect(input)?.answer == CandidateConfirmation.detect(input)?.answer,"Malformed input differs")
        }
        try require(nonIdempotent > 0 && fast > 0 && foreign > 0, "Missing required paths")
        print("YESNO_ORACLE normalizations \(normalizations); fast \(fast); foreign \(foreign); scalarExclusions \(scalarExclusions); scalarProbes \(scalarProbes); menus \(menus); nonIdempotent \(nonIdempotent); digest \(digest)")
    }
}
