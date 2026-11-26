import Foundation

public struct TerminalProfileExecutionSettings: Codable, Equatable, Sendable {
    public var model: String?
    public var reasoningEffort: String?
    public var serviceTier: String?
    public init(model: String? = nil, reasoningEffort: String? = nil, serviceTier: String? = nil) {
        self.model = model; self.reasoningEffort = reasoningEffort; self.serviceTier = serviceTier
    }
    public var isEmpty: Bool { model == nil && reasoningEffort == nil && serviceTier == nil }
    public func validated(agent: String) throws -> Self {
        guard model.map({ !$0.isEmpty && $0.first.map { $0.isLetter || $0.isNumber } == true && $0.count <= 256 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/+".contains($0)) } }) ?? true,
              reasoningEffort.map({ (agent == "codex" ? ["none","minimal","low","medium","high","xhigh","max","ultra"] : ["low","medium","high","xhigh","max"]).contains($0) }) ?? true,
              serviceTier.map({ agent == "codex" && ["default","priority","ultrafast","flex"].contains($0) }) ?? true else {
            throw AppError.message("모델·추론 수준·처리 속도 설정을 확인해주세요.")
        }
        return self
    }
    public var summary: String {
        [model, reasoningEffort.map { "추론 " + $0 }, serviceTier.map {
            switch $0 { case "priority": return "Fast"; case "ultrafast": return "Ultrafast"; case "default": return "Standard"; default: return $0.capitalized }
        }].compactMap { $0 }.joined(separator: " · ")
    }
    func arguments(agent: String) throws -> [String] {
        let value = try validated(agent: agent)
        var result: [String] = []
        if let model = value.model { result += ["--model", model] }
        if let effort = value.reasoningEffort {
            result += agent == "codex" ? ["-c", "model_reasoning_effort=\"" + effort + "\""] : ["--effort", effort]
        }
        if let tier = value.serviceTier { result += ["-c", "service_tier=\"" + tier + "\""] }
        return result
    }
}

public enum TerminalProfileExecutionSettingsReader {
    static let reader = SessionGroupModelSettingsReader()

    static func home(for agent: AgentKind, environment: [String: String] = [:]) -> String? {
        let base = environment["HOME"] ?? NSHomeDirectory()
        switch agent {
        case .codex: return environment["CODEX_HOME"] ?? base + "/.codex"
        case .claude: return environment["CLAUDE_CONFIG_DIR"] ?? base + "/.claude"
        case .agy: return base + "/.gemini/antigravity"
        case .shell: return nil
        }
    }

    public static func refreshed(_ entries: [TerminalProfileEntry]) -> [TerminalProfileEntry] {
        let connection = CodexThreadSettingsConnection()
        return entries.map { entry in
            guard !Task.isCancelled, entry.resumesConversation, entry.usesProfileReasoningEffort != true,
                  let agent = AgentKind(rawValue: entry.agent) else { return entry }
            let value = reader.read(agent: agent, cwd: entry.cwd, conversationID: entry.conversationID,
                                    home: entry.providerHome ?? home(for: agent), connection: connection)
            var copy = entry, settings = entry.executionSettings ?? .init()
            let effort = TerminalProfileExecutionSettings(reasoningEffort: value?.reasoningEffort)
            settings.reasoningEffort = (try? effort.validated(agent: entry.agent))?.reasoningEffort
            copy.executionSettings = settings.isEmpty ? nil : settings
            return copy
        }
    }

    public static func read(_ live: SessionGroupLiveSession) -> TerminalProfileExecutionSettings? {
        guard !live.providerIdentityAmbiguous else { return nil }
        let value = reader.read(agent: live.session.agent, cwd: live.session.cwd, conversationID: live.conversationID,
                                home: live.providerHome, includeTier: true, connection: CodexThreadSettingsConnection())
        let settings = TerminalProfileExecutionSettings(model: value?.model, reasoningEffort: value?.reasoningEffort, serviceTier: value?.serviceTier)
        return settings.isEmpty ? nil : try? settings.validated(agent: live.session.agent.rawValue)
    }
}
