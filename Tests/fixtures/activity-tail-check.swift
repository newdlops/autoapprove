import Foundation
import Darwin
import CryptoKit
import CoreFoundation

/// Linked production detectors and the exact ActivityDetector source. No terminals or user files.
@main struct ActivityTailCheck {
    struct Example {
        let screen: String
        let agent: AgentKind
        let permission: Bool
        let phase: SessionPhase
        var monitoring = false
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "ActivityTailCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @inline(never) static func activity(_ screen: String, permission: Bool) -> ActivityObservation {
        ActivityDetector.detect(screen, agent: .codex, permissionPrompt: { permission })
    }

    static func foundationString(_ text: String) -> String {
        let units = Array(text.utf16)
        let value = CFStringCreateWithCharacters(kCFAllocatorDefault, units, units.count)!
        return unsafeBitCast(value, to: NSString.self) as String
    }

    static func correctness() throws -> (Int, String) {
        let examples = [
            Example(screen: "", agent: .codex, permission: true, phase: .unknown),
            Example(screen: " \t\n\u{00A0}\n", agent: .codex, permission: true, phase: .unknown),
            Example(screen: "Finished 한글 👨‍👩‍👧‍👦 e\u{301}\n›\n? for shortcuts", agent: .codex, permission: false, phase: .idle),
            Example(screen: "» Ask Codex to do anything\ngpt-6 · ~/fixture", agent: .codex, permission: false, phase: .idle),
            Example(screen: "❯\n⏵⏵ accept edits on (shift+tab to cycle)", agent: .claude, permission: false, phase: .idle),
            Example(screen: "› Explain 한글 🤖\n? for shortcuts", agent: .codex, permission: false, phase: .input),
            Example(screen: "• Working (esc to interrupt)\n›\n? for shortcuts", agent: .codex, permission: true, phase: .working),
            Example(screen: "›\n? for shortcuts\ntab to queue", agent: .codex, permission: false, phase: .working),
            Example(screen: "Would you like to proceed?\n› 1. Yes\n2. No", agent: .codex, permission: true, phase: .approval),
            Example(screen: "1 background task\n›\n? for shortcuts", agent: .codex, permission: false, phase: .idle, monitoring: true),
            Example(screen: "1 background task\nReading logs…", agent: .codex, permission: false, phase: .working),
            Example(screen: "```\n›\n? for shortcuts\n```", agent: .codex, permission: false, phase: .unknown),
            Example(screen: "› 1. First\n? for shortcuts", agent: .codex, permission: false, phase: .unknown),
            Example(screen: "›\nUnknown footer", agent: .codex, permission: false, phase: .unknown),
            Example(screen: "›\n? for shortcuts", agent: .shell, permission: true, phase: .unknown)
        ]
        let newlines = ["\n", "\r\n", "\r", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"]
        let blanks = ["", " \t", "\u{00A0}\u{2009}"]
        var digest = SHA256(), cases = 0
        for example in examples {
            for newline in newlines {
                for blank in blanks {
                    for count in [0, 18, 64, 256] {
                        let prefix = String(repeating: "Old synthetic output 漢字 e\u{301} 🤖" + newline, count: count)
                        let text = prefix + blank + newline + example.screen.replacingOccurrences(of: "\n", with: newline) + newline + blank + newline
                        // A prefix makes an otherwise empty permission frame nonempty.
                        let expected = count > 0 && example.screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && example.agent != .shell && example.permission ? SessionPhase.approval : example.phase
                        for bridged in [false, true] {
                            let result = ActivityDetector.detect(bridged ? foundationString(text) : text, agent: example.agent, permissionPrompt: { example.permission })
                            try check(result.phase == expected, "Wrong phase for example \(cases): \(result.phase), expected \(expected)")
                            try check(result.monitoring == example.monitoring, "Wrong background state for example \(cases)")
                            digest.update(data: Data((result.phase.rawValue + "\u{0000}" + result.detail + "\u{0000}" + String(result.monitoring) + "\n").utf8))
                            cases += 1
                        }
                    }
                }
            }
        }
        for newline in newlines {
            let numbered = (1...25).map { "row \($0) e\u{301} 👨‍👩‍👧‍👦" }
            let text = numbered.map { "\t" + $0 + "\u{200B}" }.joined(separator: newline + " \t" + newline) + newline
            let expected = (8...25).map { Array("row \($0) e\u{301} 👨‍👩‍👧‍👦".utf8) }
          for history in [0, 256] {
            for bridged in [false, true] {
                let input = String(repeating: "Ignored previous result 🤖 e\u{301}" + newline, count: history) + text
                let actual = ActivityDetector.fixtureTail(bridged ? foundationString(input) : input)
                try check(actual.map { Array($0.utf8) } == expected, "The ordered 18-row boundary changed")
                cases += 1
            }
          }
        }
        for (screen, agent, expected) in [
            ("Done\n›\n? for shortcuts", AgentKind.codex, SessionPhase.idle),
            ("Would you like to run the following command?\n  $ npm test\n› 1. Yes, proceed (y)\n  2. No (esc)\nPress enter to confirm or esc to cancel", .codex, .approval),
            ("Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel", .claude, .approval)
        ] {
            try check(ActivityDetector.detect(screen, agent: agent).phase == expected, "Default permission detector changed")
            cases += 1
        }
        // Foundation treats U+200B as whitespace; preserve that behavior as well as real drafts.
        for scalar in ["\u{0000}", "\u{0008}", "\u{001F}", "\u{200B}", "\u{2060}", "\u{FEFF}", "e\u{301}", "👨‍👩‍👧‍👦"] {
            let result = activity("› \(scalar)\n? for shortcuts", permission: false)
            try check(result.phase == (scalar == "\u{200B}" ? .idle : .input), "Draft whitespace interpretation changed")
            digest.update(data: Data((result.phase.rawValue + result.detail).utf8)); cases += 1
        }
        // Working hints win over permission; shell and empty frames never request permission.
        for (text, agent, calls) in [("esc to interrupt", AgentKind.codex, 0), ("", .codex, 0), ("›\n? for shortcuts", .shell, 0), ("›\n? for shortcuts", .codex, 1)] {
            var invoked = 0
            _ = ActivityDetector.detect(text, agent: agent, permissionPrompt: { invoked += 1; return false })
            try check(invoked == calls, "Permission detection order changed"); cases += 1
        }
        return (cases, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    static func run() throws {
        let (cases, digest) = try correctness()
        let row = "Synthetic ignored output: 한글 Ω e\u{301} 👨‍👩‍👧‍👦 completed fixture step with unchanged state.\n"
        let tail = "Recent synthetic result\n›\n? for shortcuts\n"
        var workloads: [[String: Any]] = [], checksum = 0
        for bridged in [false, true] {
          for scenario in ["reused", "changing"] {
            let rounds = scenario == "reused" ? 160 : 32
            for lines in [18, 4096] {
                let original = String(repeating: row, count: lines) + tail
                // Exercise both Swift input and a Foundation-provided screen.
                let text = bridged ? foundationString(original) : original
                try check(text.isContiguousUTF8 != bridged, "Both native and foreign string storage must be exercised")
                var trials: [[String: Double]] = []
                for _ in 0..<3 {
                    autoreleasepool {
                        // Every changing frame owns a fresh buffer before the timed region.
                        let changed = scenario == "changing" ? (0..<rounds).map { index -> String in
                            let frame = String(index) + "\n" + String(repeating: row, count: lines) + tail
                            return bridged ? foundationString(frame) : frame
                        } : []
                        let beforeCPU = cpu(), beforeWall = ProcessInfo.processInfo.systemUptime
                        for index in 0..<rounds {
                            let result = activity(scenario == "changing" ? changed[index] : text, permission: false)
                            checksum += result.phase.rawValue.utf8.count + (result.monitoring ? 1 : 0)
                        }
                        trials.append(["cpuSeconds": cpu() - beforeCPU, "wallSeconds": ProcessInfo.processInfo.systemUptime - beforeWall])
                    }
                }
                workloads.append(["storage": bridged ? "foundation" : "swift", "contiguousUTF8": text.isContiguousUTF8, "scenario": scenario, "historyLines": lines, "screenBytes": original.utf8.count,
                    "rounds": rounds, "trials": trials])
            }
          }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["correctnessCases": cases, "observationSHA256": digest, "workloads": workloads,
            "checksum": checksum, "peakResidentBytes": usage.ru_maxrss, "inputPosts": 0,
            "scope": "Exact production ActivityDetector and linked Core dependencies, fixed synthetic screens; permission parsing is shared as in ScreenAnalysis. Not whole-app or physical network performance."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
