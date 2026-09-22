import Foundation

public struct AttentionRequest: Equatable, Identifiable {
    public enum Kind: Equatable { case question, completion }
    public let id: String
    public let sessionID: String
    public let project: String
    public let agent: String
    public let summary: String
    public var kind: Kind = .question
    public var notificationKey: String = ""
    public var originSessionID: String?
    public var title: String { project + (kind == .completion ? " · 작업 완료" : " · 응답 필요") }

    public static func completions(_ snapshot: EngineSnapshot, at now: Date = Date()) -> [AttentionRequest] {
        snapshot.sessions.flatMap { session in
            ([session] + session.backgroundChildren).compactMap { source -> AttentionRequest? in
                guard source.agent != .shell, source.phase != .ended, let completion = source.completion,
                      now.timeIntervalSince(completion.date) <= 300 else { return nil }
                return AttentionRequest(id: "completion-" + PromptDetector.fingerprint(source.id + "\n" + completion.id),
                    sessionID: session.id, project: session.project, agent: session.agent.title,
                    summary: completion.summary, kind: .completion, notificationKey: SessionNotice.key(.completion, completion.id), originSessionID: source.id)
            }
        }
    }

    public static func needsAttention(_ session: AgentSession, paused: Bool) -> Bool {
        !candidates(session, paused: paused).isEmpty
    }

    public struct Candidate: Equatable {
        public var key: String
        public var summary: String
        public var sourceSessionID: String
        public var sourceKey: String
    }

    public static func candidates(_ session: AgentSession, paused: Bool) -> [Candidate] {
        guard session.agent != .shell, session.phase != .ended else { return [] }
        let phase = session.ownPhase ?? session.phase
        let automatic = session.automatic && !paused
        var result = session.unansweredQuestions.filter {
            !automatic || $0.automation?.phase != .scheduled
        }.map { Candidate(key: $0.id, summary: $0.summary, sourceSessionID: session.id, sourceKey: $0.id) }
        if let approvals = session.claudeApprovals, !approvals.isEmpty {
            // A live five-second countdown needs no manual attention. Keep the request
            // visible in the detail view, but share this rule across banners and badges.
            result += approvals.filter { !$0.sending && (!automatic || $0.automaticAt == nil) }
                .map { Candidate(key: "bridge:" + $0.id, summary: $0.summary, sourceSessionID: session.id, sourceKey: "bridge:" + $0.id) }
        } else if let summary = session.pendingSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           phase == .input || (phase == .approval && (session.pendingInTerminal || !session.automatic || paused)) {
            let normalized = summary.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let alreadyQueued = phase == .input && session.questions.contains {
                let title = $0.title.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                return normalized.hasPrefix(title)
            }
            if !alreadyQueued {
                let key = session.pendingRequestID ?? normalized
                result.append(Candidate(key: key, summary: summary, sourceSessionID: session.id, sourceKey: key))
            }
        }
        for child in session.backgroundChildren {
            result += candidates(child, paused: paused).map { candidate in
                var value = candidate; value.key = child.id + "\n" + value.key; return value
            }
        }
        return result
    }

    /// Old child notifications may open their verified live main, never a similar project or TTY.
    public static func target(sessionID: String, sessions: [AgentSession]) throws -> AgentSession {
        guard let session = sessions.first(where: {
            $0.phase != .ended && ($0.id == sessionID || $0.backgroundChildren.contains { $0.id == sessionID && $0.phase != .ended })
        }) else {
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
                    sessionID: session.id, project: session.project, agent: session.agent.title, summary: candidate.summary,
                    notificationKey: SessionNotice.key(.question, candidate.sourceKey), originSessionID: candidate.sourceSessionID)
                next[key] = request; requests.append(request)
            }
        }
        active = next
        return requests
    }
}
