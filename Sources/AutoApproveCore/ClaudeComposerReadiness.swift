import Foundation

public enum ClaudeComposerReadiness {
    static let submitLineEndings = ["\r", "\n", "\r\n"]

    @MainActor package static func matchesBridgeDraft(_ text: String, visibleMatch: Bool,
                                                      read: (String) async -> String?) async -> Bool {
        let first = await read(text)
        if first == "matchingDraft" { return true }
        guard visibleMatch else { return false }
        if first == "draft" { return true }
        guard first == "differentDraft" else { return false }
        for ending in submitLineEndings {
            guard !Task.isCancelled else { return false }
            let state = await read(text + ending)
            if state == "matchingDraft" { return true }
            if state != "differentDraft" { return false }
        }
        return false
    }

    private static func rule(_ row: String) -> Bool {
        row.count >= 3 && row.allSatisfy { "─━╌".contains($0) }
    }
    private static func border(_ row: String) -> Bool {
        if rule(row) { return true }
        let line = "─━╌"
        guard row.count >= 3, row.prefix(3).allSatisfy({ line.contains($0) }), let last = row.last, line.contains(last) else { return false }
        let labels = row.split(whereSeparator: { line.contains($0) })
        guard labels.count == 1, let label = labels.first, label.hasPrefix(" "), label.hasSuffix(" ") else { return false }
        let name = label.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && name.count <= 40
    }

