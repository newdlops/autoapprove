import Foundation

/// Wire fields from the official Antigravity CLI. A conversation ID identifies
/// a conversation, never the process authorized to operate on a session.
public struct AgyHookRequest: Decodable {
    public enum Event: String, Decodable {
        case sessionStart = "SessionStart"
        case preInvocation = "PreInvocation"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case stop = "Stop"
    }

    public struct ToolCall: Decodable {
        public let id: String?
        public let name: String
        public let commandLine: String?

        private enum CodingKeys: String, CodingKey { case id, name, args }
        private enum ArgumentKey: String, CodingKey { case commandLine = "CommandLine" }

        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decodeIfPresent(String.self, forKey: .id)
            name = try fields.decode(String.self, forKey: .name)
            if name == "run_command", fields.contains(.args) {
                let args = try fields.nestedContainer(keyedBy: ArgumentKey.self, forKey: .args)
                commandLine = try args.decodeIfPresent(String.self, forKey: .commandLine)
            } else {
                commandLine = nil
            }
        }
    }

    public let hookEventName: Event
    public let conversationId: String
    public let toolCall: ToolCall?
    public let transcriptPath: String?
    public let modelName: String?
    public let fullyIdle: Bool?
    public let terminationReason: String?

    public var isIdle: Bool {
        switch hookEventName {
        case .sessionStart: return true
        case .stop: return fullyIdle == true
        case .preInvocation, .preToolUse, .postToolUse: return false
        }
    }
}

/// The idle CLI puts one prompt row between horizontal rules followed by its model footer.
public enum AgyComposerReadiness {
    public static func isEmpty(_ screen: String) -> Bool {
        let rows = PromptDetector.normalizedLines(screen).suffix(30).map { $0.trimmingCharacters(in: .whitespaces) }
        func rule(_ s: String) -> Bool { s.count >= 4 && s.allSatisfy { $0 == "─" } }
        guard let bottom = rows.lastIndex(where: rule), bottom >= 2,
              rule(rows[bottom-2]), rows.dropFirst(bottom+1).first(where: { !$0.isEmpty })?.contains(" | ") == true else { return false }
        let prompt = rows[bottom-1]
        return prompt == ">" || prompt == "> Auto mode: edits & safe commands auto-approved (shift+tab to cycle)"
    }
}
