import Foundation
import CryptoKit

public struct ApprovalPrompt: Equatable {
    public var summary: String
    public var answer: String
    public var fingerprint: String
    public var dialog: String
    public var identity: String { PromptDetector.fingerprint(dialog) }
}

public enum PromptDetector {
    public static func fingerprint(_ screen: String) -> String {
        SHA256.hash(data: Data(screen.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Matches complete, active CLI permission dialogs. Arbitrary yes/no text is never sufficient.
    public static func detect(_ screen: String, agent: AgentKind) -> ApprovalPrompt? {
        guard agent != .shell else { return nil }
        let rawLines = normalizedLines(screen)
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let promptIndex = lines.lastIndex(where: { line in permissionMarkers(agent).contains { line.hasPrefix($0) } }) else { return nil }
        // A long command can push its title beyond the old 32-line window.
        guard lines.count - promptIndex <= 300 else { return nil }
        let dialog = Array(lines[promptIndex...])
        guard let selectedYes = dialog.firstIndex(where: { $0.range(of: #"^[›❯»>]\s*1\.\s+"#, options: .regularExpression) != nil }) else { return nil }
        let lastOption = dialog.lastIndex(where: isOption) ?? selectedYes
        guard let footerStart = dialogFooterStart(in: dialog, after: lastOption) else { return nil }
        let optionLines = dialog[selectedYes...lastOption].filter(isOption)
        guard optionLines.filter({ $0.range(of: #"^[›❯»>]"#, options: .regularExpression) != nil }).count == 1 else { return nil }
        var labels: [String] = []
        for line in dialog[selectedYes..<footerStart] {
            if isOption(line) {
                let prefix = "^[›❯»>]?\\s*" + String(labels.count + 1) + #"\.\s+"#
                guard let range = line.range(of: prefix, options: .regularExpression) else { return nil }
                labels.append(String(line[range.upperBound...]))
            } else if !line.isEmpty {
                guard line.range(of: #"^[›❯»>]"#, options: .regularExpression) == nil else { return nil }
                // Narrow terminal windows can wrap a permission scope onto another line.
                labels[labels.count - 1] += " " + line
            }
        }
        guard YesNoConfirmation.singleApprovalIndex(labels) == 0 else { return nil }
        let summary = dialog.prefix(selectedYes).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !dialog.contains(where: { $0.contains("```") }), !summary.isEmpty,
              lines[..<promptIndex].filter({ $0.hasPrefix("```") }).count % 2 == 0 else { return nil }
        // Claude prints the command/edit before its confirmation heading. Keep that context in validation.
        let start = agent == .claude ? 0 : promptIndex
        let context = rawLines[start..<(promptIndex + selectedYes)].joined(separator: "\n")
        return ApprovalPrompt(summary: String(context.suffix(4000)), answer: "1", fingerprint: fingerprint(screen), dialog: rawLines[start...].joined(separator: "\n"))
    }

    public static func normalizedLines(_ screen: String) -> [String] {
        var lines = screen.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines
    }
    static func permissionMarkers(_ agent: AgentKind) -> [String] {
        agent == .codex
            ? ["Would you like to run the following command?", "Would you like to make the following edits?"]
            : ["Do you want to proceed?", "Do you want to make this edit", "Do you want to create", "Do you want to allow"]
    }
    static func isOption(_ line: String) -> Bool {
        line.range(of: #"^[›❯»>]?\s*[1-9][0-9]?\.\s+"#, options: .regularExpression) != nil
    }
    static func isDialogFooter(_ line: String) -> Bool {
        line.range(of: #"(?i)^(?:(?:press )?enter to (?:confirm|select|submit)|esc to cancel|ctrl-g to edit|tab/arrow keys to navigate)"#, options: .regularExpression) != nil
            || line.allSatisfy { "─━╌- ".contains($0) }
    }

    /// The final option and the keyboard hint can both wrap in a narrow terminal.
    /// Require the entire remaining hint so later output cannot revive a stale dialog.
    static func dialogFooterStart(in lines: [String], after lastOption: Int) -> Int? {
        guard lastOption + 1 < lines.count else { return nil }
        let action = #"(?:(?:press\s+)?enter\s+to\s+(?:confirm|select|submit)|esc\s+to\s+cancel|ctrl-g\s+to\s+edit|tab/arrow\s+keys\s+to\s+navigate)"#
        let pattern = "(?i)^" + action + #"(?:(?:\s*(?:[,·•|/]|or|and)\s*|\s+)"# + action + #")*[.!]?$"#
        guard let start = ((lastOption + 1)..<lines.count).first(where: {
            lines[$0].range(of: #"(?i)^(?:press|enter|esc|ctrl-g|tab/arrow)(?:\s|$)"#, options: .regularExpression) != nil
        }) else { return nil }
        let hint = lines[start...].filter { !$0.isEmpty && !$0.allSatisfy { "─━╌- ".contains($0) } }.joined(separator: " ")
        return hint.range(of: pattern, options: .regularExpression) != nil ? start : nil
    }
}