    package static func containsOnly(_ text: String, screen: String) -> Bool {
        let rows = PromptDetector.normalizedLines(screen).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let i = rows.lastIndex(where: { $0.hasPrefix("❯") }), i > 0, border(rows[i - 1]),
              let end = rows[(i + 1)...].firstIndex(where: border) else { return false }
        let footer = rows.dropFirst(end + 1).filter { !$0.isEmpty }
        guard footer.count <= 8, !footer.contains(where: border) else { return false }
        let first = String(rows[i].dropFirst()).trimmingCharacters(in: .whitespaces)
        var parts = [first] + Array(rows[(i + 1)..<end])
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        var remaining = text[...]
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty else { return false }
            if index > 0, remaining.first == " " { remaining = remaining.dropFirst() }
            guard remaining.hasPrefix(part) else { return false }
            remaining = remaining.dropFirst(part.count)
        }
        return remaining.isEmpty
    }

    package static func framedCandidate(_ screen: String) -> String? {
        let ns = screen as NSString
        let marker = ns.range(of: "❯", options: .backwards)
        guard marker.location != NSNotFound else { return nil }
        let range = ns.lineRange(for: marker)
        let line = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.first == "❯", line.dropFirst().first?.isWhitespace == true else { return nil }
        let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard (2...256).contains(body.count), body.first?.isLetter == true,
              !body.contains("❯"), body.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let cleared = ns.replacingCharacters(in: range, with: "❯\n")
        guard isEmpty(cleared), !RemoteMessageReadiness.hasMenu(screen, agent: .claude),
              ActivityDetector.detect(screen, agent: .claude).phase != .working else { return nil }
        let rows = ActivityDetector.nonemptyTail(cleared)
        guard let i = rows.lastIndex(of: "❯"), i > 0, i + 1 < rows.count,
              rows[i - 1].hasPrefix("───"), rows[i + 1].hasPrefix("───"),
              rows[i + 1].allSatisfy({ $0 == "─" }) else { return nil }
        return body
    }

    static func emptyInterruptComposer(_ screen: String) -> Bool {
        let rows = ActivityDetector.nonemptyTail(screen)
        guard let index = rows.lastIndex(where: { $0.hasPrefix("❯") }), rows[index] == "❯",
              index > 0, index + 1 < rows.count else { return false }
        return border(rows[index - 1]) && border(rows[index + 1])
    }

    static func feedbackToDismiss(_ screen: String, tail: [String]? = nil) -> String? {
        let rows = tail ?? ActivityDetector.nonemptyTail(screen)
        guard let feedback = feedbackShortcut(rows) else { return nil }
        let prepared = DetectionLines(screen), suffix = prepared.normalizedSuffix(64)
        guard let prompt = suffix.rows.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "❯" }),
              !prepared.hasOpenCodeFence(beforeSuffixRow: prompt, in: suffix) else { return nil }
        return feedback
    }

    private static func feedbackShortcut(_ rows: [String]) -> String? {
        guard let prompt = rows.lastIndex(where: { $0.hasPrefix("❯") }), rows[prompt] == "❯",
              prompt > 0, prompt + 1 < rows.count, border(rows[prompt - 1]), border(rows[prompt + 1]) else { return nil }
        let footer = rows.dropFirst(prompt + 2)
        guard footer.count <= 8, !footer.contains(where: { border($0) || $0.contains("```") || $0.contains("Enter to select") || $0.contains("Esc to cancel") }) else { return nil }
        if let status = footer.indices.last, footer[status].contains("feedback draft"),
           footer[status].range(of: #"\b[1-9][0-9]* feedback drafts?$"#, options: .regularExpression) != nil {
            let shortcuts = footer[..<status].joined().filter { !$0.isWhitespace }
            if shortcuts == "1toreview·2tosend·0todismiss" {
                return "draft:" + (footer[status].components(separatedBy: "·").last ?? footer[status]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard footer.isEmpty || ActivityDetector.detect("", agent: .claude, preparedTail: rows, permissionPrompt: { false }).phase == .idle else { return nil }
        let before = rows.prefix(prompt - 1).suffix(10)
        guard let first = before.lastIndex(where: { $0.hasPrefix("● ") }),
              rows[..<first].filter({ $0.hasPrefix("```") }).count.isMultiple(of: 2) else { return nil }
        let panel = before[first...].joined(separator: " ").filter { !$0.isWhitespace }
        let headings = ["How is Claude doing this session? (optional)", "How did that compaction go? (optional)",
                        "How was Claude's recollection?", "How well is Claude following the instructions you gave earlier in this conversation? (optional)"]
        for heading in headings {
            let prefix = "●" + heading.filter { !$0.isWhitespace }
            guard panel.hasPrefix(prefix) else { continue }
            let choices = String(panel.dropFirst(prefix.count))
            if choices.range(of: #"^1:Bad2:Fine3:Good(?:4:Unsure)?0:(?:Dismiss|Skip)$"#, options: .regularExpression) != nil { return heading }
        }
        return nil
    }

    public static func isEmpty(_ screen: String) -> Bool {
        let rows = ActivityDetector.nonemptyTail(screen)
        let tail = rows.joined(separator: "\n")
        guard !rows.isEmpty, !RemoteMessageReadiness.hasMenu(screen, agent: .claude) else { return false }
        if ActivityDetector.detect(screen, agent: .claude).phase == .idle { return true }
        guard rows.suffix(8).joined(separator: "\n").range(of: #"(?i)(?:esc|ctrl\+c) to (?:interrupt|stop)|tab to queue"#, options: .regularExpression) == nil,
              tail.range(of: #"(?i)\b1\s*(?:t\s*o\s*)?r\s*e\s*v\s*i\s*e\s*w\s*·\s*2\s*(?:t\s*o\s*)?s\s*e\s*n\s*d\s*·\s*0\s*(?:t\s*o\s*)?d\s*i\s*s\s*m\s*i\s*s\s*s\b"#, options: .regularExpression) == nil else { return false }
        guard let prompt = rows.lastIndex(where: { $0.hasPrefix("❯") }), prompt > 0,
              prompt + 2 < rows.count else { return false }
        let text = String(rows[prompt].dropFirst()).trimmingCharacters(in: .whitespaces)
        guard text.isEmpty || text.range(of: #"^Try [\"“].+[\"”]$"#, options: .regularExpression) != nil else { return false }
        guard border(rows[prompt - 1]), border(rows[prompt + 1]) else { return false }
        let footer = rows.dropFirst(prompt + 2)
        return footer.count <= 8 && !footer.contains(where: rule) && !footer.contains(where: { $0.contains("```") }) &&
            footer.reduce(0, { $0 + $1.utf16.count }) <= 2048
    }
}
