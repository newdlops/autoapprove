import Foundation

public struct AttentionRequest: Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let project: String
    public let agent: String
    public let summary: String

    public static func needsAttention(_ session: AgentSession, paused: Bool) -> Bool {
        !candidates(session, paused: paused).isEmpty
    }

    public static func candidates(_ session: AgentSession, paused: Bool) -> [(key: String, summary: String)] {
        guard session.agent != .shell, session.phase != .ended else { return [] }
        var result = session.unansweredQuestions.map { (key: $0.id, summary: $0.summary) }
        if let summary = session.pendingSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           session.phase == .input || (session.phase == .approval && (session.pendingInTerminal || !session.automatic || paused)) {
            let normalized = summary.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let alreadyQueued = session.phase == .input && session.questions.contains {
                let title = $0.title.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                return normalized.hasPrefix(title)
            }
            if !alreadyQueued { result.append((session.pendingRequestID ?? normalized, summary)) }
        }
        return result
    }

    /// Only an exact live session may be opened; never match by project or reused TTY.
    public static func target(sessionID: String, sessions: [AgentSession]) throws -> AgentSession {
        guard let session = sessions.first(where: { $0.id == sessionID && $0.phase != .ended }) else {
            throw AppError.message("이 알림의 세션이 종료되었습니다. 관리 창에서 현재 세션을 확인해주세요.")
        }
        guard session.canReveal else {
            throw AppError.message("이 세션의 터미널 연결을 찾지 못했습니다. 연결 설정을 확인해주세요.")
        }
        return session
    }
}

/// Keeps one notification per question, including concurrent non-blocking questions.
/// A later identical question receives a new ID after resolution or a new tool use.
public struct AttentionTracker {
    private var active: [String: AttentionRequest] = [:]
    public init() {}

    public mutating func update(_ snapshot: EngineSnapshot) -> [AttentionRequest] {
        var next: [String: AttentionRequest] = [:], requests: [AttentionRequest] = []
        for session in snapshot.sessions {
            for candidate in AttentionRequest.candidates(session, paused: snapshot.paused) {
                let key = session.id + "\n" + candidate.key
                guard next[key] == nil else { continue }
                let request = AttentionRequest(id: active[key]?.id ?? "attention-" + UUID().uuidString,
                    sessionID: session.id, project: session.project, agent: session.agent.title, summary: candidate.summary)
                next[key] = request; requests.append(request)
            }
        }
        active = next
        return requests
    }
}
