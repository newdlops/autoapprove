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
            tool("get_session_groups", "현재 세션의 그룹과 구성원을 로컬에서 조회합니다. 공유 서버에서는 현재 대화 UUID를 conversationID로 지정하세요. connected가 false이고 canReconnect가 true인 구성원은 reconnect_group_member로 재연결하세요. 그룹장이 있으면 get_group_status, assign_group_task, answer_group_question을 사용하고, 없으면 send_group_message로 같은 도구의 구성원에게 전달하세요. 그룹 연결과 메시지는 같은 Mac의 Unix 소켓과 원래 터미널만 사용하며 네트워크 격리 중에도 동작합니다. 외부 서버, codex queue 또는 SendMessage로 우회하지 마세요.", ["conversationID": string], readOnly: true),
            tool("reconnect_group_member", "같은 Mac의 원래 터미널에서 구성원의 현재 세션 ID를 확인하고 그룹 연결을 갱신합니다. get_session_groups의 canReconnect가 true인 자기 자신·직속 구성원(그룹장이 없으면 같은 도구 구성원)에만 사용할 수 있습니다. 필요하면 빈 입력창에 /status를 입력하며 Codex는 작업 중에도 조회할 수 있습니다. 작성 중인 입력·질문·승인과 충돌하면 보류합니다. 종료된 CLI를 재실행하거나 다른 터미널을 추측해서 연결하지 않습니다. 성공 후 connected와 conversationID를 확인하세요.",
                 ["groupID": string, "memberID": string, "conversationID": string], ["groupID", "memberID"]),
            tool("send_group_message", "그룹장이 없는 그룹에서 같은 도구의 다른 구성원에게 메시지를 보냅니다. 같은 Mac의 확인된 원래 터미널에 한 줄로 입력하며 외부 네트워크나 별도 큐를 사용하지 않습니다. 대상이 작업·질문·승인·입력 중이면 보류합니다. 실패나 제출 불확실은 성공이 아니며 무조건 재전송하지 마세요. 그룹장이 있는 그룹은 assign_group_task와 answer_group_question을 사용하세요.",
                 ["groupID": string, "memberID": string, "text": ["type": "string", "minLength": 1, "maxLength": SessionGroupOrchestration.maximumTaskLength], "conversationID": string], ["groupID", "memberID", "text"]),
            tool("get_group_status", "그룹장이 있는 세션 그룹의 트리, 구성원 상태, 진행 중인 작업과 이 세션에 도착한 작업 보고를 조회합니다. 여기서 읽은 보고는 터미널로 다시 전달하지 않습니다. canAssign이 true인 직속 구성원에게만 작업을 지시할 수 있습니다. 공유 서버에서 세션을 자동 식별하지 못하면 현재 대화 UUID를 conversationID로 지정하세요.",
                 ["conversationID": string]),
            tool("assign_group_task", "직속 하위 구성원의 터미널에 작업을 입력합니다. 작업자가 대기 상태일 때만 전달하고, 작업자가 권한 확인에서 멈추지 않도록 작업자 세션의 자동 승인을 켭니다. 작업자가 응답을 마치면 마지막 응답 요약이 이 세션의 터미널에 자동으로 전달됩니다. 작업 내용은 머리말이나 출처 표시 없이, 사용자가 직접 입력한 것처럼 한 줄로 그대로 입력됩니다. 작업자가 그대로 읽고 수행할 지시만 적고, 그룹이나 그룹장, 위임, AutoApprove를 언급하지 마세요. 목록은 번호로 구분하고, /, !, #, $, &로 시작하는 내용은 보낼 수 없습니다. 공유 서버에서 세션을 자동 식별하지 못하면 현재 대화 UUID를 conversationID로 지정하세요.",
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
                "instructions": "협업할 때 get_session_groups로 현재 세션이 속한 그룹과 구성원을 확인하세요. 그룹장이 있는 그룹에서는 get_group_status로 상태를 보고, 직속 구성원에게 보내는 작업 지시와 답변은 반드시 assign_group_task와 answer_group_question을 사용하세요. AutoApprove가 지시를 작업자 터미널에 사용자가 직접 입력한 것처럼 그대로 입력하므로, 각 도구의 메시지 기능으로 직접 지시하지 말고 작업 내용에는 작업자가 수행할 지시만 적으세요. 그룹장이 없는 그룹에서는 send_group_message로 같은 도구끼리만 메시지를 보내세요. 연결이 끊겼고 canReconnect가 true이면 reconnect_group_member로 복구하세요. 모든 그룹 연결과 메시지는 같은 Mac 내부에서만 전달되며 외부 메시지 경로로 우회하지 마세요. 작업 보고, 작업자의 선택지 질문과 위임된 승인 요청은 지시한 세션의 터미널에 자동으로 입력되며, 질문과 승인 요청은 answer_group_question으로 답하세요. 휴대폰의 AutoApprove 웹에서 질문에 답하고 테스트 화면을 봅니다. ask_user 뒤 get_user_answers로 명시적 답변을 확인하세요. waiting·만료는 답변이 아닙니다. 화면은 사용자가 보고 싶어 할 때만 start_screen_share로 시작하고 시험 종료 시 stop_screen_share로 종료하세요. 기존 터미널을 재시작하거나 새 PTY를 만들 필요가 없습니다."])
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
                let groupTool = ["get_session_groups", "get_group_status", "assign_group_task", "answer_group_question", "reconnect_group_member", "send_group_message"].contains(tool)
                // Only this process may attribute the caller; never trust a supplied session or agent kind.
                if groupTool {
                    params.removeValue(forKey: "sessionID"); params.removeValue(forKey: "agentKind")
                    params.removeValue(forKey: "codexCallerHome"); params.removeValue(forKey: "codexCallerConversationID")
                }
                // Handshake/list/ping and owner-scoped replies need no process
                // scan. Resolve attribution freshly only when it is used.
                if tool == "ask_user" || tool == "start_screen_share" || groupTool {
                    let parent = getppid()
                    if let agent = try? ProcessDiscovery.enclosingAgent(of: parent), getppid() == parent {
                        params["sessionID"] = agent.key
                        if groupTool { params["agentKind"] = agent.agent?.rawValue }
                        if groupTool, agent.agent == .codex, let id = try CodexGroupIdentity.conversationID(in: message) {
                            if let claimed = params["conversationID"] as? String, UUID(uuidString: claimed) != UUID(uuidString: id) {
                                throw AppError.message("지정한 대화 ID가 이 Codex 호출의 대화와 다릅니다.")
                            }
                            params["conversationID"] = id
                            if let home = CodexGroupIdentity.home(environment: ProcessEnvironment.read(agent)) {
                                params["codexCallerHome"] = home; params["codexCallerConversationID"] = id
                            }
                        }
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
