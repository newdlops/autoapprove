import Foundation

public struct CodexApprovalBinding: Codable, Equatable, Sendable {
    public var threadID: String
    public var title: String
    public var status: String
    public init(threadID: String, title: String, status: String = "승인 연결을 확인하고 있습니다…") {
        self.threadID = threadID; self.title = title; self.status = status
    }
}

public struct CodexSubagentRow: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let status: String
}

struct CodexServerApproval {
    let id: Any
    let key: String
    let threadID: String
    let summary: String
    let request: String
    let risk: SystemCommandRisk?
    let result: JSONObject

    /// Only supported approval RPCs are eligible. Never interpret an ordinary
    /// question, tool invocation or mandatory human review as an approval.
    static func parse(_ object: JSONObject, threads: [String: JSONObject], fileItem: JSONObject? = nil) -> Self? {
        guard let id = object["id"], let rpcKey = CodexQueueConnection.requestKey(id),
              let method = object["method"] as? String, let p = object["params"] as? JSONObject,
              let thread = p["threadId"] as? String, let metadata = threads[thread],
              let cwd = metadata["cwd"] as? String,
              let bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        let turn = p["turnId"] as? String ?? "", item = p["itemId"] as? String ?? ""
        let text: String
        switch method {
        case "item/commandExecution/requestApproval":
            guard !turn.isEmpty, !item.isEmpty,
                  p["kind"] == nil || p["kind"] as? String == "command" || p["kind"] as? String == "writeStdin",
                  let command = p["command"] as? String, !command.isEmpty,
                  let commandCWD = p["cwd"] as? String, commandCWD.hasPrefix("/"),
                  p["availableDecisions"] == nil || p["availableDecisions"] is NSNull ||
                    (p["availableDecisions"] as? [Any])?.contains(where: { $0 as? String == "accept" }) == true else { return nil }
            text = command + "\n" + String(decoding: (try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        case "item/fileChange/requestApproval":
            guard !turn.isEmpty, !item.isEmpty, p["grantRoot"] == nil || p["grantRoot"] is NSNull,
                  let fileItem, fileItem["id"] as? String == item, fileItem["type"] as? String == "fileChange",
                  fileItem["status"] as? String == "inProgress",
                  let changes = fileItem["changes"] as? [JSONObject], !changes.isEmpty,
                  changes.allSatisfy({ ($0["path"] as? String)?.hasPrefix("/") == true }),
                  let data = try? JSONSerialization.data(withJSONObject: fileItem, options: [.sortedKeys]) else { return nil }
            text = String(decoding: data, as: UTF8.self)
        case "mcpServer/elicitation/request":
            // Computer Use permission is an empty form with an explicit Allow
            // question. No form fields, URL or verification challenge can be
            // invented or answered through this consent-only path.
            guard p["mode"] as? String == "form", let server = p["serverName"] as? String, !server.isEmpty,
                  let schema = p["requestedSchema"] as? JSONObject, schema["type"] as? String == "object",
                  let properties = schema["properties"] as? JSONObject, properties.isEmpty,
                  schema["required"] == nil || (schema["required"] as? [String])?.isEmpty == true,
                  Set(schema.keys).isSubset(of: ["type", "properties", "required", "additionalProperties"]),
                  schema["additionalProperties"] == nil || schema["additionalProperties"] as? Bool == false,
                  let message = p["message"] as? String,
                  message.range(of: #"^Allow [^\r\n]+\?$"#, options: .regularExpression) != nil else { return nil }
            text = server + "\n" + message
        default: return nil
        }
        let risk = SystemCommandRisk.detect(text, cwd: p["cwd"] as? String ?? cwd)
        var denial = "decline"
        if risk != nil, let decisions = p["availableDecisions"] as? [Any], !decisions.contains(where: { $0 as? String == denial }) {
            guard decisions.contains(where: { $0 as? String == "cancel" }) else { return nil }
            denial = "cancel"
        }
        let result: JSONObject = method == "mcpServer/elicitation/request"
            ? ["action": risk == nil ? "accept" : "decline", "content": risk == nil ? [:] : NSNull(), "_meta": NSNull()]
            : ["decision": risk == nil ? "accept" : denial]
        let label = metadata["agentNickname"] as? String ?? metadata["name"] as? String ?? thread
        return Self(id: id, key: PromptDetector.fingerprint(thread + "\n" + turn + "\n" + item + "\n" + rpcKey + "\n" + String(decoding: bytes, as: UTF8.self)),
            threadID: thread, summary: "Thread: " + label + "\n" + String(text.prefix(4000)), request: String(decoding: bytes, as: UTF8.self),
            risk: risk, result: result)
    }
}

enum CodexSubagentApprovals {
    static func taskPath(_ row: JSONObject) -> String? {
        guard let source = row["source"] as? JSONObject,
              let subagent = (source["subAgent"] ?? source["subagent"]) as? JSONObject,
              let spawn = subagent["thread_spawn"] as? JSONObject,
              let parent = row["parentThreadId"] as? String,
              spawn["parent_thread_id"] as? String == parent,
              let path = spawn["agent_path"] as? String, path.hasPrefix("/root/"),
              !path.contains("\n"), !path.contains("\r") else { return nil }
        return path
    }
    static func children(target: CodexReplyTarget, cwd: String) throws -> [CodexSubagentRow] {
        let connection = try CodexQueueConnection(home: target.home, captureApprovals: true)
        let root = try connection.request("thread/read", ["threadId": target.threadID, "includeTurns": false])["thread"] as? JSONObject
        guard let root, root["id"] as? String == target.threadID, root["cwd"] as? String == cwd,
              root["parentThreadId"] == nil || root["parentThreadId"] is NSNull else {
            throw AppError.message("연결한 부모 대화가 바뀌었습니다.")
        }
        let owned = ownedThreads(root: target.threadID, rows: try loadedThreads(connection))
        guard owned[target.threadID] != nil else { throw AppError.message("부모 대화가 실행 중이 아닙니다.") }
        return owned.compactMap { id, row in
            guard id != target.threadID else { return nil }
            let label = taskPath(row) ?? "작업 이름 미확인"
            let state = row["status"] as? JSONObject ?? [:]
            let waiting = (state["activeFlags"] as? [String])?.contains("waitingOnApproval") == true
            return CodexSubagentRow(id: id, title: label, status: waiting ? "승인 대기" : (state["type"] as? String ?? "상태 미확인"))
        }.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title < $1.title }
    }
    /// Validate ancestry independently of server-side filtering. Missing parents,
    /// cycles, unrelated roots, forks and unloaded threads cannot acquire a policy.
    static func ownedThreads(root: String, rows: [JSONObject]) -> [String: JSONObject] {
        var byID: [String: JSONObject] = [:]
        for row in rows {
            guard let id = row["id"] as? String, UUID(uuidString: id) != nil, byID[id] == nil else { return [:] }
            byID[id] = row
        }
        guard let owner = byID[root], owner["parentThreadId"] == nil || owner["parentThreadId"] is NSNull else { return [:] }
        return byID.filter { id, row in
            guard let status = row["status"] as? JSONObject, ["active", "idle"].contains(status["type"] as? String ?? "") else { return false }
            var current = id, seen = Set<String>()
            while current != root {
                guard seen.insert(current).inserted, let parent = byID[current]?["parentThreadId"] as? String else { return false }
                current = parent
            }
            return true
        }
    }

    static func loadedThreads(_ connection: CodexQueueConnection) throws -> [JSONObject] {
        var ids: [String] = [], cursor: String?, cursors = Set<String>()
        repeat {
            var params: JSONObject = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let page = try connection.request("thread/loaded/list", params)
            guard let data = page["data"] as? [String], data.count <= 100,
                  data.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw AppError.message("실행 중인 대화 목록을 확인하지 못했습니다.") }
            ids += data; cursor = page["nextCursor"] as? String
            guard ids.count <= 500, Set(ids).count == ids.count,
                  cursor == nil || cursors.insert(cursor!).inserted else { throw AppError.message("실행 중인 대화 목록 한도를 초과했습니다.") }
        } while cursor != nil
        return try ids.map { id in
            let response = try connection.request("thread/read", ["threadId": id, "includeTurns": false])
            guard let row = response["thread"] as? JSONObject, row["id"] as? String == id else { throw AppError.message("대화 식별자가 바뀌었습니다.") }
            return row
        }
    }

    static func roots(target: CodexReplyTarget, cwd: String) throws -> [CodexQueueConversation] {
        let connection = try CodexQueueConnection(home: target.home, captureApprovals: true)
        return try loadedThreads(connection).compactMap { row in
            guard row["cwd"] as? String == cwd, row["parentThreadId"] == nil || row["parentThreadId"] is NSNull,
                  let id = row["id"] as? String,
                  ["active", "idle"].contains((row["status"] as? JSONObject)?["type"] as? String ?? "") else { return nil }
            return CodexQueueConversation(id: id, title: String((row["name"] as? String ?? row["preview"] as? String ?? id).prefix(180)))
        }
    }

    /// Attach only to loaded conversations already waiting for a decision. No
    /// new turn, policy override, model change or terminal navigation is sent.
    static func poll(target: CodexReplyTarget, cwd: String,
                     authorize: @escaping @Sendable (CodexServerApproval) async -> Bool,
                     completed: @escaping @Sendable (CodexServerApproval, Bool) async -> Void) async throws -> (responded: Int, review: Int) {
        let connection = try CodexQueueConnection(home: target.home, captureApprovals: true)
        let root = try connection.request("thread/read", ["threadId": target.threadID, "includeTurns": false])["thread"] as? JSONObject
        guard let root, root["id"] as? String == target.threadID, root["cwd"] as? String == cwd,
              root["parentThreadId"] == nil || root["parentThreadId"] is NSNull else { throw AppError.message("연결한 부모 대화가 바뀌었습니다. 다시 연결해주세요.") }
        let rows = try loadedThreads(connection)
        let owned = ownedThreads(root: target.threadID, rows: rows)
        guard owned[target.threadID] != nil else { throw AppError.message("부모 대화가 실행 중이 아닙니다.") }
        let waiting = owned.filter {
            (($0.value["status"] as? JSONObject)?["activeFlags"] as? [String])?.contains("waitingOnApproval") == true
        }
        var attached: [String: JSONObject] = [:]
        for (id, metadata) in waiting {
            try Task.checkCancellation()
            let resumed = try connection.request("thread/resume", ["threadId": id, "excludeTurns": true])["thread"] as? JSONObject
            guard let resumed, resumed["id"] as? String == id, resumed["cwd"] as? String == metadata["cwd"] as? String,
                  resumed["parentThreadId"] as? String == metadata["parentThreadId"] as? String else { continue }
            attached[id] = metadata
        }
        if attached.isEmpty { return (0, 0) }
        try connection.collectRequests()
        var count = 0, review = 0, seen = Set<String>()
        // Bound this snapshot: new requests are picked up on the next poll.
        for object in connection.pendingRequests {
            try Task.checkCancellation()
            guard let id = object["id"], let rpcKey = CodexQueueConnection.requestKey(id), seen.insert(rpcKey).inserted,
                  !connection.resolvedRequests.contains(rpcKey), let params = object["params"] as? JSONObject,
                  let thread = params["threadId"] as? String, attached[thread] != nil else { continue }
            var fileItem: JSONObject?
            if object["method"] as? String == "item/fileChange/requestApproval",
               let turn = params["turnId"] as? String, let item = params["itemId"] as? String {
                let result = try connection.request("thread/items/read", ["threadId": thread, "turnId": turn, "itemIds": [item]])
                fileItem = (result["data"] as? [JSONObject])?.first(where: { $0["turnId"] as? String == turn })?["item"] as? JSONObject
            }
            guard let approval = CodexServerApproval.parse(object, threads: attached, fileItem: fileItem),
                  !connection.resolvedRequests.contains(rpcKey), await authorize(approval) else { review += 1; continue }
            do {
                try connection.respond(id: id, result: approval.result)
                // A live read acts as a round trip after the response; the
                // resolved notification is the acknowledgement, not write().
                _ = try connection.request("thread/read", ["threadId": thread, "includeTurns": false])
                try connection.collectRequests(untilResolved: rpcKey)
                await completed(approval, connection.resolvedRequests.contains(rpcKey)); count += 1
            } catch { await completed(approval, false); throw error }
        }
        return (count, review)
    }
}
