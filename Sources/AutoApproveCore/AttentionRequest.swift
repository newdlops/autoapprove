import Foundation

public struct AttentionRequest: Equatable, Identifiable {
    public enum Kind: Equatable { case question, completion, interruption, systemChange }
    public let id: String
    public let sessionID: String
    public let project: String
    public let agent: String
    public let summary: String
    public var kind: Kind = .question
    public var notificationKey: String = ""
    public var originSessionID: String?
    public var title: String { project + (kind == .systemChange ? " · 시스템 변경 경고" : kind == .completion ? " · 작업 완료" : kind == .interruption ? " · 작업 중단" : " · 응답 필요") }

    public static func completions(_ snapshot: EngineSnapshot, at now: Date = Date()) -> [AttentionRequest] {
        var requests: [AttentionRequest] = []
        func appendCompletion(from source: AgentSession, presentedAs session: AgentSession) {
            guard source.agent != .shell, source.phase != .ended, let completion = source.completion,
                  now.timeIntervalSince(completion.date) <= 300 else { return }
            requests.append(AttentionRequest(id: "completion-" + PromptDetector.fingerprint(source.id + "\n" + completion.id),
                sessionID: session.id, project: session.project, agent: session.agent.title,
                summary: completion.summary, kind: .completion, notificationKey: SessionNotice.key(.completion, completion.id), originSessionID: source.id))
        }
        for session in snapshot.sessions {
            appendCompletion(from: session, presentedAs: session)
            for child in session.backgroundChildren {
                appendCompletion(from: child, presentedAs: session)
            }
        }
        return requests
    }

    public static func needsAttention(_ session: AgentSession, paused: Bool) -> Bool {
        var collector = CandidateCollector(includeDetails: false, stopAfterFirst: true)
        collectCandidates(session, paused: paused, prefix: "", into: &collector)
        return collector.count > 0
    }

    public static func count(_ session: AgentSession, paused: Bool) -> Int {
        var collector = CandidateCollector(includeDetails: false)
        collectCandidates(session, paused: paused, prefix: "", into: &collector)
        return collector.count
    }

    public struct Candidate: Equatable {
        public var key: String
        public var summary: String
        public var sourceSessionID: String
        public var sourceKey: String
        public var kind: Kind = .question
    }

    private struct CandidateCollector {
        let includeDetails: Bool
        var stopAfterFirst = false
        var count = 0
        var values: [Candidate] = []
        var finished: Bool { stopAfterFirst && count > 0 }
        mutating func append(_ candidate: @autoclosure () -> Candidate, prefix: String) {
            count += 1
            guard includeDetails else { return }
            var value = candidate()
            if !prefix.isEmpty { value.key = prefix + value.key }
            values.append(value)
        }
    }

    public static func candidates(_ session: AgentSession, paused: Bool) -> [Candidate] {
        var collector = CandidateCollector(includeDetails: true)
        collectCandidates(session, paused: paused, prefix: "", into: &collector)
        return collector.values
    }

    /// Eligibility stays in one traversal. Counts do not build question summaries,
    /// arrays or child-key prefixes; existence checks stop at the first request.
    private static func collectCandidates(_ session: AgentSession, paused: Bool, prefix: String,
                                          into collector: inout CandidateCollector) {
        guard session.agent != .shell else { return }
        if let safety = session.systemSafety {
            let key = "systemSafety:" + safety.id
            let read: Bool
            if let notices = session.notices, !notices.isEmpty {
                let noticeKey = SessionNotice.key(.question, key)
                read = notices.first(where: { $0.sourceKey == noticeKey })?.isRead == true
            } else { read = false }
            if !read {
                collector.append(Candidate(key: key, summary: safety.risk.title + " · " + safety.message,
                    sourceSessionID: session.id, sourceKey: key, kind: .systemChange), prefix: prefix)
                if collector.finished { return }
            }
        }
        if let error = session.interruption, error.needsAttention, error.acknowledgedAt == nil {
            collector.append(Candidate(key: "interruption:" + error.id, summary: error.kind.title + " · " + error.detail,
                sourceSessionID: session.id, sourceKey: "interruption:" + error.id, kind: .interruption), prefix: prefix)
            if collector.finished { return }
        }
        guard session.phase != .ended else { return }
        let phase = session.ownPhase ?? session.phase
        let automatic = session.automatic && !paused
        for question in session.questions where question.needsAnswer && (!automatic || question.automation?.phase != .scheduled) {
            collector.append(Candidate(key: question.id, summary: question.summary,
                sourceSessionID: session.id, sourceKey: question.id), prefix: prefix)
            if collector.finished { return }
        }
        if let approvals = session.claudeApprovals, !approvals.isEmpty {
            // A live five-second countdown needs no manual attention. Keep the request
            // visible in the detail view, but share this rule across banners and badges.
            for approval in approvals where approval.systemCommandRisk == nil && !approval.sending && (!automatic || approval.automaticAt == nil) {
                collector.append(Candidate(key: "bridge:" + approval.id, summary: approval.summary,
                    sourceSessionID: session.id, sourceKey: "bridge:" + approval.id), prefix: prefix)
                if collector.finished { return }
            }
        } else if session.systemCommandRisk == nil, let summary = session.pendingSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           phase == .input || (phase == .approval && (session.pendingInTerminal || !session.automatic || paused)) {
            // Canonical text is needed only for queued-title comparison or a
            // missing request ID. Count-only projections never materialize keys.
            let comparesQueuedTitles = phase == .input && !session.questions.isEmpty
            let needsFallbackKey = collector.includeDetails && session.pendingRequestID == nil
            let normalized = comparesQueuedTitles || needsFallbackKey
                ? summary.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") : ""
            let alreadyQueued = comparesQueuedTitles && session.questions.contains {
                let title = $0.title.precomposedStringWithCanonicalMapping.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                return normalized.hasPrefix(title)
            }
            if !alreadyQueued {
                let key = session.pendingRequestID ?? normalized
                collector.append(Candidate(key: key, summary: summary, sourceSessionID: session.id, sourceKey: key), prefix: prefix)
                if collector.finished { return }
            }
        }
        for child in session.backgroundChildren {
            let childPrefix = collector.includeDetails ? prefix + child.id + "\n" : ""
            collectCandidates(child, paused: paused, prefix: childPrefix, into: &collector)
            if collector.finished { return }
        }
    }

    /// Old child notifications may open their verified live main, never a similar project or TTY.
    public static func target(sessionID: String, sessions: [AgentSession]) throws -> AgentSession {
        if let old = sessions.first(where:{$0.id == sessionID && $0.phase == .ended}),
           let resumed = old.interruption?.resumedSessionID,
           let live = sessions.first(where:{$0.id == resumed && $0.phase != .ended && $0.canReveal}) { return live }
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

/// Resolves an attention notification's absolute delivery time once, so a
/// waiting request can sleep until its deadline instead of polling every second.
public enum AttentionNotificationSchedule {
    public static func deadline(kind: AttentionRequest.Kind, observedAt: Date, questionDelay: Int) -> Date {
        let delay: Int
        switch kind {
        case .interruption, .systemChange: delay = 0
        case .completion: delay = 3
        case .question: delay = min(max(questionDelay, 1), 3600)
        }
        return observedAt.addingTimeInterval(TimeInterval(delay))
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
                    kind: candidate.kind,
                    notificationKey: SessionNotice.key(.question, candidate.sourceKey), originSessionID: candidate.sourceSessionID)
                next[key] = request; requests.append(request)
            }
        }
        active = next
        return requests
    }
}
