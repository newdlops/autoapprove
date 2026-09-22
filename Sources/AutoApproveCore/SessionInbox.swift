import Foundation

public struct SessionNotice: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case question, completion }
    public var id: String
    public var sourceKey: String
    public var kind: Kind
    public var summary: String
    public var date: Date
    public var isRead: Bool
    public var title: String { kind == .completion ? "작업 완료" : "응답 필요" }

    public static func key(_ kind: Kind, _ identifier: String) -> String {
        kind.rawValue + ":" + PromptDetector.fingerprint(identifier)
    }
}

/// Read receipts and unread events are independent of whether a question still needs an answer.
public struct SessionInbox: Codable, Equatable {
    public struct Candidate {
        public var key: String
        public var kind: SessionNotice.Kind
        public var summary: String
        public init(key: String, kind: SessionNotice.Kind, summary: String) {
            self.key = key; self.kind = kind; self.summary = summary
        }
    }
    private struct Active: Codable, Equatable {
        var id = UUID().uuidString
        var observedAt: Date
        var posted = false
        var acknowledged = false
    }
    private var active: [String: Active] = [:]
    public private(set) var entries: [SessionNotice] = []
    public init() {}

    @discardableResult public mutating func update(_ candidates: [Candidate], at date: Date = Date(), reconcilesAbsence: Bool = true) -> Bool {
        let previous = self
        let keys = Set(candidates.map(\.key))
        // An initial process scan has not read the questions yet. Keep restored receipts
        // until a real observation can tell us that the previous request has gone away.
        if reconcilesAbsence { active = active.filter { keys.contains($0.key) } }
        for candidate in candidates {
            var event = active[candidate.key] ?? Active(observedAt: date)
            let delay: TimeInterval = candidate.kind == .completion ? 3 : 0.8
            if !event.posted && date.timeIntervalSince(event.observedAt) >= delay {
                entries.insert(SessionNotice(id: event.id, sourceKey: candidate.key, kind: candidate.kind,
                    summary: String(candidate.summary.prefix(600)), date: date, isRead: event.acknowledged), at: 0)
                event.posted = true
            }
            active[candidate.key] = event
        }
        entries = Array(entries.prefix(50))
        return self != previous
    }

    @discardableResult public mutating func markRead() -> Bool {
        let previous = self
        for index in entries.indices { entries[index].isRead = true }
        for key in Array(active.keys) { active[key]?.acknowledged = true }
        return self != previous
    }

    public func isRead(_ sourceKey: String) -> Bool {
        active[sourceKey]?.acknowledged ?? entries.first(where: { $0.sourceKey == sourceKey })?.isRead ?? false
    }
}
