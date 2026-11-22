import Foundation
import Darwin

public enum MCPToolProfile: String {
    case all, orchestrator, worker, desktop

    func allows(_ name: String) -> Bool {
        switch self {
        case .all: return true
        case .orchestrator: return name.contains("_group") || ["ask_user", "get_user_answers", "get_diagnostics"].contains(name)
        case .worker:
            return name.hasPrefix("desktop_") || ["get_session_groups", "get_group_status", "reconnect_group_member",
                "send_group_message", "ask_group_question", "reply_group_question", "get_group_messages", "ack_group_messages",
                "wait_group_dependencies", "update_group_wait", "complete_group_task"].contains(name)
        case .desktop: return name.hasPrefix("desktop_") || name == "get_diagnostics"
        }
    }

    var instructions: String {
        var parts: [String] = []
        if self != .desktop {
            parts.append("같은 Mac의 그룹 도구로 통신하세요. 다른 스레드·전송 경로로 우회하지 마세요. 필수 대기는 wait_group_dependencies 또는 ask_group_question(blocksProgress=true), 자유 질문 회신은 reply_group_question(inReplyTo: 원래 messageID)입니다. 터미널 본문은 그대로 사용하고 참조만 받으면 get_group_messages로 원문을 읽으세요. 상태 점검은 get_group_status(mailboxView: summary, reportView: compact), 장문 발신은 includeReceiptText=false를 쓰세요. 배정·재개에 연결된 최종 응답은 자동 보고됩니다. 첫 줄에 결과와 남은 문제를 적으세요.")
        }
        if self == .all || self == .orchestrator {
            parts.append("직속 작업은 assign_group_task, 현재 선택지·위임된 승인만 answer_group_question으로 처리하세요. ask_user 뒤 get_user_answers에서 명시적 응답을 확인하세요.")
        }
        if self != .orchestrator { parts.append("desktop_ 도구로 사용자 포커스·마우스를 유지하며 백그라운드에서 조작하세요.") }
        if self == .all { parts.append("사용자가 원할 때만 화면 공유를 시작하고 시험 뒤 종료하세요.") }
        return parts.joined(separator: " ")
    }
}

