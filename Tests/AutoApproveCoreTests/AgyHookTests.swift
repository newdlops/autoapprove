import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testAgyHookStatusAndToolClassification() throws {
        func decode(_ event: String, _ fields: JSONObject = [:]) throws -> AgyHookRequest {
            var payload = fields
            payload["conversationId"] = "test-conversation"
            payload["hookEventName"] = event
            return try JSONDecoder().decode(AgyHookRequest.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        try expect(try decode("SessionStart").isIdle)
        for event in ["PreInvocation", "PreToolUse", "PostToolUse", "Stop"] {
            try expectFalse(try decode(event).isIdle)
        }
        let stopped = try decode("Stop", ["fullyIdle": true, "terminationReason": "NO_TOOL_CALL"])
        try expect(stopped.isIdle)
        try expectEqual(stopped.terminationReason, "NO_TOOL_CALL")
        for tool in ["run_command", "call_mcp_tool", "read_file"] {
            let request = try decode("PreToolUse", ["toolCall": ["name": tool, "args": ["CommandLine": "pwd"]]])
            try expectEqual(request.toolCall?.commandLine, tool == "run_command" ? "pwd" : nil)
        }
    }
}
