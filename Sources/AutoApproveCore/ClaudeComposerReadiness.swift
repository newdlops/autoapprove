import Foundation

/// Input readiness is separate from activity inference: a custom status line can
/// make activity unknown without putting any text inside Claude's composer.
public enum ClaudeComposerReadiness {
    public static func isEmpty(_ screen: String) -> Bool {
        let rows = ActivityDetector.nonemptyTail(screen)
        let tail = rows.joined(separator: "\n")
        guard !rows.isEmpty, !RemoteMessageReadiness.hasMenu(screen, agent: .claude) else { return false }
        // Retain the established unframed composer/known-footer formats.
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
        // Both borders must be visible. Text on a following line before the
        // closing border is a multiline draft, never a status-line continuation.
        guard rule(rows[prompt - 1]), rule(rows[prompt + 1]) else { return false }
        let footer = rows.dropFirst(prompt + 2)
        // Outside the closed composer, model/usage/reset text is supplemental.
        // Do not widen ActivityDetector or infer completion from these rows.
        return footer.count <= 8 && !footer.contains(where: rule) && !footer.contains(where: { $0.contains("```") }) &&
            footer.reduce(0, { $0 + $1.utf16.count }) <= 2048
    }
}