public enum AutoApproveMCPServer {
    public static var tools: [JSONObject] { toolSchema }
    private static let toolSchema: [JSONObject] = {
        let string: JSONObject = ["type": "string"]
        let ids: JSONObject = ["type": "array", "items": string, "uniqueItems": true, "maxItems": 32]
        let timeout: JSONObject = ["type": "integer", "minimum": 1, "maximum": 604800]
        let bool: JSONObject = ["type": "boolean"]
        let option: JSONObject = ["type": "object", "properties": ["label": string, "description": string], "required": ["label"], "additionalProperties": false]
        let field: JSONObject = ["type": "object", "properties": ["id": string, "question": string,
            "options": ["type": "array", "items": option, "maxItems": 16], "multiSelect": ["type": "boolean"]], "required": ["question"], "additionalProperties": false]
        func tool(_ name: String, _ description: String, _ properties: JSONObject = [:], _ required: [String] = [], readOnly: Bool = false, destructive: Bool = false) -> JSONObject {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false]]
        }
        return [
            tool("ask_user", "휴대폰 웹에 선택지·직접 답변 폼을 게시합니다. 기본값을 답변으로 처리하지 않습니다. 반환된 requestID로 get_user_answers에서 사용자가 보낸 답변을 확인하세요.",
                 ["title": string, "questions": ["type": "array", "items": field, "minItems": 1, "maxItems": 8]], ["questions"]),
            tool("get_user_answers", "이 MCP 연결에서 게시한 질문의 응답을 확인합니다. waiting이면 아직 답변이 없습니다. answered의 answers만 실제 사용자 응답입니다.", ["requestID": string], ["requestID"], readOnly: true),
            tool("get_session_groups", "현재 그룹·역할·연결·모델 기록을 조회합니다. 공유 서버는 conversationID를 지정하세요. 연결이 끊기고 canReconnect=true이면 reconnect_group_member로 복구하세요.", ["conversationID": string], readOnly: true),
            tool("reconnect_group_member", "canReconnect=true인 자신·직속 구성원(그룹장 없으면 같은 그룹)의 현재 대화를 재확인합니다. 초안·승인창이 있으면 보류합니다. 성공 후 connected와 conversationID를 확인하세요.",
                 ["groupID": string, "memberID": string, "conversationID": string], ["groupID", "memberID"]),
            tool("send_group_message", "같은 그룹의 다른 구성원에게 일반 메시지를 저장합니다. accepted는 접수입니다. 재시도에는 같은 messageID를 쓰세요. 작업 지시·승인 권한은 부여하지 않습니다.",
                 ["groupID": string, "memberID": string, "text": ["type": "string", "minLength": 1, "maxLength": SessionGroupOrchestration.maximumTaskLength], "messageID": string, "includeReceiptText": ["type": "boolean", "default": true], "conversationID": string], ["groupID", "memberID", "text"]),
            tool("ask_group_question", "그룹 구성원에게 자유 질문을 보냅니다. 진행에 필수면 blocksProgress=true와 messageID를 지정하고 재시도에도 같은 ID를 쓰세요. 수신 확인은 답변·승인이 아닙니다.",
                 ["groupID": string, "memberID": string, "text": ["type": "string", "minLength": 1, "maxLength": SessionGroupOrchestration.maximumTaskLength], "messageID": string, "includeReceiptText": ["type": "boolean", "default": true], "blocksProgress": bool, "timeoutSeconds": timeout, "taskID": string, "forQuestionID": string, "conversationID": string], ["groupID", "memberID", "text"]),
            tool("reply_group_question", "받은 groupID와 senderMemberID에 회신합니다. inReplyTo에 원래 질문의 messageID를 지정해 대기를 해제하세요. 재시도에는 같은 회신 messageID를 쓰세요.",
                 ["groupID": string, "memberID": string, "text": ["type": "string", "minLength": 1, "maxLength": SessionGroupOrchestration.maximumTaskLength], "messageID": string, "includeReceiptText": ["type": "boolean", "default": true], "inReplyTo": string, "conversationID": string], ["groupID", "memberID", "text"]),
            tool("get_group_messages", "자기 메일함 원문을 읽습니다. messageID로 ACK 후에도 조회하며 발신 건은 direction=outbox를 지정합니다. 다음 페이지에는 같은 방향과 afterSequence를 쓰세요. unansweredOnly=true는 ACK 여부와 관계없이 미응답 질문을 찾습니다.",
                 ["groupID": string, "messageID": string, "direction": ["type": "string", "enum": ["inbox", "outbox"]], "includeAcknowledged": ["type": "boolean"], "unansweredOnly": ["type": "boolean"], "afterSequence": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 50], "conversationID": string], ["groupID"], readOnly: true),
            tool("ack_group_messages", "자기 수신함의 원문을 읽은 ID만 확인합니다. 미리보기는 제외하세요. 터미널 본문 수신은 자동 확인됩니다. 반복 ACK는 안전하며 작업 완료·승인과 별개입니다.",
                 ["groupID": string, "messageIDs": ["type": "array", "items": string, "minItems": 1, "maxItems": 50, "uniqueItems": true], "conversationID": string], ["groupID", "messageIDs"]),
            tool("wait_group_dependencies", "자기 작업이 결과를 기다릴 때만 사용합니다. get_group_status의 작업 ID와 자신이 보낸 질문 ID를 지정합니다. mode는 all(기본) 또는 any, external은 외부 결과 포함입니다. forQuestionID는 자신이 답해야 하는 결정이 막힌 경우에만 지정합니다. 같은 waitID로 재시도하세요. 기본 300초입니다. 결과와 경고는 로컬 수신함으로 오며 확인된 재개 턴에서 완료 원문을 자동 보고합니다.",
                 ["groupID": string, "waitID": string, "taskID": string, "forQuestionID": string, "taskIDs": ids, "questionIDs": ids, "external": bool, "mode": ["type":"string","enum":["all","any"]], "timeoutSeconds": timeout, "conversationID": string], ["groupID","waitID"]),
            tool("update_group_wait", "자신이 등록한 대기의 외부 결과가 도착하면 externalReady, 대기가 불필요해지면 cancel을 지정합니다. 작업 실행과 승인은 별도입니다.",
                 ["groupID": string, "waitID": string, "action": ["type":"string","enum":["externalReady","cancel"]], "conversationID": string], ["groupID","waitID","action"]),
            tool("complete_group_task", "대기를 사용한 작업자가 실제 작업을 마쳤을 때 원래 배정 ID와 결과 요약을 제출합니다. 해결 전 대기는 먼저 명시적으로 해제하세요.",
                 ["groupID": string, "taskID": string, "summary": string, "conversationID": string], ["groupID","taskID","summary"]),
            tool("get_group_status", "작업·보고·대기를 조회합니다. 상태 점검은 mailboxView=summary(방향별 3건), 생략·full은 원문 20건입니다. 미리보기로 ACK하지 마세요. 원문은 get_group_messages, 대기 그래프는 includeWaitGraph=true입니다. compact 보고의 생략된 본문은 같은 구성원의 같은 작업 ID에서 읽으세요.",
                 ["conversationID": string, "includeWaitGraph": bool, "mailboxView": ["type": "string", "enum": ["full", "summary"]], "reportView": ["type": "string", "enum": ["full", "compact"], "default": "full"]]),
            tool("assign_group_task", "canAssign=true인 대기 중인 직속 작업자에게 지시를 입력하고 자동 승인을 켭니다. 수행할 지시만 적으세요. /, !, #, $, &로 시작할 수 없습니다. 연결된 응답은 자동 보고됩니다.",
                 ["groupID": string, "memberID": string, "task": ["type": "string", "minLength": 1, "maxLength": SessionGroupOrchestration.maximumTaskLength], "conversationID": string],
                 ["groupID", "memberID", "task"]),
            tool("answer_group_question", "직속 작업자의 현재 요청·선택지를 확인한 뒤 choice를 지정합니다. 권한 선택은 사용자 승인으로 처리되므로 위임된 작업 범위 안에서만 승인하세요. 전체 일시정지·금지된 시스템 변경·요청 변경 시 승인할 수 없습니다.",
                 ["groupID": string, "memberID": string, "choice": ["type": "integer", "minimum": 1, "maximum": 9], "conversationID": string],
                 ["groupID", "memberID", "choice"]),
            tool("clear_session_group", "그룹 전체(자신은 마지막)를 /clear하고 대화 ID를 갱신합니다. 그룹장이 있으면 그룹장만 가능합니다. 같은 요청은 같은 requestID로 재시도하세요. 접수 뒤 현재 응답을 끝내고 get_group_clear_status에서 완료를 확인하세요.",
                 ["groupID": string, "requestID": string, "conversationID": string], ["groupID", "requestID"], destructive:true),
            tool("clear_group_member", "지정한 구성원만 /clear하고 ID를 갱신합니다. 그룹장이 있으면 그룹장만 가능합니다. 같은 대상의 재시도는 같은 requestID, 다른 요청은 새 ID를 쓰세요. 자신이면 현재 응답을 끝내고 get_group_clear_status로 완료를 확인하세요.",
                 ["groupID": string, "memberID": string, "requestID": string, "conversationID": string], ["groupID", "memberID", "requestID"], destructive:true),
            tool("set_group_member_title", "원래 Terminal·iTerm2 탭과 구성원 이름(1~80자)을 바꿉니다. role(1~120자)은 선택입니다. 그룹장이 있으면 그룹장만 가능합니다.",
                 ["groupID": string, "memberID": string, "title": string, "role": string, "conversationID": string], ["groupID", "memberID", "title"]),
            tool("set_group_member_tab_color", "원래 탭 제목에 색상 표식을 적용합니다. default는 표식을 제거합니다. 그룹장이 있으면 그룹장만 가능합니다.",
                 ["groupID": string, "memberID": string, "color": ["type":"string","enum":SessionColor.allCases.map(\.rawValue) + ["default"]], "conversationID": string], ["groupID", "memberID", "color"]),
            tool("get_group_clear_status", "초기화 진행과 새 대화 ID를 조회합니다. requestID 생략 시 최근 요청입니다. done과 completed를 확인하세요. needs_review이면 해당 터미널을 확인하세요.",
                 ["groupID": string, "requestID": string, "conversationID": string], ["groupID"], readOnly:true),
            tool("get_diagnostics", "이 Mac의 AutoApprove·Codex 서버·세션 연결·권한·현재/과거 재연결 기록을 읽기 전용으로 조회합니다. 기존 작업을 중단하거나 진단용 Codex를 실행하지 않습니다.",readOnly:true),
            tool("list_screens", "Mac의 공유 가능한 전체 화면과 창 ID를 조회합니다. 화면 녹음 권한이 없으면 Mac에서 허용하도록 안내합니다. 캡처를 시작하지 않습니다.", readOnly: true),
            tool("start_screen_share", "사용자가 테스트 화면을 볼 때만 호출하세요. 기본은 Mac 전체 화면이며 휴대폰 웹에 게시합니다. 시험이 끝나면 stop_screen_share를 호출하세요. 최대 15분입니다.",
                 ["title": string, "scope": ["type": "string", "enum": ["display", "window"]], "sourceID": ["type": "integer", "minimum": 1], "durationSeconds": ["type": "integer", "minimum": 30, "maximum": 900]]),
            tool("stop_screen_share", "이 MCP 연결에서 시작한 화면 공유를 종료하고 보관한 이미지를 폐기합니다.", ["shareID": string], ["shareID"])
        ] + desktopTools(string: string, tool: tool)
    }()
    /// Background desktop control shared by every agent. None of these tools
    /// activates an app, moves the pointer or changes the user's keyboard focus.
    private static func desktopTools(string: JSONObject, tool: (String, String, JSONObject, [String], Bool, Bool) -> JSONObject) -> [JSONObject] {
        let app: JSONObject = ["type": "string", "description": "번들 ID(예: com.apple.TextEdit), 앱 이름 또는 pid"]
        let ref: JSONObject = ["type": "string", "description": "desktop_snapshot이 반환한 요소 ref(예: e12)"]
        let window: JSONObject = ["type": "integer", "minimum": 0, "maximum": 50]
        return [
            tool("desktop_list_apps", "실행 중인 앱과 창 수를 조회합니다. frontmost인 앱은 사용자가 쓰는 중입니다. blocked인 앱(터미널, 개발 도구, 보안·에이전트 앱)은 조작할 수 없습니다.", [:], [], true, false),
            tool("desktop_open_app", "앱을 앞으로 가져오지 않고 실행합니다. path를 지정하면 그 파일을 이 앱으로 엽니다. 앱이 스스로 앞으로 나오면 즉시 이전 앱으로 되돌리고 focus에 알립니다.",
                 ["app": app, "path": string], ["app"], false, false),
            tool("desktop_snapshot", "앱 창의 손쉬운 사용 요소를 ref가 붙은 트리로 읽습니다. 다른 desktop 도구는 이 ref로 요소를 지정합니다. {press} 요소는 desktop_press, editable 요소는 desktop_set_value로 조작합니다. frames=true는 화면 좌표를 함께 표시합니다.",
                 ["app": app, "window": window, "maxNodes": ["type": "integer", "minimum": 50, "maximum": 1500], "frames": ["type": "boolean"], "includeMenuBar": ["type": "boolean"]], ["app"], true, false),
            tool("desktop_screenshot", "다른 창에 가려져 있어도 앱의 창 하나만 캡처해 이미지로 반환합니다. 화면 전체를 캡처하지 않습니다.",
                 ["app": app, "window": window], ["app"], true, false),
            tool("desktop_press", "버튼, 체크박스, 탭 같은 요소의 동작을 실행합니다. 기본 동작은 AXPress입니다. 좌표 클릭과 메뉴 실행은 백그라운드 앱에서 동작하지 않으므로 제공하지 않습니다.",
                 ["app": app, "ref": ref, "action": ["type": "string", "enum": BackgroundDesktopPolicy.elementActions.sorted()]], ["app", "ref"], false, false),
            tool("desktop_set_value", "입력란, 슬라이더 같은 요소의 값을 직접 지정합니다. mode=insert는 커서 위치에 글자를 넣고 기존 내용을 유지합니다. 비밀번호 입력란은 거부합니다.",
                 ["app": app, "ref": ref, "value": ["type": ["string", "number", "boolean"]], "mode": ["type": "string", "enum": ["replace", "insert"]]], ["app", "ref", "value"], false, false),
            tool("desktop_type", "앱의 포커스된 입력란(ref를 지정하면 그 요소)에 글자를 키 입력으로 보냅니다. 줄바꿈은 Return, 탭 문자는 Tab 키로 보냅니다. 앱은 뒤에 남아 있습니다.",
                 ["app": app, "text": ["type": "string", "minLength": 1, "maxLength": 4000], "ref": ref], ["app", "text"], false, false),
            tool("desktop_key", "Return, Tab, Escape, 화살표 같은 키를 앱에만 보냅니다. ⌘·⌃ 단축키는 메뉴를 거치므로 백그라운드 앱에서 대부분 실행되지 않습니다.",
                 ["app": app, "key": string, "modifiers": ["type": "array", "items": ["type": "string", "enum": ["shift", "option", "control", "command"]], "maxItems": 4], "repeat": ["type": "integer", "minimum": 1, "maximum": 50]],
                 ["app", "key"], false, false)
        ]
    }
    public static func response(_ message: JSONObject, profile: MCPToolProfile = .all, call: (String, JSONObject) throws -> JSONObject) -> JSONObject? {
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
                "instructions": profile.instructions])
        case "ping": return result([:])
        case "tools/list": return result(["tools": tools.filter { profile.allows($0["name"] as? String ?? "") }])
        case "tools/call":
            do {
                guard let params = message["params"] as? JSONObject, let name = params["name"] as? String,
                      profile.allows(name), tools.contains(where: { $0["name"] as? String == name }) else { throw AppError.message("지원하지 않는 MCP 도구입니다.") }
                var value = try call(name, params["arguments"] as? JSONObject ?? [:])
                // A window capture is returned as an image block, not as base64 text.
                let image = value.removeValue(forKey: "image") as? JSONObject
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
                var content: [JSONObject] = [["type": "text", "text": String(decoding: data, as: UTF8.self)]]
                if let image, let bytes = image["data"] as? String, let mime = image["mimeType"] as? String {
                    content.append(["type": "image", "data": bytes, "mimeType": mime])
                }
                return result(["content": content, "structuredContent": value, "isError": false])
            } catch { return result(["content": [["type": "text", "text": error.localizedDescription]], "isError": true]) }
        default: return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
    }
    public static func run(paths: AppPaths, profile: MCPToolProfile = .all) {
        MCPProcessEnvironment.configure()
        let owner = UUID().uuidString
        defer { _ = try? SocketClient.request(path: paths.socket, message: ["method": "mcp", "params": ["tool": "disconnect", "owner": owner]], timeout: 2) }
        // Keep protocol health/list requests responsive while a bridge tool is
        // waiting. Mutations retain arrival order and a bounded queue; no effects
        // are replayed and stdout frames must never interleave.
        let tools = DispatchQueue(label: "autoapprove.mcp.tools")
        let queries = OperationQueue()
        queries.name = "autoapprove.mcp.queries"; queries.maxConcurrentOperationCount = 4
        let queryTools = Set(Self.tools.compactMap { tool -> String? in
            guard (tool["annotations"] as? JSONObject)?["readOnlyHint"] as? Bool == true else { return nil }
            return tool["name"] as? String
        }).union(["get_group_status"])
        let slots = DispatchSemaphore(value: 16), output = NSLock()
        func reply(_ value: JSONObject) { output.lock(); defer { output.unlock() }; write(value) }
        defer { tools.sync {}; queries.waitUntilAllOperationsAreFinished() }
        var reportedInitialization = false
        let input = MCPInputReader(descriptor: STDIN_FILENO)
        while autoreleasepool(invoking: { () -> Bool in
            guard let frame = try? input.next() else { return false }
            // JSONSerialization auto-detects UTF-16/32. A raw NUL cannot occur
            // in valid UTF-8 JSON and must not switch this NDJSON wire format.
            guard case .message(let data) = frame, !data.contains(0), String(data: data, encoding: .utf8) != nil,
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
                reply(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); return true
            }
            if !reportedInitialization, message["jsonrpc"] as? String == "2.0", message["id"] == nil,
               message["method"] as? String == "notifications/initialized" {
                reportedInitialization = true
                let parent = getppid()
                queries.addOperation {
                    _ = try? SocketClient.request(path: paths.socket, message: ["method": "mcp", "params": [
                        "tool": "connection_initialized", "owner": owner, "parentPID": Int(parent)]], timeout: 3)
                }
            }
            let handle = {
            if let value = response(message, profile: profile, call: { tool, arguments in
                var params = arguments; params["tool"] = tool; params["owner"] = owner
                let groupTool = ["wait_group_dependencies", "update_group_wait", "complete_group_task", "get_session_groups", "get_group_status", "assign_group_task", "answer_group_question", "reconnect_group_member", "send_group_message", "ask_group_question", "reply_group_question", "get_group_messages", "ack_group_messages", "clear_session_group", "clear_group_member", "set_group_member_title", "set_group_member_tab_color", "get_group_clear_status"].contains(tool)
                // Only this process may attribute the caller; never trust a supplied session or agent kind.
                params.removeValue(forKey: "codexCallerRuntimeID")
                if groupTool {
                    params.removeValue(forKey: "sessionID"); params.removeValue(forKey: "agentKind")
                    params.removeValue(forKey: "codexCallerHome"); params.removeValue(forKey: "codexCallerConversationID")
                    params.removeValue(forKey: "codexCallerSource")
                }
                // Handshake/list/ping and owner-scoped replies need no process
                // scan. Resolve attribution freshly only when it is used.
                if tool == "ask_user" || tool == "start_screen_share" || groupTool {
                    let environment = ProcessInfo.processInfo.environment
                    let parent = getppid()
                    let enclosing = try? ProcessDiscovery.enclosingAgent(of: parent)
                    let agent = getppid() == parent ? enclosing : nil
                    // Codex's per-call metadata identifies the conversation even
                    // when its MCP parent is a shared daemon, not a terminal CLI.
                    // A Claude child launched from Codex may inherit its exec
                    // environment. Keep Claude's existing attribution path.
                    let callID = groupTool && agent?.agent != .agy && agent?.agent != .claude ? try CodexGroupIdentity.conversationID(in: message) : nil
                    let codexID = callID ?? (groupTool && agent?.agent != .agy && agent?.agent != .claude ?
                        environment["CODEX_THREAD_ID"].flatMap(UUID.init(uuidString:))?.uuidString.lowercased() : nil)
                    if let id = codexID {
                        if let claimed = params["conversationID"] as? String, UUID(uuidString: claimed) != UUID(uuidString: id) {
                            throw AppError.message("지정한 대화 ID가 이 Codex 호출의 대화와 다릅니다.")
                        }
                        params["agentKind"] = AgentKind.codex.rawValue
                        params["conversationID"] = id
                        // Official Codex filters CODEX_HOME out of the default
                        // MCP environment. The parent can locate the account
                        // home, but never supplies the conversation identity.
                        let homeEnvironment = environment["CODEX_HOME"] != nil ? environment :
                            (agent.flatMap(ProcessEnvironment.read) ?? environment)
                        params["codexCallerHome"] = CodexGroupIdentity.home(environment: homeEnvironment)
                        params["codexCallerConversationID"] = id
                        params["codexCallerSource"] = callID == nil ? "codex_exec_context" : "codex_mcp_metadata"
                        if callID != nil, let agent, agent.agent == .codex, agent.isForeground,
                           TerminalProfileLauncher.validTTY("/dev/" + agent.tty), CodexGroupIdentity.allowsTerminalAttribution(message) {
                            params["codexCallerRuntimeID"] = agent.key
                        }
                    }
                    if codexID == nil, let agent {
                        params["sessionID"] = agent.key
                        if groupTool { params["agentKind"] = agent.agent?.rawValue }
                    }
                }
                return try MCPBridgeClient.request(path: paths.socket, message: ["method": "mcp", "params": params], timeout: groupTool ? 60 : 20)
            }) { reply(value) }
            }
            if message["method"] as? String == "tools/call", message["id"] != nil {
                guard slots.wait(timeout: .now()) == .success else {
                    reply(["jsonrpc": "2.0", "id": message["id"]!, "error": ["code": -32000, "message": "MCP 도구 요청이 많습니다. 진행 중인 요청의 결과를 확인한 뒤 다시 시도해주세요."]])
                    return true
                }
                let name = (message["params"] as? JSONObject)?["name"] as? String ?? ""
                if queryTools.contains(name) {
                    queries.addOperation { defer { slots.signal() }; autoreleasepool { handle() } }
                } else {
                    tools.async { defer { slots.signal() }; autoreleasepool { handle() } }
                }
            } else { handle() }
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
