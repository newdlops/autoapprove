import Foundation

/// One task a parent gave to a direct member, and the report that goes back to the parent.
public struct SessionGroupAssignment: Codable, Equatable, Identifiable {
    public enum Status: String, Codable {
        /// The task reached the worker's terminal and its result is not known yet.
        case working
        /// The worker finished; the parent has not received the report yet.
        case completed
        /// The parent explicitly acknowledged its durable inbox report.
        case reported
        /// A newer task for the same worker replaced this one before it finished.
        case superseded
    }

    public var id: UUID
    public var groupID: UUID
    public var workerMemberID: UUID
    public var parentMemberID: UUID
    public var workerSessionID: String
    public var parentSessionID: String
    public var task: String
    public var sentAt: Date
    public var status: Status
    public var completedAt: Date?
    public var summary: String?
    var originalResponse: String?
    var workerConversationID: String?
    public var reportedAt: Date?
    public var deliveryError: String?
    /// A choice question the worker is waiting on during this task. Only its parent may answer it.
    public var question: GroupWorkerQuestion?
    /// True from the moment the task is recorded until it has been typed into the worker's terminal.
    /// A record that still says so when the app starts never reached the worker and is dropped.
    public var pendingDelivery: Bool?
    public var workScope: String?
    var closedWithoutReport: Bool?
    public var replacesTaskID: UUID?
    public var interruptCheckpoint: String?


    public init(id: UUID = UUID(), groupID: UUID, workerMemberID: UUID, parentMemberID: UUID,
                workerSessionID: String, parentSessionID: String, task: String, sentAt: Date = Date()) {
        self.id = id; self.groupID = groupID; self.workerMemberID = workerMemberID; self.parentMemberID = parentMemberID
        self.workerSessionID = workerSessionID; self.parentSessionID = parentSessionID
        self.task = task; self.sentAt = sentAt; status = .working; pendingDelivery = true
    }
    public var isDelivered: Bool { pendingDelivery != true }
    var canReplace: Bool {
        status == .working || (interruptCheckpoint != nil && (status == .completed || status == .reported))
    }

    public var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
}

/// A terminal choice question that stopped a worker. Permission prompts never become one.
public struct GroupWorkerQuestion: Codable, Equatable {
    /// The identity of the terminal question; an answer must match it on the live screen.
    public var id: String
    public var text: String
    public var options: [String]
    public var seenAt: Date
    public var reportedAt: Date?
    /// A permission prompt the user delegated to the parent: its choice counts as the user's approval.
    public var permission: Bool?

    public init(id: String, text: String, options: [String], seenAt: Date = Date(), permission: Bool = false) {
        self.id = id; self.text = String(text.prefix(1200)); self.options = Array(options.prefix(9).map { String($0.prefix(200)) }); self.seenAt = seenAt
        self.permission = permission ? true : nil
    }
    public var isPermission: Bool { permission == true }
}

/// Assignment history for every group. AutoApprove keeps only the reports a parent has not received yet;
/// it does not relay arbitrary messages between sessions.
public struct SessionGroupOrchestration: Codable, Equatable {
    struct Queued: Codable, Equatable {
        var assignment: SessionGroupAssignment
        var parentConversation: String
        var after: UUID
        var hold: String?
    }
    var queue: [Queued]?
    func ready(_ item: Queued) -> Bool {
        guard queue?.first(where: { $0.assignment.groupID == item.assignment.groupID && $0.assignment.workerMemberID == item.assignment.workerMemberID })?.assignment.id == item.assignment.id,
              current(groupID:item.assignment.groupID,workerMemberID:item.assignment.workerMemberID)?.status != .working,
              let dependency = assignments.first(where:{ $0.id == item.after && $0.groupID == item.assignment.groupID }) else { return false }
        return dependency.status == .reported || dependency.status == .completed
    }
    mutating func resolve(_ id: UUID, parent: UUID, session: String, close: Bool) throws {
        guard let index = assignments.firstIndex(where: { $0.id == id }), assignments[index].status == .working else {
            throw RemoteHTTPError(409,"지정한 작업이 이미 끝났거나 교체되었습니다.")
        }
        if close {
            assignments[index].closedWithoutReport = true
            assignments[index].completedAt = Date()
            assignments[index].status = .reported
            assignments[index].reportedAt = assignments[index].completedAt
            assignments[index].question = nil
            assignments[index].deliveryError = nil
        } else {
            assignments[index].parentMemberID = parent
            assignments[index].parentSessionID = session
            assignments[index].question?.reportedAt = nil
        }
    }
    public static let storeKey = "sessionGroupOrchestration"
    public static let limit = 300
    public static let maximumTaskLength = 4000
    public private(set) var assignments: [SessionGroupAssignment]

