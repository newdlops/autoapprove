import Foundation

public struct ActivityObservation: Equatable, Sendable {
    public let phase: SessionPhase
    public let detail: String
    public var monitoring = false
}

/// Screen inference is deliberately limited to a visible composer and known CLI hints.
/// Silence, a motionless spinner, and low CPU usage are not completion signals.
public enum ActivityDetector {
    public static func detect(_ screen: String, agent: AgentKind) -> ActivityObservation {
        detect(screen, agent: agent, permissionPrompt: { PromptDetector.detect(screen, agent: agent) != nil })
    }

    /// Idle confirmation depends on the same visible tail as the activity
    /// detector. Hashing a multi-megabyte scrollback on each unchanged prompt
    /// adds work without changing the readiness decision.
    static func readinessFingerprint(_ screen: String) -> String {
        readinessFingerprint(tail: nonemptyTail(screen))
    }

    static func readinessFingerprint(tail: [String]) -> String {
        PromptDetector.fingerprint(tail.joined(separator: "\n"))
    }

    /// An already-analyzed frame can share its permission result without changing detection order.
    static func detect(_ screen: String, agent: AgentKind, permissionPrompt: () -> Bool) -> ActivityObservation {
        let tail = agent == .shell ? [] : nonemptyTail(screen)
        return detect(screen, agent: agent, preparedTail: tail, permissionPrompt: permissionPrompt)
    }

