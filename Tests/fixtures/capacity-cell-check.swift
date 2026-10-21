import Foundation
import CoreFoundation
import CryptoKit
import Darwin
import AutoApproveCore

@main struct CapacityCellCheck {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw AppError.message(message) }
    }
    static func native(_ text: String) -> String { String(decoding: Array(text.utf8), as: UTF8.self) }
    static func foreign(_ units: [UniChar]) -> String {
        let value = CFStringCreateWithCharacters(kCFAllocatorDefault, units, units.count)!
        return unsafeBitCast(value, to: NSString.self) as String
    }
    static func foreign(_ text: String) -> String { foreign(Array(text.utf16)) }
    static func cocoa(_ text: String) -> String { NSAppleEventDescriptor(string: text).stringValue! }
    static func cpu() -> Double {
        var r = rusage(); getrusage(RUSAGE_SELF, &r)
        return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1_000_000
    }
    static func run() throws {
        var cases = 0, recognized = 0, hash = SHA256()
        func compare(_ cellRows: [String], _ agent: AgentKind, emptyEnd: Bool = false) throws {
            let rows = ["OUTSIDE cell must not be inspected", ""] + cellRows + ["", "OUTSIDE trailing row"]
            let start = 2, end = emptyEnd ? nil : cellRows.count + 1
            let before = BaselineCellProbe.normalize(rows, start: start, end: end, agent: agent)
            let after = CandidateCellProbe.normalize(rows, start: start, end: end, agent: agent)
            let a = BaselineCapacityCellClassifier.classify(before, agent: agent)
            let b = CandidateCapacityCellClassifier.classify(after, agent: agent)
            try check(a == b, "Cell kind differs at synthetic case \(cases)")
            if a != nil {
                try check(before.utf8.elementsEqual(after.utf8), "Recognized cell bytes differ at synthetic case \(cases)")
                recognized += 1; hash.update(data: Data(before.utf8))
            }
            hash.update(data: Data(("\(cases):" + (a?.rawValue ?? "none") + "\n").utf8)); cases += 1
        }
        let stores: [(String, (String) -> String)] = [("native", native), ("foreign", foreign), ("cocoa", cocoa)]
        let explicit: [([String], AgentKind, SessionInterruption.Kind?)] = [
            (["■ Selected model is at capacity. Please try a different model."], .codex, .capacity),
            (["■Selected model is at ca", "pacity."], .codex, .capacity),
            (["\t", "■ selectedmodelisatcapacity."], .codex, .capacity),
            (["■ stream disconnected before completion: 403 unauthorized"], .codex, .authentication),
            (["API", "Error: 402 billing_error"], .claude, .configuration),
            (["■ stream disconnected before completion: network error"], .codex, .transport),
            (["⎿ API Error: 503 overloaded"], .claude, .api),
            (["■ A new provider wording"], .codex, .api),
            (["ordinary output followed by ■ error"], .codex, nil),
            (["API Error: network failure › user draft"], .claude, nil)
        ]
        for (rows, agent, expected) in explicit { for (_, store) in stores {
            let values = rows.map(store)
            let normalized = BaselineCellProbe.normalize(values, start: 0, end: values.count - 1, agent: agent)
            try check(BaselineCapacityCellClassifier.classify(normalized, agent: agent) == expected, "Released explicit expectation differs")
            try compare(values, agent)
        }}
        let prefixes = ["", "■", "■ ", "API Error:", "⎿ API Error:", "Error:", "⎿ Error:", "Note: ■ ", "ordinary output", "/fixture/file", "1. Yes", "› draft"]
        let suffixes = ["Selected model is at capacity. Please try a different model.", "selectedmodelisatcapacity", "Selected model is at capacity.",
            "stream disconnected before completion", "network error 403 unauthorized", "invalid_api_key 500", "402 billing_error", "404 model_not_found",
            "429 overloaded", "An error occurred while processing your request", "some new provider wording", "\u{0060}\u{0060}\u{0060} network error", "connection reset › draft", "한글 e\u{301} 👩🏽‍💻"]
        let separators = [" ", "\t", "\n", "\r\n", "\u{000B}", "\u{000C}", "\u{0085}", "\u{00A0}", "\u{1680}", "\u{2000}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{200B}", "\u{200D}", " \u{301}"]
        for prefix in prefixes { for suffix in suffixes { for gap in separators {
            let joined = gap + prefix + gap + suffix + gap
            let banks = [[joined], [prefix, gap + suffix], ["", joined], [" \u{301}", joined]]
            for bank in banks { for upper in [false, true] {
                let values = upper ? bank.map { $0.uppercased() } : bank
                for agent in [AgentKind.codex, .claude, .shell] { for (_, store) in stores { try compare(values.map(store), agent) }}
            }}
        }}}
        for value in 0..<128 {
            let first = String(UnicodeScalar(value)!)
            for suffix in ["■ selectedmodelisatcapacity.", "API Error: 503", "Error: network error", "ordinary output", "⎿ API Error: 403"] {
                for bank in [[first + suffix], [first, suffix], ["", first + suffix], [" \u{301}", first + suffix]] {
                    for agent in [AgentKind.codex, .claude, .shell] { for (_, store) in stores { try compare(bank.map(store), agent) }}
                }
            }
        }
        let broken: [[UniChar]] = [[0xd800], [0xdc00], [0xd800,0xd800], [0xdc00,0xdc00], [0xd800,0xdc00], [0xfffd], [0x20,0xd800,0x20]]
        for units in broken { for prefix in ["", "■ ", "API Error:"] { for agent in [AgentKind.codex, .claude, .shell] {
            try compare([foreign(Array(prefix.utf16) + units + Array("network error 403".utf16))], agent)
        }}}
        for agent in [AgentKind.codex, .claude, .shell] { try compare([], agent, emptyEnd: true) }
        let tokens = ["authentication","unauthorized","invalidapikey","invalid_api_key","oauth_org_not_allowed","billing_error","billingerror","insufficient_quota","insufficientquota","account_on_hold","model_not_found","modelnotfound","invalid_request","context_length_exceeded","contextlengthexceeded","streamdisconnectedbeforecompletion","connectionerror","transporterror","requesttimedout","networkerror","connectionreset","connectionrefused","connectionclosed","error-decodingresponsebody","errordecodingresponsebody","failedtosendrequest","error-sendingrequest","errorsendingrequest","reconnectfailed","streamclosed","socketclosed","requesttimeout","deadlineexceeded","connectionaborted","brokenpipe","overloaded","ratelimit","rate_limit","servererror","server_error","max_output_tokens","maxoutputtokens","internalservererror","temporarilyunavailable","anerroroccurredwhileprocessingyourrequest"]
        for token in tokens {
            let variants = [token, token + "\u{301}", "\u{301}" + token, token + "\u{200D}", "\u{200D}" + token,
                token + "\u{FE0F}", token.uppercased(), token.replacingOccurrences(of: "k", with: "K"),
                token.replacingOccurrences(of: "s", with: "ſ"), token.replacingOccurrences(of: "a", with: "ａ"),
                token.replacingOccurrences(of: "e", with: "é"), token.replacingOccurrences(of: "e", with: "e\u{301}")]
            for value in variants { for agent in [AgentKind.codex, .claude] { for (_, store) in stores {
                try compare([store((agent == .codex ? "■ " : "API Error: ") + "한글 e\u{301} 👩🏽‍💻 "+value)], agent)
            }}}
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        print("CORRECTNESS \(cases) recognized \(recognized) \(digest)"); fflush(stdout)
        var workloads = [[String: Any]](), checksum = 0
        for lines in [16, 400] { for (storage, store) in stores {
            let history = (0..<lines).map { "Completed synthetic step \($0): 한글 e\u{301} 👩🏽‍💻 /fixture/source.swift" }
            let modes: [(String, [String], AgentKind)] = [
                ("ordinary", history, .codex), ("unicode-first", ["한글 first row"] + history, .codex),
                ("leading-whitespace", ["\t"] + history, .codex), ("noted-capacity", ["Note: " + CodexCapacityStop.message] + history, .codex),
                ("capacity", ["■ " + CodexCapacityStop.message], .codex),
                ("wrapped-capacity", ["■ Selected model is at", "capacity. Please try a different model."], .codex),
                ("transport", ["■ stream disconnected before completion: network error"] + history, .codex),
                ("claude", ["API Error: 503 server_error"] + history, .claude),
                ("auth", ["■ unauthorized 403"] + history, .codex), ("config", ["■ billing_error 402"] + history, .codex),
                ("draft", ["■ network error › user draft"] + history, .codex), ("unknown", ["■ New provider wording"] + history, .codex)
            ]
            for (mode, raw, agent) in modes {
                let values = raw.map(store), end = values.count - 1
                var trials = [[String: Any]]()
                for pair in 0..<4 { for candidate in pair.isMultiple(of: 2) ? [false, true] : [true, false] { autoreleasepool {
                    let beforeCPU = cpu(), beforeWall = ProcessInfo.processInfo.systemUptime
                    for _ in 0..<32 {
                        let cell = candidate ? CandidateCellProbe.normalize(values, start: 0, end: end, agent: agent) : BaselineCellProbe.normalize(values, start: 0, end: end, agent: agent)
                        let kind = candidate ? CandidateCapacityCellClassifier.classify(cell, agent: agent) : BaselineCapacityCellClassifier.classify(cell, agent: agent)
                        checksum += kind == nil ? 0 : 1
                    }
                    trials.append(["candidate": candidate, "cpuSeconds": cpu() - beforeCPU, "wallSeconds": ProcessInfo.processInfo.systemUptime - beforeWall])
                }}}
                workloads.append(["mode": mode, "lines": lines, "storage": storage, "rounds": 32, "trials": trials])
            }
        }}
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["correctnessCases": cases, "recognizedCases": recognized, "resultSHA256": digest, "workloads": workloads, "checksum": checksum,
            "originalInputs": 0, "captures": 0, "listeners": 0], options: .sortedKeys), as: UTF8.self))
    }
    static func main() throws { try run() }
}
