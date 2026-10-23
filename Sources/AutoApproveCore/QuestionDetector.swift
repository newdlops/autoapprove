import Foundation

public struct PendingScreenRequest: Sendable {
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
        if agent == .codex, let native = prepared.nativeCodexQuestion() {
            switch native {
            case .absent: return nil
            case .request(let request): return request
            }
        }
        let suffix = prepared.normalizedSuffix(300)
        let lines = suffix.rows.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = lines.lastIndex(where: PromptDetector.isOption) else { return nil }
        guard PromptDetector.dialogFooterStart(in: lines, after: last) != nil else { return nil }
        let selected = lines[...last].lastIndex {
            $0.range(of: #"^[›❯»>]\s*[1-9][0-9]?\.\s+"#, options: .regularExpression) != nil
        }
        guard let selected else { return nil }
        let permissionHeading = PromptDetector.permissionHeading(Array(lines[..<selected]), agent: agent)
        let questionStart = lines[..<selected].lastIndex { $0.contains("?") || AutomaticQuestionDecision.isModelHeading($0) }
        let start = permissionHeading.map { heading in
            questionStart.map { $0 > heading.end ? $0 : heading.index } ?? heading.index
        } ?? questionStart
        guard let start else { return nil }
        let dialog = Array(lines[start...])
        guard dialog.filter(PromptDetector.isOption).count >= 2,
              !dialog.contains(where: { $0.contains("```") }),
              !prepared.hasOpenCodeFence(beforeSuffixRow: start, in: suffix) else { return nil }
        let permission = permissionHeading?.index == start
        return PendingScreenRequest(phase: permission ? .approval : .input, summary: String(dialog.joined(separator: "\n").prefix(4000)))
    }

    enum NativeCodexQuestion {
        case absent
        case request(PendingScreenRequest)
    }

    static func detectNativeCodex(_ bytes: UnsafeBufferPointer<UInt8>) -> NativeCodexQuestion {
        let spans = DetectionLines.nativeSuffixRanges(bytes)
        var lines = [String?](repeating: nil, count: spans.count)
        func line(_ index: Int) -> String {
            if let value = lines[index] { return value }
            let value = PromptDetector.nativeNormalizedRow(bytes, range: spans[index]).trimmingCharacters(in: .whitespaces)
            lines[index] = value
            return value
        }
        func mayBeOption(_ index: Int) -> Bool {
            guard let initial = PromptDetector.nativeASCIIRowInitial(bytes, start: spans[index].lowerBound, end: spans[index].upperBound) else { return true }
            return initial == 62 || (initial >= 49 && initial <= 57)
        }
        guard let last = spans.indices.reversed().first(where: { mayBeOption($0) && PromptDetector.isOption(line($0)) }) else { return .absent }
        let remaining = ((last + 1)..<spans.count).map(line)
        guard PromptDetector.dialogFooterStart(in: remaining, after: -1) != nil else { return .absent }
        let selected = (0...last).reversed().first {
            mayBeOption($0) && line($0).range(of: #"^[›❯»>]\s*[1-9][0-9]?\.\s+"#, options: .regularExpression) != nil
        }
        guard let selected else { return .absent }
        let permissionHeading = PromptDetector.permissionHeading(count: selected, lineAt: line, agent: .codex, mayStart: { index in
            guard let initial = PromptDetector.nativeASCIIRowInitial(bytes, start: spans[index].lowerBound, end: spans[index].upperBound) else { return true }
            return initial == 65 || initial == 87
        })
        let questionStart = (0..<selected).reversed().first { line($0).contains("?") || AutomaticQuestionDecision.isModelHeading(line($0)) }
        let start = permissionHeading.map { heading in
            questionStart.map { $0 > heading.end ? $0 : heading.index } ?? heading.index
        } ?? questionStart
        guard let start else { return .absent }
        let dialog = (start..<spans.count).map(line)
        guard dialog.filter(PromptDetector.isOption).count >= 2,
              !dialog.contains(where: { $0.contains("```") }),
              !DetectionLines.codeFenceParity(bytes, before: spans[start].lowerBound) else { return .absent }
        return .request(PendingScreenRequest(phase: permissionHeading?.index == start ? .approval : .input,
            summary: String(dialog.joined(separator: "\n").prefix(4000))))
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
