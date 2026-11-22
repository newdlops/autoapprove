import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testAgyHookStatusAndToolClassification() throws {
        let presence = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/presence").path
        let first = UUID().uuidString, next = UUID().uuidString
        let active = presence + "/" + first + ".lock"
        let switched = presence + "/" + next + ".lock"
        try expectEqual(ProcessOpenFiles.agyConversation(paths: [active, active]), first.lowercased())
        try expectEqual(ProcessOpenFiles.agyConversation(paths: [switched]), next.lowercased())
        try expectNil(ProcessOpenFiles.agyConversation(paths: [active, switched]))
        try expectNil(ProcessOpenFiles.agyConversation(paths: [presence, "/tmp/" + first + ".lock", presence + "/invalid.lock"]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("hooks.json")
        try AgyHookInstaller.update(executable: "/fixture/autoapprove", home: "/tmp/fixture", url: config)
        try expect(AgyHookInstaller.isInstalled(url: config))
        let original = try Data(contentsOf: config)
        try AgyHookInstaller.update(executable: "/fixture/autoapprove", home: "/tmp/fixture", url: config)
        try expectEqual(try Data(contentsOf: config), original)
        var doc = try JSONSerialization.jsonObject(with: original) as! JSONObject
        doc["other"] = ["note": "keep"]
        try (Data([0xef, 0xbb, 0xbf]) + JSONSerialization.data(withJSONObject: doc)).write(to: config)
        try AgyHookInstaller.update(executable: nil, home: "/tmp/fixture", url: config)
        let removed = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! JSONObject
        try expectEqual(Set(removed.keys), ["other"])
        let records = ProcessDiscovery.parse("""
        10 1 ttys001 10 10 Tue Sep 22 09:00:00 2026 /Users/example/.local/bin/agy
        11 1 ttys002 11 11 Tue Sep 22 09:00:00 2026 agy
        12 1 ttys003 12 12 Tue Sep 22 09:00:00 2026 /tmp/agency
        """)
        try expectEqual(records.map(\.agent), [.agy, .agy, nil])
        try expectNil(CodexCapacityStop.detect(CodexCapacityStop.message, agent: .agy))
        let empty = "──────────\n> Auto mode: edits & safe commands auto-approved (shift+tab to cycle)\n──────────\nGemini | /tmp | Ctx"
        try expect(AgyComposerReadiness.isEmpty(empty))
        try expectFalse(AgyComposerReadiness.isEmpty(empty.replacingOccurrences(of: "> Auto mode: edits & safe commands auto-approved (shift+tab to cycle)", with: "> draft")))
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
        func decision(_ tool: String, _ args: JSONObject, enabled: Bool = true) throws -> String? {
            let event = try decode("PreToolUse", ["toolCall": ["name": tool, "args": args]])
            return event.permission(automatic: enabled, cwd: directory.path)["decision"] as? String
        }
        try expectEqual(try decision("view_file", ["AbsolutePath": config.path]), "auto_approve")
        try expectEqual(try decision("list_dir", ["DirectoryPath": directory.path]), "auto_approve")
        try expectEqual(try decision("view_file", ["AbsolutePath": config.path], enabled: false), "ask")
        try expectEqual(try decision("view_file", ["AbsolutePath": "/outside"]), "ask")
        try expectEqual(try decision("run_command", ["CommandLine": "/bin/pwd"]), "auto_approve")
        try expectEqual(try decision("run_command", ["CommandLine": "/bin/pwd && whoami"]), "ask")
        for tool in ["run_command", "call_mcp_tool", "read_file"] {
            let request = try decode("PreToolUse", ["toolCall": ["name": tool, "args": ["CommandLine": "pwd"]]])
            try expectEqual(request.toolCall?.commandLine, tool == "run_command" ? "pwd" : nil)
        }
    }
}
