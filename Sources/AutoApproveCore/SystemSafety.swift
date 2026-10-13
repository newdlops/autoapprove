import Foundation

/// Public status is deliberately separate from the private saved composer used
/// for single-use delivery. A warning remains visible after safe redirection.
public struct SystemSafetyNotice: Codable, Equatable, Identifiable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case detected, cancelling, cancelled, typing, draft, submitting, guided, uncertain, unavailable
    }
    public var id: String
    public var risk: SystemCommandRisk
    public var request: String
    public var phase: Phase = .detected
    public var message: String = "시스템 변경을 승인하지 않고 안전한 대안을 안내합니다."
    public var date = Date()
    public var updatedAt = Date()
    public var isPending: Bool { ![.guided, .uncertain].contains(phase) }
    public init(id: String, risk: SystemCommandRisk, request: String, at date: Date = Date()) {
        self.id = id; self.risk = risk; self.request = String(request.prefix(4000)); self.date = date; self.updatedAt = date
    }
}

struct SystemSafetyState: Codable {
    var notice: SystemSafetyNotice
    var generation: String?
    var promptIdentity: String?
    var draft: SystemSafetyComposer?
    var submitAttempts = 0
    var retryAfter: Date?
    var cancelledAt: Date?
    var hookRequestID: String?
}

/// Only a known idle CLI composer may receive a new instruction. The original
/// transcript and complete draft body are checked again before each Return.
/// This avoids submitting user notes, menus, shell prompts or a newline-only send.
public struct SystemSafetyComposer: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var prefix: [String]
    public var footer: [String]
    public var text: String

    public static func capture(_ screen: String, agent: AgentKind, text: String) -> Self? {
        guard ActivityDetector.detect(screen, agent: agent).phase == .idle,
              !RemoteMessageReadiness.hasMenu(screen, agent: agent),
              !CodexResumeCheck.goalHeld(rows(screen)), !text.isEmpty,
              !text.contains("\n"), !text.contains("\r"), !text.contains("\0"),
              let index = composerIndex(rows(screen), agent: agent) else { return nil }
        let lines = rows(screen)
        return Self(agent: agent, prefix: Array(lines[..<index]), footer: Array(lines.dropFirst(index + 1)), text: text)
    }

    public func draftReady(_ screen: String) -> Bool {
        let lines = Self.rows(screen)
        guard !RemoteMessageReadiness.hasMenu(screen, agent: agent),
              !CodexResumeCheck.blocked(lines), !CodexResumeCheck.goalHeld(lines),
              ActivityDetector.detect(screen, agent: agent).phase != .working,
              let index = Self.composerIndex(lines, agent: agent),
              Self.compact(Array(lines[..<index])) == Self.compact(prefix) else { return false }
        let tail = Array(lines.dropFirst(index + 1)), variants = footerVariants()
        guard let end = variants.compactMap({ variant -> Int? in
            let nonempty = tail.indices.filter { !tail[$0].isEmpty }
            guard nonempty.count >= variant.count,
                  Array(nonempty.suffix(variant.count)).map({ tail[$0] }) == variant else { return nil }
            return variant.isEmpty ? tail.count : nonempty[nonempty.count - variant.count]
        }).first else { return false }
        let body = [String(lines[index].dropFirst()).trimmingCharacters(in: .whitespaces)] + Array(tail.prefix(end))
        return Self.compact(body) == Self.compact([text])
    }

    public func submitted(_ screen: String) -> Bool {
        let lines = Self.rows(screen)
        // A menu or unchanged owned draft is never a submission acknowledgement.
        guard !draftReady(screen), !RemoteMessageReadiness.hasMenu(screen, agent: agent),
              let index = Self.composerIndex(lines, agent: agent) else { return false }
        let transcript = Array(lines[..<index]), wanted = Self.compact([text])
        let previousCount = Self.compact(prefix).components(separatedBy: wanted).count
        let currentCount = Self.compact(transcript).components(separatedBy: wanted).count
        return currentCount > previousCount
    }

    private func footerVariants() -> [[String]] {
        let original = footer.filter { !$0.isEmpty }
        guard agent == .codex else { return [original] }
        let hidden = original.map {
            $0.replacingOccurrences(of: #"← for agents\s*·\s*\? for shortcuts|\? for shortcuts"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return original == hidden ? [original] : [original, hidden]
    }
    private static func rows(_ screen: String) -> [String] {
        PromptDetector.normalizedLines(screen).map { $0.trimmingCharacters(in: .whitespaces) }
    }
    private static func composerIndex(_ lines: [String], agent: AgentKind) -> Int? {
        let glyphs = agent == .codex ? "›»" : "❯"
        return lines.lastIndex { $0.first.map { glyphs.contains($0) } == true }
    }
    private static func compact(_ lines: [String]) -> String {
        lines.joined().precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
    }
}
