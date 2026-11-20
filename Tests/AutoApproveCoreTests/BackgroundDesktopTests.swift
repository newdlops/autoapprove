import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testBackgroundDesktopPolicyBlocksTerminalsAndSecurityApps() throws {
        for bundle in ["com.apple.Terminal", "com.googlecode.iterm2", "com.microsoft.VSCode", "local.autoapprove.mac", "com.apple.keychainaccess", "com.jetbrains.intellij", "com.openai.sky.computer-use"] {
            try expect(BackgroundDesktopPolicy.blockReason(bundleID: bundle, name: bundle) != nil, bundle)
        }
        try expect(BackgroundDesktopPolicy.blockReason(bundleID: nil, name: "unknown") != nil)
        for bundle in ["com.apple.TextEdit", "com.apple.calculator", "com.apple.Notes", "com.tinyspeck.slackmacgap"] {
            try expectNil(BackgroundDesktopPolicy.blockReason(bundleID: bundle, name: bundle))
        }
        try expectFalse(BackgroundDesktopPolicy.elementActions.contains("AXRaise"), "AXRaise reorders the user's windows")
    }

    func testBackgroundDesktopKeysAndStrokes() throws {
        try expectEqual(BackgroundDesktopKeys.virtualKey("Return"), 36)
        try expectEqual(BackgroundDesktopKeys.virtualKey("page_down"), 121)
        try expectNil(BackgroundDesktopKeys.virtualKey("f13"))
        try expectEqual(BackgroundDesktopKeys.strokes("가a\r\nb\tc"), [.text("가"), .text("a"), .key(36), .text("b"), .key(48), .text("c")])
        // A composed emoji stays one stroke so its UTF-16 pair is never split.
        try expectEqual(BackgroundDesktopKeys.strokes("👍🏽"), [.text("👍🏽")])
    }

    func testClaudeComputerUseRedirectDeniesOnlyFocusTakingActions() throws {
        for (tool, input) in [("mcp__computer-use__left_click", [:]), ("mcp__computer-use__type", [:]), ("mcp__computer-use__open_application", [:]),
                              ("mcp__remote-devices__computer_key", [:]), ("mcp__computer-use__computer", ["action": "scroll"]) ] as [(String, JSONObject)] {
            try expect(ClaudeComputerUseRedirect.denial(tool: tool, input: input) != nil, tool)
        }
        for (tool, input) in [("mcp__computer-use__screenshot", [:]), ("mcp__computer-use__zoom", [:]), ("mcp__computer-use__request_access", [:]),
                              ("mcp__computer-use__list_granted_applications", [:]), ("mcp__computer-use__computer", ["action": "screenshot"]),
                              ("mcp__claude-in-chrome__computer", ["action": "left_click"]), ("Bash", ["command": "ls"]),
                              ("mcp__autoapprove__desktop_press", [:])] as [(String, JSONObject)] {
            try expect(ClaudeComputerUseRedirect.denial(tool: tool, input: input) == nil, tool)
        }
        try expect(ClaudeComputerUseRedirect.guidance.contains("desktop_snapshot"))
        try expect(ClaudeComputerUseRedirect.guidance.contains("ToolSearch") && ClaudeComputerUseRedirect.guidance.contains("/mcp"),
                   "A session whose MCP server predates the desktop tools learns how to get them")
    }

    func testMCPReturnsDesktopCaptureAsImageContent() throws {
        let names = Set(AutoApproveMCPServer.tools.compactMap { $0["name"] as? String })
        for name in ["desktop_list_apps", "desktop_open_app", "desktop_snapshot", "desktop_screenshot", "desktop_press", "desktop_set_value", "desktop_type", "desktop_key"] {
            try expect(names.contains(name), name)
        }
        let message: JSONObject = ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "desktop_screenshot", "arguments": ["app": "com.apple.TextEdit"]]]
        let reply = AutoApproveMCPServer.response(message) { tool, arguments in
            try expectEqual(tool, "desktop_screenshot"); try expectEqual(arguments["app"] as? String, "com.apple.TextEdit")
            return ["app": "TextEdit", "image": ["data": "AAAA", "mimeType": "image/jpeg"]]
        }
        let result = reply?["result"] as? JSONObject
        let content = result?["content"] as? [JSONObject] ?? []
        try expectEqual(content.count, 2)
        try expectEqual(content.last?["type"] as? String, "image")
        try expectEqual(content.last?["data"] as? String, "AAAA")
        try expectNil((result?["structuredContent"] as? JSONObject)?["image"] as Any?)
        try expectFalse((content.first?["text"] as? String ?? "").contains("AAAA"), "image bytes must not be repeated as text")
    }
}
