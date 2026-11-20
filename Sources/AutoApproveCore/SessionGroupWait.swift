import Foundation
import CSQLite

/// A task result and a decision by the same member are independent graph nodes.
struct GroupWaitRequest: Codable, Equatable {
    enum Mode: String, Codable { case all, any }
    let id: UUID
    let group: UUID
    let member: UUID
    let task: UUID?
    let decision: UUID?
    let tasks: [UUID]
    let questions: [UUID]
    let external: Bool
    let mode: Mode
    let seconds: Int

    var source: String {
        if let decision { return "question:" + decision.uuidString }
        if let task { return "task:" + task.uuidString }
        return "member:" + member.uuidString
    }
    var inputs: [String] {
        tasks.map { "task:" + $0.uuidString } + questions.map { "question:" + $0.uuidString }
    }
    func matches(_ values: [Bool]) -> Bool {
        mode == .all ? values.allSatisfy { $0 } : values.contains(true)
    }
}

struct GroupWaitRecord {
    let request: GroupWaitRequest
    let state: String
    let deadline: Date
    let externalReady: Bool
    let detail: String

    var json: JSONObject {
        ["waitID": request.id.uuidString, "memberID": request.member.uuidString,
         "taskID": request.task?.uuidString as Any? ?? NSNull(), "source": request.source,
         "mode": request.mode.rawValue, "dependencies": request.inputs, "external": request.external,
         "externalReady": externalReady, "deadline": ISO8601DateFormatter().string(from: deadline),
         "state": state, "detail": detail]
    }
}

extension SessionGroupMailbox {
    private func waitRows(_ filter: String, _ values: [String] = []) throws -> [GroupWaitRecord] {
        let query = try statement("SELECT request,state,deadline,external_ready,detail FROM group_waits " + filter, values)
        defer { sqlite3_finalize(query) }
        var result: [GroupWaitRecord] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else {
                throw AppError.message("그룹 대기 기록을 읽지 못했습니다.")
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
            result.append(try GroupWaitRecord(request: JSONDecoder().decode(GroupWaitRequest.self, from: data),
                state: String(cString: sqlite3_column_text(query, 1)), deadline: Date(timeIntervalSince1970: sqlite3_column_double(query, 2)),
                externalReady: sqlite3_column_int(query, 3) != 0, detail: String(cString: sqlite3_column_text(query, 4))))
        }
    }

    func waitRecord(_ id: UUID) throws -> GroupWaitRecord? { try waitRows("WHERE id=?", [id.uuidString]).first }
    func visibleWaits(_ group: UUID) throws -> [GroupWaitRecord] {
        try waitRows("WHERE group_id=? AND state IN ('waiting','expired') ORDER BY deadline", [group.uuidString])
    }

