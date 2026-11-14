import Foundation
import Darwin

/// Local stdio MCP facade. The GUI owns questions and captures; this process never injects keys or captures independently.
public enum AutoApproveMCPServer {
    public static var tools: [JSONObject] { toolSchema }
    private static let toolSchema: [JSONObject] = {
        let string: JSONObject = ["type": "string"]
        let option: JSONObject = ["type": "object", "properties": ["label": string, "description": string], "required": ["label"], "additionalProperties": false]
        let field: JSONObject = ["type": "object", "properties": ["id": string, "question": string,
            "options": ["type": "array", "items": option, "maxItems": 16], "multiSelect": ["type": "boolean"]], "required": ["question"], "additionalProperties": false]
        func tool(_ name: String, _ description: String, _ properties: JSONObject = [:], _ required: [String] = [], readOnly: Bool = false) -> JSONObject {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]]
        }
        return [
            tool("ask_user", "휴대폰 웹에 선택지·직접 답변 폼을 게시합니다. 기본값을 답변으로 처리하지 않습니다. 반환된 requestID로 get_user_answers에서 사용자가 보낸 답변을 확인하세요.",
                 ["title": string, "questions": ["type": "array", "items": field, "minItems": 1, "maxItems": 8]], ["questions"]),
            tool("get_user_answers", "이 MCP 연결에서 게시한 질문의 응답을 확인합니다. waiting이면 아직 답변이 없습니다. answered의 answers만 실제 사용자 응답입니다.", ["requestID": string], ["requestID"], readOnly: true),
            tool("get_session_groups", "현재 세션이 속한 AutoApprove 그룹과 구성원을 조회합니다. 공유 서버가 도구를 실행해 세션을 자동 식별하지 못하면 현재 대화 UUID를 conversationID로 지정하세요. 같은 도구의 구성원에게만 메시지를 보낼 수 있습니다. Codex는 확인된 대화 ID와 홈을 사용해 기존 codex queue로 전달할 수 있습니다. Claude는 messagingName을 참고해 기존 SendMessage의 실제 수신 대상을 확인하세요. 이름이 중복되거나 비어 있으면 대상을 추측하지 마세요. ID 미확인·연결 끊김은 전송 대상으로 추정하지 마세요.", ["conversationID": string], readOnly: true),
            tool("get_group_status", "그룹장이 있는 세션 그룹의 트리, 구성원 상태, 진행 중인 작업과 이 세션에 도착한 작업 보고를 조회합니다. 여기서 읽은 보고는 터미널로 다시 전달하지 않습니다. canAssign이 true인 직속 구성원에게만 작업을 지시할 수 있습니다. 공유 서버에서 세션을 자동 식별하지 못하면 현재 대화 UUID를 conversationID로 지정하세요.",
                 ["conversationID": string]),
            tool("assign_group_task", "직속 하위 구성원의 터미널에 작업을 입력합니다. 작업자가 대기 상태일 때만 전달하고, 작업자가 권한 확인에서 멈추지 않도록 작업자 세션의 자동 승인을 켭니다. 작업자가 응답을 마치면 마지막 응답 요약이 이 세션의 터미널에 자동으로 전달됩니다. 작업 내용은 한 줄로 입력되므로 목록은 번호로 구분하세요. 공유 서버에서 세션을 자동 식별하지 못하면 현재 대화 UUID를 conversationID로 지정하세요.",
                 ["groupID": string, "memberID": string, "task": ["type": "string", "minLength": 1, "maxLength": SessionGroupOrchestration.maximumTaskLength], "conversationID": string],
                 ["groupID", "memberID", "task"]),
            tool("answer_group_question", "직속 하위 구성원이 작업 중에 터미널 선택지 질문이나 권한 확인에서 멈췄을 때 선택지 번호로 답합니다. 질문과 승인 요청은 그룹 보고나 get_group_status의 task.question으로 받습니다. 권한 확인은 사용자가 이 세션에 위임한 승인이므로, 선택이 사용자 승인으로 처리됩니다. 요청 내용을 확인하고 작업 범위 안의 요청만 승인하세요. AutoApprove가 사용자에게도 승인시키지 않는 시스템 변경과 전체 일시정지 중의 요청은 넘어오지 않습니다. 화면의 요청이 바뀌었으면 답하지 않습니다. 공유 서버에서 세션을 자동 식별하지 못하면 현재 대화 UUID를 conversationID로 지정하세요.",
                 ["groupID": string, "memberID": string, "choice": ["type": "integer", "minimum": 1, "maximum": 9], "conversationID": string],
                 ["groupID", "memberID", "choice"]),
            tool("get_diagnostics", "이 Mac의 AutoApprove·Codex 서버·세션 연결·권한·현재/과거 재연결 기록을 읽기 전용으로 조회합니다. 기존 작업을 중단하거나 진단용 Codex를 실행하지 않습니다.",readOnly:true),
            tool("list_screens", "Mac의 공유 가능한 전체 화면과 창 ID를 조회합니다. 화면 녹음 권한이 없으면 Mac에서 허용하도록 안내합니다. 캡처를 시작하지 않습니다.", readOnly: true),
            tool("start_screen_share", "사용자가 테스트 화면을 볼 때만 호출하세요. 기본은 Mac 전체 화면이며 휴대폰 웹에 게시합니다. 시험이 끝나면 stop_screen_share를 호출하세요. 최대 15분입니다.",
                 ["title": string, "scope": ["type": "string", "enum": ["display", "window"]], "sourceID": ["type": "integer", "minimum": 1], "durationSeconds": ["type": "integer", "minimum": 30, "maximum": 900]]),
            tool("stop_screen_share", "이 MCP 연결에서 시작한 화면 공유를 종료하고 보관한 이미지를 폐기합니다.", ["shareID": string], ["shareID"])
        ]
    }()
    public static func response(_ message: JSONObject, call: (String, JSONObject) throws -> JSONObject) -> JSONObject? {
        guard let id = message["id"] else { return nil }
        func result(_ value: JSONObject) -> JSONObject { ["jsonrpc": "2.0", "id": id, "result": value] }
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32600, "message": "Invalid request"]]
        }
        switch method {
        case "initialize":
            let requested = (message["params"] as? JSONObject)?["protocolVersion"] as? String ?? "2025-11-25"
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
            return result(["protocolVersion": supported.contains(requested) ? requested : "2025-11-25",
                "capabilities": ["tools": [:]], "serverInfo": ["name": "autoapprove", "version": RemoteWebVersion.current?.version ?? "0.2.72"],
                "instructions": "협업할 때 get_session_groups로 현재 세션이 속한 그룹과 구성원을 확인하세요. 같은 도구끼리만 메시지를 보내며 대상 식별이 불확실하면 전송하지 마세요. 그룹장이 있는 그룹에서는 get_group_status로 상태를 보고 assign_group_task로 직속 구성원에게 작업을 지시하세요. 작업 보고, 작업자의 선택지 질문과 위임된 승인 요청은 지시한 세션의 터미널에 자동으로 입력되며, 질문과 승인 요청은 answer_group_question으로 답하세요. 휴대폰의 AutoApprove 웹에서 질문에 답하고 테스트 화면을 봅니다. ask_user 뒤 get_user_answers로 명시적 답변을 확인하세요. waiting·만료는 답변이 아닙니다. 화면은 사용자가 보고 싶어 할 때만 start_screen_share로 시작하고 시험 종료 시 stop_screen_share로 종료하세요. 기존 터미널을 재시작하거나 새 PTY를 만들 필요가 없습니다."])
        case "ping": return result([:])
        case "tools/list": return result(["tools": tools])
        case "tools/call":
            do {
                guard let params = message["params"] as? JSONObject, let name = params["name"] as? String,
                      tools.contains(where: { $0["name"] as? String == name }) else { throw AppError.message("지원하지 않는 MCP 도구입니다.") }
                let value = try call(name, params["arguments"] as? JSONObject ?? [:])
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
                return result(["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "structuredContent": value, "isError": false])
            } catch { return result(["content": [["type": "text", "text": error.localizedDescription]], "isError": true]) }
        default: return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
    }
    public static func run(paths: AppPaths) {
        let owner = UUID().uuidString
        defer { _ = try? SocketClient.request(path: paths.socket, message: ["method": "mcp", "params": ["tool": "disconnect", "owner": owner]], timeout: 2) }
        let input = MCPInputReader(descriptor: STDIN_FILENO)
        while autoreleasepool(invoking: { () -> Bool in
            guard let frame = try? input.next() else { return false }
            // JSONSerialization auto-detects UTF-16/32. A raw NUL cannot occur
            // in valid UTF-8 JSON and must not switch this NDJSON wire format.
            guard case .message(let data) = frame, !data.contains(0), String(data: data, encoding: .utf8) != nil,
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
                write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); return true
            }
            if let reply = response(message, call: { tool, arguments in
                var params = arguments; params["tool"] = tool; params["owner"] = owner
                let groupTool = ["get_session_groups", "get_group_status", "assign_group_task", "answer_group_question"].contains(tool)
                // Only this process may attribute the caller; never trust a supplied session or agent kind.
                if groupTool { params.removeValue(forKey: "sessionID"); params.removeValue(forKey: "agentKind") }
                // Handshake/list/ping and owner-scoped replies need no process
                // scan. Resolve attribution freshly only when it is used.
                if tool == "ask_user" || tool == "start_screen_share" || groupTool {
                    let parent = getppid()
                    if let agent = try? ProcessDiscovery.enclosingAgent(of: parent), getppid() == parent {
                        params["sessionID"] = agent.key
                        if groupTool { params["agentKind"] = agent.agent?.rawValue }
                    }
                }
                return try SocketClient.request(path: paths.socket, message: ["method": "mcp", "params": params], timeout: groupTool ? 60 : 20)
            }) { write(reply) }
            return true
        }) {
            // Drain temporary Foundation objects before the next blocking read.
        }
    }
    private static func write(_ object: JSONObject) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(10); FileHandle.standardOutput.write(data)
    }
}