    /// Reuse the visible rows when an analysis also needs the readiness fingerprint.
    static func detect(_ screen: String, agent: AgentKind, preparedTail tail: [String],
                       permissionPrompt: () -> Bool) -> ActivityObservation {
        let unknown = ActivityObservation(phase: .unknown, detail: "현재 화면에서 작업 중인지 입력 대기 중인지 확인하지 못했습니다.")
        guard agent != .shell, !tail.isEmpty else { return unknown }
        let bottom = tail.suffix(8).joined(separator: "\n")
        if matches(bottom, #"(?i)(?:esc|ctrl\+c) to (?:interrupt|stop)|tab to queue"#) {
            return ActivityObservation(phase: .working, detail: "CLI 화면에 실행 중인 작업 또는 중단 안내가 표시되어 있습니다.")
        }
        if permissionPrompt() {
            return ActivityObservation(phase: .approval, detail: "실행 권한에 대한 응답을 기다리고 있습니다.")
        }
        if agent == .codex, bottom.contains("Giving this request a little extra thought"), !bottom.contains("```") {
            let dialog=bottom.components(separatedBy:.whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator:" ")
            let message="1. Dismiss and keep waiting 2. Learn more No action is required. Codex will keep waiting, and this menu will close when the response is ready."
            if ["›","»"].contains(where: { dialog.hasSuffix("Giving this request a little extra thought \($0) "+message) }) {
                return ActivityObservation(phase:.working,detail:"Codex가 서버 응답을 기다리고 있습니다. 응답이 준비되면 작업을 계속합니다.")
            }
        }
        let compact = agent == .claude ? compactClaudeFooter(tail) : nil
        let background = compact?.monitoring == true || matches(bottom, #"(?i)\b[1-9][0-9]* (?:background (?:tasks?|terminals?|processes?|monitors?)|running tasks?)\b|running in (?:the )?background"#)
        let unresolved = background ? ActivityObservation(phase: .working, detail: "백그라운드 작업이 보이지만 다음 지시를 받을 준비가 됐는지 아직 확인하지 못했습니다.") : unknown
        let glyphs = agent == .claude ? "❯" : "›»"
        guard let index = tail.lastIndex(where: { line in line.first.map { glyphs.contains($0) } == true }) else { return unresolved }
        let prompt = String(tail[index].dropFirst()).trimmingCharacters(in: .whitespaces)
        // The CLI replaces its shortcut hint with activity counts when space is
        // tight. Rejoin only this fixed suffix, never freeform project/body rows.
        let footer = compact.map { value in
            value.start > index ? Array(tail[(index+1)..<value.start])+[value.text] : Array(tail.dropFirst(index+1))
        } ?? Array(tail.dropFirst(index+1))
        let isHint: (String) -> Bool = { line in
            matches(line, #"\?\s*for shortcuts|shift\+tab to cycle"#)
                || (agent == .claude && isCompactClaudeFooter(line))
                || (agent == .codex && matches(line, #"[0-9]{1,3}% (?:context )?left|^[^·]+ · [~/]"#))
        }
        let isDecoration: (String) -> Bool = { isHint($0) || isBackgroundHint($0) || $0.allSatisfy { "─━╌- ".contains($0) } }
        guard !footer.isEmpty, footer.count <= 6, !bottom.contains("```"),
              footer.contains(where: isHint),
              (footer.allSatisfy({ isDecoration($0) || isStatusFooter($0,agent:agent) })
                || (agent == .claude && isWrappedClaudeStatusFooter(footer,decoration:isDecoration))
                || (agent == .codex && CodexResumeCheck.goalStalled(tail))) else { return unresolved }
        // Option menus and questions also use prompt glyphs; they are never idle composers.
        if matches(prompt, #"^[0-9]+\."#) { return unknown }
        let placeholder = agent == .codex
            ? matches(prompt, #"^(?:Ask Codex to do anything|Ask anything|Explain this codebase|Summarize recent commits|Find and fix a bug in @filename|Write tests for @filename|Improve documentation in @filename|Implement \{feature\}|Use /skills to list available skills)$"#)
            : matches(prompt, #"^Try [\"“].+[\"”]$"#)
        guard prompt.isEmpty || placeholder else {
            return ActivityObservation(phase: .input, detail: "CLI 입력창에 내용이 있습니다. 터미널에서 확인해주세요.")
        }
        // The card's numeric shortcuts own an empty composer. Terminal reflow
        // can split even a label's letters; tolerate whitespace only inside this
        // fixed negative guard, never in command identities or arbitrary text.
        // A real draft disables these shortcuts and keeps the input phase above.
        if compact != nil, matches(tail.joined(separator:" "), #"(?i)\b1\s*(?:t\s*o\s*)?r\s*e\s*v\s*i\s*e\s*w\s*·\s*2\s*(?:t\s*o\s*)?s\s*e\s*n\s*d\s*·\s*0\s*(?:t\s*o\s*)?d\s*i\s*s\s*m\s*i\s*s\s*s\b"#) {return unknown}
        return ActivityObservation(phase: .idle,
            detail: background ? "다음 지시를 받을 수 있습니다. 백그라운드 작업이 남아 있어 모니터링 중으로 표시합니다." : "CLI의 입력 대기 화면을 반복 확인했습니다. 새 지시를 기다리고 있습니다.",
            monitoring: background)
    }

    private static func isBackgroundHint(_ line: String) -> Bool {
        matches(line, #"(?i)^[•·⏵▶↳\s]*[0-9]+ (?:background (?:tasks?|terminals?|processes?|monitors?)|running tasks?)\b"#)
    }

    private static func isCompactClaudeFooter(_ line:String) -> Bool {
        matches(line, #"^⏵⏵ auto mode on · (?:[1-9][0-9]{0,2} shells?(?: · [1-9][0-9]{0,2} feedback drafts?)?|[1-9][0-9]{0,2} feedback drafts?)$"#)
    }

    /// At most three short rows and seven fixed-grammar candidates. A missing
    /// suffix, unknown item, or unrelated row cannot be discarded as decoration.
    private static func compactClaudeFooter(_ lines:[String]) -> (start:Int,text:String,monitoring:Bool)? {
        for start in max(0,lines.count-3)..<lines.count where lines[start].hasPrefix("⏵⏵ auto mode on ·") {
            let rows=Array(lines[start...])
            guard rows.allSatisfy({$0.utf16.count<=128}),rows.reduce(0,{$0+$1.utf16.count})<=256 else {continue}
            var candidates=[rows[0]]
            for row in rows.dropFirst() {candidates=candidates.flatMap {[$0+row,$0+" "+row]}}
            if let text=candidates.first(where:isCompactClaudeFooter) {
                return (start,text,matches(text,#" · [1-9][0-9]{0,2} shells?(?: ·|$)"#))
            }
        }
        return nil
    }

    /// Restore wrapped structured model/usage fields only after both freeform
    /// fields are complete. Never join across a hint/rule or rewrite the screen
    /// used for permissions; freeform continuations remain unverified.
    private static func isWrappedClaudeStatusFooter(_ footer:[String],decoration:(String)->Bool) -> Bool {
        let indices=footer.indices.filter { !decoration(footer[$0]) }
        guard (2...4).contains(indices.count),let first=indices.first,let last=indices.last,
              last-first+1==indices.count else {return false}
        let rows=Array(footer[first...last])
        // A question between branch fragments is indistinguishable from a hard
        // line break in plain text. Do not concatenate those freeform fields.
        guard rows.allSatisfy({$0.utf16.count<=512}),rows.reduce(0,{$0+$1.utf16.count})<=1024,
              rows[0].filter({$0=="|"}).count>=2 else {return false}
        // At most eight bounded candidates; trimmed rows may have lost a space.
        var candidates=[rows[0]]
        for row in rows.dropFirst() {candidates=candidates.flatMap {[$0+row,$0+" "+row]}}
        return candidates.contains {isStatusFooter($0,agent:.claude)}
    }

    /// A user status line can sit between the composer and the CLI's own hint.
    /// These supplemental rows never establish a ready composer on their own.
    private static func isStatusFooter(_ line: String, agent: AgentKind) -> Bool {
        switch agent {
        case .claude:
            guard line.contains("|") else { return false }
            // Usage metadata can be absent, or show both five-hour and weekly
            // quotas. It remains supplemental to a visible composer and hint.
            return matches(line, #"^[^|\r\n]{1,200}\|[^|\r\n]{1,200}\|\s*(?:Opus|Sonnet|Haiku) [0-9]+(?:\.[0-9]+){0,2}(?:\s*\|\s*ctx (?:100|[0-9]{1,2})%(?:\s*\|\s*(?:5h (?:100|[0-9]{1,2})%\s+)?7d (?:100|[0-9]{1,2})%)?)?\s*$"#)
        case .codex:
            return line.hasPrefix("⚠") && matches(line, #"^⚠\s*[1-9][0-9]{0,2} warnings? · f2 to view$"#)
        case .shell: return false
        }
    }

    /// Only the last 18 nonempty rows participate. Walk backwards to avoid splitting
    /// ignored scrollback. Small frames keep the cheaper whole-split path; storage
    /// metadata selects it without first converting a large Foundation string to UTF-8.
    static func nonemptyTail(_ screen: String) -> [String] {
        let small = screen.isContiguousUTF8 ? screen.utf8.count <= 4096 : screen.utf16.count <= 2048
        if small {
            return Array(screen.components(separatedBy: .newlines).reversed().lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(18).reversed())
        }
        let scalars = screen.unicodeScalars, newlines = CharacterSet.newlines
        var position = scalars.endIndex, end = position, rows: [String] = []
        rows.reserveCapacity(18)
        while position != scalars.startIndex {
            let previous = scalars.index(before: position)
            if newlines.contains(scalars[previous]) {
                let row = String(scalars[position..<end]).trimmingCharacters(in: .whitespaces)
                if !row.isEmpty {
                    rows.append(row)
                    if rows.count == 18 { return Array(rows.reversed()) }
                }
                end = previous
            }
            position = previous
        }
        let row = String(scalars[..<end]).trimmingCharacters(in: .whitespaces)
        if !row.isEmpty { rows.append(row) }
        return Array(rows.reversed())
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

public struct ActivityTracker {
    private var candidate: (fingerprint: String, generation: String, since: Date)?
    public init() {}

    public mutating func observe(_ screen: String, agent: AgentKind, generation: String, at now: Date = Date()) -> ActivityObservation {
        let tail = agent == .shell ? [] : ActivityDetector.nonemptyTail(screen)
        let observation = ActivityDetector.detect(screen, agent: agent, preparedTail: tail) {
            PromptDetector.detect(screen, agent: agent) != nil
        }
        return observe(observation, fingerprint: ActivityDetector.readinessFingerprint(tail: tail), agent: agent, generation: generation, at: now)
    }

    /// Time and generation are checked on every observation, even when parsing is reused.
    mutating func observe(_ observation: ActivityObservation, fingerprint: @autoclosure () -> String, agent: AgentKind, generation: String, at now: Date) -> ActivityObservation {
        guard observation.phase == .idle else { candidate = nil; return observation }
        // Background output may keep changing while the ready composer stays usable.
        // Consecutive idle observations still require the same CLI generation.
        let fingerprint = observation.monitoring ? "monitoring:\(agent.rawValue)" : fingerprint()
        if let candidate, candidate.fingerprint == fingerprint, candidate.generation == generation {
            if now.timeIntervalSince(candidate.since) >= 2 { return observation }
        } else {
            candidate = (fingerprint, generation, now)
        }
        return ActivityObservation(phase: .unknown, detail: "입력 대기 화면이 유지되는지 확인하고 있습니다.")
    }
}
