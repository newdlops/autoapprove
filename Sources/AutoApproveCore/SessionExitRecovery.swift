import Foundation

/// A stopped CLI can return only to its original shell and exact conversation.
/// This record is private runtime state; it never creates a terminal or chooses --last.
public struct SessionExitRecovery: Codable {
    public var session: AgentSession
    public var shell: ProcessRecord
    public var executable: String
    public var conversationID: String?
    public var state: String = "ready"
    public var deadline: Date?
    public var attempts: Int = 0
    /// An explicit opt-out after launch must not enable automation on the replacement CLI.
    /// Missing in older saved plans: preserve their original recovery behavior.
    public var automaticCancelled: Bool?
    public init(session: AgentSession, process: ProcessRecord, shell: ProcessRecord, conversationID: String?) {
        self.session = session; self.shell = shell; executable = process.executable
        self.conversationID = conversationID.flatMap { UUID(uuidString:$0)?.uuidString.lowercased() }
    }
    public static func isShell(_ record: ProcessRecord) -> Bool {
        ["zsh","bash","sh","fish","dash","ksh"].contains(URL(fileURLWithPath:record.executable).lastPathComponent)
    }
    public static func conversation(in screen: String) -> String? {
        let pattern = #"^To continue this session, run codex resume ([0-9a-fA-F-]{36})\s*$"#
        for line in PromptDetector.normalizedLines(screen).suffix(40).reversed() {
            let text = line.trimmingCharacters(in:.whitespaces)
            if let range = text.range(of:pattern,options:.regularExpression) {
                let value = text[range].split(whereSeparator:{$0.isWhitespace}).last.map(String.init) ?? ""
                if let uuid = UUID(uuidString:value) { return uuid.uuidString.lowercased() }
            }
        }
        return nil
    }
    public static func emptyShellPrompt(_ screen: String) -> Bool {
        guard let row = PromptDetector.normalizedLines(screen).last?.trimmingCharacters(in:.whitespaces),
              !row.isEmpty, row.count < 1000, let last = row.last, "$%#❯➜".contains(last) else { return false }
        // Agent composers and dialogs are never shell prompts.
        return !row.hasPrefix("›") && !row.hasPrefix("❯") && !row.hasPrefix("API Error:") && !row.hasPrefix("■")
    }
    public func verifiedShell(in records: [ProcessRecord]) -> ProcessRecord? {
        guard !records.contains(where:{$0.pid == session.pid && $0.started == session.started}),
              let live = records.first(where:{$0.pid == shell.pid && $0.started == shell.started && $0.tty == shell.tty}),
              Self.isShell(live), live.isForeground else { return nil }
        let foreground = records.filter {$0.tty == live.tty && $0.processGroup == live.foregroundGroup}
        guard foreground.count == 1, foreground[0].pid == live.pid else { return nil }
        return live
    }
    public var command: String? {
        guard let conversationID, UUID(uuidString:conversationID) != nil,
              executable.hasPrefix("/"), !executable.unicodeScalars.contains(where:{$0.value < 32 || $0.value == 127}),
              session.agent == .codex || session.agent == .claude else { return nil }
        let args = session.agent == .codex ? [executable,"resume",conversationID,CodexCapacityStop.resumeText]
            : [executable,"--resume",conversationID,CodexCapacityStop.resumeText]
        return args.map(HookInstaller.quote).joined(separator:" ")
    }
}
