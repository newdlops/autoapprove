import Foundation
import JavaScriptCore
import AutoApproveCore

// Codex 0.158–0.159 approval overlay snapshots (tui/src/bottom_pane/approval_overlay).
private let subAgentApproval = """
  Would you like to run the following command?

  Thread: Robie [explorer]

  $ echo hi


› 1. Yes, proceed (y)
  2. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel or o to open thread
"""
private let clippedApproval = """
  Would you like to run the following command?

  Environment: local

  Reason: A reason requiring review.A reason requiring review.A reason
  requiring review.A reason requiring review.A reason requiring review.A
  [… 34 lines] ctrl+g view all
› 1. Yes, proceed (y)
  2. No, and tell Codex what to do differently (esc)
  Press enter to confirm or esc to cancel
"""

extension ApprovalTests {
    func testCodexSubAgentAndClippedApprovals() throws {
        // A sub-agent's request follows the parent's in the same overlay queue and adds `o to open thread`.
        let prompt = PromptDetector.detect("• Ran npm test\n" + subAgentApproval, agent: .codex)
        try expectEqual(prompt?.answer, "1")
        try expect(prompt?.summary.contains("Thread: Robie [explorer]") == true, "The requesting thread stays in the audit summary")
        try expectEqual(QuestionDetector.detect(subAgentApproval, agent: .codex)?.phase, .approval)
        try expectEqual(ActivityDetector.detect(subAgentApproval, agent: .codex).phase, .approval)
        try expectNil(PromptDetector.detect(subAgentApproval.replacingOccurrences(of: "or o to open thread", with: "or x to run everything"), agent: .codex))
        try expect(PromptDetector.detect(subAgentApproval + "\n› Next input", agent: .codex) == nil, "Later output still retires the dialog")
        try expectNil(PromptDetector.detect(subAgentApproval.replacingOccurrences(of: "› 1.", with: "  1.").replacingOccurrences(of: "  2.", with: "› 2."), agent: .codex))
        try expectNil(PromptDetector.detect(subAgentApproval, agent: .claude))

        // The final check compares the same active dialog in the terminal before typing.
        let context = JSContext()!
        context.setObject(subAgentApproval, forKeyedSubscript: "current" as NSString)
        context.evaluateScript("""
        var writes = [];
        var tab = {tty: () => '/dev/fixture', contents: () => current, processes: () => ['codex']};
        function Application(id) { return {running: () => true, windows: () => [{tabs: () => [tab]}], doScript: (value) => writes.push(value)}; }
        """)
        let delivery = context.evaluateScript(try TerminalAdapter.approvalScript(tty: "/dev/fixture", expectedScreen: subAgentApproval, agent: .codex))
        try expectNil(context.exception)
        try expectEqual(delivery?.toString(), "sent")
        try expectEqual(context.evaluateScript("writes.join(',')")?.toString(), "1")

        // A long request is clipped with a `ctrl+g view all` marker; the choices and hint remain visible.
        try expectEqual(PromptDetector.detect(clippedApproval, agent: .codex)?.answer, "1")
        let footerless = clippedApproval.components(separatedBy: "\n").dropLast().joined(separator: "\n")
        try expect(PromptDetector.detect(footerless, agent: .codex) == nil, "A frame without the key hint is never answered")
    }
}
