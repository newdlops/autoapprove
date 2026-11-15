import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testClaudeMailboxComposerSeparatesCustomStatusFromDrafts() throws {
        let rule = String(repeating: "─", count: 30)
        let status = "user@host project (main) | Opus 4.7 | ctx 32% | 5h 12% (resets 23:00) | 7d 53% (resets Tue 18:00)"
        func framed(_ body: String, footer: String = "custom status") -> String {
            "answer\n\(rule)\n❯ \(body)\n\(rule)\n\(footer)"
        }
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
                       "answer\n❯ \n" + status + "\n? for shortcuts", // No boundary: unknown text could be a draft.
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
    }
}
