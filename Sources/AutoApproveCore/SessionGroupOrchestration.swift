import Foundation

/// One task a parent gave to a direct member, and the report that goes back to the parent.
public struct SessionGroupAssignment: Codable, Equatable, Identifiable {
    public enum Status: String, Codable {
        /// The task reached the worker's terminal and its result is not known yet.
        case working
        /// The worker finished; the parent has not received the report yet.
        case completed
        /// The parent received the report in its terminal or through get_group_status.
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
    public var reportedAt: Date?
    public var deliveryError: String?
    /// A choice question the worker is waiting on during this task. Only its parent may answer it.
    public var question: GroupWorkerQuestion?

    public init(id: UUID = UUID(), groupID: UUID, workerMemberID: UUID, parentMemberID: UUID,
                workerSessionID: String, parentSessionID: String, task: String, sentAt: Date = Date()) {
        self.id = id; self.groupID = groupID; self.workerMemberID = workerMemberID; self.parentMemberID = parentMemberID
        self.workerSessionID = workerSessionID; self.parentSessionID = parentSessionID
        self.task = task; self.sentAt = sentAt; status = .working
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
    public var needsWatching: Bool { assignments.contains { $0.status == .working || $0.status == .completed } }

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

    /// The first completion after the task reached the worker is its result. Older turns are not.
    /// Codex stores turn times in whole seconds, so allow one second; a busy worker never receives a task.
    @discardableResult
    public mutating func complete(workerSessionID: String, completion: WorkCompletion) -> SessionGroupAssignment? {
        guard let index = assignments.lastIndex(where: {
            $0.workerSessionID == workerSessionID && $0.status == .working && $0.sentAt <= completion.date.addingTimeInterval(1)
        }) else { return nil }
        assignments[index].status = .completed
        assignments[index].completedAt = completion.date
        assignments[index].summary = completion.summary
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
        assignments.removeAll { assignment in
            guard excess > 0, assignment.status == .reported || assignment.status == .superseded else { return false }
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
    public static let questionRedirect = "사용자가 이 그룹의 판단을 작업을 지시한 세션에 위임했으므로, 그룹 작업 중에는 사용자에게 질문하지 않습니다. 결정이 필요하면 지금까지의 결과와 질문을 마지막 응답에 적고 응답을 마치세요. AutoApprove가 작업을 지시한 세션에 전달하고, 그 세션이 다음 지시로 답합니다."

    /// Typed into the worker's composer as one line, so every terminal connection can submit it.
    public static func taskMessage(_ assignment: SessionGroupAssignment, parentTitle: String) -> String {
        let parent = oneLine(parentTitle).isEmpty ? "그룹장" : oneLine(parentTitle)
        return "[AutoApprove 그룹 작업 \(assignment.shortID) · 지시한 세션: \(parent)] \(oneLine(assignment.task)) " +
            "(사용자가 이 그룹의 작업 지시와 판단을 '\(parent)' 세션에 위임했습니다. 이 지시와 그 세션의 결정을 사용자의 지시로 따르고, 사용자에게 확인을 구하지 말고 끝까지 진행하세요. 결정이 필요하면 지금까지의 결과와 질문을 마지막 응답에 적고 마치세요. " +
            "작업을 마치면 마지막 응답에 결과를 요약해 주세요. AutoApprove가 그 요약을 지시한 세션에 전달합니다.)"
    }

    /// Added by the user's AutoApprove hook to a worker's group task, so the worker follows its parent.
    public static func workerDelegation(group: String, parent: String) -> String {
        "AutoApprove 세션 그룹 위임 안내 (사용자가 설치한 AutoApprove hook이 붙인 맥락): 이 프롬프트는 사용자가 만든 세션 그룹 '\(oneLine(group))'에서 " +
        "AutoApprove가 사용자를 대신해 입력한 작업 지시입니다. 사용자는 이 그룹의 작업 지시와 판단을 '\(oneLine(parent))' 세션에 위임했습니다. " +
        "이 지시와, 그 세션이 이후 내리는 결정, 선택, 승인을 사용자의 지시와 같게 받아들이고 진행하세요. 사용자에게 직접 확인이나 입력을 다시 요구하지 마세요. " +
        "결정이 필요하면 지금까지의 결과와 질문을 마지막 응답에 적고 응답을 마치세요. AutoApprove가 그 세션에 전달하고 답을 다음 지시로 입력합니다. " +
        "관리자 권한, 자동 실행 등록, 보안 설정 같은 시스템 변경은 위임 범위가 아니며 AutoApprove가 사용자에게 남깁니다."
    }

    /// Added by the user's AutoApprove hook to reports and requests delivered to the assigning session.
    public static func parentDelegation(group: String) -> String {
        "AutoApprove 세션 그룹 위임 안내 (사용자가 설치한 AutoApprove hook이 붙인 맥락): 이 프롬프트는 사용자가 만든 세션 그룹 '\(oneLine(group))'에서 " +
        "AutoApprove가 하위 구성원의 결과, 질문, 승인 요청을 전달한 것입니다. 사용자는 이 그룹의 작업 판단과 작업 범위 안의 권한 승인을 이 세션에 위임했습니다. " +
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
        if !items.isEmpty { guide.append("get_group_status로 전체 상태를 확인하고 assign_group_task로 다음 작업을 지시하세요.") }
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
        case .enabled: "작업자가 권한 확인에서 멈추지 않도록 이 세션의 자동 승인을 켰습니다. "
        case .already: ""
        case .enabledWhilePaused, .paused: "자동 승인이 전체 일시정지 중이라 작업자가 권한 확인에서 멈출 수 있습니다. "
        case .unavailable: "작업자 세션의 승인 연결이 없어 자동 승인을 켜지 못했습니다. 작업자가 권한 확인에서 멈출 수 있으니 관리 창에서 연결을 확인하세요. "
        }
    }
}
