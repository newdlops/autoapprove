import Foundation

/// A currently visible, numbered single-choice menu. Permission dialogs keep
/// their existing approval path; transcript examples and incomplete menus do not qualify.
public struct TerminalChoiceQuestion: Codable, Equatable, Sendable {
    public var id: String
    public var question: String
    public var options: [String]
    public var selected: Int
    public var reply: QuestionReply?
    public var numericSubmission: Bool? = nil

    private static func codexHeader(_ lines: [String]) -> Int? {
        lines.lastIndex { $0.range(of: #"^Question\s+[1-9][0-9]?/[1-9][0-9]?\s+\([0-9]{1,2}\s+unanswered\)$"#, options: .regularExpression) != nil }
    }
    private static let codexOptionsFooter = #"^tabtoaddnotes\|?entertosubmit(?:answer|all)(?:\|?←/→tonavigatequestions)?\|?esctointerrupt$"#
    private static func codexFooter(_ lines: [String], after last: Int, optionsOnly: Bool) -> Int? {
        guard last + 1 < lines.count else { return nil }
        let pattern = optionsOnly ? codexOptionsFooter : #"^(?:tabtoaddnotes\|?entertosubmit(?:answer|all)(?:\|?←/→tonavigatequestions)?\|?esctointerrupt|taboresctoclearnotes\|?entertosubmit(?:answer|all)|entertosubmit(?:answer|all)(?:\|?ctrl\+p/ctrl\+nchangequestion)?\|?esctointerrupt)$"#
        return ((last + 1)..<lines.count).first { index in
            let compact = lines[index...].joined().lowercased().filter { !$0.isWhitespace }
            return compact.range(of: pattern, options: .regularExpression) != nil
        }
    }
    /// Notes/freeform overlays also block ordinary conversational messages;
    /// they must never receive a queued question's quoted reply as editor input.
    public static func hasCodexOverlay(_ screen: String) -> Bool {
        hasCodexOverlay(prepared: DetectionLines(screen))
    }
    static func hasCodexOverlay(prepared: DetectionLines) -> Bool {
        let suffix = prepared.normalizedSuffix(300)
        let lines = suffix.rows.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let header = codexHeader(lines), !prepared.hasOpenCodeFence(beforeSuffixRow: header, in: suffix) else { return false }
        return codexFooter(lines, after: header, optionsOnly: false) != nil
    }
    public func command(for index: Int) -> String {
        numericSubmission == true ? "digit:\(index + 1)" : String(index - selected)
    }
    public func targetIndex(command: String) -> Int? {
        if numericSubmission == true {
            guard command.hasPrefix("digit:"), let number = Int(command.dropFirst(6)), (1...9).contains(number) else { return nil }
            return number - 1
        }
        return Int(command).map { selected + $0 }
    }

    public static func detect(_ screen: String, agent: AgentKind) -> Self? {
        let prepared = DetectionLines(screen)
        let prompt = PromptDetector.detect(screen, agent: agent, prepared: prepared)
        guard prompt == nil else { return nil }
        let request = QuestionDetector.detect(agent: agent, prepared: prepared)
        return detect(screen, agent: agent, prepared: prepared, permissionPrompt: prompt, request: request)
    }

    static func detect(_ screen: String, agent: AgentKind, prepared: DetectionLines,
                       permissionPrompt: ApprovalPrompt?, request: PendingScreenRequest?) -> Self? {
        guard agent != .shell, permissionPrompt == nil else { return nil }
        guard request?.phase != .approval else { return nil }
        let suffix = prepared.normalizedSuffix(300), raw = suffix.rows
        let lines = raw.map { $0.trimmingCharacters(in: .whitespaces) }
        let header = agent == .codex ? codexHeader(lines) : nil
        guard let first = lines.lastIndex(where: { $0.range(of: #"^[›❯»>]?\s*1\.\s+"#, options: .regularExpression) != nil }),
              let last = lines.lastIndex(where: PromptDetector.isOption),
              let footer = PromptDetector.dialogFooterStart(in: lines, after: last) ?? (header != nil ? codexFooter(lines, after: last, optionsOnly: true) : nil) else { return nil }
        let numericSubmission = header != nil && codexFooter(lines, after: last, optionsOnly: true) == footer
        let start: Int
        if numericSubmission, let header { start = header }
        else if let heading = request?.summary.components(separatedBy: .newlines).first, let headingIndex = lines[..<first].lastIndex(of: heading) { start = headingIndex }
        else {
            guard let headingIndex = lines[..<first].lastIndex(where: { !$0.isEmpty && !$0.allSatisfy({ "─━╌- ".contains($0) }) }) else { return nil }
            var index = headingIndex
            while index > 0, !lines[index - 1].isEmpty, !PromptDetector.isOption(lines[index - 1]), !lines[index - 1].allSatisfy({ "─━╌- ".contains($0) }) { index -= 1 }
            start = index
        }
        guard !prepared.hasOpenCodeFence(beforeSuffixRow: start, in: suffix),
              !lines[start...].contains(where: { $0.contains("```") }) else { return nil }
        var options: [String] = [], selected: Int?
        let indents = raw.map { $0.prefix(while: \.isWhitespace).count }
        let optionRows = Set(PromptDetector.optionRows(Array(lines[..<footer]), indents: Array(indents[..<footer]), from: first))
        for index in first..<footer {
            let line = lines[index]
            if line.isEmpty || line.allSatisfy({ "─━╌- ".contains($0) }) { continue }
            if optionRows.contains(index), let prefix = line.range(of: PromptDetector.optionPrefix, options: .regularExpression) {
                let number = line[prefix].filter(\.isNumber)
                guard Int(number) == options.count + 1, options.count < 20 else { return nil }
                if "›❯»>".contains(line.first ?? " ") {
                    guard selected == nil else { return nil }; selected = options.count
                }
                options.append(String(line[prefix.upperBound...]))
            } else {
                guard !options.isEmpty else { return nil }
                options[options.count - 1] += " " + line
            }
        }
        let question = lines[start..<first].filter { !$0.isEmpty }.joined(separator: "\n")
        let permissionLabels = options.allSatisfy({ $0.range(of: #"(?i)^(?:yes|no|allow|deny|cancel|always allow|don't allow|예|아니요|허가|불허)(?:\b|\s|$)"#, options: .regularExpression) != nil })
        guard options.count >= 2, let selected, options.allSatisfy({ !$0.isEmpty }),
              !numericSubmission || options.count <= 9,
              lines[start...].joined(separator: "\n").count < 4000,
              !permissionLabels || AutomaticQuestionDecision.currentModelIndex(question: question, options: options) != nil else { return nil }
        // Include visible conversation context to distinguish identical labels
        // in successive questions. Selection movement and line wrapping are cosmetic.
        let all = prepared.raw
        let suffixStart = max(0, all.count - raw.count)
        let context = all[..<(suffixStart + footer)].map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let prefix = trimmed.range(of: PromptDetector.optionPrefix, options: .regularExpression) {
                return trimmed[prefix].filter(\.isNumber) + "." + String(trimmed[prefix.upperBound...])
            }
            return trimmed
        }.joined().filter { !$0.isWhitespace }
        let footerIdentity = lines[footer...].joined().lowercased().filter { !$0.isWhitespace && $0 != "|" }
        var result = Self(id: PromptDetector.fingerprint(agent.rawValue + context + footerIdentity), question: question, options: options, selected: selected)
        result.numericSubmission = numericSubmission ? true : nil
        return result
    }
}