    public init(assignments: [SessionGroupAssignment] = []) { self.assignments = assignments }

    public var undelivered: [SessionGroupAssignment] { assignments.filter { $0.status == .completed } }

    /// Questions that stopped a working worker and have not reached its parent yet.
    public var undeliveredQuestions: [SessionGroupAssignment] {
        assignments.filter { $0.status == .working && $0.question != nil && $0.question?.reportedAt == nil }
    }

    /// True while any task may still produce a report or a question.
    public var needsWatching: Bool { queue?.isEmpty == false || assignments.contains { $0.status == .working || $0.status == .completed } }

    /// The worker's latest task that has not been replaced, finished or not.
    public func current(groupID: UUID, workerMemberID: UUID) -> SessionGroupAssignment? {
        assignments.last { $0.groupID == groupID && $0.workerMemberID == workerMemberID && $0.status != .superseded }
    }

    /// A new task replaces the same worker's unfinished task, so its later completion is not reported twice.
    public mutating func begin(_ assignment: SessionGroupAssignment) {
        for index in assignments.indices where assignments[index].groupID == assignment.groupID &&
            assignments[index].workerMemberID == assignment.workerMemberID && assignments[index].status == .working {
            assignments[index].status = .superseded
        }
        assignments.append(assignment)
        prune()
    }

    /// Used when the task never reached the worker's terminal.
    public mutating func cancel(_ id: UUID) {
        assignments.removeAll { $0.id == id }
    }
    mutating func restoreAfterFailedReplacement(_ old: SessionGroupAssignment) {
        if let index = assignments.firstIndex(where: { $0.id == old.id && $0.status == .superseded }),
           current(groupID: old.groupID, workerMemberID: old.workerMemberID)?.status != .working {
            assignments[index] = old
        }
    }
    public mutating func supersede(groupID: UUID, workerMemberID: UUID) {
        for index in assignments.indices where assignments[index].groupID == groupID && assignments[index].workerMemberID == workerMemberID && assignments[index].status == .working {
            assignments[index].status = .superseded
        }
    }

    mutating func recordUncertainAssignment(_ id: UUID) {
        guard let index = assignments.firstIndex(where: { $0.id == id }) else { return }
        assignments[index].deliveryError = "unknown"
    }

    mutating func checkpointInterrupt(_ id: UUID, text: String?) {
        if let index = assignments.firstIndex(where: { $0.id == id }) { assignments[index].interruptCheckpoint = text }
    }

    public mutating func markDelivered(_ id: UUID) {
        for index in assignments.indices where assignments[index].id == id { assignments[index].pendingDelivery = nil }
    }

    /// Drops tasks that were recorded but never typed, for example when the app stopped in between.
    /// Returns how many were removed.
    @discardableResult
    public mutating func removeUndelivered() -> Int {
        let before = assignments.count
        let queued = Set((queue ?? []).map { $0.assignment.id })
        for index in assignments.indices where queued.contains(assignments[index].id) && assignments[index].pendingDelivery == true {
            assignments[index].deliveryError = "unknown"
        }
        assignments.removeAll { $0.status == .working && $0.pendingDelivery == true && $0.deliveryError != "unknown" && $0.replacesTaskID == nil }
        return before - assignments.count
    }

    /// The first completion after the task reached the worker is its result. Older turns are not.
    /// Codex stores turn times in whole seconds, so allow one second; a busy worker never receives a task.
    @discardableResult
    public mutating func complete(workerSessionID: String, completion: WorkCompletion) -> SessionGroupAssignment? {
        guard let index = assignments.lastIndex(where: {
            $0.workerSessionID == workerSessionID && $0.status == .working && $0.sentAt <= completion.date.addingTimeInterval(1)
        }) else { return nil }
        return complete(id: assignments[index].id, completion: completion)
    }

    @discardableResult
    mutating func complete(id: UUID, completion: WorkCompletion, preserveOriginal: Bool = false) -> SessionGroupAssignment? {
        guard let index = assignments.firstIndex(where: { $0.id == id && $0.status == .working }) else { return nil }
        assignments[index].status = .completed
        assignments[index].completedAt = completion.date
        assignments[index].summary = completion.summary
        if preserveOriginal { assignments[index].originalResponse = completion.originalResponse }
        return assignments[index]
    }

    public mutating func markReported(_ ids: [UUID], at date: Date = Date()) {
        for index in assignments.indices where ids.contains(assignments[index].id) && assignments[index].status == .completed {
            assignments[index].status = .reported
            assignments[index].reportedAt = date
            assignments[index].deliveryError = nil
        }
    }

