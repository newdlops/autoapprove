import SwiftUI
import AutoApproveCore

@main struct NativeQuestionQueueCheck {
    @MainActor static func main() async throws {
        let actions = CodexQuestionActions()
        let question = QueuedQuestion(id: "question", threadID: "thread", title: "합성 질문", options: ["개발", "시험"])
        func display(id: String = "session", questions: [QueuedQuestion]? = nil, error: String? = nil,
                     observed: Bool = true, canReveal: Bool = true, opening: Bool = false,
                     handlers: CodexQuestionActions? = nil, drafts: QuestionReplyDrafts? = nil) -> CodexQuestionListDisplay {
            .init(sessionID: id, questions: questions ?? [question], connectionError: error,
                observed: observed, canReveal: canReveal, openingTerminal: opening, actions: handlers ?? actions, drafts: drafts)
        }
        let base = display()
        precondition(base == display())
        var changed = question; changed.title = "변경된 질문"
        var replying = question; replying.reply = .init(phase: .sending, answer: "개발", message: "전달 중")
        var automation = question; automation.automation = .init(phase: .editing)
        let variants = [display(id: "other"), display(questions: []), display(questions: [changed]),
            display(questions: [replying]), display(questions: [automation]), display(error: "기록 읽기 실패"),
            display(observed: false), display(canReveal: false), display(opening: true),
            display(handlers: CodexQuestionActions()), display(drafts: QuestionReplyDrafts())]
        precondition(variants.allSatisfy { $0 != base })

        var calls: [String] = []
        for generation in 0..<2 {
            actions.update(dismiss: { calls.append("dismiss:\(generation):\($0)") },
                reply: { calls.append("reply:\(generation):\($0):\($1)") }, reveal: { calls.append("reveal:\(generation)") },
                beginReply: { calls.append("begin:\(generation):\($0)") },
                cancelAutomaticReply: { calls.append("cancel:\(generation):\($0)") })
        }
        // The retained display remains equal, while all controls use new handlers.
        precondition(base == display())
        actions.dismiss("question"); try await actions.reply("question", "합성 답변")
        actions.reveal(); actions.beginReply("question"); actions.cancelAutomaticReply("question")
        precondition(calls == ["dismiss:1:question", "reply:1:question:합성 답변", "reveal:1", "begin:1:question", "cancel:1:question"])
        actions.update(dismiss: { _ in }, reply: { _,_ in throw AppError.message("합성 실패") },
            reveal: {}, beginReply: { _ in }, cancelAutomaticReply: { _ in })
        do { try await actions.reply("question", "답변"); preconditionFailure("Reply errors must propagate") }
        catch { precondition(error.localizedDescription == "합성 실패") }
        let drafts = QuestionReplyDrafts()
        let first = drafts.draft(sessionID: "first", questionID: "question")
        first.selected = [1]; first.customAnswer = "초안 e\u{301} 🧪"; first.submitting = true; first.error = "합성 오류"
        let retained = drafts.draft(sessionID: "first", questionID: "question")
        precondition(first === retained && retained.selected == [1] && retained.customAnswer == "초안 e\u{301} 🧪")
        precondition(retained.submitting && retained.error == "합성 오류")
        let other = drafts.draft(sessionID: "second", questionID: "question")
        precondition(other !== first && other.customAnswer.isEmpty && other.selected.isEmpty && !other.submitting)
        drafts.retain([.init(sessionID: "second", questionID: "question")])
        precondition(drafts.draft(sessionID: "second", questionID: "question") === other)
        precondition(drafts.draft(sessionID: "first", questionID: "question") !== first)
        drafts.retain([])
        precondition(drafts.draft(sessionID: "second", questionID: "question") !== other)
        print("{\"displayVariants\":\(variants.count),\"latestHandlers\":\(calls.count),\"replyErrorsPropagate\":true,\"draftIdentityAndState\":true,\"sessionIsolation\":true,\"removedDraftsPruned\":true}")
    }
}
