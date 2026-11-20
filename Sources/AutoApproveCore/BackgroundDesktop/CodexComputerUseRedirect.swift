import Foundation

/// Adapts the official Codex PreToolUse payload without running its tool input.
public enum CodexComputerUseRedirect {
    static let matcher = #"^mcp__(cua[_-]repl__.*|.*computer[-_]use__.*|remote-devices__computer_.*)$"#
    private static let replPrefixes = ["mcp__cua_repl__", "mcp__cua-repl__"]

    public static func response(_ payload: JSONObject, isEnabled: () -> Bool) -> JSONObject {
        guard payload["hook_event_name"] as? String == "PreToolUse",
              let tool = payload["tool_name"] as? String else { return [:] }
        let name = tool.lowercased()
        let input = payload["tool_input"] as? JSONObject ?? [:]
        if let prefix = replPrefixes.first(where: { name.hasPrefix($0) }) {
            let action = String(name.dropFirst(prefix.count))
            // This tool accepts arbitrary JavaScript, so it cannot be classified from its name alone.
            let isSummary = action == "js" && input["code"] == nil &&
                !(input["completion_summary"] as? String ?? "").isEmpty
            guard !isSummary, action != "js_reset", !ComputerUseAction.isObservation(action) else { return [:] }
        } else {
            guard let action = ClaudeComputerUseRedirect.action(tool: name, input: input),
                  !ComputerUseAction.isObservation(action) else { return [:] }
        }

        guard isEnabled() else { return [:] }
        return ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": guidance
        ]]
    }

    public static let guidance = """
    AutoApprove가 화면 앞의 앱과 마우스 포커스가 바뀔 수 있는 computer use 호출을 차단했습니다.
    autoapprove MCP의 desktop_list_apps와 desktop_snapshot으로 대상과 요소 ref를 확인하고,
    desktop_press, desktop_set_value, desktop_type 또는 desktop_key로 백그라운드에서 조작하세요.
    결과는 desktop_snapshot이나 desktop_screenshot으로 확인하세요.
    도구가 없으면 이 Codex 세션의 autoapprove MCP 연결을 확인해주세요.
    좌표 클릭이나 메뉴 실행처럼 백그라운드에서 지원하지 않는 동작은 사용자에게 요청하세요.
    """
}
