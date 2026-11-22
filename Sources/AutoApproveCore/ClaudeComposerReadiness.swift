import Foundation

public enum ClaudeComposerReadiness {
    package static func containsOnly(_ text: String, screen: String) -> Bool {
        let rows = PromptDetector.normalizedLines(screen).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let i = rows.lastIndex(where: { $0.hasPrefix("❯") }), i > 0, rows[i - 1].hasPrefix("───"),
              let end = rows[(i + 1)...].firstIndex(where: { $0.count >= 3 && $0.allSatisfy { $0 == "─" } }) else { return false }
        let footer = rows.dropFirst(end + 1).filter { !$0.isEmpty }
        guard footer.count <= 8, !footer.contains(where: { $0.hasPrefix("───") }) else { return false }
        let first = String(rows[i].dropFirst()).trimmingCharacters(in: .whitespaces)
        let parts = [first] + Array(rows[(i + 1)..<end])
        return parts.joined() == text || parts.joined(separator: " ") == text
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
        func rule(_ row: String) -> Bool {
            row.count >= 3 && row.allSatisfy { "─━╌".contains($0) }
        }
        func border(_ row: String) -> Bool {
            if rule(row) { return true }
            let line = "─━╌"
            guard row.prefix(3).allSatisfy({ line.contains($0) }), let last = row.last, line.contains(last) else { return false }
            let labels = row.split(whereSeparator: { line.contains($0) })
            guard labels.count == 1, let label = labels.first, label.hasPrefix(" "), label.hasSuffix(" ") else { return false }
            let name = label.trimmingCharacters(in: .whitespaces)
            return !name.isEmpty && name.count <= 40
        }
        guard border(rows[prompt - 1]), border(rows[prompt + 1]) else { return false }
        let footer = rows.dropFirst(prompt + 2)
        return footer.count <= 8 && !footer.contains(where: rule) && !footer.contains(where: { $0.contains("```") }) &&
            footer.reduce(0, { $0 + $1.utf16.count }) <= 2048
    }
}
