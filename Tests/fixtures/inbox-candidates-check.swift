// BEGIN ORIGINAL SessionInbox
import AutoApproveCore
import Foundation

public struct ReferenceNotice: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case question, completion }
    public var id: String
    public var sourceKey: String
    public var kind: Kind
    public var summary: String
    public var date: Date
    public var isRead: Bool
    public var isInterruption: Bool? = nil
    public var isSystemSafety: Bool? = nil
    public var title: String { isSystemSafety == true ? "시스템 변경 경고" : isInterruption == true ? "작업 중단" : kind == .completion ? "작업 완료" : "응답 필요" }

    public static func key(_ kind: Kind, _ identifier: String) -> String {
        kind.rawValue + ":" + PromptDetector.fingerprint(identifier)
    }
}

/// Read receipts and unread events are independent of whether a question still needs an answer.
public struct ReferenceInbox: Codable, Equatable {
    public struct Candidate {
        public var key: String
        public var kind: ReferenceNotice.Kind
        public var summary: String
        public var isInterruption: Bool = false
        public var isSystemSafety: Bool = false
        public init(key: String, kind: ReferenceNotice.Kind, summary: String, isInterruption: Bool = false, isSystemSafety: Bool = false) {
            self.key = key; self.kind = kind; self.summary = summary; self.isInterruption = isInterruption; self.isSystemSafety = isSystemSafety
        }
    }
    private struct Active: Codable, Equatable {
        var id = UUID().uuidString
        var observedAt: Date
        var posted = false
        var acknowledged = false
    }
    private var active: [String: Active] = [:]
    public private(set) var entries: [ReferenceNotice] = []
    public init() {}

