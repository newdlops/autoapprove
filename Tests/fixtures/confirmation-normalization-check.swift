import Foundation
import Darwin
import AutoApproveCore
import CryptoKit

@main struct ConfirmationNormalizationCheck {
    static func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }

    static func result(_ input: JSONObject, baseline: Bool) -> [Data]? {
        if baseline {
            return BaselineYesNoConfirmation.detect(input).map { [Data($0.question.utf8), Data($0.answer.utf8)] }
        }
        return YesNoConfirmation.detect(input).map { [Data($0.question.utf8), Data($0.answer.utf8)] }
    }

    static func input(_ labels: [String], descriptions: Bool = false) -> JSONObject {
        ["questions": [["question": "이 작업을 진행할까요? e\u{301}", "options": labels.map {
            descriptions ? ["label": $0, "description": "Allow for this session (Recommended)."] : ["label": $0]
        }]]]
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppError.message(message) }
    }

    static func run() throws {
        let menus = [
            ["Yes", "No"], ["No", "Yes, proceed"], ["Yes", "Yes, don't ask again", "No"],
            ["Allow", "Cancel"], ["Allow", "Allow for this session", "Always allow", "Cancel"],
            ["Allow", "Allow and don't ask me again", "Don't allow"],
            ["예", "아니오"], ["항상 허용", "거부", "허용"], ["네", "취소"], ["응", "아니요"],
            ["Yes, use staging", "No, use production"], ["First plan", "Second plan"], ["Yes", "Maybe"],
            ["Yes", "YES", "No"], ["No", "Cancel"], ["Yes", "Yes, and switch to auto mode", "No"],
            ["Yes, and switch to accept edits for this session", "No", "Yes, allow once"],
            ["Allow Run the tool and continue.", "Cancel Cancel this tool call."],
            ["Yes", "No, and tell Codex what to do differently"], ["Ａllow", "Cancel"], ["e\u{301}", "é"],
            ["Allow for this session", "Deny"], ["Always allow", "Cancel"],
            ["Allow for this session", "Allow", "Cancel"], ["Deny", "Allow for this session"],
            ["Allow", "Deny", "Cancel"], ["Allow for this session", "Always allow", "Deny"]
        ]
        let hints = ["", " (Recommended)", " [esc]", " (a).", " (a) (recommended).", " (a). [esc]!", "\n (shift + tab)"]
        let wrappers: [(String, String)] = [("", ""), (" \n", "\n "), ("", ".!。！"), ("", " [esc]."), ("‘", "’")]
        var cases = 0, digest = SHA256()
        for menu in menus { for hint in hints { for (prefix, suffix) in wrappers {
            for reverse in [false, true] { for descriptions in [false, true] {
                let labels = menu.map { prefix + $0 + hint + suffix }
                let base = input(reverse ? Array(labels.reversed()) : labels, descriptions: descriptions)
                let toolLabels = reverse ? Array(labels.reversed()) : labels
                let toolMenu = YesNoConfirmation.isToolPermissionMenu(toolLabels)
                try check(toolMenu == BaselineYesNoConfirmation.isToolPermissionMenu(toolLabels), "Tool permission menu changed at case \(cases)")
                digest.update(data: Data([toolMenu ? 1 : 0])); cases += 1
                for mode in 0..<4 {
                    var value = base
                    if mode == 1 { value["answers"] = ["already": "answered"] }
                    if mode >= 2 {
                        var question = (base["questions"] as! [JSONObject])[0]
                        question["multiSelect"] = mode == 2 ? true : false
                        value["questions"] = [question]
                    }
                    let expected = result(value, baseline: true), actual = result(value, baseline: false)
                    try check(actual == expected, "Confirmation changed at case \(cases)")
                    digest.update(data: Data([actual == nil ? 0 : 1]))
                    for field in actual ?? [] { digest.update(data: field) }
                    cases += 1
                }
            }}
        }}}
        let malformed: [JSONObject] = [[:], ["questions": []], ["answers": "invalid"],
            ["questions": [["question": "", "options": [["label": "Yes"], ["label": "No"]]]]],
            ["questions": [["question": "Proceed?", "multiSelect": "false", "options": [["label": "Yes"], ["label": "No"]]]]],
            ["questions": [["question": "Proceed?", "options": [["label": "Yes"], ["label": 2]]]]]]
        for value in malformed {
            try check(result(value, baseline: false) == result(value, baseline: true), "Malformed input changed")
            cases += 1
        }

        let workloads: [(String, JSONObject)] = [
            ("manual-task-choice", input(["Yes, use staging", "No, use production"])),
            ("one-time-confirmation", input(["No", "Yes (Recommended)"])),
            ("session-permission", input(["Allow for this session", "Deny"])),
            ("repeated-permission", input(["Allow", "Allow for this session", "Always allow", "Cancel"]))
        ]
        var measurements: [[String: Any]] = [], checksum = 0
        for (name, value) in workloads {
            var before: [Double] = [], after: [Double] = []
            for pair in 0..<3 {
                for baseline in pair.isMultiple(of: 2) ? [true, false] : [false, true] {
                    let start = cpu()
                    for _ in 0..<256 { checksum += result(value, baseline: baseline)?.last?.count ?? 0 }
                    let elapsed = cpu() - start
                    if baseline { before.append(elapsed) } else { after.append(elapsed) }
                }
            }
            measurements.append(["name": name, "rounds": 256, "beforeCPU": before.sorted()[1], "afterCPU": after.sorted()[1]])
        }
        let report: [String: Any] = ["cases": cases, "digest": digest.finalize().map { String(format: "%02x", $0) }.joined(),
            "pairs": 3, "workloads": measurements, "checksum": checksum, "inputPosts": 0]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: .sortedKeys), as: UTF8.self))
    }

    static func main() {
        do { try run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
