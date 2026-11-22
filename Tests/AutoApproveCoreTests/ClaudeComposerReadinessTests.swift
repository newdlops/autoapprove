import Foundation
import AutoApproveCore

extension ApprovalTests {
    @MainActor func testClaudeMailboxComposerSeparatesCustomStatusFromDrafts() async throws {
        let original = "AutoApprove 요청 " + UUID().uuidString
        for ending in ["", "\r", "\n", "\r\n", "\r\r", "\n\n", " 편집", "\r편집"] {
            let buffer = original + ending
            let accepted = await ClaudeComposerReadiness.matchesBridgeDraft(original, visibleMatch: true) {
                $0 == buffer ? "matchingDraft" : "differentDraft"
            }
            try expectEqual(accepted, ["", "\r", "\n", "\r\n"].contains(ending))
        }
        try expect(!(await ClaudeComposerReadiness.matchesBridgeDraft(original, visibleMatch: false) {
            $0 == original + "\r" ? "matchingDraft" : "differentDraft"
        }))
        try expect(!(await ClaudeComposerReadiness.matchesBridgeDraft(original, visibleMatch: true) { _ in nil }))
        let rule = String(repeating: "─", count: 30)
        let status = "user@host project (main) | Opus 4.7 | ctx 32% | 5h 12% (resets 23:00) | 7d 53% (resets Tue 18:00)"
        func framed(_ body: String, footer: String = "custom status") -> String {
            "answer\n\(rule)\n❯ \(body)\n\(rule)\n\(footer)"
        }
        try expect(ClaudeTerminalSuggestion.matchesInk(marker: (52, 235), text: (52, 163), hint: (54, 169)))
        try expect(!ClaudeTerminalSuggestion.matchesInk(marker: (52, 235), text: (52, 235), hint: (54, 169)))
        try expect(!ClaudeTerminalSuggestion.matchesInk(marker: (52, 235), text: (52, 163), hint: (54, 225)))
        let suggestion = "진행상황은?"
        try expectEqual(ClaudeComposerReadiness.framedCandidate(framed(suggestion)), suggestion)
        try expect(!ClaudeComposerReadiness.isEmpty(framed(suggestion)), "Plain text alone cannot authorize a suggested prompt")
        try expectNil(ClaudeComposerReadiness.framedCandidate(framed("draft\nsecond line")))
        try expectNil(ClaudeComposerReadiness.framedCandidate(framed(suggestion, footer: "esc to interrupt")))
        try expect(ClaudeComposerReadiness.containsOnly("group message", screen: framed("group message")))
        try expect(!ClaudeComposerReadiness.containsOnly("group message", screen: framed(suggestion)))
        try expect(!ClaudeComposerReadiness.containsOnly("group message", screen: framed("group message plus draft")))
        try expect(ClaudeComposerReadiness.containsOnly("group message 전달", screen: framed("group mes\nsage\n전달")))
        try expect(!ClaudeComposerReadiness.containsOnly("group message 전달", screen: framed("group mes\nsage\n수정 전달")))
        try expect(ClaudeComposerReadiness.containsOnly("group message 전달", screen: framed("group mes\nsage\n전달\n")))
        try expect(!ClaudeComposerReadiness.containsOnly("group message 전달", screen: framed("group mes\n\nsage\n전달\n")))
        try expect(!ClaudeComposerReadiness.containsOnly("group message 전달", screen: framed("group message 전달\n사용자 입력\n")))
        try expect(!ClaudeComposerReadiness.containsOnly("group message 전달", screen: framed("group message 전달\n\n")))
        let custom = framed("", footer: status)
        try expectEqual(ActivityDetector.detect(custom, agent: .claude).phase, .unknown,
                        "Input readiness must not change general activity or manufacture completion")
        for screen in [custom, framed("", footer: "user@host project (main) | Opus 4.7\n| ctx 32% | 5h 12%\n(resets 23:00) | 7d 53%"),
                       framed("Try \"explain this code\"", footer: status), "answer\n❯ \n? for shortcuts",
                       framed("", footer: "⏵⏵ auto mode on · 1 shell\n" + status),
                       "```swift\nlet value = 1\n```\n" + custom,
                       "```\n" + Array(repeating: "answer", count: 8).joined(separator: "\n") + "\n❯ \n? for shortcuts"] {
            try expect(ClaudeComposerReadiness.isEmpty(screen), "A visible empty composer must survive custom footer text")
        }
        for screen in [framed("user draft", footer: status), framed("\ncontinued draft", footer: status),
                       framed("\n---\nmultiline markdown", footer: status), framed("\n\(rule)\ncontinued draft", footer: status),
                       "answer\n❯ \n" + status + "\n? for shortcuts",
                       "❯ \n\(rule)\n" + status, "\(rule)\n❯ \n" + status,
                       framed("", footer: String(repeating: "long", count: 600)),
                       framed("", footer: Array(repeating: "status", count: 9).joined(separator: "\n")),
                       framed("", footer: "1 to review · 2 to send · 0 to dismiss\n⏵⏵ auto mode on · 1 feedback draft"),
                       framed("", footer: "esc to interrupt"),
                       framed("", footer: "Which environment?\n❯ 1. Development\n  2. Production\nEnter to select"),
                       framed("", footer: "Do you want to proceed?\n$ echo fixture\n❯ 1. Yes\n  2. No\nEsc to cancel"),
                       "```\n" + custom + "\n```"] {
            try expect(!ClaudeComposerReadiness.isEmpty(screen), "Drafts, menus and ambiguous/clipped composers must stay blocked")
        }
        let labelled = String(repeating: "─", count: 40) + " 4번 ─"
        func named(_ body: String, top: String = labelled) -> String { "answer\n\(top)\n❯ \(body)\n\(rule)\n\(status)\n⏵⏵ auto mode on (shift+tab to cycle)" }
        for screen in [named(""), named("", top: "─── fixture 리뷰 ───"), named("Try \"fix lint errors\"")] {
            try expect(ClaudeComposerReadiness.isEmpty(screen), "A name inside the composer border must not block delivery")
        }
        for screen in [named("draft text"), named("", top: "─── two labels ─── here ─"), named("", top: "─── " + String(repeating: "x", count: 41) + " ─"),
                       named("", top: "──name──"), named("", top: "text ─────")] {
            try expect(!ClaudeComposerReadiness.isEmpty(screen), "Drafts and text that is not a border label stay blocked")
        }
        func reason(_ screen: String, input: String? = nil) -> String { ApprovalEngine.composerHoldReason(screen, agent: .claude, inputReason: input) }
        try expectEqual(reason(framed("user draft", footer: status)), "Claude 추천 문구와 작성 중인 글을 구분할 수 없음")
        try expectEqual(reason(framed("", footer: "Which environment?\n❯ 1. Development\n  2. Production\nEnter to select")), "선택지나 확인 화면이 열려 있음")
        try expectEqual(reason("✻ Thinking… (12s · esc to interrupt)\n\(rule)\n❯ \n\(rule)"), "세션이 작업 중임")
        try expectEqual(reason("answer\n❯ \n" + status + "\n? for shortcuts"), "입력창 모양을 판독하지 못함")
        try expectEqual(reason(custom, input: "Claude Code에서 셸 명령 실행 중"), "터미널이 입력을 받을 수 없음(Claude Code에서 셸 명령 실행 중)")
    }
}
