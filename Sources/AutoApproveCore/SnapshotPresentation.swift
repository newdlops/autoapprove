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