    func expiredConversationQuestions(_ group: UUID) throws -> Set<UUID> {
        let waits = try visibleWaits(group)
        let waiting = Set(waits.filter { $0.state == "waiting" }.flatMap { $0.request.questions })
        return Set(waits.filter { $0.state == "expired" }.flatMap { $0.request.questions }).subtracting(waiting)
    }
    /// Uses only typed identifiers for Mermaid labels. Message bodies never enter the diagram.
    static func diagram(_ rows: [GroupWaitRecord]) -> String {
        func node(_ key: String) -> String {
            let identifier = "n" + key.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
            return identifier + "[\"" + key + "\"]"
        }
        var lines = ["flowchart LR"]
        for row in rows {
            let r = row.request
            let targets = r.inputs + (r.external ? ["external:" + r.id.uuidString] : [])
            for input in targets {
                let edge = row.state == "expired" ? "-.->" : "-->"
                lines.append("  " + node(r.source) + " " + edge + "|" + r.mode.rawValue + "| " + node(input))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func suppressLateAnswerDelivery(_ question: UUID, answer: SessionGroupMessage) throws {
        let waits = try waitRows("WHERE group_id=? AND state IN ('waiting','expired')", [answer.groupID.uuidString])
            .filter { $0.request.member == answer.recipientID && $0.request.questions.contains(question) }
        guard waits.contains(where: { $0.state == "expired" }),
              !waits.contains(where: { $0.state == "waiting" }) else { return }
        try update("UPDATE messages SET last_result='late' WHERE id=? AND last_result IS NULL", [answer.id.uuidString])
    }

    func canAutomaticallyAnswer(_ question: UUID) throws -> Bool {
        try !waitRows("WHERE state IN ('waiting','ready','expired')").contains { $0.request.decision == question }
    }

    func resumedWait(for notice: SessionGroupMessage) throws -> GroupWaitRequest? {
        guard let key = notice.sourceKey else { return nil }
        if notice.kind == .reply, key.hasPrefix("answer:"),
           let answered = UUID(uuidString: String(key.dropFirst(7))) {
            let matches = try waitRows("WHERE group_id=? AND state='ready'", [notice.groupID.uuidString]).filter {
                $0.request.member == notice.recipientID && $0.request.questions == [answered] &&
                    $0.request.tasks.isEmpty && !$0.request.external
            }
            return matches.count == 1 ? matches.first?.request : nil
        }
        guard notice.kind == .waitNotice else { return nil }
        let parts = key.split(separator: ":")
        guard parts.count == 4, parts[0] == "wait", parts[2] == "ready",
              let id = UUID(uuidString: String(parts[1])), let row = try waitRecord(id),
              row.state == "ready", row.request.group == notice.groupID,
              row.request.member == notice.recipientID else { return nil }
        return row.request
    }

    private func readyBody(_ request: GroupWaitRequest, assignments: [SessionGroupAssignment]) throws -> String {
        var results: [String] = []
        let noticeKey = "wait:\(request.id.uuidString):ready:\(request.member.uuidString)"
        for id in request.questions {
            guard let reply = try message(sourceKey: "answer:" + id.uuidString),
                  reply.groupID == request.group, reply.recipientID == request.member else { continue }
            results.append(try batchResult(reply, noticeKey: noticeKey))
        }
        for id in request.tasks {
            if let report = try message(sourceKey: "report:" + id.uuidString),
               report.groupID == request.group, report.recipientID == request.member {
                results.append(try batchResult(report, noticeKey: noticeKey))
            } else if let task = assignments.first(where: {
                $0.id == id && $0.groupID == request.group && $0.parentMemberID == request.member &&
                    [.completed, .reported].contains($0.status)
            }), let text = task.originalResponse ?? task.summary {
                try insertBatchSource(noticeKey, "report:" + id.uuidString)
                results.append("작업 " + id.uuidString + "\n" + text)
            }
        }
        return results.joined(separator: "\n\n")
    }

    private func insertBatchSource(_ notice: String, _ source: String) throws {
        try update("INSERT OR IGNORE INTO group_batch_sources(notice_key,source_key) VALUES(?,?)", [notice, source])
    }

    private func batchResult(_ message: SessionGroupMessage, noticeKey: String) throws -> String {
        let key = message.sourceKey ?? message.id.uuidString
        if message.acknowledgedAt != nil || (message.attempts > 0 && message.lastResult != "not_started") ||
            message.lastResult == "batched" {
            return key + " · 기존 수신함 원문 " + message.id.uuidString
        }
        try insertBatchSource(noticeKey, key)
        try update("UPDATE messages SET last_result='batched' WHERE id=?", [message.id.uuidString])
        return key + "\n" + message.text
    }

    func taskStillWaiting(_ id: UUID) throws -> Bool {
        try !waitRows("WHERE owner_task=? AND state='waiting'", [id.uuidString]).isEmpty
    }

    func tracksTask(_ task: UUID) throws -> Bool {
        let s = try statement("SELECT EXISTS(SELECT 1 FROM group_waits WHERE owner_task=?)", [task.uuidString])
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw AppError.message("작업 대기 기록을 확인하지 못했습니다.") }
        return sqlite3_column_int(s, 0) != 0
    }

    func hasUnresolvedWaits() throws -> Bool {
        let query = try statement("SELECT 1 FROM group_waits WHERE state IN ('waiting','expired') LIMIT 1")
        defer { sqlite3_finalize(query) }
        switch sqlite3_step(query) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw AppError.message("대기 상태를 읽지 못했습니다.")
        }
    }

    func nextWaitDeadline() throws -> Date? {
        let s = try statement("SELECT min(deadline) FROM group_waits WHERE state='waiting'")
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw AppError.message("다음 대기 기한을 읽지 못했습니다.") }
        return sqlite3_column_type(s, 0) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 0))
    }

    // Called inside the mailbox write transaction, together with the question if there is one.
    func registerWait(_ request: GroupWaitRequest, assignments: [SessionGroupAssignment], now: Date = Date()) throws -> GroupWaitRecord {
        if let old = try waitRecord(request.id) {
            guard old.request == request else { throw RemoteHTTPError(409, "waitID가 다른 요청에 사용되었습니다.") }
            return old
        }
        let groupTasks = assignments.filter { $0.groupID == request.group }
        if let task = request.task {
            guard groupTasks.contains(where: { $0.id == task && $0.workerMemberID == request.member && $0.status == .working && $0.isDelivered }) else {
                throw RemoteHTTPError(403, "현재 구성원에게 전달된 진행 중 작업만 대기를 등록할 수 있습니다.")
            }
        }
        if let decision = request.decision {
            guard let q = try message(decision), q.kind == .question, q.groupID == request.group, q.recipientID == request.member,
                  try message(sourceKey: "answer:" + decision.uuidString) == nil else { throw RemoteHTTPError(403, "자신이 답해야 하는 미해결 질문을 지정해주세요.") }
        }
        for q in request.questions {
            guard let m = try message(q), m.groupID == request.group, m.kind == .question, m.senderID == request.member else {
                throw RemoteHTTPError(403, "이 그룹에서 자신이 보낸 질문 ID를 지정해주세요.")
            }
        }
        for t in request.tasks where !groupTasks.contains(where: { $0.id == t && $0.isDelivered }) {
            throw RemoteHTTPError(400, "같은 그룹에서 확인된 작업 ID를 지정해주세요.")
        }
        try reconcileWaits(assignments: assignments, group: request.group, now: now)
        let previous = try visibleWaits(request.group)
        let active = previous.filter { $0.state == "waiting" }
        guard !active.contains(where: { $0.request.source == request.source }) else { throw RemoteHTTPError(409, "이 작업에 이미 대기가 있습니다. 기존 waitID를 확인하세요.") }
        for row in previous where row.state == "expired" && row.request.source == request.source {
            try transition(row, to: "cancelled", detail: "요청자가 새 대기를 등록했습니다.")
        }
        let data = try JSONEncoder().encode(request)
        try update("INSERT INTO group_waits(id,group_id,owner_task,request,state,deadline) VALUES(?,?,?,?,'waiting',?)",
                   [request.id.uuidString, request.group.uuidString, request.task?.uuidString ?? "", String(decoding: data, as: UTF8.self),
                    String(now.addingTimeInterval(TimeInterval(request.seconds)).timeIntervalSince1970)])
        try reconcileWaits(assignments: assignments, group: request.group, now: now, newest: request.id)
        return try savedWait(request.id)
    }

    private func savedWait(_ id: UUID) throws -> GroupWaitRecord {
        guard let row = try waitRecord(id) else { throw AppError.message("저장된 대기를 확인하지 못했습니다.") }
        return row
    }

    /// Least fixed point: an unblocked producer or an external event can make progress.
    /// AND requires every prerequisite, OR only one. Return the reachable closed subgraph.
    static func closedDependencies(in requests: [GroupWaitRequest], from source: String, unavailable: Set<String>) -> [String] {
        let graph = Dictionary(uniqueKeysWithValues: requests.map { ($0.source, $0) })
        var closed = Set(graph.keys)
        while true {
            let open = closed.filter { key in
                let r = graph[key]!
                return r.matches(r.inputs.map { !closed.contains($0) && !unavailable.contains($0) } + (r.external ? [true] : []))
            }
            if open.isEmpty { break }
            closed.subtract(open)
        }
        guard closed.contains(source) else { return [] }
        var stack = [source], seen = Set<String>(), edges: [String] = [], returnsToSource = false
        while let key = stack.popLast() {
            guard seen.insert(key).inserted else { continue }
            let r = graph[key]!
            let dependencies = r.inputs.filter(closed.contains)
            if dependencies.contains(source) { returnsToSource = true }
            edges.append("\(key) → \(r.mode.rawValue)(\(dependencies.joined(separator: ", ")))")
            stack.append(contentsOf: dependencies.filter { !seen.contains($0) })
        }
        return returnsToSource ? edges : []
    }

    func answer(_ question: UUID, id: UUID?, group: UUID, sender: UUID, recipient: UUID, text: String) throws -> SessionGroupMessage {
        guard let q = try message(question), q.kind == .question, q.groupID == group, q.senderID == recipient, q.recipientID == sender else {
            throw RemoteHTTPError(403, "원래 질문의 지정 수신자만 같은 그룹에서 답할 수 있습니다.")
        }
        let key = "answer:" + question.uuidString
        if let old = try message(sourceKey: key), old.text != text || (id != nil && old.id != id) {
            throw RemoteHTTPError(409, "이미 답변된 질문입니다. 새 대화는 별도 메시지로 보내세요.")
        }
        let answer = try insertMessage(id: id, groupID: group, senderID: sender, recipientID: recipient, kind: .reply, text: text, sourceKey: key)
        try suppressLateAnswerDelivery(question, answer: answer)
        return answer
    }

    func changeWait(_ id: UUID, group: UUID, member: UUID, externalReady: Bool, assignments: [SessionGroupAssignment]) throws -> GroupWaitRecord {
        try transaction {
            guard let row = try waitRecord(id), row.request.group == group, row.request.member == member else { throw RemoteHTTPError(403, "자신이 등록한 대기만 변경할 수 있습니다.") }
            if ["waiting","expired"].contains(row.state) {
                if externalReady {
                    guard row.request.external else { throw RemoteHTTPError(400, "외부 응답 대기가 아닙니다.") }
                    try update("UPDATE group_waits SET external_ready=1 WHERE id=?", [id.uuidString])
                    try reconcileWaits(assignments: assignments, group: group)
                } else { try transition(row, to: "cancelled", detail: "요청자가 대기를 해제했습니다.") }
            }
            return try savedWait(id)
        }
    }

    /// Read actual results, independently of transport ACKs. Run inside a write transaction.
    func reconcileWaits(assignments: [SessionGroupAssignment], group: UUID? = nil, now: Date = Date(), newest: UUID? = nil) throws {
        let rows = try waitRows("WHERE state IN ('waiting','expired')" + (group == nil ? "" : " AND group_id=?"), group.map { [$0.uuidString] } ?? [])
        var active: [UUID: [GroupWaitRecord]] = [:]
        var unavailable: [UUID: Set<String>] = [:]
        for row in rows {
            let r = row.request
            let tasks = assignments.filter { $0.groupID == r.group }
            if let owner = r.task, !tasks.contains(where: { $0.id == owner && $0.status == .working }) {
                try transition(row, to: "cancelled", detail: "원래 작업이 종료되거나 교체되었습니다.")
                continue
            }
            if let decision = r.decision, try message(sourceKey: "answer:" + decision.uuidString) != nil {
                try transition(row, to: "cancelled", detail: "원래 결정 요청에 이미 답변했습니다.")
                continue
            }
            var results: [Bool] = [], possible: [Bool] = []
            for id in r.tasks {
                let status = tasks.first { $0.id == id }?.status
                let done = try status == .completed || status == .reported || message(sourceKey: "report:" + id.uuidString) != nil
                results.append(done)
                possible.append(done || status == .working)
                if !done && status != .working { unavailable[r.group, default: []].insert("task:" + id.uuidString) }
            }
            for q in r.questions {
                results.append(try message(sourceKey: "answer:" + q.uuidString) != nil)
                possible.append(true)
            }
            if r.external { results.append(row.externalReady); possible.append(true) }
            if r.matches(results) {
                let singleQuestion = r.questions.count == 1 && r.tasks.isEmpty && !r.external
                // An expired wait still owns its results: the filter withholds them from
                // individual notices, so a late arrival must be summarised in one ready notice.
                let body = !singleQuestion && (row.state == "waiting" || !r.tasks.isEmpty || !r.questions.isEmpty)
                    ? try readyBody(r, assignments: assignments) : ""
                try transition(row, to: "ready", detail: row.state == "expired" ? "기한이 지난 뒤 필요한 응답이 도착했습니다." : "필요한 응답이 도착했습니다.", payload: body)
            }
            else if !r.matches(possible) { try transition(row, to: "cancelled", detail: "필요한 작업이 결과 없이 교체되었습니다.") }
            else if row.state == "waiting", now >= row.deadline { try transition(row, to: "expired", detail: "정한 기한까지 결과가 도착하지 않았습니다.") }
            else if row.state == "waiting" { active[r.group, default: []].append(row) }
        }
        // A replaced alternative can close an existing OR cycle even without a new wait.
        for (groupID, candidates) in active where newest != nil || unavailable[groupID] != nil {
            var graph = candidates.map(\.request)
            let ordered = candidates.sorted { left, right in
                if left.request.id == newest { return right.request.id != newest }
                if right.request.id == newest { return false }
                return left.request.id.uuidString < right.request.id.uuidString
            }
            for row in ordered {
                let r = row.request
                if let newest, newest != r.id, unavailable[groupID] == nil { continue }
                let edges = Self.closedDependencies(in: graph, from: r.source, unavailable: unavailable[groupID] ?? [])
                guard !edges.isEmpty else { continue }
                let detail = "순환으로 자동 대기를 보류했습니다. " + edges.joined(separator: " / ")
                try transition(row, to: "cycle", detail: detail)
                if let parent = assignments.first(where: { $0.id == r.task })?.parentMemberID, parent != r.member {
                    try notify(row, recipient: parent, state: "cycle", detail: detail)
                }
                graph.removeAll { $0.source == r.source }
                if newest == r.id && unavailable[groupID] == nil { break }
            }

        }
    }

    private func transition(_ row: GroupWaitRecord, to state: String, detail: String, payload: String = "") throws {
        try update("UPDATE group_waits SET state=?,detail=? WHERE id=?", [state, detail, row.request.id.uuidString])
        // A late external signal comes from the waiting member itself; only late results are news to it.
        if row.state == "expired", state == "ready", payload.isEmpty { return }
        // The answer's own body is also the wake-up for a single blocking question.
        if state != "ready" || row.request.questions.count != 1 || !row.request.tasks.isEmpty || row.request.external {
            try notify(row, recipient: row.request.member, state: state, detail: detail, payload: payload)
        }
    }
    private func notify(_ row: GroupWaitRecord, recipient: UUID, state: String, detail: String, payload: String = "") throws {
        let id = row.request.id.uuidString
        let key = "wait:\(id):\(state):\(recipient.uuidString)"
        let body = "대기 \(id) · \(state) · " + String(detail.prefix(3000)) + (payload.isEmpty ? "" : "\n" + payload)
        if row.state == "expired", let stale = try message(sourceKey: "wait:\(id):expired:\(recipient.uuidString)"),
           stale.attempts == 0 || stale.lastResult == "not_started", stale.acknowledgedAt == nil {
            // Retire only the unsubmitted hint: never tried, or every try stopped before typing.
            // A reader may already know its immutable message ID.
            try update("UPDATE messages SET last_result='superseded' WHERE id=?", [stale.id.uuidString])
        }
        _ = try insertMessage(groupID: row.request.group, senderID: recipient, recipientID: recipient, kind: .waitNotice,
            text: body, sourceKey: key)
    }
}

