import Foundation

/// Immutable detector results may cross from a host's reader to the UI actor.
/// Prepared scrollback rows are confined to this initializer and never cached.
struct ScreenAnalysis: Sendable {
    /// Preserve the existing cache budget without retaining another copy of
    /// the terminal frame; ApprovalEngine already owns the observed source.
    let sourceByteCount: Int
    let agent: AgentKind
    let prompt: ApprovalPrompt?
    let request: PendingScreenRequest?
    let modelChoice: TerminalChoiceQuestion?
    let activity: ActivityObservation
    let capacityStop: CodexCapacityStop?
    let fingerprint: String

    init(raw: String, agent: AgentKind) {
        let lines = DetectionLines(raw)
        self.agent = agent
        let prompt = PromptDetector.detect(raw, agent: agent, prepared: lines)
        self.prompt = prompt
        let activityTail = agent == .shell ? [] : ActivityDetector.nonemptyTail(raw)
        let activity = ActivityDetector.detect(raw, agent: agent, preparedTail: activityTail, permissionPrompt: { prompt != nil })
        self.activity = activity
        let stop = CodexCapacityStop.detect(raw, agent: agent, activity: activity, prepared: lines)
        capacityStop = stop
        let request: PendingScreenRequest?
        if prompt == nil, stop == nil {
            if let detected = QuestionDetector.detect(agent: agent, prepared: lines) { request = detected }
            else if agent == .codex, TerminalChoiceQuestion.hasCodexOverlay(prepared: lines) {
                let question = TerminalChoiceQuestion.detect(raw, agent: agent, prepared: lines,
                    permissionPrompt: prompt, request: nil)?.question
                request = PendingScreenRequest(phase: .input, summary: question ?? "Codex가 질문의 답변을 기다리고 있습니다. 원본 입력란에서 답변해주세요.")
            } else { request = nil }
        } else { request = nil }
        self.request = request
        // Only a complete current question parses another menu. Ordinary output
        // never scans model names or constructs a model preference candidate.
        if agent != .shell, prompt == nil, stop == nil, request?.phase == .input,
           let choice = TerminalChoiceQuestion.detect(raw, agent: agent, prepared: lines, permissionPrompt: prompt, request: request),
           AutomaticQuestionDecision.currentModelIndex(question: choice.question, options: choice.options) != nil {
            modelChoice = choice
        } else { modelChoice = nil }
        // ActivityTracker asks for this only when confirming an idle composer.
        fingerprint = activity.phase == .idle ? ActivityDetector.readinessFingerprint(tail: activityTail) : ""
        sourceByteCount = lines.sourceByteCount
    }

}