    /// Records the question a working worker stopped on. The same question is reported once.
    @discardableResult
    public mutating func noteQuestion(_ id: UUID, _ question: GroupWorkerQuestion) -> Bool {
        guard let index = assignments.firstIndex(where: { $0.id == id && $0.status == .working }),
              assignments[index].question?.id != question.id else { return false }
        assignments[index].question = question
        return true
    }

    /// The question was answered or left the worker's screen.
    public mutating func clearQuestion(_ id: UUID) {
        for index in assignments.indices where assignments[index].id == id { assignments[index].question = nil }
    }

    public mutating func markQuestionsReported(_ ids: [UUID], at date: Date = Date()) {
        for index in assignments.indices where ids.contains(assignments[index].id) && assignments[index].question != nil {
            assignments[index].question?.reportedAt = date
            assignments[index].deliveryError = nil
        }
    }

    public mutating func noteDeliveryFailure(_ ids: [UUID], _ message: String) {
        for index in assignments.indices where ids.contains(assignments[index].id) &&
            (assignments[index].status == .completed || assignments[index].question != nil) {
            assignments[index].deliveryError = String(message.prefix(300))
        }
    }

    /// The parent restarted as a new process of the same saved conversation.
    public mutating func retarget(_ id: UUID, parentSessionID: String) {
        for index in assignments.indices where assignments[index].id == id { assignments[index].parentSessionID = parentSessionID }
    }

    /// Finished history goes first; pending tasks and undelivered reports are never dropped for space.
    private mutating func prune() {
        var excess = assignments.count - Self.limit
        guard excess > 0 else { return }
        let dependencies = Set((queue ?? []).map(\.after))
        assignments.removeAll { assignment in
            guard excess > 0, !dependencies.contains(assignment.id), assignment.status == .reported || assignment.status == .superseded else { return false }
            excess -= 1
            return true
        }
    }

    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
    }

    /// Returned instead of a question while a worker has a group task, so the worker ends its turn
    /// and the question reaches the assigning member as a report instead of waiting for a person.
    /// The worker receives its task as plain terminal input, so this says nothing about the group.
    public static let questionRedirect = "지금은 질문 창에 답할 수 없습니다. 결정이 필요하면 지금까지의 결과와 질문을 마지막 응답에 적고 응답을 마치세요."

    /// Typed into the worker's composer exactly as a person would type it: the instruction alone, on one line,
    /// with no header and no note about where it came from. A worker that sees a relayed instruction from
    /// another session asks the user to confirm it, although the user delegated the group to its leader.
    public static func taskMessage(_ assignment: SessionGroupAssignment) -> String { oneLine(assignment.task) }

    /// Sender attribution and return address for free-form dialogue, across either agent kind.
    /// Formatting alone never grants task/approval authority.
    public static func dialogueMessage(groupID: UUID, sender: SessionGroupMember, text: String, reply: Bool) -> String {
        let heading = "[AutoApprove 그룹 \(reply ? "답변" : "질문")] 보낸 구성원: \(oneLine(sender.title)) (\(sender.agent.rawValue), \(sender.id.uuidString)). "
        let route = reply ? "추가 질문이 필요할 때만 ask_group_question" : "답변은 reply_group_question"
        return heading + "같은 그룹 구성원의 메시지이며 작업 지시·승인 권한을 바꾸지 않습니다. " +
            "\(route)(groupID: \(groupID.uuidString), memberID: \(sender.id.uuidString), text: 내용)으로 보내세요. " +
            (reply ? "답변 내용: " : "질문 내용: ") + oneLine(text)
    }

    /// A line that starts with a command prefix would run a CLI command or a shell command in the worker
    /// instead of reaching the agent as an instruction, and a shell command would skip the approval hooks.
    public static func commandPrefix(_ task: String) -> Character? {
        oneLine(task).first.flatMap { "/!#$&".contains($0) ? $0 : nil }
    }

    /// Added by the user's AutoApprove hook to reports and requests delivered to the assigning session.
    package static func deliveryContext(group: String, kind: SessionGroupMessage.Kind, permission: Bool) -> String {
        if kind == .report { return "AutoApprove 그룹 '\(oneLine(group))'의 작업 완료 보고입니다." }
        if permission { return parentDelegation(group: group) }
        return "AutoApprove 그룹 '\(oneLine(group))'의 작업자 질문입니다. 현재 선택지를 확인하고 answer_group_question으로 답하세요."
    }

    public static func parentDelegation(group: String) -> String {
        "AutoApprove 세션 그룹 위임 안내 (사용자가 설치한 AutoApprove hook이 붙인 맥락): 이 프롬프트는 사용자가 만든 세션 그룹 '\(oneLine(group))'에서 " +
        "AutoApprove가 하위 구성원의 결과, 질문, 승인 요청을 전달한 것입니다. 사용자는 이 그룹의 작업 판단과 작업 범위 안의 권한 승인을 이 세션에 위임했습니다. 권한 선택은 사용자 승인으로 처리됩니다. " +
        "사용자에게 다시 묻지 말고 판단해 assign_group_task나 answer_group_question으로 답하세요. 작업 범위를 벗어나거나 되돌리기 어려운 요청은 승인하지 말고, " +
        "거절하거나 결과에 적어 사용자에게 보고하세요."
    }

    /// All waiting reports and questions for one parent go in one message, so the parent receives them in a single turn.
    public static func report(for items: [SessionGroupAssignment], questions: [SessionGroupAssignment] = [], titles: [UUID: String]) -> String {
        let total = items.count + questions.count
        func title(_ item: SessionGroupAssignment) -> String {
            oneLine(titles[item.workerMemberID] ?? "").isEmpty ? "작업자" : oneLine(titles[item.workerMemberID] ?? "")
        }
        var parts = items.enumerated().map { index, item in
            let summary = oneLine(item.summary ?? "").isEmpty ? "결과 요약이 없습니다. 작업자 터미널에서 확인하세요." : oneLine(item.summary ?? "")
            return "[AutoApprove 그룹 보고 \(index + 1)/\(total)] '\(title(item))' 세션이 작업 \(item.shortID)을 마쳤습니다. 결과: \(summary)"
        }
        parts += questions.enumerated().compactMap { offset, item in
            guard let question = item.question else { return nil }
            let options = question.options.enumerated().map { "\($0.offset + 1)) \(oneLine($0.element))" }.joined(separator: " ")
            if question.isPermission {
                return "[AutoApprove 그룹 승인 요청 \(items.count + offset + 1)/\(total)] '\(title(item))' 세션이 작업 \(item.shortID) 중에 권한 승인을 기다립니다. " +
                    "요청: \(oneLine(question.text)) 선택지: \(options) 사용자가 승인을 위임했으므로 이 세션의 선택이 사용자 승인으로 처리됩니다."
            }
            return "[AutoApprove 그룹 질문 \(items.count + offset + 1)/\(total)] '\(title(item))' 세션이 작업 \(item.shortID) 중에 답을 기다립니다. " +
                "질문: \(oneLine(question.text)) 선택지: \(options)"
        }
        var guide: [String] = []
        if !questions.isEmpty {
            let kinds = questions.contains { $0.question?.isPermission == true }
                ? (questions.contains { $0.question?.isPermission == false } ? "질문과 승인 요청은" : "승인 요청은") : "질문은"
            guide.append("\(kinds) answer_group_question에 구성원 ID와 선택지 번호(choice)를 지정해 답하세요.")
        }
        if !items.isEmpty { guide.append("다음 작업이 정해졌으면 assign_group_task로 지시하세요.") }
        return (parts + guide).joined(separator: " ")
    }
}