extension GroupWaitRequest {
    static func uuid(_ object: JSONObject, _ key: String) throws -> UUID? {
        guard let value = object[key] else { return nil }
        guard let string = value as? String, let id = UUID(uuidString: string) else { throw RemoteHTTPError(400, "\(key)는 UUID여야 합니다.") }
        return id
    }

    static func flag(_ object: JSONObject, _ key: String) throws -> Bool {
        guard let value = object[key] else { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw RemoteHTTPError(400, "\(key)는 불리언이어야 합니다.") }
        return number.boolValue
    }

    static func parse(_ object: JSONObject, id: UUID, group: UUID, member: UUID, task: UUID?, question: UUID? = nil) throws -> Self {
        func ids(_ key: String) throws -> [UUID] {
            guard let value = object[key] else { return [] }
            guard let strings = value as? [String], strings.count <= 32 else { throw RemoteHTTPError(400, "\(key)는 UUID 최대 32개의 배열이어야 합니다.") }
            let values = strings.compactMap(UUID.init(uuidString:))
            guard values.count == strings.count, Set(values).count == values.count else { throw RemoteHTTPError(400, "중복 없는 UUID를 지정해주세요.") }
            return values.sorted { $0.uuidString < $1.uuidString }
        }
        let seconds = object["timeoutSeconds"] ?? 300
        guard let number = seconds as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              (1...604800).contains(number.doubleValue), Double(number.intValue) == number.doubleValue,
              let raw = (object["mode"] ?? "all") as? String, let mode = Mode(rawValue: raw) else { throw RemoteHTTPError(400, "mode(all/any)와 기한(1~604800초)을 확인해주세요.") }
        let tasks = try ids("taskIDs"), questions = try question.map { [$0] } ?? ids("questionIDs")
        let external = try flag(object, "external")
        guard !tasks.isEmpty || !questions.isEmpty || external else { throw RemoteHTTPError(400, "기다릴 작업·질문·외부 결과를 지정해주세요.") }
        return try Self(id: id, group: group, member: member, task: task, decision: uuid(object, "forQuestionID"),
                        tasks: tasks, questions: questions, external: external, mode: mode, seconds: number.intValue)
    }
}
