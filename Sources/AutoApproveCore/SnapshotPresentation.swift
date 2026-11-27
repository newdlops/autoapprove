import Foundation
import Combine

// Observation timestamps are still part of the domain snapshot and its normal
// equality: freshness checks and remote clients must receive every observation.
// Only consumers of presentation content may omit this one heartbeat field.
extension AgentSession {
    fileprivate var presentationContent: Self {
        var value = self
        if value.codexActivity != nil {
            value.codexActivity?.observedAt = Date(timeIntervalSinceReferenceDate: 0)
        }
        value.backgroundSessions = backgroundSessions?.map(\.presentationContent)
        return value
    }
}

extension EngineSnapshot {
    public func hasSamePresentation(as other: Self) -> Bool {
        var left = self, right = other
        left.sessions = sessions.map(\.presentationContent)
        right.sessions = other.sessions.map(\.presentationContent)
        return left == right
    }
}

extension SessionGroupLiveSession {
    public func hasSamePresentation(as other: Self) -> Bool {
        var left = self, right = other
        left.session = session.presentationContent
        right.session = other.session.presentationContent
        return left == right
    }
}

extension ApprovalEngine {
    /// Emits the original snapshot on every content change, including stale or
    /// recovered activity, questions, read receipts, health and group changes.
    /// A timestamp label should subscribe to its own field on `$snapshot`.
    public var presentationUpdates: AnyPublisher<EngineSnapshot, Never> {
        $snapshot.presentationChanges()
    }
}

extension Publisher where Output == EngineSnapshot, Failure == Never {
    public func presentationChanges() -> AnyPublisher<EngineSnapshot, Never> {
        removeDuplicates { $0.hasSamePresentation(as: $1) }.eraseToAnyPublisher()
    }
}

extension AgentSession {
    package func projectedCodexActivity(now: Date = Date(), conversationID: String? = nil,
                                        terminal: ActivityObservation? = nil) -> Self {
        guard agent == .codex, phase != .ended, codexApprovalBinding != nil || codexActivity != nil else { return self }
        var session = self
        let activity = codexActivity
        let sourceID = codexApprovalBinding?.threadID ?? activity?.parent.id
        let sameConversation = conversationID.map { sourceID?.caseInsensitiveCompare($0) == .orderedSame } ?? true
        if sameConversation, var current = activity, (0..<12).contains(now.timeIntervalSince(current.observedAt)),
           sourceID?.caseInsensitiveCompare(current.parent.id) == .orderedSame {
            if current.parent.phase == .unknown, let terminal { current.parent.phase = terminal.phase }
            session.ownPhase = current.parent.phase
            session.phase = current.phase
            session.activityDetail = current.summary
            session.backgroundMonitoring = current.children.contains { $0.phase == .working } || terminal?.monitoring == true
        } else {
            session.codexActivity = nil
            session.ownPhase = terminal?.phase
            session.phase = terminal?.phase ?? .unknown
            session.backgroundMonitoring = terminal?.monitoring == true
            session.activityDetail = terminal?.detail ?? "Codex의 실시간 상태를 확인하고 있습니다."
        }
        session.idleSince = nil
        return session
    }

    package func projectedClaudeActivity(_ activity: ClaudeSessionActivity?, lastHook: Date?, now: Date = Date()) -> Self {
        guard agent == .claude, [.working, .idle, .unknown].contains(phase),
              !pendingInTerminal, pendingRequestID == nil, osPermissionWaiting != true,
              let activity, activity.changedAt <= now,
              activity.changedAt > max(lastActivity, lastHook ?? .distantPast),
              activity.status == "idle" || activity.status == "busy" else { return self }
        let next: SessionPhase = activity.status == "idle" ? .idle : .working
        guard phase != next else { return self }
        var projected = self
        projected.setPhase(next, detail: next == .idle ? "Claude가 다음 지시를 기다리고 있습니다." : "Claude가 작업 중입니다.", at: activity.changedAt)
        return projected
    }
}
