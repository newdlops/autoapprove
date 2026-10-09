import Foundation

public struct PendingScreenRequest {
    public let phase: SessionPhase
    public let summary: String
}

public enum QuestionDetector {
    /// Recognize a current interactive menu without treating its first option as an answer.
    public static func detect(_ screen: String, agent: AgentKind) -> PendingScreenRequest? {
        detect(agent: agent, prepared: DetectionLines(screen))
    }

    static func detect(agent: AgentKind, prepared: DetectionLines) -> PendingScreenRequest? {
        guard agent != .shell else { return nil }
        let lines = prepared.trimmedSuffix(300)
        guard let last = lines.lastIndex(where: PromptDetector.isOption) else { return nil }
        guard PromptDetector.dialogFooterStart(in: lines, after: last) != nil else { return nil }
        let selected = lines[...last].lastIndex {
            $0.range(of: #"^[›❯»>]\s*[1-9][0-9]?\.\s+"#, options: .regularExpression) != nil
        }
        guard let selected else { return nil }
        let permissionHeading = PromptDetector.permissionHeading(Array(lines[..<selected]), agent: agent)
        let questionStart = lines[..<selected].lastIndex { $0.contains("?") }
        let start = permissionHeading.map { heading in
            questionStart.map { $0 > heading.end ? $0 : heading.index } ?? heading.index
        } ?? questionStart
        guard let start else { return nil }
        let dialog = Array(lines[start...])
        guard dialog.filter(PromptDetector.isOption).count >= 2,
              !dialog.contains(where: { $0.contains("```") }),
              lines[..<start].filter({ $0.hasPrefix("```") }).count % 2 == 0 else { return nil }
        let permission = permissionHeading?.index == start
        return PendingScreenRequest(phase: permission ? .approval : .input, summary: String(dialog.joined(separator: "\n").prefix(4000)))
    }

    public static func hookSummary(tool: String, input: JSONObject, message: String? = nil) -> String {
        if tool == "AskUserQuestion", let questions = input["questions"] as? [JSONObject] {
            let text = questions.map { question -> String in
                let options = (question["options"] as? [JSONObject] ?? []).enumerated().map { index, option in
                    "\(index + 1). \(option["label"] as? String ?? "")" + ((option["description"] as? String).map { " — \($0)" } ?? "")
                }
                return ([question["question"] as? String ?? "질문"] + options).joined(separator: "\n")
            }.joined(separator: "\n\n")
            if !text.isEmpty { return String(text.prefix(4000)) }
        }
        return String(((input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["plan"] as? String) ?? message ?? tool).prefix(4000))
    }
}
