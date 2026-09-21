import Foundation

public struct ActivityObservation: Equatable {
    public let phase: SessionPhase
    public let detail: String
}

/// Screen inference is deliberately limited to a visible composer and known CLI hints.
/// Silence, a motionless spinner, and low CPU usage are not completion signals.
public enum ActivityDetector {
    public static func detect(_ screen: String, agent: AgentKind) -> ActivityObservation {
        let unknown = ActivityObservation(phase: .unknown, detail: "현재 화면에서 작업 중인지 입력 대기 중인지 확인하지 못했습니다.")
        guard agent != .shell else { return unknown }
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let tail = Array(lines.filter { !$0.isEmpty }.suffix(18))
        guard !tail.isEmpty else { return unknown }
        let bottom = tail.suffix(8).joined(separator: "\n")
        if matches(bottom, #"(?i)(?:esc|ctrl\+c) to (?:interrupt|stop)|tab to queue|[1-9][0-9]* (?:background tasks?|background terminals?|running tasks?)|running in (?:the )?background"#) {
            return ActivityObservation(phase: .working, detail: "CLI 화면에 실행 중인 작업 또는 중단 안내가 표시되어 있습니다.")
        }
        if PromptDetector.detect(screen, agent: agent) != nil {
            return ActivityObservation(phase: .approval, detail: "실행 권한에 대한 응답을 기다리고 있습니다.")
        }
        let glyphs = agent == .claude ? "❯" : "›»"
        guard let index = tail.lastIndex(where: { line in line.first.map { glyphs.contains($0) } == true }) else { return unknown }
        let prompt = String(tail[index].dropFirst()).trimmingCharacters(in: .whitespaces)
        let footer = Array(tail.dropFirst(index + 1))
        let isHint: (String) -> Bool = { line in
            matches(line, #"\?\s*for shortcuts|shift\+tab to cycle"#)
                || (agent == .codex && matches(line, #"[0-9]{1,3}% (?:context )?left|^[^·]+ · [~/]"#))
        }
        guard !footer.isEmpty, footer.count <= 4, !bottom.contains("```"),
              footer.contains(where: isHint),
              footer.allSatisfy({ isHint($0) || $0.allSatisfy { "─━╌- ".contains($0) } }) else { return unknown }
        // Option menus and questions also use prompt glyphs; they are never idle composers.
        if matches(prompt, #"^[0-9]+\."#) { return unknown }
        let placeholder = agent == .codex
            ? matches(prompt, #"^(?:Ask Codex to do anything|Ask anything|Explain this codebase|Summarize recent commits|Find and fix a bug in @filename|Write tests for @filename|Improve documentation in @filename|Implement \{feature\}|Use /skills to list available skills)$"#)
            : matches(prompt, #"^Try [\"“].+[\"”]$"#)
        guard prompt.isEmpty || placeholder else {
            return ActivityObservation(phase: .input, detail: "CLI 입력창에 내용이 있습니다. 터미널에서 확인해주세요.")
        }
        return ActivityObservation(phase: .idle, detail: "CLI의 입력 대기 화면을 반복 확인했습니다. 새 지시를 기다리고 있습니다.")
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

public struct ActivityTracker {
    private var candidate: (fingerprint: String, generation: String, since: Date)?
    public init() {}

    public mutating func observe(_ screen: String, agent: AgentKind, generation: String, at now: Date = Date()) -> ActivityObservation {
        let observation = ActivityDetector.detect(screen, agent: agent)
        guard observation.phase == .idle else { candidate = nil; return observation }
        let fingerprint = PromptDetector.fingerprint(screen)
        if let candidate, candidate.fingerprint == fingerprint, candidate.generation == generation {
            if now.timeIntervalSince(candidate.since) >= 2 { return observation }
        } else {
            candidate = (fingerprint, generation, now)
        }
        return ActivityObservation(phase: .unknown, detail: "입력 대기 화면이 유지되는지 확인하고 있습니다.")
    }
}