    @discardableResult public mutating func update(_ candidates: [Candidate], at date: Date = Date(), reconcilesAbsence: Bool = true) -> Bool {
        var changed = false
        let keys = Set(candidates.map(\.key))
        // An initial process scan has not read the questions yet. Keep restored receipts
        // until a real observation can tell us that the previous request has gone away.
        if reconcilesAbsence {
            let removed = active.keys.filter { !keys.contains($0) }
            for key in removed { active.removeValue(forKey:key) }
            changed = changed || !removed.isEmpty
        }
        for candidate in candidates {
            var event: Active
            if let existing = active[candidate.key] { event = existing }
            else { event = Active(observedAt: date); changed = true }
            let delay: TimeInterval = candidate.isSystemSafety ? 0 : candidate.kind == .completion ? 3 : 0.8
            if !event.posted && date.timeIntervalSince(event.observedAt) >= delay {
                entries.insert(ReferenceNotice(id: event.id, sourceKey: candidate.key, kind: candidate.kind,
                    summary: String(candidate.summary.prefix(600)), date: date, isRead: event.acknowledged,
                    isInterruption: candidate.isInterruption ? true : nil, isSystemSafety: candidate.isSystemSafety ? true : nil), at: 0)
                event.posted = true; changed = true
            }
            active[candidate.key] = event
        }
        if entries.count > 50 { entries.removeLast(entries.count - 50) }
        return changed
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
// END ORIGINAL SessionInbox
// BEGIN ORIGINAL AttentionRequest
import AutoApproveCore
import Foundation

public struct ReferenceAttention: Equatable, Identifiable {
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

    public static func completions(_ snapshot: EngineSnapshot, at now: Date = Date()) -> [ReferenceAttention] {
        var requests: [ReferenceAttention] = []
        func appendCompletion(from source: AgentSession, presentedAs session: AgentSession) {
            guard source.agent != .shell, source.phase != .ended, let completion = source.completion,
                  now.timeIntervalSince(completion.date) <= 300 else { return }
            requests.append(ReferenceAttention(id: "completion-" + PromptDetector.fingerprint(source.id + "\n" + completion.id),
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
public enum ReferenceSchedule {
    public static func deadline(kind: ReferenceAttention.Kind, observedAt: Date, questionDelay: Int) -> Date {
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
public struct ReferenceTracker {
    private var active: [String: ReferenceAttention] = [:]
    public init() {}

    public mutating func update(_ snapshot: EngineSnapshot) -> [ReferenceAttention] {
        var next: [String: ReferenceAttention] = [:], requests: [ReferenceAttention] = []
        for session in snapshot.sessions {
            for candidate in ReferenceAttention.candidates(session, paused: snapshot.paused) {
                let key = session.id + "\n" + candidate.key
                guard next[key] == nil else { continue }
                let request = ReferenceAttention(id: active[key]?.id ?? "attention-" + UUID().uuidString,
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
// END ORIGINAL AttentionRequest
import Foundation
import CryptoKit
import CoreFoundation
import AutoApproveCore

@main enum InboxOracle {
    struct Failure: Error { let message: String }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    struct Random {
        var value: UInt64
        mutating func next(_ limit: Int) -> Int { value = value &* 6364136223846793005 &+ 1442695040888963407; return Int((value >> 24) % UInt64(limit)) }
    }
    struct Input { let key: String, completion: Bool, summary: String, interruption: Bool, safety: Bool }
    static func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        value.dateEncodingStrategy = .millisecondsSince1970; return value
    }
    static func decoder() -> JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .millisecondsSince1970; return value }
    static func normalized<T: Encodable>(_ value: T, aliases: inout [String: String]) throws -> Data {
        func walk(_ value: Any, field: String = "") -> Any {
            if var string = value as? String {
                if field == "id" {
                    if aliases[string] == nil { aliases[string] = "occurrence-" + String(aliases.count) }
                    string = aliases[string]!
                }
                let units = Array(string.utf16).map { $0.littleEndian }
                return ["utf8": Data(string.utf8).base64EncodedString(),
                    "utf16": units.withUnsafeBytes { Data($0).base64EncodedString() }]
            }
            if let date = value as? Date { return ["date": date.timeIntervalSinceReferenceDate] }
            if let bool = value as? Bool { return bool }
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .dictionary {
                let pairs = mirror.children.map { Array(Mirror(reflecting: $0.value).children).map(\.value) }
                var result: [String: Any] = [:]
                for pair in pairs.sorted(by: { ($0[0] as! String) < ($1[0] as! String) }) {
                    let key = pair[0] as! String; result[key] = walk(pair[1])
                }
                return result
            }
            if mirror.displayStyle == .collection { return mirror.children.map { walk($0.value) } }
            if mirror.displayStyle == .optional { return mirror.children.first.map { walk($0.value, field: field) } ?? NSNull() }
            if mirror.displayStyle == .enum { return ["case": String(describing: value)] }
            var result: [String: Any] = [:]
            for child in mirror.children.sorted(by: { ($0.label ?? "") < ($1.label ?? "") }) {
                result[child.label!] = walk(child.value, field: child.label!)
            }
            return result
        }
        return try JSONSerialization.data(withJSONObject: walk(value), options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func encoded<T: Encodable>(_ value: T) -> Result<Data, NSError> {
        do { return .success(try encoder().encode(value)) } catch { return .failure(error as NSError) }
    }
    static func sameFailure(_ left: NSError, _ right: NSError) -> Bool { left.domain == right.domain && left.code == right.code }
    static func decoded<T: Decodable>(_ type: T.Type, data: Data) -> Result<T, NSError> {
        do { return .success(try decoder().decode(type, from: data)) } catch { return .failure(error as NSError) }
    }
    static func wireResult(_ data: Data, aliases: [String: String]) -> Result<Data, NSError> {
        do { return .success(try wire(data, aliases: aliases)) } catch { return .failure(error as NSError) }
    }
    static func wire(_ data: Data, aliases: [String: String]) throws -> Data {
        func walk(_ value: Any, field: String = "") -> Any {
            if field == "id", let string = value as? String { return aliases[string]! }
            if let values = value as? [Any] { return values.map { walk($0) } }
            if let fields = value as? [String: Any] {
                var result: [String: Any] = [:]; for key in fields.keys.sorted() { result[key] = walk(fields[key]!, field: key) }; return result
            }
            return value
        }
        return try JSONSerialization.data(withJSONObject: walk(JSONSerialization.jsonObject(with: data)), options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func foreign(_ units: [UInt16]) -> String {
        units.withUnsafeBufferPointer { unsafeBitCast(CFStringCreateWithCharacters(kCFAllocatorDefault, $0.baseAddress, $0.count)!, to: NSString.self) as String }
    }
    static let texts = ["", "simple", "é", "e\u{301}", "\0\u{1b}[31mred\r\n", "한글🙂\nchoice",
        String(repeating: "👩🏽‍💻e\u{301}한글", count: 220), foreign([0xd800, 65, 0xdc00, 0, 0xac00, 13, 10])]
    static func inboxCases(_ digest: inout SHA256) throws -> (steps: Int, encodingFailures: Int, wireFailures: Int, restoreFailures: Int, malformedPosted: Int) {
        var checks = 0, encodingFailures = 0, wireFailures = 0, restoreFailures = 0, malformedPostedCases = 0
        for bank in 0..<4 {
            var actual = SessionInbox(), original = ReferenceInbox(), aIDs: [String: String] = [:], oIDs: [String: String] = [:]
            var random = Random(value: 0x1791b0 + UInt64(bank)), clock = 1_000.0
            if bank > 0 {
                let entries: [[String: Any]] = (0..<(bank == 3 ? 55 : bank == 2 ? 50 : 0)).map {
                    ["id": "saved-\($0)", "sourceKey": "saved-key-\($0)", "kind": "question", "summary": String(decoding: texts[$0 % texts.count].utf8, as: UTF8.self), "date": 999_000.0, "isRead": $0.isMultiple(of: 2)]
                }
                let data = try JSONSerialization.data(withJSONObject: ["active": ["saved": ["id": "saved-active", "observedAt": 999_000.0, "posted": true, "acknowledged": true]], "entries": entries])
                actual = try decoder().decode(SessionInbox.self, from: data); original = try decoder().decode(ReferenceInbox.self, from: data)
            }
            for step in 0..<1_024 {
                try autoreleasepool {
                    if step % 29 == 13 && step % 128 != 30 {
                        try require(actual.markRead() == original.markRead(), "Read-change result differs")
                    } else if step % 31 == 17 && step % 128 != 30 {
                        switch (encoded(actual), encoded(original)) {
                        case (.success(let a), .success(let o)):
                            switch (decoded(SessionInbox.self, data: a), decoded(ReferenceInbox.self, data: o)) {
                            case (.success(let a), .success(let o)): actual = a; original = o
                            case (.failure(let a), .failure(let o)): try require(sameFailure(a, o), "Restoration decoding error differs"); restoreFailures += 1
                            default: throw Failure(message: "Only one inbox can be decoded for restoration")
                            }
                        case (.failure(let a), .failure(let o)): try require(sameFailure(a, o), "Restoration encoding error differs")
                        default: throw Failure(message: "Only one inbox can be encoded for restoration")
                        }
                    } else {
                        var inputs: [Input] = [], observed = random.next(4) != 0
                        if step == 0 { observed = false }
                        if step % 24 < 9 && step != 0 {
                            let offset = [0.0, 0.7, 0.8, 0.81, 3.0, 3.01, 4.0, 5.0, 6.0][step % 24]
                            clock = 1_000 + Double(step / 24) * 20 + offset
                            if step % 24 != 6 {
                                inputs = [.init(key: "question", completion: false, summary: texts[(step / 24) % texts.count], interruption: false, safety: false),
                                    .init(key: "completion", completion: true, summary: "done", interruption: false, safety: false)]
                            }
                        } else if step != 0 {
                            clock += [-4.0, 0, 0.2, 0.8, 3, 3.01, 10][random.next(7)]
                            inputs = (0..<random.next(8)).map { _ in
                                Input(key: "key:" + String(random.next(7)), completion: random.next(2) == 0,
                                    summary: texts[random.next(texts.count)], interruption: random.next(4) == 0, safety: random.next(5) == 0)
                            }
                        }
                        let postsMalformed = step % 128 == 30
                        if postsMalformed {
                            inputs = [.init(key: "malformed:\(step)", completion: false, summary: texts[7], interruption: false, safety: true)]
                        }
                        let time = Date(timeIntervalSince1970: clock)
                        let a = inputs.map { SessionInbox.Candidate(key: $0.key, kind: $0.completion ? .completion : .question, summary: $0.summary, isInterruption: $0.interruption, isSystemSafety: $0.safety) }
                        let o = inputs.map { ReferenceInbox.Candidate(key: $0.key, kind: $0.completion ? .completion : .question, summary: $0.summary, isInterruption: $0.interruption, isSystemSafety: $0.safety) }
                        try require(actual.update(a, at: time, reconcilesAbsence: observed) == original.update(o, at: time, reconcilesAbsence: observed), "Update-change result differs at \(bank)/\(step)")
                        if postsMalformed {
                            let repaired = String(decoding: texts[7].utf8, as: UTF8.self)
                            try require(actual.entries.first?.sourceKey == inputs[0].key && actual.entries.first?.summary.utf8.elementsEqual(repaired.utf8) == true,
                                "The original notice prefix must repair malformed source text identically")
                            malformedPostedCases += 1
                        }
                    }
                    let a = try normalized(actual, aliases: &aIDs), o = try normalized(original, aliases: &oIDs)
                    try require(a == o, "Exact full state, UTF-8 or UTF-16 differs at \(bank)/\(step)")
                    switch (encoded(actual), encoded(original)) {
                    case (.success(let a), .success(let o)):
                        switch (wireResult(a, aliases: aIDs), wireResult(o, aliases: oIDs)) {
                        case (.success(let a), .success(let o)): try require(a == o, "Exact serialized state differs")
                        case (.failure(let a), .failure(let o)): try require(sameFailure(a, o), "Wire serialization error differs"); wireFailures += 1
                        default: throw Failure(message: "Only one inbox has a serializable JSON state")
                        }
                    case (.failure(let a), .failure(let o)):
                        try require(sameFailure(a, o), "Encoding error differs"); encodingFailures += 1
                    default: throw Failure(message: "Only one inbox can encode its current state")
                    }
                    for key in ["question", "completion", "key:0", "key:6", "saved", "missing"] {
                        try require(actual.isRead(key) == original.isRead(key), "Read receipt differs")
                    }
                    digest.update(data: a); checks += 1
                }
            }
        }
        try require(malformedPostedCases == 32, "Explicit malformed-source notices must all be posted")
        return (checks, encodingFailures, wireFailures, restoreFailures, malformedPostedCases)
    }
    static func approval(_ index: Int) throws -> ClaudeApproval {
        let data = try JSONSerialization.data(withJSONObject: ["id": "approval:\(index)", "summary": "", "answer": "Allow",
            "isQuestion": index.isMultiple(of: 2), "sending": index.isMultiple(of: 3), "expiresAt": 1_800_000_000_000.0])
        var value = try decoder().decode(ClaudeApproval.self, from: data)
        value.summary = texts[index % texts.count]
        if index.isMultiple(of: 4) { value.automaticAt = Date(timeIntervalSince1970: 1_800_000_000) }
        if index.isMultiple(of: 5) { value.systemCommandRisk = SystemCommandRisk.detect("sudo id") }
        return value
    }
    static func session(_ index: Int, depth: Int = 0) throws -> AgentSession {
        var value = AgentSession(id: "fixture:\(index):\(depth)", agent: index % 5 == 0 ? .shell : index % 2 == 0 ? .claude : .codex,
            pid: Int32(900_000 + index), started: "fixture", tty: "/dev/fixture-\(index)", cwd: "/fixture/한글 project\(index % 3)", terminal: .terminal)
        let phases = [value.phase, .working, .input, .approval, .ended, .idle]
        value.phase = phases[index % phases.count]; value.automatic = index.isMultiple(of: 2)
        if index % 4 == 0 { value.ownPhase = .input }
        if index % 7 == 0 {
            value.systemSafety = SystemSafetyNotice(id: "safety:\(index)", risk: SystemCommandRisk.detect("sudo id")!, request: "Synthetic warning", at: Date(timeIntervalSince1970: 1_800_000_000))
            if index % 14 == 0 {
                let key = SessionNotice.key(.question, "systemSafety:safety:\(index)")
                var inbox = SessionInbox(); let c = SessionInbox.Candidate(key: key, kind: .question, summary: "Synthetic warning", isSystemSafety: true)
                inbox.update([c], at: Date(timeIntervalSince1970: 1_800_000_000)); inbox.markRead(); value.notices = inbox.entries
            }
        }
        if index % 3 == 0 {
            value.interruption = SessionInterruption(id: "error:\(index)", kind: .transport, detail: texts[index % texts.count], date: Date(timeIntervalSince1970: 1_800_000_000))
            if index % 9 == 0 { value.interruption?.acknowledgedAt = Date(timeIntervalSince1970: 1_800_000_001) }
            if index % 12 == 0 { value.interruption?.recoveredAt = Date(timeIntervalSince1970: 1_800_000_002) }
        }
        value.queuedQuestions = (0..<(index % 4)).map { offset in
            var q = QueuedQuestion(id: "q:\(index):\(offset)", threadID: "thread:\(index)", title: texts[(index + offset) % texts.count], options: ["One", "Two"])
            if (index + offset) % 3 == 0 { q.automation = .init(phase: .scheduled, deadline: Date(timeIntervalSince1970: 1_800_000_005), answer: "Yes") }
            if (index + offset) % 5 == 0 { q.reply = .init(phase: .queued, answer: "One", message: "Synthetic receipt") }
            return q
        }
        value.pendingSummary = index % 3 == 1 ? texts[index % texts.count] : index % 3 == 2 ? "Ordinary pending choice" : nil
        if index % 4 == 1 { value.pendingRequestID = "request:\(index)" }
        if index % 7 == 1 { value.claudeApprovals = try (0..<3).map { try approval(index + $0) } }
        if depth < 2 && index % 4 == 2 { value.backgroundSessions = try [session(index + 1, depth: depth + 1), session(index + 6, depth: depth + 1)] }
        return value
    }
    static func attentionCases(_ digest: inout SHA256) throws -> Int {
        var checks = 0
        for index in 0..<1_024 {
            for paused in [false, true] {
                try autoreleasepool {
                    let value = try session(index), actual = AttentionRequest.candidates(value, paused: paused), original = ReferenceAttention.candidates(value, paused: paused)
                    try require(actual.count == original.count && AttentionRequest.count(value, paused: paused) == ReferenceAttention.count(value, paused: paused)
                        && AttentionRequest.needsAttention(value, paused: paused) == ReferenceAttention.needsAttention(value, paused: paused), "Attention eligibility differs")
                    var records: [[String]] = []
                    for (a, o) in zip(actual, original) {
                        let left = [a.key, a.summary, a.sourceSessionID, a.sourceKey, String(describing: a.kind)]
                        let right = [o.key, o.summary, o.sourceSessionID, o.sourceKey, String(describing: o.kind)]
                        try require(zip(left, right).allSatisfy { $0.utf8.elementsEqual($1.utf8) && $0.utf16.elementsEqual($1.utf16) }, "Exact candidate key, summary, kind or source differs")
                        records.append(left)
                    }
                    let rawRecords = records.map { row in row.map { text in
                        let units = Array(text.utf16).map { $0.littleEndian }
                        return ["utf8": Data(text.utf8).base64EncodedString(), "utf16": units.withUnsafeBytes { Data($0).base64EncodedString() }]
                    } }
                    digest.update(data: try JSONSerialization.data(withJSONObject: rawRecords, options: [.sortedKeys, .withoutEscapingSlashes])); checks += 1
                }
            }
        }
        return checks
    }
    @MainActor static func main() throws {
        var digest = SHA256()
        let inbox: (steps: Int, encodingFailures: Int, wireFailures: Int, restoreFailures: Int, malformedPosted: Int)
        do { inbox = try inboxCases(&digest) } catch { throw Failure(message: "Inbox stage: \(error)") }
        let attention: Int
        do { attention = try attentionCases(&digest) } catch { throw Failure(message: "Attention stage: \(error)") }
        let permissionPrefix = try PermissionPrefixOracle.run()
        let modelWords = try ModelWordOracle.run()
        let decisions = try TypedDecisionOracle.run()
        let lifetime = try NoticeKeyCacheOracle.run()
        digest.update(data: Data(lifetime.digest.utf8))
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": true, "inboxSteps": inbox.steps, "attentionCases": attention, "permissionPrefixCases": permissionPrefix.cases, "permissionPrefixForeignInputs": permissionPrefix.foreignInputs, "permissionPrefixDigest": permissionPrefix.digest, "modelWordLinkedCoreCases": modelWords.linkedCoreCases, "modelWordCases": modelWords.cases, "modelWordForeignInputs": modelWords.foreignInputs, "modelWordDigest": modelWords.digest, "typedDecisionCases": decisions.typed, "jsonDecisionCases": decisions.json, "foreignDecisionInputs": decisions.foreignInputs, "decisionDigest": decisions.digest, "noticeKeyCacheCases": lifetime.steps, "noticeKeyCachePresent": lifetime.implementationPresent, "noticeKeyCacheCapacityExercised": lifetime.capacityReached, "noticeKeyCacheStateDigest": lifetime.digest,
            "encodingFailurePairs": inbox.encodingFailures, "wireFailurePairs": inbox.wireFailures, "restoreFailurePairs": inbox.restoreFailures, "explicitMalformedNotices": inbox.malformedPosted,
            "digest": hash, "exactSerializedState": true, "onlyUUIDsNormalizedAcrossSteps": true, "schemaAndReadFlagsPreserved": true,
            "originalTerminalActions": 0, "realPowerCommands": 0], options: [.sortedKeys]), as: UTF8.self))
    }
}
@MainActor enum NoticeKeyCacheOracle {
    struct Result { let steps: Int; let digest: String; let implementationPresent: Bool; let capacityReached: Bool }
    static func bytes(_ text: String) -> [String] {
        let units = Array(text.utf16).map { $0.littleEndian }
        return [Data(text.utf8).base64EncodedString(), units.withUnsafeBytes { Data($0).base64EncodedString() }]
    }
    static func object(_ engine: ApprovalEngine) -> (Bool, AnyObject?) {
        guard let field = Mirror(reflecting: engine).children.first(where: { $0.label == "noticeKeyCache" }) else { return (false, nil) }
        return (true, Mirror(reflecting: field.value).children.first.map { $0.value as AnyObject })
    }
    static func run() throws -> Result {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-notice-key-lifetime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = ProcessDiscovery.parse((0..<33).map {
            "\(980001+$0) 1 ttys\(800+$0) \(980001+$0) \(980001+$0) Mon Oct 12 09:00:00 2026 /fixture/codex"
        }.joined(separator: "\n"))
        let seeds = records.enumerated().map { index, record -> AgentSession in
            var value = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
                tty: "/dev/" + record.tty, cwd: "/fixture/notice-\(index)", terminal: .iterm)
            value.channel = .itermScreen; value.lastActivity = Date(timeIntervalSince1970: 1_800_000_000); return value
        }
        let power = PowerControl(read: { PowerReading() }, ruleInstalled: { false }, ruleFile: { false },
            installRule: { throw InboxOracle.Failure(message: "Forbidden power install") }, removeRule: { throw InboxOracle.Failure(message: "Forbidden power remove") },
            setSleepDisabled: { _ in throw InboxOracle.Failure(message: "Forbidden real power") },
            startGuard: { _, _ in throw InboxOracle.Failure(message: "Forbidden resident guard") })
        func make() throws -> ApprovalEngine {
            let engine = try ApprovalEngine(paths: AppPaths(directory: root),
                terminalReader: { _ in throw InboxOracle.Failure(message: "Forbidden original read") },
                claudeRegistryReader: { _ in [] }, processReader: { records }, powerControl: power,
                terminalInputAvailable: { false }, terminalInputIdentity: { _ in nil })
            engine.updateDiscovery(seeds, records: records)
            for row in seeds { engine.receiveScreen(sessionID: row.id,
                raw: "Synthetic output\n• Working (esc to interrupt)\n›\n? for shortcuts", generation: "fixture",
                at: Date(timeIntervalSince1970: 1_800_000_000)) }
            return engine
        }
        var engine = try make(); defer { engine.stop() }
        let implementationPresent = object(engine).0
        var digest = SHA256(), steps = 0, capacityReached = false, compareNotices = false
        func inspect(requireCache: Bool = false) throws {
            let current = engine.snapshot.sessions
            let sources = Mirror(reflecting: engine).children.first { $0.label == "sessions" }!.value as! [String: AgentSession]
            let inboxes = Mirror(reflecting: engine).children.first { $0.label == "inboxes" }!.value as! [String: SessionInbox]
            var activeTrace: [[String: Any]] = []
            var expected: [Data] = [], expectedNoticeKeys: [Data] = [], cacheEligible = false
            for row in sources.values.sorted(by: { $0.id < $1.id }) {
                for candidate in ReferenceAttention.candidates(row, paused: engine.snapshot.paused) {
                    expected.append(Data(candidate.key.utf8)); expectedNoticeKeys.append(Data(SessionNotice.key(.question, candidate.key).utf8))
                    cacheEligible = cacheEligible || (candidate.key.isContiguousUTF8 && candidate.key.utf8.count <= 256)
                }
                if let completion = row.completion, row.phase != .ended,
                   Date().timeIntervalSince(completion.date) <= 300 {
                    expected.append(Data(completion.id.utf8)); expectedNoticeKeys.append(Data(SessionNotice.key(.completion, completion.id).utf8))
                    cacheEligible = cacheEligible || (completion.id.isContiguousUTF8 && completion.id.utf8.count <= 256)
                }
            }
            for row in sources.values.sorted(by: { $0.id < $1.id }) {
                var wanted = Set(ReferenceAttention.candidates(row, paused: engine.snapshot.paused).map { ReferenceNotice.key(.question, $0.key) })
                if let completion = row.completion, row.phase != .ended, Date().timeIntervalSince(completion.date) <= 300 {
                    wanted.insert(ReferenceNotice.key(.completion, completion.id))
                }
                let data = try JSONEncoder().encode(inboxes[row.id] ?? SessionInbox())
                let active = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["active"] as! [String: Any]
                let actual = Set(active.keys)
                let observed = row.phase == .ended || (row.phase != .unknown && (row.agent != .codex || (row.codexQuestionsObservedAt != nil && row.codexQuestionsError == nil)))
                try InboxOracle.require(observed ? actual == wanted : wanted.isSubset(of: actual), "Actual inbox keys differ from original raw identifier policy")
                activeTrace.append(["id": bytes(row.id), "keys": actual.sorted(), "sourceQuestions": row.questions.map { bytes($0.id) }])
            }
            digest.update(data: try JSONSerialization.data(withJSONObject: activeTrace, options: [.sortedKeys, .withoutEscapingSlashes]))
            let state = object(engine)
            try InboxOracle.require(state.0 == implementationPresent, "Cache implementation presence changed")
            if let cache = state.1 {
                let cacheBytes = Mirror(reflecting: cache).children.first { $0.label == "identifierBytes" }!.value as! [UInt8]
                try InboxOracle.require(cacheBytes.count <= 96 * 256, "Packed identifier bytes exceeded the logical budget")
                var packedEnd = 0
                let fields = Mirror(reflecting: cache).children
                let entries = Array(Mirror(reflecting: fields.first { $0.label == "entries" }!.value).children)
                let buckets = fields.first { $0.label == "buckets" }!.value as! [UInt8]
                try InboxOracle.require(entries.count > 0 && entries.count <= 96 && buckets.count == 128, "Notice-key cache exceeded its fixed budget")
                let occupied = buckets.filter { $0 != 0 }
                try InboxOracle.require(occupied.count == entries.count && Set(occupied).count == entries.count
                    && occupied.allSatisfy { Int($0) <= entries.count }, "Cache bucket indices do not describe its live entries")
                if entries.count == 96 { capacityReached = true }
                for entry in entries {
                    let fields = Mirror(reflecting: entry.value).children
                    let offset = Int(fields.first { $0.label == "offset" }!.value as! UInt16)
                    let length = Int(fields.first { $0.label == "length" }!.value as! UInt16)
                    try InboxOracle.require(offset + length <= cacheBytes.count, "Packed identifier range exceeds its owned buffer")
                    let identifier = String(decoding: cacheBytes[offset..<(offset + length)], as: UTF8.self)
                    let key = fields.first { $0.label == "key" }!.value as! String
                    try InboxOracle.require(Set(fields.map { $0.label! }) == Set(["offset", "length", "key"]), "Entry unexpectedly retains an original String owner")
                    try InboxOracle.require(offset == packedEnd, "Unused identifier bytes were not compacted")
                    packedEnd += length
                    let completion = key.hasPrefix("completion:")
                    let expectedKey = SessionNotice.key(completion ? .completion : .question, identifier)
                    try InboxOracle.require(key.utf8.elementsEqual(expectedKey.utf8) && key.utf16.elementsEqual(expectedKey.utf16), "Cache returned a different original SHA key")
                    try InboxOracle.require(identifier.isContiguousUTF8 && identifier.utf8.count <= 256, "Cache retained an ineligible original identifier")
                    try InboxOracle.require(expected.contains(Data(identifier.utf8)), "Cache retained an identifier unused by the completed current pass")
                }
                try InboxOracle.require(packedEnd == cacheBytes.count, "Packed storage retains bytes outside its live entries")
            } else if implementationPresent && requireCache {
                try InboxOracle.require(!cacheEligible, "An eligible current notice cache was unexpectedly absent")
            }
            let rows: [[String: Any]] = current.sorted { $0.id < $1.id }.map { row in
                ["id": bytes(row.id), "phase": row.phase.rawValue, "automatic": row.automatic,
                 "questions": row.questions.map { ["id": bytes($0.id), "title": bytes($0.title), "needsAnswer": $0.needsAnswer] as [String: Any] },
                 "notices": (compareNotices ? (row.notices ?? []).filter { expectedNoticeKeys.contains(Data($0.sourceKey.utf8)) } : []).map { ["sourceKey": bytes($0.sourceKey), "kind": $0.kind.rawValue,
                    "summary": bytes($0.summary), "read": $0.isRead, "interruption": $0.isInterruption == true, "safety": $0.isSystemSafety == true] as [String: Any] }]
            }
            digest.update(data: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes])); steps += 1
        }
        func apply(_ identifiers: [[String]], unreadable: Bool = false) throws {
            let updates = seeds.enumerated().map { index, row -> CodexQuestionUpdate in
                if unreadable { return CodexQuestionUpdate(sessionID: row.id, questions: nil, error: "Synthetic source unavailable") }
                let values = identifiers[index].enumerated().map { offset, id in
                    QueuedQuestion(id: id, threadID: "fixture:" + row.id, title: "Synthetic choice \(offset)", options: ["Development", "Production"])
                }
                return CodexQuestionUpdate(sessionID: row.id, questions: values, threadID: "fixture:" + row.id)
            }
            engine.updateCodexQuestions(updates, at: Date(timeIntervalSince1970: 1_800_000_000)); try inspect()
        }
        let empty = Array(repeating: [String](), count: seeds.count)
        try apply(empty); try InboxOracle.require(object(engine).1 == nil, "Empty engine allocated a notice-key cache")
        func values(_ generation: Int, perSession: Int = 3) -> [[String]] {
            seeds.enumerated().map { index, _ in (0..<perSession).map { "question:native-heap:\(generation):\(index):\($0)" } }
        }
        try apply(values(0))
        for _ in 0..<8 { engine.refreshNotices(); try inspect(requireCache: true) }
        // Equal long values in new allocations must remain correct even if the
        // address hint misses. A following stable refresh must repopulate it.
        let copied = values(0).map { $0.map { String(decoding: Array($0.utf8), as: UTF8.self) } }
        try apply(copied); engine.refreshNotices(); try inspect()
        engine.refreshNotices(); try inspect(requireCache: true)
        if implementationPresent { try InboxOracle.require(capacityReached, "The real96-entry cache limit was never exercised") }
        try apply(empty, unreadable: true)
        for generation in 1...64 {
            var ids = values(generation, perSession: generation.isMultiple(of: 4) ? 5 : 3)
            if generation.isMultiple(of: 3) { for index in ids.indices where index.isMultiple(of: 2) { ids[index] = [] } }
            try apply(ids); engine.refreshNotices(); try inspect(requireCache: true)
        }
        let raw = InboxOracle.texts + ["é", "e\u{301}", String(repeating: "a", count: 255), String(repeating: "b", count: 256), String(repeating: "c", count: 257)]
        for (bank, text) in raw.enumerated() {
            var ids = empty
            ids[0] = ["native:\(bank):" + text]
            ids[1] = [NSAppleEventDescriptor(string: "event:\(bank):" + text).stringValue!]
            ids[2] = [InboxOracle.foreign(Array(("foreign:\(bank):" + text).utf16))]
            try apply(ids); engine.refreshNotices(); try inspect()
        }
        var capacityIDs = empty
        var oversized = String(); oversized.reserveCapacity(1_048_576); oversized.append("short-id-from-oversized-owner")
        capacityIDs[0] = [oversized]; try apply(capacityIDs); engine.refreshNotices(); try inspect(requireCache: true)
        capacityIDs[0] = [String(decoding: Array(oversized.utf8), as: UTF8.self)]; oversized = ""
        try apply(capacityIDs); engine.refreshNotices(); try inspect(requireCache: true)
        var edges = empty
        edges[0] = [String(repeating: "a", count: 256)]; edges[1] = [String(repeating: "a", count: 257)]
        edges[2] = [String(repeating: "b", count: 255)]; edges[3] = [""]; edges[4] = ["1234567"]; edges[5] = ["12345678"]; edges[6] = ["🙂🙂"]
        try apply(edges); engine.refreshNotices(); try inspect(requireCache: true)
        // Four sampled8-byte words are equal;byte64 differs in every128-byte ID.
        var colliding = empty
        for index in 0..<16 {
            var units = [UInt8](repeating: 120, count: 128); units[64] = UInt8(65 + index)
            colliding[index] = [String(decoding: units, as: UTF8.self)]
        }
        try apply(colliding); engine.refreshNotices(); try inspect(requireCache: true)
        try apply(empty)
        let shared = "codex:cache-kind-thread:same-identifier"
        let question = QueuedQuestion(id: shared, threadID: "cache-kind-thread", title: "Same ID,independent kinds", options: ["Development", "Production"])
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: seeds[0].id, questions: [question],
            turn: CodexTurnState(threadID: "cache-kind-thread", turnID: "same-identifier", status: "inProgress"))], at: Date(timeIntervalSince1970: 1_800_000_000)); try inspect()
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: seeds[0].id, questions: [question],
            turn: CodexTurnState(threadID: "cache-kind-thread", turnID: "same-identifier", status: "completed",
                completedAt: Date(timeIntervalSince1970: 1_800_000_000), summary: "Synthetic completion"))], at: Date(timeIntervalSince1970: 1_800_000_000)); try inspect()
        try InboxOracle.require(engine.snapshot.sessions.first { $0.id == seeds[0].id }?.completion?.id == shared, "Actual completion cache path was not exercised")
        engine.refreshNotices(); try inspect(requireCache: true)
        if let cache = object(engine).1 {
            let cacheBytes = Mirror(reflecting: cache).children.first { $0.label == "identifierBytes" }!.value as! [UInt8]
            let entries = Mirror(reflecting: Mirror(reflecting: cache).children.first { $0.label == "entries" }!.value).children
            var kinds = Set<UInt8>()
            for entry in entries {
                let fields = Mirror(reflecting: entry.value).children
                let offset = Int(fields.first { $0.label == "offset" }!.value as! UInt16)
                let length = Int(fields.first { $0.label == "length" }!.value as! UInt16)
                try InboxOracle.require(offset + length <= cacheBytes.count, "Packed identifier range exceeds its owned buffer")
                let identifier = String(decoding: cacheBytes[offset..<(offset + length)], as: UTF8.self)
                if identifier.utf8.elementsEqual(shared.utf8) { kinds.insert((fields.first { $0.label == "key" }!.value as! String).utf8.first!) }
            }
            try InboxOracle.require(kinds == Set([UInt8(99), UInt8(113)]), "Question/completion keys were merged in the cache")
        }
        engine.updateCodexQuestions([CodexQuestionUpdate(sessionID: seeds[0].id, questions: nil, error: "Synthetic completion source unavailable")]); try inspect()
        try apply(values(999, perSession: 1))
        Thread.sleep(forTimeInterval: 1.0); engine.refreshNotices(); compareNotices = true; try inspect()
        try engine.markNotificationsRead(seeds[0].id); try inspect()
        let first = object(engine).1
        _ = try engine.resetAutomation(seeds[0].id); try inspect()
        if let first, let next = object(engine).1 { try InboxOracle.require(first !== next, "Single-session reset kept the old memoization object") }
        let second = object(engine).1
        _ = try engine.resetAllAutomation(); try inspect()
        if let second, let next = object(engine).1 { try InboxOracle.require(second !== next, "All-session reset kept the old memoization object") }
        engine.stop(); try InboxOracle.require(object(engine).1 == nil, "Stopping retained the notice-key cache")
        engine = try make(); try apply(values(999, perSession: 1)); try inspect()
        try apply(empty); try InboxOracle.require(object(engine).1 == nil, "Removing every notice retained cache storage")
        engine.updateDiscovery([], records: []); try inspect()
        return Result(steps: steps, digest: digest.finalize().map { String(format: "%02x", $0) }.joined(), implementationPresent: implementationPresent, capacityReached: capacityReached)
    }
}

// BEGIN ORIGINAL AutomaticQuestionDecision
import AutoApproveCore
import Foundation

/// Automatic questions have two explicit policies: confirm a permission, or
/// retain a model that the question itself identifies as the current model.
public struct BoundOriginalQuestionDecision {
    public enum Kind: Equatable, Sendable { case confirmation, keepCurrentModel }
    public let question: String
    public let answer: String
    public let kind: Kind

    public static func detect(_ question: QueuedQuestion) -> Self? {
        detect(["questions": [["question": question.title, "multiSelect": question.multiSelect ?? false,
                                "options": question.options.map { ["label": $0] }]]])
    }

    public static func detect(_ input: JSONObject) -> Self? {
        if let answers = input["answers"] {
            guard let answers = answers as? JSONObject, answers.isEmpty else { return nil }
        }
        guard let questions = input["questions"] as? [JSONObject], questions.count == 1,
              let item = questions.first, let title = item["question"] as? String,
              let options = item["options"] as? [JSONObject] else { return nil }
        if let multi = item["multiSelect"] { guard let value = multi as? Bool, !value else { return nil } }
        let labels = options.compactMap { $0["label"] as? String }
        guard labels.count == options.count else { return nil }
        if let index = currentModelIndex(question: title, options: labels,
                descriptions: options.map { $0["description"] as? String ?? "" }) {
            return Self(question: title, answer: labels[index], kind: .keepCurrentModel)
        }
        // Model changes are never an ordinary affirmative confirmation.
        guard !isModelChange(title), !isModelPicker(title),
              let confirmation = BoundOriginalYesNoConfirmation.detect(input) else { return nil }
        return Self(question: confirmation.question, answer: confirmation.answer, kind: .confirmation)
    }

    public func updatedInput(_ input: JSONObject) -> JSONObject {
        var result = input; result["answers"] = [question: answer]; return result
    }

    static func mentionsModel(_ text: String) -> Bool {
        text.contains("모델") || modelWords.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }
    private static let modelWords = ["model", "gpt-", "claude", "sonnet ", "opus ", "haiku "]

    static func isModelHeading(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.hasPrefix("select model") || value.hasPrefix("select a model") || value.hasPrefix("choose model")
            || value.hasPrefix("choose a model") || value.hasPrefix("model selection")
            || value.hasPrefix("모델 선택") || value.hasPrefix("모델을 선택")
    }

    private static func isModelChange(_ title: String) -> Bool {
        guard mentionsModel(title), !isKeepingModel(title) else { return false }
        return title.range(of: #"(?i)\b(?:switch|change|replace|upgrade)\s+(?:to\s+)?(?:(?:a|the)\s+)?(?:(?:different|another|new|current)\s+)?(?:model|(?:gpt|claude)[-_/][a-z0-9._+/-]+|(?:claude\s+)?(?:sonnet|opus|haiku)\s+[0-9.]+)\b|\b(?:use|try)\s+(?:(?:a|the)\s+)?(?:(?:different|another|new)\s+model|(?:gpt|claude)[-_/][a-z0-9._+/-]+|(?:claude\s+)?(?:sonnet|opus|haiku)\s+[0-9.]+)\b|\b(?:don't|do not)\s+(?:keep|retain|continue using|use)\s+(?:the\s+)?(?:current|existing|same)\s+model\b|(?:모델(?:을)?\s*|(?:gpt|claude)[-_/][a-z0-9._+/-]+\s*(?:으로|로)\s*)(?:(?:변경|전환|교체)\s*(?:할까요|하시겠습니까|하겠습니까|할래요)|바꿀까요|바꾸시겠습니까|바꾸겠습니까)"#, options: .regularExpression) != nil
    }

    private static func isModelPicker(_ title: String) -> Bool {
        guard mentionsModel(title) else { return false }
        return title.range(of: #"(?i)\b(?:which|what|select|choose|pick)\b[^\n?]{0,100}\bmodel\b|어떤\s*모델|모델\s*(?:선택|고르)"#, options: .regularExpression) != nil
    }

    private static func isKeepingModel(_ title: String) -> Bool {
        guard mentionsModel(title) else { return false }
        if title.range(of: #"(?i)\b(?:don't|do not)\s+(?:keep|retain|continue using|use)\b"#, options: .regularExpression) != nil { return false }
        return title.range(of: #"(?i)\b(?:keep(?: using)?|retain|continue using|stay with|use)\s+(?:the\s+)?(?:current|existing|same)\s+model\b|\b(?:don't|do not)\s+(?:switch|change|replace)\s+(?:the\s+)?(?:current\s+|existing\s+|same\s+)?model\b|(?:현재|기존|같은)\s*모델(?:을)?\s*(?:그대로\s*)?(?:계속\s*)?(?:유지|사용)"#, options: .regularExpression) != nil
    }

    private static func cleaned(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"[‘’ʼ]"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s*(?:\((?:recommended|추천|권장)\)|\[(?:recommended|추천|권장)\])\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!。！")))
    }

    // These are model identifier shapes, not a preference list. A newer model
    // or the highlighted/recommended row is never inferred to be the old model.
    private static let modelName = #"(?i)^(?:(?:gpt|codex|claude)[-_/.][a-z0-9][a-z0-9._+/-]*|o[0-9][a-z0-9._+/-]*|(?:claude[ -])?(?:sonnet|opus|haiku)(?:[ -][0-9]+(?:[. -][0-9]+)*)?)$"#

    static func currentModelIndex(question: String, options: [String], descriptions: [String] = []) -> Int? {
        guard options.count >= 2, mentionsModel(question) else { return nil }
        let labels = options.map(cleaned)
        let retain = #"(?i)^(?:(?:no|아니오|아니요)\s*[,，:：]\s*)?(?:(?:keep|retain|use) (?:using )?(?:the )?(?:current|existing|same)(?: model)?|(?:the )?(?:current|existing|same) model|(?:continue|stay) (?:using|with) (?:the )?(?:current|existing|same) model|(?:don't|do not) change (?:the )?model|(?:현재|기존|같은|동일한)\s*모델(?:을)?(?:\s*(?:그대로\s*)?(?:유지|사용|계속 사용)(?:하기|합니다)?|\s*그대로)?|모델\s*변경\s*(?:없음|안 함|하지 않음))$"#
        let currentMarker = #"(?i)\s*(?:\((?:current|currently selected|현재|현재 모델|사용 중|사용중)\)|\[(?:current|currently selected|현재|현재 모델|사용 중|사용중)\])\s*$"#
        let currentDescription = #"(?i)^(?:(?:the )?(?:current|currently selected|existing) model|(?:현재|기존)\s*(?:사용\s*중인\s*)?모델)$"#
        var explicit: [Int] = []
        for (index, label) in labels.enumerated() {
            if label.range(of: retain, options: .regularExpression) != nil { explicit.append(index); continue }
            if let marker = label.range(of: currentMarker, options: .regularExpression),
               String(label[..<marker.lowerBound]).range(of: modelName, options: .regularExpression) != nil {
                explicit.append(index); continue
            }
            if descriptions.indices.contains(index),
               cleaned(descriptions[index]).range(of: currentDescription, options: .regularExpression) != nil,
               label.range(of: modelName, options: .regularExpression) != nil { explicit.append(index) }
        }
        if explicit.isEmpty, isModelChange(question) || isKeepingModel(question) {
            let input: JSONObject = ["questions": [["question": question, "options": options.enumerated().map { index, label -> JSONObject in
                ["label": label, "description": descriptions.indices.contains(index) ? descriptions[index] : ""]
            }]]]
            if let confirmation = BoundOriginalYesNoConfirmation.detect(input) {
                if isKeepingModel(question), !isModelChange(question) {
                    explicit = options.indices.filter { options[$0] == confirmation.answer }
                } else { explicit = options.indices.filter { BoundOriginalYesNoConfirmation.isDenial(options[$0]) } }
            }
        }
        // A title may name the old model while listing ordinary model names.
        if explicit.isEmpty {
            let pattern = #"(?i)(?:current model\s*[:=]|currently using|(?:현재|기존)\s*모델\s*[:=])\s*([a-z0-9][a-z0-9._+/-]*)"#
            if let expression = try? NSRegularExpression(pattern: pattern) {
                let matches = expression.matches(in: question, range: NSRange(question.startIndex..., in: question))
                if matches.count == 1, let range = Range(matches[0].range(at: 1), in: question) {
                    let name = String(question[range])
                    if name.range(of: modelName, options: .regularExpression) != nil {
                        explicit = labels.indices.filter { labels[$0].caseInsensitiveCompare(name) == .orderedSame }
                    }
                }
            }
        }
        guard explicit.count == 1, let index = explicit.first,
              labels.filter({ $0.caseInsensitiveCompare(labels[index]) == .orderedSame }).count == 1 else { return nil }
        return index
    }
}
// END ORIGINAL AutomaticQuestionDecision

// BEGIN ORIGINAL YesNoConfirmation
import AutoApproveCore
import Foundation

/// A single yes/no decision, optionally with repeated-permission choices.
/// This does not choose between projects, plans, environments or multiple answers.
public struct BoundOriginalYesNoConfirmation {
    public let question: String
    public let answer: String
    private static let affirmativeWords = "예|네|응|허용|yes|allow"
    private static let denialWords = "아니오|아니요|거부|취소|no|deny|cancel|don't allow|do not allow"

    public static func detect(_ question: QueuedQuestion) -> BoundOriginalYesNoConfirmation? {
        detect(["questions": [[
            "question": question.title,
            "multiSelect": question.multiSelect ?? false,
            "options": question.options.map { ["label": $0] }
        ]]])
    }

    public static func detect(_ input: JSONObject) -> BoundOriginalYesNoConfirmation? {
        if let answers = input["answers"] {
            guard let answers = answers as? JSONObject, answers.isEmpty else { return nil }
        }
        guard let questions = input["questions"] as? [JSONObject], questions.count == 1,
              let item = questions.first, let question = item["question"] as? String,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let options = item["options"] as? [JSONObject], options.count >= 2 else { return nil }
        if let multiSelect = item["multiSelect"] {
            guard let value = multiSelect as? Bool, !value else { return nil }
        }
        let labels = options.compactMap { $0["label"] as? String }
        guard labels.count == options.count else { return nil }
        // Two options are not inherently a confirmation: "Yes, use staging" /
        // "No, use production" still chooses a task. Apply the same complete-label
        // permission rules to every menu, regardless of its option count.
        guard let index = singleApprovalIndex(labels, descriptions: options.map { $0["description"] as? String ?? "" }) else { return nil }
        // Hook answers identify an option by its label, not by its position.
        let answer = labels[index].precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard labels.filter({ $0.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == answer }).count == 1 else { return nil }
        return BoundOriginalYesNoConfirmation(question: question, answer: labels[index])
    }

    static func isDenial(_ label: String) -> Bool {
        isDenial(cleaned: cleaned(label))
    }

    private static func isDenial(cleaned text: String) -> Bool {
        if text.range(of: "(?i)^(?:" + denialWords + ")$", options: .regularExpression) != nil { return true }
        // The CLI's fixed rejection action is still No. Arbitrary explanations
        // after No/Cancel must not turn a different task into a permission menu.
        return text.range(of: #"(?i)^no\s*[,，:：—–-]\s*and tell (?:codex|claude|the agent) what to do differently$"#, options: .regularExpression) != nil
    }

    private static func isUnchangedASCII(_ value: String) -> Bool {
        value.utf8.withContiguousStorageIfAvailable { bytes in
            guard let first = bytes.first, let last = bytes.last else { return true }
            guard first != 32, first != 33, first != 46,
                  last != 32, last != 33, last != 46 else { return false }
            var previousSpace = false
            for byte in bytes {
                guard byte >= 32, byte < 127, byte != 40, byte != 91 else { return false }
                if byte == 32 && previousSpace { return false }
                previousSpace = byte == 32
            }
            return true
        } ?? false
    }

    private static func cleaned(_ value: String) -> String {
        if isUnchangedASCII(value) { return value }
        let hint = #"(?:추천|권장|recommended|[a-z]|esc|shift\s*\+\s*tab)"#
        return value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"[‘’ʼ]"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: "(?i)(?:\\s*(?:\\(" + hint + "\\)|\\[" + hint + "\\]))+\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!。！")))
    }

    private static func affirmativeTail(cleaned text: String) -> String? {
        guard let prefix = text.range(of: "(?i)^(?:" + affirmativeWords + #")(?=$|[\s,，:：—–-])[\s,，:：—–-]*"#, options: .regularExpression) else { return nil }
        return String(text[prefix.upperBound...])
    }

    // These descriptions do not depend on a request. Normalize them once rather
    // than repeating regex/string work for every option in every permission menu.
    private static let permissionPhrases: [(compact: String, label: String)] = {
        let descriptions = [
            ("Allow", "Run the tool and continue."),
            ("Allow for this session", "Run the tool and remember this choice for this session."),
            ("Always allow", "Run the tool and remember this choice for future tool calls."),
            ("Allow and don't ask me again", "Run the tool and remember this choice for future tool calls."),
            ("Cancel", "Cancel this tool call.")
        ]
        return descriptions.flatMap { label, description in
            [label, cleaned(label + " " + description)].map { phrase in
                (compact: phrase.filter { !$0.isWhitespace }, label: label)
            }
        }
    }()

    /// Codex renders tool permission labels and descriptions in two columns. Match
    /// only complete known phrases. Terminal cells can wrap inside a word, so the
    /// added line-boundary space must not change those phrases' meaning.
    private static func permissionLabel(_ value: String) -> String {
        let text = cleaned(value)
        let compact = text.filter { !$0.isWhitespace }
        for phrase in permissionPhrases where compact.caseInsensitiveCompare(phrase.compact) == .orderedSame {
            return phrase.label
        }
        return text
    }

    static func isToolPermissionMenu(_ labels: [String]) -> Bool {
        let labels = labels.map { permissionLabel($0).lowercased() }
        let known: Set<String> = ["allow", "allow for this session", "always allow", "allow and don't ask me again",
                                  "cancel", "deny", "don't allow", "do not allow"]
        // Tool capabilities determine which permission scopes are offered. Two,
        // three and four rows are valid; an unrelated task is never a scope.
        return (2...4).contains(labels.count) && labels.allSatisfy(known.contains)
            && singleApprovalIndex(labels) == 0
    }

    private static func isCurrentPermission(_ tail: String) -> Bool {
        tail.isEmpty || tail.range(of: #"(?i)^(?:proceed|continue|allow (?:once|this (?:request|time)(?: only)?)|(?:just )?this (?:once|time only)|for this request only|이번(?: 요청)?만(?:\s*(?:허용|승인|진행)(?:하기|합니다|해 ?주세요)?)?|한\s*번만(?:\s*(?:허용|승인)(?:하기|합니다)?)?|(?:허용|승인|진행)(?:합니다|해 ?주세요)?)$"#, options: .regularExpression) != nil
    }

    private static func isRepeatedPermission(_ value: String) -> Bool {
        isRepeatedPermission(cleaned: cleaned(value))
    }

    private static func isRepeatedPermission(cleaned text: String) -> Bool {
        let english = #"(?i)^(?:and\s+)?(?:(?:don't|do not) ask(?: me)?(?: for (?:approval|permission))? again(?: (?:for:?|in|during) .+| this session)?|always allow(?: .+)?|(?:allow|approve) (?:all (?:edits|commands|changes) )?(?:for|during|in) (?:this|the) (?:session|project|folder)|allow all (?:edits|commands|changes)|allow reading from .+ (?:from this project|during this session))$"#
        // Claude Code also offers its permission modes; each changes only later prompts.
        let mode = #"(?i)^(?:and\s+)?(?:(?:switch to|use) auto mode(?: · .+)?|switch to (?:default|accept edits|auto|don't ask|plan mode|bypass permissions)(?: \([^)]*\))? for this session)$"#
        let scope = #"(?:앞으로|이후(?:에도|부터)?|이(?:번)?\s*(?:세션|프로젝트|폴더|명령)(?:에서(?:는)?|\s*동안(?:에는)?|에\s*대해서(?:는)?)?)"#
        let korean = "^(?:" + scope + #"\s*)?(?:(?:다시|매번)\s*)?묻지\s*않(?:기|음|습니다|아도\s*됩니다|고\s*(?:허용|승인)(?:하기|합니다)?)$"#
        let allow = "^(?:" + scope + #"\s*(?:(?:항상|자동으로|계속)\s*)?|(?:항상|자동으로|계속)\s*)(?:허용|승인)(?:하기|합니다|해\s*주세요)?$"#
        return [english, mode, korean, allow].contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func isSessionPermission(cleaned text: String) -> Bool {
        text.range(of: #"(?i)^(?:allow|approve) (?:for|during|in) (?:this|the) session$"#, options: .regularExpression) != nil
    }

    /// Prefer one request. If it is not offered, an explicit session-only Allow
    /// is permitted. Never fall back to a permanent permission or a task choice.
    static func singleApprovalIndex(_ labels: [String], descriptions: [String] = []) -> Int? {
        guard labels.count >= 2 else { return nil }
        var current: [Int] = [], sessionOnly: [Int] = [], denials = 0
        for (index, label) in labels.enumerated() {
            let label = permissionLabel(label)
            // These predicates inspect the same normalized label. Keep
            // permissionLabel's separate first pass: cleaning is not idempotent
            // for every nested hint and punctuation combination.
            let text = cleaned(label)
            if isDenial(cleaned: text) { denials += 1; continue }
            if isSessionPermission(cleaned: text) { sessionOnly.append(index); continue }
            if isRepeatedPermission(cleaned: text) { continue }
            guard let tail = affirmativeTail(cleaned: text) else { return nil }
            if isRepeatedPermission(tail) || isRepeatedPermission("allow " + tail) { continue }
            guard isCurrentPermission(tail) || isCurrentPermission("allow " + tail) else { return nil }
            // Claude may put the scope in the description beneath a plain Yes label.
            if descriptions.indices.contains(index), isRepeatedPermission(descriptions[index]) { continue }
            current.append(index)
        }
        guard denials == 1 else { return nil }
        if current.count == 1 { return current[0] }
        return current.isEmpty && sessionOnly.count == 1 ? sessionOnly[0] : nil
    }

    public func updatedInput(_ input: JSONObject) -> JSONObject {
        var updated = input
        updated["answers"] = [question: answer]
        return updated
    }
}
// END ORIGINAL YesNoConfirmation
// A source-bound original decision and confirmation implementation is embedded
// above this oracle. All strings and hook objects here are synthetic.
enum TypedDecisionOracle {
    struct Result { let typed: Int; let json: Int; let foreignInputs: Int; let digest: String }
    static func raw(_ text: String) -> String {
        let units = Array(text.utf16).map { $0.littleEndian }
        return Data(text.utf8).base64EncodedString() + ":" + units.withUnsafeBytes { Data($0).base64EncodedString() }
    }
    static func signature(_ value: AutomaticQuestionDecision?) -> [String] {
        guard let value else { return ["nil"] }
        return [value.kind == .confirmation ? "confirmation" : "keepCurrentModel", raw(value.question), raw(value.answer)]
    }
    static func signature(_ value: BoundOriginalQuestionDecision?) -> [String] {
        guard let value else { return ["nil"] }
        return [value.kind == .confirmation ? "confirmation" : "keepCurrentModel", raw(value.question), raw(value.answer)]
    }
    static func signature(_ value: YesNoConfirmation?) -> [String] {
        guard let value else { return ["nil"] }
        return ["confirmation", raw(value.question), raw(value.answer)]
    }
    static func signature(_ value: BoundOriginalYesNoConfirmation?) -> [String] {
        guard let value else { return ["nil"] }
        return ["confirmation", raw(value.question), raw(value.answer)]
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw InboxOracle.Failure(message: message) }
    }
    static func run() throws -> Result {
        let titles = ["Continue with this request?", "Choose a deployment target.", "Which model should run?",
            "Change the current model?", "Keep the current model?", "Current model: gpt-5. Which model?",
            "현재 모델을 유지할까요?", "모델을 변경할까요?", "", " \r\n\t", "mOdEl selection",
            "Use a different model?", "A normal 한글 e\u{301} 👩🏽‍💻 question", "\0\u{1b}[31mContinue?\r\n",
            String(repeating: "plain ", count: 120) + "model?", "Continue with MODEL configuration?"]
        let menus: [[String]] = [
            ["Yes", "No"], ["No", "Yes (recommended)"], ["예", "아니오"], ["허용", "거부"],
            ["Allow", "Allow for this session", "Always allow", "Cancel"], ["Allow for this session", "Deny"],
            ["Always allow", "No"], ["Development", "Production"], ["Yes, use staging", "No, use production"],
            ["gpt-5 (current)", "gpt-6"], ["Keep current model", "gpt-6"], ["gpt-5", "gpt-6"],
            ["Yes", "Yes", "No"], ["Yes [y].", "No"], [], ["네"]
        ]
        var digest = SHA256(), typed = 0, json = 0, foreignInputs = 0
        func record(_ parts: [String]) throws {
            digest.update(data: try JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys]))
            digest.update(data: Data([0]))
        }
        func transformed(_ text: String, _ mode: Int) -> String {
            switch mode {
            case 1: return text.decomposedStringWithCanonicalMapping
            case 2: return NSAppleEventDescriptor(string: text).stringValue!
            case 3:
                var units = Array(text.utf16)
                units.append(contentsOf: [0xd800, 0, 0xdc00])
                return units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) as String }
            default: return text
            }
        }
        for index in 0..<4096 {
            let mode = (index >> 8) & 3
            let title = transformed(titles[index & 15], mode)
            let labels = menus[(index >> 4) & 15].map { transformed($0, mode) }
            let before = ([title] + labels).map(raw)
            let native = ([title] + labels).map(\.isContiguousUTF8)
            foreignInputs += native.filter { !$0 }.count
            var question = QueuedQuestion(id: "typed:\(index)", threadID: "synthetic", title: title, options: labels)
            switch (index >> 10) & 3 {
            case 1: question.multiSelect = false
            case 2: question.multiSelect = true
            case 3: question.hasLaterUserMessage = true
            default: break
            }
            let actualDecision = AutomaticQuestionDecision.detect(question)
            let expectedDecision = BoundOriginalQuestionDecision.detect(question)
            let actualConfirmation = YesNoConfirmation.detect(question)
            let expectedConfirmation = BoundOriginalYesNoConfirmation.detect(question)
            try require(signature(actualDecision) == signature(expectedDecision), "Typed automatic decision changed: \(index)")
            try require(signature(actualConfirmation) == signature(expectedConfirmation), "Typed confirmation changed: \(index)")
            try require(([title] + labels).map(raw) == before && ([title] + labels).map(\.isContiguousUTF8) == native,
                "Typed caller bytes or storage changed: \(index)")
            try record(signature(actualDecision) + signature(actualConfirmation)); typed += 1
        }
        for index in 0..<512 {
            let title = titles[index & 15]
            var item: JSONObject = ["question": title, "options": menus[(index >> 4) & 15].map { ["label": $0] }]
            var input: JSONObject = [:]
            let mutation = index >> 4
            switch mutation {
            case 1: input["answers"] = JSONObject()
            case 2: input["answers"] = ["previous": "Yes"]
            case 3: input["answers"] = "false"
            case 4: input["answers"] = NSNull()
            case 5: input["questions"] = [JSONObject]()
            case 6: input["questions"] = [item, item]
            case 7: input["questions"] = "invalid"
            case 8: item.removeValue(forKey: "question")
            case 9: item["question"] = 42
            case 10: item.removeValue(forKey: "options")
            case 11: item["options"] = "invalid"
            case 12: item["options"] = [["label": "Yes"], "No"] as [Any]
            case 13: item["options"] = [["description": "Yes"], ["label": "No"]]
            case 14: item["options"] = [["label": 7], ["label": "No"]] as [JSONObject]
            case 15: item["multiSelect"] = "false"
            case 16: item["multiSelect"] = NSNull()
            case 17: item["multiSelect"] = NSNumber(value: 0)
            case 18: item["multiSelect"] = true
            case 19: item["multiSelect"] = false
            case 20: item["options"] = [JSONObject]()
            case 21: item["options"] = [["label": "Yes"]]
            case 22: item["question"] = ""
            case 23: item["question"] = " \r\n\t"
            case 24:
                item["question"] = "Which model?"
                item["options"] = [["label": "gpt-5", "description": "The current model"], ["label": "gpt-6"]]
            case 25: item["options"] = [["label": "Yes", "description": "Allow for this session"], ["label": "No"]]
            case 26: item["options"] = [["label": "Yes"], ["label": "Yes"], ["label": "No"]]
            case 27: item["options"] = [["label": "Yes", "description": ["invalid"]], ["label": "No"]] as [JSONObject]
            case 28: input["questions"] = ["invalid"]
            case 29: input["answers"] = ["invalid"]
            case 30: item["multiSelect"] = NSNumber(value: 1)
            case 31: input["answers"] = ["answer": NSNumber(value: 0)]
            default: break
            }
            if input["questions"] == nil { input["questions"] = [item] }
            let a = AutomaticQuestionDecision.detect(input), b = BoundOriginalQuestionDecision.detect(input)
            let c = YesNoConfirmation.detect(input), d = BoundOriginalYesNoConfirmation.detect(input)
            try require(signature(a) == signature(b), "JSON automatic decision changed: \(index)")
            try require(signature(c) == signature(d), "JSON confirmation changed: \(index)")
            if let a, let b {
                let actual = a.updatedInput(input)["answers"] as? [String: String]
                let expected = b.updatedInput(input)["answers"] as? [String: String]
                try require(actual?.count == 1 && expected?.count == 1, "Invalid updated answer count")
                try require(actual!.map { raw($0.key) + ":" + raw($0.value) }.sorted() == expected!.map { raw($0.key) + ":" + raw($0.value) }.sorted(), "Updated answer changed")
            }
            try record(signature(a) + signature(c)); json += 1
        }
        try require(AutomaticQuestionDecision.detect(QueuedQuestion(id: "ordinary", threadID: "fixture", title: "Which environment?", options: ["Development", "Production"])) == nil, "An ordinary choice cannot be auto-selected")
        try require(AutomaticQuestionDecision.detect(QueuedQuestion(id: "model", threadID: "fixture", title: "Select model", options: ["gpt-5 (current)", "gpt-6"]))?.answer == "gpt-5 (current)", "Keep only the explicit current model")
        try require(typed == 4096 && json == 512 && foreignInputs > 0, "Missing typed, JSON or foreign-string cases")
        return Result(typed: typed, json: json, foreignInputs: foreignInputs,
            digest: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
// BEGIN ORIGINAL ModelWordMatcher
enum BoundPreviousModelWordMatcher {
    static func mentionsModel(_ text: String) -> Bool {
        text.contains("모델") || modelWords.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }
    private static let modelWords = ["model", "gpt-", "claude", "sonnet ", "opus ", "haiku "]

}
// END ORIGINAL ModelWordMatcher
// BEGIN PREVIOUS ModelWordMatcher
enum BoundImmediateModelWordMatcher {
    static func mentionsModel(_ text: String) -> Bool {
        // A short native ASCII title needs only one case conversion. Keep
        // Foundation's case-fold behavior for every other representation.
        if let result = text.utf8.withContiguousStorageIfAvailable({ bytes -> Bool? in
            guard bytes.count <= 4096, bytes.allSatisfy({ $0 < 128 }) else { return nil }
            let folded = text.lowercased()
            return modelWords.contains { folded.contains($0) }
        }) ?? nil { return result }
        return text.contains("모델") || modelWords.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }
    private static let modelWords = ["model", "gpt-", "claude", "sonnet ", "opus ", "haiku "]

}
// END PREVIOUS ModelWordMatcher
// BEGIN CANDIDATE ModelWordMatcher
enum BoundCandidateModelWordMatcher {
    static func mentionsModel(_ text: String) -> Bool {
        // Short native ASCII titles need only a byte scan. Keep Foundation's
        // case-fold behavior for every other representation.
        if let result = text.utf8.withContiguousStorageIfAvailable({ bytes -> Bool? in
            guard bytes.count <= 4096, bytes.allSatisfy({ $0 < 128 }) else { return nil }
            // Match the six fixed modelWords, including punctuation and spaces.
            for offset in bytes.indices {
                switch bytes[offset] | 32 {
                case 109: // "model"
                    if bytes.count - offset >= 5 && bytes[offset + 1] | 32 == 111 && bytes[offset + 2] | 32 == 100 && bytes[offset + 3] | 32 == 101 && bytes[offset + 4] | 32 == 108 { return true }
                case 103: // "gpt-"
                    if bytes.count - offset >= 4 && bytes[offset + 1] | 32 == 112 && bytes[offset + 2] | 32 == 116 && bytes[offset + 3] == 45 { return true }
                case 99: // "claude"
                    if bytes.count - offset >= 6 && bytes[offset + 1] | 32 == 108 && bytes[offset + 2] | 32 == 97 && bytes[offset + 3] | 32 == 117 && bytes[offset + 4] | 32 == 100 && bytes[offset + 5] | 32 == 101 { return true }
                case 115: // "sonnet "
                    if bytes.count - offset >= 7 && bytes[offset + 1] | 32 == 111 && bytes[offset + 2] | 32 == 110 && bytes[offset + 3] | 32 == 110 && bytes[offset + 4] | 32 == 101 && bytes[offset + 5] | 32 == 116 && bytes[offset + 6] == 32 { return true }
                case 111: // "opus "
                    if bytes.count - offset >= 5 && bytes[offset + 1] | 32 == 112 && bytes[offset + 2] | 32 == 117 && bytes[offset + 3] | 32 == 115 && bytes[offset + 4] == 32 { return true }
                case 104: // "haiku "
                    if bytes.count - offset >= 6 && bytes[offset + 1] | 32 == 97 && bytes[offset + 2] | 32 == 105 && bytes[offset + 3] | 32 == 107 && bytes[offset + 4] | 32 == 117 && bytes[offset + 5] == 32 { return true }
                default: break
                }
            }
            return false
        }) ?? nil { return result }
        return text.contains("모델") || modelWords.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }
    private static let modelWords = ["model", "gpt-", "claude", "sonnet ", "opus ", "haiku "]

}
// END CANDIDATE ModelWordMatcher
import Foundation
import CryptoKit
#if !MODEL_WORD_SOURCE_ONLY
import AutoApproveCore
#endif

enum ModelWordOracle {
    struct Failure: Error { let message: String }
    struct Result { let cases: Int; let linkedCoreCases: Int; let foreignInputs: Int; let digest: String; let counts: [String: Int] }
    static let words = ["model", "gpt-", "claude", "sonnet ", "opus ", "haiku "]
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func run() throws -> Result {
        var counts: [String: Int] = [:], foreignInputs = 0, linkedCoreCases = 0, digest = SHA256()
        func check(_ text: String, bank: String) throws {
            let before = Array(text.utf8), units = Array(text.utf16), native = text.isContiguousUTF8
            let expected = BoundPreviousModelWordMatcher.mentionsModel(text)
            let immediate = BoundImmediateModelWordMatcher.mentionsModel(text)
            let actual = BoundCandidateModelWordMatcher.mentionsModel(text)
            try require(expected == immediate, "Immediate previous model matcher differs from the Foundation reference")
            #if !MODEL_WORD_SOURCE_ONLY
            let linked = AutomaticQuestionDecision.detect(QueuedQuestion(id: "model-word-probe", threadID: "synthetic",
                title: text, options: ["Current model", "gpt-5.5"]))
            if expected {
                try require(linked?.kind == .keepCurrentModel && linked?.answer == "Current model" && linked?.question == text,
                    "Actual linked Core lost a model mention in \(bank): \(before)")
            } else {
                try require(linked == nil, "Actual linked Core gained a model mention in \(bank): \(before)")
            }
            linkedCoreCases += 1
            #endif
            try require(expected == actual, "Model word result changed in \(bank): \(before)")
            try require(text.utf8.elementsEqual(before) && text.utf16.elementsEqual(units)
                && text.isContiguousUTF8 == native, "Caller storage changed in \(bank)")
            digest.update(data: Data(before)); digest.update(data: Data([actual ? 1 : 0, 255]))
            counts[bank, default: 0] += 1
            if !native { foreignInputs += 1 }
        }
        func foreign(_ text: String) -> String { NSAppleEventDescriptor(string: text).stringValue! }
        for a in UInt8(0)..<128 { for b in UInt8(0)..<128 {
            let pair = String(decoding: [a, b], as: UTF8.self)
            for text in ["mo" + pair + "del", "c" + pair + "laude", "G" + pair + "PT-",
                         "SONN" + pair + "ET ", "OP" + pair + "US ", "HAI" + pair + "KU ",
                         pair + "MoDeL" + pair, "plain " + pair + " text"] {
                try check(text, bank: "asciiPairs")
            }
        }}
        for word in words {
            let original = Array(word.utf8), letters = original.indices.filter { (97...122).contains(original[$0]) }
            for mask in 0..<(1 << letters.count) {
                var bytes = original
                for (bit, index) in letters.enumerated() where mask & (1 << bit) != 0 { bytes[index] -= 32 }
                let text = String(decoding: bytes, as: UTF8.self)
                for value in [text, "plain " + text + " text", "\0" + text + "\r\n"] {
                    try check(value, bank: "asciiCaseVariants")
                }
            }
            for position in 0...original.count { for byte in UInt8(0)..<128 {
                var bytes = original; bytes.insert(byte, at: position)
                let text = String(decoding: bytes, as: UTF8.self)
                for value in [text, text.uppercased(), "prefix " + text + " suffix"] {
                    try check(value, bank: "asciiInsertions")
                    try check(foreign(value), bank: "asciiInsertions")
                }
            }}
        }
        var random: UInt64 = 0x1290cafe
        for index in 0..<4096 {
            var bytes: [UInt8] = []
            for _ in 0..<(index % 129) {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                bytes.append(UInt8((random >> 24) & 127))
            }
            let text = String(decoding: bytes, as: UTF8.self) + (index.isMultiple(of: 2) ? words[index % words.count].uppercased() : "")
            try check(text, bank: "randomASCII")
        }
        let additions: [UInt32] = [0x100, 0x130, 0x17f, 0x300, 0x301, 0x307, 0x34f, 0x390, 0x3a3, 0x3c2, 0x3c3,
            0x1e9e, 0x200b, 0x200c, 0x200d, 0x2028, 0x2029, 0x2060, 0x212a, 0x212b,
            0xfb00, 0xfb01, 0xfb02, 0xfb03, 0xfb04, 0xfb05, 0xfb06, 0xfeff, 0xfffd, 0x1f4bb, 0x10ffff, 0xbaa8, 0xb378]
        let scalars = Array(UInt32(0)..<256) + additions
        try require(scalars.count == 289 && Set(scalars).count == 289, "Scalar bank changed")
        for value in scalars {
            let insertion = String(Unicode.Scalar(value)!)
            for word in words {
                let bytes = Array(word.utf8)
                for index in 0...bytes.count {
                    let text = String(decoding: bytes[..<index], as: UTF8.self) + insertion + String(decoding: bytes[index...], as: UTF8.self)
                    try check(text, bank: "unicodeInsertions")
                    try check(foreign(text), bank: "unicodeInsertions")
                }
            }
        }
        for length in [0, 15, 255, 256, 4095, 4096, 4097, 8192] {
            for word in words {
                let fill = String(repeating: "x", count: max(0, length - word.utf8.count))
                for value in [length == 0 ? "" : word.uppercased() + fill, length == 0 ? "" : fill + word.uppercased()] {
                    try require(value.utf8.count == length, "Length boundary changed")
                    try check(value, bank: "lengthBoundaries")
                    try check(foreign(value), bank: "lengthBoundaries")
                }
            }
        }
        let malformed: [[UInt16]] = [[0xd800], [0xdc00], [0xd800, 0xd800, 0xdc00], [0xdc00, 0xd800],
            [0xd800, 10, 0xdc00], [0xd800, 0xdc00], [0xffff, 0xfffd, 0, 27], [0x301, 0xfeff, 0x200d]]
        for units in malformed {
            let source = units.withUnsafeBufferPointer { NSString(characters: $0.baseAddress!, length: $0.count) as String }
            let repaired = String(decoding: units, as: UTF16.self)
            for word in words {
                for insert in [source, repaired] {
                    for text in [insert + word, "mo" + insert + "del " + word, word + insert] {
                        try check(text, bank: "malformedUTF16")
                    }
                }
            }
        }
        let expected = ["asciiPairs": 131072, "asciiCaseVariants": 648, "asciiInsertions": 29952,
            "randomASCII": 4096, "unicodeInsertions": 22542, "lengthBoundaries": 192, "malformedUTF16": 288]
        try require(counts == expected, "Missing model word cases: \(counts)")
        let cases = counts.values.reduce(0, +)
        try require(cases == 188790 && foreignInputs > 0, "Missing model word or foreign-string coverage")
        return Result(cases: cases, linkedCoreCases: linkedCoreCases, foreignInputs: foreignInputs,
            digest: digest.finalize().map { String(format: "%02x", $0) }.joined(), counts: counts)
    }
}

// BEGIN PREVIOUS PermissionPrefix
import AutoApproveCore
import Foundation

/// A single yes/no decision, optionally with repeated-permission choices.
/// This does not choose between projects, plans, environments or multiple answers.
public struct BoundPreviousPermissionConfirmation {
    public let question: String
    public let answer: String
    private static let affirmativeWords = "예|네|응|허용|yes|allow"
    private static let denialWords = "아니오|아니요|거부|취소|no|deny|cancel|don't allow|do not allow"

    public static func detect(_ question: QueuedQuestion) -> BoundPreviousPermissionConfirmation? {
        guard question.multiSelect != true else { return nil }
        return detect(question: question.title, labels: question.options)
    }

    public static func detect(_ input: JSONObject) -> BoundPreviousPermissionConfirmation? {
        if let answers = input["answers"] {
            guard let answers = answers as? JSONObject, answers.isEmpty else { return nil }
        }
        guard let questions = input["questions"] as? [JSONObject], questions.count == 1,
              let item = questions.first, let question = item["question"] as? String,
              let options = item["options"] as? [JSONObject] else { return nil }
        if let multiSelect = item["multiSelect"] {
            guard let value = multiSelect as? Bool, !value else { return nil }
        }
        let labels = options.compactMap { $0["label"] as? String }
        guard labels.count == options.count else { return nil }
        return detect(question: question, labels: labels,
            descriptions: options.map { $0["description"] as? String ?? "" })
    }

    /// A queue already has typed labels. Hook objects validate their shape
    /// before entering this shared confirmation policy.
    static func detect(question: String, labels: [String], descriptions: [String] = []) -> BoundPreviousPermissionConfirmation? {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              labels.count >= 2 else { return nil }
        // Two options are not inherently a confirmation: "Yes, use staging" /
        // "No, use production" still chooses a task. Apply the same complete-label
        // permission rules to every menu, regardless of its option count.
        guard let index = singleApprovalIndex(labels, descriptions: descriptions) else { return nil }
        // Hook answers identify an option by its label, not by its position.
        let answer = labels[index].precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard labels.filter({ $0.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == answer }).count == 1 else { return nil }
        return BoundPreviousPermissionConfirmation(question: question, answer: labels[index])
    }

    static func isDenial(_ label: String) -> Bool {
        isDenial(cleaned: cleaned(label))
    }

    private static func isDenial(cleaned text: String) -> Bool {
        if text.range(of: "(?i)^(?:" + denialWords + ")$", options: .regularExpression) != nil { return true }
        // The CLI's fixed rejection action is still No. Arbitrary explanations
        // after No/Cancel must not turn a different task into a permission menu.
        return text.range(of: #"(?i)^no\s*[,，:：—–-]\s*and tell (?:codex|claude|the agent) what to do differently$"#, options: .regularExpression) != nil
    }

    private static func isUnchangedASCII(_ value: String) -> Bool {
        value.utf8.withContiguousStorageIfAvailable { bytes in
            guard let first = bytes.first, let last = bytes.last else { return true }
            guard first != 32, first != 33, first != 46,
                  last != 32, last != 33, last != 46 else { return false }
            var previousSpace = false
            for byte in bytes {
                guard byte >= 32, byte < 127, byte != 40, byte != 91 else { return false }
                if byte == 32 && previousSpace { return false }
                previousSpace = byte == 32
            }
            return true
        } ?? false
    }

    private static func cleaned(_ value: String) -> String {
        if isUnchangedASCII(value) { return value }
        let hint = #"(?:추천|권장|recommended|[a-z]|esc|shift\s*\+\s*tab)"#
        return value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"[‘’ʼ]"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: "(?i)(?:\\s*(?:\\(" + hint + "\\)|\\[" + hint + "\\]))+\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!。！")))
    }

    private static func affirmativeTail(cleaned text: String) -> String? {
        guard let prefix = text.range(of: "(?i)^(?:" + affirmativeWords + #")(?=$|[\s,，:：—–-])[\s,，:：—–-]*"#, options: .regularExpression) else { return nil }
        return String(text[prefix.upperBound...])
    }

    // These descriptions do not depend on a request. Normalize them once rather
    // than repeating regex/string work for every option in every permission menu.
    private static let permissionPhrases: [(compact: String, label: String)] = {
        let descriptions = [
            ("Allow", "Run the tool and continue."),
            ("Allow for this session", "Run the tool and remember this choice for this session."),
            ("Always allow", "Run the tool and remember this choice for future tool calls."),
            ("Allow and don't ask me again", "Run the tool and remember this choice for future tool calls."),
            ("Cancel", "Cancel this tool call.")
        ]
        return descriptions.flatMap { label, description in
            [label, cleaned(label + " " + description)].map { phrase in
                (compact: phrase.filter { !$0.isWhitespace }, label: label)
            }
        }
    }()

    /// Codex renders tool permission labels and descriptions in two columns. Match
    /// only complete known phrases. Terminal cells can wrap inside a word, so the
    /// added line-boundary space must not change those phrases' meaning.
    private static func permissionLabel(_ value: String) -> String {
        let text = cleaned(value)
        let compact = text.filter { !$0.isWhitespace }
        for phrase in permissionPhrases where compact.caseInsensitiveCompare(phrase.compact) == .orderedSame {
            return phrase.label
        }
        return text
    }

    static func isToolPermissionMenu(_ labels: [String]) -> Bool {
        let labels = labels.map { permissionLabel($0).lowercased() }
        let known: Set<String> = ["allow", "allow for this session", "always allow", "allow and don't ask me again",
                                  "cancel", "deny", "don't allow", "do not allow"]
        // Tool capabilities determine which permission scopes are offered. Two,
        // three and four rows are valid; an unrelated task is never a scope.
        return (2...4).contains(labels.count) && labels.allSatisfy(known.contains)
            && singleApprovalIndex(labels) == 0
    }

    private static func isCurrentPermission(_ tail: String) -> Bool {
        tail.isEmpty || tail.range(of: #"(?i)^(?:proceed|continue|allow (?:once|this (?:request|time)(?: only)?)|(?:just )?this (?:once|time only)|for this request only|이번(?: 요청)?만(?:\s*(?:허용|승인|진행)(?:하기|합니다|해 ?주세요)?)?|한\s*번만(?:\s*(?:허용|승인)(?:하기|합니다)?)?|(?:허용|승인|진행)(?:합니다|해 ?주세요)?)$"#, options: .regularExpression) != nil
    }

    private static func isRepeatedPermission(_ value: String) -> Bool {
        isRepeatedPermission(cleaned: cleaned(value))
    }

    private static func isRepeatedPermission(cleaned text: String) -> Bool {
        let english = #"(?i)^(?:and\s+)?(?:(?:don't|do not) ask(?: me)?(?: for (?:approval|permission))? again(?: (?:for:?|in|during) .+| this session)?|always allow(?: .+)?|(?:allow|approve) (?:all (?:edits|commands|changes) )?(?:for|during|in) (?:this|the) (?:session|project|folder)|allow all (?:edits|commands|changes)|allow reading from .+ (?:from this project|during this session))$"#
        // Claude Code also offers its permission modes; each changes only later prompts.
        let mode = #"(?i)^(?:and\s+)?(?:(?:switch to|use) auto mode(?: · .+)?|switch to (?:default|accept edits|auto|don't ask|plan mode|bypass permissions)(?: \([^)]*\))? for this session)$"#
        let scope = #"(?:앞으로|이후(?:에도|부터)?|이(?:번)?\s*(?:세션|프로젝트|폴더|명령)(?:에서(?:는)?|\s*동안(?:에는)?|에\s*대해서(?:는)?)?)"#
        let korean = "^(?:" + scope + #"\s*)?(?:(?:다시|매번)\s*)?묻지\s*않(?:기|음|습니다|아도\s*됩니다|고\s*(?:허용|승인)(?:하기|합니다)?)$"#
        let allow = "^(?:" + scope + #"\s*(?:(?:항상|자동으로|계속)\s*)?|(?:항상|자동으로|계속)\s*)(?:허용|승인)(?:하기|합니다|해\s*주세요)?$"#
        return [english, mode, korean, allow].contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func isSessionPermission(cleaned text: String) -> Bool {
        text.range(of: #"(?i)^(?:allow|approve) (?:for|during|in) (?:this|the) session$"#, options: .regularExpression) != nil
    }

    /// Prefer one request. If it is not offered, an explicit session-only Allow
    /// is permitted. Never fall back to a permanent permission or a task choice.
    static func singleApprovalIndex(_ labels: [String], descriptions: [String] = []) -> Int? {
        guard labels.count >= 2 else { return nil }
        var current: [Int] = [], sessionOnly: [Int] = [], denials = 0
        for (index, label) in labels.enumerated() {
            let label = permissionLabel(label)
            // These predicates inspect the same normalized label. Keep
            // permissionLabel's separate first pass: cleaning is not idempotent
            // for every nested hint and punctuation combination.
            let text = cleaned(label)
            if isDenial(cleaned: text) { denials += 1; continue }
            if isSessionPermission(cleaned: text) { sessionOnly.append(index); continue }
            if isRepeatedPermission(cleaned: text) { continue }
            guard let tail = affirmativeTail(cleaned: text) else { return nil }
            if isRepeatedPermission(tail) || isRepeatedPermission("allow " + tail) { continue }
            guard isCurrentPermission(tail) || isCurrentPermission("allow " + tail) else { return nil }
            // Claude may put the scope in the description beneath a plain Yes label.
            if descriptions.indices.contains(index), isRepeatedPermission(descriptions[index]) { continue }
            current.append(index)
        }
        guard denials == 1 else { return nil }
        if current.count == 1 { return current[0] }
        return current.isEmpty && sessionOnly.count == 1 ? sessionOnly[0] : nil
    }

    public func updatedInput(_ input: JSONObject) -> JSONObject {
        var updated = input
        updated["answers"] = [question: answer]
        return updated
    }
}
// END PREVIOUS PermissionPrefix

// BEGIN CANDIDATE PermissionPrefix
import AutoApproveCore
import Foundation

/// A single yes/no decision, optionally with repeated-permission choices.
/// This does not choose between projects, plans, environments or multiple answers.
public struct BoundCandidatePermissionConfirmation {
    public let question: String
    public let answer: String
    private static let affirmativeWords = "예|네|응|허용|yes|allow"
    private static let denialWords = "아니오|아니요|거부|취소|no|deny|cancel|don't allow|do not allow"

    public static func detect(_ question: QueuedQuestion) -> BoundCandidatePermissionConfirmation? {
        guard question.multiSelect != true else { return nil }
        return detect(question: question.title, labels: question.options)
    }

    public static func detect(_ input: JSONObject) -> BoundCandidatePermissionConfirmation? {
        if let answers = input["answers"] {
            guard let answers = answers as? JSONObject, answers.isEmpty else { return nil }
        }
        guard let questions = input["questions"] as? [JSONObject], questions.count == 1,
              let item = questions.first, let question = item["question"] as? String,
              let options = item["options"] as? [JSONObject] else { return nil }
        if let multiSelect = item["multiSelect"] {
            guard let value = multiSelect as? Bool, !value else { return nil }
        }
        let labels = options.compactMap { $0["label"] as? String }
        guard labels.count == options.count else { return nil }
        return detect(question: question, labels: labels,
            descriptions: options.map { $0["description"] as? String ?? "" })
    }

    /// A queue already has typed labels. Hook objects validate their shape
    /// before entering this shared confirmation policy.
    static func detect(question: String, labels: [String], descriptions: [String] = []) -> BoundCandidatePermissionConfirmation? {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              labels.count >= 2 else { return nil }
        // Two options are not inherently a confirmation: "Yes, use staging" /
        // "No, use production" still chooses a task. Apply the same complete-label
        // permission rules to every menu, regardless of its option count.
        guard let index = singleApprovalIndex(labels, descriptions: descriptions) else { return nil }
        // Hook answers identify an option by its label, not by its position.
        let answer = labels[index].precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard labels.filter({ $0.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == answer }).count == 1 else { return nil }
        return BoundCandidatePermissionConfirmation(question: question, answer: labels[index])
    }

    static func isDenial(_ label: String) -> Bool {
        isDenial(cleaned: cleaned(label))
    }

    private static func isDenial(cleaned text: String) -> Bool {
        if text.range(of: "(?i)^(?:" + denialWords + ")$", options: .regularExpression) != nil { return true }
        // The CLI's fixed rejection action is still No. Arbitrary explanations
        // after No/Cancel must not turn a different task into a permission menu.
        return text.range(of: #"(?i)^no\s*[,，:：—–-]\s*and tell (?:codex|claude|the agent) what to do differently$"#, options: .regularExpression) != nil
    }

    private static func isUnchangedASCII(_ value: String) -> Bool {
        value.utf8.withContiguousStorageIfAvailable { bytes in
            guard let first = bytes.first, let last = bytes.last else { return true }
            guard first != 32, first != 33, first != 46,
                  last != 32, last != 33, last != 46 else { return false }
            var previousSpace = false
            for byte in bytes {
                guard byte >= 32, byte < 127, byte != 40, byte != 91 else { return false }
                if byte == 32 && previousSpace { return false }
                previousSpace = byte == 32
            }
            return true
        } ?? false
    }

    /// Plain words outside every supported permission prefix cannot become a
    /// confirmation. Hints, whitespace compaction, punctuation cleanup and
    /// Unicode/foreign labels always keep the original parser.
    private static func isPlainNonPermissionWord(_ value: String) -> Bool {
        value.utf8.withContiguousStorageIfAvailable { bytes in
            guard bytes.count <= 4096, let first = bytes.first, first < 128 else { return false }
            switch first | 32 {
            case 97: return false // Allow, approve, always, and
            case 99 where bytes.count >= 3 && bytes[1] | 32 == 97 && bytes[2] | 32 == 110: return false
            case 100 where bytes.count >= 2 && bytes[1] | 32 == 111: return false
            case 100 where bytes.count >= 3 && bytes[1] | 32 == 101 && bytes[2] | 32 == 110: return false
            case 110 where bytes.count >= 2 && bytes[1] | 32 == 111: return false
            case 115 where bytes.count >= 2 && bytes[1] | 32 == 119: return false
            case 117 where bytes.count >= 3 && bytes[1] | 32 == 115 && bytes[2] | 32 == 101: return false
            case 121 where bytes.count >= 3 && bytes[1] | 32 == 101 && bytes[2] | 32 == 115: return false
            default: break
            }
            return isUnchangedASCII(value) && !bytes.contains(32)
        } ?? false
    }

    private static func cleaned(_ value: String) -> String {
        if isUnchangedASCII(value) { return value }
        let hint = #"(?:추천|권장|recommended|[a-z]|esc|shift\s*\+\s*tab)"#
        return value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: #"[‘’ʼ]"#, with: "'", options: .regularExpression)
            .replacingOccurrences(of: "(?i)(?:\\s*(?:\\(" + hint + "\\)|\\[" + hint + "\\]))+\\s*$", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!。！")))
    }

    private static func affirmativeTail(cleaned text: String) -> String? {
        guard let prefix = text.range(of: "(?i)^(?:" + affirmativeWords + #")(?=$|[\s,，:：—–-])[\s,，:：—–-]*"#, options: .regularExpression) else { return nil }
        return String(text[prefix.upperBound...])
    }

    // These descriptions do not depend on a request. Normalize them once rather
    // than repeating regex/string work for every option in every permission menu.
    private static let permissionPhrases: [(compact: String, label: String)] = {
        let descriptions = [
            ("Allow", "Run the tool and continue."),
            ("Allow for this session", "Run the tool and remember this choice for this session."),
            ("Always allow", "Run the tool and remember this choice for future tool calls."),
            ("Allow and don't ask me again", "Run the tool and remember this choice for future tool calls."),
            ("Cancel", "Cancel this tool call.")
        ]
        return descriptions.flatMap { label, description in
            [label, cleaned(label + " " + description)].map { phrase in
                (compact: phrase.filter { !$0.isWhitespace }, label: label)
            }
        }
    }()

    /// Codex renders tool permission labels and descriptions in two columns. Match
    /// only complete known phrases. Terminal cells can wrap inside a word, so the
    /// added line-boundary space must not change those phrases' meaning.
    private static func permissionLabel(_ value: String) -> String {
        let text = cleaned(value)
        let compact = text.filter { !$0.isWhitespace }
        for phrase in permissionPhrases where compact.caseInsensitiveCompare(phrase.compact) == .orderedSame {
            return phrase.label
        }
        return text
    }

    static func isToolPermissionMenu(_ labels: [String]) -> Bool {
        let labels = labels.map { permissionLabel($0).lowercased() }
        let known: Set<String> = ["allow", "allow for this session", "always allow", "allow and don't ask me again",
                                  "cancel", "deny", "don't allow", "do not allow"]
        // Tool capabilities determine which permission scopes are offered. Two,
        // three and four rows are valid; an unrelated task is never a scope.
        return (2...4).contains(labels.count) && labels.allSatisfy(known.contains)
            && singleApprovalIndex(labels) == 0
    }

    private static func isCurrentPermission(_ tail: String) -> Bool {
        tail.isEmpty || tail.range(of: #"(?i)^(?:proceed|continue|allow (?:once|this (?:request|time)(?: only)?)|(?:just )?this (?:once|time only)|for this request only|이번(?: 요청)?만(?:\s*(?:허용|승인|진행)(?:하기|합니다|해 ?주세요)?)?|한\s*번만(?:\s*(?:허용|승인)(?:하기|합니다)?)?|(?:허용|승인|진행)(?:합니다|해 ?주세요)?)$"#, options: .regularExpression) != nil
    }

    private static func isRepeatedPermission(_ value: String) -> Bool {
        isRepeatedPermission(cleaned: cleaned(value))
    }

    private static func isRepeatedPermission(cleaned text: String) -> Bool {
        let english = #"(?i)^(?:and\s+)?(?:(?:don't|do not) ask(?: me)?(?: for (?:approval|permission))? again(?: (?:for:?|in|during) .+| this session)?|always allow(?: .+)?|(?:allow|approve) (?:all (?:edits|commands|changes) )?(?:for|during|in) (?:this|the) (?:session|project|folder)|allow all (?:edits|commands|changes)|allow reading from .+ (?:from this project|during this session))$"#
        // Claude Code also offers its permission modes; each changes only later prompts.
        let mode = #"(?i)^(?:and\s+)?(?:(?:switch to|use) auto mode(?: · .+)?|switch to (?:default|accept edits|auto|don't ask|plan mode|bypass permissions)(?: \([^)]*\))? for this session)$"#
        let scope = #"(?:앞으로|이후(?:에도|부터)?|이(?:번)?\s*(?:세션|프로젝트|폴더|명령)(?:에서(?:는)?|\s*동안(?:에는)?|에\s*대해서(?:는)?)?)"#
        let korean = "^(?:" + scope + #"\s*)?(?:(?:다시|매번)\s*)?묻지\s*않(?:기|음|습니다|아도\s*됩니다|고\s*(?:허용|승인)(?:하기|합니다)?)$"#
        let allow = "^(?:" + scope + #"\s*(?:(?:항상|자동으로|계속)\s*)?|(?:항상|자동으로|계속)\s*)(?:허용|승인)(?:하기|합니다|해\s*주세요)?$"#
        return [english, mode, korean, allow].contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static func isSessionPermission(cleaned text: String) -> Bool {
        text.range(of: #"(?i)^(?:allow|approve) (?:for|during|in) (?:this|the) session$"#, options: .regularExpression) != nil
    }

    /// Prefer one request. If it is not offered, an explicit session-only Allow
    /// is permitted. Never fall back to a permanent permission or a task choice.
    static func singleApprovalIndex(_ labels: [String], descriptions: [String] = []) -> Int? {
        guard labels.count >= 2 else { return nil }
        var current: [Int] = [], sessionOnly: [Int] = [], denials = 0
        for (index, label) in labels.enumerated() {
            if isPlainNonPermissionWord(label) { return nil }
            let label = permissionLabel(label)
            // These predicates inspect the same normalized label. Keep
            // permissionLabel's separate first pass: cleaning is not idempotent
            // for every nested hint and punctuation combination.
            let text = cleaned(label)
            if isDenial(cleaned: text) { denials += 1; continue }
            if isSessionPermission(cleaned: text) { sessionOnly.append(index); continue }
            if isRepeatedPermission(cleaned: text) { continue }
            guard let tail = affirmativeTail(cleaned: text) else { return nil }
            if isRepeatedPermission(tail) || isRepeatedPermission("allow " + tail) { continue }
            guard isCurrentPermission(tail) || isCurrentPermission("allow " + tail) else { return nil }
            // Claude may put the scope in the description beneath a plain Yes label.
            if descriptions.indices.contains(index), isRepeatedPermission(descriptions[index]) { continue }
            current.append(index)
        }
        guard denials == 1 else { return nil }
        if current.count == 1 { return current[0] }
        return current.isEmpty && sessionOnly.count == 1 ? sessionOnly[0] : nil
    }

    public func updatedInput(_ input: JSONObject) -> JSONObject {
        var updated = input
        updated["answers"] = [question: answer]
        return updated
    }
}
// END CANDIDATE PermissionPrefix
import Foundation
import CryptoKit
import AutoApproveCore

enum PermissionPrefixOracle {
    struct Failure: Error { let message: String }
    struct Result { let cases: Int; let foreignInputs: Int; let digest: String; let counts: [String: Int] }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    static func raw(_ text: String) -> String {
        let units = Array(text.utf16).map { $0.littleEndian }
        return Data(text.utf8).base64EncodedString() + ":" + units.withUnsafeBytes { Data($0).base64EncodedString() }
    }
    static func signature(_ value: BoundPreviousPermissionConfirmation?) -> [String] {
        value.map { [raw($0.question), raw($0.answer)] } ?? ["nil"]
    }
    static func signature(_ value: BoundCandidatePermissionConfirmation?) -> [String] {
        value.map { [raw($0.question), raw($0.answer)] } ?? ["nil"]
    }
    static func signature(_ value: YesNoConfirmation?) -> [String] {
        value.map { [raw($0.question), raw($0.answer)] } ?? ["nil"]
    }
    static func run() throws -> Result {
        var digest = SHA256(), counts: [String: Int] = [:], foreignInputs = 0
        func foreign(_ text: String) -> String { NSAppleEventDescriptor(string: text).stringValue! }
        func check(_ labels: [String], descriptions: [String] = [], bank: String) throws {
            let strings = labels + descriptions, before = strings.map(raw), storage = strings.map(\.isContiguousUTF8)
            let index = BoundPreviousPermissionConfirmation.singleApprovalIndex(labels, descriptions: descriptions)
            let actual = BoundCandidatePermissionConfirmation.singleApprovalIndex(labels, descriptions: descriptions)
            try require(index == actual, "Permission index changed in \(bank): \(labels.map(raw))")
            let options: [JSONObject] = labels.enumerated().map { index, label in
                ["label": label, "description": descriptions.indices.contains(index) ? descriptions[index] : ""]
            }
            let input: JSONObject = ["questions": [["question": "Continue with this request?", "multiSelect": false, "options": options]]]
            let expected = signature(BoundPreviousPermissionConfirmation.detect(input))
            let candidate = signature(BoundCandidatePermissionConfirmation.detect(input))
            let linked = signature(YesNoConfirmation.detect(input))
            try require(expected == candidate && expected == linked, "Full or linked Core confirmation changed in \(bank): \(labels.map(raw))")
            try require(strings.map(raw) == before && strings.map(\.isContiguousUTF8) == storage, "Caller bytes or storage changed in \(bank)")
            digest.update(data: try JSONSerialization.data(withJSONObject: [before, expected, [index.map(String.init) ?? "nil"]], options: [.sortedKeys]))
            counts[bank, default: 0] += 1; foreignInputs += storage.filter { !$0 }.count
        }
        func menu(_ label: String, denial: Bool) -> [String] { denial ? ["Yes", label] : [label, "No"] }
        for a in UInt8(0)..<128 { for b in UInt8(0)..<128 {
            let pair = String(decoding: [a, b], as: UTF8.self)
            try check([pair + "task", "No"], bank: "leadingASCIIPairs")
            try check(["Yes" + pair, "No"], bank: "trailingASCIIPairs")
        }}
        let words = ["Yes", "No", "Allow", "Cancel", "Deny", "Always allow"]
        for word in words {
            let bytes = Array(word.utf8), denial = ["No", "Cancel", "Deny"].contains(word)
            for position in 0...bytes.count { for byte in UInt8(0)..<128 {
                var value = bytes; value.insert(byte, at: position)
                let text = String(decoding: value, as: UTF8.self)
                for label in [text, text.uppercased(), foreign(text)] {
                    try check(menu(label, denial: denial), bank: "asciiInsertions")
                }
            }}
        }
        let menus: [[String]] = [
            ["Yes", "No"], ["No", "Yes"], ["Allow", "Cancel"], ["Allow for this session", "Deny"],
            ["Allow", "Allow for this session", "Always allow", "Cancel"], ["Always allow", "No"],
            ["Yes, use staging", "No, use production"], ["Yes", "Other project", "No"], ["Yes", "Yes", "No"],
            ["예", "아니오"], ["허용", "항상 허용", "거부"], ["C a n c e l", "Allow"],
            ["AllowRunTheToolAndContinue", "Cancel"], ["Allow", "CancelCancelThisToolCall"],
            ["Yes [y].", "No"], ["Yes (y).", "No"], ["No", "Allow for this session", "Always allow"],
            ["Development", "Production"], ["Keep current model", "gpt-6"], ["Yes", "No, and tell Codex what to do differently"]
        ]
        try require(menus.count == 20, "Curated menu count changed")
        for base in menus { for variant in 0..<8 { for representation in 0..<2 { for scope in 0..<4 { for reverse in 0..<2 {
            var labels = base.map { text -> String in
                switch variant {
                case 1: return text.lowercased()
                case 2: return text.uppercased()
                case 3: return " !" + text + "! "
                case 4: return text + " [a]!"
                case 5: return text + " (y)."
                case 6: return text.map(String.init).joined(separator: " ")
                case 7: return text.replacingOccurrences(of: " ", with: "\r\n")
                default: return text
                }
            }
            if representation == 1 { labels = labels.map(foreign) }
            if reverse == 1 { labels.reverse() }
            var descriptions = Array(repeating: "", count: labels.count)
            descriptions[0] = ["", "Allow and don't ask me again", "Allow for this session", "The current model"][scope]
            try check(labels, descriptions: descriptions, bank: "curatedMenus")
        }}}}}
        let additions: [UInt32] = [0x100, 0x130, 0x17f, 0x300, 0x301, 0x307, 0x34f, 0x390, 0x3a3, 0x3c2, 0x3c3,
            0x1e9e, 0x200b, 0x200c, 0x200d, 0x2028, 0x2029, 0x2060, 0x212a, 0x212b,
            0xfb00, 0xfb01, 0xfb02, 0xfb03, 0xfb04, 0xfb05, 0xfb06, 0xfeff, 0xfffd, 0x1f4bb, 0x10ffff, 0xbaa8, 0xb378]
        let scalars = Array(UInt32(0)..<256) + additions
        try require(scalars.count == 289 && Set(scalars).count == 289, "Unicode bank changed")
        for scalar in scalars { for word in ["Yes", "Allow", "Cancel", "Deny"] {
            let bytes = Array(word.utf8), denial = ["Cancel", "Deny"].contains(word)
            for position in 0...bytes.count {
                let label = String(decoding: bytes[..<position], as: UTF8.self) + String(Unicode.Scalar(scalar)!) + String(decoding: bytes[position...], as: UTF8.self)
                try check(menu(label, denial: denial), bank: "unicodeInsertions")
                try check(menu(foreign(label), denial: denial), bank: "unicodeInsertions")
            }
        }}
        let names = ["Development", "Production", "Staging", "Preview", "Main", "Other", "Current", "ProjectA", "ProjectB", "De n y",
            "NoThing", "DENIAL", "cancelled", "Allowlist", "YesNo", "no", "yes", "deny", "cancel", "allow"]
        for a in names { for b in names { for scope in 0..<2 { for representation in 0..<2 {
            let labels = representation == 0 ? [a,b] : [foreign(a),foreign(b)]
            try check(labels, descriptions: scope == 0 ? [] : ["Allow for this session", ""], bank: "optionNames")
        }}}}
        for length in [0, 15, 255, 256, 4095, 4096, 4097, 8192] { for word in ["Development", "Allow", "Cancel", "Yes"] {
            let fill = String(repeating: "x", count: max(0,length-word.utf8.count))
            for label in [length == 0 ? "" : word + fill, length == 0 ? "" : fill + word] {
                try require(label.utf8.count == length, "Length boundary changed")
                try check(menu(label, denial: word == "Cancel"), bank: "lengthBoundaries")
                try check(menu(foreign(label), denial: word == "Cancel"), bank: "lengthBoundaries")
            }
        }}
        let malformed: [[UInt16]] = [[0xd800], [0xdc00], [0xd800,0xd800,0xdc00], [0xdc00,0xd800],
            [0xd800,10,0xdc00], [0xd800,0xdc00], [0xffff,0xfffd,0,27], [0x301,0xfeff,0x200d]]
        for units in malformed {
            let source = units.withUnsafeBufferPointer { NSString(characters:$0.baseAddress!,length:$0.count) as String }
            for word in ["Yes", "Allow", "Cancel", "Deny"] { for value in [source,String(decoding:units,as:UTF16.self)] {
                for label in [value+word, word+value, "De"+value+"velopment"] {
                    try check(menu(label, denial: ["Cancel","Deny"].contains(word)), bank: "malformedUTF16")
                }
            }}
        }
        let expected = ["leadingASCIIPairs":16384,"trailingASCIIPairs":16384,"asciiInsertions":14592,"curatedMenus":2560,
            "unicodeInsertions":12716,"optionNames":1600,"lengthBoundaries":128,"malformedUTF16":192]
        try require(counts == expected, "Missing permission prefix coverage: \(counts)")
        let cases=counts.values.reduce(0,+);try require(cases == 64556 && foreignInputs>0, "Missing prefix or foreign-string cases")
        return Result(cases:cases,foreignInputs:foreignInputs,digest:digest.finalize().map { String(format:"%02x",$0) }.joined(),counts:counts)
    }
}
