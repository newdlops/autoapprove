import Foundation

/// Claude Code adapter: maps Claude's computer-use tool calls onto the shared
/// action classification. A Codex adapter can reuse `ComputerUseAction` and the
/// same guidance with its own tool names.
public enum ClaudeComputerUseRedirect {
    public static let guidance = """
    포커스를 빼앗는 computer use 조작을 AutoApprove가 막았습니다. 사용자가 다른 앱으로 작업 중이므로 화면 앞의 앱, 키보드 포커스와 마우스를 바꾸지 마세요. \
    대신 autoapprove MCP의 백그라운드 도구로 같은 작업을 계속하세요: desktop_list_apps로 앱을 찾고, 실행되지 않았으면 desktop_open_app으로 뒤에서 실행합니다. \
    desktop_snapshot으로 요소 목록(ref)을 읽은 뒤 desktop_press(버튼 누르기), desktop_set_value(입력란 값 지정), desktop_type(포커스된 입력란에 글자 입력), desktop_key(Return, Tab, 화살표 등)를 사용하고, \
    결과는 desktop_snapshot이나 desktop_screenshot으로 확인하세요. 메뉴 실행, ⌘ 단축키, 좌표 클릭은 백그라운드에서 동작하지 않으니, 필요하면 버튼이나 입력란으로 같은 일을 하거나 사용자에게 요청하세요. \
    Claude Code에서는 mcp__autoapprove__desktop_snapshot처럼 보입니다. 도구 목록에 없으면 ToolSearch로 "desktop_"을 찾고, 그래도 없으면 이 세션의 autoapprove MCP 서버가 이 기능보다 먼저 시작된 것이니 사용자에게 /mcp에서 autoapprove를 다시 연결해 달라고 요청하세요.
    """

    /// The action named by a Claude computer-use call, or nil for other tools.
    public static func action(tool: String, input: JSONObject) -> String? {
        let lower = tool.lowercased()
        let marker: String
        if let range = lower.range(of: "computer-use__") ?? lower.range(of: "computer_use__") { marker = String(lower[range.upperBound...]) }
        else if lower.hasPrefix("mcp__remote-devices__computer_") { marker = String(lower.dropFirst("mcp__remote-devices__computer_".count)) }
        else { return nil }
        guard lower.hasPrefix("mcp__") else { return nil }
        // Some servers expose one tool whose input names the action.
        if ["computer", "action", ""].contains(marker), let name = input["action"] as? String { return name }
        return marker
    }

    /// A denial reason when the call would take the user's focus; nil otherwise.
    public static func denial(tool: String, input: JSONObject) -> String? {
        guard let action = action(tool: tool, input: input), !ComputerUseAction.isObservation(action) else { return nil }
        return guidance
    }
}
