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
        func tool(_ name: String, _ description: String, _ properties: JSONObject = [:], _ required: [String] = [], readOnly: Bool = false, destructive: Bool = false) -> JSONObject {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false]]
        }
        return [
            tool("ask_user", "휴대폰 웹에 선택지·직접 답변 폼을 게시합니다. 기본값을 답변으로 처리하지 않습니다. 반환된 requestID로 get_user_answers에서 사용자가 보낸 답변을 확인하세요.",
                 ["title": string, "questions": ["type": "array", "items": field, "minItems": 1, "maxItems": 8]], ["questions"]),
            tool("get_user_answers", "이 MCP 연결에서 게시한 질문의 응답을 확인합니다. waiting이면 아직 답변이 없습니다. answered의 answers만 실제 사용자 응답입니다.", ["requestID": string], ["requestID"], readOnly: true),
            tool("get_session_groups", "현재 세션의 그룹과 구성원을 로컬에서 조회합니다. model·reasoningEffort는 마지막으로 기록된 설정이며 modelSettingsSource·modelSettingsRecordedAt으로 출처·시점을 확인합니다. 확인할 수 없는 값은 null입니다. 공유 서버에서는 현재 대화 UUID를 conversationID로 지정하세요. connected가 false이고 canReconnect가 true인 구성원은 reconnect_group_member로 재연결하세요. 자유 형식 질문은 ask_group_question, 답변은 reply_group_question으로 Codex↔Claude를 포함한 같은 그룹 구성원에게 전달하세요. 그룹 상태는 get_group_status, 직속 작업·승인 지시는 assign_group_task·answer_group_question을 사용하세요. 일반 대화는 send_group_message로 Codex↔Claude를 포함한 같은 그룹 구성원에게 전달하세요. 그룹 연결과 메시지는 같은 Mac의 Unix 소켓과 원래 터미널만 사용하며 네트워크 격리 중에도 동작합니다. 외부 서버, codex queue 또는 SendMessage로 우회하지 마세요.", ["conversationID": string], readOnly: true),
            tool("reconnect_group_member", "같은 Mac에서 구성원의 현재 세션 ID를 확인하고 그룹 연결을 갱신합니다. get_session_groups의 canReconnect가 true인 자기 자신·직속 구성원(그룹장이 없으면 같은 그룹 구성원)에 사용할 수 있습니다. Codex는 로컬 대화 기록과 대상에 연결된 최근 MCP 호출을 차례로 확인합니다. 둘 다 부족하면 원래 탭의 빈 입력창에서 /status를 조회합니다. 초안이나 승인창이 열려 있으면 조회를 보류합니다. 성공 후 connected와 conversationID를 확인하세요.",
                 ["groupID": string, "memberID": string, "conversationID": string], ["groupID", "memberID"]),
            tool("send_group_message", "같은 그룹의 다른 구성원에게 일반 메시지를 보냅니다. Codex↔Claude 양방향을 지원하며 그룹장이 있어도 사용할 수 있습니다. 일반 메시지는 작업 지시·승인 권한을 부여하지 않습니다. 로컬 수신함에 디스크 저장한 뒤 accepted와 messageID를 반환합니다. 작업·입력·연결 끊김 중에도 보관하며 충돌이 없어지면 수신함 알림을 재시도합니다. 수신자의 ack_group_messages 전에는 전달 완료가 아닙니다. 재시도에는 같은 messageID를 사용하세요. 외부 전송 경로로 우회하지 마세요.",
                 ["groupID": string, "memberID": string, "text": ["type": "string", "minLength": 1, "maxLength": SessionGroupOrchestration.maximumTaskLength], "messageID": string, "conversationID": string], ["groupID", "memberID", "text"]),
            tool("ask_group_question", "같은 그룹의 그룹장·동료·하위 구성원에게 질문합니다. Codex↔Claude를 지원합니다. 원문을 로컬 수신함에 저장한 뒤 accepted와 messageID를 반환하므로 대상이 바빠도 호출자가 반복 전송할 필요가 없습니다. 터미널에는 수신함 알림을 순서대로 재시도하며 에이전트의 명시적 ACK까지 보관합니다. 재호출에는 같은 messageID(UUID)를 사용하세요. 생략한 경우 동일 대상·내용의 미확인 메시지만 합칩니다. 수신 확인은 작업 수행·승인이 아닙니다. 작업 지시는 assign_group_task, 선택지·권한 승인은 answer_group_question을 사용하세요. Codex send_message_to_thread 등으로 그룹 밖에 우회 전송하지 마세요.",
                 ["groupID": string, "memberID": string, "text": ["type": "string", "minLength": 1, "maxLength": SessionGroupOrchestration.maximumTaskLength], "messageID": string, "conversationID": string], ["groupID", "memberID", "text"]),
            tool("reply_group_question", "같은 그룹 구성원의 질문에 답변을 로컬 수신함으로 보냅니다. 받은 메시지의 groupID와 senderMemberID를 대상으로 지정하고 무엇에 대한 답인지 적으세요. Codex↔Claude를 지원합니다. accepted는 디스크 저장 완료이며 수신자가 ack_group_messages로 확인할 때까지 보관·재알림합니다. 재호출에는 같은 messageID(UUID)를 유지하세요. 답변을 보내도 받은 질문의 수신 확인은 별도로 해야 합니다. 선택지·권한 요청은 answer_group_question으로 답하세요.",
                 ["groupID": string, "memberID": string, "text": ["type": "string", "minLength": 1, "maxLength": SessionGroupOrchestration.maximumTaskLength], "messageID": string, "conversationID": string], ["groupID", "memberID", "text"]),
            tool("get_group_messages", "자기 그룹의 로컬 수신함 또는 보낸 메시지를 접수 순서대로 읽습니다. 작업 시작 전과 수신함 알림을 받았을 때 확인하세요. 조회만으로 수신 확인되지 않습니다. 받은 messageID들을 ack_group_messages로 확인하고 이미 처리한 ID는 재실행하지 마세요. hasMore이면 nextAfterSequence를 afterSequence로 넘겨 계속 읽으세요. outbox와 includeAcknowledged로 상대 수신 상태를 확인할 수 있습니다. 다른 그룹·다른 구성원의 수신함은 조회할 수 없습니다.",
                 ["groupID": string, "direction": ["type": "string", "enum": ["inbox", "outbox"]], "includeAcknowledged": ["type": "boolean"], "afterSequence": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 50], "conversationID": string], ["groupID"], readOnly: true),
            tool("ack_group_messages", "실제로 받은 자기 수신함 메시지를 ID별로 수신 확인합니다. get_group_messages 또는 get_group_status.mailbox.inbox에서 내용을 읽은 뒤 호출하세요. 저장에 성공해야 acknowledged=true를 반환하며 같은 ID의 반복 확인은 안전합니다. 작업 수행·동의·권한 승인이 아닙니다. 수신 확인한 메시지는 알림을 중단하고 재호출 시에도 중복 생성하지 않습니다.",
                 ["groupID": string, "messageIDs": ["type": "array", "items": string, "minItems": 1, "maxItems": 50, "uniqueItems": true], "conversationID": string], ["groupID", "messageIDs"]),
            tool("get_group_status", "세션 그룹의 트리, 구성원 상태, 진행 중인 작업과 이 세션에 도착한 작업 보고를 조회합니다. model·reasoningEffort는 마지막 기록값이며 출처·시점은 modelSettingsSource·modelSettingsRecordedAt에 표시합니다. 확인되지 않은 값은 null입니다. 보고는 mailbox.inbox 또는 get_group_messages로 읽고 ack_group_messages로 수신 확인해야 완료됩니다. 조회 응답을 잃어도 미확인 보고는 남습니다. canAssign이 true인 직속 구성원에게만 작업을 지시할 수 있습니다. 공유 서버에서 세션을 자동 식별하지 못하면 현재 대화 UUID를 conversationID로 지정하세요.",
                 ["conversationID": string]),
            tool("assign_group_task", "직속 하위 구성원의 터미널에 작업을 입력합니다. 작업자가 대기 상태일 때만 전달하고, 작업자가 권한 확인에서 멈추지 않도록 작업자 세션의 자동 승인을 켭니다. 작업자가 응답을 마치면 마지막 응답 요약을 이 세션의 로컬 수신함에 저장하고 수신 확인 전까지 알림을 재시도합니다. 작업 내용은 머리말이나 출처 표시 없이, 사용자가 직접 입력한 것처럼 한 줄로 그대로 입력됩니다. 작업자가 그대로 읽고 수행할 지시만 적고, 그룹이나 그룹장, 위임, AutoApprove를 언급하지 마세요. 목록은 번호로 구분하고, /, !, #, $, &로 시작하는 내용은 보낼 수 없습니다. 공유 서버에서 세션을 자동 식별하지 못하면 현재 대화 UUID를 conversationID로 지정하세요.",
                 ["groupID": string, "memberID": string, "task": ["type": "string", "minLength": 1, "maxLength": SessionGroupOrchestration.maximumTaskLength], "conversationID": string],
                 ["groupID", "memberID", "task"]),
            tool("answer_group_question", "직속 하위 구성원이 작업 중에 터미널 선택지 질문이나 권한 확인에서 멈췄을 때 선택지 번호로 답합니다. 질문과 승인 요청은 그룹 보고나 get_group_status의 task.question으로 받습니다. 권한 확인은 사용자가 이 세션에 위임한 승인이므로, 선택이 사용자 승인으로 처리됩니다. 요청 내용을 확인하고 작업 범위 안의 요청만 승인하세요. AutoApprove가 사용자에게도 승인시키지 않는 시스템 변경과 전체 일시정지 중의 요청은 넘어오지 않습니다. 화면의 요청이 바뀌었으면 답하지 않습니다. 공유 서버에서 세션을 자동 식별하지 못하면 현재 대화 UUID를 conversationID로 지정하세요.",
                 ["groupID": string, "memberID": string, "choice": ["type": "integer", "minimum": 1, "maximum": 9], "conversationID": string],
                 ["groupID", "memberID", "choice"]),
            tool("clear_session_group", "그룹 전체에 /clear를 한 번씩 실행한 뒤 새 대화 UUID를 조회하여 그룹에 저장하는 비동기 작업을 접수합니다. 호출자 자신도 포함되며 마지막에 처리됩니다. 그룹장이 있으면 그룹장만 요청할 수 있습니다. 새 requestID(UUID)를 한 번 만들고 재시도에도 같은 값을 유지하세요. accepted는 저장 완료이며 초기화 완료가 아닙니다. 작업·질문·승인·작성 중인 입력이 있으면 빈 입력창까지 기다립니다. 새 ID를 확인하지 못하면 needs_review로 남기며 /clear를 자동 재전송하지 않습니다. 기존 그룹 역할·미확인 메시지는 보존합니다. 접수 후 현재 응답을 마쳐 호출자도 초기화될 수 있게 하세요. get_group_clear_status로 결과를 조회합니다.",
                 ["groupID": string, "requestID": string, "conversationID": string], ["groupID", "requestID"], destructive:true),
            tool("clear_group_member", "같은 그룹의 memberID로 지정한 세션 하나에 /clear를 실행하고 새 대화 UUID를 조회하여 그룹에 저장하는 비동기 작업을 접수합니다. 다른 세션은 초기화하지 않습니다. 전체 초기화와 같은 권한으로 그룹장이 있으면 그룹장만 요청할 수 있습니다. 새 requestID(UUID)를 만들고 같은 대상의 재시도에도 유지하세요. 다른 대상이나 전체 초기화에는 새 requestID가 필요합니다. accepted는 저장 완료이며 초기화 완료가 아닙니다. 작업·질문·승인·작성 중인 입력이 있으면 빈 입력창까지 기다립니다. 전달이 불확실해도 /clear를 자동 재전송하지 않습니다. 그룹 역할·미확인 메시지는 보존합니다. 자신을 지정했다면 접수 후 현재 응답을 마치세요. get_group_clear_status(groupID,requestID)로 결과를 확인합니다.",
                 ["groupID": string, "memberID": string, "requestID": string, "conversationID": string], ["groupID", "memberID", "requestID"], destructive:true),
            tool("set_group_member_title", "같은 그룹에서 지정한 구성원의 원래 Terminal·iTerm2 탭 이름과 AutoApprove 표시 이름을 바꿉니다. title은 한 줄로 1~80자입니다. 기존 탭 색상 표식·메모는 유지합니다. 대화 UUID와 원래 프로세스·TTY를 확인하고 실제 적용된 이름을 다시 읽습니다. 그룹장이 있으면 그룹장만 요청할 수 있습니다. CLI 입력이나 작업을 중단하지 않아 작업 중에도 사용할 수 있습니다.",
                 ["groupID": string, "memberID": string, "title": string, "conversationID": string], ["groupID", "memberID", "title"]),
            tool("set_group_member_tab_color", "같은 그룹에서 지정한 구성원의 Terminal·iTerm2 탭 이름 앞에 색상 표식을 붙입니다. Terminal.app은 탭 바만의 배경색 API가 없어 🔴·🟠·🟡·🟢·🔵·🟣·⚪️ 표식을 사용하며 colorMode=title_marker로 반환합니다. default는 표식을 제거합니다. 탭 이름과 메모를 유지하고 AutoApprove의 세션 색상도 함께 저장합니다. 그룹장이 있으면 그룹장만 요청할 수 있습니다. CLI 입력·본문 배경색·글자색·포커스는 변경하지 않습니다. 작업 중에도 사용할 수 있습니다.",
                 ["groupID": string, "memberID": string, "color": ["type":"string","enum":SessionColor.allCases.map(\.rawValue) + ["default"]], "conversationID": string], ["groupID", "memberID", "color"]),
            tool("get_group_clear_status", "같은 그룹의 전체 또는 개별 초기화 진행과 대상의 beforeConversationID·새 conversationID·오류를 조회합니다. scope=group은 전체, scope=member와 memberID는 개별 지정 요청입니다. requestID를 생략하면 그룹의 최근 요청을 조회하므로 초기화로 대화 맥락이 사라진 뒤에도 확인할 수 있습니다. done과 status=completed를 확인해야 요청한 대상의 초기화·ID 갱신이 완료된 것입니다. needs_review는 터미널 확인이 필요하며 조회로 /clear를 재전송하지 않습니다. 초기화 뒤에는 현재 대화 UUID로 호출하세요.",
                 ["groupID": string, "requestID": string, "conversationID": string], ["groupID"], readOnly:true),
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
                "instructions": "작업 시작 전과 그룹 수신함 알림을 받으면 get_group_messages로 메시지를 읽고 ack_group_messages로 수신 확인하세요. 같은 messageID의 작업을 반복하지 마세요. accepted는 로컬 저장이며 수신 확인이 아닙니다. 협업할 때 get_session_groups로 현재 세션이 속한 그룹과 구성원을 확인하세요. 그룹장이 있는 그룹에서는 get_group_status로 상태를 보고, 직속 구성원에게 보내는 작업 지시와 선택지·승인 답변은 반드시 assign_group_task와 answer_group_question을 사용하세요. AutoApprove가 지시를 작업자 터미널에 사용자가 직접 입력한 것처럼 그대로 입력하므로, 각 도구의 메시지 기능으로 직접 지시하지 말고 작업 내용에는 작업자가 수행할 지시만 적으세요. 일반 메시지는 send_group_message로 Codex↔Claude를 포함한 같은 그룹 구성원에게 보내세요. 일반 대화는 작업 지시·승인 권한을 부여하지 않습니다. 연결이 끊겼고 canReconnect가 true이면 reconnect_group_member로 복구하세요. 그룹장·동료에게 자유 형식 질문은 ask_group_question, 답변은 reply_group_question으로 보내세요. Codex↔Claude도 지원하며 작업·승인 권한을 바꾸지 않습니다. 메시지는 같은 Mac의 로컬 수신함에 저장되며 수신 확인 전까지 보관·재알림합니다. 모든 그룹 통신은 같은 Mac 안에서만 처리하세요. 전송이 지연돼도 Codex send_message_to_thread, codex queue, Claude SendMessage 등 별도 도구로 그룹 밖이나 다른 스레드에 우회하지 마세요. 작업 보고, 작업자의 선택지 질문과 위임된 승인 요청은 지시한 세션의 로컬 수신함에 보관됩니다. get_group_messages로 읽고 ack_group_messages로 수신 확인하세요. 선택지·승인 요청은 현재 화면을 확인하는 answer_group_question으로 답하세요. 휴대폰의 AutoApprove 웹에서 질문에 답하고 테스트 화면을 봅니다. ask_user 뒤 get_user_answers로 명시적 답변을 확인하세요. waiting·만료는 답변이 아닙니다. 화면은 사용자가 보고 싶어 할 때만 start_screen_share로 시작하고 시험 종료 시 stop_screen_share로 종료하세요. 기존 터미널을 재시작하거나 새 PTY를 만들 필요가 없습니다."])
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
        let input = MCPInputReader(descriptor: STDIN_FILENO)
        while autoreleasepool(invoking: { () -> Bool in
            guard let frame = try? input.next() else { return false }
            // JSONSerialization auto-detects UTF-16/32. A raw NUL cannot occur
            // in valid UTF-8 JSON and must not switch this NDJSON wire format.
            guard case .message(let data) = frame, !data.contains(0), String(data: data, encoding: .utf8) != nil,
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
                reply(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); return true
            }
            let handle = {
            if let value = response(message, call: { tool, arguments in
                var params = arguments; params["tool"] = tool; params["owner"] = owner
                let groupTool = ["get_session_groups", "get_group_status", "assign_group_task", "answer_group_question", "reconnect_group_member", "send_group_message", "ask_group_question", "reply_group_question", "get_group_messages", "ack_group_messages", "clear_session_group", "clear_group_member", "set_group_member_title", "set_group_member_tab_color", "get_group_clear_status"].contains(tool)
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
                    let callID = groupTool && agent?.agent != .claude ? try CodexGroupIdentity.conversationID(in: message) : nil
                    let codexID = callID ?? (groupTool && agent?.agent != .claude ?
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