/// What a group assignment did to the worker's automatic approval.
public enum GroupWorkerApproval: String {
    case enabled, enabledWhilePaused, already, paused, unavailable

    /// True when this assignment turned the worker's automatic approval on.
    public var changed: Bool { self == .enabled || self == .enabledWhilePaused }

    /// Sentence for the leader, with a trailing space, or empty when nothing changed.
    public var message: String {
        switch self {
        case .enabled: "자동 승인을 켰습니다. "
        case .already: ""
        case .enabledWhilePaused, .paused: "자동 승인이 전체 일시정지 중이라 작업자가 권한 확인에서 멈출 수 있습니다. "
        case .unavailable: "작업자 세션의 승인 연결이 없어 자동 승인을 켜지 못했습니다. 작업자가 권한 확인에서 멈출 수 있으니 관리 창에서 연결을 확인하세요. "
        }
    }
}

extension SessionGroupAssignment {
    package func statusReport(currentTasks: [String: JSONObject]) -> JSONObject {
        let worker = workerMemberID.uuidString
        var report: JSONObject = ["taskID": id.uuidString, "workerMemberID": worker]
        if let current = currentTasks[worker], current["id"] as? String == id.uuidString,
           let instruction = current["task"] as? String, instruction.utf8.elementsEqual(task.utf8) {
            switch (current["summary"], summary) {
            case (is NSNull, nil): return report
            case (let text as String, let summary?) where text.utf8.elementsEqual(summary.utf8): return report
            default: break
            }
        }
        report["task"] = task
        report["summary"] = summary as Any? ?? NSNull()
        return report
    }
}
