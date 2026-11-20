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

    func testCodexDesktopHookDeniesDesktopActionsWithoutAffectingOtherTools() throws {
        func response(_ tool: String, _ input: JSONObject = [:], enabled: Bool = true) -> JSONObject {
            CodexComputerUseRedirect.response(["hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": input]) { enabled }
        }
        for (tool, input) in [("mcp__cua_repl__js", ["code": "await app.click(1)"]),
                              ("mcp__computer_use__computer", ["action": "left_click"]),
                              ("mcp__remote-devices__computer_type", [:])] as [(String, JSONObject)] {
            let result = response(tool, input)["hookSpecificOutput"] as? JSONObject
            try expectEqual(result?["hookEventName"] as? String, "PreToolUse")
            try expectEqual(result?["permissionDecision"] as? String, "deny")
            try expect((result?["permissionDecisionReason"] as? String ?? "").contains("desktop_snapshot"))
            try expect(response(tool, input, enabled: false).isEmpty)
        }
        for tool in ["Bash", "mcp__autoapprove__desktop_press", "mcp__computer_use__screenshot", "mcp__cua_repl__js_reset"] {
            try expect(response(tool).isEmpty, tool)
        }
        try expect(response("mcp__cua_repl__js", ["completion_summary": "Checked window state"]).isEmpty)
        try expect(CodexComputerUseRedirect.response(["hook_event_name": "PostToolUse", "tool_name": "mcp__cua_repl__js"]) { true }.isEmpty)
    }

    func testCodexDesktopHookInstallationPreservesOtherHooks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-codex-hooks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("hooks.json")
        let foreign: JSONObject = ["description": "keep", "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "echo keep"]]]], "Stop": []]]
        try JSONSerialization.data(withJSONObject: foreign).write(to: config)
        let helper = "/Applications/AutoApprove.app/Contents/MacOS/autoapprove"
        try expect(CodexDesktopHookInstaller.update(home: root, executable: helper, applicationHome: "/tmp/a 'quoted' home"))
        let installed = try Data(contentsOf: config)
        let parsed = try JSONSerialization.jsonObject(with: installed) as? JSONObject
        let groups = (parsed?["hooks"] as? JSONObject)?["PreToolUse"] as? [JSONObject]
        try expectEqual(groups?.count, 2)
        try expectEqual(groups?.first?["matcher"] as? String, "Bash")
        let matcher = try NSRegularExpression(pattern: groups?.last?["matcher"] as? String ?? "$")
        let repl = "mcp__cua_repl__js"
        try expect(matcher.firstMatch(in: repl, range: NSRange(repl.startIndex..., in: repl)) != nil)
        try expectFalse(CodexDesktopHookInstaller.update(home: root, executable: helper, applicationHome: "/tmp/a 'quoted' home"))
        try expectEqual(Data(contentsOf: config), installed)
        try expect(CodexDesktopHookInstaller.update(home: root, executable: nil, applicationHome: ""))
        let remaining = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? JSONObject
        try expect(NSDictionary(dictionary: foreign).isEqual(to: remaining ?? [:]))
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
