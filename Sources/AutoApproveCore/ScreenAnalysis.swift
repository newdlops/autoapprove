import Foundation

/// Immutable detector results may cross from a host's reader to the UI actor.
/// Prepared scrollback rows are confined to this initializer and never cached.
struct ScreenAnalysis: Sendable {
    let raw: String
    let agent: AgentKind
    let prompt: ApprovalPrompt?
    let request: PendingScreenRequest?
    let activity: ActivityObservation
    let capacityStop: CodexCapacityStop?
    let fingerprint: String

    init(raw: String, agent: AgentKind) {
        self.raw = raw; self.agent = agent
        let lines = DetectionLines(raw)
        let prompt = PromptDetector.detect(raw, agent: agent, prepared: lines)
        self.prompt = prompt
        let activity = ActivityDetector.detect(raw, agent: agent, permissionPrompt: { prompt != nil })
        self.activity = activity
        let stop = CodexCapacityStop.detect(raw, agent: agent, activity: activity, prepared: lines)
        capacityStop = stop
        if prompt == nil, stop == nil {
            if let request = QuestionDetector.detect(agent: agent, prepared: lines) { self.request = request }
            else if agent == .codex, TerminalChoiceQuestion.hasCodexOverlay(raw) {
                request = PendingScreenRequest(phase: .input, summary: TerminalChoiceQuestion.detect(raw, agent: agent)?.question ?? "Codex가 질문의 답변을 기다리고 있습니다. 원본 입력란에서 답변해주세요.")
            } else { request = nil }
        } else { request = nil }
        // ActivityTracker asks for this only when confirming an idle composer.
        fingerprint = activity.phase == .idle ? PromptDetector.fingerprint(raw) : ""
    }

    func matches(_ raw: String, agent: AgentKind) -> Bool {
        self.agent == agent && self.raw.utf8.elementsEqual(raw.utf8)
    }
}
