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
        public let targetPath: String?

        private enum CodingKeys: String, CodingKey { case id, name, args }
        private enum ArgumentKey: String, CodingKey { case commandLine = "CommandLine", file = "AbsolutePath", path = "Path", directory = "DirectoryPath" }

        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decodeIfPresent(String.self, forKey: .id)
            name = try fields.decode(String.self, forKey: .name)
            let args = try fields.contains(.args) ? fields.nestedContainer(keyedBy: ArgumentKey.self, forKey: .args) : nil
            commandLine = name == "run_command" ? try args?.decodeIfPresent(String.self, forKey: .commandLine) : nil
            let legacy = try args?.decodeIfPresent(String.self, forKey: name == "list_dir" ? .directory : .file)
            let path = name == "read_file" ? try args?.decodeIfPresent(String.self, forKey: .path) : nil
            targetPath = path == nil || legacy == nil || path == legacy ? (path ?? legacy) : nil
        }
    }

    public let hookEventName: Event
    public let conversationId: String
    public let toolCall: ToolCall?
    public let transcriptPath: String?
    public let modelName: String?
    public let fullyIdle: Bool?
    public let terminationReason: String?

    package func permission(automatic: Bool, cwd: String?) -> JSONObject {
        if let call = toolCall, let risk = SystemCommandRisk.detect(tool: call.name,
            input: call.commandLine.map { ["command": $0] } ?? [:], cwd: cwd ?? "") {
            return ["decision": risk.blocksAutomatically ? "deny" : "ask", "reason": risk.detail]
        }
        guard hookEventName == .preToolUse, automatic, let toolCall else { return ["decision": "ask"] }
        if toolCall.name == "run_command", toolCall.commandLine == "/bin/pwd" { return ["decision": "auto_approve"] }
        guard ["view_file", "read_file", "list_dir"].contains(toolCall.name),
              let path = toolCall.targetPath, path.hasPrefix("/"), let cwd, cwd.hasPrefix("/") else { return ["decision": "ask"] }
        let root = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().standardizedFileURL.path
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard root != "/", target == root || target.hasPrefix(root + "/") else { return ["decision": "ask"] }
        return ["decision": "auto_approve"]
    }

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
